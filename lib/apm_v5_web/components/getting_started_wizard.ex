defmodule ApmV5Web.Components.GettingStartedWizard do
  @moduledoc """
  Getting Started Wizard — 6-slide modal overlay for new users.

  Slides: Welcome, Agentic Fleet, Monitor, Manage, Formations, Get Started.
  Uses LocalStorage flag to auto-dismiss after first completion.
  Re-triggerable from Help menu.
  """

  use Phoenix.Component

  @slides [
    %{
      id: "welcome",
      title: "Welcome to CCEM APM",
      subtitle: "Your Agentic Performance Monitor",
      body: "CCEM APM gives you real-time visibility into your AI agent fleet. Monitor performance, manage resources, and orchestrate complex multi-agent formations — all from a single dashboard.",
      icon: "hero-rocket-launch"
    },
    %{
      id: "agentic-fleet",
      title: "Agentic Fleet Overview",
      subtitle: "See all your agents at a glance",
      body: "The dashboard shows every registered agent with live status indicators, heartbeat monitoring, and project-level grouping. Agents self-register via the REST API and send periodic heartbeats.",
      icon: "hero-cpu-chip"
    },
    %{
      id: "monitor",
      title: "Monitor & Observe",
      subtitle: "Real-time metrics and telemetry",
      body: "Track token usage, response latency, error rates, and SLO compliance. Time-series charts update every 5 seconds. Set alert rules to catch issues before they impact your users.",
      icon: "hero-chart-bar"
    },
    %{
      id: "manage",
      title: "Manage & Control",
      subtitle: "Interactive agent management",
      body: "Connect, disconnect, restart, or pause agents directly from the dashboard. Send messages via the contextual chat panel. Control entire formations or individual agents with one click.",
      icon: "hero-cog-6-tooth"
    },
    %{
      id: "formations",
      title: "Formations & Orchestration",
      subtitle: "Hierarchical agent deployment",
      body: "Deploy squadrons of agents organized into formations. Each formation has waves that execute in sequence, with automatic gating between waves. Monitor progress in the formation graph view.",
      icon: "hero-squares-2x2"
    },
    %{
      id: "get-started",
      title: "Get Started",
      subtitle: "Quick setup checklist",
      body: nil,
      icon: "hero-check-circle",
      checklist: [
        %{label: "APM server running", check: "server"},
        %{label: "First agent registered", check: "agent"},
        %{label: "Dashboard explored", check: "dashboard"},
        %{label: "Notifications configured", check: "notifications"},
        %{label: "Formation deployed (optional)", check: "formation"}
      ]
    }
  ]

  attr :id, :string, default: "getting-started-wizard"
  attr :show, :boolean, default: false

  def wizard(assigns) do
    assigns = assign(assigns, :slides, @slides)

    ~H"""
    <div
      id={@id}
      phx-hook="TooltipOverlay"
      class={[
        "fixed inset-0 z-50 flex items-center justify-center transition-opacity duration-300",
        if(@show, do: "opacity-100", else: "opacity-0 pointer-events-none")
      ]}
      data-wizard="true"
    >
      <%!-- Backdrop --%>
      <div class="absolute inset-0 bg-black/70 backdrop-blur-sm" phx-click="wizard:dismiss"></div>

      <%!-- Modal --%>
      <div class="relative w-full max-w-2xl mx-4 bg-base-200 rounded-2xl shadow-2xl border border-base-300 overflow-hidden">
        <%!-- Header --%>
        <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
          <h2 class="text-lg font-semibold text-base-content">Getting Started</h2>
          <button
            phx-click="wizard:dismiss"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Close wizard"
          >
            <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
              <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
            </svg>
          </button>
        </div>

        <%!-- Slide content area — managed by JS --%>
        <div id={"#{@id}-slides"} class="px-6 py-8 min-h-[320px]">
          <%= for {slide, idx} <- Enum.with_index(@slides) do %>
            <div
              id={"#{@id}-slide-#{idx}"}
              class={["wizard-slide transition-all duration-300", if(idx == 0, do: "block", else: "hidden")]}
              data-slide-index={idx}
            >
              <div class="text-center">
                <div class="inline-flex items-center justify-center w-16 h-16 rounded-full bg-primary/10 mb-4">
                  <span class={"#{slide.icon} w-8 h-8 text-primary"}></span>
                </div>
                <h3 class="text-xl font-bold text-base-content mb-1"><%= slide.title %></h3>
                <p class="text-sm text-base-content/60 mb-4"><%= slide.subtitle %></p>

                <%= if slide.body do %>
                  <p class="text-base-content/80 max-w-md mx-auto leading-relaxed"><%= slide.body %></p>
                <% end %>

                <%= if slide[:checklist] do %>
                  <div class="text-left max-w-sm mx-auto mt-4 space-y-3">
                    <%= for item <- slide.checklist do %>
                      <label class="flex items-center gap-3 p-2 rounded-lg hover:bg-base-300/50 cursor-pointer">
                        <input type="checkbox" class="checkbox checkbox-primary checkbox-sm" data-check={item.check} />
                        <span class="text-base-content/80"><%= item.label %></span>
                      </label>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Footer with progress dots and nav --%>
        <div class="flex items-center justify-between px-6 py-4 border-t border-base-300">
          <%!-- Progress dots --%>
          <div class="flex gap-1.5">
            <%= for {_slide, idx} <- Enum.with_index(@slides) do %>
              <button
                class={["w-2 h-2 rounded-full transition-colors wizard-dot", if(idx == 0, do: "bg-primary", else: "bg-base-content/20")]}
                phx-click="wizard:goto"
                phx-value-slide={idx}
                aria-label={"Go to slide #{idx + 1}"}
              ></button>
            <% end %>
          </div>

          <%!-- Navigation --%>
          <div class="flex items-center gap-2">
            <button
              phx-click="wizard:dismiss"
              class="btn btn-ghost btn-sm text-base-content/50"
            >Skip</button>
            <button
              id={"#{@id}-prev"}
              class="btn btn-ghost btn-sm hidden"
              phx-click="wizard:prev"
            >Previous</button>
            <button
              id={"#{@id}-next"}
              class="btn btn-primary btn-sm"
              phx-click="wizard:next"
            >Next</button>
          </div>
        </div>
      </div>
    </div>

    <script>
      // Wizard slide navigation (client-side for smooth UX)
      (function() {
        const wizardId = "<%= @id %>";
        let current = 0;
        const total = <%= length(@slides) %>;

        function showSlide(idx) {
          if (idx < 0 || idx >= total) return;
          current = idx;
          document.querySelectorAll(`#${wizardId}-slides .wizard-slide`).forEach((el, i) => {
            el.classList.toggle("hidden", i !== idx);
            el.classList.toggle("block", i === idx);
          });
          document.querySelectorAll(`#${wizardId} .wizard-dot`).forEach((el, i) => {
            el.classList.toggle("bg-primary", i === idx);
            el.classList.toggle("bg-base-content/20", i !== idx);
          });
          const prev = document.getElementById(`${wizardId}-prev`);
          const next = document.getElementById(`${wizardId}-next`);
          if (prev) prev.classList.toggle("hidden", idx === 0);
          if (next) next.textContent = idx === total - 1 ? "Done" : "Next";
        }

        window.addEventListener("phx:wizard:next", () => {
          if (current >= total - 1) {
            localStorage.setItem("ccem_wizard_complete", "true");
            window.dispatchEvent(new CustomEvent("phx:wizard:dismiss"));
          } else {
            showSlide(current + 1);
          }
        });
        window.addEventListener("phx:wizard:prev", () => showSlide(current - 1));
        window.addEventListener("phx:wizard:goto", (e) => showSlide(parseInt(e.detail.slide)));
        window.addEventListener("phx:wizard:dismiss", () => {
          localStorage.setItem("ccem_wizard_complete", "true");
        });
      })();
    </script>
    """
  end
end
