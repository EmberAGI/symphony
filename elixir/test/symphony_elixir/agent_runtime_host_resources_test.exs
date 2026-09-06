defmodule SymphonyElixir.AgentRuntimeHostResourcesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentRuntime, ImplementationEffort, ImplementerDelegation}

  defmodule LaunchProbeTransport do
    def default_server_snapshot(%{owner: owner}) do
      send(owner, :host_resource_launch_started)
      {:error, :must_not_launch}
    end
  end

  defmodule ProjectionTransport do
    def default_server_snapshot(%{owner: owner}) do
      send(owner, {:host_resource_transport, :default_server_snapshot})
      {:ok, %{status: "running", version: "0.8.2", protocol: 20, socket: "/tmp/default/herdr.sock"}}
    end

    def start_session(spec, %{owner: owner}) do
      send(owner, {:host_resource_transport, :start_session, spec})

      {:ok,
       %{
         name: spec.name,
         socket: "/tmp/#{spec.name}/herdr.sock",
         runtime_root: "/tmp/#{spec.name}"
       }}
    end

    def prepare_worker(session, spec, %{owner: owner}) do
      send(owner, {:host_resource_transport, :prepare_worker, session, spec})

      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}
    end

    def start_agent(session, spec, %{owner: owner}) do
      send(owner, {:host_resource_transport, :start_agent, session, spec})
      {:ok, %{name: spec.name, pane_id: "w1:p1", profile: spec.profile}}
    end

    def stop_session(session, %{owner: owner}) do
      send(owner, {:host_resource_transport, :stop_session, session})
      :ok
    end
  end

  test "AgentRuntime rejects host resources before entering the Implementer launch path" do
    issue = %Issue{
      id: "host-resource-launch-guard",
      identifier: "TUR-877",
      title: "Host resource launch guard",
      repository: "EmberAGI/symphony"
    }

    declaration = %{
      "schema_version" => 1,
      "role" => "implementer",
      "execution_generation" => "exec-20260906",
      "runtime_generation" => 7,
      "operations" => %{
        "host_dns" => %{"resolver_target" => "/etc/resolv.conf"}
      }
    }

    assert {:error, {:invalid_host_resource_contract, %{resource: :execution_generation, reason: :missing_context}}} =
             AgentRuntime.start_session(
               "/tmp/selected-workspace",
               issue: issue,
               role: "implementer",
               run_id: "host-resource-launch-guard",
               host_resources: declaration,
               delegation_transport: LaunchProbeTransport,
               delegation_transport_context: %{owner: self()}
             )

    refute_received :host_resource_launch_started
  end

  test "direct ImplementerDelegation revalidates raw host resources before transport snapshot" do
    issue = %Issue{
      id: "host-resource-direct-guard",
      identifier: "TUR-877-DIRECT",
      title: "Host resource direct guard",
      labels: ["implementation-effort:moderate"]
    }

    assert {:ok, runtime_contract} =
             ImplementationEffort.runtime_profile_for_issue(:codex, issue, "implementer")

    declaration = %{
      "schema_version" => 1,
      "role" => "implementer",
      "execution_generation" => "exec-20260906",
      "runtime_generation" => 7,
      "operations" => %{
        "host_dns" => %{"resolver_target" => "/etc/resolv.conf"}
      }
    }

    assert {:error, {:invalid_host_resource_contract, %{resource: :role, reason: :missing_context}}} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               runtime_contract,
               issue_identifier: "TUR-877-DIRECT",
               run_id: "host-resource-direct-guard",
               host_resources: declaration,
               transport: LaunchProbeTransport,
               transport_context: %{owner: self()}
             )

    refute_received :host_resource_launch_started
  end

  test "direct Codex AppServer revalidates raw host resources before workspace or port launch" do
    declaration = %{
      "schema_version" => 1,
      "role" => "reviewer",
      "execution_generation" => "exec-20260906",
      "runtime_generation" => 7,
      "operations" => %{
        "host_dns" => %{"resolver_target" => "/etc/resolv.conf"}
      }
    }

    assert {:error, {:invalid_host_resource_contract, %{resource: :role, reason: :missing_context}}} =
             AppServer.start_session(
               "/tmp/not-a-workspace",
               host_resources: declaration,
               issue: %Issue{identifier: "TUR-877-CODEX"}
             )
  end

  test "ordinary Codex receives host reads without changing its network projection" do
    fixture = host_resource_fixture()
    root = Path.join(System.tmp_dir!(), "host-resource-codex-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "TUR-877-CODEX-PROJECT")
    fake_codex = Path.join(root, "fake-codex")
    trace = Path.join(root, "codex.trace")
    File.mkdir_p!(workspace)

    File.write!(fake_codex, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace}"
    printf 'HOST_RESOURCE:%s\\n' "${SYMPHONY_HOST_RESOURCE_CONTRACT}" >> "#{trace}"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"host-resource-thread"}}}' ;;
      esac
    done
    """)

    File.chmod!(fake_codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{fake_codex} app-server"
    )

    issue = %Issue{identifier: "TUR-877-CODEX-PROJECT", labels: ["implementation-effort:moderate"]}

    assert {:ok, session} =
             AppServer.start_session(
               workspace,
               issue: issue,
               role: "implementer",
               issue_bootstrap_env: :no_role_bootstrap,
               host_resources: fixture.declaration,
               execution_generation: "exec-20260906",
               runtime_generation: 7,
               source_ref: String.duplicate("a", 40),
               tool_config_path: fixture.context[:tool_config_path],
               tool_config_sha256: fixture.context[:tool_config_sha256]
             )

    trace_contents = File.read!(trace)

    for path <- session.host_resource_contract.read_paths do
      assert trace_contents =~ "#{inspect(path)}=\"read\""
    end

    ["HOST_RESOURCE:" <> encoded] =
      trace_contents
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "HOST_RESOURCE:"))

    expected_commands =
      Map.new(session.host_resource_contract.commands, fn {name, command} ->
        {Atom.to_string(name), command}
      end)

    decoded = Jason.decode!(encoded)
    assert decoded["commands"] == expected_commands
    assert decoded["operations"] == fixture.declaration["operations"]
    refute trace_contents =~ "permissions.symphony_skill_runtime.network"
    assert :ok = AppServer.stop_session(session)
    on_exit(fn -> File.rm_rf!(root) end)
  end

  test "one resolved host contract projects exact reads to both Codex Herdr participants" do
    fixture = host_resource_fixture()
    issue = %Issue{id: "host-resource-projection", identifier: "TUR-877-PROJECT", labels: ["implementation-effort:moderate"]}

    assert {:ok, runtime_contract} =
             ImplementationEffort.runtime_profile_for_issue(:codex, issue, "implementer")

    assert {:ok, resolved} =
             SymphonyElixir.HostResourceContract.resolve(fixture.declaration, fixture.context)

    assert {:ok, session} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               runtime_contract,
               issue_identifier: issue.identifier,
               run_id: "host-resource-projection",
               host_resources: fixture.declaration,
               role: "implementer",
               execution_generation: "exec-20260906",
               runtime_generation: 7,
               source_ref: String.duplicate("a", 40),
               tool_config_path: fixture.context[:tool_config_path],
               tool_config_sha256: fixture.context[:tool_config_sha256],
               transport: ProjectionTransport,
               transport_context: %{owner: self()}
             )

    assert_receive {:host_resource_transport, :prepare_worker, herdr_session, worker_spec}
    assert_receive {:host_resource_transport, :start_agent, _, orchestrator_spec}

    assert herdr_session.host_resource_contract == resolved

    for path <- resolved.read_paths do
      assert path in herdr_session.permission_read_roots
      assert Enum.any?(worker_spec.argv, &String.contains?(&1, "#{inspect(path)}=\"read\""))
      assert Enum.any?(orchestrator_spec.argv, &String.contains?(&1, "#{inspect(path)}=\"read\""))
    end

    encoded = SymphonyElixir.HostResourceContract.encode!(resolved)
    assert worker_spec.env["SYMPHONY_HOST_RESOURCE_CONTRACT"] == encoded
    assert orchestrator_spec.env["SYMPHONY_HOST_RESOURCE_CONTRACT"] == encoded

    expected_commands =
      Map.new(resolved.commands, fn {name, command} ->
        {Atom.to_string(name), command}
      end)

    decoded_contracts =
      Enum.map([worker_spec, orchestrator_spec], fn spec ->
        Jason.decode!(spec.env["SYMPHONY_HOST_RESOURCE_CONTRACT"])
      end)

    assert Enum.map(decoded_contracts, & &1["commands"]) ==
             List.duplicate(expected_commands, 2)

    assert Enum.map(decoded_contracts, & &1["operations"]) ==
             List.duplicate(fixture.declaration["operations"], 2)

    refute encoded =~ "secret"

    assert :ok = ImplementerDelegation.stop_session(session)
    assert_receive {:host_resource_transport, :stop_session, _}
  end

  test "mixed Claude Implementer validation adds no Claude host permission or gateway mode" do
    fixture = host_resource_fixture()

    issue = %Issue{
      id: "host-resource-claude",
      identifier: "TUR-877-CLAUDE",
      repository: "EmberAGI/symphony",
      labels: ["implementation-effort:moderate"]
    }

    previous_orchestrator_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker_provider = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")

    on_exit(fn ->
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_orchestrator_provider)
      restore_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker_provider)
    end)

    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "claude_code")

    assert {:ok, session} =
             AgentRuntime.start_session(
               "/tmp/selected-workspace",
               issue: issue,
               role: "implementer",
               run_id: "host-resource-claude",
               host_resources: fixture.declaration,
               execution_generation: "exec-20260906",
               runtime_generation: 7,
               source_ref: String.duplicate("a", 40),
               tool_config_path: fixture.context[:tool_config_path],
               tool_config_sha256: fixture.context[:tool_config_sha256],
               delegation_transport: ProjectionTransport,
               delegation_transport_context: %{owner: self()}
             )

    assert_receive {:host_resource_transport, :prepare_worker, _, worker_spec}
    assert_receive {:host_resource_transport, :start_agent, _, orchestrator_spec}

    for spec <- [worker_spec, orchestrator_spec] do
      assert spec.provider == "claude_code"
      assert spec.env["SYMPHONY_HOST_RESOURCE_CONTRACT"] != nil
      refute Enum.any?(spec.argv, &String.contains?(&1, "permissions.octo_herdr"))
      refute Enum.any?(spec.argv, &String.contains?(&1, "gateway"))
    end

    assert Enum.map([worker_spec, orchestrator_spec], fn spec ->
             spec.env["SYMPHONY_HOST_RESOURCE_CONTRACT"]
             |> Jason.decode!()
             |> Map.fetch!("operations")
           end) == List.duplicate(fixture.declaration["operations"], 2)

    assert :ok = ImplementerDelegation.stop_session(session)
    assert_receive {:host_resource_transport, :stop_session, _}
  end

  test "ordinary Claude rejects host resources before session setup" do
    root = Path.join(System.tmp_dir!(), "host-resource-claude-ordinary-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "TUR-877-CLAUDE-ORDINARY")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_runtime_provider: "claude_code",
      claude_code_command: "/bin/true",
      claude_code_model: "sonnet"
    )

    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")

    on_exit(fn ->
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider)
      File.rm_rf!(root)
    end)

    issue = %Issue{
      id: "host-resource-claude-ordinary",
      identifier: "TUR-877-CLAUDE-ORDINARY",
      repository: "EmberAGI/symphony",
      repository_source: "linear_label",
      labels: ["implementation-effort:moderate"]
    }

    declaration = %{
      "schema_version" => 1,
      "role" => "reviewer",
      "execution_generation" => "exec-20260906",
      "runtime_generation" => 7,
      "operations" => %{"host_dns" => %{"resolver_target" => "/etc/resolv.conf"}}
    }

    assert {:error, {:invalid_host_resource_contract, %{resource: :execution_generation, reason: :missing_context}}} =
             AgentRuntime.start_session(workspace,
               issue: issue,
               role: "reviewer",
               host_resources: declaration
             )
  end

  defp host_resource_fixture do
    root = Path.join(System.tmp_dir!(), "host-resource-launch-#{System.unique_integer([:positive])}")
    tool_config = Path.join(root, "mise.toml")
    mise_bin = Path.join([root, "mise", "bin", "mise"])
    mise_target = Path.join([root, "mise", "targets", "mise-2026.09"])
    elixir_install = Path.join([root, "mise", "installs", "elixir", "1.19.5-otp-28"])
    erlang_install = Path.join([root, "mise", "installs", "erlang", "28.5"])

    File.mkdir_p!(Path.dirname(mise_bin))
    File.mkdir_p!(Path.dirname(mise_target))
    File.mkdir_p!(Path.join(elixir_install, "bin"))
    File.mkdir_p!(Path.join(erlang_install, "bin"))
    File.write!(tool_config, "[tools]\nerlang = \"28\"\nelixir = \"1.19.5-otp-28\"\n")
    File.write!(mise_target, "#!/bin/sh\nexit 0\n")
    File.ln_s!(mise_target, mise_bin)
    File.write!(Path.join(elixir_install, "bin/elixir"), "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(erlang_install, "bin/erl"), "#!/bin/sh\nexit 0\n")

    File.chmod!(mise_target, 0o755)
    File.chmod!(Path.join(elixir_install, "bin/elixir"), 0o755)
    File.chmod!(Path.join(erlang_install, "bin/erl"), 0o755)

    declaration = %{
      "schema_version" => 1,
      "role" => "implementer",
      "execution_generation" => "exec-20260906",
      "runtime_generation" => 7,
      "operations" => %{
        "symphony_runtime_verification" => %{
          "symphony_ref" => String.duplicate("a", 40),
          "tool_config" => tool_config,
          "tool_config_sha256" => digest(tool_config),
          "mise" => %{
            "executable" => mise_bin,
            "target" => mise_target,
            "sha256" => digest(mise_target)
          },
          "elixir" => %{
            "version" => "1.19.5-otp-28",
            "install_path" => elixir_install
          },
          "erlang" => %{
            "version" => "28.5",
            "install_path" => erlang_install
          }
        }
      }
    }

    context = [
      role: "implementer",
      execution_generation: "exec-20260906",
      runtime_generation: 7,
      source_ref: String.duplicate("a", 40),
      tool_config_path: tool_config,
      tool_config_sha256: declaration["operations"]["symphony_runtime_verification"]["tool_config_sha256"]
    ]

    on_exit(fn -> File.rm_rf!(root) end)
    %{declaration: declaration, context: context}
  end

  defp digest(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
