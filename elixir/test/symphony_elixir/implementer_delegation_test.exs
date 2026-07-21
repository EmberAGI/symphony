defmodule SymphonyElixir.ImplementerDelegationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentRuntime, ImplementationEffort, ImplementerDelegation, SkillExecutionContract}
  alias SymphonyElixir.Linear.Issue

  defmodule RecordingTransport do
    def default_server_snapshot(%{owner: owner}) do
      send(owner, {:transport, :default_server_snapshot})
      {:ok, %{status: "running", version: "0.7.4", protocol: 16, socket: "/tmp/operator-default/herdr.sock"}}
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

    def submit(session, agent, prompt, %{owner: owner}) do
      send(owner, {:transport, :submit, session, agent, prompt})
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

  defmodule HeartbeatTransport do
    def submit(_session, _agent, _prompt, _context), do: :ok

    def await_agent(_session, agent, ["working"], _timeout_ms, _context) do
      {:ok, %{name: agent.name, agent_status: "working", agent_session: nil}}
    end

    def await_agent(_session, agent, ["idle", "done"], _timeout_ms, _context) do
      attempt = Process.get({__MODULE__, :attempt}, 0) + 1
      Process.put({__MODULE__, :attempt}, attempt)

      if attempt < 3 do
        {:error, {:herdr_agent_status_timeout, agent.name, ["done", "idle"]}}
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

    def await_agent(_session, agent, ["idle", "done"], _timeout_ms, _context) do
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

    assert_receive {:transport, :await_agent, _, _, ["idle", "done"], 30_000}
    assert session.orchestrator.name == "implementer_orchestrator"
    assert session.contract == contract
    assert session.default_server_before.socket == "/tmp/operator-default/herdr.sock"

    ownership_ref = AgentRuntime.owned_session_ref(session)
    assert ownership_ref.kind == "recording"
    assert ownership_ref.session_name == "octo-emb-1141-run-7"
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

    assert_receive {:transport, :begin_turn, %{name: "octo-emb-1141-run-7"}, %{name: "implementer_orchestrator"}, "Implement the bounded tracer task.", 30_000}

    refute_receive {:transport, :submit, _, _, _}
    assert_receive {:transport, :await_agent, _, _, ["idle", "done"], 30_000}
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

    assert Map.delete(orchestrator_spec.env, "PATH") == %{
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

    assert_receive {:transport, :await_agent, _, _, ["idle", "done"], 30_000}

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
    assert_receive {:transport, :await_agent, _, _, ["idle", "done"], 30_000}

    assert :ok = AgentRuntime.stop_session(claude_session)
    assert_receive {:transport, :stop_session, _}
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

  defp codex_argv(profile, workspace, herdr_session) do
    runtime_root = herdr_session.runtime_root
    socket = herdr_session.socket

    read_roots =
      [runtime_root | Map.get(herdr_session, :permission_read_roots, [])]
      |> Enum.uniq()
      |> Enum.map_join(",", &"#{inspect(&1)}=\"read\"")

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
      "permissions.octo_herdr.filesystem={\":minimal\"=\"read\",\":workspace_roots\"={\".\"=\"write\",\".git\"=\"write\"},#{read_roots}}",
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
