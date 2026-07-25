defmodule SymphonyElixir.OrchestratorSettlementDispatchTest do
  # EMB-1260 SHOULD-FIX 3: the terminal-settlement DISPATCH itself must be cheap
  # and total.
  #
  # 3a — the Orchestrator loop must not fork a process-table read (`ps`) while
  # dispatching. The settlement TASK captures the pre-teardown snapshot as its
  # first action and reports it back; the loop only stores it. The `:snapshot`
  # key stays present (nil until reported) so every reader — including
  # terminate/2 — sees a well-formed settlement entry, and a settlement that
  # times out before its snapshot arrives degrades to TYPED-UNAVAILABLE
  # evidence rather than fabricating an empty owned set (the 67-F1 discipline).
  #
  # 3b — `Task.Supervisor.start_child/2` returns `DynamicSupervisor.on_start_child()`:
  # `{:ok, pid} | {:ok, pid, info} | :ignore | {:error, reason}`, and EXITS
  # `:noproc` when the supervisor is down (shutdown race). Every one of those
  # outcomes must leave the ownership record in a terminal state instead of
  # crashing the Orchestrator loop or silently losing the settlement.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  defmodule TeardownProbe do
    @moduledoc """
    Owned-session cleanup double that announces when PHYSICAL teardown begins
    and then blocks briefly. Both the snapshot report and this announcement are
    sent by the settlement task itself, so their relative mailbox order is a
    real ordering proof: capture must happen BEFORE any teardown.
    """

    def cleanup_owned_session(ref) do
      if is_pid(Map.get(ref, :notify_pid)),
        do: send(ref.notify_pid, {:teardown_started, Map.get(ref, :session_name)})

      Process.sleep(Map.get(ref, :sleep_ms, 0))
      :ok
    end
  end

  defmodule StubTaskSupervisor do
    @moduledoc """
    Stands in for `SymphonyElixir.TaskSupervisor` under its registered name and
    answers every `start_child` call with one configured `on_start_child` shape,
    so each branch of the contract is driven deterministically.
    """
    use GenServer

    def start_link(reply) do
      GenServer.start_link(__MODULE__, reply, name: SymphonyElixir.TaskSupervisor)
    end

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call(_request, _from, reply), do: {:reply, reply, reply}
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")

    previous_settlement_timeout =
      Application.get_env(:symphony_elixir, :terminal_settlement_timeout_ms)

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_app_env(:terminal_settlement_timeout_ms, previous_settlement_timeout)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # 3a — snapshot capture belongs to the task, not to the loop
  # ---------------------------------------------------------------------------
  test "dispatch stores a nil snapshot and the settlement task captures it before any teardown" do
    {state, _issue, ref} =
      settlement_state("dispatch-offloop", "issue-emb-1260-offloop", "MT-1260OFFL",
        owned_session_ref: %{
          kind: "test-owned-session",
          session_name: "octo-emb-1260-offloop",
          cleanup_module: TeardownProbe,
          notify_pid: self(),
          sleep_ms: 300
        }
      )

    # Driven on the caller (the test process) so `self()` inside dispatch is the
    # test: the task's report lands in OUR mailbox, with zero scheduling races.
    assert {:noreply, dispatched} =
             Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

    assert [{token, settlement}] = Map.to_list(dispatched.settlements)

    # The key must EXIST (terminate/2 and the timeout path both read it)...
    assert Map.has_key?(settlement, :snapshot),
           "every settlement entry must carry a :snapshot key, nil until the task reports one"

    # ...and must be nil, because the loop performed no process-table read.
    assert settlement.snapshot == nil,
           "the Orchestrator loop captured the settlement snapshot inline; " <>
             "capture must happen in the settlement task, got #{inspect(settlement.snapshot)}"

    # Ordering proof: both messages come from the settlement task, so mailbox
    # order is send order. Capture must be its FIRST action.
    first =
      receive do
        {:settlement_snapshot, ^token, snapshot} -> {:snapshot, snapshot}
        {:teardown_started, _session} -> :teardown
      after
        5_000 -> :nothing
      end

    assert match?({:snapshot, _}, first),
           "expected the settlement task to report its snapshot before starting teardown, got " <>
             inspect(first)

    {:snapshot, snapshot} = first

    assert match?({:ok, _}, snapshot) or match?({:error, _}, snapshot),
           "the reported snapshot must be the typed capture result, got #{inspect(snapshot)}"

    assert_receive {:teardown_started, "octo-emb-1260-offloop"}, 5_000
  end

  test "a reported snapshot is stored on its settlement entry" do
    {state, _issue, ref} =
      settlement_state("dispatch-store", "issue-emb-1260-store", "MT-1260STOR", [])

    assert {:noreply, dispatched} =
             Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

    assert [{token, _settlement}] = Map.to_list(dispatched.settlements)

    reported = {:ok, %{owned_pids: [4_242], criteria: [], captured_at: iso8601_now()}}

    assert {:noreply, stored} =
             Orchestrator.handle_info({:settlement_snapshot, token, reported}, dispatched)

    assert stored.settlements[token].snapshot == reported,
           "the reported pre-teardown snapshot was dropped; the timeout path would then " <>
             "have no evidence to preserve"
  end

  test "a snapshot report for an unknown or already-settled token never re-creates a settlement" do
    {state, _issue, ref} =
      settlement_state("dispatch-unknown", "issue-emb-1260-unknown", "MT-1260UNKN", [])

    assert {:noreply, dispatched} =
             Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

    reported = {:ok, %{owned_pids: [], criteria: [], captured_at: iso8601_now()}}

    # Unknown token alongside a live settlement.
    assert {:noreply, untouched} =
             Orchestrator.handle_info({:settlement_snapshot, make_ref(), reported}, dispatched)

    assert untouched.settlements == dispatched.settlements,
           "a report for an unknown token mutated the settlement table"

    # Already-settled: the timeout path popped the entry, and the task's report
    # then arrives. It must NOT resurrect a popped settlement — that entry would
    # never be finalized and would leak into terminate/2.
    settled = %{dispatched | settlements: %{}}

    assert {:noreply, still_empty} =
             Orchestrator.handle_info({:settlement_snapshot, make_ref(), reported}, settled)

    assert still_empty.settlements == %{},
           "a late snapshot report re-created an already-settled settlement entry"
  end

  # Guard contract (already true at HEAD — asserted so it stays true now that a
  # nil snapshot is REACHABLE): a settlement that times out before its task
  # reported anything must record typed-unavailable evidence. Fabricating
  # `verified: true` / an empty observed owned set here is exactly what 67-F1
  # forbids.
  test "a settlement timing out before its snapshot arrives records typed-unavailable evidence" do
    {state, issue, ref} =
      settlement_state("dispatch-nil-evidence", "issue-emb-1260-nilev", "MT-1260NILE", [])

    assert {:noreply, dispatched} =
             Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

    assert [{token, settlement}] = Map.to_list(dispatched.settlements)
    assert settlement.snapshot == nil

    # Take the deadline while :snapshot is still nil.
    assert {:noreply, _timed_out} =
             Orchestrator.handle_info({:settlement_timeout, token}, dispatched)

    status = ProcessOwnership.status_for_issue(issue)

    assert status.state == "quarantined",
           "a settlement timing out must still leave the record active, got #{inspect(status.state)}"

    assert %{evidence_status: :unavailable, verified: false} = status.cleanup_evidence,
           "a never-captured snapshot must degrade to typed-unavailable evidence, never a " <>
             "fabricated clean observation: #{inspect(status.cleanup_evidence)}"
  end

  test "the running orchestrator stores a task-reported snapshot without wedging its loop" do
    Application.put_env(:symphony_elixir, :terminal_settlement_timeout_ms, 60_000)

    {pid, name, issue, ref} =
      start_orchestrator_with_running_entry(
        "dispatch-live",
        "issue-emb-1260-live",
        "MT-1260LIVE",
        owned_session_ref: %{
          kind: "test-owned-session",
          session_name: "octo-emb-1260-live",
          cleanup_module: TeardownProbe,
          notify_pid: self(),
          sleep_ms: 1_500
        }
      )

    send(pid, {:DOWN, ref, :process, self(), :normal})
    assert_receive {:teardown_started, "octo-emb-1260-live"}, 2_000

    assert is_map(Orchestrator.snapshot(name, 500)),
           "the orchestrator wedged while a settlement was in flight"

    # The report crossed the real GenServer mailbox and landed on the entry.
    snapshot =
      assert_eventually_value(fn ->
        :sys.get_state(pid).settlements
        |> Map.values()
        |> Enum.find_value(fn settlement -> settlement.snapshot end)
      end)

    assert match?({:ok, _}, snapshot) or match?({:error, _}, snapshot)

    assert_eventually_value(fn ->
      case ProcessOwnership.status_for_issue(issue) do
        %{state: state} when state != "active" -> state
        _ -> nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # 3b — every on_start_child outcome is total
  # ---------------------------------------------------------------------------
  test "an {:ok, pid, info} start is treated as a started settlement, not a crash" do
    child = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(child), do: Process.exit(child, :kill) end)

    with_stub_task_supervisor({:ok, child, :extra_info}, fn ->
      {state, _issue, ref} =
        settlement_state("dispatch-ok-info", "issue-emb-1260-okinfo", "MT-1260OKIN", [])

      assert {:noreply, dispatched} =
               Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      assert [{_token, settlement}] = Map.to_list(dispatched.settlements),
             "an {:ok, pid, info} start is a STARTED child; the settlement must stay pending"

      assert settlement.task_pid == child
    end)
  end

  test "an :ignore start settles synchronously and logs the degenerate path" do
    assert_degenerate_start_settles(:ignore, "dispatch-ignore", "issue-emb-1260-ignore", "MT-1260IGNR")
  end

  test "an {:error, reason} start settles synchronously and logs the degenerate path" do
    assert_degenerate_start_settles(
      {:error, :max_children},
      "dispatch-error",
      "issue-emb-1260-error",
      "MT-1260ERRR"
    )
  end

  test "a task supervisor that is down exits :noproc and still settles the record" do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)
    on_exit(&restart_task_supervisor/0)

    {state, issue, ref} =
      settlement_state("dispatch-noproc", "issue-emb-1260-noproc", "MT-1260NOPR", [])

    log =
      capture_log(fn ->
        assert {:noreply, dispatched} =
                 Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

        assert dispatched.settlements == %{},
               "a settlement that could not be spawned must not be left pending"
      end)

    assert log =~ "could not start" and log =~ "issue-emb-1260-noproc",
           "a :noproc exit from start_child must be logged at error with its issue_id and reason"

    refute ProcessOwnership.status_for_issue(issue).state == "active",
           "the ownership record stayed silently active after the settlement task could not start"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  defp assert_degenerate_start_settles(reply, label, issue_id, identifier) do
    with_stub_task_supervisor(reply, fn ->
      {state, issue, ref} = settlement_state(label, issue_id, identifier, [])

      log =
        capture_log(fn ->
          assert {:noreply, dispatched} =
                   Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

          assert dispatched.settlements == %{},
                 "a settlement that could not be spawned must not be left pending"
        end)

      assert log =~ "could not start" and log =~ issue_id,
             "the degenerate spawn path must be logged at error with its issue_id and reason"

      refute ProcessOwnership.status_for_issue(issue).state == "active",
             "the ownership record stayed silently active after a #{inspect(reply)} start"
    end)
  end

  defp with_stub_task_supervisor(reply, fun) do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)
    {:ok, stub} = StubTaskSupervisor.start_link(reply)

    try do
      fun.()
    after
      if Process.alive?(stub), do: GenServer.stop(stub, :normal)
      restart_task_supervisor()
    end
  end

  defp restart_task_supervisor do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      nil -> {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)
      _pid -> :ok
    end
  end

  # Builds an Orchestrator.State holding one running entry whose monitor ref is
  # returned, so a terminal :DOWN can be driven by hand.
  defp settlement_state(label, issue_id, identifier, opts) do
    issue = prepare_workflow!(label, issue_id, identifier)

    {:ok, ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-#{identifier}",
        holder: ProcessOwnership.holder_id()
      })

    ref = make_ref()

    running_entry =
      %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        run_id: ownership.run_id,
        process_ownership: ownership,
        codex_app_server_pid: nil,
        retry_attempt: 1,
        started_at: DateTime.utc_now()
      }
      |> maybe_put_owned_session(Keyword.get(opts, :owned_session_ref), issue)

    state = %Orchestrator.State{
      running: %{issue_id => running_entry},
      claimed: MapSet.new([issue_id]),
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      settlements: %{}
    }

    {state, issue, ref}
  end

  defp start_orchestrator_with_running_entry(label, issue_id, identifier, opts) do
    issue = prepare_workflow!(label, issue_id, identifier)

    orchestrator_name = Module.concat(__MODULE__, :"#{identifier}Orchestrator")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    Process.unlink(pid)
    on_exit(fn -> stop_orchestrator!(pid) end)

    {:ok, ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-#{identifier}",
        holder: ProcessOwnership.holder_id()
      })

    ref = make_ref()
    initial_state = :sys.get_state(pid)

    running_entry =
      %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        run_id: ownership.run_id,
        process_ownership: ownership,
        codex_app_server_pid: nil,
        started_at: DateTime.utc_now()
      }
      |> maybe_put_owned_session(Keyword.get(opts, :owned_session_ref), issue)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    {pid, orchestrator_name, issue, ref}
  end

  defp maybe_put_owned_session(running_entry, nil, _issue), do: running_entry

  defp maybe_put_owned_session(running_entry, owned_session_ref, issue),
    do: Map.put(running_entry, :owned_session_ref, Map.put(owned_session_ref, :issue_id, issue.id))

  defp prepare_workflow!(label, issue_id, identifier) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-#{label}-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    %Issue{id: issue_id, identifier: identifier, state: "In Progress"}
  end

  defp iso8601_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

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
