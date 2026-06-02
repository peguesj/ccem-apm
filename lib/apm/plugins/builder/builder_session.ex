defmodule Apm.Plugins.Builder.BuilderSession do
  @moduledoc "Struct representing a single Builder wizard session."

  @enforce_keys [:id]
  defstruct [
    :id,
    :name,
    :description,
    :source,
    :analyzed,
    :generated_plugin_code,
    :generated_skill_md,
    :error,
    capabilities: [],
    status: :draft,
    created_at: nil
  ]

  @type status :: :draft | :analyzing | :analyzed | :generating | :preview | :writing | :complete | :error

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          source: String.t() | nil,
          capabilities: [atom()],
          analyzed: map() | nil,
          generated_plugin_code: String.t() | nil,
          generated_skill_md: String.t() | nil,
          status: status(),
          error: term() | nil,
          created_at: DateTime.t() | nil
        }

  @spec new(String.t()) :: t()
  def new(id) do
    %__MODULE__{id: id, created_at: DateTime.utc_now()}
  end
end
