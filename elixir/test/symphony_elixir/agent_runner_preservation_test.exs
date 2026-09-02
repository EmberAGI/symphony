defmodule SymphonyElixir.AgentRunnerPreservationTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Runner cleanup contract for supervised delegated turns (EMB-1244 Stage 2):
  a typed work-preservation checkpoint failure blocks the runner's destructive
  session stop and leaves the owned-session reference recoverable, while a
  successful checkpoint still permits bounded shutdown.
  """

  defmodule PreservationTransport do
    def default_server_snapshot(%{owner: _owner}) do
      {:ok, %{status: "running", version: "0.8.2", protocol: 20, socket: "/tmp/default.sock"}}
    end

    def start_session(spec, %{owner: _owner}) do
      {:ok, %{name: spec.name, socket: "/tmp/#{spec.name}/sock", runtime_root: "/tmp/#{spec.name}", workspace: spec.workspace}}
    end

    def prepare_worker(session, _spec, %{owner: _owner}) do
      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}
    end

    def start_agent(_session, spec, %{owner: _owner}) do
      {:ok, %{name: spec.name, pane_id: "w1:p1", agent_status: "idle"}}
    end

    def begin_turn(_session, agent, _prompt, _timeout_ms, %{owner: _owner}) do
      {:ok, %{phase: :working, agent: %{name: agent.name, agent_status: "working", agent_session: nil}}}
    end

    def get_agent(_session, agent, _timeout_ms, %{owner: _owner}) do
      {:ok, %{name: agent.name, agent_status: "blocked", agent_session: nil}}
    end

    def read_agent(_session, _agent, _opts, %{owner: owner, checkpoint_readable: readable}) do
      if readable do
        {:ok, %{text: "blocked pane evidence"}}
      else
        send(owner, :checkpoint_read_failed)
        {:error, :pane_unreadable}
      end
    end

    def stop_session(session, %{owner: owner}) do
      send(owner, {:stop_session, session.name})
      :ok
    end

    def owned_session_ref(session, %{owner: owner}) do
      %{kind: "preservation", session_name: session.name, owner: owner}
    end
  end

  defmodule PromptBlockedPreservationTransport do
    alias SymphonyElixir.AgentRunnerPreservationTest.PreservationTransport

    defdelegate default_server_snapshot(context), to: PreservationTransport
    defdelegate start_session(spec, context), to: PreservationTransport
    defdelegate prepare_worker(session, spec, context), to: PreservationTransport
    defdelegate start_agent(session, spec, context), to: PreservationTransport
    defdelegate read_agent(session, agent, opts, context), to: PreservationTransport
    defdelegate stop_session(session, context), to: PreservationTransport
    defdelegate owned_session_ref(session, context), to: PreservationTransport

    def begin_turn(_session, agent, _prompt, _timeout_ms, %{owner: _owner}) do
      {:error, {:herdr_agent_blocked, agent.name}}
    end
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    previous_orchestrator = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")
    System.put_env("SYMPHONY_ROLE", "implementer")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "codex")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_orchestrator)
      restore_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker)
    end)

    :ok
  end

  defp run_preservation_case(label, checkpoint_readable, transport \\ PreservationTransport) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-runner-preservation-#{label}-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-preservation-#{label}",
        identifier: "EMB-1244",
        repository: "EmberAGI/scaling-octo-engine",
        repository_source: "linear_label",
        title: "Preserve supervised work",
        description: "Stage 2 preservation",
        state: "In Progress",
        branch_name: "octo/emb-1244-preserve",
        url: "https://example.org/issues/EMB-1244",
        labels: []
      }

      capture_log(fn ->
        catch_exit(
          run_agent_with_ownership(issue, self(),
            run_id: "run-preserve-#{label}",
            role: "implementer",
            delegation_transport: transport,
            delegation_transport_context: %{owner: self(), checkpoint_readable: checkpoint_readable}
          )
        )
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "a typed checkpoint failure blocks the runner's destructive session stop" do
    log = run_preservation_case("blocked", false)

    assert_received :checkpoint_read_failed
    refute_received {:stop_session, _name}
    assert_received {:owned_session_runtime_info, "issue-preservation-blocked", %{kind: "preservation"}}
    assert log =~ "destructive shutdown is blocked"
  end

  test "a successful checkpoint still permits the runner's bounded session stop" do
    _log = run_preservation_case("shutdown", true)

    refute_received :checkpoint_read_failed
    assert_received {:stop_session, _name}
  end

  test "a prompt-blocked turn with a failed checkpoint blocks the runner's destructive session stop" do
    log = run_preservation_case("prompt-blocked", false, PromptBlockedPreservationTransport)

    assert_received :checkpoint_read_failed
    refute_received {:stop_session, _name}
    assert log =~ "destructive shutdown is blocked"
  end

  test "a prompt-blocked turn with a successful checkpoint still permits bounded shutdown" do
    _log = run_preservation_case("prompt-blocked-ok", true, PromptBlockedPreservationTransport)

    refute_received :checkpoint_read_failed
    assert_received {:stop_session, _name}
  end
end
