defmodule SymphonyElixir.OrchestratorHookEscalationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.{ClaimLease, EscalationMarker}

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    System.put_env("SYMPHONY_ROLE", "implementer")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
    end)

    :ok
  end

  test "typed before_run failure blocks the claim and creates one redacted escalation note" do
    parent = self()

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-hook-escalation-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_before_run: """
      printf '%s\\n' '{"kind":"symphony_workspace_hook_result","version":1,"hook":"before_run","classification":"deterministic","family":"missing_required_tool_or_cli","summary":"required wrapper CLI missing token=typed-before-run-secret"}'
      exit 23
      """
    )

    issue_id = "issue-orchestrator-hook-escalation"
    issue_identifier = "EMB-1217-HOOK"
    run_id = "run-orchestrator-hook-escalation"

    claim_lease =
      ClaimLease.new(%{
        comment_id: "hook-retry-epoch",
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        holder: ClaimLease.holder_id(),
        role: ClaimLease.role_name(),
        run_id: run_id,
        attempt: 1,
        state: "active"
      })

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Escalate typed before_run failures",
      state: "In Progress",
      claim_lease: claim_lease,
      claim_leases: [claim_lease]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    on_exit(fn -> File.rm_rf(test_root) end)

    {:ok, runner_pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        AgentRunner.run(issue, parent, run_id: run_id)
      end)

    runner_ref = Process.monitor(runner_pid)

    initial_state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: runner_pid,
          ref: runner_ref,
          identifier: issue_identifier,
          issue: issue,
          claim_lease: claim_lease,
          run_id: run_id,
          workspace_path: nil,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert_receive {:worker_runtime_info, ^issue_id, ^run_id, runtime_info}, 2_000

    assert {:noreply, state_with_runtime_info} =
             Orchestrator.handle_info(
               {:worker_runtime_info, issue_id, run_id, runtime_info},
               initial_state
             )

    assert_receive {:memory_tracker_claim_lease, ^issue_id, active_lease}, 500
    assert active_lease.state == "active"

    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, down_reason}, 2_000
    assert {:irrecoverable_runtime_failed, runner_failure} = down_reason
    assert runner_failure.family == :missing_required_tool_or_cli
    assert runner_failure.subtype == "before_run_hook"
    refute runner_failure.retry_reason =~ "typed-before-run-secret"

    assert {:noreply, blocked_state} =
             Orchestrator.handle_info(
               {:DOWN, runner_ref, :process, runner_pid, down_reason},
               state_with_runtime_info
             )

    blocked_failure = blocked_state.blocked_failures[issue_id]

    durable_failure_values =
      blocked_state
      |> Map.take([:failure_observations, :blocked_failures, :retry_attempts])
      |> inspect()

    assert blocked_failure.family == :missing_required_tool_or_cli
    assert blocked_failure.subtype == "before_run_hook"
    assert Map.has_key?(blocked_state.blocked_failures, issue_id)
    refute Map.has_key?(blocked_state.running, issue_id)
    refute Map.has_key?(blocked_state.retry_attempts, issue_id)
    assert MapSet.member?(blocked_state.claimed, issue_id)

    assert_receive {:memory_tracker_claim_lease, ^issue_id, blocked_lease}, 500
    assert blocked_lease.state == "blocked"
    refute durable_failure_values =~ "typed-before-run-secret"
    refute inspect(blocked_failure) =~ "typed-before-run-secret"
    refute inspect(blocked_lease) =~ "typed-before-run-secret"

    assert {:ok, [%Issue{} = escalated_issue]} = Tracker.fetch_issue_states_by_ids([issue_id])
    assert escalated_issue.state == "Human Escalation"
    assert Enum.count(escalated_issue.labels, &(&1 == "Human Escalation")) == 1
    assert [%{body: note}] = escalated_issue.comments
    assert {:ok, marker} = EscalationMarker.parse(note)
    assert marker.retry_epoch == "hook-retry-epoch"
    assert note =~ "## Operator Note"
    assert note =~ "before_run_hook"
    assert note =~ "before_run"
    assert note =~ "required wrapper CLI missing"
    refute note =~ "typed-before-run-secret"

    assert_receive {:memory_tracker_comment, ^issue_id, ^note}, 500
    assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 500
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}, 500
    refute_receive {:memory_tracker_comment, ^issue_id, _duplicate_note}, 100
    refute_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 100
    refute_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}, 100
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
