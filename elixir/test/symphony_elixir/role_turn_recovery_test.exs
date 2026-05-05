defmodule SymphonyElixir.RoleTurnRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RoleTurnRecovery

  @active_states MapSet.new(["todo", "in progress", "agent fixes", "rework", "agent review", "agent qa", "merging", "backlog"])
  @terminal_states MapSet.new(["done", "closed", "cancelled", "canceled", "duplicate"])

  test "EMB-171-style in-progress workpad without final handoff recovers to Agent Fixes" do
    issue = %Issue{
      id: "issue-171",
      identifier: "EMB-171",
      title: "Restart attempt aborted before handoff",
      state: "In Progress",
      branch_name: "admin/emb-171-restart-safe-role-stack",
      comments: [
        %{
          id: "workpad",
          body: "## Codex Workpad\n\nImplementation started; restart attempted before final handoff."
        }
      ]
    }

    marker = %{
      "issue_id" => issue.id,
      "identifier" => issue.identifier,
      "role" => "implementer",
      "state" => "In Progress",
      "started_at" => "2026-05-05T01:02:03Z"
    }

    assert {:recover, "Agent Fixes", body} =
             RoleTurnRecovery.recovery_plan_for_test(issue, marker, @active_states, @terminal_states)

    assert body =~ "## Operator Note"
    assert body =~ "symphony:aborted-role-turn-recovery"
    assert body =~ "Detected an aborted Symphony role turn before a final handoff."
    assert body =~ "Recovery route: `Agent Fixes`."
    assert body =~ "Branch context preserved: `admin/emb-171-restart-safe-role-stack`."
  end

  test "existing recovery marker prevents duplicate comments while preserving the route" do
    issue = %Issue{
      id: "issue-171",
      identifier: "EMB-171",
      title: "Already recovered",
      state: "In Progress",
      comments: [
        %{
          id: "recovery",
          body: "## Operator Note\n\n<!-- symphony:aborted-role-turn-recovery issue=EMB-171 role=implementer state=In Progress target=Agent Fixes -->"
        }
      ]
    }

    marker = %{"issue_id" => issue.id, "role" => "implementer", "state" => "In Progress"}

    assert :already_recovered =
             RoleTurnRecovery.recovery_plan_for_test(issue, marker, @active_states, @terminal_states)
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

      assert {:recover, ^target, body} =
               RoleTurnRecovery.recovery_plan_for_test(issue, marker, @active_states, @terminal_states)

      assert body =~ "Recovery route: `#{target}`."
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
end
