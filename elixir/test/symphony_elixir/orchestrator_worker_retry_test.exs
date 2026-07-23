defmodule SymphonyElixir.OrchestratorWorkerRetryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  test "abnormal worker exit writes compact run-scoped retry evidence" do
    previous_run_log_root = Application.get_env(:symphony_elixir, :run_log_root)

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

      stop_orchestrator!(pid)
    end)

    Application.put_env(:symphony_elixir, :run_log_root, run_log_root)
    initial_state = :sys.get_state(pid)
    long_detail = String.duplicate("run-log-detail-", 500)
    reason = {:shutdown, {:agent_failed, long_detail}}

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
    Process.sleep(50)

    assert %{attempt: 2, due_at_ms: due_at_ms} = :sys.get_state(pid).retry_attempts[issue_id]
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
    assert event["reason"] =~ "agent exited: retryable_runtime_failure"
    refute event["reason"] =~ long_detail
    assert String.length(event["reason"]) < 260
    assert event["retry"]["attempt"] == 2
    assert event["retry"]["delay_ms"] == 20_000
    assert event["retry"]["due_at_ms"] == due_at_ms
    assert event["retry"]["lease_state"] == "retrying"
    assert event["retry"]["claim_lease_state"] == "retrying"
    assert is_binary(event["timestamp"])
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
end
