defmodule ApmV5.Uat.TestSuite do
  @moduledoc """
  Behaviour for UAT test suite modules.

  Each test suite module must implement:
  - `run/0`      — execute all tests, returning a list of result maps
  - `category/0` — atom identifying the test category (e.g. :api, :liveview)
  - `count/0`    — number of tests in this suite
  """

  @callback run() :: [map()]
  @callback category() :: atom()
  @callback count() :: non_neg_integer()
end
