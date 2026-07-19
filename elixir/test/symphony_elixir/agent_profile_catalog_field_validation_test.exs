defmodule SymphonyElixir.AgentProfileCatalogFieldValidationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentProfileCatalog

  setup do
    root = Path.join(System.tmp_dir!(), "agent-profile-catalog-field-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "load/1 rejects an unsupported reasoning_effort for the provider", %{root: root} do
    path = write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")

    body =
      File.read!(path)
      |> String.replace(
        ~s(extreme = { model = "gpt-5.6-luna", reasoning_effort = "xhigh" }),
        ~s(extreme = { model = "gpt-5.6-luna", reasoning_effort = "ultra" })
      )

    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:unsupported_reasoning_effort, "codex", "extreme", "ultra"}}} =
             AgentProfileCatalog.load(root)
  end

  test "load/1 accepts the Claude Code max reasoning_effort for a supported model", %{root: root} do
    path = write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")

    body =
      File.read!(path)
      |> String.replace(
        ~s(extreme = { model = "claude-sonnet-5", reasoning_effort = "xhigh" }),
        ~s(extreme = { model = "claude-sonnet-5", reasoning_effort = "max" })
      )

    File.write!(path, body)

    assert {:ok, catalog} = AgentProfileCatalog.load(root)

    assert {:ok, profile} =
             AgentProfileCatalog.resolve(catalog, "implementer-worker", "claude_code", "extreme", "default")

    assert profile.reasoning_effort == "max"
  end

  test "load/1 rejects a non-boolean capability value", %{root: root} do
    path = write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")
    body = File.read!(path) |> String.replace("can_delegate = false", ~s(can_delegate = "false"))
    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:invalid_boolean, "can_delegate", "false"}}} =
             AgentProfileCatalog.load(root)
  end

  test "load/1 rejects a negative delegation depth", %{root: root} do
    path = write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")
    body = File.read!(path) |> String.replace("max_delegation_depth = 0", "max_delegation_depth = -1")
    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:invalid_nonnegative_integer, "max_delegation_depth", -1}}} =
             AgentProfileCatalog.load(root)
  end

  test "load/1 rejects a non-string model value", %{root: root} do
    path = write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")

    body =
      File.read!(path)
      |> String.replace(
        ~s(low = { model = "gpt-5.6-luna", reasoning_effort = "low" }),
        ~s(low = { model = 42, reasoning_effort = "low" })
      )

    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:invalid_string, "model", 42}}} = AgentProfileCatalog.load(root)
  end

  test "resolve/5 rejects a tier that is not one of the supported implementation efforts", %{root: root} do
    write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")
    assert {:ok, catalog} = AgentProfileCatalog.load(root)

    assert {:error, {:unsupported_implementation_effort, "bogus"}} =
             AgentProfileCatalog.resolve(catalog, "implementer-worker", "codex", "bogus", "default")
  end

  test "resolve/5 normalizes an atom provider", %{root: root} do
    write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")
    assert {:ok, catalog} = AgentProfileCatalog.load(root)

    assert {:ok, %{provider: "codex"}} =
             AgentProfileCatalog.resolve(catalog, "implementer-worker", :codex, nil, "default")
  end

  test "resolve/5 rejects a provider that is neither an atom nor a string", %{root: root} do
    write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")
    assert {:ok, catalog} = AgentProfileCatalog.load(root)

    assert {:error, {:unsupported_agent_profile_provider, 123}} =
             AgentProfileCatalog.resolve(catalog, "implementer-worker", 123, nil, "default")
  end

  test "resolve/5 rejects an unknown agent profile name", %{root: root} do
    write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")
    assert {:ok, catalog} = AgentProfileCatalog.load(root)

    assert {:error, {:unknown_agent_profile, "no-such-agent"}} =
             AgentProfileCatalog.resolve(catalog, "no-such-agent", "codex", nil, "default")
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
