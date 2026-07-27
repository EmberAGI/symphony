defmodule SymphonyElixir.RoleFinalizationTrackerDeadlineTest do
  @moduledoc """
  RED companion: a completed provider run whose final tracker refresh stalls
  must not wedge the role.

  This is the exact EMB-1313 Agent QA finalization wedge. The provider run had
  finished; `AgentRunner` then entered the pre-terminal issue-state refresh,
  which reached `Linear.Client.graphql/3` and blocked there forever. Because
  the runner never exited, the Orchestrator never observed a terminal `DOWN`,
  terminal settlement and cleanup never ran, the ownership registry stayed
  active around a dead app-server PID, and role state plus work-admission
  endpoints became unserviceable until an operator restarted the role.

  The proof drives the public seams only: the runner runs in the same
  supervised task the Orchestrator dispatches it in, the tracker refresh goes
  through the real `Linear.Client` with an injected transport that causally
  signals entry and then never returns, and settlement is driven through the
  Orchestrator's terminal `DOWN` path. It asserts the runner reaches a typed
  failed terminal outcome inside a bounded deadline, that settlement and
  cleanup then execute, and that role state and work admission answer both
  while the stalled request is in flight and after settlement.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  # Long enough to probe serviceability while the tracker request is genuinely
  # stalled, short enough to keep the suite fast.
  @deadline_ms 2_000
  @terminal_wait_ms 20_000

  defmodule CompletingTransport do
    @moduledoc """
    Delegation transport double whose orchestrator turn completes normally, so
    the run reaches the pre-terminal tracker refresh — the only place this test
    stalls. Owned-session teardown reports to the test process so terminal
    cleanup is observable.
    """

    def default_server_snapshot(_context),
      do: {:ok, %{status: "running", version: "0.7.5", protocol: 17, socket: "/tmp/default.sock"}}

    def start_session(spec, _context) do
      {:ok,
       %{
         name: spec.name,
         socket: "/tmp/#{spec.name}/herdr.sock",
         runtime_root: "/tmp/#{spec.name}",
         workspace: spec.workspace
       }}
    end

    def prepare_worker(session, _spec, _context) do
      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}
    end

    def start_agent(_session, spec, _context),
      do: {:ok, %{name: spec.name, pane_id: "w1:p1", agent_status: "idle"}}

    def begin_turn(_session, agent, _prompt, _timeout_ms, context) do
      if test_pid = Map.get(context, :test_pid), do: send(test_pid, :provider_turn_started)

      {:ok,
       %{
         phase: :completed,
         agent: %{name: agent.name, agent_status: "idle", agent_session: %{value: "sess"}}
       }}
    end

    def await_agent(_session, agent, _statuses, _timeout_ms, _context),
      do: {:ok, %{name: agent.name, agent_status: "idle"}}

    def get_agent(_session, agent, _timeout_ms, _context),
      do: {:ok, %{name: agent.name, agent_status: "idle"}}

    def read_agent(_session, _agent, _opts, _context),
      do: {:ok, %{text: "orchestrator turn finished"}}

    def stop_session(_session, _context), do: :ok

    def worker_assignments(_session, _context), do: {:ok, []}

    def owned_session_ref(session, context) do
      %{
        cleanup_module: __MODULE__,
        notify_pid: Map.get(context, :test_pid),
        issue_id: Map.get(context, :issue_id),
        session_name: session.name
      }
    end

    def cleanup_owned_session(%{notify_pid: notify_pid} = ref) when is_pid(notify_pid) do
      send(notify_pid, {:cleanup_probe_ran, Map.get(ref, :session_name)})
      :ok
    end

    def cleanup_owned_session(_ref), do: :ok
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    previous_orchestrator_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker_provider = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    System.put_env("SYMPHONY_ROLE", "implementer")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "codex")
    # Keep the orchestrator's own poll cycle benign; this test drives dispatch
    # and settlement by hand.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_orchestrator_provider)
      restore_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker_provider)

      case previous_memory_issues do
        nil -> Application.delete_env(:symphony_elixir, :memory_tracker_issues)
        issues -> Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
      end
    end)

    :ok
  end

  test "a stalled pre-terminal tracker refresh still reaches a typed terminal outcome and keeps the role serviceable" do
    test_pid = self()

    test_root =
      Path.join(System.tmp_dir!(), "symphony-emb-1315-role-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      tracker_request_timeout_ms: @deadline_ms
    )

    issue = %Issue{
      id: "issue-emb-1315-role",
      identifier: "MT-1315ROLE",
      title: "Bound tracker requests before role finalization",
      state: "In Progress",
      repository: "EmberAGI/demo-repo"
    }

    orchestrator_name = Module.concat(__MODULE__, :RoleFinalizationOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)
    Process.unlink(orchestrator_pid)
    on_exit(fn -> stop_orchestrator!(orchestrator_pid) end)

    %{execution_generation: generation} = Orchestrator.snapshot(orchestrator_name, 1_000)

    {:ok, ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-emb-1315-role",
        holder: ProcessOwnership.holder_id()
      })

    on_exit(fn ->
      _ =
        ProcessOwnership.release(issue, %{
          holder: ownership.holder,
          run_id: ownership.run_id,
          workspace_path: ownership.workspace_path
        })
    end)

    # The pre-terminal refresh goes through the real Linear client; only its
    # request transport is injected, and it never returns.
    stalled_refresh = fn issue_ids ->
      Client.fetch_issue_states_by_ids_for_test(issue_ids, fn query, variables ->
        Client.graphql(query, variables,
          request_fun: fn _payload, _headers ->
            send(test_pid, {:tracker_request_entered, self()})

            receive do
              :never_sent -> {:ok, %{status: 200, body: %{}}}
            end
          end
        )
      end)
    end

    {:ok, runner_pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        AgentRunner.run(issue, nil,
          run_id: ownership.run_id,
          role: "implementer",
          process_ownership: ownership,
          issue_state_fetcher: stalled_refresh,
          delegation_transport: CompletingTransport,
          delegation_transport_context: %{issue_id: issue.id, test_pid: test_pid}
        )
      end)

    runner_ref = Process.monitor(runner_pid)

    # The Orchestrator's view of this run, so its terminal DOWN path settles
    # the same ownership record the runner holds.
    orchestrator_ref = make_ref()
    initial_state = :sys.get_state(orchestrator_pid)

    running_entry = %{
      pid: runner_pid,
      ref: orchestrator_ref,
      identifier: issue.identifier,
      issue: issue,
      run_id: ownership.run_id,
      process_ownership: ownership,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: 1,
      owned_session_ref: %{
        cleanup_module: CompletingTransport,
        notify_pid: test_pid,
        issue_id: issue.id,
        session_name: "octo-emb-1315-role"
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(orchestrator_pid, fn _state ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue.id]))
      |> Map.put(:retry_attempts, %{})
    end)

    # Causal barrier: the provider run completed and the pre-terminal tracker
    # refresh is in flight and stalled.
    assert_receive :provider_turn_started, @terminal_wait_ms
    assert_receive {:tracker_request_entered, request_pid}, @terminal_wait_ms

    # While the stalled request is in flight, both role endpoints must answer.
    assert is_map(Orchestrator.snapshot(orchestrator_name, 500)),
           "role state timed out while a tracker request was stalled"

    assert_admission_serviceable(orchestrator_name, generation)

    # The wedge: without a total tracker-request deadline this DOWN never
    # arrives, so nothing below can happen.
    terminal_reason =
      receive do
        {:DOWN, ^runner_ref, :process, ^runner_pid, reason} -> reason
      after
        @terminal_wait_ms ->
          flunk(
            "the role run never terminated: a completed provider run stalled forever in its " <>
              "pre-terminal tracker refresh"
          )
      end

    refute terminal_reason == :normal,
           "a stalled tracker refresh was reported as a completed run"

    assert match?({:agent_runtime_failed, _reason}, terminal_reason) or
             match?({:irrecoverable_runtime_failed, _failure}, terminal_reason),
           "expected a typed failed terminal outcome, got #{inspect(terminal_reason)}"

    assert inspect(terminal_reason) =~ "linear_request_timeout",
           "the terminal outcome must name the bounded tracker request that failed, got " <>
             inspect(terminal_reason)

    refute Process.alive?(request_pid),
           "the stalled tracker request process outlived the run it blocked"

    # Terminal settlement and cleanup then execute on the ownership record.
    send(orchestrator_pid, {:DOWN, orchestrator_ref, :process, runner_pid, terminal_reason})

    assert_receive {:cleanup_probe_ran, "octo-emb-1315-role"}, @terminal_wait_ms

    {status, _states} = await_settlement_status(issue)
    assert is_map(status.cleanup_evidence), "terminal settlement recorded no cleanup evidence"

    # And the role stays serviceable after settlement.
    assert is_map(Orchestrator.snapshot(orchestrator_name, 500)),
           "role state timed out after terminal settlement"

    assert_admission_serviceable(orchestrator_name, generation)
  end

  # Work admission must answer with a typed reply inside the bound; a missing
  # reply or an :unavailable call timeout is the production 503 wedge.
  defp assert_admission_serviceable(orchestrator_name, generation) do
    caller = self()

    spawn(fn ->
      send(caller, {:admission_result, Orchestrator.close_work_admission(orchestrator_name, generation)})
    end)

    result =
      receive do
        {:admission_result, value} -> value
      after
        1_000 -> :no_reply
      end

    refute result == :no_reply, "work admission did not answer within the bound"
    refute result == {:error, :unavailable}, "work admission timed out into orchestrator_unavailable"

    result
  end
end
