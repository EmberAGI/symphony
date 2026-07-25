defmodule SymphonyElixir.ImplementerWorkerCorrelationEvidenceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduledoc """
  RED: a delegation that really happened must never settle without evidence.

  Production canary EMB-1282 delegated assignment `EMB1282-EVIDENCE-7F3A` to a
  real Implementer worker, the worker returned its result, and the runtime
  still emitted no `Implementer worker result correlated ...` event. The
  observation path is fail-open at three seams — the transport capability
  probe, `HerdrTransport.worker_assignments/2`, and
  `validate_worker_assignments/1` — and every one of them renders "I could not
  observe any assignment" as the same `[]` that means "there was nothing to
  observe". The evidence contract downstream is fail-closed, so the run is
  reported as a clean completion that cannot be joined to its cleanup event.

  These tests pin the distinction at the public runtime seam
  (`AgentRuntime.start_session/2` + `AgentRuntime.run_turn/4` over the real
  `HerdrTransport`) and at each of the three fail-open steps.
  """

  alias SymphonyElixir.{AgentRuntime, ImplementationEffort, ImplementerDelegation}
  alias SymphonyElixir.ImplementerDelegation.HerdrTransport
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.HerdrReplayFixture

  @correlation_event "Implementer worker result correlated"

  setup do
    root = Path.join(System.tmp_dir!(), "iwce-#{System.unique_integer([:positive])}")
    provider_bin = Path.join(root, "provider-bin")
    workspace = Path.join(root, "selected-product")

    File.mkdir_p!(provider_bin)
    File.mkdir_p!(workspace)

    for provider <- ["codex", "claude"] do
      fake = Path.join(provider_bin, provider)
      File.write!(fake, "#!/bin/sh\nexit 0\n")
      File.chmod!(fake, 0o755)
    end

    previous_path = System.get_env("PATH") || ""
    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)

    System.put_env("PATH", provider_bin <> ":" <> previous_path)
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    Application.put_env(:symphony_elixir, :delegation_transport_module, HerdrTransport)

    herdr_bin = Path.join(root, "fake-herdr")
    herdr_log = Path.join(root, "herdr.log")
    replay_dir = Path.join(root, "herdr-replay")
    HerdrReplayFixture.materialize_replay_dir!(replay_dir)
    HerdrReplayFixture.write_fake_herdr!(herdr_bin, replay_dir)

    runtime_root = Path.join(System.tmp_dir!(), "iwce-rt-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      System.put_env("PATH", previous_path)

      if previous_provider,
        do: System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider),
        else: System.delete_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")

      Application.put_env(:symphony_elixir, :delegation_transport_module, previous_transport)
      File.rm_rf(root)
      File.rm_rf(runtime_root)
    end)

    {:ok, workspace: workspace, herdr_bin: herdr_bin, herdr_log: herdr_log, runtime_root: runtime_root}
  end

  defmodule BlindTransport do
    @moduledoc false

    def default_server_snapshot(_context),
      do: {:ok, %{status: "running", version: "0.7.5", protocol: 17, socket: "/tmp/default.sock"}}

    def start_session(spec, _context),
      do:
        {:ok,
         %{
           name: spec.name,
           socket: "/tmp/#{spec.name}/herdr.sock",
           runtime_root: "/tmp/#{spec.name}",
           workspace: spec.workspace
         }}

    def prepare_worker(session, _spec, %{launch_worker: true}) do
      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")
       |> Map.put(:worker, %{name: "implementer_worker", agent_status: "idle"})}
    end

    def prepare_worker(session, _spec, _context) do
      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}
    end

    def start_agent(_session, spec, _context),
      do: {:ok, %{name: spec.name, pane_id: "w1:p1", agent_status: "idle"}}

    def begin_turn(_session, agent, _prompt, _timeout_ms, _context),
      do:
        {:ok,
         %{
           phase: :completed,
           agent: %{name: agent.name, agent_status: "idle", agent_session: %{value: "orchestrator-session"}}
         }}

    def get_agent(_session, agent, _timeout_ms, _context),
      do: {:ok, %{name: agent.name, agent_status: "idle"}}

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "orchestrator turn finished"}}

    def stop_session(_session, _context), do: :ok
  end

  test "a worker that really received an assignment never settles as a silent no-evidence completion", context do
    session = start_implementer_session(context, "evidence-unrecorded")

    # Exactly what the EMB-1282 orchestrator did: it delegated bounded work to
    # the prestarted worker through its own Herdr authority. The delegation is
    # real; only its `OCTO_MSG/1 kind=assignment` record is absent.
    assert :ok =
             orchestrator_prompt(
               session,
               context,
               "implementer_worker",
               "EMB1282-EVIDENCE-7F3A: produce the bounded deliverable"
             )

    {result, log} = with_log(fn -> AgentRuntime.run_turn(session, "Implement the bounded issue.", issue(), []) end)

    refute log =~ @correlation_event

    assert {:error, {:implementer_worker_delegation_unrecorded, %{delivered: 1}}} = result

    stop(session)
  end

  test "a recorded worker result whose assignment record is missing is typed, not discarded", context do
    session = start_implementer_session(context, "evidence-orphan-result")

    assert :ok =
             worker_prompt(
               session,
               context,
               "implementer_orchestrator",
               "OCTO_MSG/1 kind=result assignment=EMB1282-EVIDENCE-7F3A status=completed"
             )

    assert {:error,
            {:implementer_worker_assignment_unrecorded,
             %{
               assignment_id: "EMB1282-EVIDENCE-7F3A",
               result: %{assignment_id: "EMB1282-EVIDENCE-7F3A", status: "completed"}
             }}} = AgentRuntime.run_turn(session, "Implement the bounded issue.", issue(), [])

    stop(session)
  end

  test "a fully recorded delegation emits the correlation event naming assignment, result and session", context do
    session = start_implementer_session(context, "evidence-correlated")

    assert :ok =
             orchestrator_prompt(
               session,
               context,
               "implementer_worker",
               "OCTO_MSG/1 kind=assignment assignment=EMB1282-EVIDENCE-7F3A deliverable=bounded"
             )

    assert :ok =
             worker_prompt(
               session,
               context,
               "implementer_orchestrator",
               "OCTO_MSG/1 kind=result assignment=EMB1282-EVIDENCE-7F3A status=completed"
             )

    {result, log} = with_log(fn -> AgentRuntime.run_turn(session, "Implement the bounded issue.", issue(), []) end)

    assert {:ok, {_next_session, turn}} = result
    assert [%{assignment_id: "EMB1282-EVIDENCE-7F3A", status: :completed}] = turn.worker_assignments

    assert log =~ @correlation_event
    assert log =~ "herdr_session=#{session.name}"
    assert log =~ "EMB1282-EVIDENCE-7F3A"
    assert log =~ "result_status: \"completed\""

    stop(session)
  end

  test "a run that never delegated succeeds with no assignments and no spurious correlation event", context do
    session = start_implementer_session(context, "evidence-direct-work")

    {result, log} = with_log(fn -> AgentRuntime.run_turn(session, "Implement the bounded issue.", issue(), []) end)

    assert {:ok, {_next_session, turn}} = result
    assert turn.worker_assignments == []
    refute log =~ @correlation_event

    stop(session)
  end

  describe "step 2 — the transport separates an unobservable session from an empty one" do
    test "a session carrying no runtime root is unobservable, not assignment-free" do
      assert {:error, {:worker_assignments_unobservable, %{reason: :session_runtime_root_missing}}} =
               HerdrTransport.worker_assignments(%{name: "octo-emb-1282-orphan"}, %{})
    end

    test "a runtime root with no worker-event recording is unobservable, not assignment-free" do
      runtime_root = Path.join(System.tmp_dir!(), "iwce-bare-#{System.unique_integer([:positive])}")
      File.mkdir_p!(runtime_root)
      on_exit(fn -> File.rm_rf(runtime_root) end)

      session = %{name: "octo-emb-1282-bare", runtime_root: runtime_root}
      unobservable = %{reason: :worker_events_root_missing, runtime_root: runtime_root}

      assert {:error, {:worker_assignments_unobservable, ^unobservable}} =
               HerdrTransport.worker_assignments(session, %{})
    end

    test "a materialized recording with nothing delivered is genuinely assignment-free" do
      runtime_root = Path.join(System.tmp_dir!(), "iwce-empty-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(runtime_root, "worker-events"))
      on_exit(fn -> File.rm_rf(runtime_root) end)

      assert {:ok, []} =
               HerdrTransport.worker_assignments(%{name: "octo-emb-1282-empty", runtime_root: runtime_root}, %{})
    end
  end

  test "a launched worker under a transport with no assignment capability fails typed" do
    unobservable = %{reason: :transport_capability_missing, transport: BlindTransport}

    assert {:error, {:implementer_worker_assignments_unobservable, ^unobservable}} =
             run_blind_turn(%{launch_worker: true})
  end

  test "a session that launched no worker under the same transport still completes" do
    assert {:ok, %{worker_assignments: []}} = run_blind_turn(%{})
  end

  defp run_blind_turn(transport_context) do
    assert {:ok, session} =
             ImplementerDelegation.start_session(
               "/tmp/symphony-correlation-evidence-ws",
               valid_contract(),
               issue_identifier: "EMB-1282",
               run_id: "run-correlation-evidence",
               transport: BlindTransport,
               transport_context: transport_context
             )

    ImplementerDelegation.run_turn(session, "Implement the bounded issue.", issue(), [])
  end

  defp start_implementer_session(context, run_id) do
    assert {:ok, session} =
             AgentRuntime.start_session(context.workspace,
               issue: issue(),
               role: "implementer",
               run_id: run_id,
               delegation_transport_context: %{
                 herdr_bin: context.herdr_bin,
                 extra_env: [{"HERDR_FAKE_LOG", context.herdr_log}],
                 socket_root: context.runtime_root,
                 poll_interval_ms: 5,
                 start_timeout_ms: 2_000
               }
             )

    session
  end

  defp orchestrator_prompt(session, context, agent, message),
    do: shim_prompt(Path.join(session.herdr_session.orchestrator_bin, "herdr"), session, context, agent, message)

  defp worker_prompt(session, context, agent, message),
    do:
      shim_prompt(
        Path.join([session.herdr_session.runtime_root, "worker-bin", "herdr"]),
        session,
        context,
        agent,
        message
      )

  defp shim_prompt(shim, session, context, agent, message) do
    assert {_output, 0} =
             System.cmd(shim, ["agent", "prompt", agent, message],
               env: [
                 {"HERDR_FAKE_LOG", context.herdr_log},
                 {"XDG_CONFIG_HOME", session.herdr_session.runtime_root}
               ],
               stderr_to_stdout: true
             )

    :ok
  end

  defp stop(session), do: AgentRuntime.stop_session(session)

  defp valid_contract do
    assert {:ok, contract} = ImplementationEffort.runtime_profile_for_issue(:codex, issue(), "implementer")
    contract
  end

  defp issue do
    %Issue{
      id: "issue-1282",
      identifier: "EMB-1282",
      title: "Correlate the Implementer worker assignment with its result",
      state: "In Progress",
      branch_name: "octo/emb-1282-correlate-worker-assignment",
      url: "https://linear.app/emberai/issue/EMB-1282",
      repository: "EmberAGI/scaling-octo-engine",
      repository_source: "linear_label",
      labels: ["implementation-effort:moderate"]
    }
  end
end
