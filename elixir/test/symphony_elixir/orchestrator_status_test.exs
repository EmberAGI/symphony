defmodule SymphonyElixir.OrchestratorStatusTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.ClaimLease
  alias SymphonyElixirWeb.Presenter

  defmodule DispatchAttemptLinearClient do
    def fetch_candidate_issues do
      Application.fetch_env!(:symphony_elixir, :dispatch_attempt_candidate_issues)
    end

    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_states_by_ids(_issue_ids) do
      Application.fetch_env!(:symphony_elixir, :dispatch_attempt_refetched_issues)
    end

    def graphql(_query, _variables) do
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "claim-comment"}}}}}
    end
  end

  test "snapshot returns :timeout when snapshot server is unresponsive" do
    server_name = Module.concat(__MODULE__, :UnresponsiveSnapshotServer)
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), server_name)
        send(parent, :snapshot_server_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :snapshot_server_ready, 1_000
    assert Orchestrator.snapshot(server_name, 10) == :timeout

    send(pid, :stop)
  end

  test "orchestrator snapshot reflects last codex update and session id" do
    issue_id = "issue-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-188",
      title: "Snapshot test",
      description: "Capture codex state",
      state: "In Progress",
      url: "https://example.org/issues/MT-188"
    }

    orchestrator_name = Module.concat(__MODULE__, :SnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    state_with_issue =
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))

    :sys.replace_state(pid, fn _ -> state_with_issue end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-live-turn-live",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{method: "some-event"},
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.issue_id == issue_id
    assert snapshot_entry.session_id == "thread-live-turn-live"
    assert snapshot_entry.turn_count == 1
    assert snapshot_entry.last_codex_timestamp == now

    assert snapshot_entry.last_codex_message == %{
             event: :notification,
             message: %{method: "some-event"},
             timestamp: now
           }
  end

  test "Claude Code dispatch accepts malformed effort labels for provider defaulting" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude"
    )

    issue = %Issue{
      id: "issue-claude-effort-default",
      identifier: "EMB-CC",
      title: "Claude effort default",
      state: "Todo",
      labels: ["implementation-effort:bogus"]
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new()
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "Codex dispatch still fails closed on malformed effort labels" do
    write_workflow_file!(Workflow.workflow_file_path())

    issue = %Issue{
      id: "issue-codex-effort-invalid",
      identifier: "EMB-CX",
      title: "Codex effort invalid",
      state: "Todo",
      labels: ["implementation-effort:bogus"]
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new()
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "running issue transition to human review without Human Escalation label does not send telegram notification" do
    parent = self()
    previous_request_fun = Application.get_env(:symphony_elixir, :telegram_request_fun)

    on_exit(fn ->
      case previous_request_fun do
        nil -> Application.delete_env(:symphony_elixir, :telegram_request_fun)
        request_fun -> Application.put_env(:symphony_elixir, :telegram_request_fun, request_fun)
      end
    end)

    Application.put_env(:symphony_elixir, :telegram_request_fun, fn request ->
      send(parent, {:telegram_request, request})
      {:ok, %Req.Response{status: 200}}
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    issue_id = "issue-human-review-notify"

    running_issue = %Issue{
      id: issue_id,
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      labels: [],
      state: "In Progress",
      url: "https://linear.app/example/EMB-99"
    }

    human_review_issue = %{running_issue | state: "Human Review"}

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: nil,
          identifier: running_issue.identifier,
          issue: running_issue,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    state = Orchestrator.reconcile_issue_states_for_test([human_review_issue], state)

    assert state.running == %{}
    assert MapSet.size(state.claimed) == 0
    refute_receive {:telegram_request, _request}
  end

  test "running issue Human Escalation label addition sends one telegram notification" do
    parent = self()
    previous_request_fun = Application.get_env(:symphony_elixir, :telegram_request_fun)

    on_exit(fn ->
      case previous_request_fun do
        nil -> Application.delete_env(:symphony_elixir, :telegram_request_fun)
        request_fun -> Application.put_env(:symphony_elixir, :telegram_request_fun, request_fun)
      end
    end)

    Application.put_env(:symphony_elixir, :telegram_request_fun, fn request ->
      send(parent, {:telegram_request, request})
      {:ok, %Req.Response{status: 200}}
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    issue_id = "issue-human-escalation-notify"

    running_issue = %Issue{
      id: issue_id,
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human escalation",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/EMB-99"
    }

    human_review_issue = %{running_issue | state: "Human Review", labels: ["human escalation"]}

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: nil,
          identifier: running_issue.identifier,
          issue: running_issue,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    state = Orchestrator.reconcile_issue_states_for_test([human_review_issue], state)

    assert state.running == %{}
    assert MapSet.size(state.claimed) == 0
    assert_receive {:telegram_request, request}
    assert request[:json].text =~ "Symphony needs human escalation"
    assert request[:json].text =~ "Issue: EMB-99"
    assert request[:json].text =~ "State: Human Review"

    state = Orchestrator.reconcile_issue_states_for_test([human_review_issue], state)
    assert state.running == %{}
    refute_receive {:telegram_request, _request}
  end

  test "agent task failure sends one telegram notification before retry" do
    parent = self()
    previous_request_fun = Application.get_env(:symphony_elixir, :telegram_request_fun)

    on_exit(fn ->
      case previous_request_fun do
        nil -> Application.delete_env(:symphony_elixir, :telegram_request_fun)
        request_fun -> Application.put_env(:symphony_elixir, :telegram_request_fun, request_fun)
      end
    end)

    Application.put_env(:symphony_elixir, :telegram_request_fun, fn request ->
      send(parent, {:telegram_request, request})
      {:ok, %Req.Response{status: 200}}
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id",
      telegram_events: ["human_escalation", "agent_failed"]
    )

    issue_id = "issue-agent-failed-notify"
    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "In Progress",
      url: "https://linear.app/example/EMB-99"
    }

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          retry_attempt: 0
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), :timeout}, state)
    assert state.running == %{}
    assert MapSet.member?(state.claimed, issue_id)
    assert Map.has_key?(state.retry_attempts, issue_id)

    assert_receive {:telegram_request, request}
    assert request[:json].text =~ "Symphony agent failed"
    assert request[:json].text =~ "Issue: EMB-99"
    assert request[:json].text =~ "State: In Progress"
    assert request[:json].text =~ "Reason: :timeout"
  end

  test "Claude provider auth task failure escalates visibly without ordinary retry" do
    parent = self()
    previous_request_fun = Application.get_env(:symphony_elixir, :telegram_request_fun)

    on_exit(fn ->
      case previous_request_fun do
        nil -> Application.delete_env(:symphony_elixir, :telegram_request_fun)
        request_fun -> Application.put_env(:symphony_elixir, :telegram_request_fun, request_fun)
      end
    end)

    Application.put_env(:symphony_elixir, :telegram_request_fun, fn request ->
      send(parent, {:telegram_request, request})
      {:ok, %Req.Response{status: 200}}
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    issue_id = "issue-provider-auth-blocked"
    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "EMB-1123",
      title: "Classify provider auth",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/EMB-1123"
    }

    claim_lease =
      ClaimLease.new(%{
        comment_id: "lease-comment",
        issue_id: issue_id,
        issue_identifier: issue.identifier,
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-provider-auth",
        attempt: 0,
        state: "active",
        started_at: DateTime.utc_now()
      })

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: %{issue | claim_lease: claim_lease},
          claim_lease: claim_lease,
          run_id: claim_lease.run_id,
          started_at: DateTime.utc_now(),
          retry_attempt: 15
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{issue_id => %{attempt: 15, error: "ordinary retry should be cleared"}},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    auth_reason =
      {:provider_auth_failed,
       %{
         provider: :claude_code,
         api_error_status: 401,
         subtype: "oauth_expired",
         remediation_hint: "refresh with Bearer raw-secret-token",
         raw: "Bearer raw-secret-token"
       }}

    log =
      capture_log(fn ->
        assert {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), auth_reason}, state)
        assert state.running == %{}
        assert state.retry_attempts == %{}
        assert MapSet.member?(state.claimed, issue_id)
      end)

    blocked_lease = receive_claim_lease_state!(issue_id, "blocked")
    assert blocked_lease.state == "blocked"

    assert blocked_lease.retry_reason ==
             "provider_auth_failed: claude_code status=401 subtype=oauth_expired remediation=refresh with [REDACTED]"

    assert blocked_lease.recovery_reason == "provider-authentication-required"
    assert blocked_lease.run_id == "run-provider-auth"

    assert_receive {:memory_tracker_comment, ^issue_id, note}
    assert note =~ "## Operator Note"

    assert note =~
             "provider_auth_failed: claude_code status=401 subtype=oauth_expired remediation=refresh with [REDACTED]"

    refute note =~ "raw-secret-token"
    refute note =~ "Bearer"

    assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}
    assert_receive {:telegram_request, request}
    assert request[:json].text =~ "Symphony needs human escalation"
    assert request[:json].text =~ "Issue: EMB-1123"
    refute request[:json].text =~ "raw-secret-token"
    refute request[:json].text =~ "Bearer"

    assert log =~ "Provider authentication failed"
    assert log =~ "status=401"
    assert log =~ "subtype=oauth_expired"
    assert log =~ "remediation=refresh with [REDACTED]"
    refute log =~ "raw-secret-token"
    refute log =~ "Bearer"
  end

  test "deterministic irrecoverable runtime task failure escalates without ordinary retry" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    run_log_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-irrecoverable-run-log-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:symphony_elixir, :run_log_root, run_log_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :run_log_root)
      File.rm_rf(run_log_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-missing-tool-blocked"
    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "EMB-1127",
      title: "Classify missing runtime tool",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/EMB-1127"
    }

    claim_lease =
      ClaimLease.new(%{
        comment_id: "lease-comment-missing-tool",
        issue_id: issue_id,
        issue_identifier: issue.identifier,
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-missing-tool",
        attempt: 0,
        state: "active",
        started_at: DateTime.utc_now()
      })

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: %{issue | claim_lease: claim_lease},
          claim_lease: claim_lease,
          run_id: claim_lease.run_id,
          workspace_path: "/tmp/symphony/EMB-1127",
          started_at: DateTime.utc_now(),
          retry_attempt: 3
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{issue_id => %{attempt: 3, error: "ordinary retry should be cleared"}},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    reason =
      {:missing_required_tool_or_cli, %{tool: "claude", message: "command not found token=missing-tool-secret"}}

    log =
      capture_log(fn ->
        assert {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)
        assert state.running == %{}
        assert state.retry_attempts == %{}
        assert MapSet.member?(state.claimed, issue_id)
      end)

    blocked_lease = receive_claim_lease_state!(issue_id, "blocked")
    assert blocked_lease.state == "blocked"
    assert blocked_lease.retry_reason =~ "missing_required_tool_or_cli"
    assert blocked_lease.recovery_reason == "missing-required-tool-or-cli-repair-required"

    assert_receive {:memory_tracker_comment, ^issue_id, note}
    assert note =~ "## Operator Note"
    assert note =~ "missing_required_tool_or_cli"
    assert note =~ "Action required"
    refute note =~ "missing-tool-secret"
    refute note =~ "token="

    assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}
    refute_receive {:memory_tracker_claim_lease, ^issue_id, %{state: "retrying"}}, 100

    assert log =~ "Irrecoverable runtime failure"
    assert log =~ "missing_required_tool_or_cli"
    refute log =~ "missing-tool-secret"
    refute log =~ "token="

    run_log_path = Path.join([run_log_root, "EMB-1127", "run-missing-tool.jsonl"])
    assert File.exists?(run_log_path)

    [event] =
      run_log_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert event["event"] == "irrecoverable_runtime_failure_escalated"
    assert event["failure"]["family"] == "missing_required_tool_or_cli"
    assert event["failure"]["claim_lease_state"] == "blocked"
    refute event["failure"]["reason"] =~ "missing-tool-secret"
    refute event["failure"]["reason"] =~ "token="
  end

  test "real invalid workspace adapter failure escalates without ordinary retry" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-invalid-workspace-blocked"
    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "EMB-1127",
      title: "Classify invalid workspace",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/EMB-1127"
    }

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          run_id: "run-invalid-workspace",
          workspace_path: "/tmp/symphony/EMB-1127",
          started_at: DateTime.utc_now(),
          retry_attempt: 2
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{issue_id => %{attempt: 2, error: "ordinary retry should be cleared"}},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    reason =
      {:invalid_workspace_cwd, :outside_workspace_root, "/tmp/outside token=workspace-secret", "/tmp/root"}

    log =
      capture_log(fn ->
        assert {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)
        assert state.running == %{}
        assert state.retry_attempts == %{}
        assert state.blocked_failures[issue_id].family == :invalid_workspace_or_runtime_protocol
        assert MapSet.member?(state.claimed, issue_id)
      end)

    blocked_lease = receive_claim_lease_state!(issue_id, "blocked")
    assert blocked_lease.retry_reason =~ "invalid_workspace_or_runtime_protocol"
    assert blocked_lease.recovery_reason == "invalid-workspace-or-runtime-protocol-repair-required"

    assert_receive {:memory_tracker_comment, ^issue_id, note}
    assert note =~ "## Operator Note"
    assert note =~ "invalid_workspace_or_runtime_protocol"
    refute note =~ "workspace-secret"
    refute note =~ "token="

    assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}
    refute_receive {:memory_tracker_claim_lease, ^issue_id, %{state: "retrying"}}, 100

    assert log =~ "Irrecoverable runtime failure"
    assert log =~ "invalid_workspace_or_runtime_protocol"
    refute log =~ "workspace-secret"
    refute log =~ "token="
  end

  test "irrecoverable escalation stays blocked when tracker mutation writes fail" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_fail_mutations, %{
      comment: :comment_down,
      label: :label_down,
      state: :state_down
    })

    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_fail_mutations) end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-tracker-mutation-failure"
    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "EMB-1127",
      title: "Tracker mutation failure still blocks",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/EMB-1127"
    }

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          run_id: "run-tracker-failure",
          workspace_path: "/tmp/symphony/EMB-1127",
          started_at: DateTime.utc_now(),
          retry_attempt: 1
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{issue_id => %{attempt: 1, error: "ordinary retry should be cleared"}},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    reason = {:permission_denied, %{path: "/root/.claude.json", message: "Permission denied secret=hidden"}}

    log =
      capture_log(fn ->
        assert {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)
        assert state.running == %{}
        assert state.retry_attempts == %{}
        assert state.blocked_failures[issue_id].family == :permission_denied
        assert MapSet.member?(state.claimed, issue_id)
      end)

    blocked_lease = receive_claim_lease_state!(issue_id, "blocked")
    assert blocked_lease.retry_reason =~ "permission_denied"
    assert log =~ "Failed irrecoverable Human Escalation comment update"
    assert log =~ "Failed irrecoverable Human Escalation label update"
    assert log =~ "Failed irrecoverable Human Escalation state update"
    refute log =~ "hidden"
    refute log =~ "secret="
  end

  test "irrecoverable escalation redacts credential prose and JSON fields from side effects" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-irrecoverable-json-redaction"
    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "EMB-1127",
      title: "Redact irrecoverable runtime evidence",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/EMB-1127"
    }

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          run_id: "run-json-redaction",
          workspace_path: "/tmp/symphony/EMB-1127",
          started_at: DateTime.utc_now(),
          retry_attempt: 1
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{issue_id => %{attempt: 1, error: "ordinary retry should be cleared"}},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    raw_details =
      ~s(Permission denied refresh token raw-refresh-token {"api_key":"raw-api-key","refresh_token":"raw-json-refresh"})

    reason = {:permission_denied, %{path: "/root/.claude.json", message: raw_details}}

    log =
      capture_log(fn ->
        assert {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)
        assert state.running == %{}
        assert state.retry_attempts == %{}
        assert state.blocked_failures[issue_id].family == :permission_denied
      end)

    blocked_lease = receive_claim_lease_state!(issue_id, "blocked")
    assert blocked_lease.retry_reason =~ "permission_denied"
    assert blocked_lease.retry_reason =~ "[REDACTED]"
    refute blocked_lease.retry_reason =~ "raw-refresh-token"
    refute blocked_lease.retry_reason =~ "raw-api-key"
    refute blocked_lease.retry_reason =~ "raw-json-refresh"

    assert_receive {:memory_tracker_comment, ^issue_id, note}
    assert note =~ "## Operator Note"
    assert note =~ "[REDACTED]"
    refute note =~ "raw-refresh-token"
    refute note =~ "raw-api-key"
    refute note =~ "raw-json-refresh"

    assert log =~ "Irrecoverable runtime failure"
    assert log =~ "[REDACTED]"
    refute log =~ "raw-refresh-token"
    refute log =~ "raw-api-key"
    refute log =~ "raw-json-refresh"
  end

  test "third consecutive identical AgentRunner no-progress exit escalates immediately" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-no-progress-threshold"

    issue = %Issue{
      id: issue_id,
      identifier: "EMB-1127",
      title: "Detect repeated no progress",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/EMB-1127"
    }

    claim_lease =
      ClaimLease.new(%{
        comment_id: "lease-comment-no-progress",
        issue_id: issue_id,
        issue_identifier: issue.identifier,
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-no-progress",
        attempt: 0,
        state: "active",
        started_at: DateTime.utc_now()
      })

    running_entry = fn ref, attempt ->
      %{
        pid: nil,
        ref: ref,
        identifier: issue.identifier,
        issue: %{issue | claim_lease: claim_lease},
        claim_lease: claim_lease,
        run_id: claim_lease.run_id,
        workspace_path: "/tmp/symphony/EMB-1127",
        started_at: DateTime.utc_now(),
        retry_attempt: attempt
      }
    end

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    reason = {:agent_runtime_failed, {:empty_turn_completed, %{message: "same no progress token=hidden"}}}

    first_ref = make_ref()
    state = %{state | running: %{issue_id => running_entry.(first_ref, 1)}}
    assert {:noreply, state} = Orchestrator.handle_info({:DOWN, first_ref, :process, self(), reason}, state)
    assert Map.has_key?(state.retry_attempts, issue_id)
    assert state.failure_observations[issue_id].count == 1
    refute_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 100

    second_ref = make_ref()
    state = %{state | running: %{issue_id => running_entry.(second_ref, 2)}, retry_attempts: %{}}
    assert {:noreply, state} = Orchestrator.handle_info({:DOWN, second_ref, :process, self(), reason}, state)
    assert Map.has_key?(state.retry_attempts, issue_id)
    assert state.failure_observations[issue_id].count == 2
    refute_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 100

    third_ref = make_ref()
    state = %{state | running: %{issue_id => running_entry.(third_ref, 3)}, retry_attempts: %{}}

    log =
      capture_log(fn ->
        assert {:noreply, state} = Orchestrator.handle_info({:DOWN, third_ref, :process, self(), reason}, state)
        assert state.running == %{}
        assert state.retry_attempts == %{}
        assert state.failure_observations[issue_id].count == 3
        assert MapSet.member?(state.claimed, issue_id)
      end)

    blocked_lease = receive_claim_lease_state!(issue_id, "blocked")
    assert blocked_lease.state == "blocked"
    assert blocked_lease.retry_reason =~ "repeated_identical_no_progress_failure"
    assert blocked_lease.recovery_reason == "repeated-identical-no-progress-failure-repair-required"
    assert_receive {:memory_tracker_comment, ^issue_id, note}
    assert note =~ "repeated_identical_no_progress_failure"
    assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}
    refute log =~ "hidden"
    refute log =~ "token="
  end

  test "new claim lease run resets identical no-progress observations through orchestrator context" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-no-progress-new-claim-reset"

    issue = %Issue{
      id: issue_id,
      identifier: "EMB-1127",
      title: "Reset no-progress on new claim",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/EMB-1127"
    }

    claim_lease = fn run_id ->
      ClaimLease.new(%{
        comment_id: "lease-comment-#{run_id}",
        issue_id: issue_id,
        issue_identifier: issue.identifier,
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: run_id,
        attempt: 0,
        state: "active",
        started_at: DateTime.utc_now()
      })
    end

    running_entry = fn ref, run_id, attempt ->
      lease = claim_lease.(run_id)

      %{
        pid: nil,
        ref: ref,
        identifier: issue.identifier,
        issue: %{issue | claim_lease: lease},
        claim_lease: lease,
        run_id: run_id,
        workspace_path: "/tmp/symphony/EMB-1127",
        started_at: DateTime.utc_now(),
        retry_attempt: attempt
      }
    end

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    reason = {:empty_turn_completed, %{message: "same no progress token=hidden"}}

    first_ref = make_ref()
    state = %{state | running: %{issue_id => running_entry.(first_ref, "claim-run-a", 1)}}
    assert {:noreply, state} = Orchestrator.handle_info({:DOWN, first_ref, :process, self(), reason}, state)
    assert state.failure_observations[issue_id].count == 1

    second_ref = make_ref()
    state = %{state | running: %{issue_id => running_entry.(second_ref, "claim-run-a", 2)}, retry_attempts: %{}}
    assert {:noreply, state} = Orchestrator.handle_info({:DOWN, second_ref, :process, self(), reason}, state)
    assert state.failure_observations[issue_id].count == 2

    third_ref = make_ref()
    state = %{state | running: %{issue_id => running_entry.(third_ref, "claim-run-b", 1)}, retry_attempts: %{}}

    assert {:noreply, state} = Orchestrator.handle_info({:DOWN, third_ref, :process, self(), reason}, state)
    assert state.failure_observations[issue_id].count == 1
    assert Map.has_key?(state.retry_attempts, issue_id)
    refute Map.has_key?(state.blocked_failures, issue_id)
    refute_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 100
  end

  test "third identical no-progress retry escalates across retry timer dispatches with redacted metadata" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    test_root_alias =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-retry-dispatch-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root_alias)
    test_root = File.cd!(test_root_alias, fn -> File.cwd!() end)

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        max_retry_backoff_ms: 1,
        hook_before_run: "sleep 30"
      )

      issue_id = "issue-no-progress-retry-dispatch"

      issue = %Issue{
        id: issue_id,
        identifier: "EMB-1127",
        title: "Detect repeated no progress across retry dispatch",
        state: "In Progress",
        labels: [],
        url: "https://linear.app/example/EMB-1127"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      issue_workspace_path = Path.join(workspace_root, issue.identifier)

      orchestrator_name = Module.concat(__MODULE__, :NoProgressRetryDispatchOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      first_ref = make_ref()

      :sys.replace_state(pid, fn _ ->
        %{
          initial_state
          | running: %{
              issue_id => %{
                pid: nil,
                ref: first_ref,
                identifier: issue.identifier,
                issue: issue,
                run_id: "run-initial-no-progress",
                workspace_path: issue_workspace_path,
                started_at: DateTime.utc_now(),
                retry_attempt: 0
              }
            },
            claimed: MapSet.new([issue_id]),
            retry_attempts: %{}
        }
      end)

      reason = {:empty_turn_completed, %{message: "same no progress token=hidden"}}

      log =
        capture_log(fn ->
          send(pid, {:DOWN, first_ref, :process, self(), reason})

          first_retry_lease = receive_claim_lease_state!(issue_id, "retrying")
          refute first_retry_lease.retry_reason =~ "hidden"
          refute first_retry_lease.retry_reason =~ "token="
          assert first_retry_lease.retry_reason =~ "retryable_runtime_failure"

          first_retry_run = kill_retry_dispatch!(pid, issue_id, reason)
          assert first_retry_run != "run-initial-no-progress"

          second_retry_lease = receive_claim_lease_state!(issue_id, "retrying")
          refute second_retry_lease.retry_reason =~ "hidden"
          refute second_retry_lease.retry_reason =~ "token="

          second_retry_run = kill_retry_dispatch!(pid, issue_id, reason)
          assert second_retry_run != first_retry_run

          blocked_lease = receive_claim_lease_state!(issue_id, "blocked")
          assert blocked_lease.retry_reason =~ "repeated_identical_no_progress_failure"
          assert blocked_lease.recovery_reason == "repeated-identical-no-progress-failure-repair-required"
          refute blocked_lease.retry_reason =~ "hidden"
          refute blocked_lease.retry_reason =~ "token="

          note = receive_memory_comment_containing!(issue_id, "repeated_identical_no_progress_failure")
          assert note =~ "repeated_identical_no_progress_failure"
          refute note =~ "hidden"
          refute note =~ "token="

          assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 1_000
          assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}, 1_000

          state = :sys.get_state(pid)
          assert state.running == %{}
          assert state.retry_attempts == %{}
          assert state.failure_observations[issue_id].count == 3
        end)

      refute log =~ "hidden"
      refute log =~ "token="
    after
      File.rm_rf(test_root)
    end
  end

  test "generic retryable worker exit uses redacted classifier metadata for retry claim leases" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-generic-retry-redacted"
    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "EMB-1127",
      title: "Redact retry metadata",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/EMB-1127"
    }

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          run_id: "run-generic-retry",
          workspace_path: "/tmp/symphony/EMB-1127",
          started_at: DateTime.utc_now(),
          retry_attempt: 1
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    reason = {:agent_failed, %{message: "agent failed without progress token=generic-retry-secret"}}

    log =
      capture_log(fn ->
        assert {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)
        assert Map.has_key?(state.retry_attempts, issue_id)
      end)

    retry_lease = receive_claim_lease_state!(issue_id, "retrying")

    assert retry_lease.retry_reason =~ "retryable_runtime_failure"
    refute retry_lease.retry_reason =~ "generic-retry-secret"
    refute retry_lease.retry_reason =~ "token="
    refute log =~ "generic-retry-secret"
    refute log =~ "token="
  end

  test "provider auth before_run hook failure reaches orchestrator as blocked without ordinary retry" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-before-run-auth-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        poll_interval_ms: 30_000,
        workspace_root: workspace_root,
        hook_before_run: """
        printf '%s\\n' 'Provider-auth pre-turn withheld: provider-auth provider=claude_code status=unhealthy affected_roles=implementer,qa remediation=run claude setup-token raw=Bearer orchestrator-hook-secret'
        exit 17
        """
      )

      issue_id = "issue-orchestrator-before-run-auth"

      issue = %Issue{
        id: issue_id,
        identifier: "EMB-1128",
        title: "Classify pre-turn provider auth",
        state: "In Progress",
        labels: ["implementation-effort:high"],
        url: "https://linear.app/example/EMB-1128"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :BeforeRunProviderAuthOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      :sys.replace_state(pid, fn state ->
        %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
      end)

      log =
        capture_log(fn ->
          send(pid, :run_poll_cycle)

          active_lease = receive_claim_lease_state!(issue_id, "active")
          assert active_lease.state == "active"

          blocked_lease = receive_claim_lease_state!(issue_id, "blocked")
          assert blocked_lease.state == "blocked"

          assert blocked_lease.retry_reason ==
                   "provider_auth_failed: claude_code readiness_status=unhealthy affected_roles=implementer,qa remediation=run claude setup-token"

          assert blocked_lease.recovery_reason == "provider-authentication-required"

          note = receive_memory_comment_containing!(issue_id, "provider_auth_failed")
          assert note =~ "## Operator Note"

          assert note =~
                   "provider_auth_failed: claude_code readiness_status=unhealthy affected_roles=implementer,qa remediation=run claude setup-token"

          refute note =~ "orchestrator-hook-secret"
          refute note =~ "Bearer"

          assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 1_000
          assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}, 1_000

          state = :sys.get_state(pid)
          assert state.retry_attempts == %{}
          assert MapSet.member?(state.claimed, issue_id)
        end)

      assert log =~ "Provider authentication failed"

      assert log =~
               "provider_auth_failed: claude_code readiness_status=unhealthy affected_roles=implementer,qa remediation=run claude setup-token"

      refute log =~ "orchestrator-hook-secret"
      refute log =~ "Bearer"
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator snapshot tracks codex thread totals and app-server pid" do
    issue_id = "issue-usage-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-201",
      title: "Usage snapshot test",
      description: "Collect usage stats",
      state: "In Progress",
      url: "https://example.org/issues/MT-201"
    }

    orchestrator_name = Module.concat(__MODULE__, :UsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-usage-turn-usage",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}
             }
           }
         },
         timestamp: now,
         codex_app_server_pid: "4242"
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_app_server_pid == "4242"
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16
    assert snapshot_entry.turn_count == 1
    assert is_integer(snapshot_entry.runtime_seconds)

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
    assert is_integer(completed_state.codex_totals.seconds_running)
  end

  test "orchestrator snapshot tracks turn completed usage when present" do
    issue_id = "issue-turn-completed-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-202",
      title: "Turn completed usage test",
      description: "Track final turn usage",
      state: "In Progress",
      url: "https://example.org/issues/MT-202"
    }

    orchestrator_name = Module.concat(__MODULE__, :TurnCompletedUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :turn_completed,
         payload: %{
           method: "turn/completed",
           usage: %{"input_tokens" => "12", "output_tokens" => 4, "total_tokens" => 16}
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)
    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
  end

  test "orchestrator snapshot tracks Claude normalized progress and terminal usage" do
    issue_id = "issue-claude-normalized-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-203",
      title: "Claude normalized usage test",
      description: "Track Claude Code normalized events",
      state: "In Progress",
      url: "https://example.org/issues/MT-203"
    }

    orchestrator_name = Module.concat(__MODULE__, :ClaudeNormalizedUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "claude-session-1",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :text_delta,
         payload: %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "Checking status"}]}},
         timestamp: now
       }}
    )

    progress_snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [progress_entry]} = progress_snapshot
    assert progress_entry.session_id == "claude-session-1"
    assert progress_entry.turn_count == 1
    assert progress_entry.last_codex_event == :text_delta
    refute progress_entry.last_codex_message.message == nil

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :turn_completed,
         session_id: "claude-session-1",
         usage: %{"input_tokens" => 153, "output_tokens" => 6, "total_tokens" => 159},
         payload: %{
           "type" => "result",
           "subtype" => "success",
           "usage" => %{"input_tokens" => 153, "output_tokens" => 6, "total_tokens" => 159}
         },
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 153
    assert snapshot_entry.codex_output_tokens == 6
    assert snapshot_entry.codex_total_tokens == 159
    assert snapshot_entry.last_codex_event == :turn_completed

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)
    assert completed_state.codex_totals.input_tokens == 153
    assert completed_state.codex_totals.output_tokens == 6
    assert completed_state.codex_totals.total_tokens == 159
  end

  test "orchestrator snapshot tracks codex token-count cumulative usage payloads" do
    issue_id = "issue-token-count-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-220",
      title: "Token count snapshot test",
      description: "Validate token-count style payloads",
      state: "In Progress",
      url: "https://example.org/issues/MT-220"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "input_tokens" => "2",
                   "output_tokens" => 2,
                   "total_tokens" => 4
                 }
               }
             }
           }
         },
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "prompt_tokens" => 10,
                   "completion_tokens" => 5,
                   "total_tokens" => 15
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 5
    assert snapshot_entry.codex_total_tokens == 15

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.codex_totals.input_tokens == 10
    assert completed_state.codex_totals.output_tokens == 5
    assert completed_state.codex_totals.total_tokens == 15
  end

  test "orchestrator snapshot tracks codex rate-limit payloads" do
    issue_id = "issue-rate-limit-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-221",
      title: "Rate limit snapshot test",
      description: "Capture codex rate limit state",
      state: "In Progress",
      url: "https://example.org/issues/MT-221"
    }

    orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    rate_limits = %{
      "limit_id" => "codex",
      "primary" => %{"remaining" => 90, "limit" => 100},
      "secondary" => nil,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => nil}
    }

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "rate_limits" => rate_limits
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.rate_limits == rate_limits
  end

  test "orchestrator token accounting prefers total_token_usage over last_token_usage in token_count payloads" do
    issue_id = "issue-token-precedence"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-222",
      title: "Token precedence",
      description: "Prefer per-event deltas",
      state: "In Progress",
      url: "https://example.org/issues/MT-222"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenPrecedenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 2,
                     "output_tokens" => 1,
                     "total_tokens" => 3
                   },
                   "total_token_usage" => %{
                     "input_tokens" => 200,
                     "output_tokens" => 100,
                     "total_tokens" => 300
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 200
    assert snapshot_entry.codex_output_tokens == 100
    assert snapshot_entry.codex_total_tokens == 300
  end

  test "orchestrator token accounting accumulates monotonic thread token usage totals" do
    issue_id = "issue-thread-token-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-223",
      title: "Thread token usage",
      description: "Accumulate absolute thread totals",
      state: "In Progress",
      url: "https://example.org/issues/MT-223"
    }

    orchestrator_name = Module.concat(__MODULE__, :ThreadTokenUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    for usage <- [
          %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11},
          %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
        ] do
      send(
        pid,
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "thread/tokenUsage/updated",
             "params" => %{"tokenUsage" => %{"total" => usage}}
           },
           timestamp: DateTime.utc_now()
         }}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 14
  end

  test "orchestrator token accounting ignores last_token_usage without cumulative totals" do
    issue_id = "issue-last-token-ignored"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-224",
      title: "Last token ignored",
      description: "Ignore delta-only token reports",
      state: "In Progress",
      url: "https://example.org/issues/MT-224"
    }

    orchestrator_name = Module.concat(__MODULE__, :LastTokenIgnoredOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 8,
                     "output_tokens" => 3,
                     "total_tokens" => 11
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 0
    assert snapshot_entry.codex_output_tokens == 0
    assert snapshot_entry.codex_total_tokens == 0
  end

  test "orchestrator snapshot includes retry backoff entries" do
    orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    retry_entry = %{
      attempt: 2,
      timer_ref: nil,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      identifier: "MT-500",
      error: "agent exited: :boom"
    }

    initial_state = :sys.get_state(pid)
    new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
    :sys.replace_state(pid, fn _ -> new_state end)

    snapshot = GenServer.call(pid, :snapshot)
    assert is_list(snapshot.retrying)

    assert [
             %{
               issue_id: "mt-500",
               attempt: 2,
               due_in_ms: due_in_ms,
               identifier: "MT-500",
               error: "agent exited: :boom"
             }
           ] = snapshot.retrying

    assert due_in_ms > 0
  end

  test "orchestrator snapshot includes poll countdown and checking status" do
    orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 30_000,
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: now_ms + 4_000,
          poll_check_in_progress: false
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 30_000,
               next_poll_in_ms: due_in_ms
             }
           } = snapshot

    assert is_integer(due_in_ms)
    assert due_in_ms >= 0
    assert due_in_ms <= 4_000

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{polling: %{checking?: true, next_poll_in_ms: nil}} = snapshot
  end

  test "orchestrator triggers an immediate poll cycle shortly after startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 5_000
    )

    orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    startup_snapshot =
      wait_for_snapshot(
        pid,
        fn
          %{polling: %{checking?: true}} ->
            true

          %{polling: %{last_poll_started_at: started_at}} when is_binary(started_at) ->
            true

          _ ->
            false
        end,
        500
      )

    assert startup_snapshot.polling.checking? == true or is_binary(startup_snapshot.polling.last_poll_started_at)

    assert %{
             polling: %{
               checking?: false,
               next_poll_in_ms: next_poll_in_ms,
               poll_interval_ms: 5_000
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}}
                 when is_integer(due_in_ms) and due_in_ms <= 5_000 ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
  end

  test "orchestrator poll cycle resets next refresh countdown after a check" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 50,
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{polling: %{checking?: false, poll_interval_ms: 50, next_poll_in_ms: next_poll_in_ms}}
        when is_integer(next_poll_in_ms) and next_poll_in_ms <= 50 ->
          true

        _ ->
          false
      end)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 50,
               next_poll_in_ms: next_poll_in_ms
             }
           } = snapshot

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
    assert next_poll_in_ms <= 50
  end

  test "orchestrator snapshot records poll diagnostics for all skipped stale claim candidates" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 30_000,
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces")
    )

    now = DateTime.utc_now()

    claim_lease =
      ClaimLease.new(%{
        issue_id: "issue-stale-lease",
        issue_identifier: "MT-LEASE",
        role: ClaimLease.role_name(),
        holder: "dead-host:1234:implementer",
        run_id: "dead-host:1234:implementer:issue-stale-lease:1",
        workspace_path: Path.join(System.tmp_dir!(), "symphony_workspaces/MT-LEASE"),
        state: "active",
        started_at: DateTime.add(now, -120, :second),
        refreshed_at: DateTime.add(now, -120, :second),
        expires_at: DateTime.add(now, 120, :second),
        attempt: 1
      })

    issue = %Issue{
      id: "issue-stale-lease",
      identifier: "MT-LEASE",
      title: "Blocked by stale same-role lease",
      state: "Todo",
      labels: ["implementation-effort:high"],
      claim_lease: claim_lease,
      claim_leases: [claim_lease]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :SkippedClaimLeaseDiagnosticsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{polling: %{last_poll_result: "all_candidates_skipped"}} -> true
        _ -> false
      end)

    assert %{
             polling: %{
               checking?: false,
               last_poll_started_at: last_poll_started_at,
               last_poll_completed_at: last_poll_completed_at,
               last_poll_result: "all_candidates_skipped",
               latest_dispatch_summary: %{
                 result: "all_candidates_skipped",
                 candidate_count: 1,
                 dispatched_count: 0,
                 candidate_identifiers: ["MT-LEASE"],
                 dispatched_identifiers: [],
                 skip_reason_families: ["stale_claim_lease_blocked"],
                 skipped_candidates: [
                   %{
                     issue_identifier: "MT-LEASE",
                     reason_family: "stale_claim_lease_blocked",
                     claim_lease: %{
                       holder: "dead-host:1234:implementer",
                       role: role,
                       state: "active",
                       expires_at: expires_at,
                       recovery_decision: "wait_for_expiry_or_dead_holder_recovery"
                     }
                   }
                 ]
               }
             }
           } = snapshot

    assert role == ClaimLease.role_name()
    assert is_binary(expires_at)
    assert is_binary(last_poll_started_at)
    assert is_binary(last_poll_completed_at)
  end

  test "role state presenter exposes polling diagnostics from the default orchestrator snapshot" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 30_000
    )

    orchestrator_name = Module.concat(__MODULE__, :PresenterPollingDiagnosticsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    wait_for_snapshot(pid, fn
      %{polling: %{checking?: false}} -> true
      _ -> false
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_check_in_progress: false,
          next_poll_due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          last_poll_started_at: DateTime.utc_now(),
          last_poll_completed_at: DateTime.utc_now(),
          last_poll_result: "no_candidates",
          latest_dispatch_summary: %{
            result: "no_candidates",
            candidate_count: 0,
            dispatched_count: 0,
            candidate_identifiers: [],
            dispatched_identifiers: [],
            skip_reason_families: [],
            skipped_candidates: []
          }
      }
    end)

    payload = Presenter.state_payload(orchestrator_name, 50)

    assert %{
             polling_diagnostics: %{
               checking: checking,
               status: status,
               poll_interval_ms: 30_000,
               next_poll_in_ms: next_poll_in_ms,
               last_poll_result: "no_candidates",
               latest_dispatch_summary: %{
                 result: "no_candidates",
                 candidate_count: 0,
                 dispatched_count: 0
               }
             }
           } = payload

    assert checking in [true, false]
    assert status in ["idle", "checking"]
    assert is_integer(next_poll_in_ms) or is_nil(next_poll_in_ms)
  end

  test "role state presenter exposes every dispatch diagnostic result family" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 30_000
    )

    issue = %Issue{
      id: "issue-dispatch-family",
      identifier: "MT-FAMILY",
      title: "Dispatch family",
      state: "Todo"
    }

    cases = [
      {"no_candidates", [], []},
      {"all_candidates_skipped", [issue], [{:skipped, %{issue_id: issue.id, issue_identifier: issue.identifier, reason_family: "role_capacity_blocked"}}]},
      {"dispatch_attempted", [issue], [:attempted]},
      {"dispatch_failed", [issue], [{:failed, "spawn_failed"}]},
      {"dispatch_succeeded", [issue], [:dispatched]}
    ]

    orchestrator_name = Module.concat(__MODULE__, :DispatchFamiliesPresenterOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    Enum.each(cases, fn {expected_result, issues, dispatch_results} ->
      summary = Orchestrator.dispatch_summary_for_test(issues, dispatch_results)
      assert summary.result == expected_result

      :sys.replace_state(pid, fn state ->
        %{state | last_poll_result: expected_result, latest_dispatch_summary: summary}
      end)

      payload = Presenter.state_payload(orchestrator_name, 50)

      assert %{
               polling_diagnostics: %{
                 last_poll_result: ^expected_result,
                 latest_dispatch_summary: %{result: ^expected_result}
               }
             } = payload
    end)
  end

  test "role state presenter exposes dispatch attempted from the live poll path" do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      end

      Application.delete_env(:symphony_elixir, :dispatch_attempt_candidate_issues)
      Application.delete_env(:symphony_elixir, :dispatch_attempt_refetched_issues)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: "project",
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :linear_client_module, DispatchAttemptLinearClient)

    candidate = %Issue{
      id: "issue-attempted-live",
      identifier: "MT-ATTEMPT",
      title: "Attempted live dispatch",
      state: "Todo",
      labels: ["implementation-effort:high"]
    }

    Application.put_env(:symphony_elixir, :dispatch_attempt_candidate_issues, {:ok, [candidate]})
    Application.put_env(:symphony_elixir, :dispatch_attempt_refetched_issues, {:ok, [%{candidate | state: "Done"}]})

    orchestrator_name = Module.concat(__MODULE__, :LiveDispatchAttemptPresenterOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    send(pid, :run_poll_cycle)

    wait_for_snapshot(pid, fn
      %{polling: %{last_poll_result: "dispatch_attempted"}} -> true
      _ -> false
    end)

    assert %{
             polling_diagnostics: %{
               last_poll_result: "dispatch_attempted",
               latest_dispatch_summary: %{
                 result: "dispatch_attempted",
                 candidate_count: 1,
                 dispatched_count: 0,
                 attempted_count: 1,
                 candidate_identifiers: ["MT-ATTEMPT"],
                 dispatched_identifiers: []
               }
             }
           } = Presenter.state_payload(orchestrator_name, 50)
  end

  test "role state presenter exposes candidate fetch failure diagnostics from polling" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: nil,
      poll_interval_ms: 30_000
    )

    orchestrator_name = Module.concat(__MODULE__, :CandidateFetchFailurePresenterOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    wait_for_snapshot(pid, fn
      %{polling: %{last_poll_result: "candidate_fetch_failure"}} -> true
      _ -> false
    end)

    assert %{
             polling_diagnostics: %{
               last_poll_result: "candidate_fetch_failure",
               latest_dispatch_summary: %{
                 result: "candidate_fetch_failure",
                 candidate_count: 0,
                 dispatched_count: 0,
                 attempted_count: 0,
                 candidate_identifiers: [],
                 dispatched_identifiers: [],
                 failure_reason_families: ["missing_tracker_kind"]
               }
             }
           } = Presenter.state_payload(orchestrator_name, 50)
  end

  test "orchestrator restarts stalled workers with retry backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-stall"
    orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL",
      issue: %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"},
      session_id: "thread-stall-turn-stall",
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    before_tick_ms = System.monotonic_time(:millisecond)
    send(pid, :tick)

    # Tick reconciliation completes asynchronously; poll instead of racing it.
    state =
      wait_for_orchestrator_state(pid, fn state ->
        not Map.has_key?(state.running, issue_id) and not Process.alive?(worker_pid)
      end)

    after_state_ms = System.monotonic_time(:millisecond)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-STALL",
             error: "stalled for " <> _
           } = state.retry_attempts[issue_id]

    assert is_integer(due_at_ms)
    assert due_at_ms >= before_tick_ms + 10_000
    assert due_at_ms <= after_state_ms + 10_000
  end

  test "stalled worker restart surfaces quarantined live process ownership on retry status" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stalled-live-process-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue_id = "issue-stalled-live-process"
    issue = %Issue{id: issue_id, identifier: "MT-STALL-LIVE", state: "In Progress"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000,
      workspace_root: workspace_root
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :StalledLiveProcessOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    sleep = System.find_executable("sleep")
    assert is_binary(sleep)
    port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: [~c"5"]])
    {:os_pid, app_server_pid} = :erlang.port_info(port, :os_pid)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_memory_recipient)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf(test_root)
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-stall-live",
      run_id: "run-stall-live",
      workspace_path: Path.join(workspace_root, issue.identifier),
      codex_app_server_pid: app_server_pid,
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)

    # Tick reconciliation completes asynchronously; poll instead of racing it.
    state =
      wait_for_orchestrator_state(pid, fn state ->
        not Map.has_key?(state.running, issue_id) and not Process.alive?(worker_pid)
      end)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)
    assert %{attempt: 1} = state.retry_attempts[issue_id]

    assert_receive {:memory_tracker_claim_lease, ^issue_id, quarantined_lease}, 500
    assert quarantined_lease.state == "quarantined"
    assert quarantined_lease.retry_reason =~ "stalled for "

    snapshot = GenServer.call(pid, :snapshot)

    assert [
             %{
               issue_id: ^issue_id,
               identifier: "MT-STALL-LIVE",
               claim_lease: %{state: "quarantined"},
               process_ownership: %{
                 state: "quarantined",
                 cleanup_status: "quarantined",
                 app_server_pid: ^app_server_pid,
                 live?: true,
                 quarantine_reason: quarantine_reason
               }
             }
           ] = snapshot.retrying

    assert quarantine_reason =~ "agent exited before app-server process cleaned: :terminated"

    refute Orchestrator.should_dispatch_issue_for_test(
             issue,
             %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}
           )
  end

  test "status dashboard renders offline marker to terminal" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = StatusDashboard.render_offline_status()
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  test "status dashboard renders linear project link in header" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "https://linear.app/project/project/issues"
    refute rendered =~ "Dashboard:"
  end

  test "status dashboard renders dashboard url on its own line when server port is configured" do
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "│ Project:"
    assert rendered =~ "https://linear.app/project/project/issues"
    assert rendered =~ "│ Dashboard:"
    assert rendered =~ "http://127.0.0.1:4000/"
  end

  test "status dashboard prefers the bound server port and normalizes wildcard hosts" do
    assert StatusDashboard.dashboard_url_for_test("0.0.0.0", 0, 43_123) ==
             "http://127.0.0.1:43123/"

    assert StatusDashboard.dashboard_url_for_test("::1", 4000, nil) ==
             "http://[::1]:4000/"
  end

  test "status dashboard renders next refresh countdown and checking marker" do
    waiting_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: false, next_poll_in_ms: 2_000, poll_interval_ms: 30_000}
       }}

    waiting_rendered = StatusDashboard.format_snapshot_content_for_test(waiting_snapshot, 0.0)
    assert waiting_rendered =~ "Next refresh:"
    assert waiting_rendered =~ "2s"

    checking_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: 30_000}
       }}

    checking_rendered = StatusDashboard.format_snapshot_content_for_test(checking_snapshot, 0.0)
    assert checking_rendered =~ "checking now…"
  end

  test "status dashboard adds a spacer line before backoff queue when no agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/No active agents\r?\n│\s*\r?\n├─ Backoff queue/
  end

  test "status dashboard adds a spacer line before backoff queue when agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [
           %{
             identifier: "MT-777",
             state: "running",
             session_id: "thread-1234567890",
             codex_app_server_pid: "4242",
             codex_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_codex_event: "turn_completed",
             last_codex_message: %{
               event: :notification,
               message: %{
                 "method" => "turn/completed",
                 "params" => %{"turn" => %{"status" => "completed"}}
               }
             }
           }
         ],
         retrying: [],
         codex_totals: %{
           input_tokens: 90,
           output_tokens: 12,
           total_tokens: 102,
           seconds_running: 75
         },
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/MT-777.*\r?\n│\s*\r?\n├─ Backoff queue/s
  end

  test "status dashboard renders an unstyled closing corner when the retry queue is empty" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered |> String.split("\n") |> List.last() == "╰─"
  end

  test "status dashboard coalesces rapid updates to one render per interval" do
    dashboard_name = Module.concat(__MODULE__, :RenderDashboard)
    parent = self()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    {:ok, pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 16,
        render_fun: fn content ->
          send(parent, {:render, System.monotonic_time(:millisecond), content})
        end
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    StatusDashboard.notify_update(dashboard_name)
    assert_receive {:render, first_render_ms, _content}, 200

    :sys.replace_state(pid, fn state ->
      %{state | last_snapshot_fingerprint: :force_next_change, last_rendered_content: nil}
    end)

    StatusDashboard.notify_update(dashboard_name)
    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:render, second_render_ms, _content}, 200
    assert second_render_ms > first_render_ms
    refute_receive {:render, _third_render_ms, _content}, 60
  end

  test "status dashboard computes rolling 5-second token throughput" do
    assert StatusDashboard.rolling_tps([], 10_000, 0) == 0.0

    assert StatusDashboard.rolling_tps([{9_000, 20}], 10_000, 40) == 20.0

    # sample older than 5s is dropped from the window
    assert StatusDashboard.rolling_tps([{4_900, 10}], 10_000, 90) == 0.0

    tps =
      StatusDashboard.rolling_tps(
        [{9_500, 10}, {9_000, 40}, {8_000, 80}],
        10_000,
        95
      )

    assert tps == 7.5
  end

  test "status dashboard throttles tps updates to once per second" do
    {first_second, first_tps} =
      StatusDashboard.throttled_tps(nil, nil, 10_000, [{9_000, 20}], 40)

    {same_second, same_tps} =
      StatusDashboard.throttled_tps(first_second, first_tps, 10_500, [{9_000, 20}], 200)

    assert same_second == first_second
    assert same_tps == first_tps

    {next_second, next_tps} =
      StatusDashboard.throttled_tps(same_second, same_tps, 11_000, [{10_500, 200}], 260)

    assert next_second == 11
    refute next_tps == same_tps
  end

  test "status dashboard formats timestamps at second precision" do
    dt = ~U[2026-02-15 21:36:38.987654Z]
    assert StatusDashboard.format_timestamp_for_test(dt) == "2026-02-15 21:36:38Z"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for steady throughput" do
    now_ms = 600_000
    current_tokens = 6_000

    samples =
      for timestamp <- 575_000..0//-25_000 do
        {timestamp, div(timestamp, 100)}
      end

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "████████████████████████"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for ramping throughput" do
    now_ms = 600_000

    rates_per_bucket =
      1..24
      |> Enum.map(&(&1 * 2))

    {current_tokens, samples} = graph_samples_from_rates(rates_per_bucket)

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "▁▂▂▂▃▃▃▃▄▄▄▅▅▅▆▆▆▆▇▇▇██▅"
  end

  test "status dashboard keeps historical TPS bars stable within the active bucket" do
    now_ms = 600_000
    current_tokens = 74_400
    next_current_tokens = current_tokens + 120
    samples = graph_samples_for_stability_test(now_ms)

    graph_at_now = StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens)

    graph_next_second =
      StatusDashboard.tps_graph_for_test(samples, now_ms + 1_000, next_current_tokens)

    historical_changes =
      graph_at_now
      |> String.graphemes()
      |> Enum.zip(String.graphemes(graph_next_second))
      |> Enum.take(23)
      |> Enum.count(fn {left, right} -> left != right end)

    assert historical_changes == 0
  end

  test "application configures a rotating file logger handler" do
    assert {:ok, handler_config} = :logger.get_handler_config(:symphony_disk_log)
    assert handler_config.module == :logger_disk_log_h

    disk_config = handler_config.config
    assert disk_config.type == :wrap
    assert is_list(disk_config.file)
    assert disk_config.max_no_bytes > 0
    assert disk_config.max_no_files > 0
  end

  test "status dashboard renders last codex message in EVENT column" do
    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-233",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 12,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              "method" => "turn/completed",
              "params" => %{"turn" => %{"status" => "completed"}}
            }
          }
        },
        115
      )

    plain = Regex.replace(~r/\e\[[\\d;]*m/, row, "")

    assert plain =~ "turn completed (completed)"
    assert (String.split(plain, "turn completed (completed)") |> length()) - 1 == 1
    refute plain =~ " notification "
  end

  test "status dashboard strips ANSI and control bytes from last codex message" do
    payload =
      "cmd: " <>
        <<27>> <>
        "[31mRED" <>
        <<27>> <>
        "[0m" <>
        <<0>> <>
        " after\nline"

    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-898",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 12,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: payload
        },
        115
      )

    plain = Regex.replace(~r/\e\[[0-9;]*m/, row, "")

    assert plain =~ "cmd: RED after line"
    refute plain =~ <<27>>
    refute plain =~ <<0>>
  end

  test "status dashboard expands running row to requested terminal width" do
    terminal_columns = 140

    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-598",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 123,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              "method" => "turn/completed",
              "params" => %{"turn" => %{"status" => "completed"}}
            }
          }
        },
        terminal_columns
      )

    plain = Regex.replace(~r/\e\[[\d;]*m/, row, "")

    assert String.length(plain) == terminal_columns
    assert plain =~ "turn completed (completed)"
  end

  test "status dashboard humanizes full codex app-server event set" do
    event_cases = [
      {"turn/started", %{"params" => %{"turn" => %{"id" => "turn-1"}}}, "turn started"},
      {"turn/completed", %{"params" => %{"turn" => %{"status" => "completed"}}}, "turn completed"},
      {"turn/diff/updated", %{"params" => %{"diff" => "line1\nline2"}}, "turn diff updated"},
      {"turn/plan/updated", %{"params" => %{"plan" => [%{"step" => "a"}, %{"step" => "b"}]}}, "plan updated"},
      {"thread/tokenUsage/updated",
       %{
         "params" => %{
           "usage" => %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11}
         }
       }, "thread token usage updated"},
      {"item/started",
       %{
         "params" => %{
           "item" => %{
             "id" => "item-1234567890abcdef",
             "type" => "commandExecution",
             "status" => "running"
           }
         }
       }, "item started: command execution"},
      {"item/completed", %{"params" => %{"item" => %{"type" => "fileChange", "status" => "completed"}}}, "item completed: file change"},
      {"item/agentMessage/delta", %{"params" => %{"delta" => "hello"}}, "agent message streaming"},
      {"item/plan/delta", %{"params" => %{"delta" => "step"}}, "plan streaming"},
      {"item/reasoning/summaryTextDelta", %{"params" => %{"summaryText" => "thinking"}}, "reasoning summary streaming"},
      {"item/reasoning/summaryPartAdded", %{"params" => %{"summaryText" => "section"}}, "reasoning summary section added"},
      {"item/reasoning/textDelta", %{"params" => %{"textDelta" => "reason"}}, "reasoning text streaming"},
      {"item/commandExecution/outputDelta", %{"params" => %{"outputDelta" => "ok"}}, "command output streaming"},
      {"item/fileChange/outputDelta", %{"params" => %{"outputDelta" => "changed"}}, "file change output streaming"},
      {"item/commandExecution/requestApproval", %{"params" => %{"parsedCmd" => "git status"}}, "command approval requested (git status)"},
      {"item/fileChange/requestApproval", %{"params" => %{"fileChangeCount" => 2}}, "file change approval requested (2 files)"},
      {"item/tool/call", %{"params" => %{"tool" => "linear_graphql"}}, "dynamic tool call requested (linear_graphql)"},
      {"item/tool/requestUserInput", %{"params" => %{"question" => "Continue?"}}, "tool requires user input: Continue?"}
    ]

    Enum.each(event_cases, fn {method, payload, expected_fragment} ->
      message = Map.put(payload, "method", method)

      humanized =
        StatusDashboard.humanize_codex_message(%{event: :notification, message: message})

      assert humanized =~ expected_fragment
    end)
  end

  test "status dashboard humanizes Claude Code normalized stream events" do
    assistant_message = %{
      event: :text_delta,
      message: %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => "Checking status"}]}
      }
    }

    result_message = %{
      event: :turn_completed,
      message: %{
        "type" => "result",
        "subtype" => "success",
        "usage" => %{"input_tokens" => 153, "output_tokens" => 6, "total_tokens" => 159}
      }
    }

    assert StatusDashboard.humanize_codex_message(assistant_message) == "Claude Code: Checking status"

    assert StatusDashboard.humanize_codex_message(result_message) ==
             "Claude Code turn success (in 153, out 6, total 159)"
  end

  test "status dashboard humanizes dynamic tool wrapper events" do
    completed = %{
      event: :tool_call_completed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"name" => "linear_graphql"}}
      }
    }

    failed = %{
      event: :tool_call_failed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "linear_graphql"}}
      }
    }

    unsupported = %{
      event: :unsupported_tool_call,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "unknown_tool"}}
      }
    }

    assert StatusDashboard.humanize_codex_message(completed) =~
             "dynamic tool call completed (linear_graphql)"

    assert StatusDashboard.humanize_codex_message(failed) =~
             "dynamic tool call failed (linear_graphql)"

    assert StatusDashboard.humanize_codex_message(unsupported) =~
             "unsupported dynamic tool call rejected (unknown_tool)"
  end

  test "status dashboard unwraps nested codex payload envelopes" do
    wrapped = %{
      event: :notification,
      message: %{
        payload: %{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{"status" => "completed"},
            "usage" => %{"input_tokens" => "10", "output_tokens" => 2, "total_tokens" => 12}
          }
        },
        raw: "{\"method\":\"turn/completed\"}"
      }
    }

    assert StatusDashboard.humanize_codex_message(wrapped) =~ "turn completed"
    assert StatusDashboard.humanize_codex_message(wrapped) =~ "in 10"
  end

  test "status dashboard uses shell command line as exec command status text" do
    message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => "git status --short"}}
      }
    }

    assert StatusDashboard.humanize_codex_message(message) == "git status --short"
  end

  test "status dashboard formats auto-approval updates from codex" do
    message = %{
      event: :approval_auto_approved,
      message: %{
        payload: %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"parsedCmd" => "mix test"}
        },
        decision: "acceptForSession"
      }
    }

    humanized = StatusDashboard.humanize_codex_message(message)
    assert humanized =~ "command approval requested"
    assert humanized =~ "auto-approved"
  end

  test "status dashboard formats auto-answered tool input updates from codex" do
    message = %{
      event: :tool_input_auto_answered,
      message: %{
        payload: %{
          "method" => "item/tool/requestUserInput",
          "params" => %{"question" => "Continue?"}
        },
        answer: "This is a non-interactive session. Operator input is unavailable."
      }
    }

    humanized = StatusDashboard.humanize_codex_message(message)
    assert humanized =~ "tool requires user input"
    assert humanized =~ "auto-answered"
  end

  test "status dashboard enriches wrapper reasoning and message streaming events with payload context" do
    reasoning_message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{
          "msg" => %{
            "payload" => %{"summaryText" => "compare retry paths for Linear polling"}
          }
        }
      }
    }

    message_delta = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_message_delta",
        "params" => %{
          "msg" => %{
            "payload" => %{"delta" => "writing workpad reconciliation update"}
          }
        }
      }
    }

    fallback_reasoning = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{"msg" => %{"payload" => %{}}}
      }
    }

    assert StatusDashboard.humanize_codex_message(reasoning_message) =~
             "reasoning update: compare retry paths for Linear polling"

    assert StatusDashboard.humanize_codex_message(message_delta) =~
             "agent message streaming: writing workpad reconciliation update"

    assert StatusDashboard.humanize_codex_message(fallback_reasoning) == "reasoning update"
  end

  test "application stop renders offline status" do
    on_exit(fn ->
      {:ok, _apps} = Application.ensure_all_started(:symphony_elixir)
    end)

    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = SymphonyElixir.Application.stop(:normal)
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp receive_claim_lease_state!(issue_id, expected_state, timeout_ms \\ 5_000) do
    receive do
      {:memory_tracker_claim_lease, ^issue_id, lease} ->
        case lease.state do
          ^expected_state -> lease
          _other_state -> receive_claim_lease_state!(issue_id, expected_state, timeout_ms)
        end
    after
      timeout_ms -> flunk("timed out waiting for claim lease state #{expected_state}")
    end
  end

  defp receive_memory_comment_containing!(issue_id, expected_text, timeout_ms \\ 5_000) do
    receive do
      {:memory_tracker_comment, ^issue_id, body} ->
        if String.contains?(body, expected_text) do
          body
        else
          receive_memory_comment_containing!(issue_id, expected_text, timeout_ms)
        end
    after
      timeout_ms -> flunk("timed out waiting for memory tracker comment containing #{expected_text}")
    end
  end

  defp kill_retry_dispatch!(pid, issue_id, reason) do
    running = wait_for_running_entry(pid, issue_id, 5_000)

    Process.exit(running.pid, reason)

    running.claim_lease.run_id
  end

  defp wait_for_running_entry(pid, issue_id, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_running_entry(pid, issue_id, deadline_ms)
  end

  defp do_wait_for_running_entry(pid, issue_id, deadline_ms) do
    case :sys.get_state(pid).running do
      %{^issue_id => %{pid: running_pid, workspace_path: workspace_path} = running_entry}
      when is_pid(running_pid) and is_binary(workspace_path) ->
        running_entry

      _running ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk("timed out waiting for running retry dispatch")
        else
          Process.sleep(5)
          do_wait_for_running_entry(pid, issue_id, deadline_ms)
        end
    end
  end

  defp wait_for_orchestrator_state(pid, predicate, timeout_ms \\ 5_000) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
  end

  defp do_wait_for_orchestrator_state(pid, predicate, deadline_ms) do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator state: #{inspect(Map.take(state, [:running, :claimed, :retry_attempts]))}")
      else
        Process.sleep(5)
        do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
      end
    end
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  defp graph_samples_from_rates(rates_per_bucket) do
    bucket_ms = 25_000

    {timestamp, tokens, samples} =
      Enum.reduce(rates_per_bucket, {0, 0, []}, fn rate, {timestamp, tokens, acc} ->
        next_timestamp = timestamp + bucket_ms
        next_tokens = tokens + trunc(rate * bucket_ms / 1000)
        {next_timestamp, next_tokens, [{timestamp, tokens} | acc]}
      end)

    {tokens, [{timestamp, tokens} | samples]}
  end

  defp graph_samples_for_stability_test(now_ms) do
    rates_per_bucket = Enum.map(1..24, &(&1 * 5))
    bucket_ms = 25_000

    rate_for_timestamp = fn timestamp ->
      bucket_idx = min(div(max(timestamp, 0), bucket_ms), 23)
      Enum.at(rates_per_bucket, bucket_idx, 0)
    end

    0..(now_ms - 1_000)//1_000
    |> Enum.reduce({0, []}, fn timestamp, {tokens, acc} ->
      next_tokens = tokens + rate_for_timestamp.(timestamp)
      {next_tokens, [{timestamp, next_tokens} | acc]}
    end)
    |> elem(1)
  end
end
