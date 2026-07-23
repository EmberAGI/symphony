defmodule SymphonyElixir.OrchestratorDispatchOwnershipTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Runtime.ProcessOwnership
  alias SymphonyElixir.Tracker.{ClaimLease, Memory}

  defmodule OwnedSessionLivenessAdapter do
    def owned_session_liveness(ownership_ref) do
      recipient = Application.fetch_env!(:symphony_elixir, :owned_session_liveness_recipient)
      result = Application.fetch_env!(:symphony_elixir, :owned_session_liveness_result)
      send(recipient, {:dispatch_liveness_checked, ownership_ref})
      {:ok, result}
    end
  end

  defmodule PostRunOwnedSessionLivenessAdapter do
    def owned_session_liveness(ownership_ref) do
      recipient =
        Map.get(ownership_ref, :owner) ||
          Application.fetch_env!(:symphony_elixir, :post_run_liveness_recipient)

      result =
        Map.get(ownership_ref, :result) ||
          Application.fetch_env!(:symphony_elixir, :post_run_liveness_result)

      send(recipient, {:post_run_liveness_checked, Map.get(ownership_ref, :session_name), result})
      {:ok, result}
    end
  end

  defmodule PlannedOwnedSessionTransport do
    def planned_owned_session_ref(session_name, _context) do
      %{kind: "herdr", session_name: session_name}
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

  test "orphaned claim release preserves a claim with live quarantined ownership" do
    previous_liveness_module = Application.get_env(:symphony_elixir, :owned_session_liveness_module)
    previous_liveness_recipient = Application.get_env(:symphony_elixir, :post_run_liveness_recipient)
    previous_liveness_result = Application.get_env(:symphony_elixir, :post_run_liveness_result)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    test_root = Path.join(System.tmp_dir!(), "symphony-post-run-release-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    Application.put_env(
      :symphony_elixir,
      :owned_session_liveness_module,
      PostRunOwnedSessionLivenessAdapter
    )

    Application.put_env(:symphony_elixir, :post_run_liveness_recipient, self())
    Application.put_env(:symphony_elixir, :post_run_liveness_result, :live)

    on_exit(fn ->
      restore_app_env(:owned_session_liveness_module, previous_liveness_module)
      restore_app_env(:post_run_liveness_recipient, previous_liveness_recipient)
      restore_app_env(:post_run_liveness_result, previous_liveness_result)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end)

    issue_id = "issue-post-run-release-live"
    issue_identifier = "MT-POST-RUN-LIVE"
    workspace_path = Path.join(workspace_root, "#{issue_identifier}-symphony")

    claim_lease =
      ClaimLease.new(%{
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-post-run-release-live",
        workspace_path: workspace_path,
        state: "active"
      })

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Post-run claim release",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      claim_lease: claim_lease,
      claim_leases: [claim_lease]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert :ok =
             ProcessOwnership.record_quarantined(
               issue,
               %{
                 role: "implementer",
                 run_id: claim_lease.run_id,
                 workspace_path: workspace_path,
                 owned_session_ref: %{
                   kind: "herdr",
                   session_name: "octo-post-run-live",
                   agent_name: "implementer_orchestrator"
                 }
               },
               "post-run native ownership"
             )

    next_state = Orchestrator.reconcile_claims_for_test(%Orchestrator.State{claimed: MapSet.new([issue_id])})

    assert MapSet.member?(next_state.claimed, issue_id)
    assert next_state.blocked_failures[issue_id].family == :owned_session_cleanup_unverified
    assert_receive {:post_run_liveness_checked, "octo-post-run-live", :live}, 500
    assert_receive {:memory_tracker_comment, ^issue_id, note}, 500
    assert note =~ "owned_session_cleanup_unverified"
    assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 500
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}, 500
    refute_receive {:memory_tracker_claim_lease, ^issue_id, %{state: "released"}}, 100
  end

  test "orphaned claim release refuses a replacement same-scope claim after an absent old session" do
    previous_liveness_module = Application.get_env(:symphony_elixir, :owned_session_liveness_module)
    previous_liveness_recipient = Application.get_env(:symphony_elixir, :post_run_liveness_recipient)
    previous_liveness_result = Application.get_env(:symphony_elixir, :post_run_liveness_result)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    test_root = Path.join(System.tmp_dir!(), "symphony-stale-claim-release-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    Application.put_env(
      :symphony_elixir,
      :owned_session_liveness_module,
      PostRunOwnedSessionLivenessAdapter
    )

    Application.put_env(:symphony_elixir, :post_run_liveness_recipient, self())
    Application.put_env(:symphony_elixir, :post_run_liveness_result, :absent)

    on_exit(fn ->
      restore_app_env(:owned_session_liveness_module, previous_liveness_module)
      restore_app_env(:post_run_liveness_recipient, previous_liveness_recipient)
      restore_app_env(:post_run_liveness_result, previous_liveness_result)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end)

    issue_id = "issue-stale-claim-release"
    issue_identifier = "MT-STALE-CLAIM-RELEASE"
    workspace_path = Path.join(workspace_root, "#{issue_identifier}-symphony")

    replacement_claim =
      ClaimLease.new(%{
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-replacement",
        workspace_path: workspace_path,
        state: "active"
      })

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Replacement claim fencing",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      claim_lease: replacement_claim,
      claim_leases: [replacement_claim]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert :ok =
             ProcessOwnership.record_quarantined(
               issue,
               %{
                 role: "implementer",
                 run_id: "run-old-session",
                 workspace_path: workspace_path,
                 owned_session_ref: %{
                   kind: "herdr",
                   session_name: "octo-stale-old-session",
                   agent_name: "implementer_orchestrator"
                 }
               },
               "old session is absent"
             )

    next_state = Orchestrator.reconcile_claims_for_test(%Orchestrator.State{claimed: MapSet.new([issue_id])})

    assert MapSet.member?(next_state.claimed, issue_id)
    assert next_state.blocked_failures[issue_id].family == :tracker_claim_release_failed
    assert next_state.blocked_failures[issue_id].error == :claim_run_identity_changed
    assert_receive {:post_run_liveness_checked, "octo-stale-old-session", :absent}, 500
    refute_receive {:memory_tracker_claim_lease, ^issue_id, %{state: "released"}}, 100
  end

  test "missing-retry release with empty metadata preserves a newer fetched claim without prior run identity" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-missing-retry-no-run-identity"
    issue_identifier = "MT-MISSING-RETRY-NO-RUN"
    now = DateTime.utc_now()

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    replacement_claim =
      ClaimLease.new(%{
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-newer-fetched-claim",
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Missing retry identity",
      state: "Done",
      repository: "EmberAGI/symphony",
      claim_lease: replacement_claim,
      claim_leases: [replacement_claim]
    }

    assert is_nil(ProcessOwnership.status_for_issue(issue))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    state = %Orchestrator.State{claimed: MapSet.new([issue_id])}

    assert {:noreply, next_state} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{})

    assert MapSet.member?(next_state.claimed, issue_id)

    assert %{family: :tracker_claim_release_failed, error: :claim_run_identity_unavailable} =
             next_state.blocked_failures[issue_id]

    refute_receive {:memory_tracker_claim_lease, ^issue_id, %{state: "released"}}, 100
  end

  test "running teardown without a run identity preserves a replacement claim and workspace" do
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    test_root = Path.join(System.tmp_dir!(), "symphony-nil-run-teardown-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue_id = "issue-nil-run-teardown"
    issue_identifier = "MT-NIL-RUN-TEARDOWN"
    now = DateTime.utc_now()
    workspace_path = Path.join(workspace_root, "#{issue_identifier}-symphony")

    on_exit(fn ->
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    File.mkdir_p!(workspace_path)
    File.write!(Path.join(workspace_path, "must-remain"), "replacement workspace")

    old_claim =
      ClaimLease.new(%{
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: "run-old-teardown",
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    replacement_claim =
      ClaimLease.new(%{
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        role: "implementer",
        holder: "replacement-holder",
        run_id: "run-replacement-teardown",
        refreshed_at: now,
        expires_at: DateTime.add(now, 60, :second),
        state: "active"
      })

    running_issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Nil run teardown",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      claim_lease: old_claim,
      claim_leases: [old_claim]
    }

    terminal_issue = %{
      running_issue
      | state: "Done",
        claim_lease: replacement_claim,
        claim_leases: [replacement_claim, old_claim]
    }

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: nil,
          ref: nil,
          identifier: issue_identifier,
          issue: running_issue,
          claim_lease: old_claim,
          run_id: nil,
          workspace_path: workspace_path,
          started_at: now
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([terminal_issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert File.exists?(Path.join(workspace_path, "must-remain"))

    assert %{family: :tracker_claim_release_failed, error: :claim_run_identity_unavailable} =
             updated_state.blocked_failures[issue_id]

    refute_receive {:memory_tracker_claim_lease, ^issue_id, %{state: "released"}}, 100
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

  test "final dispatch refusal releases only the claim created by that run" do
    issue_id = "issue-dispatch-final-refusal"
    run_id = "run-dispatch-final-refusal"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-DISPATCH-REFUSAL",
      title: "Reconcile refused dispatch",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      labels: []
    }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    assert {:ok, claim_lease} =
             Memory.upsert_claim_lease(issue_id, %{
               comment_id: "comment-dispatch-final-refusal",
               issue_identifier: issue.identifier,
               role: "implementer",
               holder: ClaimLease.holder_id(),
               run_id: run_id,
               refreshed_at: DateTime.utc_now(),
               expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
               state: "active"
             })

    assert_receive {:memory_tracker_claim_lease, ^issue_id, %{state: "active"}}, 500

    claimed_issue = %{issue | claim_lease: claim_lease, claim_leases: [claim_lease]}
    terminal_issue = %{claimed_issue | state: "Done"}
    fetcher = fn [^issue_id] -> {:ok, [terminal_issue]} end

    state = %Orchestrator.State{claimed: MapSet.new()}

    assert {^state, {:error, :issue_or_claim_changed}} =
             Orchestrator.reconcile_final_dispatch_fence_for_test(
               state,
               claimed_issue,
               run_id,
               fetcher
             )

    assert_receive {:memory_tracker_claim_lease, ^issue_id, released_lease}, 500
    assert released_lease.comment_id == claim_lease.comment_id
    assert released_lease.run_id == run_id
    assert released_lease.state == "released"
  end

  test "final dispatch fence queries the planned run-owned Herdr session before spawn" do
    previous_adapter = Application.get_env(:symphony_elixir, :owned_session_liveness_module)
    previous_recipient = Application.get_env(:symphony_elixir, :owned_session_liveness_recipient)
    previous_result = Application.get_env(:symphony_elixir, :owned_session_liveness_result)
    previous_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-planned-session-final-fence"
    run_id = "run-planned-session-final-fence"

    on_exit(fn ->
      restore_app_env(:owned_session_liveness_module, previous_adapter)
      restore_app_env(:owned_session_liveness_recipient, previous_recipient)
      restore_app_env(:owned_session_liveness_result, previous_result)
      restore_app_env(:delegation_transport_module, previous_transport)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
    end)

    Application.put_env(
      :symphony_elixir,
      :owned_session_liveness_module,
      OwnedSessionLivenessAdapter
    )

    Application.put_env(:symphony_elixir, :owned_session_liveness_recipient, self())
    Application.put_env(:symphony_elixir, :owned_session_liveness_result, :live)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(
      :symphony_elixir,
      :delegation_transport_module,
      PlannedOwnedSessionTransport
    )

    claim_lease =
      ClaimLease.new(%{
        comment_id: "comment-planned-session-final-fence",
        issue_id: issue_id,
        issue_identifier: "MT-PLANNED-SESSION-FENCE",
        role: "implementer",
        holder: ClaimLease.holder_id(),
        run_id: run_id,
        refreshed_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
        state: "active"
      })

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PLANNED-SESSION-FENCE",
      title: "Planned session final fence",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      claim_lease: claim_lease,
      claim_leases: [claim_lease]
    }

    fetcher = fn [^issue_id] -> {:ok, [issue]} end
    state = %Orchestrator.State{claimed: MapSet.new()}

    assert {next_state, {:error, {:native_session_liveness_changed, :live}}} =
             Orchestrator.reconcile_final_dispatch_fence_for_test(
               state,
               issue,
               run_id,
               fetcher
             )

    assert next_state == state

    assert_receive {:dispatch_liveness_checked,
                    %{
                      kind: "herdr",
                      session_name: session_name,
                      agent_name: "implementer_orchestrator"
                    }}

    assert String.starts_with?(session_name, "octo-mt-planned-session")
    refute_receive {:memory_tracker_claim_lease, ^issue_id, %{state: "released"}}, 100
  end

  test "dispatch persists planned session ownership before launching the task" do
    previous_adapter = Application.get_env(:symphony_elixir, :owned_session_liveness_module)
    previous_recipient = Application.get_env(:symphony_elixir, :owned_session_liveness_recipient)
    previous_result = Application.get_env(:symphony_elixir, :owned_session_liveness_result)
    previous_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-prelaunch-session-ownership-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-prelaunch-session-ownership",
      identifier: "MT-PRELAUNCH-SESSION",
      title: "Prelaunch session ownership",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      labels: []
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      poll_interval_ms: 1_000_000,
      hook_before_run: "sleep 30"
    )

    Application.put_env(
      :symphony_elixir,
      :owned_session_liveness_module,
      OwnedSessionLivenessAdapter
    )

    Application.put_env(:symphony_elixir, :owned_session_liveness_recipient, self())
    Application.put_env(:symphony_elixir, :owned_session_liveness_result, :absent)

    Application.put_env(
      :symphony_elixir,
      :delegation_transport_module,
      PlannedOwnedSessionTransport
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :PrelaunchSessionOwnership)
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
      restore_app_env(:owned_session_liveness_module, previous_adapter)
      restore_app_env(:owned_session_liveness_recipient, previous_recipient)
      restore_app_env(:owned_session_liveness_result, previous_result)
      restore_app_env(:delegation_transport_module, previous_transport)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end)

    assert_receive {:dispatch_liveness_checked, %{session_name: session_name}}, 5_000
    assert_receive {:memory_tracker_claim_lease, issue_id, claim_lease}, 5_000
    assert issue_id == issue.id
    assert_receive {:dispatch_liveness_checked, %{session_name: ^session_name}}, 5_000

    assert_eventually(fn ->
      case ProcessOwnership.status_for_issue(issue) do
        %{
          state: "active",
          run_id: run_id,
          owned_session_ref: %{
            kind: "herdr",
            session_name: ^session_name,
            agent_name: "implementer_orchestrator"
          }
        } ->
          run_id == claim_lease.run_id

        _ ->
          false
      end
    end)
  end

  test "actual dispatch refuses a live planned session before claim upsert or spawn" do
    previous_adapter = Application.get_env(:symphony_elixir, :owned_session_liveness_module)
    previous_recipient = Application.get_env(:symphony_elixir, :owned_session_liveness_recipient)
    previous_result = Application.get_env(:symphony_elixir, :owned_session_liveness_result)
    previous_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-live-planned-session-dispatch-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-live-planned-session-dispatch",
      identifier: "MT-LIVE-PLANNED-SESSION",
      title: "Live planned session dispatch",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      labels: []
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      poll_interval_ms: 1_000_000,
      hook_before_run: "sleep 30"
    )

    Application.put_env(:symphony_elixir, :owned_session_liveness_module, OwnedSessionLivenessAdapter)
    Application.put_env(:symphony_elixir, :owned_session_liveness_recipient, self())
    Application.put_env(:symphony_elixir, :owned_session_liveness_result, :live)
    Application.put_env(:symphony_elixir, :delegation_transport_module, PlannedOwnedSessionTransport)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :LivePlannedSessionDispatch)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(orchestrator_pid)
      restore_app_env(:owned_session_liveness_module, previous_adapter)
      restore_app_env(:owned_session_liveness_recipient, previous_recipient)
      restore_app_env(:owned_session_liveness_result, previous_result)
      restore_app_env(:delegation_transport_module, previous_transport)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end)

    assert_receive {:dispatch_liveness_checked, %{kind: "herdr", agent_name: "implementer_orchestrator"}},
                   5_000

    issue_id = issue.id
    refute_receive {:memory_tracker_claim_lease, ^issue_id, _lease}, 500
    assert :sys.get_state(orchestrator_pid).running == %{}
    refute ProcessOwnership.status_for_issue(issue)
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
