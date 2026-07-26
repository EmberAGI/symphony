defmodule SymphonyElixir.ImplementerHandoffSettlementActivityTest do
  @moduledoc """
  RED: Implementer handoff settlement expires on INACTIVITY, not on elapsed
  wall clock since the handoff.

  Production canary EMB-1306/EMB-1307. The issue routed to `Agent Review` at
  17:55:01.964Z, settlement observation began at 17:55:14.670Z, and forced
  cleanup fired at 17:55:45.874Z capturing eight live owned PIDs with no
  `after_run` and no correlation evidence. The provider was therefore still
  legitimately `working` ~44s after the route and ~31s after settlement began.
  Any fixed wall-clock bound measured from the handoff — 30s, 45s, or larger —
  races a turn that is still making progress; `ImplementerDelegation.Supervision`
  already permits a working turn until its 15-minute stale threshold and hard
  turn budget, and that is the layer that owns a live-but-stale provider turn.

  The bound here is instead anchored on the turn's last observed runtime
  activity. Delegation supervision emits `turn_heartbeat` on every observation
  cycle while the Herdr orchestrator is working, and each such worker update
  refreshes the anchor in the same write that records `last_codex_timestamp`.
  Continuous activity therefore keeps the already-running task alive
  indefinitely; when activity stops, forced cleanup still happens after the
  finite no-activity grace.

  Each test drives the Orchestrator's public callbacks — `handle_info/2` for
  worker updates and `reconcile_issue_states_for_test/2` for reconciliation —
  so neutering only the activity reset or the activity comparison fails
  behaviorally rather than only structurally.
  """
  use SymphonyElixir.TestSupport

  # The tests never sleep: every anchor is placed explicitly on the same
  # monotonic clock the Orchestrator reads, and the inactivity used is an order
  # of magnitude past the grace. The grace itself stays generous so a retained
  # turn cannot age out from scheduling jitter between two assertions — the
  # tests decide retention from the anchor, never from real elapsed time.
  @grace_ms 60_000
  @long_inactivity_ms 300_000

  defmodule RecordingOwnedSessionCleanup do
    def cleanup_owned_session(%{owner: owner, agent_pid: agent_pid, session_name: session_name}) do
      send(owner, {:owned_session_cleanup, session_name, Process.alive?(agent_pid)})
      :ok
    end
  end

  setup do
    previous_grace = Application.get_env(:symphony_elixir, :implementer_handoff_settlement_grace_ms)
    Application.put_env(:symphony_elixir, :implementer_handoff_settlement_grace_ms, @grace_ms)

    on_exit(fn ->
      restore_app_env(:implementer_handoff_settlement_grace_ms, previous_grace)
    end)

    :ok
  end

  describe "runtime activity keeps a settling turn alive" do
    test "a turn_heartbeat past the grace resets the anchor and retains the turn" do
      %{state: state, agent_pid: agent_pid, issue_id: issue_id} =
        settling_state("MT-1307A", @long_inactivity_ms)

      stale_anchor = state.running[issue_id].handoff_settlement_last_activity_at_ms

      assert {:noreply, active_state} =
               Orchestrator.handle_info(turn_heartbeat_update(issue_id), state)

      refreshed_anchor = active_state.running[issue_id].handoff_settlement_last_activity_at_ms

      assert is_integer(refreshed_anchor)

      assert refreshed_anchor - stale_anchor >= @long_inactivity_ms,
             "a turn_heartbeat is proof the provider is still working; it must reset the " <>
               "no-activity anchor, not merely record last_codex_timestamp"

      reconciled =
        Orchestrator.reconcile_issue_states_for_test([handed_off_issue(issue_id, "MT-1307A")], active_state)

      assert Map.has_key?(reconciled.running, issue_id),
             "a turn that reported activity inside the grace was force-cleaned anyway"

      assert MapSet.member?(reconciled.claimed, issue_id)
      assert Process.alive?(agent_pid)
      refute_receive {:owned_session_cleanup, "octo-mt-1307a", _alive?}
    end

    test "repeated activity keeps the turn retained across many settlement observations" do
      %{state: state, agent_pid: agent_pid, issue_id: issue_id} =
        settling_state("MT-1307B", @long_inactivity_ms)

      issue = handed_off_issue(issue_id, "MT-1307B")

      final_state =
        Enum.reduce(1..5, state, fn _cycle, acc ->
          assert {:noreply, active} = Orchestrator.handle_info(turn_heartbeat_update(issue_id), acc)

          # Age the freshly reset anchor past the grace again, exactly as a
          # long-running turn does between two supervision heartbeats.
          aged = age_anchor(active, issue_id, @long_inactivity_ms)

          assert {:noreply, refreshed} =
                   Orchestrator.handle_info(turn_heartbeat_update(issue_id), aged)

          reconciled = Orchestrator.reconcile_issue_states_for_test([issue], refreshed)

          assert Map.has_key?(reconciled.running, issue_id),
                 "a continuously working turn must never age out; supervision's stale-working " <>
                   "threshold and hard turn budget own a live-but-stale provider turn"

          reconciled
        end)

      assert MapSet.member?(final_state.claimed, issue_id)
      assert Process.alive?(agent_pid)
      refute_receive {:owned_session_cleanup, "octo-mt-1307b", _alive?}
    end
  end

  describe "silence still expires" do
    test "no newer activity beyond the grace takes the existing forced-cleanup path" do
      %{state: state, agent_pid: agent_pid, issue_id: issue_id} =
        settling_state("MT-1307C", @long_inactivity_ms)

      reconciled =
        Orchestrator.reconcile_issue_states_for_test([handed_off_issue(issue_id, "MT-1307C")], state)

      refute Map.has_key?(reconciled.running, issue_id),
             "an activity-anchored grace must still be a finite grace"

      refute MapSet.member?(reconciled.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert_receive {:owned_session_cleanup, "octo-mt-1307c", false}
    end
  end

  describe "settlement tracking is scoped to a settling turn" do
    test "returning to an active state clears all settlement tracking fields" do
      %{state: state, issue_id: issue_id} = settling_state("MT-1307D", 0)

      assert is_integer(state.running[issue_id].handoff_settlement_last_activity_at_ms)

      reactivated =
        Orchestrator.reconcile_issue_states_for_test(
          [%{handed_off_issue(issue_id, "MT-1307D") | state: "In Progress"}],
          state
        )

      refute Map.has_key?(
               reactivated.running[issue_id],
               :handoff_settlement_last_activity_at_ms
             ),
             "an issue back in an active state is no longer settling, so it must carry no " <>
               "settlement anchor into a later handoff"

      assert {:noreply, after_activity} =
               Orchestrator.handle_info(turn_heartbeat_update(issue_id), reactivated)

      refute Map.has_key?(
               after_activity.running[issue_id],
               :handoff_settlement_last_activity_at_ms
             ),
             "activity refreshes an existing anchor; it must never enrol a turn that is not " <>
               "settling into settlement tracking"
    end
  end

  # A run-owned Implementer session that already handed off, with its
  # no-activity anchor placed `inactive_ms` in the past on the same monotonic
  # clock the Orchestrator reads.
  defp settling_state(identifier, inactive_ms) do
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
          session_id: nil,
          handoff_settlement_last_activity_at_ms: System.monotonic_time(:millisecond) - inactive_ms,
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

  # The exact worker update delegation supervision emits from `on_heartbeat`
  # while the Herdr orchestrator reads `working`.
  defp turn_heartbeat_update(issue_id) do
    {:codex_worker_update, issue_id,
     %{
       event: :turn_heartbeat,
       timestamp: DateTime.utc_now(),
       agent_status: "working"
     }}
  end

  defp age_anchor(%Orchestrator.State{} = state, issue_id, by_ms) do
    running_entry = Map.fetch!(state.running, issue_id)

    aged_entry =
      Map.update!(running_entry, :handoff_settlement_last_activity_at_ms, &(&1 - by_ms))

    %{state | running: Map.put(state.running, issue_id, aged_entry)}
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
