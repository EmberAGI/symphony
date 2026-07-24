defmodule SymphonyElixir.ImplementerDelegationTurnLifecycleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ImplementerDelegation

  defmodule ImmediateCompletionTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :completed, agent: %{name: agent.name, agent_status: "done", agent_session: %{value: "sess-immediate"}}}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "IMPLEMENTER_TURN_COMPLETE"}}
  end

  defmodule AlreadyIdleTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "idle", agent_session: %{value: "sess-already-idle"}}}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "IMPLEMENTER_TURN_COMPLETE"}}
  end

  defmodule UnexpectedStatusTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "crashed", agent_session: nil}}}
    end
  end

  defmodule AlwaysTimeoutTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      {:ok, %{name: agent.name, agent_status: "working", agent_session: nil}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "still working"}}
  end

  defmodule OtherAwaitErrorTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, _agent, _timeout_ms, _context), do: {:error, :boom}

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "pane evidence"}}
  end

  defmodule LoginRequiredTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "idle", agent_session: nil}}}
    end

    def read_agent(_session, _agent, _opts, _context) do
      {:ok, %{text: "Session expired. Please run /login to continue."}}
    end
  end

  defmodule StringKeyedSessionTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "idle", agent_session: %{"value" => "string-keyed-session"}}}}
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "IMPLEMENTER_TURN_COMPLETE"}}
  end

  test "run_turn/4 rejects a malformed session/prompt/opts via the catch-all clause" do
    assert {:error, :invalid_implementer_delegation_turn} = ImplementerDelegation.run_turn(%{}, "", %{}, [])
  end

  test "a transport-observed immediate completion skips awaiting and reads the turn result" do
    assert {:ok, %{response: "IMPLEMENTER_TURN_COMPLETE", session_id: "sess-immediate"}} =
             ImplementerDelegation.run_turn(session(ImmediateCompletionTransport), "prompt", %{}, [])
  end

  test "an orchestrator observed already idle completes the turn without polling" do
    assert {:ok, %{response: "IMPLEMENTER_TURN_COMPLETE", session_id: "sess-already-idle"}} =
             ImplementerDelegation.run_turn(session(AlreadyIdleTransport), "prompt", %{}, [])
  end

  test "an unexpected non-terminal agent status fails the turn closed" do
    assert {:error, {:unexpected_herdr_agent_status, "crashed"}} =
             ImplementerDelegation.run_turn(session(UnexpectedStatusTransport), "prompt", %{}, [])
  end

  test "a turn that exhausts the hard budget checkpoints and preserves instead of timing out silently" do
    assert {:error, {:implementer_hard_budget_exhausted, %{checkpoint: {:ok, checkpoint}}}} =
             ImplementerDelegation.run_turn(session(AlwaysTimeoutTransport), "prompt", %{},
               turn_timeout_ms: 10,
               heartbeat_interval_ms: 10_000
             )

    assert checkpoint.pane_tail == "still working"
    assert checkpoint.shutdown_reason == :hard_budget_exhausted
  end

  test "a persistent non-timeout status-read error escalates typed after bounded retries" do
    assert {:error, {:implementer_status_reads_failed, %{last_error: :boom}}} =
             ImplementerDelegation.run_turn(session(OtherAwaitErrorTransport), "prompt", %{},
               turn_timeout_ms: 10_000,
               heartbeat_interval_ms: 1
             )
  end

  test "a login-required response without a matching API-Error line fails the turn closed" do
    session = session(LoginRequiredTransport) |> Map.put(:contract, %{provider: "claude_code"})

    assert {:error, {:auth_failed, %{api_error_status: nil, subtype: "login_required"}}} =
             ImplementerDelegation.run_turn(session, "prompt", %{}, [])
  end

  test "a string-keyed agent_session value is recognized as the turn's session id" do
    assert {:ok, %{session_id: "string-keyed-session"}} =
             ImplementerDelegation.run_turn(session(StringKeyedSessionTransport), "prompt", %{}, [])
  end

  defp session(transport) do
    %{
      transport: transport,
      transport_context: %{},
      herdr_session: %{name: "octo-emb-1180-turn"},
      orchestrator: %{name: "implementer_orchestrator", pane_id: "w1:p1"}
    }
  end
end
