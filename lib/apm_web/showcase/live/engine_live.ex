defmodule ApmWeb.Showcase.Live.EngineLive do
  @moduledoc """
  Generic LiveView host that mounts a showcase engine by id.

  Resolves the engine module via `ApmWeb.Showcase.Registry`, computes the
  active project from `Apm.ConfigLoader`, fetches the engine's payload,
  enforces project scoping, and delegates rendering to the engine's
  `render_payload/2` callback.

  Routes (see router.ex):

      live "/showcase/engines/:engine_id",        Live.EngineLive, :show
      live "/showcase/engines/:engine_id/health", Live.EngineLive, :health
  """

  use ApmWeb, :live_view

  alias ApmWeb.Showcase.Registry
  alias ApmWeb.Showcase.Components.EngineChrome
  alias Apm.ConfigLoader

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:engine_id, nil)
     |> assign(:engine_mod, nil)
     |> assign(:active_project, "")
     |> assign(:status, :ok)
     |> assign(:status_detail, "")
     |> assign(:payload, nil)
     |> assign(:live_action, :show)}
  end

  @impl true
  def handle_params(%{"engine_id" => engine_id} = _params, _uri, socket) do
    active_project = active_project_name()

    case Registry.lookup(engine_id) do
      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:engine_id, engine_id)
         |> assign(:active_project, active_project)
         |> assign(:status, :error)
         |> assign(:status_detail, "engine '#{engine_id}' is not registered")}

      {:ok, engine_mod} ->
        socket =
          socket
          |> assign(:engine_id, engine_id)
          |> assign(:engine_mod, engine_mod)
          |> assign(:active_project, active_project)

        maybe_load_payload(socket, engine_mod, active_project)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <EngineChrome.engine_chrome
      engine_id={@engine_id || "?"}
      active_project={@active_project}
      status={@status}
      status_detail={@status_detail}>
      <%= cond do %>
        <% @status == :ok and is_map(@payload) and @engine_mod != nil -> %>
          {@engine_mod.render_payload(@payload, assigns_for_engine(assigns))}
        <% @status == :not_found -> %>
          <section class="showcase-engine-empty">
            <h2>No payload yet</h2>
            <p>
              No payload has been ingested for engine <code>{@engine_id}</code>
              under project <code>{@active_project}</code>.
            </p>
            <p>
              POST to
              <code>/api/showcase/engines/{@engine_id}</code>
              to ingest a payload.
            </p>
          </section>
        <% @status == :scope_mismatch -> %>
          <section class="showcase-engine-error">
            <h2>Project scope mismatch</h2>
            <p>{@status_detail}</p>
          </section>
        <% true -> %>
          <section class="showcase-engine-error">
            <h2>Engine error</h2>
            <p>{@status_detail}</p>
          </section>
      <% end %>
    </EngineChrome.engine_chrome>
    """
  end

  # --- Internals ---

  defp maybe_load_payload(socket, engine_mod, active_project) do
    cond do
      active_project == "" and engine_mod.project_scope() == :strict ->
        {:noreply,
         socket
         |> assign(:status, :scope_mismatch)
         |> assign(:status_detail, "engine requires an active project but none is set")}

      true ->
        case engine_mod.fetch(active_project, %{}) do
          {:ok, payload} ->
            {:noreply,
             socket
             |> assign(:status, :ok)
             |> assign(:status_detail, "")
             |> assign(:payload, payload)}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> assign(:status, :not_found)
             |> assign(:status_detail, "no payload ingested for this project")
             |> assign(:payload, nil)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:status, :error)
             |> assign(:status_detail, "fetch failed: #{inspect(reason)}")
             |> assign(:payload, nil)}
        end
    end
  end

  defp active_project_name do
    case ConfigLoader.get_active_project() do
      %{"name" => name} when is_binary(name) -> name
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp assigns_for_engine(assigns) do
    Map.take(assigns, [:engine_id, :active_project, :live_action])
  end
end
