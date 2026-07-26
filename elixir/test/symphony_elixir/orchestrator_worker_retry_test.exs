defmodule SymphonyElixir.OrchestratorWorkerRetryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.Runtime.ProcessOwnership

  test "abnormal worker exit writes compact run-scoped retry evidence" do
    previous_run_log_root = Application.get_env(:symphony_elixir, :run_log_root)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-retry-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    run_log_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-log-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-crash-run-log"
    run_id = "run-crash-log"
    session_id = "session-crash-log"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRunLogOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      restore_app_env(:run_log_root, previous_run_log_root)
      File.rm_rf(run_log_root)
      File.rm_rf(workspace_root)

      stop_orchestrator!(pid)
    end)

    Application.put_env(:symphony_elixir, :run_log_root, run_log_root)
    initial_state = :sys.get_state(pid)
    long_detail = String.duplicate("run-log-detail-", 500)
    reason = {:agent_runtime_failed, {:network_error, %{message: long_detail}}}

    issue = %Issue{id: issue_id, identifier: "MT-RUN-LOG", state: "In Progress"}

    assert {:ok, process_ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: run_id,
               holder: ProcessOwnership.holder_id()
             })

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-RUN-LOG",
      retry_attempt: 1,
      issue: issue,
      run_id: run_id,
      process_ownership: process_ownership,
      session_id: session_id,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), reason})

    # Terminal settlement runs off the serial path (EMB-1260); poll for the
    # scheduled retry instead of a fixed sleep. Assertions below are unchanged.
    state =
      wait_for_orchestrator_state(pid, fn state ->
        Map.has_key?(state.retry_attempts, issue_id) or
          Map.has_key?(state.blocked_failures, issue_id)
      end)

    assert %{attempt: 2, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    run_log_path = Path.join([run_log_root, "MT-RUN-LOG", "#{run_id}.jsonl"])
    assert File.exists?(run_log_path)

    [event] =
      run_log_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert event["event"] == "agent_retry_scheduled"
    assert event["issue_id"] == issue_id
    assert event["issue_identifier"] == "MT-RUN-LOG"
    assert event["run_id"] == run_id
    assert event["session_id"] == session_id
    assert event["attempt"] == 1
    assert event["reason"] =~ "agent exited: transient_runtime_failure"
    refute event["reason"] =~ long_detail
    assert String.length(event["reason"]) < 260
    assert event["retry"]["attempt"] == 2
    assert event["retry"]["delay_ms"] == 20_000
    assert event["retry"]["due_at_ms"] == due_at_ms
    assert event["retry"]["lease_state"] == "retrying"
    assert event["retry"]["claim_lease_state"] == "retrying"
    assert is_binary(event["timestamp"])
  end

  test "the first equivalent retry is blocked before redispatch" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    unique = System.unique_integer([:positive])
    issue_id = "issue-equivalent-redispatch-#{unique}"
    workspace_root = Path.join(System.tmp_dir!(), "symphony-equivalent-redispatch-#{unique}")

    issue = %Issue{
      id: issue_id,
      identifier: "MT-EQUIVALENT-#{unique}",
      title: "Equivalent retry must stop",
      description: "unchanged input",
      state: "In Progress"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(workspace_root)
    end)

    workspace_path = Path.join(workspace_root, issue.identifier)

    assert {:ok, ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-equivalent-redispatch",
               holder: ProcessOwnership.holder_id(),
               workspace_path: workspace_path
             })

    running_entry = %{
      identifier: issue.identifier,
      issue: issue,
      run_id: ownership.run_id,
      workspace_path: workspace_path,
      process_ownership: ownership
    }

    state = %Orchestrator.State{
      execution_generation: "generation-equivalent",
      max_concurrent_agents: 0,
      claimed: MapSet.new([issue_id]),
      failure_observations: %{}
    }

    assert {:retryable, _failure, observation} =
             Orchestrator.classify_task_exit_for_test(
               {:network_error, :econnreset},
               running_entry,
               issue_id,
               state
             )

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, durable_ownership} =
             ProcessOwnership.verify_and_update(issue, identity, %{
               state: "retrying",
               failure_observation: observation
             })

    state = %{state | failure_observations: %{issue_id => observation}}

    assert {:noreply, blocked} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{
               identifier: issue.identifier,
               issue: issue,
               workspace_path: workspace_path,
               run_id: ownership.run_id,
               process_ownership: durable_ownership,
               failure_observation: observation
             })

    refute Map.has_key?(blocked.running, issue_id)
    refute Map.has_key?(blocked.retry_attempts, issue_id)
    assert blocked.blocked_failures[issue_id].family == :repeated_identical_no_progress_failure
    assert ProcessOwnership.status_for_issue(issue).state == "blocked"
  end

  test "a normal exit after a failed retry preserves the typed failure instead of recording completion" do
    unique = System.unique_integer([:positive])
    issue_id = "issue-retry-success-laundering-#{unique}"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-RETRY-SUCCESS-#{unique}",
      title: "Retry success must not launder failure",
      description: "unchanged input",
      state: "In Progress"
    }

    assert {:ok, ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-retry-success",
               holder: ProcessOwnership.holder_id()
             })

    failure_state = %Orchestrator.State{execution_generation: "generation-stable"}

    failure_entry = %{
      identifier: issue.identifier,
      issue: issue,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path,
      process_ownership: ownership
    }

    assert {:retryable, _failure, observation} =
             Orchestrator.classify_task_exit_for_test(
               {:network_error, :econnreset},
               failure_entry,
               issue_id,
               failure_state
             )

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, ownership} =
             ProcessOwnership.verify_and_update(issue, identity, %{
               state: "active",
               failure_observation: observation
             })

    ref = make_ref()

    running_entry = %{
      pid: nil,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      run_id: ownership.run_id,
      process_ownership: ownership,
      retry_attempt: 1,
      started_at: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      execution_generation: "generation-stable",
      running: %{issue_id => running_entry},
      claimed: MapSet.new([issue_id]),
      completed: MapSet.new(),
      failure_observations: %{issue_id => observation},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    updated = drive_down_settlement(state, ref, :normal)

    refute MapSet.member?(updated.completed, issue_id)
    refute Map.has_key?(updated.retry_attempts, issue_id)
    durable_observation = updated.failure_observations[issue_id]
    assert durable_observation.fingerprint.family == :repeated_identical_no_progress_failure
    assert durable_observation.fingerprint.summary =~ "transient_runtime_failure"
    assert updated.blocked_failures[issue_id].family == :repeated_identical_no_progress_failure

    assert %{state: "blocked", failure_observation: ^durable_observation} =
             ProcessOwnership.status_for_issue(issue)
  end

  test "a restarted stale retry takeover with attempt zero cannot launder an unchanged failure" do
    unique = System.unique_integer([:positive])
    issue_id = "issue-restarted-retry-success-laundering-#{unique}"
    dead_holder = "#{ProcessOwnership.current_host()}:999999:implementer"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-RESTARTED-RETRY-SUCCESS-#{unique}",
      title: "Restarted retry success must not launder failure",
      description: "unchanged input",
      state: "In Progress"
    }

    assert {:ok, failed_ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-before-service-restart",
               holder: dead_holder
             })

    failure_state = %Orchestrator.State{execution_generation: "generation-stable"}

    failure_entry = %{
      identifier: issue.identifier,
      issue: issue,
      run_id: failed_ownership.run_id,
      workspace_path: failed_ownership.workspace_path,
      process_ownership: failed_ownership
    }

    assert {:retryable, _failure, observation} =
             Orchestrator.classify_task_exit_for_test(
               {:network_error, :econnreset},
               failure_entry,
               issue_id,
               failure_state
             )

    failed_identity = %{
      holder: failed_ownership.holder,
      run_id: failed_ownership.run_id,
      workspace_path: failed_ownership.workspace_path
    }

    assert {:ok, %{state: "retrying", failure_observation: ^observation}} =
             ProcessOwnership.verify_and_update(issue, failed_identity, %{
               state: "retrying",
               failure_observation: observation
             })

    assert {:ok, %{state: "active", failure_observation: ^observation} = ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-after-service-restart",
               holder: ProcessOwnership.holder_id()
             })

    ref = make_ref()

    running_entry = %{
      pid: nil,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      run_id: ownership.run_id,
      process_ownership: ownership,
      retry_attempt: 0,
      started_at: DateTime.utc_now()
    }

    assert running_entry.retry_attempt == 0

    state = %Orchestrator.State{
      execution_generation: "generation-stable",
      running: %{issue_id => running_entry},
      claimed: MapSet.new([issue_id]),
      completed: MapSet.new(),
      failure_observations: %{issue_id => observation},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    updated = drive_down_settlement(state, ref, :normal)

    refute MapSet.member?(updated.completed, issue_id)
    refute Map.has_key?(updated.retry_attempts, issue_id)
    durable_observation = updated.failure_observations[issue_id]
    assert durable_observation.fingerprint.family == :repeated_identical_no_progress_failure
    assert updated.blocked_failures[issue_id].family == :repeated_identical_no_progress_failure

    assert %{state: "blocked", failure_observation: ^durable_observation} =
             ProcessOwnership.status_for_issue(issue)
  end

  test "an allowlisted retry with changed reset evidence settles successfully and clears the old observation" do
    unique = System.unique_integer([:positive])
    issue_id = "issue-reset-retry-success-#{unique}"

    failed_issue = %Issue{
      id: issue_id,
      identifier: "MT-RESET-SUCCESS-#{unique}",
      title: "Reset retry may settle",
      description: "checkpoint before input repair",
      state: "In Progress"
    }

    assert {:ok, ownership} =
             ProcessOwnership.acquire(failed_issue, %{
               role: "implementer",
               run_id: "run-reset-success",
               holder: ProcessOwnership.holder_id()
             })

    failure_state = %Orchestrator.State{execution_generation: "generation-reset"}

    failure_entry = %{
      identifier: failed_issue.identifier,
      issue: failed_issue,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path,
      process_ownership: ownership
    }

    assert {:retryable, _failure, observation} =
             Orchestrator.classify_task_exit_for_test(
               {:network_error, :econnreset},
               failure_entry,
               issue_id,
               failure_state
             )

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, ownership} =
             ProcessOwnership.verify_and_update(failed_issue, identity, %{
               state: "active",
               failure_observation: observation
             })

    repaired_issue = %{failed_issue | description: "checkpoint after input repair"}
    ref = make_ref()

    running_entry = %{
      pid: nil,
      ref: ref,
      identifier: repaired_issue.identifier,
      issue: repaired_issue,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path,
      process_ownership: ownership,
      retry_attempt: 1,
      started_at: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      execution_generation: "generation-reset",
      running: %{issue_id => running_entry},
      claimed: MapSet.new([issue_id]),
      completed: MapSet.new(),
      failure_observations: %{issue_id => observation},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    updated = drive_down_settlement(state, ref, :normal)

    assert MapSet.member?(updated.completed, issue_id)
    assert %{delay_type: :continuation} = updated.retry_attempts[issue_id]
    refute Map.has_key?(updated.failure_observations, issue_id)

    assert %{state: "retrying", failure_observation: nil} =
             ProcessOwnership.status_for_issue(repaired_issue)
  end

  test "a continuation retry is not blocked by a stale failure observation" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    unique = System.unique_integer([:positive])
    issue_id = "issue-continuation-stale-observation-#{unique}"
    workspace_root = Path.join(System.tmp_dir!(), "symphony-continuation-stale-#{unique}")

    issue = %Issue{
      id: issue_id,
      identifier: "MT-CONTINUATION-#{unique}",
      title: "Continuation ignores stale failure",
      description: "completed turn",
      state: "In Progress"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(workspace_root)
    end)

    assert {:ok, ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-continuation-stale",
               holder: ProcessOwnership.holder_id()
             })

    context = %{
      issue_id: issue_id,
      workspace_path: ownership.workspace_path,
      role: "implementer",
      provider: :codex,
      execution_generation: "generation-continuation",
      input_fingerprint: "completed-checkpoint"
    }

    assert {observation, {:retryable, _failure}} =
             AgentRuntime.record_failure_observation(nil, {:network_error, :econnreset}, context)

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, ownership} =
             ProcessOwnership.verify_and_update(issue, identity, %{
               state: "retrying",
               failure_observation: observation
             })

    state = %Orchestrator.State{
      execution_generation: "generation-continuation",
      max_concurrent_agents: 0,
      claimed: MapSet.new([issue_id]),
      failure_observations: %{issue_id => observation}
    }

    assert {:noreply, updated} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{
               identifier: issue.identifier,
               issue: issue,
               workspace_path: ownership.workspace_path,
               run_id: ownership.run_id,
               process_ownership: ownership,
               delay_type: :continuation
             })

    refute Map.has_key?(updated.blocked_failures, issue_id)

    assert %{delay_type: :continuation, failure_observation: nil} =
             updated.retry_attempts[issue_id]
  end

  test "a nil running workspace uses durable ownership for the failure fingerprint" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    unique = System.unique_integer([:positive])
    issue_id = "issue-nil-workspace-#{unique}"
    workspace_root = Path.join(System.tmp_dir!(), "symphony-nil-workspace-#{unique}")

    issue = %Issue{
      id: issue_id,
      identifier: "MT-NIL-WORKSPACE-#{unique}",
      title: "Durable workspace fallback",
      description: "unchanged input",
      state: "In Progress"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(workspace_root)
    end)

    workspace_path = Path.join(workspace_root, issue.identifier)

    assert {:ok, ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-nil-workspace",
               holder: ProcessOwnership.holder_id(),
               workspace_path: workspace_path
             })

    running_entry = %{
      identifier: issue.identifier,
      issue: issue,
      run_id: ownership.run_id,
      workspace_path: nil,
      process_ownership: ownership
    }

    state = %Orchestrator.State{
      execution_generation: "generation-nil-workspace",
      max_concurrent_agents: 0,
      claimed: MapSet.new([issue_id])
    }

    assert {:retryable, _failure, observation} =
             Orchestrator.classify_task_exit_for_test(
               {:network_error, :econnreset},
               running_entry,
               issue_id,
               state
             )

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, durable_ownership} =
             ProcessOwnership.verify_and_update(issue, identity, %{
               state: "retrying",
               failure_observation: observation
             })

    assert {:noreply, blocked} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{
               identifier: issue.identifier,
               issue: issue,
               workspace_path: nil,
               run_id: ownership.run_id,
               process_ownership: durable_ownership,
               failure_observation: observation
             })

    assert blocked.blocked_failures[issue_id].family ==
             :repeated_identical_no_progress_failure
  end

  test "changed issue evidence reacquires a live blocked record without a service restart" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    unique = System.unique_integer([:positive])
    issue_id = "issue-blocked-reset-#{unique}"
    workspace_root = Path.join(System.tmp_dir!(), "symphony-blocked-reset-#{unique}")
    orchestrator_name = Module.concat(__MODULE__, :"BlockedReset#{unique}")

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BLOCKED-RESET-#{unique}",
      title: "Changed input releases blocked ownership",
      description: "unchanged durable input",
      state: "In Progress"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000,
      hook_before_run: "sleep 30"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-blocked-reset"
      )

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      stop_orchestrator!(pid)
      File.rm_rf(workspace_root)
    end)

    assert {:ok, ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-blocked-reset",
               holder: ProcessOwnership.holder_id()
             })

    ref = make_ref()

    running_entry = %{
      pid: nil,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path,
      process_ownership: ownership,
      retry_attempt: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{issue_id => running_entry},
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }
    end)

    send(pid, {
      :DOWN,
      ref,
      :process,
      self(),
      {:missing_required_tool_or_cli, %{tool: "provider-cli", message: "not installed"}}
    })

    blocked =
      wait_for_orchestrator_state(pid, fn state ->
        Map.has_key?(state.blocked_failures, issue_id)
      end)

    assert %{state: "blocked", failure_observation: blocked_observation} =
             ProcessOwnership.status_for_issue(issue)

    assert blocked.blocked_failures[issue_id].family == :missing_required_tool_or_cli

    escalated_issue = %{issue | labels: ["Human Escalation"]}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [escalated_issue])
    flush_candidate_fetch_events()
    completed_at = blocked.last_poll_completed_at
    send(pid, :run_poll_cycle)
    assert_receive {:memory_tracker_fetch_candidate_issues, [^issue_id]}

    unchanged =
      wait_for_orchestrator_state(pid, fn state ->
        state.last_poll_completed_at != completed_at
      end)

    refute Map.has_key?(unchanged.running, issue_id)
    assert Map.has_key?(unchanged.blocked_failures, issue_id)
    assert MapSet.member?(unchanged.claimed, issue_id)
    assert unchanged.latest_dispatch_summary.skip_reason_families == ["already_claimed"]

    assert %{state: "blocked", failure_observation: ^blocked_observation} =
             ProcessOwnership.status_for_issue(issue)

    repaired_issue = %{escalated_issue | description: "changed durable repair input"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [repaired_issue])
    flush_candidate_fetch_events()
    send(pid, :run_poll_cycle)
    assert_receive {:memory_tracker_fetch_candidate_issues, [^issue_id]}

    redispatched =
      wait_for_orchestrator_state(pid, fn state ->
        match?(%{pid: runner_pid} when is_pid(runner_pid), state.running[issue_id])
      end)

    running_retry = redispatched.running[issue_id]
    assert running_retry.retry_attempt == 1
    assert Process.alive?(running_retry.pid)
    refute Map.has_key?(redispatched.blocked_failures, issue_id)

    assert %{state: "active", failure_observation: ^blocked_observation} =
             ProcessOwnership.status_for_issue(repaired_issue)

    stop_orchestrator!(pid)
    assert :ok = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, running_retry.pid)
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
      stop_orchestrator!(pid)
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

  test "stalled worker cleanup removes exact-marker descendants before retry" do
    if File.dir?("/proc") do
      previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
      previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
      issue_id = "issue-stall-owned-marker"
      issue = %Issue{id: issue_id, identifier: "MT-STALL-MARKER", state: "In Progress"}

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_stall_timeout_ms: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :StalledOwnedMarkerOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      assert {:ok, ownership} =
               ProcessOwnership.acquire(issue, %{
                 role: "implementer",
                 run_id: "run-stall-owned-marker",
                 holder: ProcessOwnership.holder_id()
               })

      owned_port = start_owned_process(ProcessOwnership.ownership_env(issue, ownership))
      {:os_pid, owned_shell_pid} = Port.info(owned_port, :os_pid)

      worker_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        signal_test_pid(owned_shell_pid, "KILL")
        close_port(owned_port)
        stop_orchestrator!(orchestrator_pid)
      end)

      assert_eventually(fn ->
        case ProcessOwnership.status_for_issue(issue) do
          %{ownership_env_pids: pids} -> owned_shell_pid in pids and length(pids) >= 2
          _ -> false
        end
      end)

      stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
      initial_state = :sys.get_state(orchestrator_pid)

      running_entry = %{
        pid: worker_pid,
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        run_id: ownership.run_id,
        process_ownership: ownership,
        last_codex_timestamp: stale_activity_at,
        started_at: stale_activity_at
      }

      :sys.replace_state(orchestrator_pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      end)

      send(orchestrator_pid, :tick)

      state =
        wait_for_orchestrator_state(orchestrator_pid, fn state ->
          not Map.has_key?(state.running, issue_id) and
            match?(%{attempt: 1}, state.retry_attempts[issue_id])
        end)

      refute Process.alive?(worker_pid)
      assert state.retry_attempts[issue_id].process_ownership.state == "retrying"
      assert_eventually(fn -> !os_process_alive?(owned_shell_pid) end)

      assert %{state: "retrying", ownership_env_pids: []} =
               ProcessOwnership.status_for_issue(issue)
    else
      assert true
    end
  end

  test "stalled cleanup failure replaces timeout retry evidence and suppresses dispatch" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    unique = System.unique_integer([:positive])
    issue_id = "issue-stall-marker-cleanup-failure-#{unique}"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-STALL-CLEANUP-FAIL-#{unique}",
      state: "In Progress"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :StalledMarkerCleanupFailureOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    assert {:ok, ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-stall-cleanup-failure",
               holder: ProcessOwnership.holder_id()
             })

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      stop_orchestrator!(orchestrator_pid)

      _ =
        ProcessOwnership.release(issue, %{
          holder: ownership.holder,
          run_id: ownership.run_id,
          workspace_path: ownership.workspace_path
        })
    end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(orchestrator_pid)
    stale_ownership = %{ownership | run_id: "wrong-run"}

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_id: ownership.run_id,
      process_ownership: stale_ownership,
      last_codex_timestamp: stale_activity_at,
      started_at: stale_activity_at
    }

    :sys.replace_state(orchestrator_pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(orchestrator_pid, :tick)

    state =
      wait_for_orchestrator_state(orchestrator_pid, fn state ->
        not Map.has_key?(state.running, issue_id) and
          (Map.has_key?(state.retry_attempts, issue_id) or
             Map.has_key?(state.blocked_failures, issue_id))
      end)

    refute Process.alive?(worker_pid)

    assert %{fingerprint: fingerprint} = state.failure_observations[issue_id]
    assert is_map(fingerprint)

    refute Map.has_key?(state.retry_attempts, issue_id)
    assert state.blocked_failures[issue_id].family == :unclassified_runtime_failure
    assert state.blocked_failures[issue_id].subtype == "owned_process_cleanup_failed"
  end

  test "abnormal DOWN cleanup removes exact-marker descendants before classification" do
    if File.dir?("/proc") do
      issue_id = "issue-down-owned-marker"
      issue = %Issue{id: issue_id, identifier: "MT-DOWN-MARKER", state: "In Progress"}

      assert {:ok, ownership} =
               ProcessOwnership.acquire(issue, %{
                 role: "implementer",
                 run_id: "run-down-owned-marker",
                 holder: ProcessOwnership.holder_id()
               })

      owned_port = start_owned_process(ProcessOwnership.ownership_env(issue, ownership))
      {:os_pid, owned_shell_pid} = Port.info(owned_port, :os_pid)

      on_exit(fn ->
        signal_test_pid(owned_shell_pid, "KILL")
        close_port(owned_port)
      end)

      assert_eventually(fn ->
        case ProcessOwnership.status_for_issue(issue) do
          %{ownership_env_pids: pids} -> owned_shell_pid in pids and length(pids) >= 2
          _ -> false
        end
      end)

      ref = make_ref()

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            run_id: ownership.run_id,
            process_ownership: ownership,
            retry_attempt: 1,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        completed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      # Terminal settlement is off the serial path (EMB-1260): the DOWN
      # handler dispatches it and finalizes on the settlement-result message.
      # Drive that message through handle_info so the direct-call test observes
      # the same finalized state a live loop would, with assertions unchanged.
      updated = drive_down_settlement(state, ref, {:shutdown, :owned_marker_failure})

      refute Map.has_key?(updated.retry_attempts, issue_id)
      assert updated.blocked_failures[issue_id].family == :unclassified_runtime_failure
      assert_eventually(fn -> !os_process_alive?(owned_shell_pid) end)

      assert %{state: "blocked", ownership_env_pids: []} =
               ProcessOwnership.status_for_issue(issue)
    else
      assert true
    end
  end

  test "marker cleanup failure replaces normal DOWN with a typed failed run" do
    issue_id = "issue-down-marker-cleanup-failure"
    issue = %Issue{id: issue_id, identifier: "MT-DOWN-CLEANUP-FAIL", state: "In Progress"}

    assert {:ok, ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-down-cleanup-failure",
               holder: ProcessOwnership.holder_id()
             })

    stale_ownership = %{ownership | run_id: "wrong-run"}
    ref = make_ref()

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          run_id: ownership.run_id,
          process_ownership: stale_ownership,
          retry_attempt: 1,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    log =
      capture_log(fn ->
        # Terminal settlement is off the serial path (EMB-1260): the DOWN
        # handler dispatches it and finalizes on the settlement-result message.
        # Drive that message through handle_info so the direct-call test observes
        # the same finalized state a live loop would, with assertions unchanged.
        updated = drive_down_settlement(state, ref, :normal)

        refute MapSet.member?(updated.completed, issue_id)

        assert Map.has_key?(updated.retry_attempts, issue_id) or
                 Map.has_key?(updated.blocked_failures, issue_id)
      end)

    assert log =~ "Role-run terminal cleanup failed issue_id=#{issue_id}"
    assert log =~ "owned_process_cleanup_failed"
    refute log =~ "Agent task completed for issue_id=#{issue_id}"
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

      stop_orchestrator!(pid)

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

    assert {:ok, process_ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-stall-live",
               holder: ProcessOwnership.holder_id(),
               workspace_path: Path.join(workspace_root, issue.identifier),
               app_server_pid: app_server_pid
             })

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-stall-live",
      run_id: "run-stall-live",
      process_ownership: process_ownership,
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

    snapshot = GenServer.call(pid, :snapshot)

    assert [
             %{
               issue_id: ^issue_id,
               identifier: "MT-STALL-LIVE",
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

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp start_owned_process(env) do
    Port.open({:spawn_executable, System.find_executable("bash")}, [
      :binary,
      :exit_status,
      args: [~c"-lc", ~c"trap '' TERM; while :; do sleep 300; done"],
      env:
        Enum.map(env, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)
    ])
  end

  defp signal_test_pid(pid, signal) do
    _ = System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  # Drive an off-loop terminal settlement to completion for direct-handle_info
  # tests: dispatch the DOWN, then feed the {:settlement_result, ...} message the
  # settlement task sends back through handle_info, exactly as a live GenServer
  # loop would, and return the finalized state.
  defp drive_down_settlement(state, ref, reason) do
    assert {:noreply, dispatched} =
             Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)

    receive do
      {:settlement_result, _token, _result} = message ->
        assert {:noreply, finalized} = Orchestrator.handle_info(message, dispatched)
        finalized
    after
      5_000 -> flunk("terminal settlement did not report its result in time")
    end
  end

  defp wait_for_orchestrator_state(pid, predicate, timeout_ms \\ 5_000) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
  end

  defp flush_candidate_fetch_events do
    receive do
      {:memory_tracker_fetch_candidate_issues, _issue_ids} ->
        flush_candidate_fetch_events()
    after
      0 -> :ok
    end
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
end
