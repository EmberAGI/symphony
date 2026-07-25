defmodule SymphonyElixir.OrchestratorSettlementConfigTest do
  # EMB-1260 audit SHOULD-FIX 4b and 4c.
  #
  # 4b: `@settled_ownership_states` omitted `quarantined`. A record quarantined
  # by the settlement's OWN terminal typed write is settled — it has left active
  # on observed evidence — but read back as unsettled forever, so the settlement
  # deadline overwrote it with a fabricated `terminal_settlement_timed_out`
  # quarantine, destroying the settlement's real reason and evidence. That is
  # exactly the property 67-F1 established: never fabricate a timeout failure
  # over a record that already reached a terminal typed write.
  #
  # 4c: the terminal settlement timeout was reachable only through
  # `Application.get_env/2` — a test seam, not a production surface. It is now a
  # `Config.settings!()` value like any other tunable, with the app-env override
  # still winning so existing test seams keep working.
  #
  # Every assertion here is a TYPED OUTCOME (record state, quarantine reason,
  # evidence marker, resolved integer), not ownership pid-set content, so none
  # of it degrades to a tautology on a host without `/proc`.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")
    previous_timeout = Application.get_env(:symphony_elixir, :terminal_settlement_timeout_ms)

    on_exit(fn ->
      restore_app_env(:terminal_settlement_timeout_ms, previous_timeout)
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    :ok
  end

  describe "a quarantined record is a terminal typed write (4b)" do
    test "the deadline never fabricates a timeout over a settlement's own quarantine" do
      settlement_reason = "cleanup_failed observed_by_settlement"

      {issue, updated} =
        run_deadline_over_quarantined_record(
          "own-quarantine",
          "MT-1260B1",
          settlement_reason,
          %{owned_pids: [], live_after: 0, verified: true, captured_at: iso8601_now()}
        )

      status = ProcessOwnership.status_for_issue(issue)

      refute (status.quarantine_reason || "") =~ "terminal_settlement_timed_out",
             "a settlement that already settled typed was recorded as timed out: " <>
               inspect(status.quarantine_reason)

      assert (status.quarantine_reason || "") =~ "terminal_settlement_completed_late",
             "the record must carry the honest late-completion reason: " <>
               inspect(status.quarantine_reason)

      assert %{verified: true, evidence_status: :captured} = status.cleanup_evidence,
             "the settlement's own evidence was replaced by unverified timeout evidence"

      retry = updated.retry_attempts[issue.id]

      assert is_map(retry), "the deadline must still finalize the issue lifecycle"

      assert retry.error =~ "terminal_settlement_completed_late",
             "the retry must record late completion, not a fabricated timeout: " <> inspect(retry.error)
    end

    test "a quarantine carrying unavailable evidence is still a terminal typed write" do
      settlement_reason = "settlement_evidence_unavailable observed_by_settlement"

      {issue, updated} =
        run_deadline_over_quarantined_record(
          "unavailable-quarantine",
          "MT-1260B2",
          settlement_reason,
          %{
            owned_pids: [],
            live_after: 0,
            verified: false,
            captured_at: nil,
            evidence_status: :unavailable
          }
        )

      status = ProcessOwnership.status_for_issue(issue)

      # Evidence marked unavailable is TRUE evidence about what the settlement
      # could observe. Overwriting it with a fabricated timeout claim replaces a
      # true statement with a possibly false one, so this record is settled too.
      refute (status.quarantine_reason || "") =~ "terminal_settlement_timed_out",
             "a record that already reached a terminal typed write was re-quarantined as timed out: " <>
               inspect(status.quarantine_reason)

      assert (status.quarantine_reason || "") =~ "terminal_settlement_completed_late",
             "the record must carry the honest late-completion reason: " <>
               inspect(status.quarantine_reason)

      assert %{evidence_status: :unavailable} = status.cleanup_evidence,
             "the settlement's unavailable-evidence marker was overwritten"

      retry = updated.retry_attempts[issue.id]

      assert is_map(retry) and retry.error =~ "terminal_settlement_completed_late",
             "the retry must record late completion, not a fabricated timeout: " <> inspect(retry)
    end
  end

  describe "terminal settlement timeout is production-configurable (4c)" do
    test "the configured settings value is the production surface" do
      write_settlement_workflow_file!("config-default", nil)

      settings = SymphonyElixir.Config.settings!()

      assert %{agent_runtime: %{terminal_settlement_timeout_ms: timeout_ms}} = settings,
             "the terminal settlement timeout must be reachable from Config.settings!/0"

      assert timeout_ms == 60_000, "the shipped default must stay 60_000"
    end

    test "a configured value is used when no app-env override is set" do
      write_settlement_workflow_file!("config-set", 9_100)

      Application.delete_env(:symphony_elixir, :terminal_settlement_timeout_ms)

      assert SymphonyElixir.Orchestrator.terminal_settlement_timeout_ms() == 9_100,
             "the configured production value must be used when nothing overrides it"
    end

    test "the app-env seam still overrides the configured value" do
      write_settlement_workflow_file!("config-overridden", 9_100)

      Application.put_env(:symphony_elixir, :terminal_settlement_timeout_ms, 137)

      assert SymphonyElixir.Orchestrator.terminal_settlement_timeout_ms() == 137,
             "the existing app-env test seam must keep winning over the config value"
    end

    test "the compiled default survives an unconfigured runtime" do
      write_settlement_workflow_file!("config-absent", nil)

      Application.delete_env(:symphony_elixir, :terminal_settlement_timeout_ms)

      assert SymphonyElixir.Orchestrator.terminal_settlement_timeout_ms() == 60_000,
             "with neither an override nor a configured value the default must hold"
    end
  end

  # Drives the settlement deadline over a record the settlement itself already
  # quarantined typed, exactly as `time_out_terminal_settlement/2` sees it when
  # the task wins the race by microseconds.
  defp run_deadline_over_quarantined_record(label, identifier, quarantine_reason, evidence) do
    issue_id = "issue-emb-1260-#{label}"
    issue = %Issue{id: issue_id, identifier: identifier, state: "In Progress"}

    test_root = unique_test_root("settlement-config-#{label}")
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
               run_id: "run-#{identifier}",
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

    task_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(task_pid), do: Process.exit(task_pid, :kill) end)

    token = make_ref()

    state = %SymphonyElixir.Orchestrator.State{
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

    # The settlement task lands its OWN terminal typed write — a quarantine
    # carrying the reason and evidence it actually observed — before the queued
    # deadline message reaches the mailbox head.
    assert {:ok, _quarantined} =
             ProcessOwnership.verify_and_update(
               issue,
               %{
                 holder: ownership.holder,
                 run_id: ownership.run_id,
                 workspace_path: ownership.workspace_path
               },
               %{
                 state: "quarantined",
                 quarantine_reason: quarantine_reason,
                 cleanup_evidence: evidence
               }
             )

    assert %{state: "quarantined"} = ProcessOwnership.status_for_issue(issue)

    assert {:noreply, updated} =
             SymphonyElixir.Orchestrator.handle_info({:settlement_timeout, token}, state)

    {issue, updated}
  end

  # Renders the standard workflow fixture and, when a value is given, injects
  # `agent_runtime.terminal_settlement_timeout_ms` into it — the production
  # configuration surface — then points the store at it.
  defp write_settlement_workflow_file!(label, timeout_ms) do
    test_root = unique_test_root("settlement-config-#{label}")
    File.mkdir_p!(Path.join(test_root, "workspaces"))
    staging_path = Path.join(test_root, "staging-workflow.yaml")
    workflow_path = Path.join(test_root, "workflow.yaml")

    previous_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(previous_path)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(staging_path,
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      agent_runtime_provider: "codex"
    )

    body = File.read!(staging_path)

    body =
      if is_integer(timeout_ms) do
        String.replace(
          body,
          ~r/^agent_runtime:$/m,
          "agent_runtime:\n  terminal_settlement_timeout_ms: #{timeout_ms}",
          global: false
        )
      else
        body
      end

    File.write!(workflow_path, body)
    Workflow.set_workflow_file_path(workflow_path)

    :ok
  end

  defp iso8601_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp unique_test_root(label) do
    Path.join(System.tmp_dir!(), "symphony-elixir-#{label}-#{System.unique_integer([:positive])}")
  end
end
