defmodule SymphonyElixir.OrchestratorCurrentRunActivityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.CurrentRun
  alias SymphonyElixir.Runtime.ProcessOwnership
  alias SymphonyElixir.TestSupport.GatedProcessOwnershipFileSystem

  defmodule HandoffTransport do
    def default_server_snapshot(_context), do: {:ok, %{status: "running", version: "0.8.2", protocol: 20}}

    def start_session(spec, _context) do
      {:ok, %{name: spec.name, socket: "/tmp/#{spec.name}/herdr.sock", runtime_root: "/tmp/#{spec.name}"}}
    end

    def prepare_worker(session, _spec, _context) do
      {:ok, session |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker") |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}
    end

    def start_agent(_session, spec, _context), do: {:ok, %{name: spec.name, pane_id: "w1:p1", profile: spec.profile}}
    def stop_session(_session, _context), do: :ok

    def owned_session_ref(session, _context) do
      %{kind: "handoff-test", session_name: session.name, cleanup_module: __MODULE__, handoff_settlement: :implementer_turn}
    end

    def cleanup_owned_session(_ownership_ref), do: :ok

    def begin_turn(_session, agent, _prompt, _timeout_ms, context) do
      case Application.get_env(:symphony_elixir, :handoff_transport_gate) do
        %{owner: owner, token: token} ->
          send(owner, {:handoff_begin_entered, self(), token})

          receive do
            {:release_handoff_begin, ^token} -> :ok
          end

        _ ->
          :ok
      end

      agent_status = Map.get(context, :agent_status, "working")
      phase = if agent_status == "idle", do: :completed, else: :working

      {:ok, %{phase: phase, agent: %{name: agent.name, pane_id: agent.pane_id, agent_status: agent_status, agent_session: %{value: "handoff-session"}}}}
    end

    def get_agent(_session, agent, _timeout_ms, context) do
      {:ok, %{name: agent.name, pane_id: agent.pane_id, agent_status: Map.get(context, :agent_status, "working"), agent_session: %{value: "handoff-session"}}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "HANDOFF_TEST"}}
  end

  defmodule CleanupProbe do
    def cleanup_owned_session(%{owner: owner, marker: marker}) do
      send(owner, {:stale_owned_session_cleaned, marker})
      :ok
    end
  end

  defmodule CrashingProcessOwnershipFileSystem do
    @behaviour SymphonyElixir.Runtime.ProcessOwnership.FileSystem

    alias SymphonyElixir.Runtime.ProcessOwnership.FileSystem.Real

    @impl true
    def write(path, contents, modes) do
      record = contents |> IO.iodata_to_binary() |> Jason.decode!()

      case Application.get_env(:symphony_elixir, :process_ownership_file_system_crash_probe) do
        %{issue_id: issue_id, owner: owner} ->
          if record["issue_id"] == issue_id do
            send(owner, {:routine_ownership_write_crashing, self(), record["run_id"]})

            receive do
              :crash_routine_ownership_writer -> Process.exit(self(), :kill)
            end
          else
            Real.write(path, contents, modes)
          end

        _ ->
          Real.write(path, contents, modes)
      end
    end
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    previous_file_system = Application.get_env(:symphony_elixir, :process_ownership_file_system)
    previous_gate = Application.get_env(:symphony_elixir, :process_ownership_file_system_gate)
    previous_delegation_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)
    previous_handoff_gate = Application.get_env(:symphony_elixir, :handoff_transport_gate)

    previous_crash_probe =
      Application.get_env(:symphony_elixir, :process_ownership_file_system_crash_probe)

    System.put_env("SYMPHONY_ROLE", "reviewer")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_app_env(:process_ownership_file_system, previous_file_system)
      restore_app_env(:process_ownership_file_system_gate, previous_gate)
      restore_app_env(:delegation_transport_module, previous_delegation_transport)
      restore_app_env(:handoff_transport_gate, previous_handoff_gate)
      restore_app_env(:process_ownership_file_system_crash_probe, previous_crash_probe)
    end)

    :ok
  end

  test "fresh current-run ingress remains visible while routine ownership persistence is held" do
    # Leave enough post-barrier budget for bounded public assertions before
    # requesting reconciliation. The same timeout and age are used on both
    # sides of the RED/GREEN; only the persistence scheduling changes.
    timeout_ms = 2_000
    test_root = unique_test_root("fresh-activity-slow-persistence")
    workspace_root = Path.join(test_root, "workspaces")
    control_root = Path.join(test_root, "provider-control")
    codex_binary = Path.join(test_root, "controlled-codex")
    File.mkdir_p!(control_root)
    write_controlled_codex!(codex_binary, control_root)

    hot_issue = issue("issue-tur-878-hot", "TUR-878-HOT")
    quiet_issue = issue("issue-tur-878-quiet", "TUR-878-QUIET")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      max_concurrent_agents: 2,
      max_turns: 1,
      codex_stall_timeout_ms: timeout_ms,
      codex_command: "#{codex_binary} app-server"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [hot_issue, quiet_issue])

    orchestrator_name = Module.concat(__MODULE__, :SlowPersistenceOrchestrator)
    admission_marker = Path.join(test_root, "work-admission.json")

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-tur-878",
        work_admission_marker_path: admission_marker
      )

    assert {:ok, %{status: "open"}} =
             Orchestrator.open_work_admission(orchestrator_name, "generation-tur-878")

    on_exit(fn ->
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    initial_snapshot = await_two_provider_sessions(orchestrator_name, control_root)

    assert Enum.all?([hot_issue, quiet_issue], fn issue ->
             status = ProcessOwnership.status_for_issue(issue)
             match?(%{state: "active", session_id: session_id} when is_binary(session_id), status)
           end)

    initial_poll_completed_at = initial_snapshot.polling.last_poll_completed_at
    initial_hot_activity_at_ms = running_entry(initial_snapshot, hot_issue.id).last_activity_at_ms

    initial_quiet_activity_at_ms =
      running_entry(initial_snapshot, quiet_issue.id).last_activity_at_ms

    hot_workspace = running_entry(initial_snapshot, hot_issue.id).workspace_path
    hot_run_id = running_entry(initial_snapshot, hot_issue.id).run_id
    hot_emit = Path.join(control_root, Path.basename(hot_workspace) <> ".emit")

    quiet_old_envelope =
      initial_snapshot
      |> running_entry(quiet_issue.id)
      |> Map.fetch!(:process_ownership)
      |> Map.take([:issue_id, :workspace_path, :role, :holder, :run_id])
      |> Map.put(:ingress_at_ms, initial_quiet_activity_at_ms)

    wait_until_monotonic_age(timeout_ms + 50)

    for index <- 1..64 do
      send(
        orchestrator,
        {:codex_worker_update, quiet_issue.id, quiet_old_envelope,
         %{
           event: :notification,
           timestamp: DateTime.add(DateTime.utc_now(), 86_400, :second),
           payload: %{method: "old-backlog-#{index}"}
         }}
      )
    end

    gate_token = make_ref()
    {:ok, gate_controller} = Agent.start_link(fn -> :armed end)

    Application.put_env(
      :symphony_elixir,
      :process_ownership_file_system,
      GatedProcessOwnershipFileSystem
    )

    Application.put_env(:symphony_elixir, :process_ownership_file_system_gate, %{
      controller: gate_controller,
      issue_id: hot_issue.id,
      owner: self(),
      token: gate_token
    })

    active_orchestrator = Process.whereis(orchestrator_name)
    assert is_pid(active_orchestrator), "running Orchestrator disappeared before ingress"
    File.touch!(hot_emit)

    assert_receive {:routine_ownership_write_entered, writer, ^gate_token, ownership_path, %{"run_id" => ^hot_run_id}},
                   2_000

    assert String.contains?(ownership_path, ".tmp-")
    assert System.monotonic_time(:millisecond) - initial_hot_activity_at_ms > timeout_ms

    try do
      serviceable_snapshot = Orchestrator.snapshot(orchestrator_name, 150)

      assert is_map(serviceable_snapshot),
             "snapshot was blocked behind routine ownership persistence: #{inspect(serviceable_snapshot)}"

      assert {:ok, %{status: "closed"}} =
               Orchestrator.close_work_admission(orchestrator_name, "generation-tur-878")

      assert {:ok, %{status: "open"}} =
               Orchestrator.open_work_admission(orchestrator_name, "generation-tur-878")

      assert running_entry(serviceable_snapshot, hot_issue.id)
      assert running_entry(serviceable_snapshot, quiet_issue.id)

      assert running_entry(serviceable_snapshot, hot_issue.id).last_activity_at_ms !=
               initial_hot_activity_at_ms

      assert running_entry(serviceable_snapshot, quiet_issue.id).last_activity_at_ms ==
               initial_quiet_activity_at_ms

      fresh_activity_at_ms = running_entry(serviceable_snapshot, hot_issue.id).last_activity_at_ms

      assert System.monotonic_time(:millisecond) - fresh_activity_at_ms < timeout_ms,
             "the explicit filesystem-entry barrier must precede the tick while ingress is fresh"

      accounted_snapshot =
        eventually_value(
          fn ->
            case Orchestrator.snapshot(orchestrator_name, 150) do
              %{rate_limits: %{"limit_id" => "burst-limit"}} = snapshot ->
                entry = running_entry(snapshot, hot_issue.id)
                if entry.codex_total_tokens == 16, do: snapshot

              _ ->
                nil
            end
          end,
          50
        )

      accounted_hot = running_entry(accounted_snapshot, hot_issue.id)
      assert accounted_hot.codex_input_tokens == 12
      assert accounted_hot.codex_output_tokens == 4
      assert accounted_hot.codex_total_tokens == 16

      assert %{queued: true, operations: ["poll", "reconcile"]} =
               Orchestrator.request_refresh(orchestrator_name)

      reconciled_snapshot =
        eventually_value(fn ->
          case Orchestrator.snapshot(orchestrator_name, 150) do
            %{polling: %{checking?: false, last_poll_completed_at: completed_at}} = snapshot
            when completed_at != initial_poll_completed_at ->
              snapshot

            _ ->
              nil
          end
        end)

      assert running_entry(reconciled_snapshot, hot_issue.id)

      assert Enum.any?(
               reconciled_snapshot.retrying,
               &(&1.issue_id == quiet_issue.id)
             )
    after
      send(writer, {:release_routine_ownership_write, gate_token})
    end

    assert eventually_value(fn -> if Process.alive?(writer), do: nil, else: true end)

    assert eventually_value(fn ->
             case ProcessOwnership.status_for_issue(hot_issue) do
               %{state: "active", run_id: ^hot_run_id} = ownership -> ownership
               _ -> nil
             end
           end)
  end

  test "token and rate-limit-only ingress is accounted without refreshing current-run activity" do
    test_root = unique_test_root("token-only-activity")
    workspace_root = Path.join(test_root, "workspaces")
    control_root = Path.join(test_root, "provider-control")
    codex_binary = Path.join(test_root, "controlled-codex")
    File.mkdir_p!(control_root)
    write_controlled_codex!(codex_binary, control_root)

    issue = issue("issue-tur-878-token-only", "TUR-878-TOKEN-ONLY")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      max_turns: 1,
      codex_stall_timeout_ms: 0,
      codex_command: "#{codex_binary} app-server"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :TokenOnlyActivityOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    initial_snapshot = await_provider_sessions(orchestrator_name, control_root, 1)
    initial_entry = running_entry(initial_snapshot, issue.id)
    emit_file = Path.join(control_root, Path.basename(initial_entry.workspace_path) <> ".emit")
    initial_activity_at_ms = initial_entry.last_activity_at_ms

    File.touch!(emit_file <> ".single")

    accounted_snapshot =
      eventually_value(fn ->
        case Orchestrator.snapshot(orchestrator_name, 500) do
          %{rate_limits: %{"limit_id" => "single-limit"}} = snapshot ->
            entry = running_entry(snapshot, issue.id)
            if entry.codex_total_tokens == 2, do: snapshot

          _ ->
            nil
        end
      end)

    accounted_entry = running_entry(accounted_snapshot, issue.id)
    assert accounted_entry.codex_input_tokens == 1
    assert accounted_entry.codex_output_tokens == 1
    assert accounted_entry.codex_total_tokens == 2
    assert accounted_entry.last_activity_at_ms == initial_activity_at_ms
  end

  test "default running Orchestrator handoff grace refreshes from a real implementer sender" do
    previous_role = System.get_env("SYMPHONY_ROLE")

    previous_grace =
      Application.get_env(:symphony_elixir, :implementer_handoff_settlement_grace_ms)

    System.put_env("SYMPHONY_ROLE", "implementer")
    Application.put_env(:symphony_elixir, :implementer_handoff_settlement_grace_ms, 2_000)

    test_root = unique_test_root("handoff-real-path")
    workspace_root = Path.join(test_root, "workspaces")
    control_root = Path.join(test_root, "provider-control")
    codex_binary = Path.join(test_root, "controlled-codex")
    File.mkdir_p!(control_root)
    write_controlled_codex!(codex_binary, control_root)

    issue = issue("issue-tur-878-handoff-real", "TUR-878-HANDOFF-REAL")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      max_turns: 1,
      codex_stall_timeout_ms: 0,
      codex_command: "#{codex_binary} app-server"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :delegation_transport_module, HandoffTransport)
    handoff_gate_token = make_ref()

    Application.put_env(:symphony_elixir, :handoff_transport_gate, %{
      owner: self(),
      token: handoff_gate_token
    })

    orchestrator_name = Module.concat(__MODULE__, :HandoffRealOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_app_env(:implementer_handoff_settlement_grace_ms, previous_grace)
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    assert_receive {:handoff_begin_entered, runner, ^handoff_gate_token}, 2_000
    initial_snapshot = Orchestrator.snapshot(orchestrator_name, 500)
    initial_activity = running_entry(initial_snapshot, issue.id).last_activity_at_ms

    wait_until_monotonic_deadline(initial_activity + 2_050)

    # Release the real sender only after the run is stale under the same
    # bounded grace used for reconciliation.
    send(runner, {:release_handoff_begin, handoff_gate_token})

    fresh_snapshot =
      eventually_value(fn ->
        case Orchestrator.snapshot(orchestrator_name, 500) do
          %{running: [%{issue_id: issue_id, last_activity_at_ms: activity} | _]} = snapshot
          when issue_id == issue.id and is_integer(activity) and activity > initial_activity ->
            snapshot

          _ ->
            nil
        end
      end)

    assert running_entry(fresh_snapshot, issue.id).last_activity_at_ms > initial_activity

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Agent Review"}])
    assert %{queued: true} = Orchestrator.request_refresh(orchestrator_name)

    handoff_snapshot =
      eventually_value(fn ->
        case Orchestrator.snapshot(orchestrator_name, 500) do
          %{running: [%{issue_id: issue_id, state: "Agent Review"} | _]} = snapshot
          when issue_id == issue.id ->
            snapshot

          _ ->
            nil
        end
      end)

    assert running_entry(handoff_snapshot, issue.id).run_id ==
             running_entry(fresh_snapshot, issue.id).run_id

    refreshed_snapshot =
      eventually_value(fn ->
        case Orchestrator.snapshot(orchestrator_name, 500) do
          %{running: [%{issue_id: issue_id} | _]} = snapshot when issue_id == issue.id ->
            snapshot

          _ ->
            nil
        end
      end)

    assert refreshed_snapshot.running != []
  end

  test "disabled stall detection leaves a silent real run owned" do
    test_root = unique_test_root("disabled-stall-detection")
    workspace_root = Path.join(test_root, "workspaces")
    control_root = Path.join(test_root, "provider-control")
    codex_binary = Path.join(test_root, "controlled-codex")
    File.mkdir_p!(control_root)
    write_controlled_codex!(codex_binary, control_root)

    issue = issue("issue-tur-878-disabled-stall", "TUR-878-DISABLED-STALL")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      max_turns: 1,
      codex_stall_timeout_ms: 0,
      codex_command: "#{codex_binary} app-server"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :DisabledStallOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    snapshot = await_provider_sessions(orchestrator_name, control_root, 1)
    run_id = running_entry(snapshot, issue.id).run_id
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert %{queued: true} = Orchestrator.request_refresh(orchestrator_name)
    assert_receive {:memory_tracker_fetch_issue_states_by_ids, issue_ids}, 1_000
    assert issue.id in issue_ids

    reconciled = Orchestrator.snapshot(orchestrator_name, 2_000)

    assert %{run_id: ^run_id} = running_entry(reconciled, issue.id)
    assert %{state: "active", run_id: ^run_id} = ProcessOwnership.status_for_issue(issue)
  end

  test "routine persistence recovers after its supervised writer is killed" do
    test_root = unique_test_root("routine-writer-recovery")
    workspace_root = Path.join(test_root, "workspaces")
    control_root = Path.join(test_root, "provider-control")
    codex_binary = Path.join(test_root, "controlled-codex")
    File.mkdir_p!(control_root)
    write_controlled_codex!(codex_binary, control_root)

    issue = issue("issue-tur-878-writer-recovery", "TUR-878-WRITER-RECOVERY")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      max_turns: 1,
      codex_stall_timeout_ms: 0,
      codex_command: "#{codex_binary} app-server"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :RoutineWriterRecoveryOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    snapshot = await_provider_sessions(orchestrator_name, control_root, 1)
    entry = running_entry(snapshot, issue.id)
    emit_file = Path.join(control_root, Path.basename(entry.workspace_path) <> ".emit")
    run_id = entry.run_id

    Application.put_env(
      :symphony_elixir,
      :process_ownership_file_system,
      CrashingProcessOwnershipFileSystem
    )

    Application.put_env(:symphony_elixir, :process_ownership_file_system_crash_probe, %{
      issue_id: issue.id,
      owner: self()
    })

    File.touch!(emit_file <> ".single")
    assert_receive {:routine_ownership_write_crashing, crashed_writer, ^run_id}, 2_000
    crash_ref = Process.monitor(crashed_writer)
    send(crashed_writer, :crash_routine_ownership_writer)
    assert_receive {:DOWN, ^crash_ref, :process, ^crashed_writer, :killed}, 1_000

    gate_token = make_ref()
    {:ok, gate_controller} = Agent.start_link(fn -> :armed end)

    Application.put_env(
      :symphony_elixir,
      :process_ownership_file_system,
      GatedProcessOwnershipFileSystem
    )

    Application.put_env(:symphony_elixir, :process_ownership_file_system_gate, %{
      controller: gate_controller,
      issue_id: issue.id,
      owner: self(),
      token: gate_token
    })

    File.touch!(emit_file <> ".again")

    assert_receive {:routine_ownership_write_entered, writer, ^gate_token, _path, %{"run_id" => ^run_id}},
                   2_000

    send(writer, {:release_routine_ownership_write, gate_token})

    assert eventually_value(fn -> if Process.alive?(writer), do: nil, else: true end)

    assert eventually_value(fn ->
             case ProcessOwnership.status_for_issue(issue) do
               %{state: "active", run_id: ^run_id, session_id: session_id} = ownership
               when is_binary(session_id) ->
                 ownership

               _ ->
                 nil
             end
           end)
  end

  @tag timeout: 120_000
  test "terminal settlement and redispatch reject the predecessor envelope" do
    test_root = unique_test_root("retry-replaces-run")
    workspace_root = Path.join(test_root, "workspaces")
    control_root = Path.join(test_root, "provider-control")
    codex_binary = Path.join(test_root, "controlled-codex")
    File.mkdir_p!(control_root)
    write_controlled_codex!(codex_binary, control_root)

    issue = issue("issue-tur-878-retry-replacement", "TUR-878-RETRY-REPLACEMENT")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      max_turns: 1,
      max_retry_backoff_ms: 50,
      codex_stall_timeout_ms: 0,
      codex_command: "#{codex_binary} app-server"
    )

    # Hold the tracker empty until the isolated OTP 28 trace session is
    # attached to the existing TaskSupervisor. This removes the first-dispatch
    # race while preserving normal Orchestrator -> AgentRunner composition.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_name = Module.concat(__MODULE__, :RetryReplacementOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    assert eventually_value(fn ->
             case Orchestrator.snapshot(orchestrator_name, 500) do
               %{running: [], polling: %{checking?: false, last_poll_completed_at: completed_at}}
               when not is_nil(completed_at) ->
                 true

               _ ->
                 nil
             end
           end)

    trace_session = start_current_run_trace!()
    on_exit(fn -> destroy_current_run_trace(trace_session) end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert %{queued: true} = Orchestrator.request_refresh(orchestrator_name)

    predecessor_snapshot = await_provider_sessions(orchestrator_name, control_root, 1)
    predecessor = running_entry(predecessor_snapshot, issue.id)
    predecessor_run_id = predecessor.run_id

    predecessor_sender_capture =
      await_current_run_sender(trace_session, predecessor, orchestrator_name)

    retained_predecessor_sender = predecessor_sender_capture.sender
    retained_predecessor_recipient = predecessor_sender_capture.recipient
    predecessor_envelope = CurrentRun.envelope(retained_predecessor_sender)

    delayed_predecessor_envelope =
      Map.put(predecessor_envelope, :ingress_at_ms, System.monotonic_time(:millisecond))

    assert predecessor_sender_capture.trace_pid in Task.Supervisor.children(SymphonyElixir.TaskSupervisor)

    assert predecessor_envelope ==
             Map.take(predecessor.process_ownership, [
               :issue_id,
               :workspace_path,
               :role,
               :holder,
               :run_id
             ])

    assert %{run_id: ^predecessor_run_id, session_id: predecessor_session_id, live?: true} =
             await_durable_run_identity(issue, predecessor)

    assert predecessor_session_id == predecessor.session_id

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %{issue | state: "Agent Review"}
    ])

    predecessor_emit =
      Path.join(control_root, Path.basename(predecessor.workspace_path) <> ".emit")

    File.touch!(predecessor_emit <> ".complete")
    assert %{queued: true} = Orchestrator.request_refresh(orchestrator_name)

    assert %{state: predecessor_terminal_state} =
             await_non_active_ownership(issue, orchestrator_name)

    refute predecessor_terminal_state == "active"

    # The controlled provider emits completion before removing its marker.
    # Do not let the successor observe predecessor-owned fixture state.
    assert eventually_value(fn ->
             if File.exists?(predecessor_emit <> ".complete"), do: nil, else: true
           end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %{issue | description: "Changed checkpoint authorizes a distinct successor run."}
    ])

    assert %{queued: true} = Orchestrator.request_refresh(orchestrator_name)

    successor =
      eventually_value(fn ->
        case Orchestrator.snapshot(orchestrator_name, 500) do
          %{running: running} ->
            case Enum.find(running, &(&1.issue_id == issue.id)) do
              %{run_id: run_id, session_id: session_id} = entry
              when run_id != predecessor_run_id and is_binary(session_id) and session_id != "n/a" ->
                entry

              _ ->
                nil
            end

          _ ->
            nil
        end
      end)

    successor_sender_capture =
      await_current_run_sender(trace_session, successor, orchestrator_name)

    retained_successor_sender = successor_sender_capture.sender
    retained_successor_recipient = successor_sender_capture.recipient

    assert CurrentRun.envelope(retained_successor_sender) ==
             Map.take(successor.process_ownership, [
               :issue_id,
               :workspace_path,
               :role,
               :holder,
               :run_id
             ])

    # The session has served its bounded provenance capture. Its destruction
    # removes only this test's dynamic trace settings; the retained terms are
    # the exact public recipient/capabilities observed from AgentRunner.
    destroy_current_run_trace(trace_session)

    stale_owned_session = %{cleanup_module: CleanupProbe, owner: self(), marker: :retry_predecessor}

    successor_before_late_ownership = await_durable_run_identity(issue, successor)

    successor_before_late = Orchestrator.snapshot(orchestrator_name, 500)
    successor_before_late_entry = running_entry(successor_before_late, issue.id)

    assert durable_ownership_view(successor_before_late_entry.process_ownership) ==
             durable_ownership_view(successor_before_late_ownership)

    # This is the retained, dispatch-created public sender proof. Normal
    # settlement retired its shared capability, so the late activity is a
    # valid public call whose no-op must leave the successor untouched.
    assert is_nil(CurrentRun.activity_ms(retained_predecessor_sender))

    assert :ok =
             CurrentRun.forward_update(
               retained_predecessor_recipient,
               retained_predecessor_sender,
               %{
                 event: :session_started,
                 timestamp: DateTime.utc_now(),
                 session_id: "stale-retry-session",
                 codex_app_server_pid: "999999",
                 usage: %{"input_tokens" => 900, "output_tokens" => 90, "total_tokens" => 990},
                 rate_limits: %{"limit_id" => "stale-retry"}
               }
             )

    assert :ok =
             CurrentRun.forward_update(
               retained_predecessor_recipient,
               retained_predecessor_sender,
               %{
                 event: :turn_completed,
                 timestamp: DateTime.utc_now(),
                 session_id: "late-predecessor"
               }
             )

    # The following three messages are explicitly delayed-envelope receiver
    # checks. They are not retained-sender evidence: the real sender above is
    # the only activity provenance path in this test.
    send(
      orchestrator,
      {:codex_worker_update, issue.id, delayed_predecessor_envelope,
       %{
         event: :session_started,
         timestamp: DateTime.utc_now(),
         session_id: "stale-retry-session",
         codex_app_server_pid: "999999",
         usage: %{"input_tokens" => 900, "output_tokens" => 90, "total_tokens" => 990},
         rate_limits: %{"limit_id" => "stale-retry"}
       }}
    )

    send(
      orchestrator,
      {:worker_runtime_info, issue.id, predecessor_envelope, %{worker_host: "stale-retry-host", workspace_path: "/tmp/stale-retry"}}
    )

    send(
      orchestrator,
      {:owned_session_runtime_info, issue.id, predecessor_envelope, stale_owned_session}
    )

    unchanged = Orchestrator.snapshot(orchestrator_name, 500)
    current = running_entry(unchanged, issue.id)

    assert_receive {:stale_owned_session_cleaned, :retry_predecessor}, 500
    refute current.run_id == predecessor_run_id
    assert current.run_id == successor.run_id
    assert current.run_id == successor_before_late_entry.run_id
    assert current.session_id == successor.session_id
    assert current.codex_app_server_pid == successor.codex_app_server_pid
    assert current.session_id == successor_before_late_entry.session_id
    assert current.codex_app_server_pid == successor_before_late_entry.codex_app_server_pid
    assert current.worker_host == successor_before_late_entry.worker_host
    assert current.workspace_path == successor_before_late_entry.workspace_path
    assert current.last_activity_at_ms == successor_before_late_entry.last_activity_at_ms
    assert current.codex_input_tokens == successor_before_late_entry.codex_input_tokens
    assert current.codex_output_tokens == successor_before_late_entry.codex_output_tokens
    assert current.codex_total_tokens == successor_before_late_entry.codex_total_tokens

    assert durable_ownership_view(current.process_ownership) ==
             durable_ownership_view(successor_before_late_entry.process_ownership)

    assert unchanged.rate_limits == successor_before_late.rate_limits
    refute unchanged.rate_limits == %{"limit_id" => "stale-retry"}

    assert durable_ownership_view(ProcessOwnership.status_for_issue(issue)) ==
             durable_ownership_view(successor_before_late_ownership)

    # Preserve the legacy issue-only/malformed-envelope receiver checks. These
    # are delayed envelope probes only; they are not activity provenance.
    send(
      orchestrator,
      {:codex_worker_update, issue.id, %{event: :notification, timestamp: DateTime.utc_now()}}
    )

    send(orchestrator, {:worker_runtime_info, issue.id, %{workspace_path: "/tmp/legacy"}})
    send(orchestrator, {:owned_session_runtime_info, issue.id, stale_owned_session})

    legacy_unchanged = Orchestrator.snapshot(orchestrator_name, 500)
    legacy_current = running_entry(legacy_unchanged, issue.id)

    assert legacy_current.run_id == successor_before_late_entry.run_id
    assert legacy_current.session_id == successor_before_late_entry.session_id
    assert legacy_current.codex_app_server_pid == successor_before_late_entry.codex_app_server_pid
    assert legacy_current.worker_host == successor_before_late_entry.worker_host
    assert legacy_current.workspace_path == successor_before_late_entry.workspace_path
    assert legacy_current.last_activity_at_ms == successor_before_late_entry.last_activity_at_ms
    assert legacy_current.codex_input_tokens == successor_before_late_entry.codex_input_tokens
    assert legacy_current.codex_output_tokens == successor_before_late_entry.codex_output_tokens
    assert legacy_current.codex_total_tokens == successor_before_late_entry.codex_total_tokens

    assert durable_ownership_view(legacy_current.process_ownership) ==
             durable_ownership_view(successor_before_late_entry.process_ownership)

    assert legacy_unchanged.rate_limits == successor_before_late.rate_limits

    assert durable_ownership_view(ProcessOwnership.status_for_issue(issue)) ==
             durable_ownership_view(successor_before_late_ownership)

    initial_turn_count = legacy_current.turn_count

    for {session_id, include_provider_timestamp?} <- [
          {"successor-turn-2", true},
          {"successor-turn-3", false}
        ] do
      update = %{event: :session_started, session_id: session_id}

      update =
        if include_provider_timestamp?,
          do: Map.put(update, :timestamp, DateTime.utc_now()),
          else: update

      assert :ok =
               CurrentRun.forward_update(
                 retained_successor_recipient,
                 retained_successor_sender,
                 update
               )
    end

    accepted = Orchestrator.snapshot(orchestrator_name, 500)
    accepted_entry = running_entry(accepted, issue.id)
    assert accepted_entry.session_id == "successor-turn-3"
    assert accepted_entry.turn_count == initial_turn_count + 2

    newest_activity_at_ms = accepted_entry.last_activity_at_ms
    # These are receiver-side rejection probes for malformed/delayed
    # envelopes; they do not stand in for the retained sender capability.
    for claimed_ingress <- [
          newest_activity_at_ms - 10,
          "malformed",
          nil,
          System.monotonic_time(:millisecond) + 60_000
        ] do
      envelope =
        if is_nil(claimed_ingress),
          do: CurrentRun.envelope(retained_successor_sender),
          else: Map.put(CurrentRun.envelope(retained_successor_sender), :ingress_at_ms, claimed_ingress)

      send(
        orchestrator,
        {:codex_worker_update, issue.id, envelope,
         %{
           event: :notification,
           timestamp: DateTime.add(DateTime.utc_now(), 86_400, :second),
           payload: %{method: "diagnostic-clock-only"}
         }}
      )
    end

    rejected_clocks = Orchestrator.snapshot(orchestrator_name, 500)
    assert running_entry(rejected_clocks, issue.id).last_activity_at_ms == newest_activity_at_ms

    cumulative_usage = %{"input_tokens" => 10, "output_tokens" => 6, "total_tokens" => 16}

    for _duplicate <- 1..2 do
      assert :ok =
               CurrentRun.forward_update(
                 retained_successor_recipient,
                 retained_successor_sender,
                 %{
                   event: :notification,
                   timestamp: DateTime.utc_now(),
                   usage: cumulative_usage,
                   rate_limits: %{"limit_id" => "current", "primary" => %{"remaining" => 9}}
                 }
               )
    end

    monotonic = Orchestrator.snapshot(orchestrator_name, 500)
    monotonic_entry = running_entry(monotonic, issue.id)
    assert monotonic_entry.last_activity_at_ms >= newest_activity_at_ms
    assert monotonic_entry.codex_input_tokens == successor.codex_input_tokens + 10
    assert monotonic_entry.codex_output_tokens == successor.codex_output_tokens + 6
    assert monotonic_entry.codex_total_tokens == successor.codex_total_tokens + 16
    assert monotonic.rate_limits["limit_id"] == "current"
  end

  @tag timeout: 120_000
  test "public AgentRunner publishes acquired identity for worker and owned-session startup" do
    previous_role = System.get_env("SYMPHONY_ROLE")
    test_root = unique_test_root("public-agent-runner-startup")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      File.rm_rf(test_root)
    end)

    System.put_env("SYMPHONY_ROLE", "implementer")

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      max_concurrent_agents: 1,
      max_turns: 1,
      codex_stall_timeout_ms: 0
    )

    issue = issue("issue-tur-878-public-runner", "TUR-878-PUBLIC-RUNNER")
    parent = self()
    run_id = "public-agent-runner-#{System.unique_integer([:positive])}"

    {:ok, runner} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        run_agent_with_ownership(issue, parent,
          run_id: run_id,
          delegation_transport: HandoffTransport,
          delegation_transport_context: %{
            assignments: [],
            issue_id: issue.id,
            test_pid: parent,
            agent_status: "idle"
          }
        )
      end)

    monitor_ref = Process.monitor(runner)

    on_exit(fn ->
      if Process.alive?(runner), do: Process.exit(runner, :kill)
    end)

    assert_receive {:worker_runtime_info, issue_id, worker_envelope, runtime_info}, 5_000
    assert issue_id == issue.id
    assert worker_envelope.issue_id == issue.id
    assert worker_envelope.run_id == run_id
    assert runtime_info.workspace_path == worker_envelope.workspace_path

    assert %{state: "active", run_id: ^run_id, workspace_path: workspace_path} =
             ProcessOwnership.status_for_issue(issue)

    assert workspace_path == worker_envelope.workspace_path

    assert_receive {:owned_session_runtime_info, ^issue_id, owned_envelope, ownership_ref},
                   5_000

    assert owned_envelope == worker_envelope
    assert is_binary(ownership_ref.session_name)
    assert ownership_ref.cleanup_module == HandoffTransport
    assert ownership_ref.handoff_settlement == :implementer_turn

    assert_receive {:DOWN, ^monitor_ref, :process, ^runner, :normal}, 5_000
  end

  test "terminal reconciliation fences a held routine write and late activity" do
    test_root = unique_test_root("terminal-fences-routine-write")
    workspace_root = Path.join(test_root, "workspaces")
    control_root = Path.join(test_root, "provider-control")
    codex_binary = Path.join(test_root, "controlled-codex")
    File.mkdir_p!(control_root)
    write_controlled_codex!(codex_binary, control_root)

    issue = issue("issue-tur-878-terminal", "TUR-878-TERMINAL")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      max_turns: 1,
      codex_stall_timeout_ms: 0,
      codex_command: "#{codex_binary} app-server"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :TerminalFenceOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    snapshot = await_provider_sessions(orchestrator_name, control_root, 1)
    entry = running_entry(snapshot, issue.id)
    emit_file = Path.join(control_root, Path.basename(entry.workspace_path) <> ".emit")
    run_id = entry.run_id

    delayed_envelope =
      entry.process_ownership
      |> Map.take([:issue_id, :workspace_path, :role, :holder, :run_id])
      |> Map.put(:ingress_at_ms, System.monotonic_time(:millisecond))

    gate_token = make_ref()
    {:ok, gate_controller} = Agent.start_link(fn -> :armed end)

    Application.put_env(
      :symphony_elixir,
      :process_ownership_file_system,
      GatedProcessOwnershipFileSystem
    )

    Application.put_env(:symphony_elixir, :process_ownership_file_system_gate, %{
      controller: gate_controller,
      issue_id: issue.id,
      owner: self(),
      token: gate_token
    })

    File.touch!(emit_file)

    assert_receive {:routine_ownership_write_entered, writer, ^gate_token, _path, %{"run_id" => ^run_id}},
                   2_000

    try do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %{issue | state: "Agent Review"}
      ])

      assert %{queued: true} = Orchestrator.request_refresh(orchestrator_name)

      terminal_status = await_non_active_ownership(issue, orchestrator_name)

      refute terminal_status.state == "active"

      # Retirement owns the supervised routine task lifecycle as well as its
      # result token. The blocked writer must terminate before it can consume
      # resources past settlement or attempt a stale active commit.
      assert eventually_value(fn -> if Process.alive?(writer), do: nil, else: true end)

      send(
        orchestrator,
        {:codex_worker_update, issue.id, delayed_envelope, %{event: :notification, timestamp: DateTime.utc_now(), payload: %{method: "late"}}}
      )

      send(
        orchestrator,
        {make_ref(), {:ok, Map.put(terminal_status, :state, "active")}}
      )

      final_snapshot = Orchestrator.snapshot(orchestrator_name, 500)
      refute running_entry(final_snapshot, issue.id)
      refute ProcessOwnership.status_for_issue(issue).state == "active"
    after
      send(writer, {:release_routine_ownership_write, gate_token})
    end
  end

  test "shutdown fences a held routine write before releasing ownership" do
    test_root = unique_test_root("shutdown-fences-routine-write")
    workspace_root = Path.join(test_root, "workspaces")
    control_root = Path.join(test_root, "provider-control")
    codex_binary = Path.join(test_root, "controlled-codex")
    File.mkdir_p!(control_root)
    write_controlled_codex!(codex_binary, control_root)

    issue = issue("issue-tur-878-shutdown", "TUR-878-SHUTDOWN")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      max_turns: 1,
      codex_stall_timeout_ms: 0,
      codex_command: "#{codex_binary} app-server"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :ShutdownFenceOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    snapshot = await_provider_sessions(orchestrator_name, control_root, 1)
    entry = running_entry(snapshot, issue.id)
    emit_file = Path.join(control_root, Path.basename(entry.workspace_path) <> ".emit")
    run_id = entry.run_id

    gate_token = make_ref()
    {:ok, gate_controller} = Agent.start_link(fn -> :armed end)

    Application.put_env(
      :symphony_elixir,
      :process_ownership_file_system,
      GatedProcessOwnershipFileSystem
    )

    Application.put_env(:symphony_elixir, :process_ownership_file_system_gate, %{
      controller: gate_controller,
      issue_id: issue.id,
      owner: self(),
      token: gate_token
    })

    File.touch!(emit_file <> ".single")

    assert_receive {:routine_ownership_write_entered, writer, ^gate_token, _path, %{"run_id" => ^run_id}},
                   2_000

    try do
      writer_ref = Process.monitor(writer)
      Process.unlink(orchestrator)
      :ok = GenServer.stop(orchestrator, :shutdown, 5_000)

      assert_receive {:DOWN, ^writer_ref, :process, ^writer, _reason}, 1_000
      assert %{state: "cleaned", run_id: ^run_id} = ProcessOwnership.status_for_issue(issue)
    after
      send(writer, {:release_routine_ownership_write, gate_token})
    end
  end

  defp start_current_run_trace! do
    task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)

    unless is_pid(task_supervisor) do
      raise "TaskSupervisor is unavailable for the bounded OTP 28 trace session"
    end

    session = :trace.session_create(:tur878_current_run_trace, self(), [])

    try do
      unless :trace.function(session, {CurrentRun, :forward_update, 3}, [], [:local]) == 1 do
        raise "OTP 28 trace session did not install CurrentRun.forward_update/3"
      end

      unless :trace.process(session, task_supervisor, true, [:call, :set_on_spawn]) == 1 do
        raise "OTP 28 trace session did not attach to TaskSupervisor"
      end

      session
    catch
      kind, reason ->
        _ = :trace.session_destroy(session)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp destroy_current_run_trace(session) do
    _ = :trace.session_destroy(session)
    :ok
  catch
    _kind, _reason ->
      :ok
  end

  defp await_current_run_sender(_trace_session, expected_entry, orchestrator_name, attempts \\ 500)

  defp await_current_run_sender(_trace_session, _expected_entry, _orchestrator_name, 0) do
    flunk("real AgentRunner did not produce a traceable CurrentRun.forward_update/3 call")
  end

  defp await_current_run_sender(
         trace_session,
         expected_entry,
         orchestrator_name,
         attempts
       ) do
    receive do
      {:trace, trace_pid, :call, {CurrentRun, :forward_update, [recipient, %CurrentRun{} = sender, update]}}
      when is_pid(recipient) and is_map(update) ->
        expected_identity =
          Map.take(expected_entry.process_ownership, [
            :issue_id,
            :workspace_path,
            :role,
            :holder,
            :run_id
          ])

        identity = CurrentRun.envelope(sender)

        if recipient == Process.whereis(orchestrator_name) and identity == expected_identity do
          %{trace_pid: trace_pid, recipient: recipient, sender: sender, update: update}
        else
          await_current_run_sender(trace_session, expected_entry, orchestrator_name, attempts - 1)
        end

      _other ->
        await_current_run_sender(trace_session, expected_entry, orchestrator_name, attempts - 1)
    after
      10 -> await_current_run_sender(trace_session, expected_entry, orchestrator_name, attempts - 1)
    end
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      repository: "EmberAGI/symphony",
      repository_source: "linear_label",
      title: "Current-run activity fixture",
      description: "Exercise current-run activity through real dispatch.",
      state: "In Progress",
      url: "https://example.test/#{identifier}",
      labels: []
    }
  end

  defp write_controlled_codex!(path, control_root) do
    File.write!(path, """
    #!/bin/sh
    set -eu
    count=0
    workspace=$(basename "$PWD")
    emit_file=#{control_root}/$workspace.emit

    while IFS= read -r _line; do
      count=$((count + 1))
      printf '%s:%s\n' "$count" "$_line" >> #{control_root}/$workspace.trace
      case "$count" in
        1)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '{"id":2,"result":{"thread":{"id":"thread-%s"}}}\n' "$workspace"
          ;;
        4)
          printf '{"id":3,"result":{"turn":{"id":"turn-%s"}}}\n' "$workspace"
          while [ ! -f "$emit_file" ] && [ ! -f "$emit_file.single" ] && [ ! -f "$emit_file.complete" ]; do sleep 0.01; done
          if [ -f "$emit_file.complete" ]; then
            printf '%s\n' '{"method":"item/agentMessage/delta","params":{"delta":"terminal handoff"}}'
            printf '%s\n' '{"method":"turn/completed","params":{"turn":{"status":"completed","last_agent_message":"terminal handoff"}}}'
            rm -f "$emit_file.complete"
            exit 0
          elif [ -f "$emit_file.single" ]; then
            printf '%s\n' '{"method":"runtime/usage","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2},"rate_limits":{"limit_id":"single-limit","primary":{"remaining":8}}}'
          else
            i=1
            while [ "$i" -le 64 ]; do
              printf '{"method":"item/agentMessage/delta","params":{"delta":"burst-%s"}}\n' "$i"
              i=$((i + 1))
            done
            i=1
            while [ "$i" -le 80 ]; do
              printf '%s\n' '{"method":"runtime/usage","usage":{"input_tokens":12,"output_tokens":4,"total_tokens":16},"rate_limits":{"limit_id":"burst-limit","primary":{"remaining":9}}}'
              i=$((i + 1))
            done
          fi
          while [ ! -f "$emit_file.again" ]; do sleep 0.01; done
          printf '%s\n' '{"method":"item/agentMessage/delta","params":{"delta":"handoff heartbeat"}}'
          i=1
          while [ "$i" -le 10 ]; do
            printf '%s\n' '{"method":"runtime/usage","usage":{"input_tokens":12,"output_tokens":4,"total_tokens":16},"rate_limits":{"limit_id":"burst-limit","primary":{"remaining":9}}}'
            sleep 0.05
            i=$((i + 1))
          done
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp running_entry(snapshot, issue_id) do
    Enum.find(snapshot.running, &(&1.issue_id == issue_id))
  end

  defp await_two_provider_sessions(orchestrator_name, control_root),
    do: await_provider_sessions(orchestrator_name, control_root, 2)

  defp await_provider_sessions(orchestrator_name, control_root, expected, attempts \\ 500)

  defp await_provider_sessions(orchestrator_name, control_root, _expected, 0) do
    traces =
      control_root
      |> Path.join("*.trace")
      |> Path.wildcard()
      |> Map.new(&{Path.basename(&1), File.read!(&1)})

    flunk(
      "two provider sessions did not become ready; final public snapshot=" <>
        inspect(Orchestrator.snapshot(orchestrator_name, 500)) <>
        "; provider traces=" <> inspect(traces)
    )
  end

  defp await_provider_sessions(orchestrator_name, control_root, expected, attempts) do
    case Orchestrator.snapshot(orchestrator_name, 500) do
      %{running: running} = snapshot when length(running) == expected ->
        if Enum.all?(running, &(is_binary(&1.session_id) and &1.session_id != "n/a")) and
             snapshot.polling.checking? == false do
          snapshot
        else
          Process.sleep(10)
          await_provider_sessions(orchestrator_name, control_root, expected, attempts - 1)
        end

      _ ->
        Process.sleep(10)
        await_provider_sessions(orchestrator_name, control_root, expected, attempts - 1)
    end
  end

  defp eventually_value(fun, attempts \\ 500)
  defp eventually_value(_fun, 0), do: flunk("condition not met before deadline")

  defp eventually_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  defp await_non_active_ownership(issue, orchestrator_name, attempts \\ 300)

  defp await_non_active_ownership(issue, orchestrator_name, 0) do
    flunk(
      "ownership stayed active; status=#{inspect(ProcessOwnership.status_for_issue(issue))} " <>
        "snapshot=#{inspect(Orchestrator.snapshot(orchestrator_name, 500))}"
    )
  end

  defp await_non_active_ownership(issue, orchestrator_name, attempts) do
    Process.sleep(50)

    case ProcessOwnership.status_for_issue(issue) do
      %{state: state} = status when state != "active" ->
        status

      _ ->
        await_non_active_ownership(issue, orchestrator_name, attempts - 1)
    end
  end

  defp await_durable_run_identity(issue, expected_entry) do
    eventually_value(fn ->
      case ProcessOwnership.status_for_issue(issue) do
        %{run_id: run_id, session_id: session_id, live?: true} = ownership
        when run_id == expected_entry.run_id and session_id == expected_entry.session_id ->
          ownership

        _ ->
          nil
      end
    end)
  end

  defp durable_ownership_view(ownership) do
    Map.take(ownership, [
      :state,
      :role,
      :session_id,
      :owned_session_ref,
      :issue_id,
      :cleanup_evidence,
      :run_id,
      :holder,
      :worker_host,
      :workspace_path,
      :updated_at,
      :cleanup_status,
      :app_server_pid,
      :worker_pid,
      :issue_identifier,
      :failure_observation,
      :app_server_pgid,
      :quarantine_reason
    ])
  end

  defp wait_until_monotonic_age(age_ms) do
    deadline = System.monotonic_time(:millisecond) + age_ms
    wait_until_monotonic_deadline(deadline)
  end

  defp wait_until_monotonic_deadline(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: Process.sleep(remaining)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp unique_test_root(label) do
    Path.join(System.tmp_dir!(), "symphony-elixir-#{label}-#{System.unique_integer([:positive])}")
  end
end
