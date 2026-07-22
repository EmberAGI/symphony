defmodule SymphonyElixir.ImplementerDelegationSessionLifecycleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ImplementationEffort, ImplementerDelegation}
  alias SymphonyElixir.Linear.Issue

  defmodule StartAgentFailsTransport do
    def default_server_snapshot(%{owner: owner}) do
      send(owner, :default_server_snapshot)
      {:ok, %{status: "running", version: "v", protocol: 1, socket: "/tmp/default.sock"}}
    end

    def start_session(spec, %{owner: owner}) do
      send(owner, {:start_session, spec.name})
      {:ok, %{name: spec.name, socket: "/tmp/#{spec.name}/sock", runtime_root: "/tmp/#{spec.name}"}}
    end

    def prepare_worker(session, _spec, %{owner: owner}) do
      send(owner, :prepare_worker)

      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/bin")}
    end

    def start_agent(_session, _spec, %{owner: owner}) do
      send(owner, :start_agent)
      {:error, :boom}
    end

    def stop_session(session, %{owner: owner}) do
      send(owner, {:stop_session, session.name})
      :ok
    end
  end

  defmodule PrepareWorkerFailsTransport do
    def default_server_snapshot(%{owner: owner}) do
      send(owner, :default_server_snapshot)
      {:ok, %{status: "running", version: "v", protocol: 1, socket: "/tmp/default.sock"}}
    end

    def start_session(spec, %{owner: owner}) do
      send(owner, {:start_session, spec.name})
      {:ok, %{name: spec.name, socket: "/tmp/#{spec.name}/sock", runtime_root: "/tmp/#{spec.name}"}}
    end

    def prepare_worker(_session, _spec, %{owner: owner}) do
      send(owner, :prepare_worker)
      {:error, :worker_boom}
    end

    def stop_session(session, %{owner: owner}) do
      send(owner, {:stop_session, session.name})
      :ok
    end
  end

  defmodule NoOrchestratorBinTransport do
    def default_server_snapshot(%{owner: owner}) do
      send(owner, :default_server_snapshot)
      {:ok, %{status: "running", version: "v", protocol: 1, socket: "/tmp/default.sock"}}
    end

    def start_session(spec, %{owner: owner}) do
      send(owner, {:start_session, spec.name})
      {:ok, %{name: spec.name, socket: "/tmp/#{spec.name}/sock", runtime_root: "/tmp/#{spec.name}"}}
    end

    def prepare_worker(session, _spec, %{owner: owner}) do
      send(owner, :prepare_worker)
      {:ok, Map.put(session, :worker_launcher, "/tmp/#{session.name}/launch-worker")}
    end

    def start_agent(_session, spec, %{owner: owner}) do
      send(owner, {:start_agent, spec})
      {:ok, %{name: spec.name, pane_id: "w1:p1", profile: spec.profile}}
    end

    def await_agent(_session, agent, statuses, _timeout_ms, %{owner: owner}) do
      send(owner, :await_agent)
      status = if "working" in statuses, do: "working", else: "done"
      {:ok, %{name: agent.name, pane_id: agent.pane_id, agent_status: status, agent_session: %{value: "sess"}}}
    end
  end

  defmodule ContextAgnosticTransport do
    def default_server_snapshot(_context), do: {:ok, %{status: "running", version: "v", protocol: 1, socket: "/tmp/default.sock"}}

    def start_session(spec, _context), do: {:ok, %{name: spec.name, socket: "/tmp/#{spec.name}/sock", runtime_root: "/tmp/#{spec.name}"}}

    def prepare_worker(session, _spec, _context) do
      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/bin")}
    end

    def start_agent(_session, spec, _context), do: {:ok, %{name: spec.name, pane_id: "w1:p1", profile: spec.profile}}

    def await_agent(_session, agent, statuses, timeout_ms, _context) do
      send(self(), {:await_agent, statuses, timeout_ms})
      status = if "working" in statuses, do: "working", else: "done"
      {:ok, %{name: agent.name, pane_id: agent.pane_id, agent_status: status, agent_session: %{value: "sess"}}}
    end
  end

  test "start_session/3 rejects malformed workspace/contract/opts via the catch-all clause" do
    assert {:error, :invalid_implementer_delegation_start} =
             ImplementerDelegation.start_session(:not_a_path, %{}, [])
  end

  test "stop_session/1 rejects a malformed session via the catch-all clause" do
    assert {:error, :invalid_implementer_delegation_session} = ImplementerDelegation.stop_session(%{})
  end

  test "owned_session_ref/1 returns nil for a malformed session via the catch-all clause" do
    assert ImplementerDelegation.owned_session_ref(%{}) == nil
  end

  test "start_session/3 rejects a non-map orchestrator_env via the catch-all clause" do
    assert {:error, :invalid_implementer_orchestrator_environment} =
             ImplementerDelegation.start_session(
               "/tmp/ws",
               valid_contract(),
               issue_identifier: "EMB-1",
               run_id: "run-env",
               transport: :unused,
               transport_context: %{},
               orchestrator_env: ["not", "a", "map"]
             )
  end

  test "a failed orchestrator agent start stops the isolated session and surfaces the reason" do
    assert {:error, {:implementer_orchestrator_start_failed, :boom}} =
             ImplementerDelegation.start_session(
               "/tmp/ws",
               valid_contract(),
               issue_identifier: "EMB-3",
               run_id: "r3",
               transport: StartAgentFailsTransport,
               transport_context: %{owner: self()}
             )

    assert_received {:stop_session, _name}
  end

  test "a failed worker preparation stops the isolated session and surfaces the reason" do
    assert {:error, {:implementer_worker_prepare_failed, :worker_boom}} =
             ImplementerDelegation.start_session(
               "/tmp/ws",
               valid_contract(),
               issue_identifier: "EMB-5",
               run_id: "r5",
               transport: PrepareWorkerFailsTransport,
               transport_context: %{owner: self()}
             )

    assert_received {:stop_session, _name}
  end

  test "a worker launcher without an orchestrator_bin leaves the orchestrator PATH untouched" do
    assert {:ok, _session} =
             ImplementerDelegation.start_session(
               "/tmp/ws",
               valid_contract(),
               issue_identifier: "EMB-6",
               run_id: "r6",
               transport: NoOrchestratorBinTransport,
               transport_context: %{owner: self()}
             )

    assert_received {:start_agent, spec}
    refute Map.has_key?(spec.env, "PATH")
    assert spec.env["OCTO_HERDR_WORKER_LAUNCHER"] == "/tmp/octo-emb-6-r6/launch-worker"
  end

  test "a non-map transport_context is passed through without Adapter policy leakage" do
    assert {:ok, _session} =
             ImplementerDelegation.start_session(
               "/tmp/ws",
               valid_contract(),
               issue_identifier: "EMB-7",
               run_id: "r7",
               transport: ContextAgnosticTransport,
               transport_context: :not_a_map
             )
  end

  test "launcher_argv raises for a contract provider that is neither codex nor claude_code" do
    contract = %{
      role: "implementer",
      provider: "bogus_provider",
      orchestrator_provider: "bogus_provider",
      worker_provider: "bogus_provider",
      orchestrator: %{
        name: "implementer-orchestrator",
        kind: "orchestrator",
        provider: "bogus_provider",
        effort: "moderate",
        model: "m",
        reasoning_effort: "e",
        instructions: "i",
        capabilities: %{can_delegate: true}
      },
      worker: %{
        name: "implementer-worker",
        kind: "worker",
        provider: "bogus_provider",
        effort: "moderate",
        model: "m",
        reasoning_effort: "e",
        instructions: "i",
        capabilities: %{can_delegate: false}
      }
    }

    assert_raise ArgumentError, ~r/unsupported Implementer provider "bogus_provider"/, fn ->
      ImplementerDelegation.start_session(
        "/tmp/ws",
        contract,
        issue_identifier: "EMB-8",
        run_id: "r8",
        transport: ContextAgnosticTransport,
        transport_context: %{}
      )
    end
  end

  defp valid_contract do
    assert {:ok, contract} = ImplementationEffort.runtime_profile_for_issue(:codex, issue(), "implementer")
    contract
  end

  defp issue do
    %Issue{
      id: "issue-lifecycle",
      identifier: "EMB-1",
      title: "Session lifecycle fixture",
      state: "Todo",
      labels: ["implementation-effort:moderate"]
    }
  end
end
