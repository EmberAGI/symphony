defmodule SymphonyElixir.RuntimeOwnedSessionCleanupTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  RED: the Orchestrator's monitored-task boundary must consume the run-owned
  cleanup capability on every terminal task outcome. The fake cleanup Adapter
  owns exactly one process, terminates only that process, and reports the
  bounded issue/session/PID evidence required by an operator canary.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Runtime.ProcessOwnership

  defmodule ProcessCleanup do
    def cleanup_owned_session(%{
          owner: owner,
          issue_id: issue_id,
          session_name: session_name,
          process_pid: process_pid
        }) do
      os_pid =
        case :erlang.process_info(process_pid, :registered_name) do
          nil -> nil
          _ -> :erlang.phash2(process_pid)
        end

      Process.exit(process_pid, :kill)
      await_dead(process_pid, 50)

      send(
        owner,
        {:owned_session_cleanup_verified,
         %{
           issue_id: issue_id,
           session_name: session_name,
           owned_process_id: os_pid,
           live_after: Process.alive?(process_pid)
         }}
      )

      :ok
    end

    defp await_dead(_pid, 0), do: :ok

    defp await_dead(pid, attempts) do
      if Process.alive?(pid) do
        Process.sleep(1)
        await_dead(pid, attempts - 1)
      else
        :ok
      end
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok
  end

  test "success, failure, and timeout all clean and verify the exact owned runtime process" do
    for {label, reason} <- [
          {"success", :normal},
          {"failure", {:agent_runtime_failed, {:implementer_worker_result_missing, %{assignment_id: "a"}}}},
          {"timeout", {:agent_runtime_failed, {:implementer_worker_timed_out, %{assignment_id: "a"}}}}
        ] do
      issue_id = "issue-cleanup-#{label}"
      session_name = "octo-cleanup-#{label}"
      process_pid = spawn(fn -> Process.sleep(:infinity) end)
      monitor_ref = make_ref()

      issue = %Issue{
        id: issue_id,
        identifier: "EMB-CLEANUP-#{label}",
        state: "In Progress",
        labels: []
      }

      assert {:ok, process_ownership} =
               ProcessOwnership.acquire(issue, %{
                 role: ProcessOwnership.current_role(),
                 run_id: "run-cleanup-#{label}",
                 holder: ProcessOwnership.holder_id()
               })

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: process_pid,
            ref: monitor_ref,
            identifier: issue.identifier,
            issue: issue,
            run_id: "run-cleanup-#{label}",
            workspace_path: process_ownership.workspace_path,
            process_ownership: process_ownership,
            owned_session_ref: %{
              cleanup_module: ProcessCleanup,
              owner: self(),
              issue_id: issue_id,
              session_name: session_name,
              process_pid: process_pid
            },
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        failure_observations: %{},
        completed: MapSet.new(),
        codex_totals: %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: 0
        }
      }

      assert {:noreply, _updated_state} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, process_pid, reason},
                 state
               )

      assert_receive {:owned_session_cleanup_verified,
                      %{
                        issue_id: ^issue_id,
                        session_name: ^session_name,
                        owned_process_id: owned_process_id,
                        live_after: false
                      }},
                     1_000

      assert is_integer(owned_process_id)
      refute Process.alive?(process_pid)
    end
  end

  # EMB-1259: a missing or malformed ownership record at settlement time is
  # not a cleanup failure the runtime inflicts on itself. Settlement captures
  # its own owned-PID snapshot before teardown and verifies liveness against
  # that snapshot afterwards, so a physically clean teardown settles clean —
  # typed cleanup failure stays reserved for genuine survivors or truly
  # unwritable evidence.
  test "missing or malformed scoped ownership records do not fabricate cleanup failures on clean teardown" do
    for {label, prepare} <- [
          {"missing", fn _issue -> :ok end},
          {"malformed",
           fn issue ->
             path = ProcessOwnership.registry_path(issue)
             File.mkdir_p!(Path.dirname(path))
             File.write!(path, "{}\n")
           end}
        ] do
      issue_id = "issue-cleanup-unavailable-#{label}"
      session_name = "octo-cleanup-#{label}"
      process_pid = spawn(fn -> Process.sleep(:infinity) end)
      monitor_ref = make_ref()

      issue = %Issue{
        id: issue_id,
        identifier: "EMB-CLEANUP-UNAVAILABLE-#{label}",
        state: "In Progress",
        labels: []
      }

      prepare.(issue)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: process_pid,
            ref: monitor_ref,
            identifier: issue.identifier,
            issue: issue,
            run_id: "run-cleanup-unavailable-#{label}",
            owned_session_ref: %{
              cleanup_module: ProcessCleanup,
              owner: self(),
              issue_id: issue_id,
              session_name: session_name,
              process_pid: process_pid
            },
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        failure_observations: %{},
        completed: MapSet.new(),
        codex_totals: %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: 0
        }
      }

      # Terminal settlement is off the serial path (EMB-1260): the DOWN handler
      # dispatches it and finalizes on the settlement-result message. Drive that
      # message through handle_info so this direct-call test still observes the
      # FINALIZED state — asserting on the dispatched state would leave the
      # no-fabricated-failure check below vacuous. Assertions unchanged.
      updated_state = drive_down_settlement(state, monitor_ref, process_pid, :normal)

      assert_receive {:owned_session_cleanup_verified,
                      %{
                        issue_id: ^issue_id,
                        session_name: ^session_name,
                        live_after: false
                      }},
                     1_000

      refute Process.alive?(process_pid)

      # The clean teardown keeps its normal completion: the settlement must
      # not rewrite the exit into a typed owned-session cleanup failure just
      # because its own record re-read found nothing.
      #
      # A `:normal` exit always schedules the active-state continuation check
      # and that retry carries no error at all. A settlement that rewrote the
      # exit routes through the retryable branch instead, whose retry carries
      # "agent exited: ... owned_session_cleanup_failed ...". Asserting the
      # retry exists and its error is nil therefore has no arm that can pass
      # by absence.
      retry = updated_state.retry_attempts[issue_id]

      assert is_map(retry),
             "a clean :normal teardown must still schedule its active-state continuation check, " <>
               "got retry_attempts=#{inspect(updated_state.retry_attempts)}"

      assert is_nil(retry.error),
             "settlement rewrote a physically clean teardown into a typed failure: #{inspect(retry.error)}"

      refute match?(%{state: "quarantined"}, ProcessOwnership.status_for_issue(issue)),
             "a physically clean teardown must not leave a quarantined ownership record " <>
               "(#{inspect(ProcessOwnership.status_for_issue(issue))})"
    end
  end

  # Drive an off-loop terminal settlement (EMB-1260) to completion for a
  # direct-handle_info test: dispatch the DOWN, then feed the settlement task's
  # {:settlement_result, ...} message through handle_info as a live loop would,
  # returning the finalized state.
  defp drive_down_settlement(state, ref, pid, reason) do
    assert {:noreply, dispatched} =
             Orchestrator.handle_info({:DOWN, ref, :process, pid, reason}, state)

    receive do
      {:settlement_result, _token, _result} = message ->
        assert {:noreply, finalized} = Orchestrator.handle_info(message, dispatched)
        finalized
    after
      5_000 -> flunk("terminal settlement did not report its result in time")
    end
  end
end
