defmodule SymphonyElixir.WorkAdmissionTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-work-admission-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    previous_recovery_dir = Application.get_env(:symphony_elixir, :role_turn_recovery_dir)

    Application.put_env(
      :symphony_elixir,
      :role_turn_recovery_dir,
      Path.join(test_root, "role-turn-recovery")
    )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      poll_interval_ms: 60_000,
      hook_before_run: "sleep 30"
    )

    on_exit(fn ->
      restore_application_env!(:role_turn_recovery_dir, previous_recovery_dir)
      File.rm_rf(test_root)
    end)

    {:ok, test_root: test_root}
  end

  test "close acknowledgement serializes after an admitted dispatch and blocks later normal dispatch", %{
    test_root: test_root
  } do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :DispatchRaceOrchestrator)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-old",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)

    assert %{
             work_admission: %{
               status: "closed",
               target_generation: "generation-old",
               drained: true
             }
           } = Orchestrator.snapshot(orchestrator_name, 1_000)

    assert {:ok, %{status: "open"}} =
             Orchestrator.open_work_admission(orchestrator_name, "generation-old")

    wait_for_completed_poll(orchestrator_name)

    first_issue = issue("issue-before-close", "MT-BEFORE-CLOSE")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [first_issue])

    # Both messages originate from this process, so the GenServer must finish
    # the selected dispatch before it can acknowledge the close call.
    send(pid, :run_poll_cycle)

    assert {:ok,
            %{
              status: "closed",
              target_generation: "generation-next"
            }} =
             Orchestrator.close_work_admission(
               orchestrator_name,
               "generation-next"
             )

    assert %{
             work_admission: %{
               status: "closed",
               target_generation: "generation-next",
               drained: false
             },
             execution_generation: "generation-old",
             running: [%{issue_id: "issue-before-close"}]
           } = Orchestrator.snapshot(orchestrator_name, 1_000)

    second_issue = issue("issue-after-close", "MT-AFTER-CLOSE")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [first_issue, second_issue])
    send(pid, :run_poll_cycle)

    assert %{running: [%{issue_id: "issue-before-close"}]} =
             Orchestrator.snapshot(orchestrator_name, 1_000)

    worker_pid = :sys.get_state(pid).running["issue-before-close"].pid
    Process.exit(worker_pid, :kill)
  end

  test "closing and reopening before a real retry deadline preserves its delay and prevents early refresh", %{
    test_root: test_root
  } do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :RetryDeadlineOrchestrator)
    retry_issue = issue("issue-retry-deadline", "MT-RETRY-DEADLINE")
    retry_issue_id = retry_issue.id

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      poll_interval_ms: 60_000,
      max_retry_backoff_ms: 300,
      hook_before_run: "sleep 30"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [retry_issue])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-old",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)

    open_and_poll!(orchestrator_name, retry_issue)
    Process.exit(wait_for_running_pid(pid, retry_issue.id), :kill)

    %{retrying: [%{issue_id: ^retry_issue_id, due_in_ms: due_before_close}]} =
      wait_for_retry(orchestrator_name, retry_issue.id)

    assert due_before_close > 100
    drain_retry_refreshes(retry_issue.id)

    assert {:ok, %{status: "closed"}} = Orchestrator.close_work_admission(orchestrator_name, "generation-old")
    assert {:ok, %{status: "open"}} = Orchestrator.open_work_admission(orchestrator_name, "generation-old")

    assert %{
             work_admission: %{status: "open"},
             running: [],
             retrying: [%{issue_id: ^retry_issue_id, due_in_ms: due_after_open}]
           } = Orchestrator.snapshot(orchestrator_name, 1_000)

    assert due_after_open > 50
    assert due_after_open <= due_before_close
    refute_receive {:memory_tracker_fetch_issue_states_by_ids, [^retry_issue_id]}, 50

    assert_receive {:memory_tracker_fetch_issue_states_by_ids, [^retry_issue_id]}, 1_000
  end

  test "a real retry timer that fires while closed dispatches once after reopen", %{test_root: test_root} do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :HeldRetryOrchestrator)
    retry_issue = issue("issue-retry-held", "MT-RETRY-HELD")
    retry_issue_id = retry_issue.id

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      poll_interval_ms: 60_000,
      max_retry_backoff_ms: 1_000,
      hook_before_run: "sleep 30"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [retry_issue])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-old",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)

    open_and_poll!(orchestrator_name, retry_issue)
    Process.exit(wait_for_running_pid(pid, retry_issue.id), :kill)
    _retry = wait_for_retry(orchestrator_name, retry_issue.id)
    drain_retry_refreshes(retry_issue.id)

    assert {:ok, %{status: "closed"}} = Orchestrator.close_work_admission(orchestrator_name, "generation-old")
    Process.sleep(1_100)
    refute_receive {:memory_tracker_fetch_issue_states_by_ids, [^retry_issue_id]}, 20

    assert {:ok, %{status: "open"}} =
             Orchestrator.open_work_admission(orchestrator_name, "generation-old")

    assert_receive {:memory_tracker_fetch_issue_states_by_ids, [^retry_issue_id]}, 1_000

    assert %{running: [%{issue_id: ^retry_issue_id}], retrying: []} =
             wait_for_running(orchestrator_name, retry_issue_id)
  end

  test "startup loads the durable marker before its first poll and malformed or unreadable markers fail closed", %{
    test_root: test_root
  } do
    issue = issue("issue-startup-close", "MT-STARTUP-CLOSE")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    cases = [
      {"missing", :missing},
      {"closed",
       Jason.encode!(%{
         "version" => 1,
         "status" => "closed",
         "target_generation" => "generation-next"
       })},
      {"unsupported_version",
       Jason.encode!(%{
         "version" => 2,
         "status" => "closed",
         "target_generation" => "generation-next"
       })},
      {"extra_key",
       Jason.encode!(%{
         "version" => 1,
         "status" => "closed",
         "target_generation" => "generation-next",
         "payload" => "not-part-of-the-schema"
       })},
      {"open_generation_mismatch",
       Jason.encode!(%{
         "version" => 1,
         "status" => "open",
         "target_generation" => "generation-old"
       })},
      {"malformed", "{not-json"},
      {"unreadable", :unreadable}
    ]

    Enum.each(cases, fn {case_name, marker_body} ->
      case_root = Path.join(test_root, case_name)
      marker_path = Path.join(case_root, "work-admission.json")

      case marker_body do
        :missing ->
          :ok

        :unreadable ->
          File.write!(case_root, "not-a-directory")

        body ->
          File.mkdir_p!(case_root)
          File.write!(marker_path, body)
      end

      orchestrator_name =
        Module.concat(__MODULE__, String.to_atom("Startup#{String.capitalize(case_name)}Orchestrator"))

      {:ok, pid} =
        Orchestrator.start_link(
          name: orchestrator_name,
          execution_generation: "generation-next",
          work_admission_marker_path: marker_path
        )

      assert %{
               work_admission: %{status: "closed"},
               execution_generation: "generation-next",
               running: []
             } = Orchestrator.snapshot(orchestrator_name, 1_000)

      refute_receive {:memory_tracker_fetch_candidate_issues, ["issue-startup-close"]}, 100
      stop_orchestrator!(pid)
    end)
  end

  test "bootstrap environment supplies the default generation and marker path before polling", %{
    test_root: test_root
  } do
    marker_path = Path.join([test_root, ".runtime", "symphony", "work-admission.json"])
    orchestrator_name = Module.concat(__MODULE__, :BootstrapEnvironmentOrchestrator)

    File.mkdir_p!(Path.dirname(marker_path))

    File.write!(
      marker_path,
      Jason.encode!(%{
        "version" => 1,
        "status" => "open",
        "target_generation" => "generation-bootstrap"
      })
    )

    restore_env!("SYMPHONY_EXECUTION_GENERATION", System.get_env("SYMPHONY_EXECUTION_GENERATION"))
    restore_env!("SYMPHONY_ORCHESTRATION_ROOT", System.get_env("SYMPHONY_ORCHESTRATION_ROOT"))
    restore_env!("SYMPHONY_WORK_ADMISSION_PATH", System.get_env("SYMPHONY_WORK_ADMISSION_PATH"))
    System.put_env("SYMPHONY_EXECUTION_GENERATION", "generation-bootstrap")
    System.put_env("SYMPHONY_ORCHESTRATION_ROOT", test_root)
    System.delete_env("SYMPHONY_WORK_ADMISSION_PATH")

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> stop_orchestrator!(pid) end)

    assert %{work_admission: %{status: "open", target_generation: "generation-bootstrap"}} =
             Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  test "a TaskSupervisor child without an orchestrator running entry keeps admission not drained", %{
    test_root: test_root
  } do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :ChildOnlyDrainOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-current",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)

    {:ok, child_pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> Process.sleep(5_000) end)

    on_exit(fn ->
      if Process.alive?(child_pid), do: Process.exit(child_pid, :kill)
    end)

    assert %{work_admission: %{status: "closed", drained: false}, running: []} =
             Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  test "temporarily unavailable TaskSupervisor reports admission not drained", %{test_root: test_root} do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :UnavailableSupervisorOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-current",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)

    on_exit(fn ->
      case Process.whereis(SymphonyElixir.TaskSupervisor) do
        nil -> {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)
        _pid -> :ok
      end
    end)

    assert %{work_admission: %{status: "closed", drained: false}, running: []} =
             Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  test "open rejects the wrong execution generation and the loopback API reports bounded state", %{
    test_root: test_root
  } do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :HttpOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-current",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)
    start_test_endpoint(orchestrator_name)

    assert %{
             "status" => "closed",
             "target_generation" => "generation-next",
             "drained" => true
           } =
             build_conn()
             |> post("/api/v1/work-admission/close", %{"generation" => "generation-next"})
             |> json_response(200)

    assert Jason.decode!(File.read!(marker_path)) == %{
             "version" => 1,
             "status" => "closed",
             "target_generation" => "generation-next"
           }

    assert %{
             "work_admission" => %{
               "status" => "closed",
               "target_generation" => "generation-next",
               "drained" => true
             },
             "execution_generation" => "generation-current"
           } =
             build_conn()
             |> get("/api/v1/state")
             |> json_response(200)

    assert %{
             "error" => %{
               "code" => "execution_generation_mismatch"
             }
           } =
             build_conn()
             |> post("/api/v1/work-admission/open", %{"generation" => "generation-next"})
             |> json_response(409)

    assert %{"error" => %{"code" => "work_admission_generation_mismatch"}} =
             build_conn()
             |> post("/api/v1/work-admission/open", %{"generation" => "generation-current"})
             |> json_response(409)

    assert %{work_admission: %{status: "closed"}} =
             Orchestrator.snapshot(orchestrator_name, 1_000)

    assert %{"status" => "closed", "target_generation" => "generation-current"} =
             build_conn()
             |> post("/api/v1/work-admission/close", %{"generation" => "generation-current"})
             |> json_response(200)

    assert %{
             "status" => "open",
             "target_generation" => "generation-current",
             "drained" => true
           } =
             build_conn()
             |> post("/api/v1/work-admission/open", %{"generation" => "generation-current"})
             |> json_response(200)

    assert Jason.decode!(File.read!(marker_path)) == %{
             "version" => 1,
             "status" => "open",
             "target_generation" => "generation-current"
           }

    assert %{"error" => %{"code" => "invalid_generation"}} =
             build_conn()
             |> post("/api/v1/work-admission/close", %{})
             |> json_response(400)
  end

  test "work admission mutations reject non-loopback callers", %{test_root: test_root} do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :NonLoopbackOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-current",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)
    start_test_endpoint(orchestrator_name)

    conn = %{build_conn() | remote_ip: {203, 0, 113, 10}}

    assert %{"error" => %{"code" => "loopback_required"}} =
             conn
             |> post("/api/v1/work-admission/close", %{"generation" => "generation-next"})
             |> json_response(403)

    assert %{work_admission: %{status: "closed", target_generation: "generation-current"}} =
             Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  test "public default-path restart preserves runners and reports not drained for open and closed admission", %{
    test_root: test_root
  } do
    restore_env!("SYMPHONY_EXECUTION_GENERATION", System.get_env("SYMPHONY_EXECUTION_GENERATION"))
    restore_env!("SYMPHONY_ORCHESTRATION_ROOT", System.get_env("SYMPHONY_ORCHESTRATION_ROOT"))
    restore_env!("SYMPHONY_WORK_ADMISSION_PATH", System.get_env("SYMPHONY_WORK_ADMISSION_PATH"))
    System.put_env("SYMPHONY_EXECUTION_GENERATION", "generation-current")
    System.delete_env("SYMPHONY_WORK_ADMISSION_PATH")

    Enum.each(["open", "closed"], fn expected_status ->
      case_root = Path.join(test_root, expected_status)
      System.put_env("SYMPHONY_ORCHESTRATION_ROOT", case_root)
      orchestrator_name = Module.concat(__MODULE__, :"Restart#{expected_status}Orchestrator")
      restart_issue = issue("issue-restart-#{expected_status}", "MT-RESTART-#{String.upcase(expected_status)}")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      {:ok, first_pid} = Orchestrator.start_link(name: orchestrator_name)

      assert {:ok, %{status: "open"}} =
               Orchestrator.open_work_admission(orchestrator_name, "generation-current")

      wait_for_completed_poll(orchestrator_name)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [restart_issue])
      send(first_pid, :run_poll_cycle)

      if expected_status == "closed" do
        assert {:ok, %{status: "closed"}} =
                 Orchestrator.close_work_admission(orchestrator_name, "generation-current")
      end

      runner_pid = :sys.get_state(first_pid).running[restart_issue.id].pid
      assert Process.alive?(runner_pid)

      Process.unlink(first_pid)
      first_ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^first_ref, :process, ^first_pid, :killed}, 1_000
      assert Process.alive?(runner_pid)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      {:ok, restarted_pid} = Orchestrator.start_link(name: orchestrator_name)

      assert Process.alive?(runner_pid)

      assert %{
               work_admission: %{
                 status: ^expected_status,
                 target_generation: "generation-current",
                 drained: false
               },
               running: []
             } = Orchestrator.snapshot(orchestrator_name, 1_000)

      Process.exit(runner_pid, :kill)
      stop_orchestrator!(restarted_pid)
    end)
  end

  test "configured marker path without an execution generation starts closed and cannot open", %{
    test_root: test_root
  } do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :UnknownGenerationOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    File.write!(
      marker_path,
      Jason.encode!(%{
        "version" => 1,
        "status" => "open",
        "target_generation" => "unknown"
      })
    )

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)

    assert %{
             work_admission: %{
               status: "closed",
               target_generation: nil,
               drained: true
             },
             execution_generation: "unknown"
           } = Orchestrator.snapshot(orchestrator_name, 1_000)

    assert {:error, :execution_generation_unavailable} =
             Orchestrator.open_work_admission(orchestrator_name, "unknown")
  end

  test "marker write failure never opens admission", %{test_root: test_root} do
    marker_directory = Path.join(test_root, "marker-directory")
    marker_path = Path.join(marker_directory, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :MarkerWriteFailureOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-current",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)

    assert {:ok, %{status: "closed"}} =
             Orchestrator.close_work_admission(orchestrator_name, "generation-current")

    File.rm!(marker_path)
    File.rmdir!(marker_directory)
    File.write!(marker_directory, "blocks marker directory creation")

    assert {:error, :marker_unavailable} =
             Orchestrator.open_work_admission(orchestrator_name, "generation-current")

    assert %{
             work_admission: %{
               status: "closed",
               target_generation: "generation-current"
             }
           } = Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Work admission #{identifier}",
      state: "In Progress",
      labels: ["implementation-effort:minimal"],
      url: "https://linear.app/example/#{id}"
    }
  end

  defp wait_for_completed_poll(pid, attempts \\ 100)

  defp wait_for_completed_poll(_pid, 0), do: flunk("startup poll did not complete")

  defp wait_for_completed_poll(pid, attempts) do
    case Orchestrator.snapshot(pid, 1_000) do
      %{polling: %{last_poll_completed_at: completed_at}} when is_binary(completed_at) ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_completed_poll(pid, attempts - 1)
    end
  end

  defp open_and_poll!(orchestrator_name, issue) do
    assert {:ok, %{status: "open"}} = Orchestrator.open_work_admission(orchestrator_name, "generation-old")
    wait_for_completed_poll(orchestrator_name)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    send(Process.whereis(orchestrator_name), :run_poll_cycle)
  end

  defp wait_for_running_pid(pid, issue_id, attempts \\ 100)

  defp wait_for_running_pid(_pid, _issue_id, 0), do: flunk("retry lifecycle runner did not start")

  defp wait_for_running_pid(pid, issue_id, attempts) do
    case :sys.get_state(pid).running do
      %{^issue_id => %{pid: runner_pid}} when is_pid(runner_pid) ->
        runner_pid

      _ ->
        Process.sleep(10)
        wait_for_running_pid(pid, issue_id, attempts - 1)
    end
  end

  defp wait_for_retry(orchestrator_name, issue_id, attempts \\ 100)

  defp wait_for_retry(_orchestrator_name, _issue_id, 0), do: flunk("retry lifecycle retry was not scheduled")

  defp wait_for_retry(orchestrator_name, issue_id, attempts) do
    case Orchestrator.snapshot(orchestrator_name, 1_000) do
      %{retrying: [%{issue_id: ^issue_id} | _]} = snapshot ->
        snapshot

      _ ->
        Process.sleep(10)
        wait_for_retry(orchestrator_name, issue_id, attempts - 1)
    end
  end

  defp wait_for_running(orchestrator_name, issue_id, attempts \\ 100)

  defp wait_for_running(_orchestrator_name, _issue_id, 0), do: flunk("retry lifecycle retry did not dispatch")

  defp wait_for_running(orchestrator_name, issue_id, attempts) do
    case Orchestrator.snapshot(orchestrator_name, 1_000) do
      %{running: [%{issue_id: ^issue_id}], retrying: []} = snapshot ->
        snapshot

      _ ->
        Process.sleep(10)
        wait_for_running(orchestrator_name, issue_id, attempts - 1)
    end
  end

  defp drain_retry_refreshes(issue_id) do
    receive do
      {:memory_tracker_fetch_issue_states_by_ids, [^issue_id]} -> drain_retry_refreshes(issue_id)
    after
      0 -> :ok
    end
  end

  defp start_test_endpoint(orchestrator_name) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 1_000
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp restore_env!(name, value) do
    on_exit(fn ->
      case value do
        nil -> System.delete_env(name)
        value -> System.put_env(name, value)
      end
    end)
  end

  defp restore_application_env!(name, value) do
    case value do
      nil -> Application.delete_env(:symphony_elixir, name)
      value -> Application.put_env(:symphony_elixir, name, value)
    end
  end
end
