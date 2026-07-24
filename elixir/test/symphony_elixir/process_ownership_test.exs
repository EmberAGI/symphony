defmodule SymphonyElixir.ProcessOwnershipTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-process-ownership-interface-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-process-ownership",
      identifier: "MT-1241",
      title: "Comment-independent ownership",
      state: "In Progress"
    }

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      File.rm_rf(test_root)
    end)

    {:ok, issue: issue}
  end

  test "concurrent same-scope acquisition has exactly one winner", %{issue: issue} do
    contenders =
      for index <- 1..8 do
        Task.async(fn ->
          ProcessOwnership.acquire(issue, ownership_attrs("run-#{index}", "holder-#{index}"))
        end)
      end

    results = Task.await_many(contenders, 5_000)

    assert 1 == Enum.count(results, &match?({:ok, %{state: "active"}}, &1))
    assert 7 == Enum.count(results, &match?({:error, :ownership_held}, &1))
  end

  test "stale takeover has one winner and archives the exact observed record", %{issue: issue} do
    assert {:ok, %{run_id: "stale-run"}} =
             ProcessOwnership.acquire(
               issue,
               ownership_attrs("stale-run", "localhost:999999:implementer")
             )

    contenders =
      for index <- 1..6 do
        Task.async(fn ->
          ProcessOwnership.acquire(issue, ownership_attrs("replacement-#{index}", "holder-#{index}"))
        end)
      end

    results = Task.await_many(contenders, 5_000)

    assert 1 == Enum.count(results, &match?({:ok, %{state: "active"}}, &1))
    assert 5 == Enum.count(results, &match?({:error, :ownership_held}, &1))

    ownership_path = ProcessOwnership.registry_path(issue)
    archived = Path.wildcard(ownership_path <> ".stale-*")
    assert length(archived) == 1
    assert File.read!(List.first(archived)) =~ ~s("run_id":"stale-run")

    {:ok, %{run_id: replacement_run, holder: replacement_holder}} =
      Enum.find(results, &match?({:ok, %{state: "active"}}, &1))

    assert {:ok, %{state: "cleaned"}} =
             ProcessOwnership.release(issue, %{
               holder: replacement_holder,
               run_id: replacement_run
             })

    assert {:ok, %{run_id: "final-run"}} =
             ProcessOwnership.acquire(issue, ownership_attrs("final-run", "final-holder"))

    [latest_archive] = Path.wildcard(ownership_path <> ".stale-*")
    assert File.read!(latest_archive) =~ ~s("run_id":"#{replacement_run}")
  end

  test "verify-update and release fail closed for holder or run mismatch", %{issue: issue} do
    attrs = ownership_attrs("owned-run", "owned-holder")
    assert {:ok, %{state: "active"}} = ProcessOwnership.acquire(issue, attrs)

    assert {:error, :invalid_ownership_state} =
             ProcessOwnership.verify_and_update(
               issue,
               %{holder: "owned-holder", run_id: "owned-run"},
               %{state: "retired"}
             )

    assert {:error, :ownership_mismatch} =
             ProcessOwnership.verify_and_update(
               issue,
               %{holder: "other-holder", run_id: "owned-run"},
               %{state: "retrying"}
             )

    assert {:error, :ownership_mismatch} =
             ProcessOwnership.release(issue, %{holder: "owned-holder", run_id: "other-run"})

    assert {:ok, %{state: "retrying"}} =
             ProcessOwnership.verify_and_update(
               issue,
               %{holder: "owned-holder", run_id: "owned-run"},
               %{state: "retrying", retry_reason: "transient"}
             )

    assert {:ok, %{state: "cleaned"}} =
             ProcessOwnership.release(issue, %{holder: "owned-holder", run_id: "owned-run"})
  end

  test "verify-update cannot rewrite holder, run, role, or workspace scope", %{issue: issue} do
    attrs = ownership_attrs("immutable-run", "immutable-holder")
    assert {:ok, ownership} = ProcessOwnership.acquire(issue, attrs)
    identity = %{holder: ownership.holder, run_id: ownership.run_id, workspace_path: ownership.workspace_path}

    for mutation <- [
          %{holder: "other-holder"},
          %{run_id: "other-run"},
          %{role: "reviewer"},
          %{workspace_path: Path.join(System.tmp_dir!(), "other-workspace")}
        ] do
      assert {:error, :ownership_identity_change} =
               ProcessOwnership.verify_and_update(
                 issue,
                 identity,
                 Map.put(mutation, :state, "retrying")
               )
    end

    assert %{holder: "immutable-holder", run_id: "immutable-run", role: "implementer"} =
             ProcessOwnership.status_for_issue(issue)
  end

  test "malformed ownership state blocks reads, acquisition, update, and release", %{issue: issue} do
    path = ProcessOwnership.registry_path(issue)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not-json\n")

    assert %{"state" => "malformed"} = ProcessOwnership.blocking_record(issue)
    assert %{state: "malformed"} = ProcessOwnership.status_for_issue(issue)

    assert {:error, :malformed_ownership_record} =
             ProcessOwnership.acquire(issue, ownership_attrs("new-run", "new-holder"))

    assert {:error, :malformed_ownership_record} =
             ProcessOwnership.verify_and_update(
               issue,
               %{holder: "new-holder", run_id: "new-run"},
               %{state: "retrying"}
             )

    assert {:error, :malformed_ownership_record} =
             ProcessOwnership.release(issue, %{holder: "new-holder", run_id: "new-run"})
  end

  test "structurally incomplete ownership record fails closed even when its state looks retired", %{
    issue: issue
  } do
    path = ProcessOwnership.registry_path(issue)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"version" => 1, "state" => "cleaned"}) <> "\n")

    assert %{"state" => "malformed"} = ProcessOwnership.blocking_record(issue)
    assert %{state: "malformed"} = ProcessOwnership.status_for_issue(issue)

    assert {:error, :malformed_ownership_record} =
             ProcessOwnership.acquire(issue, ownership_attrs("new-run", "new-holder"))

    File.rm!(path)

    assert {:ok, %{state: "active"}} =
             ProcessOwnership.acquire(issue, ownership_attrs("valid-run", "valid-holder"))

    invalid_state_record =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("state", "retired")
      |> Map.put("cleanup_status", "retired")

    File.write!(path, Jason.encode!(invalid_state_record) <> "\n")

    assert %{state: "malformed"} = ProcessOwnership.status_for_issue(issue)

    assert {:error, :malformed_ownership_record} =
             ProcessOwnership.acquire(issue, ownership_attrs("other-run", "other-holder"))
  end

  test "nonblank remote worker acquisition fails closed", %{issue: issue} do
    attrs =
      "remote-run"
      |> ownership_attrs("remote-holder")
      |> Map.put(:worker_host, "worker-01")

    assert {:error, :remote_worker_not_supported} = ProcessOwnership.acquire(issue, attrs)
    refute File.exists?(ProcessOwnership.registry_path(issue))
  end

  test "orphaned dead local scope lock is recovered before atomic acquisition", %{issue: issue} do
    lock_path = ProcessOwnership.registry_path(issue) <> ".lock"
    File.mkdir_p!(lock_path)

    File.write!(
      Path.join(lock_path, "owner.json"),
      Jason.encode!(%{
        "version" => 1,
        "token" => "dead-generation",
        "worker_host_id" => ProcessOwnership.current_host(),
        "owner_pid" => "999999",
        "created_at_ms" => 0
      })
    )

    assert {:ok, %{state: "active", run_id: "after-lock-crash"}} =
             ProcessOwnership.acquire(
               issue,
               ownership_attrs("after-lock-crash", "replacement-holder")
             )

    refute File.exists?(lock_path)
  end

  test "live and recent malformed scope locks fail closed", %{issue: issue} do
    lock_path = ProcessOwnership.registry_path(issue) <> ".lock"
    File.mkdir_p!(lock_path)

    File.write!(
      Path.join(lock_path, "owner.json"),
      Jason.encode!(%{
        "version" => 1,
        "token" => "live-generation",
        "worker_host_id" => ProcessOwnership.current_host(),
        "owner_pid" => System.pid(),
        "created_at_ms" => System.system_time(:millisecond)
      })
    )

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(issue, ownership_attrs("blocked-run", "blocked-holder"))

    File.rm!(Path.join(lock_path, "owner.json"))

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(issue, ownership_attrs("still-blocked", "blocked-holder"))
  end

  test "acquisition cannot overwrite another holder or run", %{issue: issue} do
    assert {:ok, %{run_id: "owned-run"}} =
             ProcessOwnership.acquire(issue, ownership_attrs("owned-run", "owned-holder"))

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(
               issue,
               ownership_attrs("other-run", "other-holder")
             )

    assert %{run_id: "owned-run", holder: "owned-holder"} =
             ProcessOwnership.status_for_issue(issue)
  end

  test "ownership env exports the exact stable record path", %{issue: issue} do
    attrs =
      ownership_attrs("golden-run", "golden-holder")
      |> Map.put(:workspace_path, "/srv/octo/workspaces/EMB-1241-symphony")

    env = ProcessOwnership.ownership_env(issue, attrs) |> Map.new()

    assert env["SYMPHONY_ROLE_OWNERSHIP_PATH"] ==
             Path.join([
               Config.settings!().workspace.root,
               ".symphony/process-ownership",
               "issue-process-ownership--implementer--EMB-1241-symphony-e95513ffaffb.json"
             ])
  end

  test "home-relative workspace roots export an absolute readable ownership path", %{
    issue: issue
  } do
    home_relative_root =
      "~/.symphony-elixir-process-ownership-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf(Path.expand(home_relative_root))
    end)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      workspace_root: home_relative_root
    )

    attrs = ownership_attrs("home-relative-run", "home-relative-holder")
    env = ProcessOwnership.ownership_env(issue, attrs) |> Map.new()
    ownership_path = env["SYMPHONY_ROLE_OWNERSHIP_PATH"]

    assert Path.type(ownership_path) == :absolute

    assert String.starts_with?(
             ownership_path,
             Path.join(Path.expand(home_relative_root), ".symphony/process-ownership")
           )

    assert {:ok, %{run_id: "home-relative-run"}} =
             ProcessOwnership.acquire(issue, attrs)

    assert File.regular?(ownership_path)
  end

  test "same workspace basename in different paths has distinct ownership scope", %{issue: issue} do
    first =
      ProcessOwnership.ownership_env(
        issue,
        ownership_attrs("first", "holder") |> Map.put(:workspace_path, "/tmp/a/shared")
      )
      |> Map.new()
      |> Map.fetch!("SYMPHONY_ROLE_OWNERSHIP_PATH")

    second =
      ProcessOwnership.ownership_env(
        issue,
        ownership_attrs("second", "holder") |> Map.put(:workspace_path, "/tmp/b/shared")
      )
      |> Map.new()
      |> Map.fetch!("SYMPHONY_ROLE_OWNERSHIP_PATH")

    assert first != second
    assert first =~ "shared-63368f58c90a.json"
    assert second =~ "shared-c22d25ce77ca.json"
  end

  test "stale-session recovery cannot clobber a concurrent takeover", %{issue: issue} do
    stale_attrs =
      ownership_attrs("stale-session-run", "localhost:999999:implementer")
      |> Map.put(:owned_session_ref, %{kind: "herdr", session_name: "octo-stale-session"})

    assert {:ok, _ownership} = ProcessOwnership.acquire(issue, stale_attrs)
    test_pid = self()

    recovery =
      Task.async(fn ->
        ProcessOwnership.recover_stale_owned_sessions(fn _ownership_ref ->
          send(test_pid, {:cleanup_started, self()})

          receive do
            :finish_cleanup -> :ok
          after
            5_000 -> {:error, :cleanup_timeout}
          end
        end)
      end)

    assert_receive {:cleanup_started, recovery_pid}, 1_000

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(issue, ownership_attrs("replacement-run", "replacement-holder"))

    send(recovery_pid, :finish_cleanup)
    assert {:ok, 1} = Task.await(recovery, 5_000)
    assert %{state: "cleaned", run_id: "stale-session-run"} = ProcessOwnership.status_for_issue(issue)

    assert {:ok, %{state: "active", run_id: "replacement-run"}} =
             ProcessOwnership.acquire(issue, ownership_attrs("replacement-run", "replacement-holder"))
  end

  defp ownership_attrs(run_id, holder) do
    %{
      role: "implementer",
      run_id: run_id,
      holder: holder,
      workspace_path: nil
    }
  end
end
