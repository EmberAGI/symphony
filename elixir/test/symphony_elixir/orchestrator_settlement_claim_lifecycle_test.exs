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

  @empty_codex_totals %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")
    on_exit(fn -> restore_env("SYMPHONY_ROLE", previous_role) end)
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
  # Helpers
  # ---------------------------------------------------------------------------
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
