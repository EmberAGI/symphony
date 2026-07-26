defmodule SymphonyElixir.ImplementerHandoffSettlementCadenceTest do
  @moduledoc """
  RED: the settlement bound must outlive one normal supervision observation
  cycle.

  Production canary EMB-1306. The Implementer performed its own In Progress ->
  Agent Review handoff from inside its turn, so settlement began at 17:55:14.670Z
  while the turn was still live. The grace expired 31.2s later, forced cleanup
  captured `captured_owned_pids=8, owned_pids=[], live_after=0`, and the turn's
  positive `outcome=no_delegation` correlation was never emitted.

  The bound was a standalone `30_000`, exactly the delegation runtime's default
  heartbeat interval. A turn that has already finished its work can still be
  anywhere inside one observation cycle — a bounded status read plus the
  heartbeat pause after it — and only then starts its terminal evidence path.
  So the settlement window expired inside a window supervision was always going
  to spend, and the kill looked like a clean cleanup.

  These tests pin the RELATIONSHIP, not the number: every elapsed time here is
  computed from the delegation runtime's own cadence, so re-flattening the
  bound to one observation cycle (or back to a bare interval) fails them again
  no matter which constants move.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ImplementerDelegation
  alias SymphonyElixir.ImplementerDelegation.Supervision
  alias SymphonyElixir.Orchestrator

  defmodule RecordingOwnedSessionCleanup do
    def cleanup_owned_session(%{owner: owner, agent_pid: agent_pid, session_name: session_name}) do
      send(owner, {:owned_session_cleanup, session_name, Process.alive?(agent_pid)})
      :ok
    end
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")
    previous_grace = Application.get_env(:symphony_elixir, :implementer_handoff_settlement_grace_ms)
    # The default is the production surface under test here.
    Application.delete_env(:symphony_elixir, :implementer_handoff_settlement_grace_ms)

    on_exit(fn ->
      restore_app_env(:implementer_handoff_settlement_grace_ms, previous_grace)
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    :ok
  end

  describe "the default settlement bound is derived from the supervision cadence" do
    test "it exceeds one normal observation cycle instead of equalling it" do
      cycle_ms = Supervision.default_observation_cycle_ms()

      assert cycle_ms ==
               Supervision.default_heartbeat_interval_ms() +
                 Supervision.default_status_read_timeout_ms(),
             "one observation cycle is a bounded status read plus the heartbeat pause after it"

      assert Orchestrator.implementer_handoff_settlement_grace_ms() > cycle_ms,
             "a bound at or under one observation cycle expires inside a window supervision " <>
               "was always going to spend"
    end

    test "it adds the terminal evidence the turn still owes after supervision completes" do
      assert Orchestrator.implementer_handoff_settlement_grace_ms() ==
               Supervision.default_observation_cycle_ms() +
                 ImplementerDelegation.terminal_evidence_allowance_ms(
                   Supervision.default_status_read_timeout_ms()
                 ),
             "the bound must stay derived from cadence plus terminal evidence, not tuned"
    end

    test "raising the heartbeat interval raises the bound with it" do
      slower = Supervision.default_heartbeat_interval_ms() * 2
      status_read_timeout_ms = Supervision.default_status_read_timeout_ms()

      assert ImplementerDelegation.handoff_settlement_bound_ms(slower, status_read_timeout_ms) >
               ImplementerDelegation.default_handoff_settlement_bound_ms(),
             "the bound must track the cadence it is derived from"

      assert ImplementerDelegation.handoff_settlement_bound_ms(slower, status_read_timeout_ms) >
               Supervision.observation_cycle_ms(slower, status_read_timeout_ms),
             "the relationship must hold at every cadence, not only the default one"
    end
  end

  describe "a routed turn inside its own cadence keeps its evidence" do
    test "a turn still inside one normal observation cycle is not force-cleaned" do
      elapsed_ms = Supervision.default_observation_cycle_ms()
      %{state: state, agent_pid: agent_pid, issue_id: issue_id} = settling_state("MT-1306A", elapsed_ms)

      updated_state = Orchestrator.reconcile_issue_states_for_test([handed_off_issue(issue_id, "MT-1306A")], state)

      assert Map.has_key?(updated_state.running, issue_id),
             "the turn was killed inside the observation cycle supervision was always going to spend"

      assert MapSet.member?(updated_state.claimed, issue_id)
      assert Process.alive?(agent_pid)
      refute_receive {:owned_session_cleanup, "octo-mt-1306a", _alive?}
    end

    test "a turn inside its terminal evidence path is not force-cleaned" do
      elapsed_ms =
        Supervision.default_observation_cycle_ms() +
          div(ImplementerDelegation.terminal_evidence_allowance_ms(Supervision.default_status_read_timeout_ms()), 2)

      %{state: state, agent_pid: agent_pid, issue_id: issue_id} = settling_state("MT-1306B", elapsed_ms)

      updated_state = Orchestrator.reconcile_issue_states_for_test([handed_off_issue(issue_id, "MT-1306B")], state)

      assert Map.has_key?(updated_state.running, issue_id),
             "the turn was killed before it could emit its correlation outcome"

      assert Process.alive?(agent_pid)
      refute_receive {:owned_session_cleanup, "octo-mt-1306b", _alive?}
    end
  end

  describe "a genuinely stuck turn stays bounded" do
    test "the derived default still force-cleans and verifies cleanup" do
      elapsed_ms = ImplementerDelegation.default_handoff_settlement_bound_ms() + 1
      %{state: state, agent_pid: agent_pid, issue_id: issue_id} = settling_state("MT-1306C", elapsed_ms)

      updated_state = Orchestrator.reconcile_issue_states_for_test([handed_off_issue(issue_id, "MT-1306C")], state)

      refute Map.has_key?(updated_state.running, issue_id),
             "a derived bound must still be a finite bound"

      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert_receive {:owned_session_cleanup, "octo-mt-1306c", false}
    end
  end

  # A run-owned Implementer session that already handed off, with settlement
  # started `elapsed_ms` ago on the same monotonic clock the orchestrator reads.
  defp settling_state(identifier, elapsed_ms) do
    issue_id = "issue-#{String.downcase(identifier)}"

    agent_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill) end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: identifier,
          issue: %Issue{id: issue_id, state: "In Progress", identifier: identifier},
          started_at: DateTime.utc_now(),
          handoff_settlement_started_at_ms: System.monotonic_time(:millisecond) - elapsed_ms,
          owned_session_ref: %{
            cleanup_module: RecordingOwnedSessionCleanup,
            handoff_settlement: :implementer_turn,
            owner: self(),
            agent_pid: agent_pid,
            session_name: "octo-#{String.downcase(identifier)}"
          }
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    %{state: state, agent_pid: agent_pid, issue_id: issue_id}
  end

  defp handed_off_issue(issue_id, identifier) do
    %Issue{
      id: issue_id,
      identifier: identifier,
      state: "Agent Review",
      title: "Handed off",
      description: "The in-flight turn still owes its terminal correlation evidence.",
      labels: []
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
