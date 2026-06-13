defmodule SymphonyElixir.RoleSkillSourceTest do
  use ExUnit.Case, async: true

  @localized_skills ~w(tdd frontend-design nodejs pnpm-patching pnpm python typescript)
  @qa_skills ~w(browser-use)
  @tdd_files ~w(SKILL.md SOURCE.md LICENSE.txt deep-modules.md interface-design.md mocking.md refactoring.md tests.md)
  @frontend_design_files ~w(SKILL.md SOURCE.md LICENSE.txt)
  @to_issues_files ~w(SKILL.md SOURCE.md)
  @son_of_anton_skills ~w(nodejs pnpm-patching pnpm python typescript)

  test "implementer manifest exposes localized skill pack only to implementer" do
    manifest = read_manifest!("implementer")

    assert manifest["role"] == "implementer"
    assert manifest["default_exposure"] == "implementer-only"

    skill_names = manifest["skills"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert skill_names == Enum.sort(@localized_skills)

    for skill <- manifest["skills"] do
      skill_path = Path.expand(skill["path"], role_skills_dir())
      assert File.dir?(skill_path), "#{skill["name"]} path must resolve"
      assert File.regular?(Path.join(skill_path, "SKILL.md"))
      assert File.regular?(Path.join(skill_path, "SOURCE.md"))
    end
  end

  test "qa manifest exposes browser-use only to Agent QA" do
    manifest = read_manifest!("qa")

    assert manifest["role"] == "qa"
    assert manifest["default_exposure"] == "agent-qa-only"

    skill_names = manifest["skills"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert skill_names == @qa_skills

    for skill <- manifest["skills"] do
      skill_path = Path.expand(skill["path"], role_skills_dir())
      assert File.dir?(skill_path), "#{skill["name"]} path must resolve"
      assert File.regular?(Path.join(skill_path, "SKILL.md"))
      assert File.regular?(Path.join(skill_path, "SOURCE.md"))
    end

    skill_body = File.read!(Path.join([skills_dir(), "browser-use", "SKILL.md"]))
    assert skill_body =~ "Agent QA"
    assert skill_body =~ "browser-use open"
    assert skill_body =~ "browser-use click <index>"
    assert skill_body =~ "browser-use input <index> \"text\""
    assert skill_body =~ "browser-use type \"text\""
    assert skill_body =~ "browser-use screenshot"
    assert skill_body =~ "uvx --from 'browser-use[cli]' browser-use --mcp"
    assert skill_body =~ "BROWSER_USE_API_KEY"
    assert skill_body =~ "Browser Use Cloud"
    assert skill_body =~ "Human Escalation"
    assert skill_body =~ "tiny review summary"
    assert skill_body =~ "Role note"
    assert skill_body =~ "compact handoff"
    assert skill_body =~ "`Work done`"
    assert skill_body =~ "approved Linear attachment metadata"
    refute skill_body =~ "`Observability`"
    refute skill_body =~ "### Human Review Packet"
    refute skill_body =~ "Validation Matrix"
    refute skill_body =~ "Artifact Index"
    refute skill_body =~ "Merge Readiness"
    refute skill_body =~ "selector-or-description"
    refute skill_body =~ "browser-use type <"
  end

  test "root workflow uses compact handoffs and legacy read-only workpads" do
    workflow = File.read!(Path.join(repo_root(), "elixir/WORKFLOW.md"))

    assert workflow =~ "Do not create or update Linear `## Codex Workpad`"
    assert workflow =~ "Existing Workpads remain legacy read-only context"
    assert workflow =~ "## Symphony Handoff"
    assert workflow =~ "- From -> To:"
    assert workflow =~ "- Work done:"
    assert workflow =~ "- Role note:"
    assert workflow =~ "- Next action:"

    refute workflow =~ "- Observability:"
    refute workflow =~ "compact handoff `Observability`"
    refute workflow =~ "find/create `## Codex Workpad`"
    refute workflow =~ "Create a new bootstrap `## Codex Workpad`"
    refute workflow =~ "Use exactly one persistent workpad"
    refute workflow =~ "## Workpad template"
    refute workflow =~ "source of truth for progress"
    refute workflow =~ "update the workpad"
  end

  test "localized upstream directories include the complete requested file sets" do
    assert committed_files("tdd") == Enum.sort(@tdd_files)
    assert committed_files("frontend-design") == Enum.sort(@frontend_design_files)
    assert committed_files("to-issues") == Enum.sort(@to_issues_files)

    for skill <- @son_of_anton_skills do
      assert committed_files(skill) == ["SKILL.md", "SOURCE.md"]
    end
  end

  test "to-issues shared skill records source and preserves Octo workflow boundaries" do
    skill_body = File.read!(Path.join([skills_dir(), "to-issues", "SKILL.md"]))
    source_body = File.read!(Path.join([skills_dir(), "to-issues", "SOURCE.md"]))

    assert skill_body =~ "tracer bullets"
    assert skill_body =~ "independently grabbable"
    assert skill_body =~ "HITL"
    assert skill_body =~ "AFK"
    assert skill_body =~ "real dependencies"
    assert skill_body =~ "Do not close or modify any parent issue"

    assert skill_body =~ "Octo/Symphony"
    assert skill_body =~ "Linear workflow state"
    assert skill_body =~ "repository metadata"
    assert skill_body =~ "labels"
    assert skill_body =~ "sortOrder"
    assert skill_body =~ "parent/child"
    assert skill_body =~ "handoffs"
    assert skill_body =~ "Human Escalation"
    assert skill_body =~ "invoking workflow"

    refute skill_body =~ "/setup-matt-pocock-skills"
    refute skill_body =~ "triage label"
    refute skill_body =~ "GitHub"

    assert source_body =~ "mattpocock/skills@733d312884b3878a9a9cff693c5886943753a741"
    assert source_body =~ "skills/engineering/to-issues/SKILL.md"
    assert source_body =~ "Upstream directory contents at that revision"
    assert source_body =~ "SKILL.md"
    assert source_body =~ "SOURCE.md"
  end

  test "localized skill guidance preserves Octo workflow boundaries and usage conditions" do
    for skill <- @localized_skills do
      body = File.read!(Path.join([skills_dir(), skill, "SKILL.md"]))

      assert body =~ "## Octo Implementer Use"
      assert body =~ "Octo workflow"
      assert body =~ "repository"
      assert body =~ "metadata"
      assert body =~ "issue"
      assert body =~ "branch"
      assert body =~ "workpad"
      assert body =~ "handoff"
      assert body =~ "validation"
      assert body =~ "Human Escalation"
    end

    tdd_body = File.read!(Path.join([skills_dir(), "tdd", "SKILL.md"]))
    assert tdd_body =~ "primary development loop"
    assert tdd_body =~ "Role workflows own the\ntrigger policy"

    assert File.read!(Path.join([skills_dir(), "frontend-design", "SKILL.md"])) =~ "Do not use this skill for backend-only changes"
  end

  test "non-implementer role manifests do not expose localized implementer skills by default" do
    role_manifests =
      role_skills_dir()
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.reject(&(&1 == "implementer.json"))

    for manifest_name <- role_manifests do
      manifest = manifest_name |> Path.rootname() |> read_manifest!()
      skill_names = manifest["skills"] |> Enum.map(& &1["name"]) |> MapSet.new()

      assert MapSet.disjoint?(skill_names, MapSet.new(@localized_skills))
      refute MapSet.member?(skill_names, "to-issues")
    end
  end

  test "to-issues markdown links are local and resolve" do
    files = Path.wildcard(Path.join([skills_dir(), "to-issues", "*.md"]))

    assert files != []

    for file <- files, target <- markdown_links(file) do
      assert local_link?(target), "#{file} must not link to external Markdown target #{target}"

      path = target |> strip_anchor() |> Path.expand(Path.dirname(file))
      assert File.exists?(path), "#{file} links to missing local file #{target}"
    end
  end

  test "localized markdown links resolve to committed local files" do
    markdown_files =
      [skills_dir(), role_skills_dir()]
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.md")))

    assert markdown_files != []

    for file <- markdown_files, target <- markdown_links(file), local_link?(target) do
      path = target |> strip_anchor() |> Path.expand(Path.dirname(file))
      assert File.exists?(path), "#{file} links to missing local file #{target}"
    end
  end

  test "repository quality assurance spec names the role skill acceptance contract" do
    spec = File.read!(Path.join(repo_root(), "spec/domains/repository-quality-assurance.md"))

    assert spec =~ "Shared Symphony role skills"
    assert spec =~ ".codex/role-skills/implementer.json"
    assert spec =~ ".codex/role-skills/qa.json"
    assert spec =~ "Browser Use CLI"
    assert spec =~ "browser-use input <index> \"text\""
    assert spec =~ "compact handoff `Work done` or approved Linear attachment metadata"
    refute spec =~ "compact handoff `Observability`"
    refute spec =~ "complete Human Review Packet section shape"
    assert spec =~ "implementer role"
    assert spec =~ "internal Markdown links resolve"
    assert spec =~ "Octo workflow authority"
    assert spec =~ "to-issues"
    assert spec =~ "tracer-bullet vertical slices"
    assert spec =~ "HITL/AFK"
    assert spec =~ "sortOrder"
  end

  defp committed_files(skill) do
    Path.join(skills_dir(), skill)
    |> File.ls!()
    |> Enum.sort()
  end

  defp read_manifest!(role) do
    [role_skills_dir(), "#{role}.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  defp markdown_links(file) do
    ~r/\[[^\]]+\]\(([^)]+)\)/
    |> Regex.scan(File.read!(file), capture: :all_but_first)
    |> List.flatten()
  end

  defp local_link?(target) do
    not String.starts_with?(target, "#") and
      not String.match?(target, ~r/^[a-z][a-z0-9+.-]*:/i)
  end

  defp strip_anchor(target) do
    target
    |> String.split("#", parts: 2)
    |> List.first()
  end

  defp skills_dir, do: Path.join(repo_root(), ".codex/skills")
  defp role_skills_dir, do: Path.join(repo_root(), ".codex/role-skills")
  defp repo_root, do: Path.expand("../../..", __DIR__)
end
