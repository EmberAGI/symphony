defmodule SymphonyElixir.AgentRuntimeFailureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime

  @context %{
    issue_id: "issue-runtime-failure",
    workspace_path: "/tmp/symphony/EMB-1127",
    role: "implementer",
    provider: :claude_code
  }

  test "classifies deterministic irrecoverable runtime failure families with redacted summaries" do
    cases = [
      {:provider_authentication_or_revocation,
       {:auth_failed,
        %{
          provider: :claude_code,
          api_error_status: 403,
          subtype: "login_required",
          raw: "Bearer provider-token"
        }}},
      {:missing_required_runtime_configuration, {:missing_required_runtime_configuration, %{name: "agent_runtime.provider", value: "secret-token"}}},
      {:missing_required_tool_or_cli, {:missing_required_tool_or_cli, %{tool: "claude", message: "command not found token=tool-secret"}}},
      {:permission_denied, {:permission_denied, %{path: "/root/.claude.json", message: "Permission denied api_key=abc123"}}},
      {:invalid_workspace_or_runtime_protocol, {:invalid_workspace_or_runtime_protocol, %{message: "workspace escaped configured root"}}},
      {:unsupported_app_server_contract, {:unsupported_app_server_contract, %{method: "turn/start", message: "unsupported schema"}}},
      {:malformed_provider_event_schema, {:malformed_provider_event_schema, %{event: "result", message: "missing required session_id"}}},
      {:human_input_required,
       {:human_input_required,
        %{
          provider: :codex,
          source: "linear",
          mode: "form",
          purpose: "MCP server requested human input",
          raw: "Bearer provider-token"
        }}},
      {:repeated_identical_no_progress_failure, {:repeated_identical_no_progress_failure, %{subtype: "empty_turn_completed", summary: "same turn emitted no progress"}}}
    ]

    for {family, reason} <- cases do
      assert {:irrecoverable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.family == family
      assert failure.retryable? == false
      assert failure.summary =~ Atom.to_string(family)
      refute failure.summary =~ "provider-token"
      refute failure.summary =~ "tool-secret"
      refute failure.summary =~ "abc123"
      refute failure.summary =~ "Bearer"
      refute failure.summary =~ "api_key="
      refute failure.summary =~ "token="
    end
  end

  test "classifies supervised delegation outcomes into runtime failure families with redaction" do
    pane_secret = "PANE TRANSCRIPT token=pane-secret"
    good_checkpoint = {:ok, %{pane_tail: pane_secret, shutdown_reason: :blocked}}

    failed_checkpoint_details = %{
      reason: :pane_unreadable,
      shutdown_reason: :stale_working,
      destructive_shutdown_blocked: true
    }

    failed_checkpoint = {:error, {:implementer_checkpoint_failed, failed_checkpoint_details}}

    # Blocked → the existing human_input_required family, never ordinary retry.
    assert {:irrecoverable, blocked} =
             AgentRuntime.classify_failure(
               {:implementer_agent_blocked, %{agent_status: "blocked", checkpoint: good_checkpoint, recovery_history: []}},
               @context
             )

    assert blocked.family == :human_input_required
    assert blocked.retryable? == false
    refute blocked.summary =~ "pane-secret"
    refute blocked.summary =~ "PANE TRANSCRIPT"
    refute blocked.retry_reason =~ "pane-secret"

    # A bare blocked prompt/wait outcome from the transport is the same
    # human-decision family: it must never re-enter ordinary retry.
    assert {:irrecoverable, bare_blocked} =
             AgentRuntime.classify_failure({:herdr_agent_blocked, "implementer_orchestrator"}, @context)

    assert bare_blocked.family == :human_input_required
    assert bare_blocked.retryable? == false

    # Direct checkpoint failure → irrecoverable, ordinary retry prevented.
    direct_checkpoint_failure =
      {:implementer_checkpoint_failed, %{failed_checkpoint_details | shutdown_reason: :hard_budget_exhausted}}

    assert {:irrecoverable, direct} = AgentRuntime.classify_failure(direct_checkpoint_failure, @context)

    assert direct.family == :invalid_workspace_or_runtime_protocol
    assert direct.retryable? == false

    # Checkpoint failure nested inside a supervised outcome → same irrecoverable family.
    assert {:irrecoverable, nested} =
             AgentRuntime.classify_failure(
               {:implementer_agent_stalled, %{checkpoint: failed_checkpoint, recovery_history: []}},
               @context
             )

    assert nested.family == :invalid_workspace_or_runtime_protocol

    assert {:irrecoverable, nested_triple} =
             AgentRuntime.classify_failure(
               {:herdr_agent_closed, "implementer_orchestrator", %{checkpoint: failed_checkpoint}},
               @context
             )

    assert nested_triple.family == :invalid_workspace_or_runtime_protocol

    # An incompatible-runtime protocol error carrying supervision evidence keeps
    # its irrecoverable invalid-protocol identity.
    assert {:irrecoverable, incompatible_with_evidence} =
             AgentRuntime.classify_failure(
               {:incompatible_herdr_runtime, %{error_code: "unrecognized_agent_status", actual_status: "rebooting"}, %{checkpoint: good_checkpoint}},
               @context
             )

    assert incompatible_with_evidence.family == :invalid_workspace_or_runtime_protocol
    refute incompatible_with_evidence.summary =~ "pane-secret"

    # Supervised out-of-enum protocol status → invalid_workspace_or_runtime_protocol.
    for reason <- [
          {:unexpected_herdr_agent_status, "rebooting"},
          {:unexpected_herdr_agent_status, "rebooting", %{checkpoint: good_checkpoint}}
        ] do
      assert {:irrecoverable, protocol} = AgentRuntime.classify_failure(reason, @context)
      assert protocol.family == :invalid_workspace_or_runtime_protocol
      assert protocol.summary =~ "rebooting"
      refute protocol.summary =~ "pane-secret"
    end

    # Preserved-checkpoint supervised outcomes keep their existing retry semantics.
    for reason <- [
          {:implementer_hard_budget_exhausted, %{checkpoint: {:ok, %{pane_tail: pane_secret}}, last_status: "working"}},
          {:implementer_agent_stalled, %{checkpoint: {:ok, %{pane_tail: pane_secret}}, recovery_history: []}},
          {:implementer_agent_unobservable, %{checkpoint: {:ok, %{pane_tail: pane_secret}}, recovery_history: []}},
          {:implementer_status_reads_failed, %{checkpoint: {:ok, %{}}, last_error: :boom}}
        ] do
      assert {:retryable, retryable} = AgentRuntime.classify_failure(reason, @context)
      refute retryable.retry_reason =~ "pane-secret"
      refute retryable.retry_reason =~ "PANE TRANSCRIPT"
    end
  end

  test "classifies real adapter and runtime error shapes without pre-normalized families" do
    incompatible_runtime = %{
      expected_version: "0.7.5",
      expected_protocol: 17,
      actual_version: "0.8.0",
      actual_protocol: 17
    }

    missing_skill_contract =
      {:invalid_skill_execution_contract, %{skill: "linear", field: :package_root, reason: :missing}}

    non_executable_skill_tool =
      {:invalid_skill_execution_contract, %{skill: "linear", field: :tool_executables, reason: :non_executable}}

    cases = [
      {:invalid_workspace_or_runtime_protocol, {:invalid_workspace_cwd, :outside_workspace_root, "/tmp/outside", "/tmp/root"}},
      {:invalid_workspace_or_runtime_protocol, {:invalid_workspace_cwd, :invalid_remote_workspace, "worker-1", "/tmp/work\nspace"}},
      {:missing_required_tool_or_cli, :bash_not_found},
      {:missing_required_tool_or_cli, {:missing_required_tool, "herdr"}},
      {:missing_required_runtime_configuration, missing_skill_contract},
      {:permission_denied, non_executable_skill_tool},
      {:missing_required_tool_or_cli, {:port_exit, 127, "claude: command not found token=tool-secret"}},
      {:permission_denied, {:port_exit, 126, "permission denied secret=hidden"}},
      {:missing_required_runtime_configuration, {:unsupported_runtime_provider, "future-provider token=config-secret"}},
      {:missing_required_runtime_configuration, :missing_herdr_run_id},
      {:missing_required_runtime_configuration, :missing_herdr_issue_identifier},
      {:missing_required_runtime_configuration, {:herdr_remote_worker_not_implemented, "worker-1"}},
      {:invalid_workspace_or_runtime_protocol, {:incompatible_herdr_runtime, incompatible_runtime}},
      {:missing_required_runtime_configuration, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}},
      {:unsupported_app_server_contract, {:turn_failed, %{subtype: "unsupported_app_server_contract", message: "unsupported schema token=contract-secret"}}},
      {:malformed_provider_event_schema,
       {:turn_failed,
        %{
          subtype: "malformed_provider_event_schema",
          event: "result",
          message: "missing required session_id token=event-secret"
        }}}
    ]

    for {family, reason} <- cases do
      assert {:irrecoverable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.family == family
      assert failure.retryable? == false
      refute failure.retry_reason =~ "tool-secret"
      refute failure.retry_reason =~ "hidden"
      refute failure.retry_reason =~ "config-secret"
      refute failure.retry_reason =~ "contract-secret"
      refute failure.retry_reason =~ "event-secret"
      refute failure.retry_reason =~ "token="
      refute failure.retry_reason =~ "secret="
    end
  end

  test "redacts provider auth retry reason side-effect fields" do
    assert {:irrecoverable, failure} =
             AgentRuntime.classify_failure(
               {:auth_failed,
                %{
                  provider: :claude_code,
                  api_error_status: 403,
                  subtype: "login_required",
                  remediation_hint: "refresh with Bearer raw-token-123"
                }},
               @context
             )

    assert failure.family == :provider_authentication_or_revocation
    assert failure.summary =~ "[REDACTED]"
    assert failure.retry_reason =~ "[REDACTED]"
    refute failure.summary =~ "raw-token-123"
    refute failure.summary =~ "Bearer"
    refute failure.retry_reason =~ "raw-token-123"
    refute failure.retry_reason =~ "Bearer"
  end

  test "redacts credential-shaped prose and JSON fields at the classifier interface" do
    raw_details =
      ~s(permission denied refresh token raw-refresh-token {"api_key":"raw-api-key","refresh_token":"raw-json-refresh"})

    assert {:irrecoverable, failure} =
             AgentRuntime.classify_failure(
               {:permission_denied, %{path: "/root/.claude.json", message: raw_details}},
               @context
             )

    assert failure.family == :permission_denied
    assert failure.summary =~ "[REDACTED]"
    assert failure.retry_reason =~ "[REDACTED]"
    refute failure.summary =~ "raw-refresh-token"
    refute failure.summary =~ "raw-api-key"
    refute failure.summary =~ "raw-json-refresh"
    refute failure.retry_reason =~ "raw-refresh-token"
    refute failure.retry_reason =~ "raw-api-key"
    refute failure.retry_reason =~ "raw-json-refresh"

    assert {:irrecoverable, normalized} =
             AgentRuntime.classify_failure(
               {:irrecoverable_runtime_failed,
                %{
                  family: :permission_denied,
                  provider: :claude_code,
                  subtype: "fixture",
                  summary: "permission_denied #{raw_details}",
                  retry_reason: "permission_denied #{raw_details}",
                  recovery_reason: "permission-denied-repair-required"
                }},
               @context
             )

    assert normalized.summary =~ "[REDACTED]"
    assert normalized.retry_reason =~ "[REDACTED]"
    refute normalized.summary =~ "raw-refresh-token"
    refute normalized.summary =~ "raw-api-key"
    refute normalized.summary =~ "raw-json-refresh"
    refute normalized.retry_reason =~ "raw-refresh-token"
    refute normalized.retry_reason =~ "raw-api-key"
    refute normalized.retry_reason =~ "raw-json-refresh"
  end

  test "keeps explicit transient runtime failures retryable" do
    for reason <- [
          :turn_timeout,
          {:network_error, :econnreset},
          {:service_unavailable, 503},
          {:rate_limited, %{retry_after_ms: 1_000}},
          {:capacity_unavailable, "provider busy"},
          {:operator_interrupted, :cancelled}
        ] do
      assert {:retryable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.retryable? == true
      refute failure.family == :repeated_identical_no_progress_failure
    end
  end

  test "escalates the third consecutive identical no-progress observation without a wall-clock cap" do
    reason = {:empty_turn_completed, %{message: "Codex completed without agent output token=secret"}}

    {observation, {:retryable, first}} = AgentRuntime.record_failure_observation(nil, reason, @context)
    assert observation.count == 1
    assert first.retryable?

    {observation, {:retryable, second}} = AgentRuntime.record_failure_observation(observation, reason, @context)
    assert observation.count == 2
    assert second.retryable?

    assert {observation, {:irrecoverable, third}} =
             AgentRuntime.record_failure_observation(observation, reason, @context)

    assert observation.count == 3
    assert third.family == :repeated_identical_no_progress_failure
    assert third.retryable? == false
    assert third.fingerprint.issue_id == @context.issue_id
    assert third.fingerprint.workspace_path == @context.workspace_path
    assert third.fingerprint.role == @context.role
    assert third.fingerprint.runtime_provider == @context.provider
    assert third.fingerprint.family == :repeated_identical_no_progress_failure
    refute third.summary =~ "secret"
    refute third.summary =~ "token="
  end

  test "ordinary retry dispatch run ids do not reset identical no-progress observations" do
    reason = {:empty_turn_completed, %{message: "same no progress"}}

    {observation, {:retryable, _first}} =
      AgentRuntime.record_failure_observation(nil, reason, Map.put(@context, :run_id, "run-a"))

    {observation, {:retryable, _second}} =
      AgentRuntime.record_failure_observation(observation, reason, Map.put(@context, :run_id, "run-b"))

    assert observation.count == 2

    assert {_observation, {:irrecoverable, failure}} =
             AgentRuntime.record_failure_observation(observation, reason, Map.put(@context, :run_id, "run-c"))

    assert failure.family == :repeated_identical_no_progress_failure
  end

  test "resets no-progress observations for transient failures and different fingerprints" do
    reason = {:empty_turn_completed, %{message: "same no progress"}}

    {observation, {:retryable, _first}} = AgentRuntime.record_failure_observation(nil, reason, @context)
    {observation, {:retryable, _second}} = AgentRuntime.record_failure_observation(observation, reason, @context)

    {observation, {:retryable, transient}} =
      AgentRuntime.record_failure_observation(observation, {:rate_limited, %{message: "retry later"}}, @context)

    assert observation.count == 0
    assert transient.retryable?

    {observation, {:retryable, _first_after_reset}} =
      AgentRuntime.record_failure_observation(observation, reason, @context)

    assert observation.count == 1

    different = {:empty_turn_completed, %{message: "different no progress"}}
    {observation, {:retryable, _different}} = AgentRuntime.record_failure_observation(observation, different, @context)
    assert observation.count == 1
  end
end
