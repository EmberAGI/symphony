defmodule SymphonyElixir.OrchestratorLifecycleIsolationTest do
  use SymphonyElixir.TestSupport

  # Cross-test isolation invariant behind the EMB-1180 order-dependent
  # suite flakes: an orchestrator owned by one test must actually be dead
  # once that test releases it. A leaked orchestrator keeps its tick timer,
  # refreshes itself from whatever workflow config the currently running
  # test installed, and claims that test's seeded memory-tracker issues
  # from outside the test's own orchestrator (observed at seeds 613012 and
  # 758170 as stolen retry dispatches and hook fall-through timeouts).
  test "orchestrator released with a :normal exit keeps foraging seeded issues until stop_orchestrator! ends it" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-lifecycle-isolation-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      poll_interval_ms: 25,
      hook_before_run: "sleep 30"
    )

    orchestrator_name = Module.concat(__MODULE__, :ForagingOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> SymphonyElixir.TestSupport.stop_orchestrator!(pid) end)

    # The orchestrator started before this issue existed; only its periodic
    # tick can pick it up, which is exactly how a leaked orchestrator reaches
    # into a later test's seeded issues.
    first_issue = foraging_issue("issue-forage-while-alive")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [first_issue])

    runner_pid = wait_for_running_pid(pid, "issue-forage-while-alive")

    # The pre-fix cleanup pattern: a :normal exit signal to a non-trapping
    # GenServer is a no-op, so the orchestrator survives and keeps polling.
    Process.exit(pid, :normal)
    assert Process.alive?(pid)

    stop_orchestrator!(pid)
    refute Process.alive?(pid)

    # The runner task lives under the app TaskSupervisor and is only
    # monitored by the orchestrator, so it must be released explicitly.
    Process.exit(runner_pid, :kill)

    drain_tracker_messages()

    # A dead orchestrator performs no tracker reads across many would-be 25ms ticks.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      foraging_issue("issue-forage-after-stop")
    ])

    refute_receive {:memory_tracker_fetch_candidate_issues, _issue_ids}, 300
  end

  defp foraging_issue(issue_id) do
    %Issue{
      id: issue_id,
      identifier: String.upcase(issue_id),
      title: "Lifecycle isolation #{issue_id}",
      state: "In Progress",
      labels: [],
      url: "https://linear.app/example/#{issue_id}"
    }
  end

  defp wait_for_running_pid(orchestrator_pid, issue_id, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_for_running_pid(orchestrator_pid, issue_id, deadline)
  end

  defp do_wait_for_running_pid(orchestrator_pid, issue_id, deadline) do
    case :sys.get_state(orchestrator_pid).running do
      %{^issue_id => %{pid: runner_pid}} when is_pid(runner_pid) ->
        runner_pid

      _running ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for the foraged issue's runner to appear")
        else
          Process.sleep(5)
          do_wait_for_running_pid(orchestrator_pid, issue_id, deadline)
        end
    end
  end

  defp drain_tracker_messages do
    receive do
      {:memory_tracker_fetch_candidate_issues, _issue_ids} -> drain_tracker_messages()
      {:memory_tracker_fetch_issue_states_by_ids, _issue_ids} -> drain_tracker_messages()
      {:memory_tracker_state_update, _issue_id, _state} -> drain_tracker_messages()
      {:memory_tracker_label_add, _issue_id, _label} -> drain_tracker_messages()
    after
      0 -> :ok
    end
  end
end
