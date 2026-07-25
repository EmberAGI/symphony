defmodule SymphonyElixir.OrchestratorServiceabilityTest do
  # EMB-1260: the QA-role orchestrator wedged after a routing turn because the
  # single Orchestrator GenServer ran expensive, shell-forking OS teardown and
  # liveness work INLINE on its own serial mailbox. While a terminal :DOWN
  # settlement was in flight the state snapshot and work-admission calls — both
  # GenServer.calls into the same process — timed out (snapshot_timeout /
  # orchestrator_unavailable), the ownership record stayed active/active, and a
  # continuation retry loop re-entered the same failing scans indefinitely.
  #
  # These are public-interface regression contracts: the orchestrator must stay
  # serviceable during terminal settlement, settlement must reach a bounded
  # typed outcome even when cleanup hangs, and teardown/liveness evaluation must
  # be batched and bounded (no per-PID fork fan-out over recorded process
  # trees).
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  defmodule SlowCleanup do
    @moduledoc """
    Owned-session cleanup double whose physical teardown is SLOW: it blocks
    the settlement work for a configured duration so the test can prove the
    GenServer stays serviceable while settlement is in flight.
    """

    def cleanup_owned_session(%{sleep_ms: sleep_ms} = ref) do
      if is_pid(Map.get(ref, :notify_pid)),
        do: send(ref.notify_pid, {:slow_cleanup_started, Map.get(ref, :session_name)})

      Process.sleep(sleep_ms)

      if is_pid(Map.get(ref, :notify_pid)),
        do: send(ref.notify_pid, {:slow_cleanup_finished, Map.get(ref, :session_name)})

      :ok
    end
  end

  defmodule HangingCleanup do
    @moduledoc """
    Owned-session cleanup double that NEVER returns: it reproduces the
    production wedge where terminal teardown hangs and, on the inline path,
    blocks the GenServer forever.
    """

    def cleanup_owned_session(ref) do
      if is_pid(Map.get(ref, :notify_pid)),
        do: send(ref.notify_pid, {:hanging_cleanup_started, Map.get(ref, :session_name)})

      Process.sleep(:infinity)
    end
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")

    previous_settlement_timeout =
      Application.get_env(:symphony_elixir, :terminal_settlement_timeout_ms)

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_app_env(:terminal_settlement_timeout_ms, previous_settlement_timeout)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Contract 1: SNAPSHOT SERVICEABILITY
  # ---------------------------------------------------------------------------
  test "snapshot stays serviceable while a slow terminal settlement is in flight" do
    {pid, name, _generation, _issue, ref} =
      start_orchestrator_with_running_entry(
        "serviceability-snapshot",
        "issue-emb-1260-snapshot",
        "MT-1260SNAP",
        owned_session_ref: %{
          kind: "test-owned-session",
          session_name: "octo-emb-1260-snap",
          cleanup_module: SlowCleanup,
          notify_pid: self(),
          sleep_ms: 2_000
        }
      )

    # The terminal :DOWN kicks off settlement whose physical teardown blocks for
    # 2s. Inline, that 2s of OS work sits at the head of the GenServer mailbox.
    send(pid, {:DOWN, ref, :process, self(), :normal})
    assert_receive {:slow_cleanup_started, "octo-emb-1260-snap"}, 1_000

    # A snapshot with a 500ms deadline must still return a map — bounded
    # staleness is acceptable, a call timeout is a contract violation.
    result = Orchestrator.snapshot(name, 500)

    assert is_map(result),
           "expected snapshot to return a map while settlement was in flight, got #{inspect(result)}"

    # And it recovers fully once settlement finishes.
    assert_receive {:slow_cleanup_finished, "octo-emb-1260-snap"}, 5_000
  end

  # ---------------------------------------------------------------------------
  # Contract 2: ADMISSION SERVICEABILITY
  # ---------------------------------------------------------------------------
  test "work admission stays serviceable while a slow terminal settlement is in flight" do
    generation = "emb-1260-admission-gen"

    {pid, name, observed_generation, _issue, ref} =
      start_orchestrator_with_running_entry(
        "serviceability-admission",
        "issue-emb-1260-admission",
        "MT-1260ADM",
        execution_generation: generation,
        owned_session_ref: %{
          kind: "test-owned-session",
          session_name: "octo-emb-1260-adm",
          cleanup_module: SlowCleanup,
          notify_pid: self(),
          sleep_ms: 2_000
        }
      )

    # The orchestrator's real running execution generation, captured before the
    # wedge; close_work_admission uses it so the reply is a real close, not a
    # generation rejection.
    assert observed_generation == generation

    send(pid, {:DOWN, ref, :process, self(), :normal})
    assert_receive {:slow_cleanup_started, "octo-emb-1260-adm"}, 1_000

    # Drive close_work_admission from an isolated caller and require it to
    # answer within a bound the inline path cannot meet: while settlement holds
    # the GenServer mailbox head-of-line, the call cannot reply, so the caller
    # reports :no_reply here. close_work_admission's own return maps a call
    # timeout to {:error, :unavailable} -> HTTP 503 orchestrator_unavailable.
    caller = self()

    spawn(fn ->
      send(caller, {:admission_result, Orchestrator.close_work_admission(name, observed_generation)})
    end)

    result =
      receive do
        {:admission_result, value} -> value
      after
        800 -> :no_reply
      end

    # Serviceable == the call ANSWERED within the bound with a typed result:
    # {:ok, _} or a typed generation/marker error. The forbidden outcomes are
    # :no_reply (mailbox wedged behind settlement) and {:error, :unavailable}
    # (call timeout -> HTTP 503 orchestrator_unavailable).
    refute result == :no_reply,
           "close_work_admission did not answer within the bound; the mailbox was wedged behind settlement"

    refute result == {:error, :unavailable},
           "close_work_admission timed out into orchestrator_unavailable during settlement"

    assert match?({:ok, _}, result) or match?({:error, reason} when is_atom(reason), result),
           "expected a typed close_work_admission reply, got #{inspect(result)}"

    assert_receive {:slow_cleanup_finished, "octo-emb-1260-adm"}, 5_000
  end

  # ---------------------------------------------------------------------------
  # Contract 3: BOUNDED TYPED SETTLEMENT
  # ---------------------------------------------------------------------------
  test "a hanging terminal settlement reaches a bounded typed outcome and stays serviceable" do
    Application.put_env(:symphony_elixir, :terminal_settlement_timeout_ms, 400)

    {pid, name, _generation, issue, ref} =
      start_orchestrator_with_running_entry(
        "serviceability-bounded",
        "issue-emb-1260-bounded",
        "MT-1260HANG",
        owned_session_ref: %{
          kind: "test-owned-session",
          session_name: "octo-emb-1260-hang",
          cleanup_module: HangingCleanup,
          notify_pid: self(),
          sleep_ms: 0
        }
      )

    send(pid, {:DOWN, ref, :process, self(), :normal})
    assert_receive {:hanging_cleanup_started, "octo-emb-1260-hang"}, 1_000

    # The orchestrator must stay serviceable throughout — the hang must not sit
    # on its mailbox head-of-line.
    assert is_map(Orchestrator.snapshot(name, 500)),
           "orchestrator wedged: snapshot timed out while settlement hung"

    # The ownership record must LEAVE active within a bounded time: quarantined
    # with a typed settlement-timeout reason, cleanup_evidence preserved.
    status =
      assert_eventually_value(fn ->
        case ProcessOwnership.status_for_issue(issue) do
          %{state: "quarantined"} = status -> status
          _other -> nil
        end
      end)

    assert status.quarantine_reason =~ "terminal_settlement",
           "expected a typed terminal-settlement-timeout quarantine reason, got " <>
             inspect(status.quarantine_reason)

    assert %{owned_pids: _owned_pids} = status.cleanup_evidence,
           "settlement-timeout quarantine must still carry cleanup_evidence semantics"

    # The continuation/retry side must carry the typed failure observation so an
    # identical failure repeating is not silently reprocessed as fresh work.
    retry =
      assert_eventually_value(fn ->
        state = :sys.get_state(pid)

        cond do
          match?(%{state: "quarantined"}, get_in(state.retry_attempts, [issue.id, :process_ownership])) ->
            {:retry, state.retry_attempts[issue.id]}

          match?(%{}, Map.get(state.blocked_failures, issue.id)) ->
            {:blocked, Map.get(state.blocked_failures, issue.id)}

          true ->
            nil
        end
      end)

    case retry do
      {:retry, entry} ->
        assert entry.process_ownership.state == "quarantined"

      {:blocked, blocked} ->
        assert is_map(blocked)
    end

    # Orchestrator still serviceable at the end.
    assert is_map(Orchestrator.snapshot(name, 500))
  end

  # ---------------------------------------------------------------------------
  # Contract 4: A SETTLED RECORD IS NEVER CLOBBERED BY ITS OWN DEADLINE
  #
  # The settlement task can land its terminal record write microseconds before
  # the deadline fires, and the mailbox can still process {:settlement_timeout,
  # token} first. The timeout write is identity-checked, not state-checked, so
  # without a current-state read it overwrites a COMPLETED clean settlement with
  # a fabricated typed timeout quarantine — inventing a failure that never
  # happened and destroying the settlement's own observed evidence.
  # ---------------------------------------------------------------------------
  test "a settlement completing at the deadline is never overwritten by a fabricated timeout failure" do
    issue_id = "issue-emb-1260-late-settlement"
    issue = %Issue{id: issue_id, identifier: "MT-1260LATE", state: "In Progress"}

    test_root = unique_test_root("serviceability-late-settlement")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:ok, ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-emb-1260-late-settlement",
               holder: ProcessOwnership.holder_id()
             })

    running_entry = %{
      pid: nil,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_id: ownership.run_id,
      process_ownership: ownership,
      retry_attempt: 1,
      started_at: DateTime.utc_now()
    }

    # Stand-in for the in-flight settlement task. The deadline path must still
    # kill it; keeping it live proves the kill does not depend on the record
    # still being unsettled.
    task_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(task_pid), do: Process.exit(task_pid, :kill) end)

    token = make_ref()

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      settlements: %{
        token => %{
          issue_id: issue_id,
          running_entry: running_entry,
          reason: :normal,
          snapshot: {:ok, %{owned_pids: [4_242], criteria: [], captured_at: iso8601_now()}},
          started_at_ms: System.monotonic_time(:millisecond) - 400,
          task_pid: task_pid,
          timer_ref: nil
        }
      }
    }

    # The task wins the race by microseconds: its terminal record write lands
    # (release -> "cleaned", carrying the evidence settlement actually observed)
    # BEFORE the already-queued deadline message is processed.
    settled_evidence = %{owned_pids: [], live_after: 0, verified: true, captured_at: iso8601_now()}

    assert {:ok, _released} =
             ProcessOwnership.release(
               issue,
               %{
                 holder: ownership.holder,
                 run_id: ownership.run_id,
                 workspace_path: ownership.workspace_path
               },
               %{cleanup_evidence: settled_evidence}
             )

    assert %{state: "cleaned"} = ProcessOwnership.status_for_issue(issue)

    assert {:noreply, updated} = Orchestrator.handle_info({:settlement_timeout, token}, state)

    status = ProcessOwnership.status_for_issue(issue)

    refute status.state == "quarantined",
           "the deadline clobbered an already-settled record into a fabricated quarantine"

    refute (status.quarantine_reason || "") =~ "terminal_settlement_timed_out",
           "a settlement that completed was recorded as timed out: " <>
             inspect(status.quarantine_reason)

    # The settled record hands off to the ordinary retry lease, exactly as a
    # settlement whose result arrived on time does — not to a typed quarantine.
    assert status.state == "retrying",
           "expected the settled record to carry the ordinary retry lease, got " <>
             inspect(status.state)

    assert %{verified: true, live_after: 0} = status.cleanup_evidence,
           "the completed settlement's own evidence was replaced by unverified timeout evidence"

    # The issue lifecycle still finalizes: a retry is scheduled, but on a plain
    # retry lease whose error says the settlement landed late — not a quarantine.
    retry = updated.retry_attempts[issue_id]

    assert is_map(retry), "the deadline must still finalize the issue lifecycle"

    assert retry.error =~ "terminal_settlement_completed_late",
           "the retry must record late completion, not a fabricated timeout: " <>
             inspect(retry.error)

    refute match?(%{state: "quarantined"}, retry.process_ownership),
           "a completed settlement must not force a quarantined retry lease"

    # The in-flight task is still killed, and the token is settled: a
    # {:settlement_result, ...} that raced the kill is a no-op, not a second
    # finalization.
    assert_eventually_value(fn -> if !Process.alive?(task_pid), do: :dead end)
    refute Map.has_key?(updated.settlements, token)

    assert {:noreply, ^updated} =
             Orchestrator.handle_info({:settlement_result, token, %{}}, updated)
  end

  # ---------------------------------------------------------------------------
  # Contract 5: BOUNDED, BATCHED TEARDOWN / LIVENESS
  # ---------------------------------------------------------------------------
  test "status_for_issue over a large stale pid set completes fast without per-pid fork fan-out" do
    issue = %Issue{
      id: "issue-emb-1260-stale-pids",
      identifier: "MT-1260STALE",
      state: "In Progress"
    }

    test_root = unique_test_root("serviceability-stale-pids")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    # ~1000 stale pids. Verify they are dead on this host first; skip any that
    # happen to exist. Per-pid `kill -0` fan-out over these at ~2-5ms/fork would
    # take multiple seconds; a single batched `ps` read is milliseconds.
    live_pids = live_host_pids()
    stale_pids = Enum.reject(60_000..60_999, &MapSet.member?(live_pids, &1))
    assert length(stale_pids) > 900, "expected a large stale pid set for the fan-out probe"

    {:ok, _ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-emb-1260-stale-pids",
        holder: ProcessOwnership.holder_id(),
        process_tree_pids: stale_pids
      })

    {elapsed_us, status} =
      :timer.tc(fn -> ProcessOwnership.status_for_issue(issue) end)

    elapsed_ms = div(elapsed_us, 1000)

    assert is_map(status)

    assert elapsed_ms < 2_000,
           "status_for_issue took #{elapsed_ms}ms over ~#{length(stale_pids)} stale pids; " <>
             "per-pid kill -0 fan-out is the wedge this contract forbids"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  defp start_orchestrator_with_running_entry(root_label, issue_id, identifier, opts) do
    test_root = unique_test_root(root_label)
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: issue_id, identifier: identifier, state: "In Progress"}

    # Keep the immediate first poll cycle benign: an empty in-memory tracker so
    # the orchestrator does not dispatch or crash while we install the running
    # entry and drive settlement by hand.
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    on_exit(fn -> restore_app_env(:memory_tracker_issues, previous_memory_issues) end)

    # The snapshot client resolves the server via `Process.whereis/1`, so the
    # public API is driven through the registered name; `:sys.replace_state`
    # and `send({:DOWN, ...})` still target the pid directly.
    orchestrator_name = Module.concat(__MODULE__, :"#{identifier}Orchestrator")
    start_opts = [name: orchestrator_name]

    start_opts =
      case Keyword.get(opts, :execution_generation) do
        nil -> start_opts
        generation -> Keyword.put(start_opts, :execution_generation, generation)
      end

    {:ok, pid} = Orchestrator.start_link(start_opts)

    # Insulate the test process from the start_link link: while settlement is
    # in flight the orchestrator's mailbox is busy, and we drive it with raw
    # `send`/`:sys` calls — a propagated exit must never fault the test itself.
    Process.unlink(pid)

    on_exit(fn ->
      stop_orchestrator!(pid)
      File.rm_rf(test_root)
    end)

    # Read the running execution generation from a snapshot taken with an empty
    # running map (before the entry is installed), so obtaining it never depends
    # on the very serviceability the tests exercise.
    %{execution_generation: observed_generation} = Orchestrator.snapshot(orchestrator_name, 1_000)

    {:ok, process_ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-#{identifier}",
        holder: ProcessOwnership.holder_id()
      })

    ref = make_ref()
    owned_session_ref = Keyword.fetch!(opts, :owned_session_ref)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      run_id: process_ownership.run_id,
      process_ownership: process_ownership,
      codex_app_server_pid: nil,
      owned_session_ref: Map.put(owned_session_ref, :issue_id, issue.id),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue.id]))
      |> Map.put(:retry_attempts, %{})
    end)

    {pid, orchestrator_name, observed_generation, issue, ref}
  end

  defp live_host_pids do
    case System.cmd("ps", ["-eo", "pid="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_pid_line/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp parse_pid_line(line) do
    case Integer.parse(String.trim(line)) do
      {pid, ""} -> [pid]
      _ -> []
    end
  end

  defp unique_test_root(label) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-#{label}-#{System.unique_integer([:positive])}"
    )
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
