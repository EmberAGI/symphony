defmodule SymphonyElixir.QaArchitectureContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @skill_path Path.join(@repo_root, ".codex/skills/qa-architecture/SKILL.md")
  @workflow_path Path.join(@repo_root, "elixir/WORKFLOW.md")
  @spec_path Path.join(@repo_root, "spec/domains/repository-quality-assurance.md")
  @handoff_spec_path Path.join(@repo_root, "spec/domains/symphony-handoff-artifacts.md")
  @index_path Path.join(@repo_root, "spec/index.md")
  @qa_skill_files ~w(DEEPENING.md INTERFACE-DESIGN.md LANGUAGE.md SKILL.md)

  test "localized QA architecture skill exists in the shared role skill source" do
    skill = File.read!(@skill_path)

    assert @repo_root
           |> Path.join(".codex/skills/qa-architecture")
           |> File.ls!()
           |> Enum.sort() == @qa_skill_files

    assert skill =~ "name: qa-architecture"
    assert skill =~ "implementation-touched files"
    assert skill =~ "deepening opportunities"
    assert skill =~ "LANGUAGE.md"
    assert skill =~ "DEEPENING.md"
    assert skill =~ "INTERFACE-DESIGN.md"
    assert skill =~ "PR changed files"
    assert skill =~ "merge base"
    assert skill =~ "origin/main"
    assert skill =~ "Architecture QA: not applicable"
    assert skill =~ "`CONTEXT.md`, when"
    assert skill =~ "is useful domain vocabulary"
    assert skill =~ "Do not use `CONTEXT.md` or `docs/adr/` as canonical sources"
    assert skill =~ "Do not inventory"
    assert skill =~ "the rest of the repository"
  end

  test "localized support files preserve upstream architecture vocabulary" do
    language = File.read!(Path.join(Path.dirname(@skill_path), "LANGUAGE.md"))
    deepening = File.read!(Path.join(Path.dirname(@skill_path), "DEEPENING.md"))
    interface_design = File.read!(Path.join(Path.dirname(@skill_path), "INTERFACE-DESIGN.md"))

    assert language =~ "Module"
    assert language =~ "Interface"
    assert language =~ "Depth"
    assert language =~ "Seam"
    assert language =~ "Adapter"
    assert language =~ "Leverage"
    assert language =~ "Locality"
    assert language =~ "The deletion test"
    assert language =~ "The interface is the test surface"
    assert language =~ "implementation-touched files"

    assert deepening =~ "Dependency Categories"
    assert deepening =~ "In-Process"
    assert deepening =~ "Local-Substitutable"
    assert deepening =~ "Remote But Owned"
    assert deepening =~ "True External"
    assert deepening =~ "One adapter means a hypothetical seam"
    assert deepening =~ "QA does not edit production implementation files"

    assert interface_design =~ "design it more\nthan once"
    assert interface_design =~ "Minimize the interface"
    assert interface_design =~ "Optimize for the common caller"
    assert interface_design =~ "Design around adapters"
    assert interface_design =~ "QA should not run an open-ended design workshop"
  end

  test "QA handoff contract records architecture suggestions once" do
    skill = File.read!(@skill_path)

    assert skill =~ "Agent QA may emit at most one set of architectural suggestions per Linear"
    assert skill =~ "issue"
    assert skill =~ "Architectural suggestions"
    assert skill =~ "- Diff basis:"
    assert skill =~ "- Changed files reviewed:"
    assert skill =~ "- Relevant spec files updated:"
    assert skill =~ "- Requested changes:"
    assert skill =~ "do not add new"
    assert skill =~ "architecture suggestions"
  end

  test "workflow requires QA skill and reviewer and implementer architecture checks" do
    workflow = File.read!(@workflow_path)

    assert workflow =~ "`qa-architecture`: required during Agent QA"
    assert workflow =~ "Agent QA must open and follow `.codex/skills/qa-architecture/SKILL.md`"
    assert workflow =~ "Do not scout the whole"
    assert workflow =~ "repository for architecture improvements"
    assert workflow =~ "QA must not edit production implementation files"
    assert workflow =~ "Agent Review must validate QA-requested architectural changes"
    assert workflow =~ "Agent Fixes work caused by architectural suggestions must use both"
    assert workflow =~ "QA-updated branch-local specs"
    assert workflow =~ "the exact marker `Architectural suggestions`"
  end

  test "repository QA spec defines minimum acceptance suite" do
    spec = File.read!(@spec_path)

    assert spec =~ "Agent QA MUST run the repository-local `qa-architecture` skill"
    assert spec =~ "complete upstream-derived support files"
    assert spec =~ "`LANGUAGE.md`, `DEEPENING.md`, and `INTERFACE-DESIGN.md`"
    assert spec =~ "thin Symphony-local handoff-artifacts consumer"
    assert spec =~ "guards against silently forking the Octo contract"
    assert spec =~ "The pass is bounded to implementation-touched files"
    assert spec =~ "`CONTEXT.md` MAY be used as domain vocabulary"
    assert spec =~ "`CONTEXT.md` and `docs/adr/` MUST NOT be treated as canonical sources"
    assert spec =~ "QA MUST NOT use the architecture pass for whole-repository improvement scouting"
    assert spec =~ "QA may emit at most one set of architectural suggestions per Linear issue"
    assert spec =~ "Agent Review validates QA-requested architecture changes"
    assert spec =~ "Agent Fixes uses QA-updated specs and the QA handoff"
  end

  test "handoff artifacts spec is a thin local reference to Octo source" do
    handoff_spec = File.read!(@handoff_spec_path)
    workflow = File.read!(@workflow_path)
    index = File.read!(@index_path)

    assert handoff_spec =~ "EmberAGI/scaling-octo-engine"
    assert handoff_spec =~ "spec/domains/symphony-handoff-artifacts.md"
    assert handoff_spec =~ "No Symphony-specific local deltas are defined"
    assert handoff_spec =~ "MUST NOT copy the full Octo contract"
    assert handoff_spec =~ "The full Octo contract is not copied into this repository"
    assert length(String.split(handoff_spec, "\n")) <= 90

    assert index =~ "[Symphony Handoff Artifacts](./domains/symphony-handoff-artifacts.md)"
    assert workflow =~ "QA should read `spec/domains/symphony-handoff-artifacts.md`"
    assert workflow =~ "reviewer\nvalidation should include `spec/domains/symphony-handoff-artifacts.md`"
  end

  test "successful QA handoffs require upstream packet sections and artifact index" do
    handoff_spec = File.read!(@handoff_spec_path)
    workflow = File.read!(@workflow_path)
    spec = File.read!(@spec_path)

    for required <- [
          "Human Review Packet",
          "Review Focus",
          "Executive Summary",
          "Action Log",
          "Validation Matrix",
          "Artifact Index",
          "Environment And Provenance",
          "Known Limitations",
          "Merge Readiness"
        ] do
      assert workflow =~ required
    end

    assert handoff_spec =~ "MUST follow Octo's upstream handoff-artifacts contract"
    assert handoff_spec =~ "The local workflow MUST NOT redefine that contract"
    assert handoff_spec =~ "The Artifact Index is mandatory"
    assert workflow =~ "Do not copy or redefine Octo's full\nhandoff-artifact policy in Symphony"
    assert spec =~ "Successful `Agent QA` to `Human Review` handoffs MUST"
    assert spec =~ "mandatory Artifact Index"
  end
end
