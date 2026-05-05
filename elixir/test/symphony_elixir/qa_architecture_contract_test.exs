defmodule SymphonyElixir.QaArchitectureContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @skill_path Path.join(@repo_root, ".codex/skills/qa-architecture/SKILL.md")
  @workflow_path Path.join(@repo_root, "elixir/WORKFLOW.md")
  @spec_path Path.join(@repo_root, "spec/domains/repository-quality-assurance.md")

  test "localized QA architecture skill exists in the shared role skill source" do
    skill = File.read!(@skill_path)

    assert skill =~ "name: qa-architecture"
    assert skill =~ "implementation-touched files"
    assert skill =~ "PR changed files"
    assert skill =~ "merge base"
    assert skill =~ "origin/main"
    assert skill =~ "Architecture QA: not applicable"
    assert skill =~ "Do not use `CONTEXT.md` or `docs/adr/` as canonical sources"
    assert skill =~ "Do not inventory"
    assert skill =~ "the rest of the repository"
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
    assert spec =~ "The pass is bounded to implementation-touched files"
    assert spec =~ "`CONTEXT.md` and `docs/adr/` MUST NOT be treated as canonical sources"
    assert spec =~ "QA MUST NOT use the architecture pass for whole-repository improvement scouting"
    assert spec =~ "QA may emit at most one set of architectural suggestions per Linear issue"
    assert spec =~ "Agent Review validates QA-requested architecture changes"
    assert spec =~ "Agent Fixes uses QA-updated specs and the QA handoff"
  end
end
