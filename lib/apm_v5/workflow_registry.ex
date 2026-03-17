defmodule ApmV5.WorkflowRegistry do
  @moduledoc "Registry of skill workflow definitions for the generic WorkflowLive visualizer."

  @workflows %{
    "ralph" => %{
      id: "ralph",
      title: "Ralph Methodology",
      description: "Autonomous fix loop: PRD → agent formation → commit cycle",
      icon: "hero-document-text",
      phases: [
        %{id: "setup", label: "Setup", color: "#6366f1"},
        %{id: "loop", label: "Loop", color: "#f59e0b"},
        %{id: "decision", label: "Decision", color: "#8b5cf6"},
        %{id: "done", label: "Done", color: "#10b981"}
      ],
      steps: [
        %{id: "1", label: "Write PRD", description: "Author a Product Requirements Document with user stories and acceptance criteria.", phase: "setup", x: 200, y: 60},
        %{id: "2", label: "Convert to prd.json", description: "Convert PRD to structured prd.json format using the /ralph skill.", phase: "setup", x: 200, y: 140},
        %{id: "3", label: "Run ralph.sh", description: "Execute the ralph autonomous agent loop to start implementing stories.", phase: "setup", x: 200, y: 220},
        %{id: "4", label: "Pick Story", description: "Select the highest-priority story where passes: false.", phase: "loop", x: 200, y: 320},
        %{id: "5", label: "Implement", description: "Agent implements the story: write code, create files, run tests.", phase: "loop", x: 200, y: 400},
        %{id: "6", label: "Quality Checks", description: "Run mix compile --warnings-as-errors and mix test.", phase: "loop", x: 200, y: 480},
        %{id: "7", label: "Commit", description: "Commit with message: feat: [Story ID] - [Story Title]", phase: "loop", x: 200, y: 560},
        %{id: "8", label: "Update PRD", description: "Set story passes: true in prd.json.", phase: "loop", x: 200, y: 640},
        %{id: "9", label: "More Stories?", description: "Check if any remaining stories have passes: false.", phase: "decision", x: 200, y: 740},
        %{id: "10", label: "Complete", description: "All stories implemented. Formation complete.", phase: "done", x: 200, y: 840}
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
      icon: "hero-rocket-launch",
      phases: [
        %{id: "plan", label: "Plan", color: "#6366f1"},
        %{id: "build", label: "Build", color: "#f59e0b"},
        %{id: "verify", label: "Verify", color: "#8b5cf6"},
        %{id: "ship", label: "Ship", color: "#10b981"}
      ],
      steps: [
        %{id: "1", label: "/upm plan", description: "Generate Ralph prd.json, create Plane issues, add CLAUDE.md checkpoints.", phase: "plan", x: 200, y: 60},
        %{id: "2", label: "Formation Deploy", description: "Analyze story dependencies, group into waves, deploy hierarchical agent formation.", phase: "build", x: 200, y: 160},
        %{id: "3", label: "Wave 1", description: "Execute independent stories concurrently. Each agent fires-and-forgets APM telemetry.", phase: "build", x: 200, y: 260},
        %{id: "4", label: "tsc Gate", description: "Run npx tsc --noEmit or mix compile. Hard gate — next wave does not start on failure.", phase: "build", x: 200, y: 360},
        %{id: "5", label: "Wave N", description: "Execute dependent stories after previous wave gate passes.", phase: "build", x: 200, y: 460},
        %{id: "6", label: "Kill Criteria?", description: "If 3+ agents fail in the same wave, stop and report.", phase: "build", x: 200, y: 560},
        %{id: "7", label: "/upm verify", description: "TypeScript/Elixir check + live integration testing + TDD unit verification.", phase: "verify", x: 200, y: 660},
        %{id: "8", label: "All Pass?", description: "Hard gate: never ship on a failing verify.", phase: "verify", x: 200, y: 760},
        %{id: "9", label: "/upm ship", description: "Atomic commit, push, PR, Plane → Done, CLAUDE.md checkpoints → [x].", phase: "ship", x: 200, y: 860}
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
    }
  }

  @spec list_workflows() :: [map()]
  def list_workflows, do: Map.values(@workflows)

  @spec get_workflow(String.t()) :: map() | nil
  def get_workflow(id), do: Map.get(@workflows, id)

  @spec workflow_ids() :: [String.t()]
  def workflow_ids, do: Map.keys(@workflows)
end
