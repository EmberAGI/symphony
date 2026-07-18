defmodule SymphonyElixir.OrchestratorDispatchOwnershipTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership

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

    script =
      "echo $$ > #{parent_pid_file}; sleep 5 >/dev/null 2>&1 & echo $! > #{child_pid_file}; sleep 0.5"

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
    assert ProcessOwnership.owned_process_live?(issue, %{app_server_pid: app_server_pid})

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
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
        sh -c 'echo $$ > #{child_pid_file}; sleep 5' >/dev/null 2>&1 &
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

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")
end
