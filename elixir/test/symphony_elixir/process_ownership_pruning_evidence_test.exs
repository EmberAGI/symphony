defmodule SymphonyElixir.ProcessOwnershipPruningEvidenceTest do
  # EMB-1260 audit SHOULD-FIX 4a: `process_tree_pids/2` prunes recorded pids
  # against a process-table snapshot. The snapshot came from the UNTYPED
  # `process_table/0` wrapper, which turns any read failure into `[]` — so a
  # failed read produced an empty live set and silently emptied the recorded
  # pid set, discarding the very evidence a settlement later needs.
  #
  # The module already documents the invariant this violated:
  #   "A failed process-table read is never evidence of an empty table."
  #
  # Pruning is an optimisation over a SUCCESSFUL observation. On an unusable
  # observation it must not run at all: recorded pids are retained unpruned.
  #
  # These assertions are about pruning logic given a forced-failed table read,
  # not about real `/proc` ownership content, so they are meaningful on macOS
  # as well as on Linux.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

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

  describe "process_tree_pids/2 pruning against an unusable process table" do
    test "retains recorded pids when the process-table read exits non-zero" do
      anchor = beam_os_pid()
      recorded = [anchor, live_init_pid(), reaped_os_pid()]

      record =
        with_process_table(:failing_exit, fn ->
          acquire!("prune-exit", "MT-1260A1", anchor, recorded)
        end)

      assert_retains_all(record, recorded)
    end

    test "retains recorded pids when the process-table output cannot be parsed" do
      anchor = beam_os_pid()
      recorded = [anchor, live_init_pid(), reaped_os_pid()]

      record =
        with_process_table(:unparseable, fn ->
          acquire!("prune-unparseable", "MT-1260A2", anchor, recorded)
        end)

      assert_retains_all(record, recorded)
    end

    test "retains recorded pids when the process-table reader is absent" do
      anchor = beam_os_pid()
      recorded = [anchor, live_init_pid(), reaped_os_pid()]

      record =
        with_process_table(:absent, fn ->
          acquire!("prune-absent", "MT-1260A3", anchor, recorded)
        end)

      assert_retains_all(record, recorded)
    end
  end

  describe "process_tree_pids/2 pruning against a usable process table" do
    test "still prunes dead recorded pids and always retains the anchor" do
      anchor = beam_os_pid()
      live = live_init_pid()
      dead = reaped_os_pid()

      record = acquire!("prune-healthy", "MT-1260A4", anchor, [anchor, live, dead])
      recorded_pids = record.process_tree_pids

      # A successful observation is evidence: the dead pid is dropped, and the
      # live pids — including the always-retained app-server anchor — survive.
      assert anchor in recorded_pids
      assert live in recorded_pids
      refute dead in recorded_pids
    end
  end

  defp assert_retains_all(record, recorded) do
    recorded_pids = record.process_tree_pids

    for pid <- recorded do
      assert pid in recorded_pids,
             "recorded pid #{pid} was pruned against an unusable process-table read"
    end
  end

  defp acquire!(label, identifier, anchor, process_tree_pids) do
    test_root = unique_test_root(label)
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    issue = %Issue{id: "issue-emb-1260-#{label}", identifier: identifier, state: "In Progress"}

    {:ok, record} =
      ProcessOwnership.acquire(issue, %{
        role: "implementer",
        run_id: "run-#{identifier}",
        holder: ProcessOwnership.holder_id(),
        app_server_pid: anchor,
        process_tree_pids: process_tree_pids
      })

    record
  end

  defp beam_os_pid, do: String.to_integer(System.pid())

  # pid 1 is the init/launchd process: live on every host that runs this suite.
  defp live_init_pid, do: 1

  # A subshell reports its own pid and then exits, so the pid is genuinely
  # dead by the time the assertion runs.
  defp reaped_os_pid do
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    output |> String.trim() |> String.to_integer()
  end

  # The process table is read through `System.cmd("ps", ...)`, which resolves
  # the executable via PATH at call time. Prepending a shim directory is
  # therefore a seam-free way to break exactly the read machinery — no
  # production code path is aware of the test. Same idiom as the EMB-1259
  # typed-failure suite.
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
        # No `ps` anywhere on PATH: `System.cmd/3` raises, covering the
        # read-crash variant. `kill` stays available (reporting "not live")
        # so the rest of the acquire path behaves normally.
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
    Path.join(System.tmp_dir!(), "symphony-elixir-#{label}-#{System.unique_integer([:positive])}")
  end
end
