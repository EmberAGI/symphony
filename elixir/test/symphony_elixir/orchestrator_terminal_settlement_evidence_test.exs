defmodule SymphonyElixir.OrchestratorTerminalSettlementEvidenceTest do
  # EMB-1259: terminal cleanup settlement must self-produce its process
  # evidence on every terminal path (success, failure, cancellation,
  # timeout/stall) instead of re-deriving it from mutable global state after
  # teardown already destroyed or drifted the sources it reads.
  #
  # Production incident (2026-07-24, run
  # localhost:2812854:implementer:48841fdc-...:10, issue EMB-1258): physical
  # teardown SUCCEEDED (session dir removed, owned pids dead, live_after=0
  # verified by host inspection), yet settlement quarantined the ownership
  # record with
  #   retryable_runtime_failure: owned_session_cleanup_failed
  #   owned_session_cleanup_failed owned_session_process_evidence_unavailable
  # because the post-teardown evidence re-read did not match its exact-match
  # expectations and the mismatch was discarded unrecorded.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  defmodule CleanupProbe do
    @moduledoc """
    Owned-session cleanup double: physical teardown always succeeds and the
    test observes exactly when it ran.
    """

    def cleanup_owned_session(%{notify_pid: notify_pid} = ownership_ref) when is_pid(notify_pid) do
      send(notify_pid, {:cleanup_probe_ran, Map.get(ownership_ref, :session_name)})
      :ok
    end

    def cleanup_owned_session(_ownership_ref), do: :ok
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
    end)

    :ok
  end

  test "cancellation settlement on a physically clean run settles cleaned with self-produced evidence despite issue-refresh drift" do
    test_root = unique_test_root("settlement-cancellation-drift")
    workspace_root = Path.join(test_root, "workspaces")

    issue = %Issue{
      id: "issue-emb-1259-cancel-clean",
      identifier: "MT-1259C",
      title: "Terminal settlement evidence on cancellation",
      state: "In Progress",
      repository: "EmberAGI/demo-repo"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 200,
      hook_before_run: "sleep 30"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :CancellationDriftOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(pid)
      File.rm_rf(test_root)
    end)

    assert_eventually(fn ->
      match?(
        %{running: [%{issue_id: "issue-emb-1259-cancel-clean"} | _]},
        Orchestrator.snapshot(orchestrator_name, 1_000)
      )
    end)

    # The run owns a delegated session whose physical teardown succeeds.
    send(
      pid,
      {:owned_session_runtime_info, issue.id,
       %{
         kind: "test-owned-session",
         session_name: "octo-emb-1259-cancel",
         cleanup_module: CleanupProbe,
         notify_pid: self()
       }}
    )

    # A later lightweight state refresh loses the label-derived repository:
    # the exact evidence re-derivation the settlement performs today now
    # disagrees with the identity the run acquired ownership under.
    drifted_issue = %{issue | repository: nil}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [drifted_issue])

    assert_eventually(fn ->
      case :sys.get_state(pid) do
        %{running: %{"issue-emb-1259-cancel-clean" => %{issue: %Issue{repository: nil}}}} -> true
        _state -> false
      end
    end)

    # The issue then leaves the active states (work routed onward), so the
    # orchestrator cancels the registered role run and settles it.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %{drifted_issue | state: "Agent Review"}
    ])

    assert_receive {:cleanup_probe_ran, "octo-emb-1259-cancel"}, 5_000

    # Physical teardown succeeded and nothing owned survived, so settlement
    # must record clean completion with its own captured evidence — not a
    # typed cleanup failure caused by its own post-teardown re-read.
    status =
      assert_eventually_value(fn ->
        case ProcessOwnership.status_for_issue(issue) do
          %{state: state} = status when state in ["cleaned", "quarantined", "retrying"] -> status
          _other -> nil
        end
      end)

    assert status.state == "cleaned",
           "expected clean terminal settlement, got #{status.state} " <>
             "(quarantine_reason=#{inspect(status.quarantine_reason)})"

    assert %{owned_pids: owned_pids, live_after: 0, verified: true} = status.cleanup_evidence
    assert is_list(owned_pids)
  end

  test "normal task exit records self-produced settlement evidence in the cleaned ownership record" do
    {issue, status} = settle_via_task_down(:normal, "issue-emb-1259-normal", "MT-1259N")

    assert status.state == "cleaned",
           "expected clean terminal settlement for #{issue.identifier}, got #{status.state}"

    assert %{owned_pids: owned_pids, live_after: 0, verified: true} = status.cleanup_evidence
    assert is_list(owned_pids)
  end

  test "abnormal task exit with no surviving owned process records settlement evidence" do
    {issue, status} = settle_via_task_down({:agent_runtime_failed, :boom}, "issue-emb-1259-crash", "MT-1259X")

    assert status.state == "cleaned",
           "expected clean terminal settlement for #{issue.identifier}, got #{status.state}"

    assert %{owned_pids: owned_pids, live_after: 0, verified: true} = status.cleanup_evidence
    assert is_list(owned_pids)
  end

  test "stall termination settles the run with self-produced evidence before scheduling the retry" do
    test_root = unique_test_root("settlement-stall")
    workspace_root = Path.join(test_root, "workspaces")

    issue = %Issue{
      id: "issue-emb-1259-stall",
      identifier: "MT-1259S",
      title: "Terminal settlement evidence on stall",
      state: "In Progress"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 200,
      codex_stall_timeout_ms: 100,
      hook_before_run: "sleep 30"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :StallSettlementOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(pid)
      File.rm_rf(test_root)
    end)

    assert_eventually(fn ->
      match?(
        %{running: [%{issue_id: "issue-emb-1259-stall"} | _]},
        Orchestrator.snapshot(orchestrator_name, 1_000)
      )
    end)

    send(
      pid,
      {:owned_session_runtime_info, issue.id,
       %{
         kind: "test-owned-session",
         session_name: "octo-emb-1259-stall",
         cleanup_module: CleanupProbe,
         notify_pid: self()
       }}
    )

    # The stall reconciler terminates the run once no codex activity lands
    # inside the stall timeout; that termination is a terminal settlement.
    assert_receive {:cleanup_probe_ran, "octo-emb-1259-stall"}, 10_000

    status =
      assert_eventually_value(fn ->
        case ProcessOwnership.status_for_issue(issue) do
          %{cleanup_evidence: %{}} = status -> status
          _other -> nil
        end
      end)

    assert %{owned_pids: owned_pids, live_after: 0, verified: true} = status.cleanup_evidence
    assert is_list(owned_pids)
    refute status.state == "quarantined"
  end

  test "genuine survivors still settle typed: quarantine keeps live_after evidence" do
    test_root = unique_test_root("settlement-survivor")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{
      id: "issue-emb-1259-survivor",
      identifier: "MT-1259L",
      state: "In Progress"
    }

    sleep = System.find_executable("sleep")
    assert is_binary(sleep)
    port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: [~c"30"]])
    {:os_pid, app_server_pid} = :erlang.port_info(port, :os_pid)

    orchestrator_name = Module.concat(__MODULE__, :SurvivorSettlementOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(pid)

      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf(test_root)
    end)

    {:ok, process_ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-emb-1259-survivor",
        holder: ProcessOwnership.holder_id(),
        app_server_pid: app_server_pid
      })

    ref = make_ref()

    install_running_entry(pid, issue, ref, process_ownership, app_server_pid)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    status =
      assert_eventually_value(fn ->
        case ProcessOwnership.status_for_issue(issue) do
          %{state: "quarantined"} = status -> status
          _other -> nil
        end
      end)

    # The typed quarantine remains for genuine inability, and the settlement
    # record still carries the evidence it observed.
    assert %{live_after: live_after, verified: false, owned_pids: owned_pids} = status.cleanup_evidence
    assert live_after >= 1
    assert app_server_pid in owned_pids
  end

  defp settle_via_task_down(down_reason, issue_id, identifier) do
    test_root = unique_test_root("settlement-#{identifier}")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: issue_id, identifier: identifier, state: "In Progress"}

    orchestrator_name = Module.concat(__MODULE__, :"Settlement#{identifier}Orchestrator")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(pid)
      File.rm_rf(test_root)
    end)

    {:ok, process_ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-#{identifier}",
        holder: ProcessOwnership.holder_id()
      })

    ref = make_ref()
    install_running_entry(pid, issue, ref, process_ownership, nil)

    send(pid, {:DOWN, ref, :process, self(), down_reason})

    status =
      assert_eventually_value(fn ->
        case ProcessOwnership.status_for_issue(issue) do
          %{state: state} = status when state in ["cleaned", "quarantined", "retrying"] -> status
          _other -> nil
        end
      end)

    {issue, status}
  end

  defp install_running_entry(pid, issue, ref, process_ownership, app_server_pid) do
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      run_id: process_ownership.run_id,
      process_ownership: process_ownership,
      codex_app_server_pid: app_server_pid,
      owned_session_ref: %{
        kind: "test-owned-session",
        session_name: "octo-#{issue.identifier |> String.downcase()}",
        cleanup_module: CleanupProbe,
        notify_pid: self(),
        issue_id: issue.id
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue.id]))
      |> Map.put(:retry_attempts, %{})
    end)
  end

  defp unique_test_root(label) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-#{label}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually_value(fun, attempts \\ 100)

  defp assert_eventually_value(fun, 0) do
    value = fun.()
    assert value, "condition did not produce a value in time"
    value
  end

  defp assert_eventually_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(50)
        assert_eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end
end
