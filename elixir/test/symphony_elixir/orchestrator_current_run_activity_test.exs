defmodule SymphonyElixir.OrchestratorCurrentRunActivityTest do
  use SymphonyElixir.TestSupport

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

    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      case Application.get_env(:symphony_elixir, :handoff_transport_gate) do
        %{owner: owner, token: token} ->
          send(owner, {:handoff_begin_entered, self(), token})

          receive do
            {:release_handoff_begin, ^token} -> :ok
          end

        _ ->
          :ok
      end

      {:ok, %{phase: :working, agent: %{name: agent.name, pane_id: agent.pane_id, agent_status: "working", agent_session: %{value: "handoff-session"}}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      {:ok, %{name: agent.name, pane_id: agent.pane_id, agent_status: "working", agent_session: %{value: "handoff-session"}}}
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
    System.put_env("SYMPHONY_ROLE", "implementer")

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
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    assert_receive {:handoff_begin_entered, runner, ^handoff_gate_token}, 2_000
    initial_snapshot = Orchestrator.snapshot(orchestrator_name, 500)
    initial_activity = running_entry(initial_snapshot, issue.id).last_activity_at_ms

    Application.put_env(:symphony_elixir, :implementer_handoff_settlement_grace_ms, 100)
    wait_until_monotonic_deadline(initial_activity + 150)

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

    _handoff_snapshot =
      eventually_value(fn ->
        case Orchestrator.snapshot(orchestrator_name, 500) do
          %{running: [%{issue_id: issue_id, state: "Agent Review"} | _]} = snapshot
          when issue_id == issue.id ->
            snapshot

          _ ->
            nil
        end
      end)

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

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :RetryReplacementOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(orchestrator)
      File.rm_rf(test_root)
    end)

    predecessor_snapshot = await_provider_sessions(orchestrator_name, control_root, 1)
    predecessor = running_entry(predecessor_snapshot, issue.id)
    predecessor_run_id = predecessor.run_id

    predecessor_envelope =
      predecessor.process_ownership
      |> Map.take([:issue_id, :workspace_path, :role, :holder, :run_id])
      |> Map.put(:ingress_at_ms, System.monotonic_time(:millisecond))

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
              when run_id != predecessor_run_id and is_binary(session_id) ->
                entry

              _ ->
                nil
            end

          _ ->
            nil
        end
      end)

    stale_owned_session = %{cleanup_module: CleanupProbe, owner: self(), marker: :retry_predecessor}

    send(
      orchestrator,
      {:codex_worker_update, issue.id, predecessor_envelope,
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
    assert current.session_id == successor.session_id
    assert current.codex_app_server_pid == successor.codex_app_server_pid
    assert current.codex_total_tokens == successor.codex_total_tokens
    refute unchanged.rate_limits == %{"limit_id" => "stale-retry"}
    assert ProcessOwnership.status_for_issue(issue).run_id == successor.run_id

    send(
      orchestrator,
      {:codex_worker_update, issue.id, predecessor_envelope, %{event: :turn_completed, timestamp: DateTime.utc_now(), session_id: "late-predecessor"}}
    )

    send(orchestrator, {:codex_worker_update, issue.id, %{event: :notification, timestamp: DateTime.utc_now()}})
    send(orchestrator, {:worker_runtime_info, issue.id, %{workspace_path: "/tmp/legacy"}})
    send(orchestrator, {:owned_session_runtime_info, issue.id, stale_owned_session})

    successor_identity =
      successor.process_ownership
      |> Map.take([:issue_id, :workspace_path, :role, :holder, :run_id])

    initial_turn_count = successor.turn_count

    for {session_id, include_provider_timestamp?} <- [
          {"successor-turn-2", true},
          {"successor-turn-3", false}
        ] do
      update = %{event: :session_started, session_id: session_id}

      update =
        if include_provider_timestamp?,
          do: Map.put(update, :timestamp, DateTime.utc_now()),
          else: update

      send(
        orchestrator,
        {:codex_worker_update, issue.id, Map.put(successor_identity, :ingress_at_ms, System.monotonic_time(:millisecond)), update}
      )
    end

    accepted = Orchestrator.snapshot(orchestrator_name, 500)
    accepted_entry = running_entry(accepted, issue.id)
    assert accepted_entry.session_id == "successor-turn-3"
    assert accepted_entry.turn_count == initial_turn_count + 2

    newest_activity_at_ms = accepted_entry.last_activity_at_ms

    for claimed_ingress <- [
          newest_activity_at_ms - 10,
          "malformed",
          nil,
          System.monotonic_time(:millisecond) + 60_000
        ] do
      envelope =
        if is_nil(claimed_ingress),
          do: successor_identity,
          else: Map.put(successor_identity, :ingress_at_ms, claimed_ingress)

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
      send(
        orchestrator,
        {:codex_worker_update, issue.id, Map.put(successor_identity, :ingress_at_ms, System.monotonic_time(:millisecond)),
         %{
           event: :notification,
           timestamp: DateTime.utc_now(),
           usage: cumulative_usage,
           rate_limits: %{"limit_id" => "current", "primary" => %{"remaining" => 9}}
         }}
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
        if Enum.all?(running, &is_binary(&1.session_id)) and
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
