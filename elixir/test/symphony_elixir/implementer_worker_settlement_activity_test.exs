defmodule SymphonyElixir.ImplementerWorkerSettlementActivityTest do
  @moduledoc """
  The orchestrator run clock advances only on runtime messages. When the
  orchestrator settles its own turn first and only the delegated worker is still
  working, the delegation turn keeps the run alive by emitting `:turn_heartbeat`
  while the worker's activity fingerprint advances.

  Herdr's `activity_revision` is pane/state bookkeeping: live evidence shows it
  does not move while a Claude Code worker is doing real work. So the settlement
  fingerprint must also read the worker's real-work progress cursor, and a
  provider without that evidence (`{:error, :not_applicable}`) must keep the
  `activity_revision`-only behavior exactly.
  """
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ImplementationEffort, ImplementerDelegation}
  alias SymphonyElixir.Linear.Issue

  defmodule WorkerProgressTransport do
    @moduledoc false

    def default_server_snapshot(_context) do
      {:ok, %{status: "running", version: "0.8.2", protocol: 20, socket: "/tmp/operator-default/herdr.sock"}}
    end

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
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")
       |> Map.put(:worker, %{name: "implementer_worker", pane_id: "w1:p2", provider: "claude_code"})}
    end

    def start_agent(_session, spec, _context),
      do: {:ok, %{name: spec.name, pane_id: "w1:p1", agent_status: "idle"}}

    # The orchestrator settles immediately: from here on the only live evidence
    # of the run is the delegated worker.
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

    def worker_assignments(_session, %{assignment_snapshots: snapshots}) do
      Agent.get_and_update(snapshots, fn
        [current, next | rest] -> {{:ok, current}, [next | rest]}
        [current] -> {{:ok, current}, [current]}
      end)
    end

    def progress_cursor(_session, %{provider: "claude_code"}, %{worker_cursor: cursor}) do
      {:ok, {:provider_transcript, Agent.get_and_update(cursor, fn {items, step} -> {items, {items + step, step}} end)}}
    end

    def progress_cursor(_session, _agent, _context), do: {:error, :not_applicable}
  end

  @working %{assignment_id: "assign-real-work", status: :working, activity_revision: {2, 2}}
  @completed %{
    assignment_id: "assign-real-work",
    status: :completed,
    result: %{assignment_id: "assign-real-work", status: "completed"}
  }

  test "an idle orchestrator keeps beating while its Claude Code worker does real work with a frozen activity revision" do
    assert {:ok, %{worker_assignments: [%{assignment_id: "assign-real-work", status: :completed}]}} =
             run_turn_with(
               [[@working], [@working], [@working], [@completed]],
               {0, 3},
               worker_result_poll_interval_ms: 1,
               turn_timeout_ms: 500,
               on_message: fn message -> send(self(), {:runtime_message, message}) end
             )

    assert_receive {:runtime_message, %{event: :turn_heartbeat, agent: "implementer_worker", agent_status: "working"}}
    assert_receive {:runtime_message, %{event: :turn_heartbeat, agent: "implementer_worker", agent_status: "working"}}
  end

  test "a Claude Code worker with no real work stops beating after the first observation" do
    assert {:ok, %{worker_assignments: [%{assignment_id: "assign-real-work", status: :completed}]}} =
             run_turn_with(
               [[@working], [@working], [@working], [@completed]],
               {41, 0},
               worker_result_poll_interval_ms: 1,
               turn_timeout_ms: 500,
               on_message: fn message -> send(self(), {:runtime_message, message}) end
             )

    assert_receive {:runtime_message, %{event: :turn_heartbeat, agent: "implementer_worker", agent_status: "working"}}

    refute_receive {:runtime_message, %{event: :turn_heartbeat, agent: "implementer_worker", agent_status: "working"}}
  end

  test "a Claude Code worker still working at the turn hard deadline is still a typed timeout" do
    assert {:error, {:implementer_worker_timed_out, %{assignment_id: "assign-real-work"}}} =
             run_turn_with(
               [[@working]],
               {0, 3},
               worker_result_poll_interval_ms: 1,
               turn_timeout_ms: 10
             )
  end

  defp run_turn_with(assignment_snapshots, cursor, opts) do
    {:ok, snapshots} = Agent.start_link(fn -> assignment_snapshots end)
    {:ok, worker_cursor} = Agent.start_link(fn -> cursor end)

    context = %{assignment_snapshots: snapshots, worker_cursor: worker_cursor}

    assert {:ok, session} =
             ImplementerDelegation.start_session(
               "/tmp/symphony-worker-settlement-activity-ws",
               valid_contract(),
               issue_identifier: "EMB-HOTFIX",
               run_id: "run-worker-settlement-activity",
               transport: WorkerProgressTransport,
               transport_context: context
             )

    ImplementerDelegation.run_turn(session, "do the bounded implementer work", issue(), opts)
  end

  defp valid_contract do
    assert {:ok, contract} = ImplementationEffort.runtime_profile_for_issue(:codex, :claude_code, issue(), "implementer")
    contract
  end

  defp issue do
    %Issue{
      id: "issue-worker-settlement-activity",
      identifier: "EMB-HOTFIX",
      title: "Advance the run clock from worker real work",
      state: "In Progress",
      labels: ["implementation-effort:moderate"]
    }
  end
end
