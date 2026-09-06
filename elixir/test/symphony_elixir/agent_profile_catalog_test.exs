defmodule SymphonyElixir.AgentProfileCatalogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentProfileCatalog

  setup do
    root = Path.join(System.tmp_dir!(), "agent-profile-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "loads a TOML-frontmatter Markdown profile and resolves its complete launch contract", %{root: root} do
    write_profile!(root, "implementer-orchestrator", "orchestrator", "implementer", "gpt-5.6-sol", "claude-fable-5")

    assert {:ok, catalog} = AgentProfileCatalog.load(root)

    assert {:ok, profile} =
             AgentProfileCatalog.resolve(catalog, "implementer-orchestrator", "codex", nil, "default")

    assert profile.name == "implementer-orchestrator"
    assert profile.kind == "orchestrator"
    assert profile.role == "implementer"
    assert profile.effort == "moderate"
    assert profile.model == "gpt-5.6-sol"
    assert profile.reasoning_effort == "medium"
    assert profile.source == "default"
    assert profile.profile_source == Path.join(root, "implementer-orchestrator.agent.md")
    assert profile.instructions =~ "Reusable implementer-orchestrator workflow."
    assert profile.capabilities.can_delegate
    assert profile.capabilities.max_delegation_depth == 1
  end

  test "loads Fable 5.1 xhigh without blocking Codex profile resolution", %{root: root} do
    write_profile!(root, "implementer-orchestrator", "orchestrator", "implementer", "gpt-6", "claude-fable-5.1")

    assert {:ok, catalog} = AgentProfileCatalog.load(root)
    assert {:ok, claude} = AgentProfileCatalog.resolve(catalog, "implementer-orchestrator", "claude_code", "extreme", "default")
    assert claude.model == "claude-fable-5.1"
    assert claude.reasoning_effort == "xhigh"
    assert {:ok, codex} = AgentProfileCatalog.resolve(catalog, "implementer-orchestrator", "codex", nil, "default")
    assert codex.model == "gpt-6"
    assert codex.reasoning_effort == "medium"
  end

  test "loads Fable 5.1 max while preserving Fable 5 max support", %{root: root} do
    for {name, model} <- [{"new-fable", "claude-fable-5.1"}, {"old-fable", "claude-fable-5"}] do
      path = write_profile!(root, name, "orchestrator", "implementer", "gpt-6", model)
      File.write!(path, String.replace(File.read!(path), "model = \"#{model}\", reasoning_effort = \"xhigh\"", "model = \"#{model}\", reasoning_effort = \"max\""))
    end

    assert {:ok, catalog} = AgentProfileCatalog.load(root)
    assert {:ok, current} = AgentProfileCatalog.resolve(catalog, "new-fable", "claude_code", "extreme", "default")
    assert current.model == "claude-fable-5.1"
    assert current.reasoning_effort == "max"
    assert {:ok, previous} = AgentProfileCatalog.resolve(catalog, "old-fable", "claude_code", "extreme", "default")
    assert previous.model == "claude-fable-5"
    assert previous.reasoning_effort == "max"
  end

  test "every provider default tier is required to be moderate", %{root: root} do
    path = write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")
    body = File.read!(path) |> String.replace("default_tier = \"moderate\"", "default_tier = \"high\"", global: false)
    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:default_tier_must_be_moderate, "codex", "high"}}} =
             AgentProfileCatalog.load(root)
  end

  test "rejects unknown frontmatter keys and an empty reusable workflow", %{root: root} do
    path = write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")

    body = File.read!(path) |> String.replace("schema_version = 1", "schema_version = 1\nunknown = true")
    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:unknown_keys, ["unknown"]}}} = AgentProfileCatalog.load(root)

    File.write!(path, String.replace(body, "unknown = true", "") |> String.replace(~r/\n# Agent Profile.*\z/s, "\n"))

    assert {:error, {:invalid_agent_profile, ^path, :empty_instructions}} = AgentProfileCatalog.load(root)
  end

  test "rejects an empty catalog and worker lifecycle authority", %{root: root} do
    assert {:error, :empty_agent_profile_catalog} = AgentProfileCatalog.load(root)

    path =
      write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")

    body = File.read!(path) |> String.replace("owns_issue_lifecycle = false", "owns_issue_lifecycle = true")
    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, :worker_cannot_own_run_authority}} =
             AgentProfileCatalog.load(root)
  end

  test "rejects unsupported provider model and effort pairs", %{root: root} do
    path =
      write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")

    body = File.read!(path) |> String.replace("claude-sonnet-5\", reasoning_effort = \"xhigh", "claude-sonnet-4-6\", reasoning_effort = \"xhigh")
    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:unsupported_model_reasoning_effort, "claude_code", "extreme", "claude-sonnet-4-6", "xhigh"}}} =
             AgentProfileCatalog.load(root)
  end

  for effort <- ["xhigh", "max"] do
    test "rejects an unlisted Fable version at #{effort}", %{root: root} do
      effort = unquote(effort)
      path = write_profile!(root, "unknown-fable", "orchestrator", "implementer", "gpt-6", "claude-fable-5.2")
      File.write!(path, String.replace(File.read!(path), "model = \"claude-fable-5.2\", reasoning_effort = \"xhigh\"", "model = \"claude-fable-5.2\", reasoning_effort = \"#{effort}\""))

      assert {:error, {:invalid_agent_profile, ^path, {:unsupported_model_reasoning_effort, "claude_code", "extreme", "claude-fable-5.2", ^effort}}} =
               AgentProfileCatalog.load(root)
    end
  end

  defp write_profile!(root, name, kind, role, codex_model, claude_model) do
    path = Path.join(root, "#{name}.agent.md")

    File.write!(path, """
    +++
    schema_version = 1
    name = "#{name}"
    kind = "#{kind}"
    role = "#{role}"

    [capabilities]
    can_delegate = #{kind == "orchestrator"}
    max_delegation_depth = #{if(kind == "orchestrator", do: 1, else: 0)}
    owns_issue_lifecycle = #{kind == "orchestrator"}
    owns_final_validation = #{kind == "orchestrator"}
    owns_handoff = #{kind == "orchestrator"}

    [providers.codex]
    default_tier = "moderate"
    extreme = { model = "#{codex_model}", reasoning_effort = "xhigh" }
    high = { model = "#{codex_model}", reasoning_effort = "high" }
    moderate = { model = "#{codex_model}", reasoning_effort = "medium" }
    low = { model = "#{codex_model}", reasoning_effort = "low" }
    minimal = { model = "#{codex_model}", reasoning_effort = "none" }

    [providers.claude_code]
    default_tier = "moderate"
    extreme = { model = "#{claude_model}", reasoning_effort = "xhigh" }
    high = { model = "#{claude_model}", reasoning_effort = "high" }
    moderate = { model = "#{claude_model}", reasoning_effort = "medium" }
    low = { model = "#{claude_model}", reasoning_effort = "low" }
    minimal = { model = "#{claude_model}", reasoning_effort = "low" }
    +++

    # Agent Profile

    Reusable #{name} workflow.
    """)

    path
  end
end
