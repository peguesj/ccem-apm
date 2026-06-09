defmodule ApmWeb.Showcase.Registry do
  @moduledoc """
  Registry of `ApmWeb.Showcase.Engine` implementations.

  Engines register themselves at application start via `register/1`. The
  registry is backed by a public, named ETS table so lookups from
  controllers and LiveViews are O(1) and do not serialize through a
  GenServer.

  ## Lifecycle

  The owning GenServer creates the ETS table during `init/1`. Engine
  modules are registered explicitly from `Apm.Application.start/2` — not
  auto-discovered via `Code.all_loaded/0` — so the boot sequence is
  deterministic and an engine module can never end up "half-registered".
  """

  use GenServer

  alias ApmWeb.Showcase.Engine

  @table :showcase_engine_registry

  # --- Public API ---

  @doc """
  Start the registry GenServer.

  ## Options

    * `:engines` — list of engine modules to register immediately after init,
      via `handle_continue/2`. Registration is atomic with respect to the
      supervisor: by the time the supervisor reports the registry as
      `started`, the table exists AND every listed engine is registered.

  ## ETS table ownership

  The ETS table `:showcase_engine_registry` is created here (in the caller's
  process — typically the supervisor) BEFORE `GenServer.start_link/3` is
  invoked, so the table outlives any subsequent GenServer crash + restart.
  This eliminates the boot race where the GenServer would die and take the
  table with it, leaving `register/1` callers with a stale atom name and
  no table.

  Idempotent: re-calling `start_link/1` (e.g. during dev reload) reuses the
  existing table rather than failing on `:ets.new`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    ensure_table!()
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an engine module. The module must implement
  `ApmWeb.Showcase.Engine` and respond to `id/0`.

  Re-registering the same id overwrites the previous binding (useful for
  iex-driven dev reloads).
  """
  @spec register(module()) :: :ok | {:error, term()}
  def register(engine_mod) when is_atom(engine_mod) do
    ensure_table!()
    do_register(engine_mod)
  end

  @doc """
  Look up an engine by id. Returns `{:ok, module}` or `{:error, :not_found}`.
  """
  @spec lookup(String.t()) :: {:ok, module()} | {:error, :not_found}
  def lookup(id) when is_binary(id) do
    case :ets.lookup(table(), id) do
      [{^id, mod}] -> {:ok, mod}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List all registered engines as `[{id, module}]`.
  """
  @spec list() :: [{String.t(), module()}]
  def list do
    :ets.tab2list(table())
  end

  @doc """
  Type guard helper. Returns `true` if `mod` declares the
  `ApmWeb.Showcase.Engine` behaviour.
  """
  @spec engine?(module()) :: boolean()
  def engine?(mod) do
    behaviours =
      mod.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Engine in behaviours
  rescue
    _ -> false
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    # Table is created in start_link/1 (caller-owned, survives restarts).
    # We still re-check here for defensive idempotency in case init/1 is
    # reached via a path that bypassed start_link/1.
    ensure_table!()
    engines = Keyword.get(opts, :engines, [])
    {:ok, %{table: @table, engines: engines}, {:continue, :register_engines}}
  end

  @impl true
  def handle_continue(:register_engines, %{engines: engines} = state) do
    require Logger

    Enum.each(engines, fn engine_mod ->
      case do_register(engine_mod) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[showcase] failed to register #{inspect(engine_mod)}: #{inspect(reason)}"
          )
      end
    end)

    {:noreply, %{state | engines: []}}
  end

  # --- Internals ---

  defp table, do: @table

  # Idempotent ETS table creator. Called from start_link/1 (caller process —
  # typically the supervisor) and again defensively from init/1.
  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

      ref when is_reference(ref) ->
        ref
    end
  end

  # Implementation of register/1 split out so init's handle_continue and the
  # public register/1 share validation logic without an inter-process round-trip.
  defp do_register(engine_mod) when is_atom(engine_mod) do
    with {:module, _} <- Code.ensure_loaded(engine_mod),
         true <- function_exported?(engine_mod, :id, 0),
         id when is_binary(id) <- engine_mod.id() do
      :ets.insert(@table, {id, engine_mod})
      :ok
    else
      false -> {:error, :missing_id_callback}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_engine, other}}
    end
  end
end
