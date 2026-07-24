defmodule SymphonyElixir.ImplementerSupervisionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ImplementerDelegation

  defmodule CadenceReadTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, timeout_ms, %{owner: owner}) do
      reads = Process.get({__MODULE__, :reads}, 0) + 1
      Process.put({__MODULE__, :reads}, reads)
      send(owner, {:status_read, reads, timeout_ms})
      status = if reads < 3, do: "working", else: "done"
      {:ok, %{name: agent.name, agent_status: status, agent_session: %{value: "cadence-session"}}}
    end

    def await_agent(_session, _agent, _statuses, _timeout_ms, %{owner: owner}) do
      send(owner, :budget_length_wait_used)
      Process.sleep(:infinity)
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "CADENCE_COMPLETE"}}
  end

  test "a working turn is supervised by bounded-cadence typed status reads, not a budget-length wait" do
    Process.delete({CadenceReadTransport, :reads})

    session = %{
      transport: CadenceReadTransport,
      transport_context: %{owner: self()},
      contract: %{provider: "codex"},
      herdr_session: %{name: "octo-emb-1244-cadence"},
      orchestrator: %{name: "implementer_orchestrator", pane_id: "w1:p1"}
    }

    assert {:ok, %{response: "CADENCE_COMPLETE", agent_status: "done"}} =
             ImplementerDelegation.run_turn(
               session,
               "Complete a supervised assignment.",
               %{identifier: "EMB-1244"},
               turn_timeout_ms: 5_000,
               heartbeat_interval_ms: 1,
               status_read_timeout_ms: 250,
               on_message: fn message -> send(self(), {:runtime_message, message}) end
             )

    assert_receive {:status_read, 1, 250}
    assert_receive {:status_read, 2, 250}
    assert_receive {:status_read, 3, 250}
    refute_received :budget_length_wait_used

    assert_receive {:runtime_message, %{event: :turn_heartbeat, agent_status: "working"}}
    assert_receive {:runtime_message, %{event: :turn_completed, agent_status: "done"}}
  end
end
