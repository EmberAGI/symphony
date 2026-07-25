defmodule SymphonyElixir.OrchestratorSettlementClaimLifecycleTest do
  # EMB-1260 (PR #67, MUST-FIX 1 + MUST-FIX 2): terminal settlement moved the
  # expensive teardown off the GenServer loop, which introduced a THIRD place an
  # issue can live — `state.settlements` — alongside `state.running` and
  # `state.retry_attempts`. Two lifecycle paths never learned about it:
  #
  #   1. `reconcile_orphaned_claims/1` builds its active-claim set from `running`
  #      ∪ `retry_attempts` only, so an issue whose run is mid-teardown reads as
  #      unclaimed, has its claim released, and becomes re-dispatchable while its
  #      predecessor is still tearing down — the canary contract's "no equivalent
  #      redispatch" violated.
  #
  #   2. `terminate/2` iterates `running` only, so on orchestrator shutdown every
  #      in-flight settlement is dropped and its ownership record is parked
  #      non-terminal forever. This is the observed production failure: the
  #      EMB-1258 QA record sat at state=retrying / cleanup=retrying with 306
  #      pids and never terminally settled.
  #
  # These are public-interface contracts driven through the orchestrator's own
  # test seam (`reconcile_claims_for_test/1`) and its `terminate/2` callback.
  #
  # Note (macOS vacuity): assertions here are about TYPED OUTCOMES — which
  # lifecycle state a record reached, whether a claim survived — never about
  # owned-pid set CONTENT, which degrades to a tautology off Linux because
  # `/proc/<pid>/environ` does not exist. Nothing here needs a /proc gate.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  @empty_codex_totals %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")

    # ONE workspace root per test. Ownership records are scoped to the workflow's
    # workspace root, so a test that acquires two records must acquire them both
    # under the same root or the first becomes invisible.
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-settlement-claim-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      File.rm_rf(test_root)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # MUST-FIX 1: an in-flight settlement IS an active claim
  # ---------------------------------------------------------------------------
  describe "reconcile_orphaned_claims/1 with in-flight settlements" do
    test "an issue mid-settlement keeps its claim and is not re-dispatchable" do
      issue_id = "issue-emb-1260-settling-claim"
      issue = %Issue{id: issue_id, identifier: "MT-1260CLAIM", state: "In Progress"}

      # The run has already been popped out of `running` and handed to
      # settlement; the issue stays in `claimed` while settling, deliberately.
      # `snapshot: nil` on purpose — settlement snapshot capture is async, so
      # claim reconciliation must never depend on it being populated.
      state =
        base_state(
          claimed: MapSet.new([issue_id]),
          settlements: %{
            make_ref() => settlement(issue_id, issue, snapshot: nil)
          }
        )

      reconciled = Orchestrator.reconcile_claims_for_test(state)

      assert MapSet.member?(reconciled.claimed, issue_id),
             "an issue with an in-flight settlement lost its claim during reconciliation; " <>
               "it is now re-dispatchable while its predecessor is still tearing down"
    end

    test "a genuinely leaked claim is still released" do
      # The guard against over-correcting MUST-FIX 1 into "never release
      # anything": a claim backed by nothing at all must still be reaped.
      leaked_id = "issue-emb-1260-leaked-claim"
      settling_id = "issue-emb-1260-still-settling"
      settling_issue = %Issue{id: settling_id, identifier: "MT-1260SETL", state: "In Progress"}

      state =
        base_state(
          claimed: MapSet.new([leaked_id, settling_id]),
          settlements: %{
            make_ref() => settlement(settling_id, settling_issue, snapshot: nil)
          }
        )

      reconciled = Orchestrator.reconcile_claims_for_test(state)

      refute MapSet.member?(reconciled.claimed, leaked_id),
             "a claim backed by no run, no retry and no settlement must still be released"

      assert MapSet.member?(reconciled.claimed, settling_id)
    end

    test "a settlement carrying a malformed context never crashes reconciliation" do
      # Settlement contexts are internal maps; reconciliation must read the
      # issue id defensively rather than fetch!-ing it.
      state =
        base_state(
          claimed: MapSet.new(["issue-emb-1260-malformed"]),
          settlements: %{make_ref() => %{reason: :normal}}
        )

      assert %Orchestrator.State{} = Orchestrator.reconcile_claims_for_test(state)
    end
  end

  # ---------------------------------------------------------------------------
  # MUST-FIX 2: shutdown must not abandon in-flight settlements
  # ---------------------------------------------------------------------------
  describe "terminate/2 with in-flight settlements" do
    test "an in-flight settlement reaches a terminal ownership state on shutdown" do
      {issue, ownership} = acquire_ownership("terminate-inflight", "MT-1260TERM")

      assert %{state: "active"} = ProcessOwnership.status_for_issue(issue),
             "precondition: the record must start non-terminal"

      # A stand-in for the settlement task: still alive at shutdown, exactly as
      # the real one is when the orchestrator is told to stop mid-teardown.
      task_pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(task_pid), do: Process.exit(task_pid, :kill) end)

      timer_ref = Process.send_after(self(), {:settlement_timeout, make_ref()}, 60_000)

      state =
        base_state(
          claimed: MapSet.new([issue.id]),
          settlements: %{
            make_ref() =>
              settlement(issue.id, issue,
                process_ownership: ownership,
                run_id: ownership.run_id,
                task_pid: task_pid,
                timer_ref: timer_ref,
                snapshot: nil
              )
          }
        )

      assert :ok = Orchestrator.terminate(:shutdown, state)

      # THE contract: the record must not be parked non-terminal forever. This
      # is the observed production failure — EMB-1258's QA record sat at
      # state=retrying / cleanup=retrying with 306 pids and never settled.
      status = ProcessOwnership.status_for_issue(issue)

      refute status.state in ["active", "retrying"],
             "shutdown abandoned an in-flight settlement; the ownership record is parked " <>
               "non-terminal at #{inspect(status.state)}"

      assert status.state == "cleaned",
             "expected the in-flight settlement to reach the terminal cancelled-run state, got " <>
               inspect(status.state)

      # The dying task must not be able to race the shutdown write, and its
      # deadline must not survive the orchestrator.
      refute Process.alive?(task_pid),
             "the in-flight settlement task outlived shutdown and can still race the record write"

      assert Process.read_timer(timer_ref) == false,
             "the settlement deadline timer was left armed across shutdown"
    end

    test "running entries and in-flight settlements both settle, without double-settling" do
      {running_issue, running_ownership} = acquire_ownership("terminate-running", "MT-1260TRUN")
      {settling_issue, settling_ownership} = acquire_ownership("terminate-settling", "MT-1260TSET")

      running_entry = %{
        pid: nil,
        ref: make_ref(),
        identifier: running_issue.identifier,
        issue: running_issue,
        run_id: running_ownership.run_id,
        process_ownership: running_ownership,
        started_at: DateTime.utc_now()
      }

      state =
        base_state(
          running: %{running_issue.id => running_entry},
          claimed: MapSet.new([running_issue.id, settling_issue.id]),
          settlements: %{
            make_ref() =>
              settlement(settling_issue.id, settling_issue,
                process_ownership: settling_ownership,
                run_id: settling_ownership.run_id,
                snapshot: nil
              )
          }
        )

      assert :ok = Orchestrator.terminate(:shutdown, state)

      assert %{state: "cleaned"} = ProcessOwnership.status_for_issue(running_issue)
      assert %{state: "cleaned"} = ProcessOwnership.status_for_issue(settling_issue)

      # Disjointness: the settlement pass must not re-settle the running entry.
      # Re-running terminate over the same state is the observable proxy — a
      # second pass over already-terminal records must still be a typed no-op,
      # never a raise.
      assert :ok = Orchestrator.terminate(:shutdown, state)
    end

    test "terminate is bounded and never raises over a malformed settlement" do
      {issue, ownership} = acquire_ownership("terminate-malformed", "MT-1260TMAL")

      state =
        base_state(
          claimed: MapSet.new([issue.id]),
          settlements: %{
            # A context whose running_entry is unusable, and one that is
            # well-formed: the first must not prevent the second from settling.
            make_ref() => %{issue_id: issue.id, running_entry: :not_a_map, reason: :normal},
            make_ref() => settlement(issue.id, issue, process_ownership: ownership, run_id: ownership.run_id)
          }
        )

      {elapsed_us, result} = :timer.tc(fn -> Orchestrator.terminate(:shutdown, state) end)

      assert result == :ok, "terminate raised or returned a non-:ok over a malformed settlement"

      assert div(elapsed_us, 1000) < 5_000,
             "terminate must stay inside the GenServer shutdown budget; took #{div(elapsed_us, 1000)}ms"

      assert %{state: "cleaned"} = ProcessOwnership.status_for_issue(issue),
             "a malformed settlement context prevented a well-formed one from settling"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  defp acquire_ownership(label, identifier) do
    issue = %Issue{id: "issue-emb-1260-#{label}", identifier: identifier, state: "In Progress"}

    {:ok, ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-#{identifier}",
        holder: ProcessOwnership.holder_id()
      })

    {issue, ownership}
  end

  defp base_state(overrides) do
    defaults = [
      running: %{},
      retry_attempts: %{},
      claimed: MapSet.new(),
      completed: MapSet.new(),
      settlements: %{},
      codex_totals: @empty_codex_totals
    ]

    struct!(Orchestrator.State, Keyword.merge(defaults, overrides))
  end

  defp settlement(issue_id, issue, opts) do
    running_entry = %{
      pid: Keyword.get(opts, :pid),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_id: Keyword.get(opts, :run_id, "run-#{issue.identifier}"),
      process_ownership: Keyword.get(opts, :process_ownership),
      started_at: DateTime.utc_now()
    }

    %{
      issue_id: issue_id,
      running_entry: running_entry,
      reason: :normal,
      snapshot: Keyword.get(opts, :snapshot),
      started_at_ms: System.monotonic_time(:millisecond),
      task_pid: Keyword.get(opts, :task_pid),
      timer_ref: Keyword.get(opts, :timer_ref)
    }
  end
end
