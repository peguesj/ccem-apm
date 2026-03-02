defmodule ApmV4.UPM.Adapters.MSProject do
  @moduledoc """
  PM adapter stub for Microsoft Project / Project Online.
  Full implementation is planned for a future release.
  Currently returns {:error, reason} for all callbacks.
  """
  @behaviour ApmV4.UPM.Adapters.PMAdapter

  @not_implemented "Microsoft Project adapter not yet implemented"

  @impl true
  def list_issues(_integration), do: {:error, @not_implemented}

  @impl true
  def create_issue(_integration, _attrs), do: {:error, @not_implemented}

  @impl true
  def update_issue(_integration, _issue_id, _attrs), do: {:error, @not_implemented}

  @impl true
  def normalize(raw), do: raw

  @impl true
  def test_connection(_integration), do: {:error, @not_implemented}
end
