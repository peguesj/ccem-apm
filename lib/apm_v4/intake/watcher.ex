defmodule ApmV4.Intake.Watcher do
  @moduledoc """
  Behaviour for intake event watchers.
  Implement this to create a new watcher that reacts to intake events.

  ## Example

      defmodule MyWatcher do
        @behaviour ApmV4.Intake.Watcher

        @impl true
        def name(), do: :my_watcher

        @impl true
        def event_types(), do: [:all]

        @impl true
        def sources(), do: [:all]

        @impl true
        def enabled?(), do: true

        @impl true
        def handle(event, _config) do
          IO.inspect(event, label: "MyWatcher")
          {:ok, %{handled: true}}
        end
      end
  """

  @type event :: map()
  @type result :: map()

  @doc "Unique atom name for this watcher."
  @callback name() :: atom()

  @doc "Event types this watcher handles. Use [:all] to handle all types."
  @callback event_types() :: [:all | String.t()]

  @doc "Sources this watcher handles. Use [:all] to handle all sources."
  @callback sources() :: [:all | String.t()]

  @doc "Whether this watcher is currently enabled."
  @callback enabled?() :: boolean()

  @doc "Handle an intake event. Return {:ok, result_map} or {:error, reason}."
  @callback handle(event(), config :: map()) :: {:ok, result()} | {:error, any()}

  @doc "Returns true if this watcher should handle the given event."
  def matches?(module, event) do
    types = module.event_types()
    sources = module.sources()

    type_match = types == [:all] or event.event_type in Enum.map(types, &to_string/1)
    source_match = sources == [:all] or event.source in Enum.map(sources, &to_string/1)

    type_match and source_match and module.enabled?()
  end
end
