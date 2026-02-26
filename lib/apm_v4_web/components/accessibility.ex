defmodule ApmV4Web.Accessibility do
  @moduledoc """
  WCAG 2.2 AA compliant function components for the APM dashboard.
  """
  use Phoenix.Component

  @doc "Skip-to-main-content link, must be the first focusable element in the page."
  attr :target, :string, default: "#main-content"
  attr :label, :string, default: "Skip to main content"

  def skip_link(assigns) do
    ~H"""
    <a
      href={@target}
      class="skip-link sr-only focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-[9999] focus:px-4 focus:py-2 focus:bg-primary focus:text-primary-content focus:rounded focus:text-sm focus:font-semibold focus:outline-none focus:ring-2 focus:ring-primary-focus"
    >
      {@label}
    </a>
    """
  end

  @doc "Wrapper for dynamic content that should be announced by screen readers."
  attr :id, :string, required: true
  attr :politeness, :string, default: "polite", values: ["polite", "assertive", "off"]
  attr :role, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def live_region(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live={@politeness}
      aria-atomic="true"
      role={@role}
      class={@class}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Accessible status badge with both color AND text label.
  Never relies on color alone (WCAG 1.4.1).
  """
  attr :status, :string, required: true
  attr :class, :string, default: nil

  def status_badge(assigns) do
    assigns = assign(assigns, :badge_class, status_to_badge_class(assigns.status))

    ~H"""
    <span class={["badge badge-sm", @badge_class, @class]} role="status">
      <span class={["inline-block w-1.5 h-1.5 rounded-full mr-1", status_dot_class(@status)]}
            aria-hidden="true"></span>
      {@status}
    </span>
    """
  end

  @doc """
  Accessible meter component for numeric metrics.
  Uses `role="meter"` with full ARIA value attributes.
  """
  attr :label, :string, required: true
  attr :value, :float, required: true
  attr :min, :float, default: 0.0
  attr :max, :float, default: 100.0
  attr :class, :string, default: nil
  attr :color, :string, default: "bg-primary"

  def metric_meter(assigns) do
    pct = if assigns.max > assigns.min do
      ((assigns.value - assigns.min) / (assigns.max - assigns.min) * 100)
      |> min(100)
      |> max(0)
      |> trunc()
    else
      0
    end

    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div
      role="meter"
      aria-label={@label}
      aria-valuenow={@value}
      aria-valuemin={@min}
      aria-valuemax={@max}
      class={["w-full bg-base-300 rounded-full h-2", @class]}
    >
      <div
        class={["h-2 rounded-full transition-all", @color]}
        style={"width: #{@pct}%"}
        aria-hidden="true"
      >
      </div>
    </div>
    """
  end

  defp status_to_badge_class("active"), do: "badge-success"
  defp status_to_badge_class("running"), do: "badge-success"
  defp status_to_badge_class("idle"), do: "badge-ghost"
  defp status_to_badge_class("error"), do: "badge-error"
  defp status_to_badge_class("discovered"), do: "badge-info"
  defp status_to_badge_class("completed"), do: "badge-accent"
  defp status_to_badge_class("warning"), do: "badge-warning"
  defp status_to_badge_class(_), do: "badge-ghost"

  defp status_dot_class("active"), do: "bg-success"
  defp status_dot_class("running"), do: "bg-success"
  defp status_dot_class("error"), do: "bg-error"
  defp status_dot_class("discovered"), do: "bg-info"
  defp status_dot_class("warning"), do: "bg-warning"
  defp status_dot_class("completed"), do: "bg-accent"
  defp status_dot_class(_), do: "bg-base-content/40"
end
