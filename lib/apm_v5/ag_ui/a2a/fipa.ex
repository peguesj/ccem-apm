defmodule ApmV5.AgUi.A2A.FIPA do
  @moduledoc """
  FIPA ACL performative helper constructors for A2A envelopes.

  FIPA (Foundation for Intelligent Physical Agents) defines a standard
  vocabulary of communicative act performatives for multi-agent coordination.
  This module provides thin constructor wrappers that build `A2A.Envelope`
  structs with the correct `message_type` set.

  ## Supported Performatives

  | Function | FIPA Name | Meaning |
  |---|---|---|
  | `cfp/3` | `cfp` | Call for proposals |
  | `propose/3` | `propose` | Respond to a CFP with an offer |
  | `accept_proposal/3` | `accept_proposal` | Accept a proposal |
  | `reject_proposal/3` | `reject_proposal` | Reject a proposal |
  | `inform/3` | `inform` | Inform the receiver of a fact |
  | `failure/3` | `failure` | Inform receiver of a failure |

  ## Usage

      alias ApmV5.AgUi.A2A.FIPA

      {:ok, envelope} = FIPA.cfp(%{task: "analyze logs"}, "agent-1", {:formation, "fmt-1"})
      {:ok, envelope} = FIPA.propose(%{cost: 0.5}, "agent-2", {:agent, "agent-1"})

  All constructors return `{:ok, Envelope.t()} | {:error, String.t()}` —
  the same tagged tuple as `Envelope.new/1`.
  """

  alias ApmV5.AgUi.A2A.Envelope

  @type address :: Envelope.address()
  @type result :: {:ok, Envelope.t()} | {:error, String.t()}

  # ---------------------------------------------------------------------------
  # FIPA Performative Constructors
  # ---------------------------------------------------------------------------

  @doc """
  Build a `cfp` (call for proposals) envelope.

  The initiating agent broadcasts a task description and invites proposals
  from potential executors.

  ## Examples

      iex> {:ok, env} = ApmV5.AgUi.A2A.FIPA.cfp(%{task: "x"}, "agent-1", {:formation, "fmt-1"})
      iex> env.message_type
      "cfp"
  """
  @spec cfp(map(), String.t(), address()) :: result()
  def cfp(payload, from, to) do
    build("cfp", payload, from, to)
  end

  @doc """
  Build a `propose` envelope.

  Response to a `cfp` offering to fulfill the requested task.
  """
  @spec propose(map(), String.t(), address()) :: result()
  def propose(payload, from, to) do
    build("propose", payload, from, to)
  end

  @doc """
  Build an `accept_proposal` envelope.

  Informs the proposing agent that its proposal has been accepted.
  """
  @spec accept_proposal(map(), String.t(), address()) :: result()
  def accept_proposal(payload, from, to) do
    build("accept_proposal", payload, from, to)
  end

  @doc """
  Build a `reject_proposal` envelope.

  Informs the proposing agent that its proposal has been rejected.
  """
  @spec reject_proposal(map(), String.t(), address()) :: result()
  def reject_proposal(payload, from, to) do
    build("reject_proposal", payload, from, to)
  end

  @doc """
  Build an `inform` envelope.

  Used to communicate a fact or result to the receiver.
  """
  @spec inform(map(), String.t(), address()) :: result()
  def inform(payload, from, to) do
    build("inform", payload, from, to)
  end

  @doc """
  Build a `failure` envelope.

  Informs the receiver that the sender was unable to perform an action.
  """
  @spec failure(map(), String.t(), address()) :: result()
  def failure(payload, from, to) do
    build("failure", payload, from, to)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build(performative, payload, from, to) do
    Envelope.new(%{
      from_agent_id: from,
      to: to,
      message_type: performative,
      payload: payload
    })
  end
end
