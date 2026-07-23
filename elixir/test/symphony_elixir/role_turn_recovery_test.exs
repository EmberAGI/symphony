defmodule SymphonyElixir.RoleTurnRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RoleTurnRecovery
  alias SymphonyElixir.Runtime.ProcessOwnership

  defmodule OwnedSessionLivenessAdapter do
    def owned_session_liveness(ownership_ref) do
      recipient = Application.fetch_env!(:symphony_elixir, :owned_session_liveness_recipient)
      send(recipient, {:recovery_owned_session_liveness, ownership_ref})
      {:ok, Application.fetch_env!(:symphony_elixir, :owned_session_liveness_result)}
    end
  end

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

    assert_receive {:memory_tracker_comment, "live-issue", body}
    assert body =~ "symphony:aborted-role-turn-recovery"
    assert_receive {:memory_tracker_state_update, "live-issue", "Agent Fixes"}
    refute File.exists?(marker_path)
  end

  test "startup recovery leaves Linear untouched while the native session remains live" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-role-turn-recovery-native-live-#{System.unique_integer([:positive])}"
      )

    recovery_dir = Path.join(test_root, "recovery")
    workspace_root = Path.join(test_root, "workspaces")
    workspace_path = Path.join(workspace_root, "EMB-LIVE-NATIVE-symphony")

    previous_recovery_dir = Application.get_env(:symphony_elixir, :role_turn_recovery_dir)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_adapter = Application.get_env(:symphony_elixir, :owned_session_liveness_module)
    previous_liveness_recipient = Application.get_env(:symphony_elixir, :owned_session_liveness_recipient)
    previous_liveness_result = Application.get_env(:symphony_elixir, :owned_session_liveness_result)

    Application.put_env(:symphony_elixir, :role_turn_recovery_dir, recovery_dir)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :owned_session_liveness_module, OwnedSessionLivenessAdapter)
    Application.put_env(:symphony_elixir, :owned_session_liveness_recipient, self())
    Application.put_env(:symphony_elixir, :owned_session_liveness_result, :live)

    on_exit(fn ->
      restore_app_env(:role_turn_recovery_dir, previous_recovery_dir)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:owned_session_liveness_module, previous_adapter)
      restore_app_env(:owned_session_liveness_recipient, previous_liveness_recipient)
      restore_app_env(:owned_session_liveness_result, previous_liveness_result)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      tracker_active_states: ["In Progress", "Agent Fixes"],
      tracker_terminal_states: ["Done"]
    )

    issue = %Issue{
      id: "live-native-issue",
      identifier: "EMB-LIVE-NATIVE",
      title: "Still live in Herdr",
      state: "In Progress",
      branch_name: "agent/live-native-turn",
      repository: "EmberAGI/symphony"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert :ok = RoleTurnRecovery.record_turn_start(issue)

    assert :ok =
             ProcessOwnership.record_quarantined(
               issue,
               %{
                 role: "implementer",
                 holder: "#{ProcessOwnership.current_host()}:999999:implementer",
                 run_id: "run-live-native-recovery",
                 workspace_path: workspace_path,
                 owned_session_ref: %{
                   kind: "herdr",
                   session_name: "octo-emb-live-native",
                   agent_name: "implementer_orchestrator"
                 }
               },
               "startup cleanup verification pending"
             )

    assert :ok = RoleTurnRecovery.recover_pending_turns(@active_states, @terminal_states, [])

    assert_receive {:recovery_owned_session_liveness, %{session_name: "octo-emb-live-native", agent_name: "implementer_orchestrator"}}

    refute_receive {:memory_tracker_comment, "live-native-issue", _body}, 100
    refute_receive {:memory_tracker_state_update, "live-native-issue", _state}, 100
    assert File.exists?(Path.join(recovery_dir, "live-native-issue.json"))
  end

  test "startup recovery fails closed when live process evidence lacks native session identity" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-role-turn-recovery-process-only-#{System.unique_integer([:positive])}"
      )

    recovery_dir = Path.join(test_root, "recovery")
    workspace_root = Path.join(test_root, "workspaces")
    workspace_path = Path.join(workspace_root, "EMB-LIVE-PROCESS-symphony")

    previous_recovery_dir = Application.get_env(:symphony_elixir, :role_turn_recovery_dir)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    Application.put_env(:symphony_elixir, :role_turn_recovery_dir, recovery_dir)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      restore_app_env(:role_turn_recovery_dir, previous_recovery_dir)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      tracker_active_states: ["In Progress", "Agent Fixes"],
      tracker_terminal_states: ["Done"]
    )

    issue = %Issue{
      id: "live-process-only-issue",
      identifier: "EMB-LIVE-PROCESS",
      title: "Still live without native identity",
      state: "In Progress",
      branch_name: "agent/live-process-turn",
      repository: "EmberAGI/symphony"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert :ok = RoleTurnRecovery.record_turn_start(issue)

    assert :ok =
             ProcessOwnership.record_active(issue, %{
               role: "implementer",
               holder: "#{ProcessOwnership.current_host()}:999999:implementer",
               run_id: "run-live-process-recovery",
               workspace_path: workspace_path,
               app_server_pid: System.pid()
             })

    assert :ok = RoleTurnRecovery.recover_pending_turns(@active_states, @terminal_states, [])

    refute_receive {:memory_tracker_comment, "live-process-only-issue", _body}, 100
    refute_receive {:memory_tracker_state_update, "live-process-only-issue", _state}, 100
    assert File.exists?(Path.join(recovery_dir, "live-process-only-issue.json"))
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

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
