defmodule SymphonyElixir.ImplementerDelegationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentRuntime, ImplementationEffort, ImplementerDelegation, SkillExecutionContract}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Runtime.ProcessOwnership
  alias SymphonyElixir.TestSupport.{HerdrReplayFixture, HerdrSessionFixture}

  defmodule RecordingTransport do
    def default_server_snapshot(%{owner: owner}) do
      send(owner, {:transport, :default_server_snapshot})
      {:ok, %{status: "running", version: "0.8.2", protocol: 20, socket: "/tmp/operator-default/herdr.sock"}}
    end

    def start_session(spec, %{owner: owner}) do
      send(owner, {:transport, :start_session, spec})

      {:ok,
       %{
         name: spec.name,
         socket: "/tmp/#{spec.name}/herdr.sock",
         runtime_root: "/tmp/#{spec.name}"
       }}
    end

    def prepare_worker(session, spec, %{owner: owner}) do
      send(owner, {:transport, :prepare_worker, session, spec})

      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}
    end

    def start_agent(session, spec, %{owner: owner}) do
      send(owner, {:transport, :start_agent, session, spec})
      {:ok, %{name: spec.name, pane_id: "w1:p1", profile: spec.profile}}
    end

    def stop_session(session, %{owner: owner}) do
      send(owner, {:transport, :stop_session, session})
      :ok
    end

    def owned_session_ref(session, %{owner: owner}) do
      %{
        kind: "recording",
        session_name: session.name,
        cleanup_module: __MODULE__,
        owner: owner
      }
    end

    def cleanup_owned_session(%{owner: owner, session_name: session_name}) do
      send(owner, {:transport, :cleanup_owned_session, session_name})
      :ok
    end

    def begin_turn(session, agent, prompt, timeout_ms, %{owner: owner}) do
      send(owner, {:transport, :begin_turn, session, agent, prompt, timeout_ms})

      {:ok,
       %{
         phase: :working,
         agent: %{
           name: agent.name,
           pane_id: agent.pane_id,
           agent_status: "working",
           agent_session: %{value: "codex-session-7"}
         }
       }}
    end

    def get_agent(session, agent, timeout_ms, %{owner: owner}) do
      send(owner, {:transport, :get_agent, session, agent, timeout_ms})

      {:ok,
       %{
         name: agent.name,
         pane_id: agent.pane_id,
         agent_status: "done",
         agent_session: %{value: "codex-session-7"}
       }}
    end

    def read_agent(session, agent, opts, %{owner: owner}) do
      send(owner, {:transport, :read_agent, session, agent, opts})
      {:ok, %{text: "IMPLEMENTER_TURN_COMPLETE"}}
    end
  end

  defmodule NotReadyTransport do
    alias SymphonyElixir.ImplementerDelegationTest.RecordingTransport

    defdelegate default_server_snapshot(context), to: RecordingTransport
    defdelegate start_session(spec, context), to: RecordingTransport
    defdelegate prepare_worker(session, spec, context), to: RecordingTransport
    defdelegate stop_session(session, context), to: RecordingTransport

    def start_agent(session, spec, %{owner: owner}) do
      send(owner, {:transport, :start_agent, session, spec})
      {:error, {:herdr_agent_not_ready, spec.name}}
    end
  end

  defmodule PromptStallTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, %{owner: owner}) do
      send(owner, {:prompt_stall, :begin_turn, agent})
      {:error, {:herdr_agent_prompt_stalled, agent.name}}
    end

    def read_agent(_session, _agent, _opts, %{owner: owner}) do
      send(owner, {:prompt_stall, :read_agent})
      {:ok, %{text: "PROMPT_STALL_MUST_NOT_COMPLETE"}}
    end
  end

  defmodule HeartbeatTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok,
       %{
         phase: :working,
         agent: %{name: agent.name, agent_status: "working", agent_session: nil}
       }}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      attempt = Process.get({__MODULE__, :attempt}, 0) + 1
      Process.put({__MODULE__, :attempt}, attempt)

      if attempt < 3 do
        {:ok, %{name: agent.name, agent_status: "working", agent_session: nil}}
      else
        {:ok,
         %{
           name: agent.name,
           agent_status: "idle",
           agent_session: %{value: "heartbeat-session"}
         }}
      end
    end

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "HEARTBEAT_COMPLETE"}}
  end

  defmodule ClaudeAuthFailureTransport do
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context) do
      {:ok,
       %{
         phase: :working,
         agent: %{name: agent.name, agent_status: "working", agent_session: nil}
       }}
    end

    def get_agent(_session, agent, _timeout_ms, _context) do
      {:ok, %{name: agent.name, agent_status: "idle", agent_session: nil}}
    end

    def read_agent(_session, _agent, _opts, _context) do
      {:ok,
       %{
         text: "Please run /login\nAPI Error: 401 Invalid authentication credentials"
       }}
    end
  end

  test "owns one isolated Herdr session and projects Codex agent profiles exactly" do
    contract = contract(:codex)
    orchestration_root = "/tmp/scaling-octo-engine"
    package_root = Path.join([orchestration_root, ".agents", "skills", "linear"])
    runtime_input = Path.join(orchestration_root, "uv.lock")
    tool_executable = "/opt/octo/bin/uv"

    skill_contract = %SkillExecutionContract{
      skill: "linear",
      package_root: package_root,
      runtime_inputs: [runtime_input],
      tool_executables: [tool_executable]
    }

    assert {:ok, session} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               contract,
               issue_identifier: "EMB-1141",
               run_id: "run-7",
               transport: RecordingTransport,
               transport_context: %{owner: self()},
               skill_execution_contracts: [skill_contract],
               orchestrator_env: %{
                 "SYMPHONY_ORCHESTRATION_ROOT" => orchestration_root
               }
             )

    assert_receive {:transport, :default_server_snapshot}
    assert_receive {:transport, :start_session, session_spec}
    assert session_spec.name == "octo-emb-1141-run-7"
    assert session_spec.isolated
    assert session_spec.workspace == "/tmp/selected-workspace"
    refute Map.has_key?(session_spec, :worker)

    assert_receive {:transport, :prepare_worker, herdr_session, worker_spec}
    assert worker_spec.name == "implementer_worker"
    assert worker_spec.role == :worker
    assert worker_spec.profile == contract.worker

    assert worker_spec.argv ==
             codex_argv(contract.worker, "/tmp/selected-workspace", herdr_session)

    assert herdr_session.permission_read_roots == [package_root, runtime_input, tool_executable]

    for path <- herdr_session.permission_read_roots do
      assert Enum.any?(worker_spec.argv, &String.contains?(&1, "#{inspect(path)}=\"read\""))
    end

    refute Enum.any?(
             worker_spec.argv,
             &String.contains?(&1, "#{inspect(orchestration_root)}=\"read\"")
           )

    refute Enum.any?(
             worker_spec.argv,
             &String.contains?(&1, "#{inspect(Path.join(orchestration_root, ".agents/skills"))}=\"read\"")
           )

    assert worker_spec.env["SYMPHONY_SKILL_EXECUTION_CONTRACTS"] ==
             SkillExecutionContract.encode!([skill_contract])

    refute worker_spec.may_spawn_agents

    assert_receive {:transport, :start_agent, %{name: "octo-emb-1141-run-7"}, orchestrator_spec}
    assert orchestrator_spec.name == "implementer_orchestrator"
    assert orchestrator_spec.role == :orchestrator
    assert orchestrator_spec.profile == contract.orchestrator

    assert orchestrator_spec.argv ==
             codex_argv(contract.orchestrator, "/tmp/selected-workspace", herdr_session)

    for path <- herdr_session.permission_read_roots do
      assert Enum.any?(orchestrator_spec.argv, &String.contains?(&1, "#{inspect(path)}=\"read\""))
    end

    refute Enum.any?(
             orchestrator_spec.argv,
             &String.contains?(&1, "#{inspect(orchestration_root)}=\"read\"")
           )

    refute Enum.any?(
             orchestrator_spec.argv,
             &String.contains?(&1, "#{inspect(Path.join(orchestration_root, ".agents/skills"))}=\"read\"")
           )

    assert Enum.any?(orchestrator_spec.argv, fn arg ->
             String.contains?(arg, "\":workspace_roots\"={\".\"=\"write\",\".git\"=\"write\"}")
           end)

    assert orchestrator_spec.env["OCTO_HERDR_WORKER_LAUNCHER"] ==
             "/tmp/octo-emb-1141-run-7/launch-worker"

    assert String.starts_with?(
             orchestrator_spec.env["PATH"],
             "/tmp/octo-emb-1141-run-7/orchestrator-bin:"
           )

    assert orchestrator_spec.env["SYMPHONY_SKILL_EXECUTION_CONTRACTS"] ==
             SkillExecutionContract.encode!([skill_contract])

    assert session.orchestrator.name == "implementer_orchestrator"
    assert session.contract == contract
    assert session.default_server_before.socket == "/tmp/operator-default/herdr.sock"

    ownership_ref = AgentRuntime.owned_session_ref(session)
    assert ownership_ref.kind == "recording"
    assert ownership_ref.session_name == "octo-emb-1141-run-7"
    assert ownership_ref.handoff_settlement == :implementer_turn
    assert :ok = AgentRuntime.cleanup_owned_session(ownership_ref)
    assert_receive {:transport, :cleanup_owned_session, "octo-emb-1141-run-7"}

    assert {:ok, turn_result} =
             ImplementerDelegation.run_turn(
               session,
               "Implement the bounded tracer task.",
               %{identifier: "EMB-1141"},
               turn_timeout_ms: 90_000,
               on_message: fn message -> send(self(), {:runtime_message, message}) end
             )

    assert_receive {:transport, :begin_turn, %{name: "octo-emb-1141-run-7"}, %{name: "implementer_orchestrator"}, "Implement the bounded tracer task.", 120_000}

    assert_receive {:transport, :get_agent, _, _, 60_000}
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
    assert_receive {:transport, :prepare_worker, _, worker_spec}
    assert_receive {:transport, :start_agent, _, orchestrator_spec}

    refute Map.has_key?(session_spec, :worker)
    assert worker_spec.argv == claude_argv(contract.worker)
    assert orchestrator_spec.argv == claude_argv(contract.orchestrator)
    assert Enum.member?(worker_spec.argv, contract.worker.instructions)
    assert Enum.member?(orchestrator_spec.argv, contract.orchestrator.instructions)
  end

  test "blocked orchestrator startup preserves the typed target for inspection and recovery" do
    assert {:error, {:herdr_agent_not_ready, "implementer_orchestrator"}} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               contract(:codex),
               issue_identifier: "EMB-1141",
               run_id: "not-ready",
               transport: NotReadyTransport,
               transport_context: %{owner: self()}
             )

    assert_receive {:transport, :start_agent, %{name: "octo-emb-1141-not-ready"}, %{name: "implementer_orchestrator"}}
    refute_receive {:transport, :stop_session, _}
  end

  test "mixed provider contract launches Claude orchestrator and Codex worker adapters" do
    assert {:ok, contract} =
             ImplementationEffort.runtime_profile_for_issue(
               :claude_code,
               :codex,
               issue(),
               "implementer"
             )

    assert {:ok, _session} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               contract,
               issue_identifier: "EMB-1163",
               run_id: "mixed-run",
               transport: RecordingTransport,
               transport_context: %{owner: self()}
             )

    assert_receive {:transport, :default_server_snapshot}
    assert_receive {:transport, :start_session, _}
    assert_receive {:transport, :prepare_worker, herdr_session, worker_spec}
    assert_receive {:transport, :start_agent, _, orchestrator_spec}

    assert worker_spec.provider == "codex"
    assert worker_spec.argv == codex_argv(contract.worker, "/tmp/selected-workspace", herdr_session)
    assert orchestrator_spec.provider == "claude_code"
    assert orchestrator_spec.argv == claude_argv(contract.orchestrator)
  end

  test "compacts production claim-lease run ids into deterministic socket-safe session names" do
    contract = contract(:codex)
    run_id = "localhost:1425052:implementer:3763a042-63a8-4b7b-a087-a18913c0a146:1"

    assert {:ok, first} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               contract,
               issue_identifier: "EMB-1156",
               run_id: run_id,
               transport: RecordingTransport,
               transport_context: %{owner: self()}
             )

    assert byte_size(first.name) <= 44
    assert first.name =~ ~r/^octo-emb-1156-[0-9a-f]{16}$/

    default_root = "/tmp/octo-herdr-" <> String.duplicate("a", 16)
    socket_path = Path.join([default_root, "herdr", "sessions", first.name, "herdr.sock"])
    assert byte_size(socket_path) <= 103

    assert {:ok, repeated} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               contract,
               issue_identifier: "EMB-1156",
               run_id: run_id,
               transport: RecordingTransport,
               transport_context: %{owner: self()}
             )

    assert repeated.name == first.name

    assert {:ok, different} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               contract,
               issue_identifier: "EMB-1156",
               run_id: run_id <> ":retry",
               transport: RecordingTransport,
               transport_context: %{owner: self()}
             )

    refute different.name == first.name
  end

  test "AgentRuntime routes and composes only Implementer sessions through Herdr" do
    orchestration_root =
      Path.join(
        System.tmp_dir!(),
        "implementer-runtime-skills-#{System.unique_integer([:positive])}"
      )

    package_root = Path.join([orchestration_root, "skill-runtime", "linear"])
    runtime_input = Path.join(orchestration_root, "uv.lock")
    executable = Path.join(orchestration_root, "uv")
    previous_root = System.get_env("SYMPHONY_ORCHESTRATION_ROOT")
    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker_provider = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")

    File.mkdir_p!(package_root)
    File.write!(runtime_input, "locked")
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.chmod!(executable, 0o755)
    System.put_env("SYMPHONY_ORCHESTRATION_ROOT", orchestration_root)
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "codex")

    on_exit(fn ->
      if previous_root,
        do: System.put_env("SYMPHONY_ORCHESTRATION_ROOT", previous_root),
        else: System.delete_env("SYMPHONY_ORCHESTRATION_ROOT")

      if previous_provider,
        do: System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider),
        else: System.delete_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")

      if previous_worker_provider,
        do: System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker_provider),
        else: System.delete_env("OCTO_RUNTIME_WORKER_PROVIDER")

      File.rm_rf(orchestration_root)
    end)

    assert AgentRuntime.session_adapter(:codex, "implementer") == ImplementerDelegation
    assert AgentRuntime.session_adapter(:claude_code, "implementer") == ImplementerDelegation
    assert AgentRuntime.session_adapter(:codex, "reviewer") == SymphonyElixir.Codex.AppServer
    assert AgentRuntime.session_adapter(:claude_code, "qa") == SymphonyElixir.ClaudeCode.AppServer

    issue = issue()

    skill_entry = %{
      skill: "linear",
      package_root: package_root,
      runtime_inputs: [runtime_input],
      tool_executables: [executable]
    }

    encoded_contract =
      Jason.encode!([
        %{
          skill: "linear",
          package_root: package_root,
          runtime_inputs: [runtime_input],
          tool_executables: [executable]
        }
      ])

    assert {:ok, session} =
             AgentRuntime.start_session(
               "/tmp/selected-workspace",
               issue: issue,
               role: "implementer",
               run_id: "runtime-seam",
               skill_execution_contracts: [skill_entry],
               delegation_transport: RecordingTransport,
               delegation_transport_context: %{owner: self()}
             )

    assert_receive {:transport, :default_server_snapshot}
    assert_receive {:transport, :start_session, session_spec}
    refute Map.has_key?(session_spec, :worker)

    assert_receive {:transport, :prepare_worker, herdr_session, worker_spec}
    assert worker_spec.profile.name == "implementer-worker"
    assert worker_spec.profile.model == "gpt-5.6-luna"
    assert herdr_session.permission_read_roots == [package_root, runtime_input, executable]
    assert worker_spec.env["SYMPHONY_SKILL_EXECUTION_CONTRACTS"] == encoded_contract
    assert Enum.any?(worker_spec.argv, &String.contains?(&1, "#{inspect(package_root)}=\"read\""))

    refute Enum.any?(
             worker_spec.argv,
             &String.contains?(&1, "#{inspect(Path.join(orchestration_root, ".agents/skills"))}=\"read\"")
           )

    assert_receive {:transport, :start_agent, _, orchestrator_spec}
    assert orchestrator_spec.profile.name == "implementer-orchestrator"
    assert orchestrator_spec.profile.model == "gpt-5.6-sol"
    assert orchestrator_spec.env["SYMPHONY_SKILL_EXECUTION_CONTRACTS"] == encoded_contract
    assert Enum.any?(orchestrator_spec.argv, &String.contains?(&1, "#{inspect(package_root)}=\"read\""))

    refute Enum.any?(
             orchestrator_spec.argv,
             &String.contains?(&1, "#{inspect(Path.join(orchestration_root, ".agents/skills"))}=\"read\"")
           )

    assert String.starts_with?(
             orchestrator_spec.env["PATH"],
             "/tmp/octo-emb-1141-runtime-seam/orchestrator-bin:"
           )

    ownership_keys = [
      "SYMPHONY_ROLE_HOLDER",
      "SYMPHONY_ROLE_ISSUE_ID",
      "SYMPHONY_ROLE_ISSUE_IDENTIFIER",
      "SYMPHONY_ROLE_OWNERSHIP_PATH",
      "SYMPHONY_ROLE_WORKSPACE_PATH"
    ]

    assert orchestrator_spec.env["SYMPHONY_ROLE_ISSUE_ID"] == "issue-1141"
    assert orchestrator_spec.env["SYMPHONY_ROLE_ISSUE_IDENTIFIER"] == "EMB-1141"
    assert orchestrator_spec.env["SYMPHONY_ROLE_WORKSPACE_PATH"] == "/tmp/selected-workspace"
    assert orchestrator_spec.env["SYMPHONY_ROLE_HOLDER"] == ProcessOwnership.holder_id()
    assert orchestrator_spec.env["SYMPHONY_ROLE_OWNERSHIP_PATH"] =~ "process-ownership"

    ownership_path = orchestrator_spec.env["SYMPHONY_ROLE_OWNERSHIP_PATH"]

    assert Enum.any?(
             orchestrator_spec.argv,
             &String.contains?(&1, "#{inspect(ownership_path)}=\"read\"")
           )

    refute Enum.any?(
             orchestrator_spec.argv,
             &String.contains?(&1, "#{inspect(Path.dirname(ownership_path))}=\"read\"")
           )

    assert orchestrator_spec.env |> Map.delete("PATH") |> Map.drop(ownership_keys) == %{
             "OCTO_HERDR_WORKER_LAUNCHER" => "/tmp/octo-emb-1141-runtime-seam/launch-worker",
             "SYMPHONY_SKILL_EXECUTION_CONTRACTS" => encoded_contract,
             "SYMPHONY_EXPECTED_BRANCH" => "agent/emb-1141-exercise-the-public-runtime-seam",
             "SYMPHONY_ISSUE_BRANCH_NAME" => "sebastianvarela/emb-1141-exercise-the-public-runtime-seam",
             "SYMPHONY_ISSUE_ID" => "issue-1141",
             "SYMPHONY_ISSUE_IDENTIFIER" => "EMB-1141",
             "SYMPHONY_ISSUE_REPOSITORY" => "EmberAGI/scaling-octo-engine",
             "SYMPHONY_ISSUE_REPOSITORY_SOURCE" => "linear_label",
             "SYMPHONY_ISSUE_STATE" => "In Progress",
             "SYMPHONY_ISSUE_TITLE" => "Exercise the public runtime seam",
             "SYMPHONY_ISSUE_URL" => "https://linear.app/emberai/issue/EMB-1141",
             "SYMPHONY_ORCHESTRATION_ROOT" => orchestration_root,
             "SYMPHONY_ROLE_NAME" => "implementer",
             "SYMPHONY_ROLE_RUN_ID" => "runtime-seam"
           }

    assert {:ok, {next_session, turn}} =
             AgentRuntime.run_turn(session, "Complete the public tracer turn.", issue, [])

    assert next_session.name == "octo-emb-1141-runtime-seam"
    assert turn.response == "IMPLEMENTER_TURN_COMPLETE"
    assert :ok = AgentRuntime.stop_session(next_session)
    assert_receive {:transport, :stop_session, _}

    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "claude_code")

    assert {:ok, claude_session} =
             AgentRuntime.start_session(
               "/tmp/selected-workspace",
               issue: issue,
               role: "implementer",
               run_id: "runtime-seam-claude",
               skill_execution_contracts: [skill_entry],
               delegation_transport: RecordingTransport,
               delegation_transport_context: %{owner: self()}
             )

    assert_receive {:transport, :default_server_snapshot}
    assert_receive {:transport, :start_session, _}
    assert_receive {:transport, :prepare_worker, _, claude_worker_spec}
    assert claude_worker_spec.provider == "claude_code"
    assert package_root in claude_worker_spec.argv
    assert claude_worker_spec.env["SYMPHONY_SKILL_EXECUTION_CONTRACTS"] == encoded_contract

    assert_receive {:transport, :start_agent, _, claude_orchestrator_spec}
    assert claude_orchestrator_spec.provider == "claude_code"
    assert package_root in claude_orchestrator_spec.argv
    assert claude_orchestrator_spec.env["SYMPHONY_SKILL_EXECUTION_CONTRACTS"] == encoded_contract
    assert :ok = AgentRuntime.stop_session(claude_session)
    assert_receive {:transport, :stop_session, _}
  end

  test "AgentRuntime starts the default Herdr Adapter with exact registered resources" do
    root = Path.join(System.tmp_dir!(), "agent-runtime-default-herdr-#{System.unique_integer([:positive])}")

    resolvable_provider_bin = Path.join(root, "resolvable-provider-bin")
    File.mkdir_p!(resolvable_provider_bin)

    for provider <- ["codex", "claude"] do
      fake = Path.join(resolvable_provider_bin, provider)
      File.write!(fake, "#!/bin/sh\nexit 0\n")
      File.chmod!(fake, 0o755)
    end

    previous_path = System.get_env("PATH") || ""
    System.put_env("PATH", resolvable_provider_bin <> ":" <> previous_path)
    on_exit(fn -> System.put_env("PATH", previous_path) end)
    orchestration_root = Path.join(root, "orchestration")
    workspace = Path.join(root, "selected-product")
    package_root = Path.join([orchestration_root, ".agents", "skills", "linear"])
    runtime_input = Path.join(orchestration_root, "uv.lock")
    executable = Path.join(root, "tooling-uv")
    herdr_bin = Path.join(root, "fake-herdr")
    herdr_log = Path.join(root, "herdr.log")
    runtime_root = Path.join(System.tmp_dir!(), "arh-#{System.unique_integer([:positive])}")
    previous_root = System.get_env("SYMPHONY_ORCHESTRATION_ROOT")
    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)

    File.mkdir_p!(package_root)
    File.mkdir_p!(workspace)
    File.write!(runtime_input, "locked")
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.chmod!(executable, 0o755)
    write_fake_herdr!(herdr_bin)
    System.put_env("SYMPHONY_ORCHESTRATION_ROOT", orchestration_root)
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")

    Application.put_env(
      :symphony_elixir,
      :delegation_transport_module,
      SymphonyElixir.ImplementerDelegation.HerdrTransport
    )

    on_exit(fn ->
      if previous_root,
        do: System.put_env("SYMPHONY_ORCHESTRATION_ROOT", previous_root),
        else: System.delete_env("SYMPHONY_ORCHESTRATION_ROOT")

      if previous_provider,
        do: System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider),
        else: System.delete_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")

      Application.put_env(:symphony_elixir, :delegation_transport_module, previous_transport)

      File.rm_rf(root)
      File.rm_rf(runtime_root)
    end)

    entry = %{
      skill: "linear",
      package_root: package_root,
      runtime_inputs: [runtime_input],
      tool_executables: [executable]
    }

    assert {:ok, session} =
             HerdrSessionFixture.start_session(workspace,
               issue: issue(),
               role: "implementer",
               run_id: "default-herdr",
               skill_execution_contracts: [entry],
               delegation_transport_context: %{
                 herdr_bin: herdr_bin,
                 extra_env: [{"HERDR_FAKE_LOG", herdr_log}],
                 socket_root: runtime_root,
                 poll_interval_ms: 5,
                 start_timeout_ms: 2_000
               }
             )

    assert session.transport == SymphonyElixir.ImplementerDelegation.HerdrTransport
    assert session.herdr_session.permission_read_roots == [package_root, runtime_input, executable]

    commands = File.read!(herdr_log)
    assert commands =~ "agent start implementer_orchestrator"
    refute commands =~ package_root
    refute commands =~ runtime_input
    refute commands =~ executable
    refute commands =~ "#{inspect(Path.join(orchestration_root, ".agents/skills"))}=\"read\""

    worker_launcher = File.read!(session.herdr_session.worker_launcher)
    refute worker_launcher =~ package_root
    refute worker_launcher =~ runtime_input
    refute worker_launcher =~ executable
    refute worker_launcher =~ "#{inspect(Path.join(orchestration_root, ".agents/skills"))}=\"read\""

    projections =
      runtime_root
      |> Path.join("launch-projections/*.sh")
      |> Path.wildcard()
      |> Enum.map_join(&File.read!/1)

    assert projections =~ package_root
    assert projections =~ runtime_input
    assert projections =~ executable
    refute projections =~ "#{inspect(Path.join(orchestration_root, ".agents/skills"))}=\"read\""

    worker_events = Path.join(session.herdr_session.runtime_root, "worker-events")

    on_message = fn
      %{event: :session_started} ->
        File.write!(
          Path.join(worker_events, "assignment.test"),
          "OCTO_MSG/1 kind=assignment assignment=default-herdr-assignment deliverable=bounded\n"
        )

        File.write!(
          Path.join(worker_events, "result.test"),
          "OCTO_MSG/1 kind=result assignment=default-herdr-assignment status=completed\n"
        )

      _message ->
        :ok
    end

    assert {:ok, {next_session, turn}} =
             AgentRuntime.run_turn(
               session,
               "Complete the public native turn.",
               issue(),
               on_message: on_message
             )

    assert turn.response ==
             HerdrReplayFixture.stdout!("agent-read-recent")
             |> String.replace("{{WORKSPACE_CWD}}", workspace)

    assert [
             %{
               assignment_id: "default-herdr-assignment",
               status: :completed,
               evidence: :envelope,
               result: %{
                 assignment_id: "default-herdr-assignment",
                 status: "completed"
               }
             }
           ] = turn.worker_assignments

    assert :ok = AgentRuntime.stop_session(next_session)
  end

  test "AgentRuntime forwards local Claude auth only to Claude delegation participants without argv leakage" do
    previous_orchestrator_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker_provider = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")
    previous_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
    token = "delegation-oauth-secret-value"

    on_exit(fn ->
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_orchestrator_provider)
      restore_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker_provider)
      restore_env("CLAUDE_CODE_OAUTH_TOKEN", previous_token)
    end)

    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "claude_code")
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", token)

    assert {:ok, session} =
             AgentRuntime.start_session(
               "/tmp/selected-workspace",
               issue: issue(),
               role: "implementer",
               run_id: "claude-auth-env",
               delegation_transport: RecordingTransport,
               delegation_transport_context: %{owner: self()}
             )

    assert_receive {:transport, :default_server_snapshot}
    assert_receive {:transport, :start_session, session_spec}
    assert session_spec.env["CLAUDE_CODE_OAUTH_TOKEN"] == token

    assert_receive {:transport, :prepare_worker, _, worker_spec}
    assert worker_spec.env["CLAUDE_CODE_OAUTH_TOKEN"] == token
    refute inspect(worker_spec.argv) =~ token

    assert_receive {:transport, :start_agent, _, orchestrator_spec}
    assert orchestrator_spec.env["CLAUDE_CODE_OAUTH_TOKEN"] == token
    refute inspect(orchestrator_spec.argv) =~ token
    refute inspect(session.orchestrator) =~ token

    assert :ok = AgentRuntime.stop_session(session)
    assert_receive {:transport, :stop_session, _}
  end

  test "AgentRuntime does not forward local Claude auth to Codex delegation participants" do
    previous_orchestrator_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker_provider = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")
    previous_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
    token = "codex-must-not-receive-this-secret"

    on_exit(fn ->
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_orchestrator_provider)
      restore_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker_provider)
      restore_env("CLAUDE_CODE_OAUTH_TOKEN", previous_token)
    end)

    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "codex")
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", token)

    assert {:ok, session} =
             AgentRuntime.start_session(
               "/tmp/selected-workspace",
               issue: issue(),
               role: "implementer",
               run_id: "codex-no-claude-auth-env",
               delegation_transport: RecordingTransport,
               delegation_transport_context: %{owner: self()}
             )

    assert_receive {:transport, :default_server_snapshot}
    assert_receive {:transport, :start_session, session_spec}
    refute Map.has_key?(session_spec.env, "CLAUDE_CODE_OAUTH_TOKEN")
    refute inspect(session_spec) =~ token

    assert_receive {:transport, :prepare_worker, _, worker_spec}
    refute Map.has_key?(worker_spec.env, "CLAUDE_CODE_OAUTH_TOKEN")
    refute inspect(worker_spec) =~ token

    assert_receive {:transport, :start_agent, _, orchestrator_spec}
    refute Map.has_key?(orchestrator_spec.env, "CLAUDE_CODE_OAUTH_TOKEN")
    refute inspect(orchestrator_spec) =~ token

    assert :ok = AgentRuntime.stop_session(session)
    assert_receive {:transport, :stop_session, _}
  end

  test "default Herdr Adapter starts both worker providers through the native live-agent Interface" do
    root =
      Path.join(
        System.tmp_dir!(),
        "agent-runtime-native-workers-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "selected-product")
    fake_provider_bin = Path.join(root, "provider-bin")
    previous_orchestrator_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker_provider = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")
    previous_path = System.get_env("PATH") || ""
    previous_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
    previous_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)

    File.mkdir_p!(workspace)
    File.mkdir_p!(fake_provider_bin)

    for provider <- ["codex", "claude"] do
      path = Path.join(fake_provider_bin, provider)

      File.write!(path, """
      #!/bin/sh
      set -eu
      printf 'NATIVE_PROVIDER_EXEC agent=%s pane=%s path=%s args=%s claude_auth=%s\n' "$HERDR_FAKE_AGENT_NAME" "$HERDR_PANE_ID" "$PATH" "$*" "${CLAUDE_CODE_OAUTH_TOKEN:+present}" >> "$HERDR_FAKE_LOG"
      if [ "$HERDR_FAKE_AGENT_NAME" = "implementer_orchestrator" ]; then
        pane_json=$(herdr pane split --current --direction right --no-focus)
        pane_id=$(printf '%s\n' "$pane_json" | sed -n 's/.*"pane_id":"\\([^"]*\\)".*/\\1/p')
        [ -n "$pane_id" ]
        "$OCTO_HERDR_WORKER_LAUNCHER" implementer_worker "$pane_id"
      fi
      """)

      File.chmod!(path, 0o755)
    end

    Application.put_env(
      :symphony_elixir,
      :delegation_transport_module,
      SymphonyElixir.ImplementerDelegation.HerdrTransport
    )

    on_exit(fn ->
      if previous_orchestrator_provider,
        do: System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_orchestrator_provider),
        else: System.delete_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")

      if previous_worker_provider,
        do: System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker_provider),
        else: System.delete_env("OCTO_RUNTIME_WORKER_PROVIDER")

      System.put_env("PATH", previous_path)
      restore_env("CLAUDE_CODE_OAUTH_TOKEN", previous_token)
      Application.put_env(:symphony_elixir, :delegation_transport_module, previous_transport)
      File.rm_rf(root)
    end)

    for {provider, kind} <- [{"codex", "codex"}, {"claude_code", "claude"}] do
      System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", provider)
      System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", provider)
      System.put_env("PATH", fake_provider_bin <> ":" <> previous_path)

      if provider == "claude_code",
        do: System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "native-delegation-secret"),
        else: System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      herdr_bin = Path.join(root, "fake-herdr-#{kind}")
      herdr_log = Path.join(root, "herdr-#{kind}.log")

      runtime_root =
        Path.join(
          System.tmp_dir!(),
          "anw-#{kind}-#{System.unique_integer([:positive])}"
        )

      write_fake_herdr!(herdr_bin)

      assert {:ok, session} =
               HerdrSessionFixture.start_session(workspace,
                 issue: issue(),
                 role: "implementer",
                 run_id: "native-worker-#{kind}",
                 delegation_transport_context: %{
                   herdr_bin: herdr_bin,
                   extra_env: [
                     {"HERDR_FAKE_EXEC_PROVIDER", "1"},
                     {"HERDR_FAKE_LOG", herdr_log}
                   ],
                   socket_root: runtime_root,
                   poll_interval_ms: 5,
                   start_timeout_ms: 2_000
                 }
               )

      commands = File.read!(herdr_log)

      assert commands =~
               "--session #{session.name} agent start implementer_worker --kind #{kind} --pane w1:p2 --timeout 120000 --"

      assert commands =~ "NATIVE_PROVIDER_EXEC agent=implementer_worker pane=w1:p2"
      assert commands =~ "path=#{runtime_root}/worker-bin:#{fake_provider_bin}:"

      if provider == "claude_code" do
        assert commands =~ "claude_auth=present"
      else
        assert commands =~ "claude_auth="
        refute commands =~ "claude_auth=present"
      end

      refute commands =~ "native-delegation-secret"
      refute inspect(session.orchestrator) =~ "native-delegation-secret"
      assert :ok = AgentRuntime.stop_session(session)
      File.rm_rf(runtime_root)
    end
  end

  test "a native prompt stall cannot complete a turn" do
    session = %{
      transport: PromptStallTransport,
      transport_context: %{owner: self()},
      herdr_session: %{name: "octo-emb-1141-fast"},
      orchestrator: %{name: "implementer_orchestrator", pane_id: "w1:p1"}
    }

    assert {:error, {:herdr_agent_prompt_stalled, "implementer_orchestrator"}} =
             ImplementerDelegation.run_turn(
               session,
               "Complete immediately.",
               %{identifier: "EMB-1141"},
               start_timeout_ms: 25
             )

    assert_receive {:prompt_stall, :begin_turn, _agent}
    refute_receive {:prompt_stall, :read_agent}
  end

  test "long working turns emit bounded heartbeats while awaiting semantic completion" do
    Process.delete({HeartbeatTransport, :attempt})

    session = %{
      transport: HeartbeatTransport,
      transport_context: %{},
      contract: %{provider: "codex"},
      herdr_session: %{name: "octo-emb-1141-heartbeat"},
      orchestrator: %{name: "implementer_orchestrator", pane_id: "w1:p1"}
    }

    assert {:ok, %{response: "HEARTBEAT_COMPLETE"}} =
             ImplementerDelegation.run_turn(
               session,
               "Complete a long bounded assignment.",
               %{identifier: "EMB-1141"},
               heartbeat_interval_ms: 1,
               turn_timeout_ms: 100,
               on_message: fn message -> send(self(), {:runtime_message, message}) end
             )

    assert_receive {:runtime_message, %{event: :turn_heartbeat, agent_status: "working"}}
    assert_receive {:runtime_message, %{event: :turn_heartbeat, agent_status: "working"}}
    assert_receive {:runtime_message, %{event: :turn_completed}}
  end

  test "Claude terminal authentication failures fail the delegated turn closed" do
    session = %{
      transport: ClaudeAuthFailureTransport,
      transport_context: %{},
      contract: %{provider: "claude_code"},
      herdr_session: %{name: "octo-emb-1180-auth"},
      orchestrator: %{name: "implementer_orchestrator", pane_id: "w1:p1"}
    }

    assert {:error, {:auth_failed, %{api_error_status: 401, subtype: "invalid_authentication_credentials"}}} =
             ImplementerDelegation.run_turn(
               session,
               "Implement the bounded issue.",
               %{identifier: "EMB-1180"},
               turn_timeout_ms: 100
             )
  end

  defp write_fake_herdr!(path) do
    replay_dir = Path.join(Path.dirname(path), "herdr-replay-#{System.unique_integer([:positive])}")
    HerdrReplayFixture.materialize_replay_dir!(replay_dir)
    HerdrReplayFixture.write_fake_herdr!(path, replay_dir)
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
      branch_name: "sebastianvarela/emb-1141-exercise-the-public-runtime-seam",
      url: "https://linear.app/emberai/issue/EMB-1141",
      repository: "EmberAGI/scaling-octo-engine",
      repository_source: "linear_label",
      labels: ["implementation-effort:moderate"]
    }
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp codex_argv(profile, workspace, herdr_session) do
    runtime_root = herdr_session.runtime_root
    socket = herdr_session.socket

    read_roots =
      [runtime_root | Map.get(herdr_session, :permission_read_roots, [])]
      |> Enum.uniq()
      |> Enum.map_join(",", &"#{inspect(&1)}=\"read\"")

    filesystem_permission =
      ~s|permissions.octo_herdr.filesystem={":minimal"="read",":workspace_roots"={"."="write",".git"="write"},| <>
        ~s|#{read_roots},#{inspect(Path.join(runtime_root, "worker-events"))}="write"}|

    [
      "codex",
      "--model",
      profile.model,
      "--config",
      "check_for_update_on_startup=false",
      "--config",
      "model_reasoning_effort=#{profile.reasoning_effort}",
      "--config",
      "developer_instructions=#{inspect(profile.instructions)}",
      "--config",
      "shell_environment_policy.inherit=all",
      "--config",
      "default_permissions=\"octo_herdr\"",
      "--config",
      filesystem_permission,
      "--config",
      "permissions.octo_herdr.network={enabled=true,unix_sockets={#{inspect(socket)}=\"allow\"}}",
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
