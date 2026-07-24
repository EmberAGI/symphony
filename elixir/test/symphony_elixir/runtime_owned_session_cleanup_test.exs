defmodule SymphonyElixir.RuntimeOwnedSessionCleanupTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  RED: the Orchestrator's monitored-task boundary must consume the run-owned
  cleanup capability on every terminal task outcome. The fake cleanup Adapter
  owns exactly one process, terminates only that process, and reports the
  bounded issue/session/PID evidence required by an operator canary.
  """

  alias SymphonyElixir.Linear.Issue

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

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: process_pid,
            ref: monitor_ref,
            identifier: "EMB-CLEANUP",
            issue: %Issue{
              id: issue_id,
              identifier: "EMB-CLEANUP",
              state: "In Progress",
              labels: []
            },
            run_id: "run-cleanup-#{label}",
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
end
