defmodule SymphonyElixir.ImplementerWorkerAssignmentTest do
  use ExUnit.Case, async: true

  @moduledoc """
  RED: worker launch assignment and worker result must be correlated.

  Today `ImplementerDelegation` prepares one worker launcher at session start
  and then never observes what the orchestrator agent launched. A worker that
  never launched, died, returned nothing, timed out, or returned somebody
  else's result is invisible to Symphony: the orchestrator agent settles
  `idle`, `run_turn/4` returns `{:ok, ...}`, and the role run is reported as a
  normal completion.

  These tests pin the missing contract at the authorized seam
  (`ImplementerDelegation` plus its `Transport` Interface):

    * the transport exposes the session's worker assignments through a
      `worker_assignments(session_ref, context)` callback;
    * `run_turn/4` correlates each launched assignment with a result carrying
      the same `assignment_id` and surfaces the correlated pairs in its turn
      result; and
    * every uncorrelated assignment is a distinct typed failure, never an
      `{:ok, _}` turn.
  """

  alias SymphonyElixir.{ImplementationEffort, ImplementerDelegation}
  alias SymphonyElixir.Linear.Issue

  # One transport whose only variable is what the session reports back about
  # its worker assignments. Everything else is a settled, successful
  # orchestrator turn, so any failure below is attributable to the worker
  # assignment contract alone.
  defmodule AssignmentTransport do
    def default_server_snapshot(_context),
      do: {:ok, %{status: "running", version: "0.7.5", protocol: 17, socket: "/tmp/default.sock"}}

    def start_session(spec, _context) do
      {:ok,
       %{
         name: spec.name,
         socket: "/tmp/#{spec.name}/herdr.sock",
         runtime_root: "/tmp/#{spec.name}",
         workspace: spec.workspace
       }}
    end

    def prepare_worker(session, _spec, _context) do
      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}
    end

    def start_agent(_session, spec, _context),
      do: {:ok, %{name: spec.name, pane_id: "w1:p1", agent_status: "idle"}}

    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok,
       %{
         phase: :completed,
         agent: %{
           name: agent.name,
           agent_status: "idle",
           agent_session: %{value: "orchestrator-session"}
         }
       }}
    end

    def get_agent(_session, agent, _timeout_ms, _context),
      do: {:ok, %{name: agent.name, agent_status: "idle"}}

    def read_agent(_session, _agent, _opts, _context),
      do: {:ok, %{text: "orchestrator turn finished"}}

    def stop_session(_session, _context), do: :ok

    def worker_assignments(_session, %{assignments: assignments}), do: {:ok, assignments}

    def worker_assignments(_session, %{assignment_snapshots: snapshots}) do
      Agent.get_and_update(snapshots, fn
        [current, next | rest] -> {{:ok, current}, [next | rest]}
        [current] -> {{:ok, current}, [current]}
      end)
    end

    def worker_assignments(_session, _context), do: {:ok, []}
  end

  test "a launched worker assignment is correlated with the result carrying the same assignment id" do
    assignments = [
      %{
        assignment_id: "assign-correlated-1",
        status: :completed,
        result: %{
          assignment_id: "assign-correlated-1",
          status: "completed",
          summary: "bounded deliverable finished"
        }
      }
    ]

    assert {:ok, turn} = run_turn_with(assignments)

    assert [
             %{
               assignment_id: "assign-correlated-1",
               result: %{
                 assignment_id: "assign-correlated-1",
                 status: "completed",
                 summary: "bounded deliverable finished"
               }
             }
           ] = turn.worker_assignments
  end

  test "a direct-work turn with no assignment bypasses worker correlation cleanly" do
    assert {:ok, %{worker_assignments: []}} = run_turn_with([])
  end

  test "a worker result stamped with another assignment id is a typed mismatch, never an ok turn" do
    assignments = [
      %{
        assignment_id: "assign-expected",
        status: :completed,
        result: %{
          assignment_id: "assign-other",
          status: "completed",
          summary: "result from a different launch"
        }
      }
    ]

    assert {:error, {:implementer_worker_result_mismatch, %{assignment_id: "assign-expected", observed_assignment_id: "assign-other"}}} =
             run_turn_with(assignments)
  end

  test "a matching result id without completed result status is a typed failure" do
    assignments = [
      %{
        assignment_id: "assign-failed-result",
        status: :completed,
        result: %{assignment_id: "assign-failed-result", status: "failed"}
      }
    ]

    assert {:error,
            {:implementer_worker_result_failed,
             %{
               assignment_id: "assign-failed-result",
               result: %{assignment_id: "assign-failed-result", status: "failed"}
             }}} = run_turn_with(assignments)
  end

  test "a worker that never launched is a typed launch failure, never an ok turn" do
    assignments = [
      %{
        assignment_id: "assign-launch-failed",
        status: :launch_failed,
        reason: {:worker_launch_failed, :wrapper_acknowledgement_missing}
      }
    ]

    assert {:error,
            {:implementer_worker_launch_failed,
             %{
               assignment_id: "assign-launch-failed",
               reason: {:worker_launch_failed, :wrapper_acknowledgement_missing}
             }}} = run_turn_with(assignments)
  end

  test "a worker that died before returning a result is a typed worker death, never an ok turn" do
    assignments = [
      %{
        assignment_id: "assign-died",
        status: :died,
        reason: {:herdr_agent_closed, "implementer_worker"}
      }
    ]

    assert {:error, {:implementer_worker_died, %{assignment_id: "assign-died", reason: {:herdr_agent_closed, "implementer_worker"}}}} =
             run_turn_with(assignments)
  end

  test "a launched worker with no result at turn settle is a typed missing result, never an ok turn" do
    assignments = [%{assignment_id: "assign-no-result", status: :launched}]

    assert {:error, {:implementer_worker_result_missing, %{assignment_id: "assign-no-result"}}} =
             run_turn_with(assignments)
  end

  test "a worker whose result never arrived in its budget is a typed timeout, never an ok turn" do
    assignments = [%{assignment_id: "assign-timed-out", status: :timed_out}]

    assert {:error, {:implementer_worker_timed_out, %{assignment_id: "assign-timed-out"}}} =
             run_turn_with(assignments)
  end

  test "a worker still making progress after the orchestrator settles remains alive until its result correlates" do
    {:ok, snapshots} =
      Agent.start_link(fn ->
        [
          [%{assignment_id: "assign-delayed", status: :working, activity_revision: {2, 2}}],
          [%{assignment_id: "assign-delayed", status: :working, activity_revision: {2, 2}}],
          [%{assignment_id: "assign-delayed", status: :working, activity_revision: {3, 2}}],
          [
            %{
              assignment_id: "assign-delayed",
              status: :completed,
              result: %{assignment_id: "assign-delayed", status: "completed"}
            }
          ]
        ]
      end)

    assert {:ok, %{worker_assignments: [%{assignment_id: "assign-delayed", status: :completed}]}} =
             run_turn_with_context(
               %{assignment_snapshots: snapshots},
               worker_result_poll_interval_ms: 1,
               turn_timeout_ms: 100,
               on_message: fn message -> send(self(), {:runtime_message, message}) end
             )

    assert_receive {:runtime_message,
                    %{
                      event: :turn_heartbeat,
                      agent: "implementer_worker",
                      agent_status: "working"
                    }}

    assert_receive {:runtime_message,
                    %{
                      event: :turn_heartbeat,
                      agent: "implementer_worker",
                      agent_status: "working"
                    }}

    refute_receive {:runtime_message,
                    %{
                      event: :turn_heartbeat,
                      agent: "implementer_worker",
                      agent_status: "working"
                    }}
  end

  test "a worker still working at the turn hard deadline is a typed timeout" do
    {:ok, snapshots} =
      Agent.start_link(fn ->
        [[%{assignment_id: "assign-still-working", status: :working, activity_revision: {2, 2}}]]
      end)

    assert {:error, {:implementer_worker_timed_out, %{assignment_id: "assign-still-working"}}} =
             run_turn_with_context(
               %{assignment_snapshots: snapshots},
               worker_result_poll_interval_ms: 1,
               turn_timeout_ms: 10
             )
  end

  defp run_turn_with(assignments) do
    run_turn_with_context(%{assignments: assignments}, [])
  end

  defp run_turn_with_context(context, opts) do
    assert {:ok, session} =
             ImplementerDelegation.start_session(
               "/tmp/symphony-worker-assignment-ws",
               valid_contract(),
               issue_identifier: "EMB-HOTFIX",
               run_id: "run-worker-assignment",
               transport: AssignmentTransport,
               transport_context: context
             )

    ImplementerDelegation.run_turn(session, "do the bounded implementer work", issue(), opts)
  end

  defp valid_contract do
    assert {:ok, contract} = ImplementationEffort.runtime_profile_for_issue(:codex, issue(), "implementer")
    contract
  end

  defp issue do
    %Issue{
      id: "issue-worker-assignment",
      identifier: "EMB-HOTFIX",
      title: "Correlate worker launch assignment and result",
      state: "In Progress",
      labels: ["implementation-effort:moderate"]
    }
  end
end
