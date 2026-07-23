defmodule SymphonyElixir.OrchestratorDispatchOwnershipTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

  defmodule OwnedSessionLivenessAdapter do
    def owned_session_liveness(ownership_ref) do
      recipient = Application.fetch_env!(:symphony_elixir, :owned_session_liveness_recipient)
      result = Application.fetch_env!(:symphony_elixir, :owned_session_liveness_result)
      send(recipient, {:dispatch_liveness_checked, ownership_ref})
      {:ok, result}
    end
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    :ok
  end

  test "dispatch refuses when a recorded app-server descendant survives after parent exit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-process-tree-ownership-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    File.mkdir_p!(test_root)

    issue = %Issue{
      id: "issue-live-process-tree",
      identifier: "MT-580",
      title: "Live process tree ownership",
      state: "In Progress"
    }

    parent_pid_file = Path.join(test_root, "parent.pid")
    child_pid_file = Path.join(test_root, "child.pid")

    # The child must stay alive through every assertion below even when the
    # suite runs under heavy load; the on_exit TERMs it, so the long sleep is
    # only a last-resort self-cleanup, not the test's clock.
    script =
      "echo $$ > #{parent_pid_file}; sleep 300 >/dev/null 2>&1 & echo $! > #{child_pid_file}; sleep 0.5"

    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        args: [~c"-lc", String.to_charlist(script)]
      ])

    {:os_pid, app_server_pid} = :erlang.port_info(port, :os_pid)

    on_exit(fn ->
      for pid_file <- [child_pid_file, parent_pid_file],
          {:ok, body} <- [File.read(pid_file)],
          {pid, ""} <- [Integer.parse(String.trim(body))] do
        System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf(test_root)
    end)

    assert_eventually(fn ->
      File.exists?(parent_pid_file) and File.exists?(child_pid_file)
    end)

    :ok =
      ProcessOwnership.record_active(issue, %{
        role: "implementer",
        run_id: "run-live-process-tree",
        app_server_pid: app_server_pid
      })

    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert_eventually(fn -> File.exists?(child_pid_file) end)

    child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()
    assert {_, 0} = System.cmd("kill", ["-0", Integer.to_string(child_pid)], stderr_to_stdout: true)

    assert_eventually(fn ->
      ProcessOwnership.owned_process_live?(issue, %{app_server_pid: app_server_pid})
    end)

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch refuses when native liveness finds a quarantined Herdr session" do
    previous_adapter = Application.get_env(:symphony_elixir, :owned_session_liveness_module)
    previous_recipient = Application.get_env(:symphony_elixir, :owned_session_liveness_recipient)
    previous_result = Application.get_env(:symphony_elixir, :owned_session_liveness_result)
    test_root = Path.join(System.tmp_dir!(), "symphony-native-dispatch-fence-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace_path = Path.join(workspace_root, "MT-582-symphony")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    File.mkdir_p!(workspace_path)

    Application.put_env(
      :symphony_elixir,
      :owned_session_liveness_module,
      OwnedSessionLivenessAdapter
    )

    Application.put_env(:symphony_elixir, :owned_session_liveness_recipient, self())
    Application.put_env(:symphony_elixir, :owned_session_liveness_result, :live)

    on_exit(fn ->
      restore_app_env(:owned_session_liveness_module, previous_adapter)
      restore_app_env(:owned_session_liveness_recipient, previous_recipient)
      restore_app_env(:owned_session_liveness_result, previous_result)
      File.rm_rf(test_root)
    end)

    issue = %Issue{
      id: "issue-native-dispatch-fence",
      identifier: "MT-582",
      title: "Native session dispatch fence",
      state: "In Progress",
      repository: "EmberAGI/symphony"
    }

    assert :ok =
             ProcessOwnership.record_quarantined(
               issue,
               %{
                 role: "implementer",
                 run_id: "run-native-dispatch-fence",
                 workspace_path: workspace_path,
                 owned_session_ref: %{
                   kind: "herdr",
                   session_name: "octo-emb-1217-dispatch-fence",
                   agent_name: "implementer_orchestrator"
                 }
               },
               "cleanup verification failed"
             )

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)

    assert_receive {:dispatch_liveness_checked,
                    %{
                      kind: "herdr",
                      session_name: "octo-emb-1217-dispatch-fence",
                      agent_name: "implementer_orchestrator"
                    }}
  end

  test "two orchestrators racing the same issue start at most one top-level role run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-dispatch-fence-race-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-dispatch-fence-race-#{System.unique_integer([:positive])}",
      identifier: "MT-DISPATCH-FENCE",
      title: "Fence concurrent dispatch",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      poll_interval_ms: 1_000_000,
      hook_before_run: "sleep 30"
    )

    first_name = Module.concat(__MODULE__, :DispatchFenceFirst)
    second_name = Module.concat(__MODULE__, :DispatchFenceSecond)
    {:ok, first_pid} = Orchestrator.start_link(name: first_name)
    {:ok, second_pid} = Orchestrator.start_link(name: second_name)

    on_exit(fn ->
      for orchestrator_pid <- [first_pid, second_pid], Process.alive?(orchestrator_pid) do
        orchestrator_pid
        |> :sys.get_state()
        |> Map.get(:running, %{})
        |> Enum.each(fn {_issue_id, running_entry} ->
          case Map.get(running_entry, :pid) do
            pid when is_pid(pid) -> Process.exit(pid, :kill)
            _ -> :ok
          end
        end)
      end

      stop_orchestrator!(first_pid)
      stop_orchestrator!(second_pid)
      File.rm_rf(test_root)
    end)

    assert_receive {:memory_tracker_claim_lease, issue_id, first_lease}, 5_000
    assert issue_id == issue.id

    run_ids = collect_claim_run_ids(issue_id, 300, MapSet.new([first_lease.run_id]))
    assert MapSet.size(run_ids) == 1
  end

  test "dispatch refetches durable ownership after claim upsert and before spawn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-dispatch-final-refetch-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-dispatch-final-refetch-#{System.unique_integer([:positive])}",
      identifier: "MT-DISPATCH-REFETCH",
      title: "Refetch final dispatch ownership",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      poll_interval_ms: 1_000_000,
      hook_before_run: "sleep 30"
    )

    orchestrator_name = Module.concat(__MODULE__, :DispatchFinalRefetch)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid) do
        orchestrator_pid
        |> :sys.get_state()
        |> Map.get(:running, %{})
        |> Enum.each(fn {_issue_id, running_entry} ->
          case Map.get(running_entry, :pid) do
            pid when is_pid(pid) -> Process.exit(pid, :kill)
            _ -> :ok
          end
        end)
      end

      stop_orchestrator!(orchestrator_pid)
      File.rm_rf(test_root)
    end)

    assert_final_refetch_after_claim(issue.id)
  end

  # Late-detached detection is Linux-hosted runtime behavior: it needs /proc
  # for env scanning and setsid to stage a detached fixture process. The guard
  # keeps the non-live gate contract identical on platforms without them; CI
  # and production role hosts always run this test.
  @tag skip:
         if(File.dir?("/proc") and is_binary(System.find_executable("setsid")),
           do: false,
           else: "requires /proc and setsid (Linux late-detached process detection)"
         )
  test "dispatch refuses when a late-detached app-server descendant inherits run ownership" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-late-detached-process-ownership-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace_path = Path.join(workspace_root, "MT-581-symphony")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    File.mkdir_p!(workspace_path)

    issue = %Issue{
      id: "issue-late-detached-process-tree",
      identifier: "MT-581",
      title: "Late detached process tree ownership",
      state: "In Progress",
      repository: "EmberAGI/symphony"
    }

    parent_pid_file = Path.join(test_root, "parent.pid")
    child_pid_file = Path.join(test_root, "child.pid")
    run_id = "run-late-detached-process-tree"
    holder = "holder-late-detached-process-tree"

    script =
      """
      echo $$ > #{parent_pid_file}
      sleep 0.2
      setsid env \
        SYMPHONY_ROLE_RUN_ID=#{run_id} \
        SYMPHONY_ROLE_ISSUE_ID=#{issue.id} \
        SYMPHONY_ROLE_ISSUE_IDENTIFIER=#{issue.identifier} \
        SYMPHONY_ROLE_NAME=implementer \
        SYMPHONY_ROLE_HOLDER=#{holder} \
        SYMPHONY_ROLE_WORKSPACE_PATH=#{workspace_path} \
        sh -c 'echo $$ > #{child_pid_file}; sleep 300' >/dev/null 2>&1 &
      sleep 0.2
      """

    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        args: [~c"-lc", String.to_charlist(script)]
      ])

    {:os_pid, app_server_pid} = :erlang.port_info(port, :os_pid)

    on_exit(fn ->
      for pid_file <- [child_pid_file, parent_pid_file],
          {:ok, body} <- [File.read(pid_file)],
          {pid, ""} <- [Integer.parse(String.trim(body))] do
        System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf(test_root)
    end)

    assert_eventually(fn -> File.exists?(parent_pid_file) end)

    :ok =
      ProcessOwnership.record_active(issue, %{
        role: "implementer",
        run_id: run_id,
        holder: holder,
        workspace_path: workspace_path,
        app_server_pid: app_server_pid
      })

    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert_eventually(fn -> File.exists?(child_pid_file) end)

    child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()
    assert {_, 0} = System.cmd("kill", ["-0", Integer.to_string(child_pid)], stderr_to_stdout: true)
    assert ProcessOwnership.owned_process_live?(issue, %{app_server_pid: app_server_pid})

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  defp assert_eventually(fun, attempts \\ 200)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp collect_claim_run_ids(issue_id, timeout_ms, run_ids) do
    receive do
      {:memory_tracker_claim_lease, ^issue_id, lease} ->
        collect_claim_run_ids(issue_id, timeout_ms, MapSet.put(run_ids, lease.run_id))
    after
      timeout_ms -> run_ids
    end
  end

  defp assert_final_refetch_after_claim(issue_id) do
    receive do
      {:memory_tracker_claim_lease, ^issue_id, _lease} ->
        assert_receive {:memory_tracker_fetch_issue_states_by_ids, [^issue_id]}, 500

      _other_event ->
        assert_final_refetch_after_claim(issue_id)
    after
      5_000 -> flunk("dispatch did not upsert its claim lease")
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
