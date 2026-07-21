defmodule SymphonyElixir.SkillExecutionContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentRuntime, ImplementerDelegation, SkillExecutionContract}
  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer

  setup do
    root = Path.join(System.tmp_dir!(), "skill-contract-#{System.unique_integer([:positive])}")
    package_root = Path.join([root, ".agents", "skills", "linear"])
    runtime_input = Path.join(root, "uv.lock")
    executable = Path.join(root, "uv")
    workspace = Path.join(root, "product-workspace")

    File.mkdir_p!(package_root)
    File.mkdir_p!(workspace)
    File.write!(runtime_input, "locked")
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(package_root, "SKILL.md"), "MUST_NOT_PRELOAD")
    File.chmod!(executable, 0o755)

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      workspace: workspace,
      package_root: package_root,
      runtime_input: runtime_input,
      executable: executable
    }
  end

  test "resolves one registered skill into canonical exact runtime resources", context do
    entry = entry(context)

    assert {:ok, [contract]} =
             SkillExecutionContract.resolve([entry], orchestration_root: context.root)

    assert contract.skill == "linear"
    assert contract.package_root == context.package_root
    assert contract.runtime_inputs == [context.runtime_input]
    assert contract.tool_executables == [context.executable]

    assert {:ok, []} = SkillExecutionContract.resolve([], worker_host: "worker-a")
  end

  test "fails closed with redacted reasons for invalid or inaccessible resources", context do
    valid = entry(context)

    assertions = [
      {Map.delete(valid, "package_root"), [], :missing},
      {%{valid | "package_root" => "relative/linear"}, [], :not_absolute},
      {%{valid | "package_root" => Path.join(context.root, "missing")}, [], :missing},
      {%{valid | "package_root" => context.root}, [orchestration_root: context.root], :broad_root}
    ]

    Enum.each(assertions, fn {invalid, opts, reason} ->
      assert {:error, {:invalid_skill_execution_contract, details}} =
               SkillExecutionContract.resolve([invalid], opts)

      assert details.reason == reason
      assert details.skill in ["linear", "unknown"]
      refute Map.has_key?(details, :path)
    end)

    File.chmod!(context.runtime_input, 0o000)
    assert_error_reason(valid, :unreadable)
    File.chmod!(context.runtime_input, 0o644)

    File.chmod!(context.executable, 0o644)
    assert_error_reason(valid, :non_executable)
    File.chmod!(context.executable, 0o755)

    escaped = Path.join(context.root, "escaped-linear")
    File.ln_s!(context.package_root, escaped)
    assert_error_reason(%{valid | "package_root" => escaped}, :symlink_escape)

    assert {:error, {:invalid_skill_execution_contract, %{reason: :denied}}} =
             SkillExecutionContract.resolve([valid], selected_workspace: context.root)

    conflicting = %{valid | "runtime_inputs" => [context.executable]}

    assert {:error, {:invalid_skill_execution_contract, %{reason: :conflicting_access}}} =
             SkillExecutionContract.resolve([conflicting])

    assert {:error, {:invalid_skill_execution_contract, %{reason: :conflict}}} =
             SkillExecutionContract.resolve([valid, %{valid | "runtime_inputs" => []}])

    assert {:ok, [_deduplicated]} = SkillExecutionContract.resolve([valid, valid])

    second = %{
      valid
      | "skill" => "linear-helper",
        "package_root" => Path.dirname(context.package_root),
        "runtime_inputs" => [context.executable],
        "tool_executables" => []
    }

    assert {:error, {:invalid_skill_execution_contract, %{reason: :conflicting_access}}} =
             SkillExecutionContract.resolve([valid, second])

    assert {:error, {:invalid_skill_execution_contract, %{reason: :remote_unmaterialized}}} =
             SkillExecutionContract.resolve([valid],
               worker_host: "worker-a",
               remote_validator: fn _host, _resources -> {:error, :unmaterialized} end
             )

    error =
      SkillExecutionContract.resolve(
        [%{valid | "package_root" => "/runtime/provider-auth/token-secret"}],
        orchestration_root: context.root
      )

    refute inspect(error) =~ "provider-auth"
    refute inspect(error) =~ "token-secret"
  end

  test "AgentRuntime resolves the same contract for every managed role and provider", context do
    roles = ["implementer", "reviewer", "qa", "landing", "backlog-processor"]
    providers = [:codex, :claude_code]

    for role <- roles, provider <- providers do
      assert {:ok, [contract]} =
               AgentRuntime.resolve_skill_execution_contracts(
                 context.workspace,
                 skill_execution_contracts: [entry(context)],
                 role: role,
                 provider: provider,
                 orchestration_root: context.root
               )

      assert contract.skill == "linear"
      assert contract.package_root == context.package_root
      assert contract.runtime_inputs == [context.runtime_input]
      assert contract.tool_executables == [context.executable]

      expected_adapter =
        if role == "implementer",
          do: ImplementerDelegation,
          else: AgentRuntime.adapter(provider)

      assert AgentRuntime.session_adapter(provider, role) == expected_adapter
    end
  end

  test "thin provider and delegation Adapters project only registered resources", context do
    assert {:ok, contracts} =
             SkillExecutionContract.resolve([entry(context)], orchestration_root: context.root)

    codex = CodexAppServer.skill_execution_projection_for_test(contracts)
    assert codex.read_paths == [context.package_root, context.runtime_input, context.executable]
    refute context.root in codex.read_paths
    assert codex.permission_config =~ "#{inspect(context.package_root)}=\"read\""
    refute codex.permission_config =~ "#{inspect(context.root)}=\"read\""

    assert codex.environment["SYMPHONY_SKILL_EXECUTION_CONTRACTS"] ==
             SkillExecutionContract.encode!(contracts)

    assert {:ok, codex_command} =
             CodexAppServer.project_skill_permissions_for_test(
               "codex --config check_for_update_on_startup=false app-server",
               contracts
             )

    assert codex_command =~ "default_permissions=\"symphony_skill_runtime\""
    assert codex_command =~ "permissions.symphony_skill_runtime.network={enabled=true}"
    assert codex_command =~ inspect(context.package_root)
    refute codex_command =~ "#{inspect(context.root)}=\"read\""

    claude = ClaudeAppServer.skill_execution_projection_for_test(contracts)
    assert claude.args == ["--add-dir", context.package_root]
    assert {:ok, [encoded]} = Jason.decode(claude.environment["SYMPHONY_SKILL_EXECUTION_CONTRACTS"])
    assert encoded["package_root"] == context.package_root
    assert encoded["runtime_inputs"] == [context.runtime_input]
    assert encoded["tool_executables"] == [context.executable]

    assert ImplementerDelegation.skill_execution_projection_for_test("codex", contracts) == codex
    assert ImplementerDelegation.skill_execution_projection_for_test("claude_code", contracts) == claude
    refute inspect(codex) =~ "MUST_NOT_PRELOAD"
    refute inspect(claude) =~ "MUST_NOT_PRELOAD"
  end

  defp entry(context) do
    %{
      "skill" => "linear",
      "package_root" => context.package_root,
      "runtime_inputs" => [context.runtime_input],
      "tool_executables" => [context.executable]
    }
  end

  defp assert_error_reason(entry, reason) do
    assert {:error, {:invalid_skill_execution_contract, %{reason: ^reason}}} =
             SkillExecutionContract.resolve([entry])
  end
end
