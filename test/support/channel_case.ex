defmodule ApmV4Web.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import ApmV4Web.ChannelCase

      @endpoint ApmV4Web.Endpoint
    end
  end

  setup _tags do
    :ok
  end
end
