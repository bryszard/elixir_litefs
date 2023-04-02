defmodule Litefs do
  @moduledoc """

  Litefs sets a primary file in the directory of the mount it is managing to indicate
  the location of the primary when on a replica. There is no file on the primary.

  Elixir communicates in a mesh with names that may be different than the hostname
  that is contained in the file managed by Litefs. As Litefs can change the primary
  without notice, we need to periodically update the state of the primary in memory.

  There are several cases when we try to update the primary:
  1) when a node goes connects / up / down
  2) after the primary_check_time has passed which is default 30 seconds

  NOTE 2022-08-24

  On a litefs crash with a stale filesystem, there are some errors to handle.
  1) Elixir will have a stale filehandle and will return (Exqlite.Error) disk I/O error
  2) Litefs will not be able to unmount or restart as Elixir has the file handle open.

  Based on the fly_rpc and fly_postgres packages.

  """

  use GenServer
  require Logger

  @tab :litefs
  @primary_check_time 30_000
  @verbose_log false
  @ets_key_primary_file :primary_file
  @ets_key_position_file :position_file
  @ets_key_primary_node :primary_node

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    _tab = :ets.new(@tab, [:named_table, :public, read_concurrency: true])

    database_path = Keyword.get(opts, :database)
    database_dir = Path.dirname(database_path)
    database_position_file = "#{database_path}-pos"
    database_primary_file = "#{database_dir}/.primary"

    set(@ets_key_primary_file, database_primary_file)
    set(@ets_key_position_file, database_position_file)

    # monitor new node up/down activity
    :global_group.monitor_nodes(true)
    {:ok, %{}, {:continue, :update_primary}}
  end

  def set(key, value) do
    :ets.insert(@tab, {key, value})
  end

  def get(key) do
    if :ets.whereis(@tab) == :undefined do
      nil
    else
      case :ets.lookup(@tab, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    end
  end

  def check_for_litefs_primary_file() do
    primary_file_path = get(@ets_key_primary_file)
    # We don't know where the database is mounted.
    if is_nil(primary_file_path) do
      Logger.error("Litefs #{Node.self()}: has no database path set in ETS.")
      false
    else
      File.exists?(primary_file_path)
    end
  end

  def get_primary!() do
    primary_node = get(@ets_key_primary_node)
    if is_nil(primary_node) do
      raise "No primary found!"
    end
    primary_node
  end

  def update_primary() do
    primary_file_path = get(@ets_key_primary_file)

    updated_primary_node =
      if !is_nil(primary_file_path) && !File.exists?(primary_file_path) do
        Node.self()
      else
        Enum.reduce_while(Node.list(), nil, fn x, acc ->
          if !Litefs.rpc(x, __MODULE__, :check_for_litefs_primary_file, []) do
            {:halt, x}
          else
            {:cont, acc}
          end
        end)
      end

    # Check if the primary_node has changed
    original_primary_node = get(@ets_key_primary_node)
    if original_primary_node != updated_primary_node  do
      Logger.info("Litefs #{Node.self()}: primary node changed from #{original_primary_node} to #{updated_primary_node}")
      set(@ets_key_primary_node, updated_primary_node)
    end

    if !is_nil(updated_primary_node), do: :ok, else: :error
  end

  def handle_continue(:update_primary, state) do
    update_primary()
    Process.send_after(self(), :update_primary, @primary_check_time)
    {:noreply, state}
  end

  def handle_info(:update_primary, state) do
    update_primary()
    Process.send_after(self(), :update_primary, @primary_check_time)
    {:noreply, state}
  end

  def handle_info({:nodeup, node_name}, state) do
    Logger.debug("nodeup #{node_name}")
    update_primary()
    {:noreply, state}
  end

  def handle_info({:nodedown, node_name}, state) do
    Logger.debug("nodedown #{node_name}")
    update_primary()
    {:noreply, state}
  end

  @doc """
  Executes the function on the remote node and waits for the response.

  Exits after `timeout` milliseconds.
  """
  @spec rpc(node, module, func :: atom(), args :: [any], non_neg_integer()) :: any()
  def rpc(node, module, func, args, timeout \\ 5000)

  def rpc(:primary, module, func, args, timeout) do
    primary_node = get_primary!()
    rpc(primary_node, module, func, args, timeout)
  end

  def rpc(node, module, func, args, timeout) do
    verbose_log(:info, fn ->
      "RPC REQ from #{Node.self()} to #{node}: #{mfa_string(module, func, args)}"
    end)

    caller = self()
    ref = make_ref()

    # Perform the RPC call to the remote node and wait for the response
    _pid =
      Node.spawn_link(node, __MODULE__, :__local_rpc__, [
        [caller, ref, module, func | args]
      ])

    receive do
      {^ref, result} ->
        verbose_log(:info, fn ->
          "RPC RECV response from #{node} to #{Node.self()}: #{mfa_string(module, func, args)}"
        end)

        result
    after
      timeout ->
        verbose_log(:error, fn ->
          "RPC TIMEOUT from #{node} to #{Node.self}: #{mfa_string(module, func, args)}"
        end)

        exit(:timeout)
    end
  end

  def rpc_and_wait(:primary, module, func, args, timeout \\ 5000) do
    primary_node = get_primary!()
    position_file = get(@ets_key_position_file)
    transaction_id = get_transaction_id(position_file)

    result = rpc(primary_node, module, func, args)

    # We don't know what the new transaction number should be, but it
    # whatever it is, it should be incremented.
    wait_for_next_transaction_id(position_file, transaction_id, System.monotonic_time(), timeout, 0)

    result
  end

  def get_transaction_id(position_file) do
    [ transaction_id, _transaction_hash] = File.read!(position_file) |> String.trim |> String.split("/")
    # If this is unparsable, something bad happenned and just crash.
    { transaction_number, "" } = Integer.parse(transaction_id, 16)
    transaction_number
  end

  def wait_for_next_transaction_id(position_file, id, start_time, timeout, retry_count) do
    Logger.info("Litefs #{Node.self()} - waiting for next transaction_id - #{start_time} - #{id}")
    cond do
      (System.monotonic_time() - start_time) / 1_000_000 > timeout ->
        Logger.error("Litefs #{Node.self()} - replication timed out waiting for next transaction_id")
        false
      get_transaction_id(position_file) > id ->
        true
      true ->
        backoff_time = backoff(retry_count)
        :timer.sleep(backoff_time)
        wait_for_next_transaction_id(position_file, id, start_time, timeout, retry_count + 1)
    end
  end

  def backoff(retry_count) do
    base = 20
    cap = 1000
    x = min(cap, base * :math.pow(2, retry_count)) |> round
    Enum.random(1..min(cap, x))
  end

  @doc false
  # Private function that can be executed on a remote node in the cluster. Used
  # to execute arbitrary function from a trusted caller.
  def __local_rpc__([caller, ref, module, func | args]) do
    result = apply(module, func, args)
    send(caller, {ref, result})
  end

  defp verbose_log(kind, func) do
    if !is_nil(Application.get_env(:litefs, :verbose_logging)) or @verbose_log == true do
      Logger.log(kind, func)
    end
  end

  @doc false
  # A "private" function that converts the MFA data into a string for logging.
  def mfa_string(module, func, args) do
    "#{Atom.to_string(module)}.#{Atom.to_string(func)}/#{length(args)}"
  end
end
