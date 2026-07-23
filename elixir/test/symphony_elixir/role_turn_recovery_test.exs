defmodule SymphonyElixir.RoleTurnRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RoleTurnRecovery

  @active_states MapSet.new(["todo", "in progress", "agent fixes", "rework", "agent review", "agent qa", "merging", "backlog"])
  @terminal_states MapSet.new(["done", "closed", "cancelled", "canceled", "duplicate"])

  test "in-progress turn recovery is independent of issue comments" do
    issue = %Issue{
      id: "issue-171",
      identifier: "EMB-171",
      title: "Restart attempt aborted before handoff",
      state: "In Progress",
      branch_name: "admin/emb-171-restart-safe-role-stack"
    }

    marker = %{
      "issue_id" => issue.id,
      "identifier" => issue.identifier,
      "role" => "implementer",
      "state" => "In Progress",
      "started_at" => "2026-05-05T01:02:03Z"
    }

    assert {:recover, "Agent Fixes"} =
             RoleTurnRecovery.recovery_plan_for_test(issue, marker, @active_states, @terminal_states)
  end

  test "recovery planning needs no comment marker" do
    issue = %Issue{
      id: "issue-171",
      identifier: "EMB-171",
      title: "Already recovered",
      state: "In Progress"
    }

    marker = %{"issue_id" => issue.id, "role" => "implementer", "state" => "In Progress"}

    assert {:recover, "Agent Fixes"} =
             RoleTurnRecovery.recovery_plan_for_test(issue, marker, @active_states, @terminal_states)
  end

  test "live pending markers are skipped until the role turn becomes orphaned" do
    recovery_dir =
      Path.join(System.tmp_dir!(), "symphony-role-turn-recovery-live-#{System.unique_integer([:positive])}")

    previous_recovery_dir = Application.get_env(:symphony_elixir, :role_turn_recovery_dir)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    Application.put_env(:symphony_elixir, :role_turn_recovery_dir, recovery_dir)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      restore_app_env(:role_turn_recovery_dir, previous_recovery_dir)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(recovery_dir)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress", "Agent Fixes"],
      tracker_terminal_states: ["Done"]
    )

    issue = %Issue{
      id: "live-issue",
      identifier: "EMB-LIVE",
      title: "Long running role turn",
      state: "In Progress",
      branch_name: "agent/live-turn"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert :ok = RoleTurnRecovery.record_turn_start(issue)
    marker_path = Path.join(recovery_dir, "live-issue.json")
    assert File.exists?(marker_path)

    assert :ok = RoleTurnRecovery.recover_pending_turns(@active_states, @terminal_states, [issue.id])

    refute_receive {:memory_tracker_comment, _, _}, 50
    refute_receive {:memory_tracker_state_update, _, _}, 50
    assert File.exists?(marker_path)

    assert :ok = RoleTurnRecovery.recover_pending_turns(@active_states, @terminal_states, [])

    assert_receive {:memory_tracker_state_update, "live-issue", "Agent Fixes"}
    refute_receive {:memory_tracker_comment, _, _}, 50
    refute File.exists?(marker_path)
  end

  test "role states recover visibly without routing implementation-started work back to Todo" do
    targets = %{
      "In Progress" => "Agent Fixes",
      "Agent Review" => "Agent Review",
      "Agent QA" => "Agent QA",
      "Merging" => "Merging",
      "Backlog" => "Backlog"
    }

    for {state, target} <- targets do
      issue = %Issue{
        id: "issue-#{state}",
        identifier: "EMB-#{String.replace(state, " ", "-")}",
        title: "Recover #{state}",
        state: state
      }

      marker = %{"issue_id" => issue.id, "role" => "role", "state" => state}

      assert {:recover, ^target} =
               RoleTurnRecovery.recovery_plan_for_test(issue, marker, @active_states, @terminal_states)

      refute target == "Todo"
    end
  end

  test "terminal or non-active issues clear stale pending markers" do
    done_issue = %Issue{id: "done", identifier: "EMB-DONE", title: "Done", state: "Done"}
    blocked_issue = %Issue{id: "blocked", identifier: "EMB-B", title: "Blocked", state: "Blocked"}
    marker = %{"issue_id" => "done", "role" => "implementer", "state" => "In Progress"}

    assert :clear = RoleTurnRecovery.recovery_plan_for_test(done_issue, marker, @active_states, @terminal_states)
    assert :clear = RoleTurnRecovery.recovery_plan_for_test(blocked_issue, marker, @active_states, @terminal_states)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
