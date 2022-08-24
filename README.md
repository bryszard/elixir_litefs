# Elixir Litefs

When using Sqlite and Litefs with multiple servers, this forwards all write requests to the primary node. 

This library is based off of the packages fly_rpc and fly_postgres_elixir.

## Installation

``` elixir
{:litefs, git: "https://git.sr.ht/~sheertj/elixir_litefs" }
```

## Configuration

  To use it, rename your existing repo module and add a new module with the same
  name as your original repo like this.

  Original code:

  ```elixir
  defmodule MyApp.Repo do
    use Ecto.Repo,
      otp_app: :my_app,
      adapter: Ecto.Adapters.SQLite3
  end
  ```

  Changes to:

  ```elixir
  defmodule MyApp.Repo.Local do
    use Ecto.Repo,
      otp_app: :my_app,
      adapter: Ecto.Adapters.SQLite3
  end

  defmodule MyApp.Repo do
    use Litefs.Repo, local_repo: MyApp.Repo.Local
  end
  ```

The `Litefs.Repo` performs all **read** operations like `all`, `one`, and `get_by`
directly on the local replica. Other modifying functions like `insert`,
`update`, and `delete` are performed on the **primary database** through proxy
calls to a node in your Elixir cluster as identified by `litefs`. 

### Migration Files

After changing your repo name, generating migrations can end up in the wrong place, or at least not where you want them.

You can override the inferred location in your config:

```elixir
config :my_app, MyApp.Repo.Local,
  priv: "priv/repo"
```

### Repo References

The goal with using this repo wrapper, is to leave the majority of your
application code and business logic unchanged. However, there are a few places
that need to be updated to make it work smoothly.

The following examples are places in your project code that need reference your
actual `Ecto.Repo`. Following the above example, it should point to
`MyApp.Repo.Local`.

- `test_helper.exs` files make references like this `Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo.Local, :manual)`
- `data_case.exs` files start the repo using `Ecto.Adapters.SQL.Sandbox.start_owner!` calls.
- `channel_case.exs` need to start your local repo.
- `conn_case.exs` need to start your local repo.
- `config/config.exs` needs to identify your local repo module. Ex: `ecto_repos: [MyApp.Repo.Local]`
- `config/dev.exs`, `config/test.exs`, `config/runtime.exs` - any special repo configuration should refer to your local repo.

With these project plumbing changes, you application code can stay largely untouched!

### Application

There are several changes to your application supervision tree. 

- start the litefs genserver
- start the renamed local ecto repo
- ensure that all the elixir nodes can communicate (using libcluster in the example)

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    # ...
    topologies = Application.get_env(:libcluster, :topologies) || []
    children = [
      # Start litefs genserver and pass the local repo configuration
      {Litefs, Application.get_env(:my_app, LitefsLiveview.Repo.Local)},
      # Start the Ecto repository
      MyApp.Repo.Local,
      # setup libcluster
      {Cluster.Supervisor, [topologies, [name: MyApp.ClusterSupervisor]]},
      #...
    ]

    # ...
  end
end
```

Sqlite journal mode needs to be changed to :delete as litefs does not support WAL atm.

``` elixir

config :my_app, MyApp.Repo.Local,
  database: "/mnt/litefs1/test.db",
  journal_mode: :delete,
  pool_size: 5,
  stacktrace: true

```


Libcluster needs to be configured appropriately for dev.exs / runtime.exs.

```elixir
config :libcluster,
  topologies: [
    local_epmd_example: [
      strategy: Elixir.Cluster.Strategy.LocalEpmd]]
```

