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

  test "the production status-read default accommodates provider continuation scheduling" do
    Process.delete({CadenceReadTransport, :reads})

    session = %{
      transport: CadenceReadTransport,
      transport_context: %{owner: self()},
      contract: %{provider: "codex"},
      herdr_session: %{name: "octo-emb-1346-continuation"},
      orchestrator: %{name: "implementer_orchestrator", pane_id: "w1:p1"}
    }

    assert {:ok, %{response: "CADENCE_COMPLETE", agent_status: "done"}} =
             ImplementerDelegation.run_turn(
               session,
               "Continue the existing provider session.",
               %{identifier: "EMB-1346"},
               turn_timeout_ms: 120_000,
               heartbeat_interval_ms: 1
             )

    assert_receive {:status_read, 1, 60_000}
    assert_receive {:status_read, 2, 60_000}
    assert_receive {:status_read, 3, 60_000}
    refute_received :budget_length_wait_used
  end

  defmodule BudgetCappedReadTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, timeout_ms, %{owner: owner}) do
      send(owner, {:status_read_budget, timeout_ms})
      {:ok, %{name: agent.name, agent_status: "working", agent_session: %{value: "budget-capped"}}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "provider remains working"}}
  end

  test "the status read cannot extend the supervision hard budget" do
    session = %{
      transport: BudgetCappedReadTransport,
      transport_context: %{owner: self()},
      contract: %{provider: "codex"},
      herdr_session: %{name: "octo-emb-1346-budget", runtime_root: "/tmp/octo-emb-1346-budget"},
      orchestrator: %{name: "implementer_orchestrator", pane_id: "w1:p1"}
    }

    assert {:error, {:implementer_hard_budget_exhausted, evidence}} =
             ImplementerDelegation.run_turn(
               session,
               "Continue only inside the remaining turn budget.",
               %{identifier: "EMB-1346"},
               turn_timeout_ms: 100,
               heartbeat_interval_ms: 1_000
             )

    assert {:ok, _checkpoint} = evidence.checkpoint
    assert_receive {:status_read_budget, read_timeout_ms}
    assert read_timeout_ms > 0
    assert read_timeout_ms <= 100
    refute_receive {:status_read_budget, _another_timeout}, 20
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

    def read_agent(_session, _agent, _opts, _context), do: {:error, :pane_gone}
  end

  test "a closed agent stays typed without retry, and its failed checkpoint blocks destruction" do
    session = supervised_session(ClosedAgentTransport)

    assert {:error, {:herdr_agent_closed, "implementer_orchestrator", evidence}} =
             ImplementerDelegation.run_turn(session, "Do bounded work.", %{}, supervision_opts())

    assert {:error, {:implementer_checkpoint_failed, failure}} = evidence.checkpoint
    assert failure.destructive_shutdown_blocked == true
    assert failure.shutdown_reason == :agent_closed
  end

  defmodule ProtocolViolationTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      {:ok, %{name: agent.name, agent_status: "rebooting", agent_session: nil}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "pane before violation"}}
  end

  test "an out-of-enum status halts typed with observable evidence checkpointed first" do
    session = supervised_session(ProtocolViolationTransport)

    assert {:error, {:unexpected_herdr_agent_status, "rebooting", evidence}} =
             ImplementerDelegation.run_turn(session, "Do bounded work.", %{}, supervision_opts())

    assert {:ok, checkpoint} = evidence.checkpoint
    assert checkpoint.pane_tail == "pane before violation"
    assert checkpoint.shutdown_reason == :status_protocol_violation
  end

  defmodule ProgressingWorkingTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      reads = Process.get({__MODULE__, :reads}, 0) + 1
      Process.put({__MODULE__, :reads}, reads)
      status = if reads < 6, do: "working", else: "done"
      {:ok, %{name: agent.name, agent_status: status, agent_session: %{value: "progress-session"}}}
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

  defmodule CheckpointFailsTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      {:ok, %{name: agent.name, agent_status: "working", agent_session: nil}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:error, :pane_unreadable}
  end

  test "a hard-budget checkpoint failure is typed and blocks destructive shutdown" do
    session = supervised_session(CheckpointFailsTransport)

    assert {:error, {:implementer_checkpoint_failed, failure}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               supervision_opts(turn_timeout_ms: 30, heartbeat_interval_ms: 5)
             )

    assert failure.destructive_shutdown_blocked == true
    assert failure.shutdown_reason == :hard_budget_exhausted
    assert failure.reason == :pane_unreadable
  end

  defmodule PromptTransitionTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", revision: 7, agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      reads = Process.get({__MODULE__, :reads}, 0) + 1
      Process.put({__MODULE__, :reads}, reads)

      if reads < 3 do
        {:ok, %{name: agent.name, agent_status: "idle", revision: 7, agent_session: nil}}
      else
        {:ok, %{name: agent.name, agent_status: "done", revision: 8, agent_session: %{value: "post-transition"}}}
      end
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "TRANSITION_COMPLETE"}}
  end

  test "an unrevised idle read during the prompt transition window is not treated as completion" do
    Process.delete({PromptTransitionTransport, :reads})
    session = supervised_session(PromptTransitionTransport)

    assert {:ok, %{agent_status: "done", session_id: "post-transition"}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               supervision_opts(settle_window_ms: 10_000)
             )

    assert Process.get({PromptTransitionTransport, :reads}) == 3
  end

  defmodule ConcurrentReadsTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      Process.sleep(5)
      reads = :counters.add(counter(), 1, 1) || :counters.get(counter(), 1)
      _ = reads
      status = if :counters.get(counter(), 1) < 4, do: "working", else: "done"
      {:ok, %{name: agent.name, agent_status: status, agent_session: %{value: "concurrent"}}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "CONCURRENT_OK"}}

    def counter do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil ->
          counter = :counters.new(1, [:atomics])
          :persistent_term.put({__MODULE__, :counter}, counter)
          counter

        counter ->
          counter
      end
    end
  end

  test "supervised status reads tolerate concurrent status commands against the same agent" do
    :persistent_term.erase({ConcurrentReadsTransport, :counter})
    session = supervised_session(ConcurrentReadsTransport)

    turn =
      Task.async(fn ->
        ImplementerDelegation.run_turn(session, "Do bounded work.", %{}, supervision_opts())
      end)

    concurrent_reads =
      for _index <- 1..4 do
        Task.async(fn ->
          ConcurrentReadsTransport.get_agent(session.herdr_session, session.orchestrator, 250, %{})
        end)
      end

    assert {:ok, %{response: "CONCURRENT_OK", agent_status: "done"}} = Task.await(turn, 5_000)

    for read <- Task.await_many(concurrent_reads, 5_000) do
      assert {:ok, %{agent_status: status}} = read
      assert status in ["working", "done"]
    end
  end

  defmodule DefaultSettleTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", revision: 4, agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      reads = Process.get({__MODULE__, :reads}, 0) + 1
      Process.put({__MODULE__, :reads}, reads)

      if reads < 3 do
        {:ok, %{name: agent.name, agent_status: "idle", revision: 4, agent_session: nil}}
      else
        {:ok, %{name: agent.name, agent_status: "done", revision: 5, agent_session: %{value: "default-settled"}}}
      end
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "DEFAULT_SETTLE_COMPLETE"}}
  end

  test "the production default settle window treats same-revision idle as transitional" do
    Process.delete({DefaultSettleTransport, :reads})
    session = supervised_session(DefaultSettleTransport)

    # No settle_window_ms option: the default run_turn behavior must already
    # cover Herdr's 5000 ms prompt-effect window.
    assert {:ok, %{agent_status: "done", session_id: "default-settled"}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               turn_timeout_ms: 5_000,
               heartbeat_interval_ms: 1,
               status_read_timeout_ms: 250
             )

    assert Process.get({DefaultSettleTransport, :reads}) == 3
  end

  defmodule SettlePauseTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", revision: 4, agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      reads = Process.get({__MODULE__, :reads}, 0) + 1
      Process.put({__MODULE__, :reads}, reads)

      if reads < 2 do
        {:ok, %{name: agent.name, agent_status: "idle", revision: 4, agent_session: nil}}
      else
        {:ok, %{name: agent.name, agent_status: "done", revision: 5, agent_session: %{value: "settle-paused"}}}
      end
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "SETTLE_PAUSE_COMPLETE"}}
  end

  test "a transitional idle read pauses only to the settle deadline, not a full heartbeat interval" do
    Process.delete({SettlePauseTransport, :reads})
    session = supervised_session(SettlePauseTransport)
    started = System.monotonic_time(:millisecond)

    assert {:ok, %{agent_status: "done", session_id: "settle-paused"}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               turn_timeout_ms: 60_000,
               heartbeat_interval_ms: 30_000,
               status_read_timeout_ms: 250,
               settle_window_ms: 200
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started

    # The only nearer deadline is the 200 ms settle window: the pause after the
    # transitional read must be bounded by it, never by the 30 s heartbeat.
    assert elapsed_ms < 2_000,
           "transitional pause exceeded the settle deadline: took #{elapsed_ms}ms"
  end

  describe "pure supervision step" do
    alias SymphonyElixir.ImplementerDelegation.Supervision

    test "step/3 is idempotent: identical state, observation, and clock yield identical results" do
      state = Supervision.new(%{hard_budget_ms: 1_000, max_indeterminate_reads: 3}, 0)
      observation = {:ok, %{agent_status: "unknown"}}

      assert Supervision.step(state, observation, 10) == Supervision.step(state, observation, 10)

      {_directive, next} = Supervision.step(state, observation, 10)
      assert Supervision.step(next, observation, 20) == Supervision.step(next, observation, 20)
    end

    test "indeterminate reads halt exactly at the configured bound" do
      state = Supervision.new(%{hard_budget_ms: 1_000, max_indeterminate_reads: 2}, 0)

      {directive_one, state} = Supervision.step(state, {:ok, %{agent_status: "unknown"}}, 1)
      assert directive_one == :continue

      {directive_two, _state} = Supervision.step(state, {:ok, %{agent_status: "unknown"}}, 2)
      assert directive_two == {:halt, :persistent_unknown}
    end

    test "the hard budget halts regardless of the observation" do
      state = Supervision.new(%{hard_budget_ms: 100}, 0)

      assert {{:halt, :hard_budget_exhausted}, _state} =
               Supervision.step(state, {:ok, %{agent_status: "done"}}, 100)
    end

    test "an out-of-enum status is a typed protocol halt, never coerced or retried" do
      state = Supervision.new(%{hard_budget_ms: 1_000}, 0)

      assert {{:halt, {:protocol, {:unexpected_herdr_agent_status, "rebooting"}}}, _state} =
               Supervision.step(state, {:ok, %{agent_status: "rebooting"}}, 1)
    end
  end

  defmodule IncompatibleStatusReadTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, _agent, _timeout_ms, %{owner: owner}) do
      send(owner, :status_read)

      {:error, {:incompatible_herdr_runtime, %{error_code: "unrecognized_agent_status", actual_status: "rebooting"}}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "pane before protocol failure"}}
  end

  test "an incompatible-runtime status read halts immediately with a checkpoint, never indeterminate retry" do
    session = supervised_session(IncompatibleStatusReadTransport)

    assert {:error, {:incompatible_herdr_runtime, details, evidence}} =
             ImplementerDelegation.run_turn(session, "Do bounded work.", %{}, supervision_opts())

    assert details.error_code == "unrecognized_agent_status"
    assert {:ok, checkpoint} = evidence.checkpoint
    assert checkpoint.pane_tail == "pane before protocol failure"
    assert checkpoint.shutdown_reason == :incompatible_runtime
    assert count_received(:status_read) == 1
  end

  defmodule PromptBlockedTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, %{owner: owner}) do
      send(owner, :prompt_submitted)
      {:error, {:herdr_agent_blocked, agent.name}}
    end

    def read_agent(_session, _agent, %{source: :visible}, _context) do
      {:ok, %{text: "Approve plan? [y/n]"}}
    end
  end

  test "a prompt that settles blocked is preserved with the same evidence shape as supervision" do
    session = supervised_session(PromptBlockedTransport)

    assert {:error, {:implementer_agent_blocked, evidence}} =
             ImplementerDelegation.run_turn(session, "Do bounded work.", %{}, supervision_opts())

    assert evidence.agent_status == "blocked"
    assert {:ok, checkpoint} = evidence.checkpoint
    assert checkpoint.pane_tail == "Approve plan? [y/n]"
    assert checkpoint.shutdown_reason == :blocked
    assert_received :prompt_submitted
    refute_received :prompt_submitted
  end

  defmodule BlockedDuringRecoveryTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      {:ok, %{name: agent.name, agent_status: "working", agent_session: nil}}
    end

    def await_agent(_session, agent, _statuses, _timeout_ms, %{owner: owner}) do
      send(owner, :recovery_probe)
      {:error, {:herdr_agent_blocked, agent.name}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "blocked during recovery"}}
  end

  test "a blocked outcome during stale recovery halts as observed blocked, not a failed recovery" do
    session = supervised_session(BlockedDuringRecoveryTransport)

    assert {:error, {:implementer_agent_blocked, evidence}} =
             ImplementerDelegation.run_turn(
               session,
               "Do bounded work.",
               %{},
               supervision_opts(stale_working_ms: 5, heartbeat_interval_ms: 2)
             )

    assert [%{result: :observed_blocked}] = evidence.recovery_history
    assert {:ok, %{shutdown_reason: :blocked}} = evidence.checkpoint
    assert count_received(:recovery_probe) == 1
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
