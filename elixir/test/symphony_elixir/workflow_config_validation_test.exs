defmodule SymphonyElixir.WorkflowConfigValidationTest do
  use SymphonyElixir.TestSupport

  @valid_host_resources %{
    "schema_version" => 1,
    "role" => "implementer",
    "execution_generation" => "exec-20260906",
    "runtime_generation" => 7,
    "operations" => %{
      "symphony_runtime_verification" => %{
        "symphony_ref" => String.duplicate("a", 40),
        "tool_config" => "/opt/symphony/mise.toml",
        "tool_config_sha256" => String.duplicate("b", 64),
        "mise" => %{
          "executable" => "/opt/mise/bin/mise",
          "target" => "/opt/mise/versions/mise-2026.09",
          "sha256" => String.duplicate("c", 64)
        },
        "elixir" => %{
          "version" => "1.19.5-otp-28",
          "install_path" => "/opt/mise/installs/elixir/1.19.5-otp-28"
        },
        "erlang" => %{
          "version" => "28.5",
          "install_path" => "/opt/mise/installs/erlang/28.5"
        }
      },
      "host_dns" => %{"resolver_target" => "/opt/symphony/bin/resolve-host"}
    }
  }

  test "Config.settings/0 accepts a complete host resources declaration" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_runtime_host_resources: @valid_host_resources
    )

    assert {:ok, settings} = Config.settings()
    assert settings.agent_runtime.host_resources == @valid_host_resources
  end

  test "Config.settings/0 rejects malformed host resources at every nesting level" do
    operations = @valid_host_resources["operations"]
    verification = operations["symphony_runtime_verification"]
    mise = verification["mise"]
    elixir_install = verification["elixir"]
    erlang_install = verification["erlang"]
    dns = operations["host_dns"]

    replace_verification = fn value ->
      Map.put(
        @valid_host_resources,
        "operations",
        Map.put(operations, "symphony_runtime_verification", value)
      )
    end

    replace_mise = fn value ->
      replace_verification.(Map.put(verification, "mise", value))
    end

    replace_elixir = fn value ->
      replace_verification.(Map.put(verification, "elixir", value))
    end

    replace_erlang = fn value ->
      replace_verification.(Map.put(verification, "erlang", value))
    end

    replace_dns = fn value ->
      Map.put(@valid_host_resources, "operations", Map.put(operations, "host_dns", value))
    end

    invalid_cases = [
      {"wrong host_resources type", []},
      {"unknown host_resources field", Map.put(@valid_host_resources, "unexpected", true)},
      {"unknown null host_resources field", Map.put(@valid_host_resources, "unexpected", nil)},
      {"missing host_resources field", Map.delete(@valid_host_resources, "role")},
      {"wrong schema version type", Map.put(@valid_host_resources, "schema_version", "1")},
      {"blank role", Map.put(@valid_host_resources, "role", "  ")},
      {"blank execution generation", Map.put(@valid_host_resources, "execution_generation", "")},
      {"wrong runtime generation type", Map.put(@valid_host_resources, "runtime_generation", "7")},
      {"wrong operations type", Map.put(@valid_host_resources, "operations", [])},
      {"empty operations", Map.put(@valid_host_resources, "operations", %{})},
      {"unsupported operation", Map.put(@valid_host_resources, "operations", %{"unsupported" => %{}})},
      {"unknown runtime operation field", replace_verification.(Map.put(verification, "unexpected", true))},
      {"missing runtime operation field", replace_verification.(Map.delete(verification, "erlang"))},
      {"wrong runtime operation type", Map.put(@valid_host_resources, "operations", %{"symphony_runtime_verification" => []})},
      {"malformed symphony ref", replace_verification.(Map.put(verification, "symphony_ref", String.duplicate("a", 39)))},
      {"relative tool config", replace_verification.(Map.put(verification, "tool_config", "mise.toml"))},
      {"malformed tool config digest", replace_verification.(Map.put(verification, "tool_config_sha256", String.duplicate("b", 63)))},
      {"unknown mise field", replace_mise.(Map.put(mise, "unexpected", true))},
      {"wrong mise type", replace_verification.(Map.put(verification, "mise", []))},
      {"blank mise executable", replace_mise.(Map.put(mise, "executable", "  "))},
      {"relative mise target", replace_mise.(Map.put(mise, "target", "versions/mise"))},
      {"malformed mise digest", replace_mise.(Map.put(mise, "sha256", String.duplicate("c", 63)))},
      {"unknown elixir installation field", replace_elixir.(Map.put(elixir_install, "unexpected", true))},
      {"wrong elixir installation type", replace_verification.(Map.put(verification, "elixir", []))},
      {"missing elixir installation field", replace_elixir.(Map.delete(elixir_install, "version"))},
      {"blank erlang installation version", replace_erlang.(Map.put(erlang_install, "version", "  "))},
      {"unknown dns field", replace_dns.(Map.put(dns, "unexpected", true))},
      {"wrong dns operation type", replace_dns.([])},
      {"blank dns resolver target", replace_dns.(Map.put(dns, "resolver_target", ""))}
    ]

    Enum.each(invalid_cases, fn {label, host_resources} ->
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_runtime_host_resources: host_resources
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "agent_runtime.host_resources", "#{label}: #{message}"
    end)
  end

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20
    assert config.agent_runtime.host_resources == %{}

    write_workflow_file!(Workflow.workflow_file_path(), agent_runtime_host_resources: %{})
    assert {:ok, settings} = Config.settings()
    assert settings.agent_runtime.host_resources == %{}

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end
end
