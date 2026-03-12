defmodule ApmV5Web.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import ApmV5Web.ChannelCase

      @endpoint ApmV5Web.Endpoint
    end
  end

  setup _tags do
    :ok
  end
end
