defmodule SymphonyElixir.RoleStatePresenterPollingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.Presenter

  defmodule DispatchAttemptLinearClient do
    def fetch_candidate_issues do
      Application.fetch_env!(:symphony_elixir, :dispatch_attempt_candidate_issues)
    end

    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_states_by_ids(_issue_ids) do
      Application.fetch_env!(:symphony_elixir, :dispatch_attempt_refetched_issues)
    end
  end

  test "role state presenter exposes polling diagnostics from the default orchestrator snapshot" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 30_000
    )

    orchestrator_name = Module.concat(__MODULE__, :PresenterPollingDiagnosticsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(pid)
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

    payload = Presenter.state_payload(orchestrator_name, 5_000)

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
      stop_orchestrator!(pid)
    end)

    Enum.each(cases, fn {expected_result, issues, dispatch_results} ->
      summary = Orchestrator.dispatch_summary_for_test(issues, dispatch_results)
      assert summary.result == expected_result

      :sys.replace_state(pid, fn state ->
        %{state | last_poll_result: expected_result, latest_dispatch_summary: summary}
      end)

      payload = Presenter.state_payload(orchestrator_name, 5_000)

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
      stop_orchestrator!(pid)
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
           } = Presenter.state_payload(orchestrator_name, 5_000)
  end

  test "role state presenter exposes candidate fetch failure diagnostics from polling" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: nil,
      # No token: the kind-less config must fail before any tracker I/O,
      # keeping even loopback socket churn out of the non-live gate.
      tracker_api_token: nil,
      poll_interval_ms: 30_000
    )

    orchestrator_name = Module.concat(__MODULE__, :CandidateFetchFailurePresenterOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(pid)
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
           } = Presenter.state_payload(orchestrator_name, 5_000)
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
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
end
