defmodule SymphonyElixir.RoleFinalizationTrackerDeadlineTest do
  @moduledoc """
  Companion role proof: a completed provider run whose worker-owned final
  tracker refresh stalls must not wedge the role.

  This is the exact EMB-1313 Agent QA finalization wedge. The provider run had
  finished; `AgentRunner` then entered the pre-terminal issue-state refresh,
  which reached `Linear.Client.graphql/3` and blocked there forever. Because
  the runner never exited, the Orchestrator never observed a terminal `DOWN`,
  terminal settlement and cleanup never ran, the ownership registry stayed
  active around a dead app-server PID, and role state plus work-admission
  endpoints became unserviceable until an operator restarted the role.

  The proof drives public role interfaces and the Orchestrator's own dispatch.
  It starts the Orchestrator with `Orchestrator.start_link/1`, opens work
  admission with `Orchestrator.open_work_admission/2`, and lets the poll cycle
  dispatch the real `AgentRunner` itself. Nothing here reads or writes
  Orchestrator state: no `:sys.get_state/1`, no `:sys.replace_state/2`, no
  hand-built `running` entry, no synthetic monitor reference, and no
  hand-delivered `DOWN`. The only doubles are the two seams the repository
  already agrees on — `:linear_client_module` and
  `:delegation_transport_module`.

  The injected Linear client answers Orchestrator-owned reads (candidate
  fetch, dispatch revalidation, running-state reconciliation) directly, and
  drives the *real* `Linear.Client` for the worker-owned pre-terminal refresh
  through an injected request transport that causally signals entry and then
  never returns. It reproduces no repository-owned validation, settlement,
  retry, or cleanup policy.

  What it asserts:

    * role state and work admission answer while the worker-owned request is
      still stalled;
    * the runner exits as exactly `{:irrecoverable_runtime_failed, failure}`
      with `retryable?: false`, `irrecoverable?: true`, and the bounded Linear
      request timeout in its context;
    * the Orchestrator observes the real `DOWN`, runs its real terminal
      settlement, and invokes the explicit external cleanup adapter;
    * after a causal post-settlement barrier the role answers both endpoints
      inside tight bounds, cleanup evidence is durable, and neither the
      stalled request task nor a monitor on it survives.

  Orchestrator-owned tracker reads (`reconcile_running_issues/1`,
  `handle_retry_issue/4`) are bounded by the same deadline but are not the
  subject of this proof.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  # Long enough to probe serviceability while the tracker request is genuinely
  # stalled, short enough to keep the suite fast.
  @deadline_ms 4_000
  @terminal_wait_ms 30_000

  # Test-owned application keys. They exist only so the two injected modules
  # can reach this test process; no production code reads them.
  @probe_key :emb_1315_probe_pid
  @issue_key :emb_1315_candidate_issue
  @orchestrator_key :emb_1315_orchestrator_name

  defp probe_pid, do: Application.get_env(:symphony_elixir, @probe_key)
  defp candidate_issue, do: Application.get_env(:symphony_elixir, @issue_key)

  defp orchestrator_owned? do
    case Application.get_env(:symphony_elixir, @orchestrator_key) do
      nil -> false
      name -> Process.whereis(name) == self()
    end
  end

  defmodule StallingRefreshLinearClient do
    @moduledoc """
    Installed at the repository's `:linear_client_module` seam.

    Orchestrator-owned reads answer immediately with the candidate issue so
    the real poll cycle can find, revalidate, dispatch, and reconcile it. The
    worker-owned pre-terminal refresh is the only stall: it goes through the
    real `SymphonyElixir.Linear.Client`, with only its request transport
    injected, so the production total-request deadline is what bounds it.
    """

    alias SymphonyElixir.Linear.Client
    alias SymphonyElixir.RoleFinalizationTrackerDeadlineTest, as: Proof

    def fetch_candidate_issues, do: {:ok, [Proof.candidate_issue_for_double()]}

    def fetch_issues_by_states(_state_names), do: {:ok, [Proof.candidate_issue_for_double()]}

    def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
      if Proof.orchestrator_owned_read?() do
        issue = Proof.candidate_issue_for_double()
        {:ok, Enum.filter([issue], &(&1.id in issue_ids))}
      else
        stalled_worker_refresh(issue_ids)
      end
    end

    def graphql(query, variables \\ %{}, opts \\ [])

    def graphql(_query, _variables, _opts), do: {:error, :emb_1315_unexpected_graphql}

    # The worker-owned final refresh: the real client, a real supervised
    # request task, and a transport that causally signals entry then blocks on
    # a message that is never sent. Nothing here decides what the failure
    # means — the client types it and the runtime classifies it.
    defp stalled_worker_refresh(issue_ids) do
      probe = Proof.probe_pid_for_double()

      # Ancestry is captured here, inside the live refreshing process, so the
      # proof that this run is the Orchestrator's own supervised dispatch can
      # never race the deadline that is about to kill it.
      send(
        probe,
        {:worker_refresh_entered, self(), Process.get(:"$ancestors"), Process.get(:"$callers")}
      )

      Client.fetch_issue_states_by_ids_for_test(issue_ids, fn query, variables ->
        Client.graphql(query, variables,
          request_fun: fn _payload, _headers ->
            send(probe, {:tracker_request_entered, self()})

            receive do
              :never_sent -> {:ok, %{status: 200, body: %{}}}
            end
          end
        )
      end)
    end
  end

  defmodule CompletingTransport do
    @moduledoc """
    Installed at the repository's `:delegation_transport_module` seam.

    Its orchestrator turn completes normally, so the run reaches the
    pre-terminal tracker refresh — the only place this proof stalls. The
    owned-session capability it hands back is the explicit external cleanup
    adapter the Orchestrator must invoke at terminal settlement; running it
    reports to the test process so cleanup is observable.
    """

    alias SymphonyElixir.RoleFinalizationTrackerDeadlineTest, as: Proof

    def default_server_snapshot(_context),
      do: {:ok, %{status: "running", version: "0.8.2", protocol: 20, socket: "/tmp/default.sock"}}

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

    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      send(Proof.probe_pid_for_double(), {:provider_turn_started, self()})

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

    # Only serializable data crosses the ownership record; the test process is
    # reached through the test-owned application key instead.
    def owned_session_ref(session, _context) do
      %{cleanup_module: __MODULE__, session_name: session.name}
    end

    def cleanup_owned_session(ref) do
      send(Proof.probe_pid_for_double(), {:cleanup_probe_ran, Map.get(ref, :session_name)})
      :ok
    end
  end

  @doc false
  @spec probe_pid_for_double() :: pid()
  def probe_pid_for_double, do: probe_pid()

  @doc false
  @spec candidate_issue_for_double() :: Issue.t()
  def candidate_issue_for_double, do: candidate_issue()

  @doc false
  @spec orchestrator_owned_read?() :: boolean()
  def orchestrator_owned_read?, do: orchestrator_owned?()

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    previous_orchestrator_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker_provider = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")

    System.put_env("SYMPHONY_ROLE", "implementer")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "codex")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_orchestrator_provider)
      restore_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker_provider)

      Application.delete_env(:symphony_elixir, @probe_key)
      Application.delete_env(:symphony_elixir, @issue_key)
      Application.delete_env(:symphony_elixir, @orchestrator_key)
    end)

    :ok
  end

  test "a stalled worker-owned tracker refresh still reaches a typed irrecoverable outcome and keeps the role serviceable" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-emb-1315-role-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    issue = %Issue{
      id: "issue-emb-1315-role",
      identifier: "MT-1315ROLE",
      title: "Bound tracker requests before role finalization",
      state: "In Progress",
      repository: "EmberAGI/demo-repo",
      labels: ["implementation-effort:moderate"]
    }

    orchestrator_name = Module.concat(__MODULE__, :RoleFinalizationOrchestrator)

    Application.put_env(:symphony_elixir, @probe_key, self())
    Application.put_env(:symphony_elixir, @issue_key, issue)
    Application.put_env(:symphony_elixir, @orchestrator_key, orchestrator_name)

    # Both external seams are the repository's already-agreed injection
    # points. `SymphonyElixir.TestSupport` restores whatever was installed
    # before this test on exit.
    Application.put_env(:symphony_elixir, :linear_client_module, StallingRefreshLinearClient)
    Application.put_env(:symphony_elixir, :delegation_transport_module, CompletingTransport)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: "project",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      tracker_request_timeout_ms: @deadline_ms
    )

    on_exit(fn -> release_issue_ownership(issue) end)

    {:ok, orchestrator_pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "emb-1315-role-proof",
        work_admission_marker_path: Path.join(test_root, "work-admission.json")
      )

    Process.unlink(orchestrator_pid)
    on_exit(fn -> stop_orchestrator!(orchestrator_pid) end)

    %{execution_generation: generation} = Orchestrator.snapshot(orchestrator_name, @terminal_wait_ms)

    # Publicly open admission, then publicly ask for a poll cycle. The
    # Orchestrator fetches the candidate, revalidates it, acquires ownership,
    # and dispatches the real `AgentRunner` into its own supervised task.
    assert {:ok, %{status: "open"}} =
             Orchestrator.open_work_admission(orchestrator_name, generation)

    assert %{queued: true} = Orchestrator.request_refresh(orchestrator_name)

    # Causal barrier chain: the provider turn ran, the worker-owned refresh
    # was entered by the dispatched runner, and its request is now stalled
    # inside the real client.
    assert_receive {:provider_turn_started, _turn_pid}, @terminal_wait_ms

    assert_receive {:worker_refresh_entered, runner_pid, runner_ancestors, runner_callers},
                   @terminal_wait_ms

    runner_ref = Process.monitor(runner_pid)

    assert_receive {:tracker_request_entered, request_pid}, @terminal_wait_ms

    # The run under test is the one the Orchestrator dispatched itself: the
    # issue is in its public running set, and the stalled runner was started
    # by the Orchestrator into the supervisor it dispatches into.
    assert running_issue_identifier(orchestrator_name, issue) == issue.identifier

    assert Process.whereis(SymphonyElixir.TaskSupervisor) in runner_ancestors,
           "the stalled run was not dispatched into the Orchestrator's task supervisor"

    assert orchestrator_pid in List.wrap(runner_callers),
           "the stalled run was not started by the Orchestrator under test"

    # While the worker-owned request is genuinely stalled, both role endpoints
    # must still answer.
    assert is_map(Orchestrator.snapshot(orchestrator_name, 500)),
           "role state timed out while a worker-owned tracker request was stalled"

    assert_admission_serviceable(orchestrator_name, generation)

    # The wedge: without a total tracker-request deadline this DOWN never
    # arrives, so nothing below can happen. This is the real exit of the real
    # dispatched runner, observed through a real monitor.
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

    assert {:irrecoverable_runtime_failed, failure} = terminal_reason,
           "expected a typed irrecoverable terminal outcome, got #{inspect(terminal_reason)}"

    assert failure.retryable? == false and failure.irrecoverable? == true,
           "a bounded tracker request failure must stay non-retryable under the explicit retry " <>
             "allowlist, got #{inspect(failure)}"

    assert inspect(terminal_reason) =~ "linear_request_timeout",
           "the terminal outcome must name the bounded tracker request that failed, got " <>
             inspect(terminal_reason)

    refute Process.alive?(request_pid),
           "the stalled tracker request process outlived the run it blocked"

    # The Orchestrator's own monitor fires, its real terminal settlement runs,
    # and it invokes the explicit external cleanup adapter.
    assert_receive {:cleanup_probe_ran, session_name}, @terminal_wait_ms
    assert is_binary(session_name) and session_name != ""

    # Causal post-settlement barrier. Running-entry absence proves nothing:
    # the Orchestrator pops the entry *before* it dispatches the off-loop
    # settlement task, and `cleanup_probe_ran` is emitted from inside that
    # task ahead of classification. The issue appearing in the public
    # `blocked` set is written by `block_irrecoverable_runtime_failure/4`,
    # which only runs when the settlement result has come back to and been
    # finalized on the GenServer loop. Only then do the tight probes below
    # measure steady-state serviceability instead of settlement latency.
    await_settlement_finalized(orchestrator_name, issue)

    # Cleanup evidence is durable on the ownership record the settlement wrote.
    # The record is written before the `blocked` entry the barrier above waited
    # on, so this read needs no further wait.
    status = ProcessOwnership.status_for_issue(issue)

    assert status.state == "blocked",
           "an irrecoverable tracker-deadline failure must settle blocked, got #{inspect(status)}"

    assert is_map(status.cleanup_evidence), "terminal settlement recorded no cleanup evidence"
    assert status.cleanup_evidence.verified == true
    assert status.cleanup_evidence.evidence_status == :captured
    assert status.live? == false
    assert is_nil(status.owned_session_ref), "the owned-session capability was not consumed"

    assert status.quarantine_reason =~ "linear_request_timeout",
           "the durable settlement record must name the bounded tracker request that failed, " <>
             "got #{inspect(status.quarantine_reason)}"

    assert is_map(Orchestrator.snapshot(orchestrator_name, 500)),
           "role state timed out after terminal settlement"

    assert_admission_serviceable(orchestrator_name, generation)

    # No request task and no monitor on it survive the deadline.
    refute Process.alive?(request_pid)

    refute request_pid in Task.Supervisor.children(SymphonyElixir.TaskSupervisor),
           "the shut-down tracker request task is still supervised"

    refute runner_pid in Task.Supervisor.children(SymphonyElixir.TaskSupervisor),
           "the terminated runner task is still supervised"

    {:monitors, monitors} = Process.info(self(), :monitors)

    refute {:process, request_pid} in monitors,
           "a monitor on the shut-down tracker request survived the run"
  end

  # Work admission must answer with a typed reply inside the bound; a missing
  # reply or an :unavailable call timeout is the production 503 wedge.
  defp assert_admission_serviceable(orchestrator_name, generation) do
    caller = self()

    spawn(fn ->
      send(
        caller,
        {:admission_result, Orchestrator.close_work_admission(orchestrator_name, generation)}
      )
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

  defp running_issue_identifier(orchestrator_name, %Issue{id: issue_id}) do
    orchestrator_name
    |> running_entries()
    |> Enum.find_value(fn
      %{issue_id: ^issue_id} = entry -> Map.get(entry, :identifier)
      _entry -> nil
    end)
  end

  defp running_entries(orchestrator_name) do
    orchestrator_name
    |> Orchestrator.snapshot(@terminal_wait_ms)
    |> Map.fetch!(:running)
  end

  defp blocked_entries(orchestrator_name) do
    orchestrator_name
    |> Orchestrator.snapshot(@terminal_wait_ms)
    |> Map.fetch!(:blocked)
  end

  # Settlement is finalized on the loop, and only there, when the irrecoverable
  # failure is recorded in `blocked`.
  defp await_settlement_finalized(orchestrator_name, %Issue{id: issue_id} = issue, attempts \\ 3_000) do
    cond do
      Enum.any?(blocked_entries(orchestrator_name), &(Map.get(&1, :issue_id) == issue_id)) ->
        :ok

      attempts == 0 ->
        flunk("terminal settlement never finalized an irrecoverable block for #{issue_id}")

      true ->
        Process.sleep(10)
        await_settlement_finalized(orchestrator_name, issue, attempts - 1)
    end
  end

  defp release_issue_ownership(issue) do
    case ProcessOwnership.status_for_issue(issue) do
      %{holder: holder, run_id: run_id} = status when is_binary(run_id) ->
        _ =
          ProcessOwnership.release(issue, %{
            holder: holder,
            run_id: run_id,
            workspace_path: Map.get(status, :workspace_path)
          })

        :ok

      _ ->
        :ok
    end
  end
end
