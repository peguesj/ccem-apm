defmodule Apm.Notifications.ActionSchema do
  @moduledoc """
  Defines action schemas for interactive notifications with keyboard shortcuts.

  Any LiveView that renders actionable notification panels can use these schemas
  to provide consistent keyboard shortcut bindings and visual kbd hints.

  ## Usage

      actions = ActionSchema.authorization_actions()
      # => [%{id: "approve", label: "Approve", shortcut: "Enter", ...}, ...]

  Shortcut values are browser key names matching `KeyboardEvent.key`:
  - `"Enter"` — Return/Enter key
  - `"Escape"` — Escape key
  - `"Ctrl+D"` — Ctrl + D combo (check both `key` and `ctrlKey` in handler)
  - `nil` — no keyboard shortcut bound
  """

  @type action :: %{
          id: String.t(),
          label: String.t(),
          shortcut: String.t() | nil,
          style: :success | :error | :warning | :info | :ghost,
          confirm: boolean()
        }

  @doc "Standard authorization actions for AgentLock pending decisions."
  @spec authorization_actions() :: [action()]
  def authorization_actions do
    [
      %{id: "approve", label: "Approve", shortcut: "Enter", style: :success, confirm: false},
      %{id: "allow_5min", label: "Allow 5min", shortcut: nil, style: :info, confirm: false},
      %{id: "always_allow", label: "Always Allow", shortcut: nil, style: :warning, confirm: true},
      %{id: "deny", label: "Deny", shortcut: "Ctrl+D", style: :error, confirm: false},
      %{id: "always_deny", label: "Always Deny", shortcut: nil, style: :error, confirm: true},
      %{id: "dismiss", label: "Dismiss", shortcut: "Escape", style: :ghost, confirm: false}
    ]
  end

  @doc "Standard formation actions for deployment/wave notifications."
  @spec formation_actions() :: [action()]
  def formation_actions do
    [
      %{id: "continue", label: "Continue", shortcut: "Enter", style: :success, confirm: false},
      %{id: "pause", label: "Pause", shortcut: nil, style: :warning, confirm: false},
      %{id: "abort", label: "Abort", shortcut: "Escape", style: :error, confirm: true},
      %{id: "dismiss", label: "Dismiss", shortcut: "Escape", style: :ghost, confirm: false}
    ]
  end

  @doc "Generic notification actions for simple acknowledge/dismiss."
  @spec default_actions() :: [action()]
  def default_actions do
    [
      %{id: "acknowledge", label: "OK", shortcut: "Enter", style: :success, confirm: false},
      %{id: "dismiss", label: "Dismiss", shortcut: "Escape", style: :ghost, confirm: false}
    ]
  end

  @doc "Find the action bound to a given keyboard shortcut key."
  @spec find_by_shortcut([action()], String.t()) :: action() | nil
  def find_by_shortcut(actions, shortcut_key) do
    Enum.find(actions, fn action -> action.shortcut == shortcut_key end)
  end

  @doc "Get the kbd display string for a shortcut (e.g., Enter -> ↵, Escape -> esc)."
  @spec kbd_display(String.t() | nil) :: String.t()
  def kbd_display(nil), do: ""
  def kbd_display("Enter"), do: "↵"
  def kbd_display("Escape"), do: "esc"
  def kbd_display("Ctrl+D"), do: "ctrl+d"
  def kbd_display(other), do: other
end
