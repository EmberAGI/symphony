defmodule SymphonyElixir.AgentProfileCatalogDocumentParsingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentProfileCatalog

  setup do
    root = Path.join(System.tmp_dir!(), "agent-profile-catalog-doc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "load/1 rejects a non-binary root via the catch-all clause" do
    assert {:error, {:invalid_agent_profile_root, 123}} = AgentProfileCatalog.load(123)
  end

  test "resolve/5 rejects a non-binary name via the catch-all clause" do
    assert {:error, {:invalid_agent_profile_provider, "codex"}} =
             AgentProfileCatalog.resolve(%{}, :not_a_string_name, "codex", nil, "default")
  end

  test "load/1 rejects a profile document missing the TOML frontmatter delimiters", %{root: root} do
    path = Path.join(root, "broken.agent.md")
    File.write!(path, "just a plain markdown file with no frontmatter at all\n")

    assert {:error, {:invalid_agent_profile, ^path, :missing_toml_frontmatter}} = AgentProfileCatalog.load(root)
  end

  test "load/1 rejects malformed TOML syntax inside the frontmatter", %{root: root} do
    path = Path.join(root, "broken.agent.md")

    File.write!(path, """
    +++
    name = [1, 2
    +++

    Body.
    """)

    assert {:error, {:invalid_agent_profile, ^path, {:invalid_toml_frontmatter, _reason}}} =
             AgentProfileCatalog.load(root)
  end

  test "load/1 rejects an unsupported schema_version", %{root: root} do
    path = write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")
    body = File.read!(path) |> String.replace("schema_version = 1", "schema_version = 2")
    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:unsupported_schema_version, 2}}} =
             AgentProfileCatalog.load(root)
  end

  test "load/1 rejects capabilities that are not a table", %{root: root} do
    path = Path.join(root, "not-map-capabilities.agent.md")

    File.write!(path, """
    +++
    schema_version = 1
    name = "not-map-capabilities"
    kind = "worker"
    role = "implementer"
    capabilities = "oops"

    [providers.codex]
    default_tier = "moderate"
    extreme = { model = "m", reasoning_effort = "xhigh" }
    high = { model = "m", reasoning_effort = "high" }
    moderate = { model = "m", reasoning_effort = "medium" }
    low = { model = "m", reasoning_effort = "low" }
    minimal = { model = "m", reasoning_effort = "none" }

    [providers.claude_code]
    default_tier = "moderate"
    extreme = { model = "m", reasoning_effort = "xhigh" }
    high = { model = "m", reasoning_effort = "high" }
    moderate = { model = "m", reasoning_effort = "medium" }
    low = { model = "m", reasoning_effort = "low" }
    minimal = { model = "m", reasoning_effort = "low" }
    +++

    # not-map-capabilities

    Reusable body text.
    """)

    assert {:error, {:invalid_agent_profile, ^path, :invalid_capabilities}} = AgentProfileCatalog.load(root)
  end

  test "load/1 rejects a non-delegating profile with a positive delegation depth", %{root: root} do
    path = write_profile!(root, "implementer-worker", "worker", "implementer", "gpt-5.6-luna", "claude-sonnet-5")
    body = File.read!(path) |> String.replace("max_delegation_depth = 0", "max_delegation_depth = 2")
    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:non_delegating_profile_has_depth, 2}}} =
             AgentProfileCatalog.load(root)
  end

  test "load/1 rejects a delegating profile with a zero delegation depth", %{root: root} do
    path =
      write_profile!(root, "implementer-orchestrator", "orchestrator", "implementer", "gpt-5.6-sol", "claude-fable-5")

    body = File.read!(path) |> String.replace("max_delegation_depth = 1", "max_delegation_depth = 0")
    File.write!(path, body)

    assert {:error, {:invalid_agent_profile, ^path, {:delegating_profile_requires_depth, 0}}} =
             AgentProfileCatalog.load(root)
  end

  test "load/1 rejects providers that are not a table", %{root: root} do
    path = Path.join(root, "not-map-providers.agent.md")

    File.write!(path, """
    +++
    schema_version = 1
    name = "not-map-providers"
    kind = "worker"
    role = "implementer"
    providers = "oops"

    [capabilities]
    can_delegate = false
    max_delegation_depth = 0
    owns_issue_lifecycle = false
    owns_final_validation = false
    owns_handoff = false
    +++

    # not-map-providers

    Reusable body text.
    """)

    assert {:error, {:invalid_agent_profile, ^path, :invalid_providers}} = AgentProfileCatalog.load(root)
  end

  test "load/1 rejects a provider config that is not a table", %{root: root} do
    path = Path.join(root, "not-map-provider-config.agent.md")

    File.write!(path, """
    +++
    schema_version = 1
    name = "not-map-provider-config"
    kind = "worker"
    role = "implementer"

    [capabilities]
    can_delegate = false
    max_delegation_depth = 0
    owns_issue_lifecycle = false
    owns_final_validation = false
    owns_handoff = false

    [providers]
    codex = "oops"

    [providers.claude_code]
    default_tier = "moderate"
    extreme = { model = "m", reasoning_effort = "xhigh" }
    high = { model = "m", reasoning_effort = "high" }
    moderate = { model = "m", reasoning_effort = "medium" }
    low = { model = "m", reasoning_effort = "low" }
    minimal = { model = "m", reasoning_effort = "low" }
    +++

    # not-map-provider-config

    Reusable body text.
    """)

    assert {:error, {:invalid_agent_profile, ^path, {:invalid_provider, "codex"}}} = AgentProfileCatalog.load(root)
  end

  test "load/1 rejects a provider tier cell that is not a table", %{root: root} do
    path = Path.join(root, "not-map-cell.agent.md")

    File.write!(path, """
    +++
    schema_version = 1
    name = "not-map-cell"
    kind = "worker"
    role = "implementer"

    [capabilities]
    can_delegate = false
    max_delegation_depth = 0
    owns_issue_lifecycle = false
    owns_final_validation = false
    owns_handoff = false

    [providers.codex]
    default_tier = "moderate"
    extreme = { model = "m", reasoning_effort = "xhigh" }
    high = { model = "m", reasoning_effort = "high" }
    moderate = "oops"
    low = { model = "m", reasoning_effort = "low" }
    minimal = { model = "m", reasoning_effort = "none" }

    [providers.claude_code]
    default_tier = "moderate"
    extreme = { model = "m", reasoning_effort = "xhigh" }
    high = { model = "m", reasoning_effort = "high" }
    moderate = { model = "m", reasoning_effort = "medium" }
    low = { model = "m", reasoning_effort = "low" }
    minimal = { model = "m", reasoning_effort = "low" }
    +++

    # not-map-cell

    Reusable body text.
    """)

    assert {:error, {:invalid_agent_profile, ^path, {:invalid_provider_tier, "codex", "moderate"}}} =
             AgentProfileCatalog.load(root)
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
