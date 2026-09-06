defmodule SymphonyElixir.OrchestratorCurrentRunActivityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.CurrentRun
  alias SymphonyElixir.Runtime.ProcessOwnership
  alias SymphonyElixir.TestSupport.GatedProcessOwnershipFileSystem

  defmodule CleanupProbe do
    def cleanup_owned_session(%{owner: owner, marker: marker}) do
      send(owner, {:stale_owned_session_cleaned, marker})
      :ok
    end
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    previous_file_system = Application.get_env(:symphony_elixir, :process_ownership_file_system)
    previous_gate = Application.get_env(:symphony_elixir, :process_ownership_file_system_gate)

    System.put_env("SYMPHONY_ROLE", "reviewer")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_app_env(:process_ownership_file_system, previous_file_system)
      restore_app_env(:process_ownership_file_system_gate, previous_gate)
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
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

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

  test "retry dispatch replaces the acquired run and rejects the predecessor envelope" do
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

    # The failure trigger is test control only; dispatch, AgentRunner startup,
    # cleanup, retry ownership, and successor dispatch remain the real path.
    predecessor_runner = :sys.get_state(orchestrator).running[issue.id].pid
    Process.exit(predecessor_runner, {:rate_limited, %{message: "retry replacement proof"}})

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %{issue | description: "Changed checkpoint authorizes a distinct successor run."}
    ])

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
  end

  test "replaced and legacy senders cannot mutate the exact current run" do
    issue = issue("issue-tur-878-replaced", "TUR-878-REPLACED")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 30_000,
      codex_stall_timeout_ms: 0
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, predecessor_ownership} = acquire_test_run(issue, "predecessor")
    predecessor = CurrentRun.new(issue, predecessor_ownership)
    {:ok, predecessor_ingress_at_ms} = CurrentRun.observe(predecessor)

    assert {:ok, %{state: "retrying"}} =
             ProcessOwnership.verify_and_update(
               issue,
               ownership_identity(predecessor_ownership),
               %{state: "retrying", retry_reason: "replace the retired run"}
             )

    {:ok, successor_ownership} =
      acquire_test_run(issue, "successor", predecessor_ownership.run_id)

    refute successor_ownership.run_id == predecessor_ownership.run_id
    successor = CurrentRun.new(issue, successor_ownership)
    CurrentRun.retire(predecessor)

    orchestrator_name = Module.concat(__MODULE__, :ExactRunOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)
    worker = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      stop_orchestrator!(orchestrator)
      _ = ProcessOwnership.release(issue, ownership_identity(successor_ownership))
    end)

    process_ref = Process.monitor(worker)
    initial_state = :sys.get_state(orchestrator)

    running_entry = %{
      pid: worker,
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: successor_ownership.workspace_path,
      process_ownership: successor_ownership,
      run_id: successor_ownership.run_id,
      current_run: successor,
      session_id: "successor-session",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: "successor-pid",
      codex_input_tokens: 5,
      codex_output_tokens: 3,
      codex_total_tokens: 8,
      codex_last_reported_input_tokens: 5,
      codex_last_reported_output_tokens: 3,
      codex_last_reported_total_tokens: 8,
      turn_count: 1,
      retry_attempt: 0,
      started_at: DateTime.utc_now(),
      started_at_ms: CurrentRun.activity_ms(successor)
    }

    :sys.replace_state(orchestrator, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue.id]))
    end)

    predecessor_envelope =
      predecessor
      |> CurrentRun.envelope()
      |> Map.put(:ingress_at_ms, predecessor_ingress_at_ms)

    stale_update = %{
      event: :session_started,
      timestamp: DateTime.add(DateTime.utc_now(), 86_400, :second),
      session_id: "predecessor-session",
      codex_app_server_pid: "predecessor-pid",
      usage: %{"input_tokens" => 500, "output_tokens" => 300, "total_tokens" => 800},
      rate_limits: %{"limit_id" => "stale", "primary" => %{"remaining" => 0}}
    }

    send(orchestrator, {:codex_worker_update, issue.id, predecessor_envelope, stale_update})

    send(
      orchestrator,
      {:worker_runtime_info, issue.id, predecessor_envelope, %{worker_host: "stale-host", workspace_path: "/tmp/stale-workspace"}}
    )

    stale_owned_session = %{cleanup_module: CleanupProbe, owner: self(), marker: :predecessor}

    send(
      orchestrator,
      {:owned_session_runtime_info, issue.id, predecessor_envelope, stale_owned_session}
    )

    send(orchestrator, {:codex_worker_update, issue.id, stale_update})
    send(orchestrator, {:worker_runtime_info, issue.id, %{workspace_path: "/tmp/legacy"}})
    send(orchestrator, {:owned_session_runtime_info, issue.id, stale_owned_session})

    unchanged = Orchestrator.snapshot(orchestrator_name, 500)
    unchanged_entry = running_entry(unchanged, issue.id)

    assert_receive {:stale_owned_session_cleaned, :predecessor}, 500
    assert unchanged_entry.session_id == "successor-session"
    assert unchanged_entry.codex_app_server_pid == "successor-pid"
    assert unchanged_entry.codex_input_tokens == 5
    assert unchanged_entry.codex_output_tokens == 3
    assert unchanged_entry.codex_total_tokens == 8
    assert unchanged.rate_limits == nil
    assert ProcessOwnership.status_for_issue(issue).run_id == successor_ownership.run_id

    first_current_envelope = ingress_envelope(successor)

    send(
      orchestrator,
      {:codex_worker_update, issue.id, first_current_envelope, %{event: :session_started, timestamp: DateTime.utc_now(), session_id: "successor-turn-2"}}
    )

    second_current_envelope = ingress_envelope(successor)

    send(
      orchestrator,
      {:codex_worker_update, issue.id, second_current_envelope, %{event: :session_started, timestamp: DateTime.utc_now(), session_id: "successor-turn-3"}}
    )

    accepted = Orchestrator.snapshot(orchestrator_name, 500)
    accepted_entry = running_entry(accepted, issue.id)
    assert accepted_entry.session_id == "successor-turn-3"
    assert accepted_entry.turn_count == 3

    newest_activity_at_ms = accepted_entry.last_activity_at_ms
    base_envelope = CurrentRun.envelope(successor)

    for claimed_ingress <- [
          newest_activity_at_ms - 10,
          "malformed",
          nil,
          System.monotonic_time(:millisecond) + 60_000
        ] do
      envelope =
        if is_nil(claimed_ingress),
          do: base_envelope,
          else: Map.put(base_envelope, :ingress_at_ms, claimed_ingress)

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

    assert running_entry(rejected_clocks, issue.id).last_activity_at_ms ==
             newest_activity_at_ms

    cumulative_usage = %{"input_tokens" => 10, "output_tokens" => 6, "total_tokens" => 16}

    for _duplicate <- 1..2 do
      send(
        orchestrator,
        {:codex_worker_update, issue.id, ingress_envelope(successor),
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
    assert monotonic_entry.codex_input_tokens == 10
    assert monotonic_entry.codex_output_tokens == 6
    assert monotonic_entry.codex_total_tokens == 16
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

      # The staged routine writer is fenced by the changed terminal record,
      # not killed while it owns a temporary-file operation. Once released it
      # must finish typed and remain unable to commit its stale active record.
      assert Process.alive?(writer)
      send(writer, {:release_routine_ownership_write, gate_token})
      assert eventually_value(fn -> if Process.alive?(writer), do: nil, else: true end)

      send(
        orchestrator,
        {:codex_worker_update, issue.id, delayed_envelope, %{event: :notification, timestamp: DateTime.utc_now(), payload: %{method: "late"}}}
      )

      send(
        orchestrator,
        {:routine_process_ownership_result, issue.id, make_ref(), run_id, {:ok, Map.put(terminal_status, :state, "active")}}
      )

      final_snapshot = Orchestrator.snapshot(orchestrator_name, 500)
      refute running_entry(final_snapshot, issue.id)
      refute ProcessOwnership.status_for_issue(issue).state == "active"
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

  defp acquire_test_run(issue, suffix, replaces_run_id \\ nil) do
    attrs = %{
      role: ProcessOwnership.current_role(),
      run_id: "#{suffix}-#{System.unique_integer([:positive])}",
      holder: ProcessOwnership.holder_id(),
      worker_host: nil
    }

    ProcessOwnership.acquire(issue, Map.put(attrs, :replaces_run_id, replaces_run_id))
  end

  defp ownership_identity(ownership) do
    Map.take(ownership, [:holder, :run_id, :workspace_path, :role])
  end

  defp ingress_envelope(current_run) do
    {:ok, ingress_at_ms} = CurrentRun.observe(current_run)
    Map.put(CurrentRun.envelope(current_run), :ingress_at_ms, ingress_at_ms)
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
          while [ ! -f "$emit_file" ]; do sleep 0.01; done
          i=1
          while [ "$i" -le 64 ]; do
            printf '{"method":"item/agentMessage/delta","params":{"delta":"burst-%s"}}\n' "$i"
            i=$((i + 1))
          done
          printf '%s\n' '{"method":"runtime/usage","usage":{"input_tokens":12,"output_tokens":4,"total_tokens":16},"rate_limits":{"limit_id":"burst-limit","primary":{"remaining":9}}}'
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

  defp await_non_active_ownership(issue, orchestrator_name, attempts \\ 1_500)

  defp await_non_active_ownership(issue, orchestrator_name, 0) do
    flunk(
      "ownership stayed active; status=#{inspect(ProcessOwnership.status_for_issue(issue))} " <>
        "snapshot=#{inspect(Orchestrator.snapshot(orchestrator_name, 500))}"
    )
  end

  defp await_non_active_ownership(issue, orchestrator_name, attempts) do
    case ProcessOwnership.status_for_issue(issue) do
      %{state: state} = status when state != "active" ->
        status

      _ ->
        Process.sleep(10)
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
