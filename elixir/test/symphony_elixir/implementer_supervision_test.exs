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

  defmodule BlockedTransport do
    def begin_turn(_session, agent, prompt, _timeout_ms, %{owner: owner}) do
      send(owner, {:prompt_submitted, prompt})
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, %{owner: owner}) do
      send(owner, :status_read)
      {:ok, %{name: agent.name, agent_status: "blocked", agent_session: nil}}
    end

    def read_agent(_session, _agent, %{source: source}, %{owner: owner}) do
      send(owner, {:pane_read, source})
      {:ok, %{text: "Allow this tool? [y/n]"}}
    end
  end

  test "a blocked agent is preserved and surfaced as a typed outcome without auto-answering" do
    session = supervised_session(BlockedTransport)

    assert {:error, {:implementer_agent_blocked, evidence}} =
             ImplementerDelegation.run_turn(session, "Do bounded work.", %{}, supervision_opts())

    assert evidence.agent_status == "blocked"
    assert {:ok, checkpoint} = evidence.checkpoint
    assert checkpoint.pane_tail == "Allow this tool? [y/n]"
    assert checkpoint.shutdown_reason == :blocked
    assert checkpoint.herdr_session == "octo-emb-1244-supervised"

    assert_receive {:prompt_submitted, "Do bounded work."}
    refute_receive {:prompt_submitted, _other}
  end

  defmodule TransientUnknownTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      reads = Process.get({__MODULE__, :reads}, 0) + 1
      Process.put({__MODULE__, :reads}, reads)
      status = if reads < 3, do: "unknown", else: "done"
      {:ok, %{name: agent.name, agent_status: status, agent_session: %{value: "recovered"}}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "UNKNOWN_RECOVERED"}}
  end

  test "transient unknown statuses are retried within the bound and can still complete" do
    Process.delete({TransientUnknownTransport, :reads})
    session = supervised_session(TransientUnknownTransport)

    assert {:ok, %{response: "UNKNOWN_RECOVERED", agent_status: "done"}} =
             ImplementerDelegation.run_turn(session, "Do bounded work.", %{}, supervision_opts())
  end

  defmodule PersistentUnknownTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, %{owner: owner}) do
      send(owner, :status_read)
      {:ok, %{name: agent.name, agent_status: "unknown", agent_session: nil}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "pane still renders a TUI"}}
  end

  test "persistent unknown escalates as a typed outcome with independent pane evidence" do
    session = supervised_session(PersistentUnknownTransport)

    assert {:error, {:implementer_agent_unobservable, evidence}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               supervision_opts(max_indeterminate_reads: 3)
             )

    assert {:ok, checkpoint} = evidence.checkpoint
    assert checkpoint.pane_tail == "pane still renders a TUI"
    assert checkpoint.shutdown_reason == :persistent_unknown

    reads = count_received(:status_read)
    assert reads == 3
  end

  defmodule FailingReadTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, %{owner: owner}) do
      send(owner, :status_read)
      {:error, {:herdr_agent_get_timeout, agent.name}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "pane evidence"}}
  end

  test "persistent status-read failures exhaust the bounded retries into a typed escalation" do
    session = supervised_session(FailingReadTransport)

    assert {:error, {:implementer_status_reads_failed, evidence}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               supervision_opts(max_indeterminate_reads: 2)
             )

    assert evidence.last_error == {:herdr_agent_get_timeout, "implementer_orchestrator"}
    assert {:ok, %{shutdown_reason: :status_reads_failed}} = evidence.checkpoint
    assert count_received(:status_read) == 2
  end

  defmodule ClosedAgentTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context), do: {:error, {:herdr_agent_closed, agent.name}}
  end

  test "a closed agent remains a typed closed-agent failure without retry" do
    session = supervised_session(ClosedAgentTransport)

    assert {:error, {:herdr_agent_closed, "implementer_orchestrator"}} =
             ImplementerDelegation.run_turn(session, "Do bounded work.", %{}, supervision_opts())
  end

  defmodule ProgressingWorkingTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      reads = Process.get({__MODULE__, :reads}, 0) + 1
      Process.put({__MODULE__, :reads}, reads)
      status = if reads < 6, do: "working", else: "done"
      {:ok, %{name: agent.name, agent_status: status, agent_session: nil}}
    end

    def await_agent(_session, _agent, _statuses, _timeout_ms, %{owner: owner}) do
      send(owner, :recovery_probe)
      {:error, {:herdr_agent_status_timeout, "implementer_orchestrator", ["idle", "done", "blocked"]}}
    end

    def read_agent(_session, _agent, _opts, _context) do
      {:ok, %{text: "output line #{Process.get({__MODULE__, :reads}, 0)}"}}
    end
  end

  test "an observably progressing working agent is never treated as stale by wall-clock alone" do
    Process.delete({ProgressingWorkingTransport, :reads})
    session = supervised_session(ProgressingWorkingTransport)

    assert {:ok, %{agent_status: "done"}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               supervision_opts(stale_working_ms: 25, heartbeat_interval_ms: 5)
             )

    refute_received :recovery_probe
  end

  defmodule StaleThenRecoveredTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      {:ok, %{name: agent.name, agent_status: "working", agent_session: nil}}
    end

    def await_agent(_session, agent, ["idle", "done", "blocked"], timeout_ms, %{owner: owner}) do
      send(owner, {:recovery_probe, timeout_ms})
      {:ok, %{name: agent.name, agent_status: "done", agent_session: %{value: "recovered-after-stall"}}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "frozen pane"}}
  end

  test "a stale working agent gets bounded recovery and can still complete" do
    session = supervised_session(StaleThenRecoveredTransport)

    assert {:ok, %{agent_status: "done", session_id: "recovered-after-stall"}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               supervision_opts(stale_working_ms: 5, heartbeat_interval_ms: 2)
             )

    assert_receive {:recovery_probe, 250}
  end

  defmodule NeverRecoversTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      {:ok, %{name: agent.name, agent_status: "working", agent_session: nil}}
    end

    def await_agent(_session, agent, _statuses, _timeout_ms, %{owner: owner}) do
      send(owner, :recovery_probe)
      {:error, {:herdr_agent_status_timeout, agent.name, ["idle", "done", "blocked"]}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "frozen pane"}}
  end

  test "failed stale-working recovery exhausts its bound into a typed stalled escalation" do
    session = supervised_session(NeverRecoversTransport)

    assert {:error, {:implementer_agent_stalled, evidence}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               supervision_opts(stale_working_ms: 5, heartbeat_interval_ms: 2, max_recovery_attempts: 2)
             )

    assert [%{result: {:failed, _}}, %{result: {:failed, _}}] = evidence.recovery_history
    assert {:ok, %{shutdown_reason: :stale_working, pane_tail: "frozen pane"}} = evidence.checkpoint
    assert count_received(:recovery_probe) == 2
  end

  defp supervised_session(transport) do
    %{
      transport: transport,
      transport_context: %{owner: self()},
      contract: %{provider: "codex"},
      herdr_session: %{name: "octo-emb-1244-supervised", runtime_root: "/tmp/octo-emb-1244-supervised"},
      orchestrator: %{name: "implementer_orchestrator", pane_id: "w1:p1"}
    }
  end

  defp supervision_opts(extra \\ []) do
    Keyword.merge(
      [
        turn_timeout_ms: 5_000,
        heartbeat_interval_ms: 1,
        status_read_timeout_ms: 250
      ],
      extra
    )
  end

  defp count_received(message, count \\ 0) do
    receive do
      ^message -> count_received(message, count + 1)
    after
      0 -> count
    end
  end
end
