defmodule SymphonyElixir.AgentRuntimeFailureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime

  test "classifies Claude model mismatch as bounded irrecoverable runtime evidence" do
    reason =
      {:claude_model_mismatched,
       %{
         agent: "implementer_orchestrator",
         requested_model: "claude-fable-5",
         observed_model: "claude-sonnet-5"
       }}

    assert {:irrecoverable, failure} =
             AgentRuntime.classify_failure(reason, %{
               provider: :claude_code,
               role: "implementer",
               issue_id: "issue-model-mismatch",
               workspace_path: "/tmp/model-mismatch"
             })

    assert failure.family == :invalid_workspace_or_runtime_protocol
    assert failure.subtype == "claude_model_mismatched"
    assert failure.retryable? == false
    assert failure.summary =~ "requested_model=claude-fable-5"
    assert failure.summary =~ "observed_model=claude-sonnet-5"
    assert failure.summary =~ "agent=implementer_orchestrator"
    assert failure.fingerprint.summary == failure.retry_reason
  end

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
          {:implementer_status_reads_failed, %{checkpoint: {:ok, %{}}, last_error: {:network_error, :econnreset}}}
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

  test "fails closed for unknown failures and timeout-shaped prose outside the allowlist" do
    for reason <- [
          :unknown_runtime_failure,
          {:future_provider_failure, %{message: "provider timed out"}},
          {:herdr_agent_status_timeout, "implementer_orchestrator", ["working", "idle", "done"]}
        ] do
      assert {:irrecoverable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.family in [:unclassified_runtime_failure, :invalid_workspace_or_runtime_protocol]
      assert failure.retryable? == false
      refute failure.retry_reason =~ "transient_runtime_failure"
      refute failure.retry_reason =~ "retryable_runtime_failure"
    end
  end

  test "retry classification uses the exact recoverable allowlist and rejects adjacent shapes" do
    recoverable = [
      :turn_timeout,
      :network_error,
      :service_unavailable,
      :rate_limited,
      :capacity_unavailable,
      :operator_interrupted,
      {:turn_timeout, :provider_deadline},
      {:network_error, :econnreset},
      {:service_unavailable, %{status: 503}},
      {:rate_limited, %{status: 429}},
      {:capacity_unavailable, :overloaded},
      {:operator_interrupted, :shutdown},
      {:empty_turn_completed, %{message: "no output"}},
      {:turn_input_required, %{source: "provider"}},
      {:approval_required, %{source: "provider"}},
      {:implementer_hard_budget_exhausted, %{checkpoint: {:ok, %{}}}},
      {:implementer_agent_stalled, %{checkpoint: {:ok, %{}}}},
      {:implementer_agent_unobservable, %{checkpoint: {:ok, %{}}}},
      {:implementer_status_reads_failed, %{last_error: :network_error}},
      {:workspace_hook_timeout, "after_run", 30_000},
      {:workspace_hook_failed, "after_run", 75, "temporary"},
      {:post_turn_routing_failed, {:network_error, :econnreset}},
      {:remote_command_failed, "worker.example", {:rate_limited, %{status: 429}}}
    ]

    irrecoverable = [
      :timeout,
      {:future_provider_failure, %{message: "network timeout"}},
      {:herdr_agent_status_timeout, "implementer_orchestrator", ["working", "idle", "done"]},
      {:implementer_status_reads_failed, %{last_error: :unknown_status_read_failure}},
      {:workspace_hook_failed, "after_run", 74, "temporary-looking prose"},
      {:post_turn_routing_failed, :timeout},
      {:remote_command_failed, "worker.example", :timeout}
    ]

    for reason <- recoverable do
      assert {:retryable, %{retryable?: true}} = AgentRuntime.classify_failure(reason, @context),
             "expected exact allowlisted shape to retry: #{inspect(reason)}"
    end

    for reason <- irrecoverable do
      assert {:irrecoverable, %{retryable?: false}} = AgentRuntime.classify_failure(reason, @context),
             "expected non-allowlisted shape to fail closed: #{inspect(reason)}"
    end
  end

  test "suppresses the first equivalent redispatch at the same durable checkpoint" do
    reason = {:empty_turn_completed, %{message: "Codex completed without agent output token=secret"}}

    {observation, {:retryable, first}} = AgentRuntime.record_failure_observation(nil, reason, @context)
    assert observation.count == 1
    assert first.retryable?

    assert {observation, {:irrecoverable, repeated}} =
             AgentRuntime.record_failure_observation(observation, reason, @context)

    assert observation.count == 2
    assert repeated.family == :repeated_identical_no_progress_failure
    assert repeated.retryable? == false
    assert repeated.fingerprint.issue_id == @context.issue_id
    assert repeated.fingerprint.workspace_path == @context.workspace_path
    assert repeated.fingerprint.role == @context.role
    assert repeated.fingerprint.runtime_provider == @context.provider
    assert repeated.fingerprint.family == :repeated_identical_no_progress_failure
    refute repeated.summary =~ "secret"
    refute repeated.summary =~ "token="
  end

  test "ordinary retry dispatch run ids do not reset identical no-progress observations" do
    reason = {:empty_turn_completed, %{message: "same no progress"}}

    {observation, {:retryable, _first}} =
      AgentRuntime.record_failure_observation(nil, reason, Map.put(@context, :run_id, "run-a"))

    assert {_observation, {:irrecoverable, failure}} =
             AgentRuntime.record_failure_observation(
               observation,
               reason,
               Map.put(@context, :run_id, "run-b")
             )

    assert failure.family == :repeated_identical_no_progress_failure
  end

  test "changed failures reset while identical transient failures are also suppressed" do
    reason = {:empty_turn_completed, %{message: "same no progress"}}

    {observation, {:retryable, _first}} = AgentRuntime.record_failure_observation(nil, reason, @context)

    {observation, {:retryable, transient}} =
      AgentRuntime.record_failure_observation(observation, {:rate_limited, %{message: "retry later"}}, @context)

    assert observation.count == 1
    assert transient.retryable?

    assert {_observation, {:irrecoverable, repeated_transient}} =
             AgentRuntime.record_failure_observation(
               observation,
               {:rate_limited, %{message: "retry later"}},
               @context
             )

    assert repeated_transient.family == :repeated_identical_no_progress_failure
  end

  test "the same durable checkpoint and typed failure cannot authorize an equivalent redispatch for any role" do
    reason = {:rate_limited, %{message: "provider retry window"}}

    for role <- ["backlog-processor", "implementer", "reviewer", "qa", "landing"] do
      context =
        @context
        |> Map.put(:role, role)
        |> Map.put(:input_fingerprint, "checkpoint-a")

      {observation, {:retryable, first}} =
        AgentRuntime.record_failure_observation(nil, reason, context)

      assert first.retryable?

      assert {_observation, {:irrecoverable, repeated}} =
               AgentRuntime.record_failure_observation(observation, reason, context)

      assert repeated.family == :repeated_identical_no_progress_failure
      assert repeated.retryable? == false
      assert repeated.fingerprint.role == role
    end
  end

  test "a changed durable checkpoint permits one new bounded attempt" do
    reason = {:rate_limited, %{message: "provider retry window"}}
    first_context = Map.put(@context, :input_fingerprint, "checkpoint-a")
    changed_context = Map.put(@context, :input_fingerprint, "checkpoint-b")

    {observation, {:retryable, _first}} =
      AgentRuntime.record_failure_observation(nil, reason, first_context)

    assert {changed_observation, {:retryable, changed}} =
             AgentRuntime.record_failure_observation(observation, reason, changed_context)

    assert changed.retryable?
    assert changed_observation.count == 1
    assert changed_observation.reset_marker.input_fingerprint == "checkpoint-b"
  end
end
