defmodule SymphonyElixir.ClaudeCodeAppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer

  import SymphonyElixir.ClaudeShimFixture

  @moduledoc """
  Deterministic contract/smoke checks for the first-party Claude Code shim.

  These tests drive a fake `claude` binary that replays recorded stream-json
  lines, so they assert the shim's protocol contract (flags, normalized events,
  failure classification, secret hygiene) without a live Claude subscription.
  """

  test "normalizes a successful turn into Symphony runtime events with usage" do
    ctx = setup_workspace("MT-CC-success")

    try do
      configure!(ctx, stream_success("claude-fable-5"),
        claude_code_model: "sonnet",
        claude_code_effort: "low",
        claude_code_no_thinking: false
      )

      {result, events, trace} =
        run_shim(ctx, "Reply with exactly: SHIMOK",
          labels: ["implementation-effort:minimal"],
          role: "implementer",
          issue_id: "issue-claude-env",
          run_id: "run-claude-env"
        )

      assert {:ok, turn} = result
      assert turn.session_id == "sess-success"
      assert turn.tool_failed == false
      # input_tokens + cache_read + cache_creation = 3 + 100 + 50; output = 6.
      assert turn.usage == %{"input_tokens" => 153, "output_tokens" => 6, "total_tokens" => 159}

      event_atoms = Enum.map(events, & &1.event)
      assert event_atoms == [:session_started, :text_delta, :notification, :turn_completed]

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.usage == %{"input_tokens" => 153, "output_tokens" => 6, "total_tokens" => 159}
      assert completed[:usage]

      # Direct legacy-adapter invocation resolves the Implementer Fable row and
      # launches it exactly (agent-runtime spec: no adapter-side substitution).
      # Production Implementer sessions use the Herdr launcher instead of this
      # adapter. The fake binary records argv after the shell strips the
      # shell-escaping the shim applies, so assert against the resolved
      # argument values.
      assert trace =~ "--print"
      assert trace =~ "--output-format stream-json"
      assert trace =~ "--verbose"
      assert trace =~ "--permission-mode bypassPermissions"
      assert trace =~ "--model claude-fable-5"
      assert trace =~ "--effort low"
      refute trace =~ "ENV_MAX_THINKING_TOKENS:0"
      assert trace =~ "ENV_SYMPHONY_ROLE_RUN_ID:run-claude-env"
      assert trace =~ "ENV_SYMPHONY_ROLE_ISSUE_ID:issue-claude-env"
      assert trace =~ "ENV_SYMPHONY_ROLE_ISSUE_IDENTIFIER:MT-CC"
      assert trace =~ "ENV_SYMPHONY_ROLE_NAME:implementer"
      {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(ctx.workspace)
      assert trace =~ "ENV_SYMPHONY_ROLE_WORKSPACE_PATH:#{canonical_workspace}"

      assert completed.implementation_effort == "minimal"
      assert completed.implementation_effort_source == "label"
      assert completed.claude_model == "claude-fable-5"
      assert completed.claude_effort == "low"
      assert completed.claude_no_thinking == false
      refute Map.has_key?(completed, :claude_preferred_model)
      refute Map.has_key?(completed, :claude_preferred_effort)
      refute Map.has_key?(completed, :claude_fallback_reason)
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "fails closed before accepting work from a model that differs from the resolved profile" do
    ctx = setup_workspace("MT-CC-model-mismatch")

    try do
      configure!(ctx, stream_model_mismatch(),
        claude_code_model: "claude-fable-5",
        claude_code_effort: "low",
        claude_code_no_thinking: false
      )

      {result, events, _trace} =
        run_shim(ctx, "do work",
          labels: ["implementation-effort:minimal"],
          role: "implementer"
        )

      assert {:error, {:claude_model_mismatched, %{requested_model: "claude-fable-5", observed_model: "claude-sonnet-5"}}} = result

      assert [%{event: :turn_failed} = failed] = events
      assert failed.reason == :claude_model_mismatched
      assert failed.requested_model == "claude-fable-5"
      assert failed.observed_model == "claude-sonnet-5"
      refute Enum.any?(events, &(&1.event in [:text_delta, :turn_completed]))
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "fails closed before completion when the provider omits observed-model evidence" do
    ctx = setup_workspace("MT-CC-model-missing")

    try do
      configure!(ctx, stream_model_missing_success(),
        claude_code_model: "claude-fable-5",
        claude_code_effort: "low",
        claude_code_no_thinking: false
      )

      {result, events, _trace} =
        run_shim(ctx, "do work",
          labels: ["implementation-effort:minimal"],
          role: "implementer"
        )

      assert {:error, {:claude_model_missing, %{requested_model: "claude-fable-5", observed_model: nil}}} = result

      assert Enum.any?(events, &(&1.event == :session_started))
      assert Enum.any?(events, &(&1.event == :text_delta))
      assert Enum.any?(events, &(&1.event == :turn_failed))
      refute Enum.any?(events, &(&1.event == :turn_completed))
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "fails closed immediately when observed-model evidence is malformed" do
    ctx = setup_workspace("MT-CC-model-malformed")

    try do
      configure!(ctx, stream_model_malformed(),
        claude_code_model: "claude-fable-5",
        claude_code_effort: "low",
        claude_code_no_thinking: false
      )

      {result, events, _trace} =
        run_shim(ctx, "do work",
          labels: ["implementation-effort:minimal"],
          role: "implementer"
        )

      assert {:error, {:claude_model_malformed, %{requested_model: "claude-fable-5"}}} = result
      assert [%{event: :turn_failed, reason: :claude_model_malformed}] = events
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "re-attests the observed model on continuation turns before accepting completion" do
    ctx = setup_workspace("MT-CC-model-continuation")

    try do
      configure!(ctx, stream_success(), claude_code_model: "opus")

      issue = %SymphonyElixir.Linear.Issue{
        id: "issue-model-continuation",
        identifier: "MT-CC-model-continuation",
        repository: "EmberAGI/scaling-octo-engine",
        repository_source: "linear_label",
        title: "Attest continuation model",
        state: "Agent Review",
        labels: ["implementation-effort:moderate"]
      }

      assert {:ok, session} = AgentRuntime.start_session(ctx.workspace, issue: issue, role: "reviewer")
      assert {:ok, {continued, first}} = AgentRuntime.run_turn(session, "first turn", issue, [])
      assert first.session_id == "sess-success"
      assert continued.claude_session_id == "sess-success"

      assert {:ok, {_continued_again, second}} =
               AgentRuntime.run_turn(continued, "continuation turn", issue, [])

      assert second.session_id == "sess-success"

      trace = File.read!(ctx.trace_file)
      assert length(Regex.scan(~r/^ARGV:/m, trace)) == 2
      assert trace =~ "--resume sess-success"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "AgentRuntime projects one registered contract to every non-Implementer Claude role" do
    ctx = setup_workspace("MT-CC-skill-contract")
    package_root = Path.join(ctx.test_root, "linear-skill")
    runtime_input = Path.join(ctx.test_root, "uv.lock")
    executable = Path.join(ctx.test_root, "uv")

    try do
      File.mkdir_p!(package_root)
      File.write!(runtime_input, "locked")
      File.write!(executable, "#!/bin/sh\nexit 0\n")
      File.chmod!(executable, 0o755)
      configure!(ctx, stream_success(), claude_code_model: "sonnet")

      issue = %SymphonyElixir.Linear.Issue{
        id: "issue-agent-runtime-claude-skills",
        identifier: "MT-CC-skill-contract",
        repository: "EmberAGI/scaling-octo-engine",
        repository_source: "linear_label",
        title: "Project registered skills",
        state: "In Progress",
        labels: ["implementation-effort:moderate"]
      }

      entry = %{
        skill: "linear",
        package_root: package_root,
        runtime_inputs: [runtime_input],
        tool_executables: [executable]
      }

      for role <- ["reviewer", "qa", "landing", "backlog-processor"] do
        assert {:ok, session} =
                 AgentRuntime.start_session(ctx.workspace,
                   issue: issue,
                   role: role,
                   skill_execution_contracts: [entry],
                   orchestration_root: ctx.test_root
                 )

        assert {:ok, {next_session, turn}} =
                 AgentRuntime.run_turn(session, "Run the registered skill", issue, [])

        assert turn.session_id == "sess-success"
        assert :ok = AgentRuntime.stop_session(next_session)
      end

      trace = File.read!(ctx.trace_file)

      assert length(Regex.scan(~r/^ARGV:/m, trace)) == 4
      assert length(Regex.scan(~r/^ENV_SYMPHONY_SKILL_EXECUTION_CONTRACTS:/m, trace)) == 4
      assert trace =~ "--add-dir #{package_root} --"
      assert trace =~ "ENV_SYMPHONY_SKILL_EXECUTION_CONTRACTS:"
      assert trace =~ package_root
      assert trace =~ runtime_input
      assert trace =~ executable
      refute trace =~ "--add-dir #{ctx.test_root} --"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "does not classify already-normalized synthetic families as provider auth at the adapter boundary" do
    ctx = setup_workspace("MT-CC-synthetic-family")

    try do
      configure!(ctx, stream_synthetic_normalized_family_failure(), [])

      {result, events, _trace} = run_shim(ctx, "Replay synthetic normalized family")

      assert {:error, {:turn_failed, %{subtype: "provider_authentication_or_revocation", api_error_status: nil}}} = result
      assert Enum.any?(events, &(&1.event == :turn_failed))
      refute match?({:error, {:auth_failed, _details}}, result)
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "adapter-boundary runtime result shapes classify as malformed and unsupported families" do
    cases = [
      {"unsupported_app_server_contract", :unsupported_app_server_contract},
      {"malformed_provider_event_schema", :malformed_provider_event_schema}
    ]

    for {subtype, family} <- cases do
      ctx = setup_workspace("MT-CC-#{subtype}")

      try do
        configure!(ctx, stream_irrecoverable_runtime_result(subtype), claude_code_model: "sonnet")

        {result, events, _trace} = run_shim(ctx, "Replay runtime protocol failure")

        assert {:error, {:turn_failed, details}} = result
        assert details.subtype == subtype
        assert Enum.any?(events, &(&1.event == :turn_failed))

        assert {:irrecoverable, failure} =
                 AgentRuntime.classify_failure(result |> elem(1), %{
                   issue_id: "issue-adapter-#{subtype}",
                   workspace_path: ctx.workspace,
                   role: "implementer",
                   provider: :claude_code
                 })

        assert failure.family == family
        refute failure.retry_reason =~ "adapter-secret"
        refute failure.retry_reason =~ "token="
      after
        File.rm_rf(ctx.test_root)
      end
    end
  end

  test "fails closed with an operator-visible error on auth failure" do
    ctx = setup_workspace("MT-CC-auth")

    try do
      configure!(ctx, stream_auth_failure(), claude_code_model: "sonnet")

      {result, events, _trace} = run_shim(ctx, "do work")

      assert {:error, {:auth_failed, %{api_error_status: 401}}} = result

      failed = Enum.find(events, &(&1.event == :turn_failed))
      assert failed.reason == :auth_failed
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "redacts auth failure provider payloads from normalized status events" do
    ctx = setup_workspace("MT-CC-auth-redaction")

    try do
      configure!(ctx, stream_auth_failure_with_provider_payload(), claude_code_model: "sonnet")

      {result, events, _trace} = run_shim(ctx, "do work")

      assert {:error, {:auth_failed, %{api_error_status: 403, subtype: "login_required"}}} = result

      failed = Enum.find(events, &(&1.event == :turn_failed))
      assert failed.reason == :auth_failed
      assert failed.api_error_status == 403
      assert failed.subtype == "login_required"
      refute inspect(failed) =~ "raw-secret-token"
      refute inspect(failed) =~ "raw-oauth-token"
      refute inspect(failed) =~ "Bearer"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "classifies Claude internal max-turns as input-required rather than success" do
    ctx = setup_workspace("MT-CC-max")

    try do
      configure!(ctx, stream_max_turns(), claude_code_model: "sonnet")

      {result, events, _trace} = run_shim(ctx, "do work")

      assert {:error, {:turn_input_required, %{subtype: "error_max_turns"}}} = result
      assert Enum.any?(events, &(&1.event == :turn_input_required))
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "surfaces a tool failure while still completing the turn" do
    ctx = setup_workspace("MT-CC-tool")

    try do
      configure!(ctx, stream_tool_failure(), claude_code_model: "sonnet")

      {result, events, _trace} = run_shim(ctx, "do work")

      assert {:ok, turn} = result
      assert turn.tool_failed == true
      assert Enum.any?(events, &(&1.event == :tool_failed))

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.tool_failed == true
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "redacts credential-bearing fields from emitted events" do
    ctx = setup_workspace("MT-CC-secret")

    leaky_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-secret","model":"claude-opus-4-8","oauth_token":"super-secret-value"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"ok","session_id":"sess-secret","usage":{"input_tokens":1,"output_tokens":1}})
    ]

    try do
      configure!(ctx, leaky_stream, claude_code_model: "sonnet")

      {result, events, _trace} = run_shim(ctx, "do work")

      assert {:ok, _turn} = result

      started = Enum.find(events, &(&1.event == :session_started))
      refute inspect(started) =~ "super-secret-value"
      assert get_in(started, [:payload, "oauth_token"]) == "[REDACTED]"
      assert started.raw == "[REDACTED]"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "rejects a workspace outside the configured workspace root" do
    ctx = setup_workspace("MT-CC-guard")

    try do
      configure!(ctx, stream_success(), claude_code_model: "sonnet")

      outside = Path.join(ctx.test_root, "outside")
      File.mkdir_p!(outside)

      issue = %{id: "guard", identifier: "MT-CC", title: "guard"}

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
               ClaudeAppServer.run(outside, "do work", issue)
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "defaults the runtime provider to codex when agent_runtime is unset" do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert SymphonyElixir.AgentRuntime.provider() == :codex
    assert SymphonyElixir.AgentRuntime.adapter() == SymphonyElixir.Codex.AppServer
  end

  test "selects the Claude Code adapter when configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude"
    )

    assert SymphonyElixir.AgentRuntime.provider() == :claude_code
    assert SymphonyElixir.AgentRuntime.adapter() == SymphonyElixir.ClaudeCode.AppServer
  end

  test "runtime participant provider environment overrides workflow selection" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "codex"
    )

    previous_orchestrator = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "codex")

    try do
      assert AgentRuntime.provider() == :claude_code
      assert AgentRuntime.worker_provider() == :codex
      assert AgentRuntime.adapter() == SymphonyElixir.ClaudeCode.AppServer
    after
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_orchestrator)
      restore_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker)
    end
  end

  test "config validation fails closed on an unsupported effort level" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_effort: "ludicrous"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "effort"
  end

  test "config validation fails closed when disabling thinking on a model that cannot" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "claude-fable-5",
      claude_code_no_thinking: true
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "thinking"
  end

  test "config validation rejects an unsupported runtime provider" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "pi"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "provider"
  end

  test "config validation fails closed on the spec's Sonnet xhigh example" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "sonnet",
      claude_code_effort: "xhigh"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "effort xhigh is not supported for model sonnet"
  end

  test "config validation fails closed on a full Sonnet model id with xhigh effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "claude-sonnet-4-6",
      claude_code_effort: "xhigh"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "effort xhigh is not supported"
  end

  test "config validation fails closed on max effort for an unsupported model" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "claude-opus-4-5",
      claude_code_effort: "max"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "effort max is not supported"
  end

  test "config validation fails closed on a restricted effort when the model is unset" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_effort: "xhigh"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "effort xhigh is not supported for model (unset)"
  end

  test "config validation fails closed on an unverifiable model with a restricted effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "some-future-model",
      claude_code_effort: "xhigh"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "effort xhigh is not supported"
  end

  test "config validation accepts xhigh effort on a supported Opus model alias" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "opus",
      claude_code_effort: "xhigh"
    )

    assert :ok = Config.validate!()
  end

  test "config validation accepts xhigh effort on a full supported Opus model id" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "claude-opus-4-7",
      claude_code_effort: "xhigh"
    )

    assert :ok = Config.validate!()
  end

  test "config validation accepts max effort on Sonnet 4.6" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "claude-sonnet-4-6",
      claude_code_effort: "max"
    )

    assert :ok = Config.validate!()
  end

  test "config validation accepts a provider-prefixed supported model with xhigh effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "us.anthropic.claude-opus-4-8",
      claude_code_effort: "xhigh"
    )

    assert :ok = Config.validate!()
  end

  test "config validation fails closed on a blank model with a restricted effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "   ",
      claude_code_effort: "max"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "effort max is not supported"
  end

  test "config validation fails closed on a major-only model id with a restricted effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "claude-opus-4",
      claude_code_effort: "max"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "effort max is not supported"
  end

  test "config validation accepts unrestricted effort levels on any model" do
    for effort <- ["low", "medium", "high"] do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
        agent_runtime_provider: "claude_code",
        claude_code_command: "claude",
        claude_code_model: "claude-sonnet-4-6",
        claude_code_effort: effort
      )

      assert :ok = Config.validate!(), "expected effort #{effort} to be accepted"
    end
  end
end
