defmodule SymphonyElixir.OrchestratorDispatchOwnershipTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{Adapter, Client}
  alias SymphonyElixir.Runtime.ProcessOwnership

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    :ok
  end

  test "dispatch and revalidation need no comment or tracker-lease state" do
    issue = %Issue{
      id: "issue-residual-lease",
      identifier: "MT-1241-COMMENTS",
      title: "Residual comment state is inert",
      state: "In Progress"
    }

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)

    assert Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fn [_issue_id] -> {:ok, [issue]} end) ==
             {:ok, issue}
  end

  test "deleting every issue comment preserves dispatch input and no runtime comment mutation exists" do
    payload = %{
      "id" => "issue-comment-deletion-parity",
      "identifier" => "MT-1241-PARITY",
      "title" => "Comment deletion parity",
      "state" => %{"name" => "In Progress"},
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []},
      "attachments" => %{"nodes" => []}
    }

    with_comments =
      Client.normalize_issue_for_test(
        Map.put(payload, "comments", %{
          "nodes" => [
            %{"id" => "historical-handoff", "body" => "## Symphony Handoff"},
            %{"id" => "historical-lock", "body" => "runtime ownership"}
          ]
        })
      )

    without_comments = Client.normalize_issue_for_test(payload)
    assert with_comments == without_comments

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}
    assert Orchestrator.should_dispatch_issue_for_test(with_comments, state)
    assert Orchestrator.should_dispatch_issue_for_test(without_comments, state)

    for module <- [SymphonyElixir.Tracker, Adapter],
        function <- [:create_comment, :update_comment, :delete_comment, :upsert_claim_lease] do
      refute function_exported?(module, function, 2)
    end
  end

  test "poll dispatch atomically takes over a dead-holder active record" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-dispatch-takeover-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")

    issue = %Issue{
      id: "issue-stale-dispatch-takeover",
      identifier: "MT-1241-TAKEOVER",
      title: "Take over stale ownership",
      state: "In Progress"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      hook_before_run: "sleep 30"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, %{run_id: "dead-run"}} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "dead-run",
               holder: "#{ProcessOwnership.current_host()}:999999:implementer"
             })

    orchestrator_name = Module.concat(__MODULE__, :StaleDispatchTakeoverOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(pid)
      File.rm_rf(test_root)
    end)

    snapshot =
      assert_eventually_value(fn ->
        case Orchestrator.snapshot(orchestrator_name, 1_000) do
          %{running: [%{issue_id: "issue-stale-dispatch-takeover"} | _]} = snapshot -> snapshot
          _ -> nil
        end
      end)

    assert [%{process_ownership: %{state: "active", run_id: replacement_run}} | _] = snapshot.running
    refute replacement_run == "dead-run"
    assert [_archive] = Path.wildcard(ProcessOwnership.registry_path(issue) <> ".stale-*")
  end

  test "irrecoverable task exit blocks process ownership without comment traffic" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-comment-independent-escalation",
      identifier: "MT-1241-BLOCKED",
      title: "Block without a tracker comment",
      state: "In Progress"
    }

    assert {:ok, process_ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-comment-independent-escalation",
               holder: ProcessOwnership.holder_id()
             })

    ref = make_ref()

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: nil,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          process_ownership: process_ownership,
          run_id: process_ownership.run_id,
          started_at: DateTime.utc_now(),
          retry_attempt: 2
        }
      },
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{issue.id => %{attempt: 2, error: "ordinary retry must clear"}},
      completed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    reason = {:missing_required_tool_or_cli, %{tool: "claude", message: "command not found"}}

    assert {:noreply, updated} =
             Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)

    assert updated.running == %{}
    assert updated.retry_attempts == %{}
    assert updated.blocked_failures[issue.id].family == :missing_required_tool_or_cli

    assert %{state: "blocked", run_id: "run-comment-independent-escalation"} =
             ProcessOwnership.status_for_issue(issue)

    assert_receive {:memory_tracker_label_add, "issue-comment-independent-escalation", "Human Escalation"}
    assert_receive {:memory_tracker_state_update, "issue-comment-independent-escalation", "Human Escalation"}
    refute_receive {:memory_tracker_comment, "issue-comment-independent-escalation", _body}, 100
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

    assert {:ok, _ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-live-process-tree",
               holder: ProcessOwnership.holder_id(),
               app_server_pid: app_server_pid
             })

    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert_eventually(fn -> File.exists?(child_pid_file) end)

    child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()
    assert {_, 0} = System.cmd("kill", ["-0", Integer.to_string(child_pid)], stderr_to_stdout: true)
    assert ProcessOwnership.owned_process_live?(issue, %{app_server_pid: app_server_pid})

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "replacement-live-process-tree",
               holder: "replacement-holder"
             })
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

    assert {:ok, _ownership} =
             ProcessOwnership.acquire(issue, %{
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

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "replacement-late-detached",
               holder: "replacement-holder",
               workspace_path: workspace_path
             })
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

  defp assert_eventually_value(fun, attempts \\ 100)

  defp assert_eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(25)
        assert_eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  defp assert_eventually_value(_fun, 0), do: flunk("condition did not produce a value in time")
end
