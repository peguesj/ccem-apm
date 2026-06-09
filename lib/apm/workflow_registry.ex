defmodule Apm.WorkflowRegistry do
  @moduledoc """
  Registry of skill workflow definitions for the generic WorkflowLive visualizer.

  Built-in workflows are compiled in as module attributes. Additional workflows
  can be registered at runtime via `register_workflow/2`, which stores them in
  the process dictionary of the current process (or a persistent ETS table if
  the registry GenServer is running).

  ## Orchestration types
  Each workflow now carries an `orchestration_type` field:
  - `:pipeline`    — ralph → :autonomous, upm → :formation
  - `:workflow`    — generic DAG
  - `:maintenance` — session health/cleanup
  - `:sync`        — state reconciliation
  - `:formation`   — multi-wave agent deployment
  - `:autonomous`  — self-directing decision loop
  """

  use GenServer

  @table :workflow_registry

  @static_workflows %{
    "ralph" => %{
      id: "ralph",
      title: "Ralph Methodology",
      description: "Autonomous fix loop: PRD → agent formation → commit cycle",
      orchestration_type: :autonomous,
      icon: "hero-document-text",
      phases: [
        %{id: "setup", label: "Setup", color: "#6366f1"},
        %{id: "loop", label: "Loop", color: "#f59e0b"},
        %{id: "decision", label: "Decision", color: "#8b5cf6"},
        %{id: "done", label: "Done", color: "#10b981"}
      ],
      steps: [
        %{
          id: "1",
          label: "Write PRD",
          description:
            "Author a Product Requirements Document with user stories and acceptance criteria.",
          phase: "setup",
          x: 200,
          y: 60
        },
        %{
          id: "2",
          label: "Convert to prd.json",
          description: "Convert PRD to structured prd.json format using the /ralph skill.",
          phase: "setup",
          x: 200,
          y: 140
        },
        %{
          id: "3",
          label: "Run ralph.sh",
          description: "Execute the ralph autonomous agent loop to start implementing stories.",
          phase: "setup",
          x: 200,
          y: 220
        },
        %{
          id: "4",
          label: "Pick Story",
          description: "Select the highest-priority story where passes: false.",
          phase: "loop",
          x: 200,
          y: 320
        },
        %{
          id: "5",
          label: "Implement",
          description: "Agent implements the story: write code, create files, run tests.",
          phase: "loop",
          x: 200,
          y: 400
        },
        %{
          id: "6",
          label: "Quality Checks",
          description: "Run mix compile --warnings-as-errors and mix test.",
          phase: "loop",
          x: 200,
          y: 480
        },
        %{
          id: "7",
          label: "Commit",
          description: "Commit with message: feat: [Story ID] - [Story Title]",
          phase: "loop",
          x: 200,
          y: 560
        },
        %{
          id: "8",
          label: "Update PRD",
          description: "Set story passes: true in prd.json.",
          phase: "loop",
          x: 200,
          y: 640
        },
        %{
          id: "9",
          label: "More Stories?",
          description: "Check if any remaining stories have passes: false.",
          phase: "decision",
          x: 200,
          y: 740
        },
        %{
          id: "10",
          label: "Complete",
          description: "All stories implemented. Formation complete.",
          phase: "done",
          x: 200,
          y: 840
        }
      ],
      edges: [
        %{source: "1", target: "2", label: nil},
        %{source: "2", target: "3", label: nil},
        %{source: "3", target: "4", label: nil},
        %{source: "4", target: "5", label: nil},
        %{source: "5", target: "6", label: nil},
        %{source: "6", target: "7", label: "pass"},
        %{source: "7", target: "8", label: nil},
        %{source: "8", target: "9", label: nil},
        %{source: "9", target: "4", label: "yes"},
        %{source: "9", target: "10", label: "no"}
      ]
    },
    "upm" => %{
      id: "upm",
      title: "UPM Workflow",
      description: "Unified Project Management: plan → build waves → verify → ship",
      orchestration_type: :formation,
      icon: "hero-rocket-launch",
      phases: [
        %{id: "plan", label: "Plan", color: "#6366f1"},
        %{id: "build", label: "Build", color: "#f59e0b"},
        %{id: "verify", label: "Verify", color: "#8b5cf6"},
        %{id: "ship", label: "Ship", color: "#10b981"}
      ],
      steps: [
        %{
          id: "1",
          label: "/upm plan",
          description: "Generate Ralph prd.json, create Plane issues, add CLAUDE.md checkpoints.",
          phase: "plan",
          x: 200,
          y: 60
        },
        %{
          id: "2",
          label: "Formation Deploy",
          description:
            "Analyze story dependencies, group into waves, deploy hierarchical agent formation.",
          phase: "build",
          x: 200,
          y: 160
        },
        %{
          id: "3",
          label: "Wave 1",
          description:
            "Execute independent stories concurrently. Each agent fires-and-forgets APM telemetry.",
          phase: "build",
          x: 200,
          y: 260
        },
        %{
          id: "4",
          label: "tsc Gate",
          description:
            "Run npx tsc --noEmit or mix compile. Hard gate — next wave does not start on failure.",
          phase: "build",
          x: 200,
          y: 360
        },
        %{
          id: "5",
          label: "Wave N",
          description: "Execute dependent stories after previous wave gate passes.",
          phase: "build",
          x: 200,
          y: 460
        },
        %{
          id: "6",
          label: "Kill Criteria?",
          description: "If 3+ agents fail in the same wave, stop and report.",
          phase: "build",
          x: 200,
          y: 560
        },
        %{
          id: "7",
          label: "/upm verify",
          description:
            "TypeScript/Elixir check + live integration testing + TDD unit verification.",
          phase: "verify",
          x: 200,
          y: 660
        },
        %{
          id: "8",
          label: "All Pass?",
          description: "Hard gate: never ship on a failing verify.",
          phase: "verify",
          x: 200,
          y: 760
        },
        %{
          id: "9",
          label: "/upm ship",
          description: "Atomic commit, push, PR, Plane → Done, CLAUDE.md checkpoints → [x].",
          phase: "ship",
          x: 200,
          y: 860
        }
      ],
      edges: [
        %{source: "1", target: "2", label: nil},
        %{source: "2", target: "3", label: nil},
        %{source: "3", target: "4", label: nil},
        %{source: "4", target: "5", label: "pass"},
        %{source: "4", target: "7", label: "last wave"},
        %{source: "5", target: "6", label: nil},
        %{source: "6", target: "4", label: "ok"},
        %{source: "6", target: "8", label: "kill"},
        %{source: "7", target: "8", label: nil},
        %{source: "8", target: "9", label: "pass"},
        %{source: "8", target: "7", label: "fix & retry"}
      ]
    },
    "skill_chain" => %{
      id: "skill_chain",
      title: "Skill Chain Pipeline",
      description:
        "Linear pipeline: /upm → /formation → /apm-auth → /coalesce → /plane-pm → /yougotit",
      orchestration_type: :pipeline,
      icon: "hero-link",
      phases: [
        %{id: "plan", label: "Plan", color: "#6366f1"},
        %{id: "build", label: "Build", color: "#f59e0b"},
        %{id: "sync", label: "Sync", color: "#8b5cf6"},
        %{id: "ship", label: "Ship", color: "#10b981"}
      ],
      steps: [
        %{
          id: "1",
          label: "/upm",
          description: "Unified project management — plan and issue creation.",
          phase: "plan",
          x: 200,
          y: 60
        },
        %{
          id: "2",
          label: "/formation",
          description: "Agent formation deployment with wave orchestration.",
          phase: "build",
          x: 200,
          y: 160
        },
        %{
          id: "3",
          label: "/apm-auth",
          description: "Agent authentication and session registration.",
          phase: "build",
          x: 200,
          y: 260
        },
        %{
          id: "4",
          label: "/coalesce",
          description: "Skill/doc coalesce to sync all references.",
          phase: "sync",
          x: 200,
          y: 360
        },
        %{
          id: "5",
          label: "/plane-pm",
          description: "Plane PM issue updates and status sync.",
          phase: "sync",
          x: 200,
          y: 460
        },
        %{
          id: "6",
          label: "/yougotit",
          description: "Ship completion gate — notify and close.",
          phase: "ship",
          x: 200,
          y: 560
        }
      ],
      edges: [
        %{source: "1", target: "2", label: nil},
        %{source: "2", target: "3", label: nil},
        %{source: "3", target: "4", label: nil},
        %{source: "4", target: "5", label: nil},
        %{source: "5", target: "6", label: nil}
      ]
    },
    "devdrive_sync" => %{
      id: "devdrive_sync",
      title: "DevDrive Sync",
      description: "Bidirectional git<->ETS worktree reconciliation",
      orchestration_type: :sync,
      icon: "hero-arrows-right-left",
      phases: [
        %{id: "read", label: "Read", color: "#6366f1"},
        %{id: "reconcile", label: "Reconcile", color: "#f59e0b"},
        %{id: "write", label: "Write", color: "#10b981"}
      ],
      steps: [
        %{
          id: "1",
          label: "Read git state",
          description: "Read current worktree and branch state from git.",
          phase: "read",
          x: 200,
          y: 60
        },
        %{
          id: "2",
          label: "Read ETS state",
          description: "Read current worktree records from ETS WorktreeStore.",
          phase: "read",
          x: 200,
          y: 160
        },
        %{
          id: "3",
          label: "Diff",
          description: "Compute delta between git and ETS state.",
          phase: "reconcile",
          x: 200,
          y: 260
        },
        %{
          id: "4",
          label: "Apply to ETS",
          description: "Update ETS records to reflect git truth.",
          phase: "write",
          x: 200,
          y: 360
        },
        %{
          id: "5",
          label: "Broadcast",
          description: "PubSub broadcast of reconciliation result.",
          phase: "write",
          x: 200,
          y: 460
        }
      ],
      edges: [
        %{source: "1", target: "3", label: nil},
        %{source: "2", target: "3", label: nil},
        %{source: "3", target: "4", label: nil},
        %{source: "4", target: "5", label: nil}
      ]
    },
    "session_maintenance" => %{
      id: "session_maintenance",
      title: "Session Maintenance",
      description: "Scheduled session health-check, cleanup, and auto-remediation",
      orchestration_type: :maintenance,
      icon: "hero-wrench-screwdriver",
      phases: [
        %{id: "check", label: "Health Check", color: "#6366f1"},
        %{id: "triage", label: "Triage", color: "#f59e0b"},
        %{id: "remediate", label: "Remediate", color: "#10b981"}
      ],
      steps: [
        %{
          id: "1",
          label: "Health Scan",
          description: "Scan all active sessions for stale or missing heartbeats.",
          phase: "check",
          x: 200,
          y: 60
        },
        %{
          id: "2",
          label: "Expired?",
          description: "Identify sessions that have exceeded the TTL threshold.",
          phase: "triage",
          x: 200,
          y: 160
        },
        %{
          id: "3",
          label: "Evict Sessions",
          description: "Remove expired sessions from ETS and log to audit.",
          phase: "remediate",
          x: 200,
          y: 260
        },
        %{
          id: "4",
          label: "Notify APM",
          description: "Emit cleanup telemetry event to APM dashboard.",
          phase: "remediate",
          x: 200,
          y: 360
        }
      ],
      edges: [
        %{source: "1", target: "2", label: nil},
        %{source: "2", target: "3", label: "expired"},
        %{source: "2", target: "4", label: "clean"},
        %{source: "3", target: "4", label: nil}
      ]
    }
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list_workflows() :: [map()]
  def list_workflows do
    runtime = runtime_workflows()
    Map.values(Map.merge(@static_workflows, runtime))
  end

  @spec get_workflow(String.t()) :: map() | nil
  def get_workflow(id) do
    runtime = runtime_workflows()
    Map.get(Map.merge(@static_workflows, runtime), id)
  end

  @spec workflow_ids() :: [String.t()]
  def workflow_ids do
    runtime = runtime_workflows()
    Map.keys(Map.merge(@static_workflows, runtime))
  end

  @doc "Register a workflow at runtime. Stored in ETS if registry is running."
  @spec register_workflow(String.t(), map()) :: :ok
  def register_workflow(id, workflow) when is_binary(id) and is_map(workflow) do
    ensure_table()
    :ets.insert(@table, {id, workflow})
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp runtime_workflows do
    ensure_table()
    :ets.tab2list(@table) |> Map.new(fn {id, wf} -> {id, wf} end)
  rescue
    _ -> %{}
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  rescue
    _ -> :ok
  end
end
