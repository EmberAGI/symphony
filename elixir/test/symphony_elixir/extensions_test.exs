defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker.ClaimLease
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      Process.get({__MODULE__, :fetch_issue_states_result}, {:ok, issue_ids})
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 2_000

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 2_000

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 2_000

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert :ok = SymphonyElixir.Tracker.add_issue_label("issue-1", "Human Escalation")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}
    assert_receive {:memory_tracker_label_add, "issue-1", "Human Escalation"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")
    assert :ok = Memory.add_issue_label("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{
                 "labels" => %{"nodes" => [%{"id" => "label-human", "name" => "Human Escalation"}]}
               },
               "labels" => %{"nodes" => []}
             }
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.add_issue_label("issue-1", "Human Escalation")
    assert_receive {:graphql_called, label_lookup_query, variables} when variables == %{issueId: "issue-1"}
    assert label_lookup_query =~ "labels"

    assert_receive {:graphql_called, add_label_query, variables}
                   when variables == %{issueId: "issue-1", labelId: "label-human"}

    assert add_label_query =~ "addedLabelIds"

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :label_not_found} = Adapter.add_issue_label("issue-1", "Missing")
  end

  test "linear adapter updates and verifies an existing claim lease comment before dispatch" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      Process.delete({FakeLinearClient, :graphql_results})
      Process.delete({FakeLinearClient, :fetch_issue_states_result})
    end)

    lease_attrs = %{
      comment_id: "comment-lease",
      issue_id: "issue-lease",
      issue_identifier: "MT-LEASE",
      role: "implementer",
      holder: "holder-1",
      run_id: "run-1",
      state: "active",
      refreshed_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    verified_lease = ClaimLease.new(lease_attrs)

    Process.put({FakeLinearClient, :graphql_results}, [
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
    ])

    Process.put(
      {FakeLinearClient, :fetch_issue_states_result},
      {:ok, [%Issue{id: "issue-lease", claim_lease: verified_lease}]}
    )

    assert {:ok, ^verified_lease} = Adapter.upsert_claim_lease("issue-lease", lease_attrs)

    assert_receive {:graphql_called, update_query, %{commentId: "comment-lease", body: body}}
    assert update_query =~ "commentUpdate"
    refute update_query =~ "commentCreate"
    assert body =~ "symphony-claim-lease:v1"
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-lease"]}
  end

  test "linear adapter creates a claim lease marker when no comment id exists" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      Process.delete({FakeLinearClient, :graphql_results})
      Process.delete({FakeLinearClient, :fetch_issue_states_result})
    end)

    now = DateTime.utc_now()

    lease_attrs = %{
      comment_id: nil,
      issue_id: "issue-new-lease",
      issue_identifier: "MT-NEW-LEASE",
      role: "implementer",
      holder: "holder-1",
      run_id: "run-1",
      state: "active",
      refreshed_at: now,
      expires_at: DateTime.add(now, 60, :second)
    }

    verified_lease = ClaimLease.new(lease_attrs)

    Process.put({FakeLinearClient, :graphql_results}, [
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "comment-created"}}}}}
    ])

    Process.put(
      {FakeLinearClient, :fetch_issue_states_result},
      {:ok, [%Issue{id: "issue-new-lease", claim_lease: verified_lease}]}
    )

    assert {:ok, ^verified_lease} = Adapter.upsert_claim_lease("issue-new-lease", lease_attrs)

    assert_receive {:graphql_called, create_query, %{issueId: "issue-new-lease", body: body}}
    assert create_query =~ "commentCreate"
    refute create_query =~ "commentUpdate"
    assert body =~ "symphony-claim-lease:v1"
    refute body =~ ~s("comment_id": "nil")
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-new-lease"]}
  end

  test "linear adapter rejects claim lease upsert when refetch sees a competing same-scope owner" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      Process.delete({FakeLinearClient, :graphql_results})
      Process.delete({FakeLinearClient, :fetch_issue_states_result})
    end)

    now = DateTime.utc_now()

    lease_attrs = %{
      comment_id: "comment-written-lease",
      issue_id: "issue-competing-lease",
      issue_identifier: "MT-COMPETE",
      role: "implementer",
      holder: "holder-1",
      run_id: "run-1",
      workspace_path: "/tmp/workspaces/MT-COMPETE",
      state: "active",
      refreshed_at: now,
      expires_at: DateTime.add(now, 60, :second)
    }

    written_lease = ClaimLease.new(lease_attrs)

    competing_lease =
      ClaimLease.new(%{
        lease_attrs
        | comment_id: "comment-competing-lease",
          holder: "holder-2",
          run_id: "run-2"
      })

    Process.put({FakeLinearClient, :graphql_results}, [
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
    ])

    Process.put(
      {FakeLinearClient, :fetch_issue_states_result},
      {:ok,
       [
         %Issue{
           id: "issue-competing-lease",
           claim_lease: written_lease,
           claim_leases: [written_lease, competing_lease]
         }
       ]}
    )

    assert {:error, :claim_lease_competing_owner} =
             Adapter.upsert_claim_lease("issue-competing-lease", lease_attrs)

    assert_receive {:graphql_called, update_query, %{commentId: "comment-written-lease"}}
    assert update_query =~ "commentUpdate"
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-competing-lease"]}
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "blocked" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "process_ownership" => %{
                   "app_server_pgid" => 5250,
                   "app_server_pid" => 5252,
                   "cleanup_status" => "quarantined",
                   "live" => true,
                   "process_tree_pids" => [5252, 5253],
                   "quarantine_reason" => "live app-server process remains after stalled worker",
                   "run_id" => "run-retry",
                   "session_id" => "thread-retry",
                   "state" => "quarantined",
                   "updated_at" => nil,
                   "worker_host" => nil,
                   "worker_pid" => nil,
                   "workspace_path" => nil
                 }
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "family" => "missing_required_tool_or_cli",
                 "provider" => "claude_code",
                 "subtype" => nil,
                 "error" => "missing_required_tool_or_cli claude command not found",
                 "recovery_reason" => "missing-required-tool-or-cli-repair-required",
                 "worker_host" => nil,
                 "workspace_path" => "/tmp/workspaces/MT-BLOCKED",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "claim_lease" => %{
                   "attempt" => 3,
                   "expires_at" => nil,
                   "holder" => "worker-1",
                   "issue_id" => "issue-blocked",
                   "issue_identifier" => "MT-BLOCKED",
                   "recovery_reason" => "missing-required-tool-or-cli-repair-required",
                   "refreshed_at" => nil,
                   "retry_reason" => "missing_required_tool_or_cli claude command not found",
                   "role" => "implementer",
                   "run_id" => "run-blocked",
                   "session_id" => nil,
                   "started_at" => state_payload["blocked"] |> List.first() |> get_in(["claim_lease", "started_at"]),
                   "state" => "blocked",
                   "worker_host" => nil,
                   "workspace_path" => "/tmp/workspaces/MT-BLOCKED"
                 }
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}},
             "polling_diagnostics" => %{
               "checking" => false,
               "status" => "unavailable",
               "next_poll_in_ms" => nil,
               "poll_interval_ms" => nil,
               "last_poll_started_at" => nil,
               "last_poll_completed_at" => nil,
               "last_poll_result" => nil,
               "latest_dispatch_summary" => %{}
             }
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{
             "status" => "retrying",
             "retry" => %{
               "attempt" => 2,
               "error" => "boom",
               "process_ownership" => %{
                 "cleanup_status" => "quarantined",
                 "app_server_pid" => 5252,
                 "live" => true
               }
             }
           } =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "blocked" => %{
               "family" => "missing_required_tool_or_cli",
               "error" => "missing_required_tool_or_cli claude command not found",
               "claim_lease" => %{"state" => "blocked"}
             },
             "retry" => nil,
             "running" => nil
           } =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "presenter exposes claim lease and process ownership payloads when present" do
    now = DateTime.utc_now()

    claim_lease =
      ClaimLease.new(%{
        issue_id: "issue-lease-payload",
        issue_identifier: "MT-LEASE",
        role: "implementer",
        holder: "worker-1",
        run_id: "run-1",
        worker_host: "worker-a",
        workspace_path: "/tmp/workspaces/MT-LEASE",
        session_id: "thread-turn",
        attempt: 3,
        started_at: now,
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    snapshot = %{
      running: [
        %{
          issue_id: "issue-lease-payload",
          identifier: "MT-LEASE",
          state: "In Progress",
          worker_host: "worker-a",
          workspace_path: "/tmp/workspaces/MT-LEASE",
          claim_lease: claim_lease,
          process_ownership: %{
            state: "active",
            cleanup_status: "active",
            worker_host: "worker-a",
            workspace_path: "/tmp/workspaces/MT-LEASE",
            app_server_pid: 4242,
            run_id: "run-1",
            session_id: "thread-turn",
            live?: true
          },
          session_id: "thread-turn",
          turn_count: 1,
          last_codex_event: :session_started,
          last_codex_message: nil,
          last_codex_timestamp: now,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          started_at: now
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    orchestrator_name = Module.concat(__MODULE__, :LeasePayloadOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    payload = SymphonyElixirWeb.Presenter.state_payload(orchestrator_name, 50)
    running = payload.running |> List.first()

    assert running.claim_lease.role == "implementer"
    assert running.claim_lease.run_id == "run-1"
    assert running.claim_lease.state == "active"
    assert running.process_ownership.cleanup_status == "active"
    assert running.process_ownership.app_server_pid == 4242
    assert running.process_ownership.live == true
  end

  test "presenter exposes retry process ownership payloads when present" do
    now = DateTime.utc_now()

    claim_lease =
      ClaimLease.new(%{
        issue_id: "issue-retry-ownership",
        issue_identifier: "MT-RETRY-OWNERSHIP",
        role: "implementer",
        holder: "worker-1",
        run_id: "run-retry-1",
        worker_host: "worker-a",
        workspace_path: "/tmp/workspaces/MT-RETRY-OWNERSHIP",
        session_id: "thread-retry",
        attempt: 2,
        started_at: now,
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        retry_reason: "stalled for 1000ms",
        state: "quarantined"
      })

    snapshot = %{
      running: [],
      retrying: [
        %{
          issue_id: "issue-retry-ownership",
          identifier: "MT-RETRY-OWNERSHIP",
          attempt: 2,
          due_in_ms: 2_000,
          error: "stalled for 1000ms",
          worker_host: "worker-a",
          workspace_path: "/tmp/workspaces/MT-RETRY-OWNERSHIP",
          claim_lease: claim_lease,
          process_ownership: %{
            state: "quarantined",
            cleanup_status: "quarantined",
            worker_host: "worker-a",
            workspace_path: "/tmp/workspaces/MT-RETRY-OWNERSHIP",
            app_server_pid: 5252,
            app_server_pgid: 5250,
            process_tree_pids: [5252, 5253],
            run_id: "run-retry-1",
            session_id: "thread-retry",
            quarantine_reason: "agent exited before app-server process cleaned: :terminated",
            live?: true
          }
        }
      ],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    orchestrator_name = Module.concat(__MODULE__, :RetryOwnershipPayloadOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    payload = SymphonyElixirWeb.Presenter.state_payload(orchestrator_name, 50)
    retry = payload.retrying |> List.first()

    assert retry.claim_lease.state == "quarantined"
    assert retry.process_ownership.cleanup_status == "quarantined"
    assert retry.process_ownership.app_server_pid == 5252
    assert retry.process_ownership.process_tree_pids == [5252, 5253]
    assert retry.process_ownership.live == true

    assert {:ok, issue_payload} =
             SymphonyElixirWeb.Presenter.issue_payload(
               "MT-RETRY-OWNERSHIP",
               orchestrator_name,
               50
             )

    assert issue_payload.retry.claim_lease.state == "quarantined"
    assert issue_payload.retry.process_ownership.cleanup_status == "quarantined"

    assert issue_payload.retry.process_ownership.quarantine_reason =~
             "app-server process cleaned"
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ "rendered"
    assert html =~ "Blocked runtime failures"
    assert html =~ "missing_required_tool_or_cli"
    assert html =~ "missing-required-tool-or-cli-repair-required"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "blocked" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    blocked_started_at = DateTime.utc_now()

    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom",
          process_ownership: %{
            state: "quarantined",
            cleanup_status: "quarantined",
            app_server_pid: 5252,
            app_server_pgid: 5250,
            process_tree_pids: [5252, 5253],
            run_id: "run-retry",
            session_id: "thread-retry",
            quarantine_reason: "live app-server process remains after stalled worker",
            live?: true
          }
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          family: :missing_required_tool_or_cli,
          provider: :claude_code,
          error: "missing_required_tool_or_cli claude command not found",
          recovery_reason: "missing-required-tool-or-cli-repair-required",
          worker_host: nil,
          workspace_path: "/tmp/workspaces/MT-BLOCKED",
          blocked_at: DateTime.utc_now(),
          claim_lease:
            ClaimLease.new(%{
              issue_id: "issue-blocked",
              issue_identifier: "MT-BLOCKED",
              role: "implementer",
              holder: "worker-1",
              run_id: "run-blocked",
              workspace_path: "/tmp/workspaces/MT-BLOCKED",
              attempt: 3,
              retry_reason: "missing_required_tool_or_cli claude command not found",
              recovery_reason: "missing-required-tool-or-cli-repair-required",
              state: "blocked",
              started_at: blocked_started_at
            })
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
