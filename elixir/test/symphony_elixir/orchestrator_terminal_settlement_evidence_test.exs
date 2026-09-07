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

  defmodule OrderingProbe do
    @moduledoc """
    Owned-session cleanup double that records when physical teardown ran, so
    the test can order it against the settlement's own process-table reads.
    """

    def cleanup_owned_session(%{events_path: events_path, notify_pid: notify_pid} = ownership_ref)
        when is_binary(events_path) and is_pid(notify_pid) do
      File.write!(events_path, "teardown\n", [:append])
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
    envelope = current_run_envelope(orchestrator_name, issue.id)

    send(
      pid,
      {:owned_session_runtime_info, issue.id, envelope,
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
    {status, states} = await_settlement_status(issue)

    assert status.state == "cleaned",
           "expected clean terminal settlement, got #{status.state} " <>
             "(quarantine_reason=#{inspect(status.quarantine_reason)})"

    refute "quarantined" in states,
           "settlement must never pass through a fabricated quarantine; observed #{inspect(states)}"

    assert %{owned_pids: owned_pids, live_after: 0, verified: true, evidence_status: :captured} =
             status.cleanup_evidence

    # `live_after: 0` above is the platform-stable proof that nothing this run
    # owned survived teardown: liveness is decided by the `ps`-based
    # process-table read, which works on every supported host. `owned_pids` is
    # the PRE-teardown capture, so on a run whose `hook_before_run` owned real
    # processes it is never empty. Asserting it empty read the snapshot as if
    # it were the survivor set, and held only where the `/proc` ownership sweep
    # that populates it is inert — exactly the tautology this file warns about
    # for evidence-content assertions.
    if File.dir?("/proc") do
      refute owned_pids == [],
             "the capture must record the hook processes this run owned before teardown"
    end
  end

  # Terminal settlement must RELEASE the ownership record, not merely stop
  # quarantining it. The continuation/retry lease scheduled immediately
  # afterwards legitimately re-marks the released record "retrying", so the
  # released state is transient and a single late read cannot tell a
  # settlement that released from one that never did — both read "retrying".
  # The observed transition list asserts the release itself and tolerates the
  # lease that follows it.
  test "normal task exit releases the ownership record and logs verified cleanup evidence" do
    {issue, status, states, log} = settle_via_task_down(:normal, "issue-emb-1259-normal", "MT-1259N")

    assert "cleaned" in states,
           "terminal settlement must release the ownership record for #{issue.identifier}; " <>
             "observed states=#{inspect(states)} (a record that never reaches \"cleaned\" was never released)"

    refute "quarantined" in states,
           "expected clean terminal settlement for #{issue.identifier}, observed #{inspect(states)} " <>
             "(quarantine_reason=#{inspect(status.quarantine_reason)})"

    assert %{owned_pids: owned_pids, live_after: 0, verified: true, evidence_status: :captured} =
             status.cleanup_evidence

    assert owned_pids == [], "no owned pid existed for this run, got #{inspect(owned_pids)}"

    assert_verified_cleanup_logged(log, issue)
  end

  test "abnormal task exit releases the ownership record and logs verified cleanup evidence" do
    {issue, status, states, log} =
      settle_via_task_down({:agent_runtime_failed, :boom}, "issue-emb-1259-crash", "MT-1259X")

    assert "cleaned" in states,
           "terminal settlement must release the ownership record for #{issue.identifier}; " <>
             "observed states=#{inspect(states)} (a record that never reaches \"cleaned\" was never released)"

    refute "quarantined" in states,
           "expected clean terminal settlement for #{issue.identifier}, observed #{inspect(states)} " <>
             "(quarantine_reason=#{inspect(status.quarantine_reason)})"

    assert %{owned_pids: owned_pids, live_after: 0, verified: true, evidence_status: :captured} =
             status.cleanup_evidence

    assert owned_pids == [], "no owned pid existed for this run, got #{inspect(owned_pids)}"

    assert_verified_cleanup_logged(log, issue)
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
      codex_stall_timeout_ms: 60_000,
      hook_before_run: "touch .hook-ready; sleep 30"
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

    workspace_path =
      assert_eventually_value(fn ->
        case Orchestrator.snapshot(orchestrator_name, 1_000) do
          %{running: [%{issue_id: issue_id, workspace_path: path} | _]} = _snapshot
          when issue_id == issue.id and is_binary(path) ->
            path

          _ ->
            nil
        end
      end)

    assert_eventually(fn -> File.exists?(Path.join(workspace_path, ".hook-ready")) end)

    envelope = current_run_envelope(orchestrator_name, issue.id)
    ack_ref = make_ref()

    send(
      pid,
      {:owned_session_runtime_info, issue.id, envelope,
       %{
         kind: "test-owned-session",
         session_name: "octo-emb-1259-stall",
         cleanup_module: CleanupProbe,
         notify_pid: self()
       }, self(), ack_ref}
    )

    assert_receive {:owned_session_runtime_info_ack, ^ack_ref}, 1_000

    # Finish the real run-envelope and cleanup-probe setup while the generous
    # arrangement timeout still applies. Only then arm the unchanged short
    # stall threshold; the next normal poll refreshes this runtime config.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 200,
      codex_stall_timeout_ms: 100,
      hook_before_run: "touch .hook-ready; sleep 30"
    )

    # The stall reconciler terminates the run once no codex activity lands
    # inside the stall timeout; that termination is a terminal settlement.
    assert_receive {:cleanup_probe_ran, "octo-emb-1259-stall"}, 10_000

    {status, states} = await_settlement_status(issue)

    assert "cleaned" in states,
           "stall termination must release the ownership record; observed states=#{inspect(states)}"

    refute "quarantined" in states,
           "expected clean stall settlement, observed #{inspect(states)} " <>
             "(quarantine_reason=#{inspect(status.quarantine_reason)})"

    assert %{owned_pids: owned_pids, live_after: 0, verified: true, evidence_status: :captured} =
             status.cleanup_evidence

    # As above: `live_after: 0` proves nothing survived the stall termination.
    # This run's `hook_before_run` owned real processes, so its pre-teardown
    # capture is non-empty wherever the ownership sweep actually runs.
    if File.dir?("/proc") do
      refute owned_pids == [],
             "the capture must record the hook processes this run owned before teardown"
    end
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

    {status, log} =
      with_log(fn ->
        send(pid, {:DOWN, ref, :process, self(), :normal})

        assert_eventually_value(fn ->
          case ProcessOwnership.status_for_issue(issue) do
            %{state: "quarantined"} = status -> status
            _other -> nil
          end
        end)
      end)

    # The typed quarantine remains for genuine inability, and the settlement
    # record still carries the evidence it observed.
    assert %{live_after: live_after, verified: false, owned_pids: owned_pids} = status.cleanup_evidence
    assert live_after >= 1
    assert app_server_pid in owned_pids

    # The third `log_terminal_cleanup_evidence/4` clause: a settlement that
    # observed survivors must say so, and must never emit the verified proof
    # line an operator or canary gate reads as "cleanup confirmed".
    assert log =~ "Run-owned runtime cleanup unverified"
    assert log =~ "issue_id=#{issue.id}"
    assert log =~ "live_after=#{live_after}"

    refute log =~ "Run-owned runtime cleanup verified",
           "a settlement with #{live_after} surviving owned process(es) emitted the verified proof line"

    refute log =~ "Run-owned runtime cleanup evidence unavailable",
           "evidence was captured here; the unavailable line would misreport a working capture"
  end

  # EMB-1259 itself: the ordering. Settlement captures its owned-PID evidence
  # BEFORE physical teardown destroys the records and processes that identify
  # it; re-deriving that evidence afterwards is the defect this PR fixes.
  #
  # The observable that holds on every supported platform is the process-table
  # read the capture performs. `/proc/<pid>/environ` (and therefore the live
  # ownership-environment sweep) exists only on the Linux role hosts, so an
  # evidence-content assertion would silently degrade to a tautology on macOS.
  # A PATH shim that records each `ps` invocation, against a teardown double
  # that records when it ran, asserts the ordering directly and identically on
  # both — no production code path is aware of the test.
  test "settlement reads its process evidence before physical teardown runs" do
    test_root = unique_test_root("settlement-ordering")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: "issue-emb-1259-ordering", identifier: "MT-1259O", state: "In Progress"}
    events_path = Path.join(test_root, "settlement-events.log")

    orchestrator_name = Module.concat(__MODULE__, :OrderingSettlementOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      stop_orchestrator!(pid)
      File.rm_rf(test_root)
    end)

    {:ok, process_ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-MT-1259O",
        holder: ProcessOwnership.holder_id()
      })

    ref = make_ref()
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      run_id: process_ownership.run_id,
      process_ownership: process_ownership,
      owned_session_ref: %{
        kind: "test-owned-session",
        session_name: "octo-mt-1259o",
        cleanup_module: OrderingProbe,
        notify_pid: self(),
        events_path: events_path,
        issue_id: issue.id
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _state ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue.id]))
      |> Map.put(:retry_attempts, %{})
    end)

    shim_dir = install_recording_ps_shim!(test_root, events_path)
    File.write!(events_path, "")

    send(pid, {:DOWN, ref, :process, self(), :normal})

    assert_receive {:cleanup_probe_ran, "octo-mt-1259o"}, 5_000
    {_status, _states} = await_settlement_status(issue)

    restore_env("PATH", previous_path)
    File.rm_rf(shim_dir)

    events = events_path |> File.read!() |> String.split("\n", trim: true)

    assert "teardown" in events, "the teardown double never ran; observed #{inspect(events)}"

    assert "process-table-read" in events,
           "settlement never read the process table for its evidence; observed #{inspect(events)}"

    assert Enum.find_index(events, &(&1 == "process-table-read")) <
             Enum.find_index(events, &(&1 == "teardown")),
           "terminal settlement must capture its owned-process evidence BEFORE teardown " <>
             "destroys the records that identify it (EMB-1259); observed #{inspect(events)}"
  end

  defp install_recording_ps_shim!(test_root, events_path) do
    real_ps = System.find_executable("ps")
    assert is_binary(real_ps)

    shim_dir = Path.join(test_root, "ps-shim-#{System.unique_integer([:positive])}")
    File.mkdir_p!(shim_dir)
    shim_path = Path.join(shim_dir, "ps")

    File.write!(shim_path, """
    #!/bin/sh
    printf 'process-table-read\\n' >> #{events_path}
    exec #{real_ps} "$@"
    """)

    File.chmod!(shim_path, 0o755)
    System.put_env("PATH", shim_dir <> ":" <> System.get_env("PATH"))
    shim_dir
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

    {{status, states}, log} =
      with_log(fn ->
        send(pid, {:DOWN, ref, :process, self(), down_reason})
        await_settlement_status(issue)
      end)

    {issue, status, states, log}
  end

  # `log_terminal_cleanup_evidence/4`'s verified clause is the line the
  # production contract and docs/specs/domains/agent-runtime.md name as proof
  # that run-owned runtime cleanup happened. Operators, canary gates and
  # log-based verifiers key on it, so it must be emitted exactly when a
  # settlement really observed a clean teardown — and by no other clause.
  defp assert_verified_cleanup_logged(log, issue) do
    assert log =~ "Run-owned runtime cleanup verified",
           "terminal settlement did not emit its verified cleanup evidence line"

    assert log =~ "issue_id=#{issue.id}"
    assert log =~ "owned_pids=[] live_after=0"

    refute log =~ "Run-owned runtime cleanup evidence unavailable",
           "a verified settlement must not also report its evidence unavailable"

    refute log =~ "Run-owned runtime cleanup unverified",
           "a verified settlement must not also report itself unverified"
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

  defp current_run_envelope(orchestrator_name, issue_id) do
    entry =
      orchestrator_name
      |> Orchestrator.snapshot(1_000)
      |> Map.fetch!(:running)
      |> Enum.find(&(&1.issue_id == issue_id))

    entry.process_ownership
    |> Map.take([:issue_id, :workspace_path, :role, :holder, :run_id])
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
