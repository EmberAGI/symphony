defmodule SymphonyElixir.SettlementEvidenceFailureTest do
  # EMB-1259 audit MUST-FIX: settlement evidence capture must fail TYPED,
  # never fail open.
  #
  # Terminal settlement writes its own cleanup evidence into the ownership
  # record. When the capture machinery itself fails — the process-table read
  # exits non-zero, returns output that cannot be parsed, or the reader is
  # absent entirely so the capture raises — the settlement previously rescued
  # to an empty capture and recorded
  #   cleanup_evidence: %{verified: true, owned_pids: [], live_after: 0}
  # which is a FORGED cleanup-verified marker: nothing was observed, yet the
  # record claims the run was verified clean and the run is released.
  #
  # A successful-but-empty capture (machinery worked, nothing owned found)
  # must still settle clean; only machinery failure settles typed.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  defmodule CleanupProbe do
    @moduledoc """
    Owned-session cleanup double: physical teardown always succeeds and the
    test observes exactly when it ran.
    """

    def cleanup_owned_session(%{notify_pid: notify_pid} = ownership_ref) when is_pid(notify_pid) do
      send(notify_pid, {:cleanup_probe_ran, Map.get(ownership_ref, :session_name)})
      :ok
    end

    def cleanup_owned_session(_ownership_ref), do: :ok
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    :ok
  end

  describe "capture primitives" do
    test "settlement_snapshot fails typed when the process table read exits non-zero" do
      {issue, ownership} = acquired_ownership("snapshot-exit", "MT-1259F1")

      assert with_process_table(:failing_exit, fn ->
               ProcessOwnership.settlement_snapshot(issue, ownership, [])
             end) == {:error, :settlement_evidence_unavailable}
    end

    test "settlement_snapshot fails typed when the process table output cannot be parsed" do
      {issue, ownership} = acquired_ownership("snapshot-unparseable", "MT-1259F2")

      assert with_process_table(:unparseable, fn ->
               ProcessOwnership.settlement_snapshot(issue, ownership, [])
             end) == {:error, :settlement_evidence_unavailable}
    end

    test "settlement_snapshot fails typed when the process table reader is absent" do
      {issue, ownership} = acquired_ownership("snapshot-absent", "MT-1259F3")

      assert with_process_table(:absent, fn ->
               ProcessOwnership.settlement_snapshot(issue, ownership, [])
             end) == {:error, :settlement_evidence_unavailable}
    end

    test "settlement_snapshot returns a successful empty capture when the machinery works" do
      {issue, ownership} = acquired_ownership("snapshot-healthy", "MT-1259F4")

      assert {:ok, snapshot} = ProcessOwnership.settlement_snapshot(issue, ownership, [])
      assert snapshot.owned_pids == []
      assert is_binary(snapshot.captured_at)
    end

    test "settlement_liveness fails typed when the process table read exits non-zero" do
      snapshot = %{owned_pids: [], criteria: [], captured_at: DateTime.utc_now() |> DateTime.to_iso8601()}

      assert with_process_table(:failing_exit, fn ->
               ProcessOwnership.settlement_liveness(snapshot)
             end) == {:error, :settlement_evidence_unavailable}
    end

    test "settlement_liveness fails typed when the liveness read raises" do
      snapshot = %{owned_pids: [], criteria: [], captured_at: DateTime.utc_now() |> DateTime.to_iso8601()}

      assert with_process_table(:absent, fn ->
               ProcessOwnership.settlement_liveness(snapshot)
             end) == {:error, :settlement_evidence_unavailable}
    end

    test "settlement_liveness verifies an empty snapshot clean when the machinery works" do
      snapshot = %{owned_pids: [], criteria: [], captured_at: DateTime.utc_now() |> DateTime.to_iso8601()}

      assert ProcessOwnership.settlement_liveness(snapshot) == {:ok, %{live_after: 0, live_pids: []}}
    end
  end

  describe "terminal settlement" do
    test "settles typed when the process table read exits non-zero" do
      {status, states, log} = settle_under_process_table(:failing_exit, "settlement-exit", "MT-1259E1")

      assert_settled_evidence_unavailable(status, states, log)
    end

    test "settles typed when the process table output cannot be parsed" do
      {status, states, log} = settle_under_process_table(:unparseable, "settlement-unparseable", "MT-1259E2")

      assert_settled_evidence_unavailable(status, states, log)
    end

    test "settles typed when the process table reader is absent" do
      {status, states, log} = settle_under_process_table(:absent, "settlement-absent", "MT-1259E3")

      assert_settled_evidence_unavailable(status, states, log)
    end

    test "settles verified-clean when capture works and nothing owned survives" do
      {status, states, log} = settle_under_process_table(:healthy, "settlement-healthy", "MT-1259E4")

      # Terminal settlement must RELEASE the record, not merely avoid
      # quarantining it. The continuation lease scheduled straight afterwards
      # legitimately re-marks the released record "retrying", so the released
      # state is transient and the observed transitions carry the assertion.
      assert "cleaned" in states,
             "settlement must release the ownership record; observed states=#{inspect(states)}"

      refute "quarantined" in states,
             "expected clean settlement, observed #{inspect(states)} " <>
               "(quarantine_reason=#{inspect(status.quarantine_reason)})"

      assert %{owned_pids: [], live_after: 0, verified: true, evidence_status: :captured} =
               status.cleanup_evidence

      assert log =~ "Run-owned runtime cleanup verified"
      assert log =~ "owned_pids=[] live_after=0"
      refute log =~ "Run-owned runtime cleanup evidence unavailable"
    end
  end

  defp assert_settled_evidence_unavailable(status, states, log) do
    refute "cleaned" in states,
           "settlement released the run as cleaned on a capture-machinery failure " <>
             "(observed states=#{inspect(states)}, cleanup_evidence=#{inspect(status.cleanup_evidence)})"

    assert status.state == "quarantined",
           "expected typed quarantine, got #{status.state} (quarantine_reason=#{inspect(status.quarantine_reason)})"

    assert status.quarantine_reason =~ "settlement_evidence_unavailable",
           "quarantine reason must name the typed capture failure, got #{inspect(status.quarantine_reason)}"

    assert %{verified: false, evidence_status: :unavailable} = status.cleanup_evidence

    # Nothing was observed, so there is no survivor count to report. A
    # recorded `live_after: 0` reads as "0 survivors confirmed" to any
    # dashboard or query keyed on that field alone.
    assert is_nil(status.cleanup_evidence.live_after),
           "unavailable evidence fabricated a survivor count: " <>
             "live_after=#{inspect(status.cleanup_evidence.live_after)}"

    # A settlement that proved nothing must say so on the operator channel.
    # The verified line is what the production contract and
    # docs/specs/domains/agent-runtime.md name as proof of cleanup: emitting
    # it here would hand every canary gate and log-based verifier forged
    # proof on any host whose process table cannot be read.
    assert log =~ "Run-owned runtime cleanup evidence unavailable",
           "settlement did not report its evidence unavailable on the operator channel"

    assert log =~ "cleanup_reason=settlement_evidence_unavailable"

    refute log =~ "Run-owned runtime cleanup verified",
           "a settlement that captured no evidence emitted the verified cleanup proof line"

    refute log =~ "Run-owned runtime cleanup unverified",
           "unavailable evidence must not be reported as a merely-unverified settlement"
  end

  defp settle_under_process_table(process_table_kind, label, identifier) do
    test_root = unique_test_root(label)
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: "issue-emb-1259-#{label}", identifier: identifier, state: "In Progress"}

    orchestrator_name = Module.concat(__MODULE__, :"Settlement#{identifier}Orchestrator")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(pid)
      File.rm_rf(test_root)
    end)

    {:ok, process_ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-#{identifier}",
        holder: ProcessOwnership.holder_id()
      })

    ref = make_ref()
    install_running_entry(pid, issue, ref, process_ownership)

    {{status, states}, log} =
      with_log(fn ->
        with_process_table(process_table_kind, fn ->
          send(pid, {:DOWN, ref, :process, self(), :normal})

          # Physical teardown still runs: an evidence failure must never skip
          # the cleanup it is supposed to be evidence for.
          assert_receive {:cleanup_probe_ran, _session_name}, 5_000

          await_settlement_status(issue)
        end)
      end)

    {status, states, log}
  end

  defp acquired_ownership(label, identifier) do
    test_root = unique_test_root(label)
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    issue = %Issue{id: "issue-emb-1259-#{label}", identifier: identifier, state: "In Progress"}

    {:ok, ownership} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-#{identifier}",
        holder: ProcessOwnership.holder_id()
      })

    {issue, ownership}
  end

  defp install_running_entry(pid, issue, ref, process_ownership) do
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      run_id: process_ownership.run_id,
      process_ownership: process_ownership,
      owned_session_ref: %{
        kind: "test-owned-session",
        session_name: "octo-#{String.downcase(issue.identifier)}",
        cleanup_module: CleanupProbe,
        notify_pid: self(),
        issue_id: issue.id
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _state ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue.id]))
      |> Map.put(:retry_attempts, %{})
    end)
  end

  # The process table is read through `System.cmd("ps", ...)`, which resolves
  # the executable via PATH at call time. Prepending a shim directory is
  # therefore a seam-free way to break exactly the capture machinery — no
  # production code path is aware of the test.
  defp with_process_table(:healthy, fun), do: fun.()

  defp with_process_table(kind, fun) do
    shim_dir = Path.join(System.tmp_dir!(), "symphony-ps-shim-#{System.unique_integer([:positive])}")
    File.mkdir_p!(shim_dir)
    previous_path = System.get_env("PATH")

    case kind do
      :failing_exit ->
        write_shim!(shim_dir, "ps", "#!/bin/sh\nexit 1\n")
        System.put_env("PATH", shim_dir <> ":" <> previous_path)

      :unparseable ->
        write_shim!(shim_dir, "ps", "#!/bin/sh\necho 'ps: process table unavailable'\nexit 0\n")
        System.put_env("PATH", shim_dir <> ":" <> previous_path)

      :absent ->
        # No `ps` anywhere on PATH: `System.cmd/3` raises, so this covers the
        # capture-crash variant. `kill` stays available (reporting "not
        # live") so the rest of the settlement behaves normally.
        write_shim!(shim_dir, "kill", "#!/bin/sh\nexit 1\n")
        System.put_env("PATH", shim_dir)
    end

    try do
      fun.()
    after
      restore_env("PATH", previous_path)
      File.rm_rf(shim_dir)
    end
  end

  defp write_shim!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp unique_test_root(label) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
