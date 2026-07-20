defmodule SymphonyElixir.RoleSkillSourceTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @skill_source_dir Path.join([@repo_root, ".codex", "skills"])
  @role_manifest_dir Path.join([@repo_root, ".codex", "role-skills"])

  test "Symphony does not contain an Octo role skill source inventory" do
    tracked_files = git!(~w(ls-files))

    refute Enum.any?(tracked_files, &under?(&1, @skill_source_dir))
    refute Enum.any?(tracked_files, &under?(&1, @role_manifest_dir))
  end

  test "active Symphony consumers do not resolve repository-local Octo role skills" do
    forbidden_references = [
      Path.join([".codex", "skills"]),
      Path.join([".codex", "role-skills"])
    ]

    test_paths =
      ["*.ex", "*.exs"]
      |> Enum.flat_map(&Path.wildcard(Path.join([@repo_root, "elixir/test/**", &1])))

    consumer_paths =
      [
        Path.join(@repo_root, "elixir/WORKFLOW.md"),
        Path.join(@repo_root, "docs/specs/domains/agent-runtime.md")
      ] ++ test_paths

    for path <- consumer_paths,
        reference <- forbidden_references do
      refute File.read!(path) =~ reference,
             "#{Path.relative_to(path, @repo_root)} must not consume #{reference}"
    end
  end

  test "repository QA assigns Octo role skill ownership to scaling-octo-engine" do
    spec = File.read!(Path.join(@repo_root, "docs/specs/domains/repository-quality-assurance.md"))

    assert spec =~ "## Shared Role Skill Sources"
    assert spec =~ "EmberAGI/scaling-octo-engine"
    assert spec =~ "Symphony MUST NOT own or expose Octo role skill packages"

    refute spec =~ "Shared Symphony role skills"
    refute spec =~ "## Shared Architecture Skill Source"
    refute spec =~ "## EMB-187 Agent QA Browser Use"
    refute spec =~ "## EMB-186 Implementer Skill Pack"
  end

  defp git!(args) do
    {output, 0} = System.cmd("git", args, cd: @repo_root)
    String.split(output, "\n", trim: true)
  end

  defp under?(path, directory) do
    String.starts_with?(Path.expand(path, @repo_root), directory <> "/")
  end
end
