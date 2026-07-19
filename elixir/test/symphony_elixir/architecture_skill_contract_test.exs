defmodule SymphonyElixir.ArchitectureSkillContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @skill_dir Path.join(@repo_root, ".codex/skills/architecture")
  @skill_path Path.join(@skill_dir, "SKILL.md")
  @old_skill_dir Path.join(@repo_root, ".codex/skills/qa-architecture")
  @workflow_path Path.join(@repo_root, "elixir/WORKFLOW.md")
  @spec_path Path.join(@repo_root, "docs/specs/domains/repository-quality-assurance.md")
  @handoff_spec_path Path.join(@repo_root, "docs/specs/domains/symphony-handoff-artifacts.md")
  @index_path Path.join(@repo_root, "docs/specs/index.md")
  @architecture_skill_files ~w(DEEPENING.md INTERFACE-DESIGN.md LANGUAGE.md SKILL.md)

  test "localized architecture skill has a neutral shared name and complete support files" do
    skill = File.read!(@skill_path)

    assert @skill_dir |> File.ls!() |> Enum.sort() == @architecture_skill_files
    refute File.exists?(@old_skill_dir)

    assert skill =~ "name: architecture"
    assert skill =~ "Reusable architecture guidance"
    assert skill =~ "Matt Pocock's `improve-codebase-architecture` skill"
    assert skill =~ "LANGUAGE.md"
    assert skill =~ "DEEPENING.md"
    assert skill =~ "INTERFACE-DESIGN.md"
    assert skill =~ "PR changed files"
    assert skill =~ "merge base"
    assert skill =~ "origin/main"
    assert skill =~ "not applicable for the selected basis"
    assert skill =~ "Do not inventory"
    assert skill =~ "the rest of the repository"

    refute skill =~ "name: qa-architecture"
    refute skill =~ "QA"
    refute skill =~ "Required during Agent QA"
    refute skill =~ "Agent QA may emit"
    refute skill =~ "Architectural suggestions"
  end

  test "localized support files preserve upstream architecture vocabulary" do
    language = File.read!(Path.join(@skill_dir, "LANGUAGE.md"))
    deepening = File.read!(Path.join(@skill_dir, "DEEPENING.md"))
    interface_design = File.read!(Path.join(@skill_dir, "INTERFACE-DESIGN.md"))

    assert language =~ "Module"
    assert language =~ "Interface"
    assert language =~ "Depth"
    assert language =~ "Seam"
    assert language =~ "Adapter"
    assert language =~ "Leverage"
    assert language =~ "Locality"
    assert language =~ "The deletion test"
    assert language =~ "The interface is the test surface"
    assert language =~ "bounded implementation files"

    assert deepening =~ "Dependency Categories"
    assert deepening =~ "In-Process"
    assert deepening =~ "Local-Substitutable"
    assert deepening =~ "Remote But Owned"
    assert deepening =~ "True External"
    assert deepening =~ "One adapter means a hypothetical seam"
    assert deepening =~ "route according to the invoking workflow"

    assert interface_design =~ "design it more\nthan once"
    assert interface_design =~ "Minimize the interface"
    assert interface_design =~ "Optimize for the common caller"
    assert interface_design =~ "Design around adapters"
    assert interface_design =~ "Do not run\nan open-ended design workshop"

    combined = Enum.join([language, deepening, interface_design], "\n")
    refute combined =~ "Agent QA"
    refute combined =~ "Architectural suggestions"
  end

  test "shared skill preserves durable source authority without treating context as canonical" do
    skill = File.read!(@skill_path)

    assert skill =~ "`CONTEXT.md`, when"
    assert skill =~ "is useful domain vocabulary"
    assert skill =~ "Use `docs/specs/` for branch-local product, workflow, and repository behavior"
    assert skill =~ "Use `docs/adr/` for accepted architecture decisions"
    assert skill =~ "Do not use `CONTEXT.md` as a canonical source"
    assert skill =~ "`CONTEXT.md` is domain vocabulary/context, not durable"
  end

  test "workflow treats architecture as a shared skill and leaves Octo QA behavior to Octo" do
    workflow = File.read!(@workflow_path)

    assert workflow =~ "`architecture`: shared architecture vocabulary"
    assert workflow =~ "Octo role workflows decide when and how to invoke it"
    assert workflow =~ ".codex/skills/architecture/"
    assert workflow =~ "not an Octo QA workflow definition"
    assert workflow =~ "EmberAGI/scaling-octo-engine"
    assert workflow =~ "must not copy that\nworkflow contract"
    assert workflow =~ "`CONTEXT.md` as vocabulary/context"
    assert workflow =~ "`docs/specs/` and\n`docs/adr/`"

    refute workflow =~ "qa-architecture"
    refute workflow =~ "Agent QA must open and follow"
    refute workflow =~ "Architectural suggestions"
    refute workflow =~ "QA-updated branch-local specs"
  end

  test "repository QA spec defines source acceptance and the Octo workflow boundary" do
    spec = File.read!(@spec_path)

    assert spec =~ "`.codex/skills/architecture/`"
    assert spec =~ "is a neutral\nshared architecture skill source"
    assert spec =~ "preserve complete upstream-derived\nsupport files"
    assert spec =~ "`LANGUAGE.md`, `DEEPENING.md`, and `INTERFACE-DESIGN.md`"
    assert spec =~ "`CONTEXT.md` is\ndomain vocabulary/context"
    assert spec =~ "`docs/specs/` and `docs/adr/` remain\ncanonical durable sources"
    assert spec =~ "A top-level directory named `spec` or `specs` is not"
    assert spec =~ "MUST NOT define Octo role workflow\nobligations"
    assert spec =~ "EmberAGI/scaling-octo-engine"
    assert spec =~ "MUST NOT claim that the shared `architecture` skill is automatically\nloaded"
    assert spec =~ "not `qa-architecture`"
    assert spec =~ "Validation guards against reintroducing the QA-specific skill name"

    refute spec =~ "Agent QA MUST run the repository-local `qa-architecture` skill"
    refute spec =~ "Agent QA may emit at most one set"
  end

  test "handoff artifacts spec remains a thin local reference to Octo source" do
    handoff_spec = File.read!(@handoff_spec_path)
    index = File.read!(@index_path)

    assert handoff_spec =~ "EmberAGI/scaling-octo-engine"
    assert handoff_spec =~ "EmberAGI/scaling-octo-engine:spec/domains/symphony-handoff-artifacts.md"
    assert handoff_spec =~ "No Symphony-specific local deltas are defined"
    assert handoff_spec =~ "MUST NOT copy the full Octo contract"
    assert handoff_spec =~ "The full Octo contract is not copied into this repository"
    assert length(String.split(handoff_spec, "\n")) <= 90

    assert index =~ "[Symphony Handoff Artifacts](./domains/symphony-handoff-artifacts.md)"
    assert index =~ "shared role\n  skill source validation"
    assert index =~ "Symphony/Octo workflow-boundary validation"
  end
end
