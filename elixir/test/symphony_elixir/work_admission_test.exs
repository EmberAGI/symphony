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

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      poll_interval_ms: 60_000,
      hook_before_run: "sleep 30"
    )

    on_exit(fn ->
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

  test "closed admission blocks and preserves an already scheduled retry", %{
    test_root: test_root
  } do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
    retry_issue = issue("issue-retry-close", "MT-RETRY-CLOSE")
    retry_token = make_ref()

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [retry_issue])

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-old",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(pid) end)

    assert {:ok, %{status: "closed"}} =
             Orchestrator.close_work_admission(orchestrator_name, "generation-next")

    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.put(state.claimed, retry_issue.id),
          retry_attempts: %{
            retry_issue.id => %{
              attempt: 2,
              retry_token: retry_token,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond),
              identifier: retry_issue.identifier,
              issue: retry_issue,
              error: "retry test"
            }
          }
      }
    end)

    send(pid, {:retry_issue, retry_issue.id, retry_token})

    assert %{
             work_admission: %{status: "closed"},
             running: [],
             retrying: [%{issue_id: "issue-retry-close", attempt: 2}]
           } = Orchestrator.snapshot(orchestrator_name, 1_000)

    refute_receive {:memory_tracker_fetch_issue_states_by_ids, ["issue-retry-close"]}, 100
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

  test "closed restart terminates orphaned runner tasks before reporting drained", %{
    test_root: test_root
  } do
    marker_path = Path.join(test_root, "work-admission.json")
    orchestrator_name = Module.concat(__MODULE__, :RestartCleanupOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, first_pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-current",
        work_admission_marker_path: marker_path
      )

    assert {:ok, %{status: "open"}} =
             Orchestrator.open_work_admission(orchestrator_name, "generation-current")

    wait_for_completed_poll(orchestrator_name)

    restart_issue = issue("issue-restart-orphan", "MT-RESTART-ORPHAN")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [restart_issue])
    send(first_pid, :run_poll_cycle)

    assert {:ok, %{status: "closed"}} =
             Orchestrator.close_work_admission(orchestrator_name, "generation-current")

    runner_pid = :sys.get_state(first_pid).running[restart_issue.id].pid
    assert Process.alive?(runner_pid)

    Process.unlink(first_pid)
    first_ref = Process.monitor(first_pid)
    Process.exit(first_pid, :kill)
    assert_receive {:DOWN, ^first_ref, :process, ^first_pid, :killed}, 1_000
    assert Process.alive?(runner_pid)

    {:ok, restarted_pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        execution_generation: "generation-current",
        work_admission_marker_path: marker_path
      )

    on_exit(fn -> stop_orchestrator!(restarted_pid) end)

    refute Process.alive?(runner_pid)

    assert %{
             work_admission: %{
               status: "closed",
               target_generation: "generation-current",
               drained: true
             },
             running: []
           } = Orchestrator.snapshot(orchestrator_name, 1_000)
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
end
