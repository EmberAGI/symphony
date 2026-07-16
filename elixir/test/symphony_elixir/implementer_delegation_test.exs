defmodule SymphonyElixir.ImplementerDelegationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentRuntime, ImplementationEffort, ImplementerDelegation}
  alias SymphonyElixir.Linear.Issue

  defmodule RecordingTransport do
    def default_server_snapshot(%{owner: owner}) do
      send(owner, {:transport, :default_server_snapshot})
      {:ok, %{status: "running", version: "0.7.3", protocol: 16, socket: "/tmp/operator-default/herdr.sock"}}
    end

    def start_session(spec, %{owner: owner}) do
      send(owner, {:transport, :start_session, spec})

      {:ok,
       %{
         name: spec.name,
         socket: "/tmp/#{spec.name}/herdr.sock",
         worker_launcher: "/tmp/#{spec.name}/launch-worker"
       }}
    end

    def start_agent(session, spec, %{owner: owner}) do
      send(owner, {:transport, :start_agent, session, spec})
      {:ok, %{name: spec.name, pane_id: "w1:p1", profile: spec.profile}}
    end

    def stop_session(session, %{owner: owner}) do
      send(owner, {:transport, :stop_session, session})
      :ok
    end

    def submit(session, agent, prompt, %{owner: owner}) do
      send(owner, {:transport, :submit, session, agent, prompt})
      :ok
    end

    def await_agent(session, agent, statuses, timeout_ms, %{owner: owner}) do
      send(owner, {:transport, :await_agent, session, agent, statuses, timeout_ms})
      status = if "working" in statuses, do: "working", else: "done"

      {:ok,
       %{
         name: agent.name,
         pane_id: agent.pane_id,
         agent_status: status,
         agent_session: %{value: "codex-session-7"}
       }}
    end

    def read_agent(session, agent, opts, %{owner: owner}) do
      send(owner, {:transport, :read_agent, session, agent, opts})
      {:ok, %{text: "IMPLEMENTER_TURN_COMPLETE"}}
    end
  end

  defmodule StaleIdleTransport do
    def submit(_session, _agent, _prompt, %{owner: owner}) do
      send(owner, {:early_completion, :submit})
      :ok
    end

    def await_agent(_session, agent, statuses, _timeout_ms, %{owner: owner}) do
      send(owner, {:stale_idle, :await_agent, statuses, agent})

      if statuses == ["working"] do
        {:error, :timeout_waiting_for_working}
      else
        {:ok,
         %{
           name: agent.name,
           pane_id: agent.pane_id,
           agent_status: "done",
           agent_session: %{value: "stale-session-1"}
         }}
      end
    end

    def read_agent(_session, _agent, _opts, %{owner: owner}) do
      send(owner, {:stale_idle, :read_agent})
      {:ok, %{text: "STALE_IDLE_MUST_NOT_COMPLETE"}}
    end
  end

  test "owns one isolated Herdr session and projects Codex agent profiles exactly" do
    contract = contract(:codex)

    assert {:ok, session} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               contract,
               issue_identifier: "EMB-1141",
               run_id: "run-7",
               transport: RecordingTransport,
               transport_context: %{owner: self()}
             )

    assert_receive {:transport, :default_server_snapshot}
    assert_receive {:transport, :start_session, session_spec}
    assert session_spec.name == "octo-emb-1141-run-7"
    assert session_spec.isolated
    assert session_spec.workspace == "/tmp/selected-workspace"
    assert session_spec.worker.name == "implementer_worker"
    assert session_spec.worker.role == :worker
    assert session_spec.worker.profile == contract.worker

    assert session_spec.worker.argv ==
             codex_argv(contract.worker, "/tmp/selected-workspace")

    refute session_spec.worker.may_spawn_agents

    assert_receive {:transport, :start_agent, %{name: "octo-emb-1141-run-7"}, orchestrator_spec}
    assert orchestrator_spec.name == "implementer_orchestrator"
    assert orchestrator_spec.role == :orchestrator
    assert orchestrator_spec.profile == contract.orchestrator
    assert orchestrator_spec.argv == codex_argv(contract.orchestrator, "/tmp/selected-workspace")

    assert orchestrator_spec.env == %{
             "OCTO_HERDR_WORKER_LAUNCHER" => "/tmp/octo-emb-1141-run-7/launch-worker"
           }

    assert_receive {:transport, :await_agent, _, _, ["idle", "done"], 30_000}
    assert session.orchestrator.name == "implementer_orchestrator"
    assert session.contract == contract
    assert session.default_server_before.socket == "/tmp/operator-default/herdr.sock"

    assert {:ok, turn_result} =
             ImplementerDelegation.run_turn(
               session,
               "Implement the bounded tracer task.",
               %{identifier: "EMB-1141"},
               turn_timeout_ms: 90_000,
               on_message: fn message -> send(self(), {:runtime_message, message}) end
             )

    assert_receive {:transport, :submit, %{name: "octo-emb-1141-run-7"}, %{name: "implementer_orchestrator"}, "Implement the bounded tracer task."}

    assert_receive {:transport, :await_agent, _, _, ["working"], 30_000}
    assert_receive {:transport, :await_agent, _, _, ["idle", "done"], 90_000}
    assert_receive {:transport, :read_agent, _, _, %{lines: 240, source: :recent_unwrapped}}

    assert turn_result.session_id == "codex-session-7"
    assert turn_result.response == "IMPLEMENTER_TURN_COMPLETE"

    assert_receive {:runtime_message,
                    %{
                      event: :session_started,
                      provider: "codex",
                      agent: "implementer_orchestrator"
                    }}

    assert_receive {:runtime_message, %{event: :turn_completed, provider: "codex"}}

    assert :ok = ImplementerDelegation.stop_session(session)
    assert_receive {:transport, :stop_session, %{name: "octo-emb-1141-run-7"}}
    assert_receive {:transport, :default_server_snapshot}
  end

  test "Claude projections append each canonical profile body and disable native descendants" do
    contract = contract(:claude_code)

    assert {:ok, _session} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               contract,
               issue_identifier: "EMB-1141",
               run_id: "claude-run",
               transport: RecordingTransport,
               transport_context: %{owner: self()}
             )

    assert_receive {:transport, :default_server_snapshot}
    assert_receive {:transport, :start_session, session_spec}
    assert_receive {:transport, :start_agent, _, orchestrator_spec}

    assert session_spec.worker.argv == claude_argv(contract.worker)
    assert orchestrator_spec.argv == claude_argv(contract.orchestrator)
    assert Enum.member?(session_spec.worker.argv, contract.worker.instructions)
    assert Enum.member?(orchestrator_spec.argv, contract.orchestrator.instructions)
  end

  test "AgentRuntime routes and composes only Implementer sessions through Herdr" do
    assert AgentRuntime.session_adapter(:codex, "implementer") == ImplementerDelegation
    assert AgentRuntime.session_adapter(:claude_code, "implementer") == ImplementerDelegation
    assert AgentRuntime.session_adapter(:codex, "reviewer") == SymphonyElixir.Codex.AppServer
    assert AgentRuntime.session_adapter(:claude_code, "qa") == SymphonyElixir.ClaudeCode.AppServer

    issue = issue()

    assert {:ok, session} =
             AgentRuntime.start_session(
               "/tmp/selected-workspace",
               issue: issue,
               role: "implementer",
               run_id: "runtime-seam",
               delegation_transport: RecordingTransport,
               delegation_transport_context: %{owner: self()}
             )

    assert_receive {:transport, :default_server_snapshot}
    assert_receive {:transport, :start_session, session_spec}
    assert session_spec.worker.profile.name == "implementer-worker"
    assert session_spec.worker.profile.model == "gpt-5.6-luna"

    assert_receive {:transport, :start_agent, _, orchestrator_spec}
    assert orchestrator_spec.profile.name == "implementer-orchestrator"
    assert orchestrator_spec.profile.model == "gpt-5.6-sol"
    assert_receive {:transport, :await_agent, _, _, ["idle", "done"], 30_000}

    assert {:ok, {next_session, turn}} =
             AgentRuntime.run_turn(session, "Complete the public tracer turn.", issue, [])

    assert next_session.name == "octo-emb-1141-runtime-seam"
    assert turn.response == "IMPLEMENTER_TURN_COMPLETE"
    assert :ok = AgentRuntime.stop_session(next_session)
  end

  test "a stale pre-submit idle state cannot complete a turn" do
    session = %{
      transport: StaleIdleTransport,
      transport_context: %{owner: self()},
      herdr_session: %{name: "octo-emb-1141-fast"},
      orchestrator: %{name: "implementer_orchestrator", pane_id: "w1:p1"}
    }

    assert {:error, :timeout_waiting_for_working} =
             ImplementerDelegation.run_turn(
               session,
               "Complete immediately.",
               %{identifier: "EMB-1141"},
               start_timeout_ms: 25
             )

    assert_receive {:stale_idle, :await_agent, ["working"], _agent}
    refute_receive {:stale_idle, :read_agent}
  end

  defp contract(provider) do
    assert {:ok, contract} =
             ImplementationEffort.runtime_profile_for_issue(provider, issue(), "implementer")

    contract
  end

  defp issue do
    %Issue{
      id: "issue-1141",
      identifier: "EMB-1141",
      title: "Exercise the public runtime seam",
      state: "In Progress",
      labels: ["implementation-effort:moderate"]
    }
  end

  defp codex_argv(profile, workspace) do
    [
      "codex",
      "--model",
      profile.model,
      "--config",
      "model_reasoning_effort=#{profile.reasoning_effort}",
      "--config",
      "developer_instructions=#{inspect(profile.instructions)}",
      "--config",
      "shell_environment_policy.inherit=all",
      "--sandbox",
      "workspace-write",
      "--ask-for-approval",
      "never",
      "--disable",
      "multi_agent",
      "--dangerously-bypass-hook-trust",
      "--config",
      "projects={#{inspect(workspace)}={trust_level=\"trusted\"}}",
      "--no-alt-screen"
    ]
  end

  defp claude_argv(profile) do
    [
      "claude",
      "--model",
      profile.model,
      "--effort",
      profile.reasoning_effort,
      "--append-system-prompt",
      profile.instructions,
      "--dangerously-skip-permissions",
      "--disallowed-tools",
      "Agent"
    ]
  end
end
