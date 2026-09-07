defmodule SymphonyElixir.ProcessOwnershipTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Orchestrator, Runtime.ProcessOwnership}
  alias SymphonyElixir.TestSupport.GatedProcessOwnershipFileSystem

  defmodule FailingFileSystem do
    @behaviour SymphonyElixir.Runtime.ProcessOwnership.FileSystem

    @impl true
    def write(_path, _contents, _modes), do: {:error, :enospc}
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    previous_file_system = Application.get_env(:symphony_elixir, :process_ownership_file_system)
    previous_gate = Application.get_env(:symphony_elixir, :process_ownership_file_system_gate)
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
      restore_app_env(:process_ownership_file_system, previous_file_system)
      restore_app_env(:process_ownership_file_system_gate, previous_gate)
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

  test "active refresh commits normally and a staged late refresh cannot resurrect terminal ownership", %{
    issue: issue
  } do
    attrs = ownership_attrs("refresh-run", "refresh-holder")
    assert {:ok, ownership} = ProcessOwnership.acquire(issue, attrs)

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    ownership_path = ProcessOwnership.registry_path(issue, ownership.workspace_path)

    assert {:ok, %{state: "active", session_id: "session-one"}} =
             ProcessOwnership.refresh_active(issue, identity, %{session_id: "session-one"})

    assert Path.wildcard(ownership_path <> ".tmp-*") == []

    gate_token = make_ref()
    {:ok, gate_controller} = Agent.start_link(fn -> :armed end)

    Application.put_env(
      :symphony_elixir,
      :process_ownership_file_system,
      GatedProcessOwnershipFileSystem
    )

    Application.put_env(:symphony_elixir, :process_ownership_file_system_gate, %{
      controller: gate_controller,
      issue_id: issue.id,
      owner: self(),
      token: gate_token
    })

    refresh =
      Task.async(fn ->
        ProcessOwnership.refresh_active(issue, identity, %{session_id: "staged-too-late"})
      end)

    assert_receive {:routine_ownership_write_entered, writer, ^gate_token, staged_path, %{"run_id" => "refresh-run"}},
                   1_000

    assert String.starts_with?(staged_path, ownership_path <> ".tmp-")

    assert {:ok, %{state: "cleaned"}} = ProcessOwnership.release(issue, identity)

    send(writer, {:release_routine_ownership_write, gate_token})
    assert {:error, :ownership_not_active} = Task.await(refresh, 1_000)

    assert %{state: "cleaned", session_id: "session-one"} =
             ProcessOwnership.status_for_issue(issue)

    assert Path.wildcard(ownership_path <> ".tmp-*") == []
  end

  test "a killed routine refresh task does not strand the scope lock", %{issue: issue} do
    attrs = ownership_attrs("killed-refresh-run", "killed-refresh-holder")
    assert {:ok, ownership} = ProcessOwnership.acquire(issue, attrs)

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    gate_token = make_ref()
    {:ok, gate_controller} = Agent.start_link(fn -> :armed end)

    Application.put_env(:symphony_elixir, :process_ownership_file_system, GatedProcessOwnershipFileSystem)

    Application.put_env(:symphony_elixir, :process_ownership_file_system_gate, %{
      controller: gate_controller,
      issue_id: issue.id,
      owner: self(),
      token: gate_token
    })

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        ProcessOwnership.verify_and_update(issue, identity, %{session_id: "staged-before-kill"})
      end)

    assert_receive {:routine_ownership_write_entered, writer, ^gate_token, _staged_path, %{"run_id" => "killed-refresh-run"}},
                   1_000

    task_pid = task.pid
    task_ref = task.ref
    Process.exit(task.pid, :shutdown)

    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 1_000

    lock_path = ProcessOwnership.registry_path(issue, ownership.workspace_path) <> ".lock"
    assert File.exists?(Path.join(lock_path, "owner.json"))

    Application.delete_env(:symphony_elixir, :process_ownership_file_system)
    Application.delete_env(:symphony_elixir, :process_ownership_file_system_gate)
    send(writer, {:release_routine_ownership_write, gate_token})

    assert {:ok, %{state: "cleaned"}} = ProcessOwnership.release(issue, identity)
  end

  test "routine refresh returns typed filesystem failure without changing active ownership", %{
    issue: issue
  } do
    attrs = ownership_attrs("failed-refresh-run", "failed-refresh-holder")
    assert {:ok, ownership} = ProcessOwnership.acquire(issue, attrs)
    ownership_path = ProcessOwnership.registry_path(issue, ownership.workspace_path)

    Application.put_env(
      :symphony_elixir,
      :process_ownership_file_system,
      FailingFileSystem
    )

    assert {:error, :enospc} =
             ProcessOwnership.refresh_active(
               issue,
               %{
                 holder: ownership.holder,
                 run_id: ownership.run_id,
                 workspace_path: ownership.workspace_path
               },
               %{session_id: "not-persisted"}
             )

    assert %{state: "active", session_id: nil} = ProcessOwnership.status_for_issue(issue)
    assert Path.wildcard(ownership_path <> ".tmp-*") == []
  end

  test "failed-run release refuses the same checkpoint and preserves evidence after reset", %{issue: issue} do
    holder = "#{ProcessOwnership.current_host()}:999999:implementer"
    attrs = ownership_attrs("failed-run", holder)
    assert {:ok, ownership} = ProcessOwnership.acquire(issue, attrs)

    running_entry = %{
      issue: issue,
      workspace_path: ownership.workspace_path,
      run_id: "failed-run",
      process_ownership: ownership
    }

    reason = {:rate_limited, %{message: "provider retry window"}}

    assert {:retryable, _failure, observation} =
             Orchestrator.classify_task_exit_for_test(
               reason,
               running_entry,
               issue.id,
               %Orchestrator.State{execution_generation: "generation-a"}
             )

    identity = %{holder: holder, run_id: "failed-run", workspace_path: ownership.workspace_path}

    assert {:ok, %{state: "retrying", failure_observation: ^observation}} =
             ProcessOwnership.verify_and_update(
               issue,
               identity,
               %{state: "retrying", failure_observation: observation}
             )

    assert {:ok, %{state: "cleaned", failure_observation: ^observation}} =
             ProcessOwnership.release(issue, identity)

    equal_marker_attrs =
      "equal-marker-run"
      |> ownership_attrs(ProcessOwnership.holder_id())
      |> Map.put(:reset_marker, observation.reset_marker)

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(issue, equal_marker_attrs)

    assert %{state: "cleaned", failure_observation: ^observation} =
             ProcessOwnership.status_for_issue(issue)

    changed_marker = %{observation.reset_marker | execution_generation: "generation-b"}

    changed_marker_attrs =
      "changed-marker-run"
      |> ownership_attrs(ProcessOwnership.holder_id())
      |> Map.put(:reset_marker, changed_marker)

    assert {:ok, %{failure_observation: persisted_observation}} =
             ProcessOwnership.acquire(issue, changed_marker_attrs)

    assert persisted_observation == observation

    restarted_entry = %{
      running_entry
      | run_id: "changed-marker-run",
        process_ownership: ProcessOwnership.status_for_issue(issue)
    }

    assert {:retryable, _failure, changed_observation} =
             Orchestrator.classify_task_exit_for_test(
               reason,
               restarted_entry,
               issue.id,
               %Orchestrator.State{execution_generation: "generation-b"}
             )

    assert changed_observation.count == 1
    assert changed_observation.reset_marker.execution_generation == "generation-b"
  end

  test "successful completion release preserves prior typed failure state", %{issue: issue} do
    attrs = ownership_attrs("successful-run", "successful-holder")
    assert {:ok, ownership} = ProcessOwnership.acquire(issue, attrs)

    observation = %{
      fingerprint: %{family: :repeated_identical_no_progress_failure},
      count: 1,
      reset_marker: %{input_fingerprint: "checkpoint-a"}
    }

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, %{failure_observation: ^observation}} =
             ProcessOwnership.verify_and_update(
               issue,
               identity,
               %{state: "retrying", failure_observation: observation}
             )

    assert {:ok, %{state: "cleaned", failure_observation: ^observation}} =
             ProcessOwnership.release_completed(issue, identity)
  end

  test "blocked ownership only reacquires when the current reset marker changes", %{
    issue: issue
  } do
    holder = ProcessOwnership.holder_id()

    initial_marker = %{
      execution_generation: "generation-a",
      input_fingerprint: "checkpoint-a"
    }

    attrs =
      "blocked-run"
      |> ownership_attrs(holder)
      |> Map.put(:reset_marker, initial_marker)

    assert {:ok, ownership} = ProcessOwnership.acquire(issue, attrs)

    observation = %{
      fingerprint: %{family: :unclassified_runtime_failure},
      count: 1,
      reset_marker: initial_marker
    }

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, %{state: "blocked", failure_observation: ^observation}} =
             ProcessOwnership.verify_and_update(issue, identity, %{
               state: "blocked",
               failure_observation: observation
             })

    unchanged_attrs =
      "unchanged-run"
      |> ownership_attrs(holder)
      |> Map.put(:reset_marker, initial_marker)

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(issue, unchanged_attrs)

    changed_attrs =
      "changed-generation-run"
      |> ownership_attrs(holder)
      |> Map.put(:reset_marker, %{initial_marker | execution_generation: "generation-b"})

    assert {:ok,
            %{
              state: "active",
              run_id: "changed-generation-run",
              failure_observation: ^observation
            }} = ProcessOwnership.acquire(issue, changed_attrs)
  end

  test "dead-holder blocked ownership still requires changed reset evidence", %{
    issue: issue
  } do
    dead_holder = "#{ProcessOwnership.current_host()}:999999:implementer"

    initial_marker = %{
      execution_generation: "generation-a",
      input_fingerprint: "checkpoint-a"
    }

    initial_attrs =
      "dead-blocked-run"
      |> ownership_attrs(dead_holder)
      |> Map.put(:reset_marker, initial_marker)

    assert {:ok, ownership} = ProcessOwnership.acquire(issue, initial_attrs)

    observation = %{
      fingerprint: %{family: :unclassified_runtime_failure},
      count: 1,
      reset_marker: initial_marker
    }

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, %{state: "blocked", failure_observation: ^observation}} =
             ProcessOwnership.verify_and_update(issue, identity, %{
               state: "blocked",
               failure_observation: observation
             })

    unchanged_attrs =
      "unchanged-after-restart"
      |> ownership_attrs(ProcessOwnership.holder_id())
      |> Map.put(:reset_marker, initial_marker)

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(issue, unchanged_attrs)

    assert %{state: "blocked", failure_observation: ^observation} =
             ProcessOwnership.status_for_issue(issue)

    changed_attrs =
      "changed-after-restart"
      |> ownership_attrs(ProcessOwnership.holder_id())
      |> Map.put(:reset_marker, %{initial_marker | execution_generation: "generation-b"})

    assert {:ok,
            %{
              state: "active",
              run_id: "changed-after-restart",
              failure_observation: ^observation
            }} = ProcessOwnership.acquire(issue, changed_attrs)
  end

  test "legacy dead-holder blocked ownership without failure evidence reacquires and archives", %{
    issue: issue
  } do
    dead_holder = "#{ProcessOwnership.current_host()}:999999:implementer"

    assert {:ok, ownership} =
             ProcessOwnership.acquire(
               issue,
               ownership_attrs("legacy-blocked-run", dead_holder)
             )

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, %{state: "blocked", failure_observation: nil}} =
             ProcessOwnership.verify_and_update(issue, identity, %{state: "blocked"})

    ownership_path = ProcessOwnership.registry_path(issue)
    legacy_body = File.read!(ownership_path)
    refute Map.has_key?(Jason.decode!(legacy_body), "failure_observation")

    incoming_marker = %{
      execution_generation: "generation-after-rollout",
      input_fingerprint: "checkpoint-after-rollout"
    }

    replacement_attrs =
      "replacement-after-rollout"
      |> ownership_attrs(ProcessOwnership.holder_id())
      |> Map.put(:reset_marker, incoming_marker)

    assert {:ok,
            %{
              state: "active",
              run_id: "replacement-after-rollout",
              failure_observation: nil
            }} = ProcessOwnership.acquire(issue, replacement_attrs)

    assert [archive_path] = Path.wildcard(ownership_path <> ".stale-*")
    assert File.read!(archive_path) == legacy_body
    refute Map.has_key?(Jason.decode!(File.read!(archive_path)), "failure_observation")
  end

  test "blocked ownership with malformed present failure evidence fails closed", %{
    issue: issue
  } do
    dead_holder = "#{ProcessOwnership.current_host()}:999999:implementer"

    assert {:ok, ownership} =
             ProcessOwnership.acquire(
               issue,
               ownership_attrs("malformed-observation-run", dead_holder)
             )

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, %{state: "blocked"}} =
             ProcessOwnership.verify_and_update(issue, identity, %{state: "blocked"})

    ownership_path = ProcessOwnership.registry_path(issue)

    incoming_attrs =
      "must-not-replace-malformed"
      |> ownership_attrs(ProcessOwnership.holder_id())
      |> Map.put(:reset_marker, %{
        execution_generation: "generation-b",
        input_fingerprint: "checkpoint-b"
      })

    for malformed_observation <- [
          nil,
          %{"count" => 1, "fingerprint" => %{"family" => "network_error"}}
        ] do
      malformed_record =
        ownership_path
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("failure_observation", malformed_observation)

      File.write!(ownership_path, Jason.encode!(malformed_record) <> "\n")

      assert {:error, :ownership_held} =
               ProcessOwnership.acquire(issue, incoming_attrs)

      assert %{"state" => "blocked", "failure_observation" => ^malformed_observation} =
               ownership_path |> File.read!() |> Jason.decode!()
    end
  end

  test "stale in-flight ownership with failure evidence requires a changed reset marker", %{
    issue: base_issue
  } do
    dead_holder = "#{ProcessOwnership.current_host()}:999999:implementer"

    initial_marker = %{
      execution_generation: "generation-a",
      input_fingerprint: "checkpoint-a"
    }

    for state <- ["active", "retrying", "quarantined"] do
      issue = %{
        base_issue
        | id: "#{base_issue.id}-#{state}",
          identifier: "#{base_issue.identifier}-#{state}"
      }

      initial_attrs =
        "dead-#{state}-run"
        |> ownership_attrs(dead_holder)
        |> Map.put(:reset_marker, initial_marker)

      assert {:ok, ownership} = ProcessOwnership.acquire(issue, initial_attrs)

      observation = %{
        fingerprint: %{family: :network_error, issue_id: issue.id},
        count: 1,
        reset_marker: initial_marker
      }

      identity = %{
        holder: ownership.holder,
        run_id: ownership.run_id,
        workspace_path: ownership.workspace_path
      }

      assert {:ok, %{state: ^state, failure_observation: ^observation}} =
               ProcessOwnership.verify_and_update(issue, identity, %{
                 state: state,
                 failure_observation: observation
               })

      equal_attrs =
        "equal-marker-#{state}"
        |> ownership_attrs(ProcessOwnership.holder_id())
        |> Map.put(:reset_marker, initial_marker)

      assert {:error, :ownership_held} =
               ProcessOwnership.acquire(issue, equal_attrs)

      assert %{state: ^state, failure_observation: ^observation} =
               ProcessOwnership.status_for_issue(issue)

      changed_attrs =
        "changed-marker-#{state}"
        |> ownership_attrs(ProcessOwnership.holder_id())
        |> Map.put(:reset_marker, %{initial_marker | execution_generation: "generation-b"})

      assert {:ok,
              %{
                state: "active",
                run_id: "changed-marker-" <> ^state,
                failure_observation: ^observation
              }} = ProcessOwnership.acquire(issue, changed_attrs)
    end
  end

  test "stale active ownership without failure evidence retains crash recovery", %{
    issue: issue
  } do
    dead_holder = "#{ProcessOwnership.current_host()}:999999:implementer"

    marker = %{
      execution_generation: "generation-a",
      input_fingerprint: "checkpoint-a"
    }

    initial_attrs =
      "crashed-active-run"
      |> ownership_attrs(dead_holder)
      |> Map.put(:reset_marker, marker)

    assert {:ok, %{state: "active", failure_observation: nil}} =
             ProcessOwnership.acquire(issue, initial_attrs)

    replacement_attrs =
      "crash-recovery-run"
      |> ownership_attrs(ProcessOwnership.holder_id())
      |> Map.put(:reset_marker, marker)

    assert {:ok,
            %{
              state: "active",
              run_id: "crash-recovery-run",
              failure_observation: nil
            }} = ProcessOwnership.acquire(issue, replacement_attrs)
  end

  test "cleaned and released ownership with failure evidence require a changed reset marker", %{
    issue: base_issue
  } do
    initial_marker = %{
      execution_generation: "generation-a",
      input_fingerprint: "checkpoint-a"
    }

    for state <- ["cleaned", "released"] do
      issue = %{
        base_issue
        | id: "#{base_issue.id}-observed-#{state}",
          identifier: "#{base_issue.identifier}-OBSERVED-#{state}"
      }

      assert {:ok, ownership} =
               ProcessOwnership.acquire(
                 issue,
                 ownership_attrs("observed-#{state}-run", ProcessOwnership.holder_id())
               )

      observation = %{
        fingerprint: %{family: :network_error, issue_id: issue.id},
        count: 1,
        reset_marker: initial_marker
      }

      identity = %{
        holder: ownership.holder,
        run_id: ownership.run_id,
        workspace_path: ownership.workspace_path
      }

      assert {:ok, %{state: ^state, failure_observation: ^observation}} =
               ProcessOwnership.verify_and_update(issue, identity, %{
                 state: state,
                 failure_observation: observation
               })

      equal_attrs =
        "equal-marker-#{state}"
        |> ownership_attrs(ProcessOwnership.holder_id())
        |> Map.put(:reset_marker, initial_marker)

      assert {:error, :ownership_held} =
               ProcessOwnership.acquire(issue, equal_attrs)

      assert %{state: ^state, failure_observation: ^observation} =
               ProcessOwnership.status_for_issue(issue)

      changed_attrs =
        "changed-marker-#{state}"
        |> ownership_attrs(ProcessOwnership.holder_id())
        |> Map.put(:reset_marker, %{initial_marker | execution_generation: "generation-b"})

      assert {:ok,
              %{
                state: "active",
                run_id: "changed-marker-" <> ^state,
                failure_observation: ^observation
              }} = ProcessOwnership.acquire(issue, changed_attrs)
    end
  end

  test "observation-free cleaned and released ownership reacquire on an equal reset marker", %{
    issue: base_issue
  } do
    marker = %{
      execution_generation: "generation-a",
      input_fingerprint: "checkpoint-a"
    }

    for state <- ["cleaned", "released"] do
      issue = %{
        base_issue
        | id: "#{base_issue.id}-unobserved-#{state}",
          identifier: "#{base_issue.identifier}-UNOBSERVED-#{state}"
      }

      assert {:ok, ownership} =
               ProcessOwnership.acquire(
                 issue,
                 ownership_attrs("unobserved-#{state}-run", ProcessOwnership.holder_id())
               )

      identity = %{
        holder: ownership.holder,
        run_id: ownership.run_id,
        workspace_path: ownership.workspace_path
      }

      assert {:ok, %{state: ^state, failure_observation: nil}} =
               ProcessOwnership.verify_and_update(issue, identity, %{state: state})

      refute ProcessOwnership.registry_path(issue)
             |> File.read!()
             |> Jason.decode!()
             |> Map.has_key?("failure_observation")

      replacement_attrs =
        "replacement-#{state}"
        |> ownership_attrs(ProcessOwnership.holder_id())
        |> Map.put(:reset_marker, marker)

      assert {:ok,
              %{
                state: "active",
                run_id: "replacement-" <> ^state,
                failure_observation: nil
              }} = ProcessOwnership.acquire(issue, replacement_attrs)
    end
  end

  test "cleaned and released ownership with malformed present failure evidence fails closed", %{
    issue: base_issue
  } do
    incoming_marker = %{
      execution_generation: "generation-b",
      input_fingerprint: "checkpoint-b"
    }

    for state <- ["cleaned", "released"],
        {malformed_name, malformed_observation} <- [
          {"null", nil},
          {"incomplete", %{"count" => 1, "fingerprint" => %{"family" => "network_error"}}}
        ] do
      issue = %{
        base_issue
        | id: "#{base_issue.id}-malformed-#{state}-#{malformed_name}",
          identifier: "#{base_issue.identifier}-MALFORMED-#{state}-#{malformed_name}"
      }

      assert {:ok, ownership} =
               ProcessOwnership.acquire(
                 issue,
                 ownership_attrs("malformed-#{state}-run", ProcessOwnership.holder_id())
               )

      identity = %{
        holder: ownership.holder,
        run_id: ownership.run_id,
        workspace_path: ownership.workspace_path
      }

      assert {:ok, %{state: ^state}} =
               ProcessOwnership.verify_and_update(issue, identity, %{state: state})

      ownership_path = ProcessOwnership.registry_path(issue)

      malformed_record =
        ownership_path
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("failure_observation", malformed_observation)

      File.write!(ownership_path, Jason.encode!(malformed_record) <> "\n")

      incoming_attrs =
        "must-not-replace-#{state}-#{malformed_name}"
        |> ownership_attrs(ProcessOwnership.holder_id())
        |> Map.put(:reset_marker, incoming_marker)

      assert {:error, :ownership_held} =
               ProcessOwnership.acquire(issue, incoming_attrs)

      assert %{"state" => ^state, "failure_observation" => ^malformed_observation} =
               ownership_path |> File.read!() |> Jason.decode!()
    end
  end

  test "stale owned-session recovery retains failure arbitration after relabeling cleaned", %{
    issue: issue
  } do
    dead_holder = "#{ProcessOwnership.current_host()}:999999:implementer"

    initial_marker = %{
      execution_generation: "generation-a",
      input_fingerprint: "checkpoint-a"
    }

    initial_attrs =
      "quarantined-session-run"
      |> ownership_attrs(dead_holder)
      |> Map.put(:owned_session_ref, %{
        kind: "herdr",
        session_name: "octo-quarantined-session"
      })

    assert {:ok, ownership} = ProcessOwnership.acquire(issue, initial_attrs)

    observation = %{
      fingerprint: %{family: :network_error, issue_id: issue.id},
      count: 1,
      reset_marker: initial_marker
    }

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    assert {:ok, %{state: "quarantined", failure_observation: ^observation}} =
             ProcessOwnership.verify_and_update(issue, identity, %{
               state: "quarantined",
               failure_observation: observation
             })

    test_pid = self()

    assert {:ok, 1} =
             ProcessOwnership.recover_stale_owned_sessions(fn ownership_ref ->
               send(test_pid, {:recovered, ownership_ref})
               :ok
             end)

    assert_receive {:recovered, %{session_name: "octo-quarantined-session"}}

    assert %{
             state: "cleaned",
             run_id: "quarantined-session-run",
             failure_observation: ^observation
           } = ProcessOwnership.status_for_issue(issue)

    equal_attrs =
      "equal-after-recovery"
      |> ownership_attrs(ProcessOwnership.holder_id())
      |> Map.put(:reset_marker, initial_marker)

    assert {:error, :ownership_held} =
             ProcessOwnership.acquire(issue, equal_attrs)

    assert %{state: "cleaned", failure_observation: ^observation} =
             ProcessOwnership.status_for_issue(issue)

    changed_attrs =
      "changed-after-recovery"
      |> ownership_attrs(ProcessOwnership.holder_id())
      |> Map.put(:reset_marker, %{initial_marker | input_fingerprint: "checkpoint-b"})

    assert {:ok,
            %{
              state: "active",
              run_id: "changed-after-recovery",
              failure_observation: ^observation
            }} = ProcessOwnership.acquire(issue, changed_attrs)
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

  @tag timeout: 30_000
  test "a live scope lock held by another BEAM cannot be stolen", %{issue: issue} do
    dead_holder = "#{ProcessOwnership.current_host()}:999999:implementer"
    attrs = ownership_attrs("cross-vm-held-run", dead_holder)
    assert {:ok, ownership} = ProcessOwnership.acquire(issue, attrs)

    identity = %{
      holder: ownership.holder,
      run_id: ownership.run_id,
      workspace_path: ownership.workspace_path
    }

    test_root = Path.dirname(Path.dirname(ownership.workspace_path))
    ready_path = Path.join(test_root, "cross-vm-lock-ready")
    release_path = Path.join(test_root, "cross-vm-lock-release")
    workflow_path = Workflow.workflow_file_path()

    holder_port =
      start_external_lock_holder(
        issue,
        identity,
        workflow_path,
        ready_path,
        release_path,
        100
      )

    on_exit(fn ->
      File.touch(release_path)
      close_port(holder_port)
    end)

    assert_eventually(fn -> File.exists?(ready_path) end, 500)

    lock_owner =
      issue
      |> ProcessOwnership.registry_path(ownership.workspace_path)
      |> Kernel.<>(".lock/owner.json")
      |> File.read!()
      |> Jason.decode!()

    refute lock_owner["owner_pid"] == System.pid()
    assert os_process_alive?(String.to_integer(lock_owner["owner_pid"]))

    assert {"", 0} =
             external_acquire_result(
               issue,
               ownership.workspace_path,
               workflow_path,
               lock_owner["owner_process"]
             )

    holder_os_pid = String.to_integer(lock_owner["owner_pid"])
    signal_test_pid(holder_os_pid, "KILL")
    assert_eventually(fn -> not os_process_alive?(holder_os_pid) end)

    assert {:ok, %{state: "active", run_id: "after-cross-vm-crash"}} =
             ProcessOwnership.acquire(
               issue,
               ownership_attrs("after-cross-vm-crash", "replacement-holder")
             )
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
               ownership_attrs("other-run", "owned-holder")
             )

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

  test "stale recovery scans canonical and one-level legacy registries without descending deeper" do
    home_relative_root =
      "~/.symphony-elixir-process-ownership-recovery-#{System.unique_integer([:positive])}"

    workspace_root = Path.expand(home_relative_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      workspace_root: home_relative_root
    )

    canonical_issue = %Issue{
      id: "canonical-recovery",
      identifier: "MT-CANONICAL",
      title: "Canonical recovery",
      state: "In Progress"
    }

    legacy_issue = %Issue{
      id: "legacy-recovery",
      identifier: "MT-LEGACY",
      title: "Legacy recovery",
      state: "In Progress"
    }

    deep_issue = %Issue{
      id: "deep-recovery",
      identifier: "MT-DEEP",
      title: "Deep recovery decoy",
      state: "In Progress"
    }

    for {issue, session_name} <- [
          {canonical_issue, "octo-canonical-recovery"},
          {legacy_issue, "octo-legacy-recovery"},
          {deep_issue, "octo-deep-recovery"}
        ] do
      attrs =
        ownership_attrs("#{issue.id}-run", "localhost:999999:implementer")
        |> Map.put(:owned_session_ref, %{kind: "herdr", session_name: session_name})

      assert {:ok, _ownership} = ProcessOwnership.acquire(issue, attrs)
    end

    legacy_source = ProcessOwnership.registry_path(legacy_issue)

    legacy_path =
      Path.join([
        workspace_root,
        "legacy-workspace",
        ".symphony",
        "process-ownership",
        Path.basename(legacy_source)
      ])

    File.mkdir_p!(Path.dirname(legacy_path))
    File.rename!(legacy_source, legacy_path)

    deep_source = ProcessOwnership.registry_path(deep_issue)

    deep_path =
      Path.join([
        workspace_root,
        "outer-workspace",
        "nested-workspace",
        ".symphony",
        "process-ownership",
        Path.basename(deep_source)
      ])

    File.mkdir_p!(Path.dirname(deep_path))
    File.rename!(deep_source, deep_path)

    test_pid = self()

    assert {:ok, 2} =
             ProcessOwnership.recover_stale_owned_sessions(fn ownership_ref ->
               send(test_pid, {:recovered, ownership_ref.session_name})
               :ok
             end)

    assert_receive {:recovered, first_session}
    assert_receive {:recovered, second_session}

    assert MapSet.new([first_session, second_session]) ==
             MapSet.new(["octo-canonical-recovery", "octo-legacy-recovery"])

    assert File.read!(deep_path) =~ ~s("state":"active")
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

  test "exact-marker cleanup terminates shell descendants without touching another run", %{
    issue: issue
  } do
    if File.dir?("/proc") do
      attrs = ownership_attrs("owned-marker-run", ProcessOwnership.holder_id())
      assert {:ok, ownership} = ProcessOwnership.acquire(issue, attrs)

      owned_env = ProcessOwnership.ownership_env(issue, ownership)
      other_env = List.keystore(owned_env, "SYMPHONY_ROLE_RUN_ID", 0, {"SYMPHONY_ROLE_RUN_ID", "other-run"})

      owned_port =
        start_owned_process(
          "trap '' TERM; while :; do sleep 300; done",
          owned_env
        )

      other_port = start_owned_process("exec sleep 300", other_env)
      {:os_pid, owned_shell_pid} = Port.info(owned_port, :os_pid)
      {:os_pid, other_run_pid} = Port.info(other_port, :os_pid)

      on_exit(fn ->
        signal_test_pid(owned_shell_pid, "KILL")
        signal_test_pid(other_run_pid, "KILL")
        close_port(owned_port)
        close_port(other_port)
      end)

      assert_eventually(fn ->
        case ProcessOwnership.status_for_issue(issue) do
          %{ownership_env_pids: pids} ->
            owned_shell_pid in pids and length(pids) >= 2

          _ ->
            false
        end
      end)

      beam_os_pid = String.to_integer(System.pid())
      refute beam_os_pid in ProcessOwnership.status_for_issue(issue).ownership_env_pids

      assert {:ok,
              %{
                term_pids: term_pids,
                kill_pids: kill_pids,
                live_after: 0
              }} =
               ProcessOwnership.terminate_owned_processes(issue, %{
                 holder: ownership.holder,
                 run_id: ownership.run_id,
                 workspace_path: ownership.workspace_path
               })

      assert owned_shell_pid in term_pids
      assert is_list(kill_pids)
      refute other_run_pid in kill_pids
      refute os_process_alive?(owned_shell_pid)
      assert os_process_alive?(other_run_pid)
      assert Process.alive?(self())

      assert {:ok, %{state: "cleaned", ownership_env_pids: []}} =
               ProcessOwnership.release(issue, %{
                 holder: ownership.holder,
                 run_id: ownership.run_id,
                 workspace_path: ownership.workspace_path
               })
    else
      assert true
    end
  end

  defp ownership_attrs(run_id, holder) do
    %{
      role: "implementer",
      run_id: run_id,
      holder: holder,
      workspace_path: nil
    }
  end

  defp start_owned_process(script, env) do
    Port.open({:spawn_executable, System.find_executable("bash")}, [
      :binary,
      :exit_status,
      args: [~c"-lc", String.to_charlist(script)],
      env:
        Enum.map(env, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)
    ])
  end

  defp signal_test_pid(pid, signal) do
    _ = System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  # 66-F1, admission side. `checked_process_table/0` is fail-closed for the
  # settlement evidence path, but the dispatch-admission gates resolved
  # liveness through readers that collapsed the identical typed failure to
  # "nothing is live". A degraded `ps`/`kill` therefore made a live owned run
  # look dead, so its record stopped blocking and a second run could be
  # started over it. Admission obeys the same invariant as settlement: a
  # process-table read that failed is never evidence that an owned run died.
  describe "dispatch admission on a degraded process table" do
    test "a live owned process still reads live when ps and kill are both broken", %{issue: issue} do
      {port, live_os_pid} = spawn_live_process()
      on_exit(fn -> close_port(port) end)

      attrs =
        ownership_attrs("run-admission-failopen", ProcessOwnership.holder_id())
        |> Map.put(:app_server_pid, live_os_pid)
        |> Map.put(:issue_id, issue.id)
        |> Map.put(:issue_identifier, issue.identifier)

      assert ProcessOwnership.owned_process_live?(attrs),
             "the healthy probe must see the live owned process (os_pid=#{live_os_pid})"

      assert with_broken_process_tools(fn -> ProcessOwnership.owned_process_live?(attrs) end),
             "a degraded ps/kill reported live owned os_pid=#{live_os_pid} as dead; " <>
               "admission would stop blocking and a second run could start over a live one"
    end

    test "an active record for a live holder keeps blocking acquisition when ps and kill are broken",
         %{issue: issue} do
      {port, live_os_pid} = spawn_live_process()
      on_exit(fn -> close_port(port) end)

      {:ok, _held} =
        ProcessOwnership.acquire(
          issue,
          ownership_attrs("run-admission-held", ProcessOwnership.holder_id())
          |> Map.put(:app_server_pid, live_os_pid)
        )

      assert ProcessOwnership.acquire(issue, ownership_attrs("run-admission-other", "other-holder")) ==
               {:error, :ownership_held}

      assert with_broken_process_tools(fn ->
               ProcessOwnership.acquire(issue, ownership_attrs("run-admission-other", "other-holder"))
             end) == {:error, :ownership_held},
             "a degraded ps/kill let a second run take over the live run's ownership record"
    end
  end

  defp spawn_live_process do
    sleep = System.find_executable("sleep")
    assert is_binary(sleep)
    port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: [~c"30"]])
    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    {port, os_pid}
  end

  defp start_external_lock_holder(
         issue,
         identity,
         workflow_path,
         ready_path,
         release_path,
         process_id_floor
       ) do
    code = """
    defmodule TUR878CrossVmGate do
      @behaviour SymphonyElixir.Runtime.ProcessOwnership.FileSystem

      @impl true
      def write(path, contents, modes) do
        File.write!(System.fetch_env!("TUR878_READY_PATH"), "ready\n")

        until_released(System.fetch_env!("TUR878_RELEASE_PATH"))
        SymphonyElixir.Runtime.ProcessOwnership.FileSystem.Real.write(path, contents, modes)
      end

      defp until_released(path) do
        if File.exists?(path) do
          :ok
        else
          Process.sleep(10)
          until_released(path)
        end
      end
    end

    SymphonyElixir.Workflow.set_workflow_file_path(System.fetch_env!("TUR878_WORKFLOW_PATH"))
    Application.put_env(:symphony_elixir, :process_ownership_file_system, TUR878CrossVmGate)
    floor = System.fetch_env!("TUR878_PROCESS_ID_FLOOR") |> String.to_integer()
    Enum.each(1..floor, fn _ -> spawn(fn -> :ok end) end)

    issue = %SymphonyElixir.Linear.Issue{
      id: System.fetch_env!("TUR878_ISSUE_ID"),
      identifier: System.fetch_env!("TUR878_ISSUE_IDENTIFIER"),
      state: "In Progress"
    }

    identity = %{
      holder: System.fetch_env!("TUR878_HOLDER"),
      run_id: System.fetch_env!("TUR878_RUN_ID"),
      workspace_path: System.fetch_env!("TUR878_WORKSPACE_PATH")
    }

    parent = self()

    spawn(fn ->
      send(parent, {:result, SymphonyElixir.Runtime.ProcessOwnership.verify_and_update(issue, identity, %{session_id: "cross-vm-held"})})
    end)

    receive do
      {:result, {:ok, _ownership}} -> System.halt(0)
      {:result, result} -> IO.puts(:stderr, inspect(result)); System.halt(1)
    after
      20_000 -> System.halt(2)
    end
    """

    args =
      ["--erl", "+S 1:1"] ++
        Enum.flat_map(test_ebin_paths(), &["-pa", &1]) ++ ["-e", code]

    env = [
      {"TUR878_WORKFLOW_PATH", workflow_path},
      {"TUR878_READY_PATH", ready_path},
      {"TUR878_RELEASE_PATH", release_path},
      {"TUR878_PROCESS_ID_FLOOR", Integer.to_string(process_id_floor)},
      {"TUR878_ISSUE_ID", issue.id},
      {"TUR878_ISSUE_IDENTIFIER", issue.identifier},
      {"TUR878_HOLDER", identity.holder},
      {"TUR878_RUN_ID", identity.run_id},
      {"TUR878_WORKSPACE_PATH", identity.workspace_path}
    ]

    Port.open({:spawn_executable, System.find_executable("elixir")}, [
      :binary,
      :exit_status,
      args: Enum.map(args, &String.to_charlist/1),
      env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
    ])
  end

  defp test_ebin_paths do
    Path.wildcard(Path.expand("_build/test/lib/*/ebin", File.cwd!()))
  end

  defp external_acquire_result(issue, workspace_path, workflow_path, owner_process) do
    code = """
    SymphonyElixir.Workflow.set_workflow_file_path(System.fetch_env!("TUR878_WORKFLOW_PATH"))

    issue = %SymphonyElixir.Linear.Issue{
      id: System.fetch_env!("TUR878_ISSUE_ID"),
      identifier: System.fetch_env!("TUR878_ISSUE_IDENTIFIER"),
      state: "In Progress"
    }

    attrs = %{
      role: "implementer",
      run_id: "must-not-steal-cross-vm-lock",
      holder: "replacement-holder",
      workspace_path: System.fetch_env!("TUR878_WORKSPACE_PATH")
    }

    owner_process =
      System.fetch_env!("TUR878_OWNER_PROCESS")
      |> String.to_charlist()
      |> :erlang.list_to_pid()

    if Process.alive?(owner_process), do: System.halt(4)

    case SymphonyElixir.Runtime.ProcessOwnership.acquire(issue, attrs) do
      {:error, :ownership_held} -> System.halt(0)
      result -> IO.puts(:stderr, inspect(result)); System.halt(3)
    end
    """

    args =
      ["--erl", "+S 1:1"] ++
        Enum.flat_map(test_ebin_paths(), &["-pa", &1]) ++ ["-e", code]

    System.cmd(System.find_executable("elixir"), args,
      stderr_to_stdout: true,
      env: [
        {"TUR878_WORKFLOW_PATH", workflow_path},
        {"TUR878_ISSUE_ID", issue.id},
        {"TUR878_ISSUE_IDENTIFIER", issue.identifier},
        {"TUR878_WORKSPACE_PATH", workspace_path},
        {"TUR878_OWNER_PROCESS", owner_process}
      ]
    )
  end

  # `ps` and `kill` are both resolved through PATH at call time, so shadowing
  # them is a seam-free way to break exactly the process-liveness machinery:
  # no production code path is aware of the test.
  defp with_broken_process_tools(fun) do
    shim_dir = Path.join(System.tmp_dir!(), "symphony-broken-proc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(shim_dir)
    previous_path = System.get_env("PATH")

    for name <- ["ps", "kill"] do
      path = Path.join(shim_dir, name)
      File.write!(path, "#!/bin/sh\nexit 1\n")
      File.chmod!(path, 0o755)
    end

    System.put_env("PATH", shim_dir <> ":" <> previous_path)

    try do
      fun.()
    after
      restore_env("PATH", previous_path)
      File.rm_rf(shim_dir)
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
