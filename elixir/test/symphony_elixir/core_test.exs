defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership
  alias SymphonyElixir.Tracker.ClaimLease

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    :ok
  end

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "git clone --depth 1 https://github.com/openai/symphony ."
    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    assert Map.get(hooks, "before_remove") =~ "cd elixir && mise exec -- mix workspace.before_remove"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-resume"
    ref = make_ref()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    down_sent_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert due_at_ms - down_sent_at_ms >= 500
    assert_due_in_range(due_at_ms, 0, 1_100)
    assert_receive {:memory_tracker_claim_lease, ^issue_id, retry_lease}, 500
    assert retry_lease.state == "retrying"
    assert retry_lease.retry_reason == "active-state-continuation-check"
    assert retry_lease.issue_identifier == "MT-558"
  end

  test "normal worker exit quarantines live app-server before continuation retry" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-normal-exit-live-app-server-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces")
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    issue_id = "issue-normal-live-process"
    issue = %Issue{id: issue_id, identifier: "MT-NORMAL-LIVE", state: "In Progress"}
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :NormalLiveProcessOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    sleep = System.find_executable("sleep")
    assert is_binary(sleep)
    port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: [~c"5"]])
    {:os_pid, app_server_pid} = :erlang.port_info(port, :os_pid)

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf(test_root)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      run_id: "run-normal-live-process",
      codex_app_server_pid: app_server_pid,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue_id)
    assert %{attempt: 1} = state.retry_attempts[issue_id]
    assert_receive {:memory_tracker_claim_lease, ^issue_id, quarantined_lease}, 500
    assert quarantined_lease.state == "quarantined"
    assert quarantined_lease.retry_reason == "active-state-continuation-check"

    process_status = ProcessOwnership.status_for_issue(issue)
    assert process_status.state == "quarantined"
    assert process_status.live?
    assert process_status.quarantine_reason =~ "app-server process remained live after normal worker exit"

    refute Orchestrator.should_dispatch_issue_for_test(
             issue,
             %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}
           )
  end

  test "terminal issue reconciliation releases the visible claim lease" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-terminal-lease"
    now = DateTime.utc_now()

    claim_lease =
      ClaimLease.new(%{
        comment_id: "comment-terminal-lease",
        issue_id: issue_id,
        issue_identifier: "MT-TERM-LEASE",
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-terminal-lease",
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-TERM-LEASE",
      state: "Done",
      title: "Terminal lease",
      claim_lease: claim_lease
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute MapSet.member?(updated_state.claimed, issue_id)
    assert_receive {:memory_tracker_claim_lease, ^issue_id, released_lease}, 500
    assert released_lease.comment_id == "comment-terminal-lease"
    assert released_lease.state == "released"
    assert released_lease.recovery_reason == "issue-left-active-dispatch"
  end

  test "terminal issue reconciliation releases claim lease for an actively running issue" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-running-terminal-lease"
    now = DateTime.utc_now()

    claim_lease =
      ClaimLease.new(%{
        comment_id: "comment-running-terminal-lease",
        issue_id: issue_id,
        issue_identifier: "MT-RUN-TERM-LEASE",
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-terminal-running-lease",
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: nil,
          identifier: "MT-RUN-TERM-LEASE",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-RUN-TERM-LEASE",
            state: "In Progress",
            claim_lease: claim_lease
          },
          claim_lease: claim_lease,
          run_id: "run-terminal-running-lease",
          started_at: now
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-RUN-TERM-LEASE",
      state: "Done",
      title: "Running terminal lease",
      claim_lease: claim_lease
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    assert_receive {:memory_tracker_claim_lease, ^issue_id, released_lease}, 500
    assert released_lease.comment_id == "comment-running-terminal-lease"
    assert released_lease.state == "released"
    assert released_lease.recovery_reason == "issue-left-active-dispatch"
  end

  test "terminal issue reconciliation releases only the current same-scope claim lease" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-terminal-scoped-lease"
    now = DateTime.utc_now()

    implementer_lease =
      ClaimLease.new(%{
        comment_id: "comment-implementer-lease",
        issue_id: issue_id,
        issue_identifier: "MT-SCOPED-TERM",
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-implementer-lease",
        refreshed_at: DateTime.add(now, -30, :second),
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    reviewer_lease =
      ClaimLease.new(%{
        comment_id: "comment-reviewer-lease",
        issue_id: issue_id,
        issue_identifier: "MT-SCOPED-TERM",
        role: "reviewer",
        holder: "reviewer-worker",
        run_id: "run-reviewer-lease",
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-SCOPED-TERM",
      state: "Done",
      title: "Terminal scoped lease",
      claim_lease: reviewer_lease,
      claim_leases: [reviewer_lease, implementer_lease]
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute MapSet.member?(updated_state.claimed, issue_id)
    assert_receive {:memory_tracker_claim_lease, ^issue_id, released_lease}, 500
    assert released_lease.comment_id == "comment-implementer-lease"
    assert released_lease.role == "implementer"
    assert released_lease.state == "released"
    assert released_lease.recovery_reason == "issue-left-active-dispatch"
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 38_000, 40_500)
  end

  test "abnormal worker exit quarantines surviving app-server process and visible lease" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-quarantine-exit-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces")
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    issue_id = "issue-quarantine-exit"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :QuarantineExitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    sleep = System.find_executable("sleep")
    assert is_binary(sleep)
    port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: [~c"5"]])
    {:os_pid, app_server_pid} = :erlang.port_info(port, :os_pid)

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf(test_root)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-QUAR",
      retry_attempt: 1,
      issue: %Issue{id: issue_id, identifier: "MT-QUAR", state: "In Progress"},
      run_id: "run-quarantine",
      codex_app_server_pid: app_server_pid,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue_id)
    assert %{attempt: 2} = state.retry_attempts[issue_id]
    assert_receive {:memory_tracker_claim_lease, ^issue_id, quarantined_lease}, 500
    assert quarantined_lease.state == "quarantined"
    assert quarantined_lease.retry_reason == "agent exited: :boom"

    process_status =
      ProcessOwnership.status_for_issue(%Issue{id: issue_id, identifier: "MT-QUAR"})

    assert process_status.state == "quarantined"
    assert process_status.quarantine_reason =~ "agent exited before app-server process cleaned"
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 8_000, 10_500)
  end

  test "abnormal worker exit writes compact run-scoped retry evidence" do
    previous_run_log_root = Application.get_env(:symphony_elixir, :run_log_root)

    run_log_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-log-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-crash-run-log"
    run_id = "run-crash-log"
    session_id = "session-crash-log"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRunLogOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      restore_app_env(:run_log_root, previous_run_log_root)
      File.rm_rf(run_log_root)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    Application.put_env(:symphony_elixir, :run_log_root, run_log_root)
    initial_state = :sys.get_state(pid)
    long_detail = String.duplicate("run-log-detail-", 500)
    reason = {:shutdown, {:agent_failed, long_detail}}

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-RUN-LOG",
      retry_attempt: 1,
      issue: %Issue{id: issue_id, identifier: "MT-RUN-LOG", state: "In Progress"},
      run_id: run_id,
      session_id: session_id,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), reason})
    Process.sleep(50)

    assert %{attempt: 2, due_at_ms: due_at_ms} = :sys.get_state(pid).retry_attempts[issue_id]
    run_log_path = Path.join([run_log_root, "MT-RUN-LOG", "#{run_id}.jsonl"])
    assert File.exists?(run_log_path)

    [event] =
      run_log_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert event["event"] == "agent_retry_scheduled"
    assert event["issue_id"] == issue_id
    assert event["issue_identifier"] == "MT-RUN-LOG"
    assert event["run_id"] == run_id
    assert event["session_id"] == session_id
    assert event["attempt"] == 1
    assert event["reason"] =~ "agent exited: retryable_runtime_failure"
    refute event["reason"] =~ long_detail
    assert String.length(event["reason"]) < 260
    assert event["retry"]["attempt"] == 2
    assert event["retry"]["delay_ms"] == 20_000
    assert event["retry"]["due_at_ms"] == due_at_ms
    assert event["retry"]["lease_state"] == "retrying"
    assert event["retry"]["claim_lease_state"] == nil
    assert is_binary(event["timestamp"])
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "quarantined retry timer preserves lease and status while live process ownership blocks dispatch" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-quarantined-retry-live-process-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-quarantined-retry"
    issue_identifier = "MT-QUAR-RETRY"
    retry_token = make_ref()
    now = DateTime.utc_now()
    orchestrator_name = Module.concat(__MODULE__, :QuarantinedRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Quarantined retry",
      state: "In Progress"
    }

    sleep = System.find_executable("sleep")
    assert is_binary(sleep)
    port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: [~c"5"]])
    {:os_pid, app_server_pid} = :erlang.port_info(port, :os_pid)

    claim_lease =
      ClaimLease.new(%{
        comment_id: "comment-quarantined-retry",
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-quarantined-retry",
        workspace_path: Path.join(workspace_root, issue_identifier),
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        retry_reason: "stalled for 301000ms without codex activity",
        state: "quarantined"
      })

    issue = %{issue | claim_lease: claim_lease, claim_leases: [claim_lease]}

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf(test_root)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    :ok =
      ProcessOwnership.record_quarantined(
        issue,
        %{
          role: "implementer",
          run_id: claim_lease.run_id,
          holder: claim_lease.holder,
          workspace_path: claim_lease.workspace_path,
          app_server_pid: app_server_pid
        },
        "stalled worker left app-server process live"
      )

    process_ownership = ProcessOwnership.status_for_issue(issue)
    assert process_ownership.state == "quarantined"
    assert process_ownership.live?

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: issue_identifier,
          error: "stalled for 301000ms without codex activity",
          issue: issue,
          claim_lease: claim_lease,
          run_id: claim_lease.run_id,
          process_ownership: process_ownership
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, retry_token})
    Process.sleep(50)

    state = :sys.get_state(pid)
    assert MapSet.member?(state.claimed, issue_id)
    assert %{attempt: 3, retry_token: new_retry_token} = retry = state.retry_attempts[issue_id]
    assert is_reference(new_retry_token)
    assert retry.identifier == issue_identifier
    assert retry.claim_lease.state == "quarantined"
    assert retry.claim_lease.comment_id == "comment-quarantined-retry"
    assert retry.claim_lease.run_id == "run-quarantined-retry"
    assert retry.process_ownership.state == "quarantined"
    assert retry.process_ownership.live?

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert %{retrying: [retry_snapshot]} = snapshot
    assert retry_snapshot.identifier == issue_identifier
    assert retry_snapshot.claim_lease.state == "quarantined"
    assert retry_snapshot.process_ownership.state == "quarantined"
    assert retry_snapshot.process_ownership.live?

    assert_receive {:memory_tracker_claim_lease, ^issue_id, refreshed_lease}, 500
    assert refreshed_lease.state == "quarantined"
    assert refreshed_lease.comment_id == "comment-quarantined-retry"
    assert refreshed_lease.run_id == "run-quarantined-retry"
    refute_receive {:memory_tracker_claim_lease, ^issue_id, %{state: "released"}}, 100

    refute Orchestrator.should_dispatch_issue_for_test(
             issue,
             %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}
           )
  end

  test "dead retry timer releases leaked claim so issue can dispatch again" do
    issue_id = "issue-dead-retry"
    orchestrator_name = Module.concat(__MODULE__, :DeadRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      title: "Retry chain died",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:retry_issue, issue_id, make_ref()})
    Process.sleep(50)

    state = :sys.get_state(pid)

    refute MapSet.member?(state.claimed, issue_id)
    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "retry timer refreshes retried issue by id instead of fetching candidate page" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    default_orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)
    issue_id = "issue-retry-by-id"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      title: "Retry by id",
      state: "Done"
    }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    if is_pid(default_orchestrator_pid) do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)

      if is_pid(default_orchestrator_pid) and is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :running} -> :ok
        end
      end
    end)

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:noreply, state} =
      Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited: :boom"
      })

    assert_receive {:memory_tracker_fetch_issue_states_by_ids, [^issue_id]}, 500
    refute_receive {:memory_tracker_fetch_candidate_issues, [^issue_id]}, 100

    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  test "claim reconciliation releases only claims that are not running or retrying" do
    running_issue_id = "issue-running-claim"
    retrying_issue_id = "issue-retrying-claim"
    orphaned_issue_id = "issue-orphaned-claim"

    state = %Orchestrator.State{
      running: %{
        running_issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-563",
          issue: %Issue{id: running_issue_id, identifier: "MT-563", state: "In Progress"},
          started_at: DateTime.utc_now()
        }
      },
      retry_attempts: %{
        retrying_issue_id => %{
          attempt: 1,
          timer_ref: nil,
          retry_token: make_ref(),
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-564",
          error: "agent exited: :boom"
        }
      },
      claimed: MapSet.new([running_issue_id, retrying_issue_id, orphaned_issue_id])
    }

    state = Orchestrator.reconcile_claims_for_test(state)

    assert MapSet.member?(state.claimed, running_issue_id)
    assert MapSet.member?(state.claimed, retrying_issue_id)
    refute MapSet.member?(state.claimed, orphaned_issue_id)
  end

  test "linear issue normalization extracts latest structured Symphony claim lease marker" do
    now = DateTime.utc_now()
    older = DateTime.add(now, -120, :second)
    newer = DateTime.add(now, -30, :second)

    old_marker =
      ClaimLease.render(%{
        issue_id: "issue-claim-marker",
        issue_identifier: "MT-566",
        role: "implementer",
        holder: "worker-old",
        run_id: "run-old",
        refreshed_at: older,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    new_marker =
      ClaimLease.render(%{
        issue_id: "issue-claim-marker",
        issue_identifier: "MT-566",
        role: "implementer",
        holder: "worker-new",
        run_id: "run-new",
        worker_host: "worker-a",
        workspace_path: "/tmp/workspaces/MT-566",
        session_id: "thread-turn",
        attempt: 2,
        refreshed_at: newer,
        expires_at: DateTime.add(now, 60, :second),
        state: "retrying"
      })

    issue =
      Client.normalize_issue_for_test(%{
        "id" => "issue-claim-marker",
        "identifier" => "MT-566",
        "title" => "Claim marker",
        "state" => %{"name" => "In Progress"},
        "comments" => %{
          "nodes" => [
            %{"id" => "comment-old", "body" => "## Symphony Claim Lease\n\n#{old_marker}"},
            %{"id" => "comment-new", "body" => "## Symphony Claim Lease\n\n#{new_marker}"}
          ]
        }
      })

    assert issue.claim_lease.holder == "worker-new"
    assert issue.claim_lease.run_id == "run-new"
    assert issue.claim_lease.state == "retrying"
    assert issue.claim_lease.worker_host == "worker-a"
    assert issue.claim_lease.workspace_path == "/tmp/workspaces/MT-566"
    assert issue.claim_lease.session_id == "thread-turn"
    assert issue.claim_lease.attempt == 2
  end

  test "claim lease normalization does not serialize missing optional fields as nil strings" do
    now = DateTime.utc_now()

    lease =
      ClaimLease.new(%{
        comment_id: nil,
        issue_id: "issue-nil-fields",
        issue_identifier: "MT-NIL",
        role: "implementer",
        holder: "worker-1",
        run_id: "run-1",
        worker_host: nil,
        workspace_path: nil,
        session_id: nil,
        retry_reason: nil,
        recovery_reason: nil,
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    assert lease.comment_id == nil
    assert lease.worker_host == nil
    assert lease.workspace_path == nil
    assert lease.session_id == nil
    assert lease.retry_reason == nil
    assert lease.recovery_reason == nil

    rendered = ClaimLease.render(lease)
    refute rendered =~ ~s("comment_id")
    refute rendered =~ ~s("session_id": "nil")
    refute rendered =~ ~s("retry_reason": "nil")
    refute rendered =~ ~s("recovery_reason": "nil")
  end

  test "dispatch refuses a duplicate top-level run while an external claim lease is active" do
    previous_holder = Application.get_env(:symphony_elixir, :claim_lease_holder)

    on_exit(fn ->
      restore_app_env(:claim_lease_holder, previous_holder)
    end)

    Application.put_env(:symphony_elixir, :claim_lease_holder, "this-worker")

    issue = %Issue{
      id: "issue-active-lease",
      identifier: "MT-567",
      title: "Duplicate lease",
      state: "In Progress",
      claim_lease:
        ClaimLease.new(%{
          issue_id: "issue-active-lease",
          issue_identifier: "MT-567",
          role: "implementer",
          holder: "other-worker",
          run_id: "run-other",
          refreshed_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
          state: "active"
        })
    }

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch refuses same-holder active lease after runtime memory loss" do
    previous_holder = Application.get_env(:symphony_elixir, :claim_lease_holder)

    on_exit(fn ->
      restore_app_env(:claim_lease_holder, previous_holder)
    end)

    Application.put_env(:symphony_elixir, :claim_lease_holder, "this-worker")

    issue = %Issue{
      id: "issue-same-holder-lease",
      identifier: "MT-571",
      title: "Same holder duplicate lease",
      state: "In Progress",
      claim_lease:
        ClaimLease.new(%{
          issue_id: "issue-same-holder-lease",
          issue_identifier: "MT-571",
          role: "implementer",
          holder: "this-worker",
          run_id: "run-existing",
          refreshed_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
          state: "active"
        })
    }

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch allows active claim lease for a different role" do
    previous_holder = Application.get_env(:symphony_elixir, :claim_lease_holder)
    previous_role = System.get_env("SYMPHONY_ROLE")

    on_exit(fn ->
      restore_app_env(:claim_lease_holder, previous_holder)
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    Application.put_env(:symphony_elixir, :claim_lease_holder, "this-reviewer")
    System.put_env("SYMPHONY_ROLE", "reviewer")

    issue = %Issue{
      id: "issue-cross-role-lease",
      identifier: "MT-573",
      title: "Cross role lease",
      state: "In Progress",
      claim_lease:
        ClaimLease.new(%{
          issue_id: "issue-cross-role-lease",
          issue_identifier: "MT-573",
          role: "implementer",
          holder: "other-worker",
          run_id: "run-other",
          refreshed_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
          state: "active"
        })
    }

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch refuses same-scope claim lease when a newer cross-role lease exists" do
    previous_holder = Application.get_env(:symphony_elixir, :claim_lease_holder)
    previous_role = System.get_env("SYMPHONY_ROLE")

    on_exit(fn ->
      restore_app_env(:claim_lease_holder, previous_holder)
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    Application.put_env(:symphony_elixir, :claim_lease_holder, "this-implementer")
    System.put_env("SYMPHONY_ROLE", "implementer")

    now = DateTime.utc_now()

    implementer_marker =
      ClaimLease.render(%{
        issue_id: "issue-hidden-implementer-lease",
        issue_identifier: "MT-577",
        role: "implementer",
        holder: "other-implementer",
        run_id: "run-implementer",
        refreshed_at: DateTime.add(now, -30, :second),
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    reviewer_marker =
      ClaimLease.render(%{
        issue_id: "issue-hidden-implementer-lease",
        issue_identifier: "MT-577",
        role: "reviewer",
        holder: "other-reviewer",
        run_id: "run-reviewer",
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    issue =
      Client.normalize_issue_for_test(%{
        "id" => "issue-hidden-implementer-lease",
        "identifier" => "MT-577",
        "title" => "Hidden implementer lease",
        "state" => %{"name" => "In Progress"},
        "comments" => %{
          "nodes" => [
            %{"id" => "comment-implementer", "body" => "## Symphony Claim Lease\n\n#{implementer_marker}"},
            %{"id" => "comment-reviewer", "body" => "## Symphony Claim Lease\n\n#{reviewer_marker}"}
          ]
        }
      })

    assert issue.claim_lease.role == "reviewer"
    assert length(Map.get(issue, :claim_leases, [])) == 2

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch allows active claim lease for a different explicit workspace" do
    previous_holder = Application.get_env(:symphony_elixir, :claim_lease_holder)

    on_exit(fn ->
      restore_app_env(:claim_lease_holder, previous_holder)
    end)

    Application.put_env(:symphony_elixir, :claim_lease_holder, "this-worker")

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cross-workspace-lease-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-cross-workspace-lease",
      identifier: "MT-574",
      title: "Cross workspace lease",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      claim_lease:
        ClaimLease.new(%{
          issue_id: "issue-cross-workspace-lease",
          issue_identifier: "MT-574",
          role: "implementer",
          holder: "other-worker",
          run_id: "run-other",
          workspace_path: Path.join(workspace_root, "other-workspace"),
          refreshed_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
          state: "active"
        })
    }

    on_exit(fn -> File.rm_rf(workspace_root) end)

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "final dispatch revalidation refuses an active external claim lease" do
    issue = %Issue{
      id: "issue-final-lease",
      identifier: "MT-572",
      title: "Final lease gate",
      state: "In Progress"
    }

    refreshed_issue = %{
      issue
      | claim_lease:
          ClaimLease.new(%{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            role: "implementer",
            holder: "other-worker",
            run_id: "run-other",
            refreshed_at: DateTime.utc_now(),
            expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
            state: "active"
          })
    }

    assert {:skip, ^refreshed_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fn [issue_id] ->
               assert issue_id == issue.id
               {:ok, [refreshed_issue]}
             end)
  end

  test "dispatch allows an expired external claim lease when no process ownership remains" do
    issue = %Issue{
      id: "issue-expired-lease",
      identifier: "MT-568",
      title: "Expired lease",
      state: "In Progress",
      claim_lease:
        ClaimLease.new(%{
          issue_id: "issue-expired-lease",
          issue_identifier: "MT-568",
          role: "implementer",
          holder: "other-worker",
          run_id: "run-other",
          refreshed_at: DateTime.add(DateTime.utc_now(), -120, :second),
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
          state: "active"
        })
    }

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch refuses when synthetic process ownership records a live app-server pid" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-process-ownership-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-live-process",
      identifier: "MT-569",
      title: "Live process ownership",
      state: "In Progress"
    }

    sleep = System.find_executable("sleep")
    assert is_binary(sleep)

    port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: [~c"5"]])
    {:os_pid, app_server_pid} = :erlang.port_info(port, :os_pid)

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf(test_root)
    end)

    :ok =
      ProcessOwnership.record_active(issue, %{
        role: "implementer",
        run_id: "run-live-process",
        app_server_pid: app_server_pid
      })

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
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

  @tag skip: is_nil(System.find_executable("setsid")) && "requires setsid"
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

  test "dispatch allows process ownership for a different role" do
    previous_role = System.get_env("SYMPHONY_ROLE")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    System.put_env("SYMPHONY_ROLE", "reviewer")

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cross-role-process-ownership-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-cross-role-process",
      identifier: "MT-575",
      title: "Cross role process ownership",
      state: "In Progress"
    }

    on_exit(fn -> File.rm_rf(test_root) end)

    :ok =
      ProcessOwnership.record_active(issue, %{
        role: "implementer",
        run_id: "run-implementer-process",
        worker_host: "worker-a"
      })

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch refuses same-scope process ownership when a newer cross-role record exists" do
    previous_role = System.get_env("SYMPHONY_ROLE")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    System.put_env("SYMPHONY_ROLE", "implementer")

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-hidden-process-ownership-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-hidden-implementer-process",
      identifier: "MT-578",
      title: "Hidden implementer process ownership",
      state: "In Progress"
    }

    sleep = System.find_executable("sleep")
    assert is_binary(sleep)

    port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: [~c"5"]])
    {:os_pid, app_server_pid} = :erlang.port_info(port, :os_pid)

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf(test_root)
    end)

    :ok =
      ProcessOwnership.record_active(issue, %{
        role: "implementer",
        run_id: "run-implementer-process",
        app_server_pid: app_server_pid
      })

    :ok =
      ProcessOwnership.record_active(issue, %{
        role: "reviewer",
        run_id: "run-reviewer-process",
        worker_host: "worker-a"
      })

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch allows process ownership for a different explicit workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cross-workspace-process-ownership-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-cross-workspace-process",
      identifier: "MT-576",
      title: "Cross workspace process ownership",
      state: "In Progress",
      repository: "EmberAGI/symphony"
    }

    on_exit(fn -> File.rm_rf(test_root) end)

    registry_path = ProcessOwnership.registry_path(issue)
    File.mkdir_p!(Path.dirname(registry_path))

    File.write!(
      registry_path,
      Jason.encode!(%{
        "version" => 1,
        "issue_id" => issue.id,
        "issue_identifier" => issue.identifier,
        "role" => "implementer",
        "run_id" => "run-other-workspace-process",
        "worker_host" => "worker-a",
        "workspace_path" => Path.join(workspace_root, "other-workspace"),
        "state" => "active",
        "cleanup_status" => "active",
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }) <> "\n"
    )

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch refuses when remote process ownership is still active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-process-ownership-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-remote-process",
      identifier: "MT-570",
      title: "Remote process ownership",
      state: "In Progress",
      repository: "EmberAGI/symphony"
    }

    on_exit(fn -> File.rm_rf(test_root) end)

    :ok =
      ProcessOwnership.record_active(issue, %{
        role: "implementer",
        run_id: "run-remote-process",
        worker_host: "worker-a",
        workspace_path: Path.join(workspace_root, "MT-570-symphony")
      })

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch ignores a stale local quarantine record after the process exits" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-quarantine-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-stale-quarantine",
      identifier: "MT-579",
      title: "Stale quarantine",
      state: "In Progress"
    }

    File.mkdir_p!(test_root)
    pid_file = Path.join(test_root, "exited-app-server.pid")
    {_, 0} = System.cmd("sh", ["-c", "echo $$ > #{pid_file}"])
    app_server_pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()

    :ok =
      ProcessOwnership.record_quarantined(
        issue,
        %{
          role: "implementer",
          run_id: "run-stale-quarantine",
          app_server_pid: app_server_pid
        },
        "agent exited before app-server process cleaned: :terminated"
      )

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    assert_eventually(fn ->
      Orchestrator.should_dispatch_issue_for_test(
        issue,
        %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}
      )
    end)
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)
    instrumentation_slack_ms = 2_500

    assert remaining_ms >= min_remaining_ms - instrumentation_slack_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
    assert prompt =~ "Do not call `gh pr merge` directly"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"done\"}}'

            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"done\"}}'

              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner preserves Claude auth failure classification as provider auth exit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-claude-auth-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace_root)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-runner-auth","apiKeySource":"none"}'
      printf '%s\\n' '{"type":"result","subtype":"login_required","is_error":true,"api_error_status":403,"result":"Bearer runner-secret-token expired","session_id":"sess-runner-auth","oauth_token":"runner-oauth-token"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: claude_binary
      )

      issue = %Issue{
        id: "issue-runner-auth",
        identifier: "EMB-1123",
        title: "Preserve provider auth",
        description: "Runtime auth failure",
        state: "In Progress",
        url: "https://example.org/issues/EMB-1123",
        labels: []
      }

      log =
        capture_log(fn ->
          assert catch_exit(AgentRunner.run(issue, nil, run_id: "run-auth")) ==
                   {:provider_auth_failed, %{provider: :claude_code, api_error_status: 403, subtype: "login_required"}}
        end)

      assert log =~ "provider_auth_failed: claude_code status=403 subtype=login_required"
      refute log =~ "runner-secret-token"
      refute log =~ "runner-oauth-token"
      refute log =~ "Bearer"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner classifies provider auth before_run hook failure as provider auth exit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-before-run-auth-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: """
        printf '%s\\n' 'Provider-auth pre-turn withheld: provider-auth provider=claude_code status=unhealthy affected_roles=implementer,reviewer remediation=run claude setup-token raw=Bearer hook-secret-token'
        exit 17
        """
      )

      issue = %Issue{
        id: "issue-before-run-auth",
        identifier: "EMB-1128",
        title: "Classify pre-turn provider auth",
        description: "Runtime auth failure",
        state: "In Progress",
        url: "https://example.org/issues/EMB-1128",
        labels: []
      }

      log =
        capture_log(fn ->
          assert catch_exit(AgentRunner.run(issue, nil, run_id: "run-before-run-auth")) ==
                   {:provider_auth_failed,
                    %{
                      provider: :claude_code,
                      readiness_status: "unhealthy",
                      affected_roles: "implementer,reviewer",
                      remediation_hint: "run claude setup-token"
                    }}
        end)

      assert log =~ "provider_auth_failed: claude_code readiness_status=unhealthy affected_roles=implementer,reviewer remediation=run claude setup-token"
      refute log =~ "hook-secret-token"
      refute log =~ "Bearer"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps non-auth before_run hook failures ordinary" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-before-run-ordinary-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: """
        printf '%s\\n' 'ordinary setup failure'
        exit 19
        """
      )

      issue = %Issue{
        id: "issue-before-run-ordinary",
        identifier: "EMB-1128",
        title: "Keep ordinary hook failures ordinary",
        description: "Ordinary hook failure",
        state: "In Progress",
        url: "https://example.org/issues/EMB-1128",
        labels: []
      }

      assert_raise RuntimeError, ~r/workspace_hook_failed.*before_run.*ordinary setup failure/, fn ->
        AgentRunner.run(issue, nil, run_id: "run-before-run-ordinary")
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner classifies missing tool before_run hook failure as irrecoverable runtime exit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-before-run-missing-tool-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: """
        printf '%s\\n' 'claude: command not found token=hook-secret-token'
        exit 127
        """
      )

      issue = %Issue{
        id: "issue-before-run-missing-tool",
        identifier: "EMB-1127",
        title: "Classify missing tool",
        description: "Runtime missing tool",
        state: "In Progress",
        url: "https://example.org/issues/EMB-1127",
        labels: []
      }

      log =
        capture_log(fn ->
          assert {:irrecoverable_runtime_failed, failure} =
                   catch_exit(AgentRunner.run(issue, nil, run_id: "run-before-run-missing-tool"))

          assert failure.family == :missing_required_tool_or_cli
          assert failure.retryable? == false
          refute failure.retry_reason =~ "hook-secret-token"
          refute failure.retry_reason =~ "token="
        end)

      assert log =~ "missing_required_tool_or_cli"
      refute log =~ "hook-secret-token"
      refute log =~ "token="
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"done"}}'

            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"done"}}'

            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"done"}}'

            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"done"}}'

            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"
      printf 'ROLE_RUN:%s\\n' \"$SYMPHONY_ROLE_RUN_ID\" >> \"$trace_file\"
      printf 'ROLE_ISSUE:%s\\n' \"$SYMPHONY_ROLE_ISSUE_ID\" >> \"$trace_file\"
      printf 'ROLE_IDENTIFIER:%s\\n' \"$SYMPHONY_ROLE_ISSUE_IDENTIFIER\" >> \"$trace_file\"
      printf 'ROLE_NAME:%s\\n' \"$SYMPHONY_ROLE_NAME\" >> \"$trace_file\"
      printf 'ROLE_WORKSPACE:%s\\n' \"$SYMPHONY_ROLE_WORKSPACE_PATH\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"done\"}}'

            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue, run_id: "run-app-server-env")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))
      assert "ROLE_RUN:run-app-server-env" in lines
      assert "ROLE_ISSUE:issue-args" in lines
      assert "ROLE_IDENTIFIER:MT-77" in lines
      assert "ROLE_NAME:implementer" in lines
      assert "ROLE_WORKSPACE:#{canonical_workspace}" in lines

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"done\"}}'

            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\"")
      assert String.contains?(argv_line, "app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"done"}}'

            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
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
