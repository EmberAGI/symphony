defmodule SymphonyElixir.AgentRuntimeHostResourcesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentRuntime, HostResourceContract, ImplementationEffort, ImplementerDelegation}
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer

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
               runtime_generation: 7,
               delegation_transport: LaunchProbeTransport,
               delegation_transport_context: %{owner: self()}
             )

    refute_received :host_resource_launch_started
  end

  test "AgentRuntime rejects unsafe local roots and remote materialization before launch" do
    fixture = host_resource_fixture()
    verification_path = ["operations", "symphony_runtime_verification"]
    tool_config_sha256 = fixture.context[:tool_config_sha256]
    shims_dir = Path.join(fixture.root, "shims")
    shim = Path.join(shims_dir, "mise")

    install_alias =
      Path.join([
        fixture.root,
        "alias",
        "installs",
        "elixir",
        Path.basename(fixture.elixir_install)
      ])

    File.mkdir_p!(shims_dir)
    File.mkdir_p!(Path.dirname(install_alias))
    File.ln_s!(fixture.mise_target, shim)
    File.ln_s!(fixture.elixir_install, install_alias)

    replace_tool_config = fn path ->
      fixture.declaration
      |> put_in(verification_path ++ ["tool_config"], path)
      |> put_in(verification_path ++ ["tool_config_sha256"], tool_config_sha256)
    end

    invalid_cases = [
      {replace_tool_config.("/"), [tool_config_path: "/"]},
      {replace_tool_config.(System.user_home!()), [tool_config_path: System.user_home!()]},
      {replace_tool_config.(Path.join(fixture.root, "nested/../mise.toml")), [tool_config_path: Path.join(fixture.root, "nested/../mise.toml")]},
      {put_in(fixture.declaration, verification_path ++ ["mise", "executable"], shim), []},
      {fixture.declaration
       |> put_in(verification_path ++ ["mise", "executable"], Path.dirname(fixture.mise_target))
       |> put_in(verification_path ++ ["mise", "target"], Path.dirname(fixture.mise_target)), []},
      {put_in(
         fixture.declaration,
         verification_path ++ ["elixir", "install_path"],
         Path.dirname(fixture.elixir_install)
       ), []},
      {put_in(
         fixture.declaration,
         verification_path ++ ["elixir", "install_path"],
         install_alias
       ), []},
      {fixture.declaration, [worker_host: "remote-worker"]}
    ]

    issue = %Issue{
      id: "host-resource-unsafe-roots",
      identifier: "TUR-877-UNSAFE-ROOTS",
      title: "Host resource unsafe roots",
      repository: "EmberAGI/symphony"
    }

    for {declaration, extra_opts} <- invalid_cases do
      opts =
        [
          issue: issue,
          role: "implementer",
          run_id: "host-resource-unsafe-roots",
          host_resources: declaration,
          execution_generation: fixture.context[:execution_generation],
          runtime_generation: fixture.context[:runtime_generation],
          source_ref: fixture.context[:source_ref],
          tool_config_path: fixture.context[:tool_config_path],
          tool_config_sha256: tool_config_sha256,
          delegation_transport: LaunchProbeTransport,
          delegation_transport_context: %{owner: self()}
        ]
        |> Keyword.merge(extra_opts)

      assert {:error, {:invalid_host_resource_contract, _details}} =
               AgentRuntime.start_session("/tmp/selected-workspace", opts)
    end

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

  test "ordinary Codex receives host runtime reads with no skills" do
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

  test "ordinary Codex enables declared DNS with no skills" do
    resolver_target = "/run/systemd/resolve/stub-resolv.conf"

    host_resources = %HostResourceContract{
      operations: %{"host_dns" => %{"resolver_target" => resolver_target}},
      read_paths: [resolver_target]
    }

    assert {:ok, command} =
             CodexAppServer.project_skill_permissions_for_test(
               "codex app-server",
               [],
               host_resources
             )

    assert command =~ "#{inspect(resolver_target)}=\"read\""
    assert command =~ "permissions.symphony_skill_runtime.network={enabled=true}"
  end

  test "normal AgentRuntime startup derives independent provenance from its locked Workflow source" do
    fixture = host_resource_fixture()
    source_root = Path.dirname(fixture.context[:tool_config_path])
    workflow_file = Path.join(source_root, "WORKFLOW.md")
    workspace_root = Path.join(source_root, "workspaces")
    workspace = Path.join(workspace_root, "TUR-877-NORMAL-START")
    fake_codex = Path.join(source_root, "fake-codex")
    trace = Path.join(source_root, "normal-start.trace")
    File.mkdir_p!(workspace)

    File.write!(fake_codex, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace}"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"host-resource-normal-start"}}}' ;;
      esac
    done
    """)

    File.chmod!(fake_codex, 0o755)
    File.ln_s!("/bin/bash", Path.join(source_root, "bash"))
    System.cmd("git", ["init", "-q", "-b", "main", source_root])
    System.cmd("git", ["-C", source_root, "add", "mise.toml"])

    {_, 0} =
      System.cmd("git", [
        "-C",
        source_root,
        "-c",
        "user.name=Symphony Test",
        "-c",
        "user.email=symphony-test@example.invalid",
        "commit",
        "-q",
        "-m",
        "locked source"
      ])

    {source_ref, 0} = System.cmd("git", ["-C", source_root, "rev-parse", "HEAD"])
    source_ref = String.trim(source_ref)

    declaration =
      fixture.declaration
      |> Map.put("role", "reviewer")
      |> put_in(
        ["operations", "symphony_runtime_verification", "symphony_ref"],
        source_ref
      )

    write_workflow_file!(workflow_file,
      workspace_root: workspace_root,
      codex_command: "#{fake_codex} app-server",
      agent_runtime_host_resources: declaration
    )

    Workflow.set_workflow_file_path(workflow_file)
    previous_generation = System.get_env("OCTO_RUNTIME_CONFIG_GENERATION")
    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_path = System.get_env("PATH")
    previous_home = System.get_env("HOME")
    System.put_env("OCTO_RUNTIME_CONFIG_GENERATION", "7")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    System.put_env("PATH", source_root)
    System.put_env("HOME", Path.join(source_root, "unrelated-home"))

    on_exit(fn ->
      restore_env("OCTO_RUNTIME_CONFIG_GENERATION", previous_generation)
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider)
      restore_env("PATH", previous_path)
      restore_env("HOME", previous_home)
    end)

    issue = %Issue{
      id: "host-resource-normal-start",
      identifier: "TUR-877-NORMAL-START",
      title: "Normal host resource startup",
      repository: "EmberAGI/symphony",
      repository_source: "linear_label",
      labels: ["implementation-effort:moderate"]
    }

    assert {:ok, session} =
             AgentRuntime.start_session(workspace,
               issue: issue,
               role: "reviewer",
               execution_generation: "exec-20260906"
             )

    assert session.host_resource_contract.provenance.symphony_ref == source_ref
    assert File.read!(trace) =~ "default_permissions=symphony_skill_runtime"
    assert :ok = AgentRuntime.stop_session(session)
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

  test "concurrent AgentRuntime sessions retain distinct versions with sparse ambient context" do
    first = host_resource_fixture(role: "reviewer")

    second =
      host_resource_fixture(
        elixir_version: "1.18.4-otp-27",
        erlang_version: "27.3",
        runtime_generation: 8,
        source_ref: String.duplicate("b", 40),
        role: "reviewer"
      )

    root = Path.join(System.tmp_dir!(), "host-resource-concurrent-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    fake_codex = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace_root)
    File.ln_s!("/bin/bash", Path.join(root, "bash"))

    File.write!(fake_codex, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"host-resource-concurrent"}}}' ;;
      esac
    done
    """)

    File.chmod!(fake_codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{fake_codex} app-server"
    )

    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_home = System.get_env("HOME")
    previous_path = System.get_env("PATH")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    System.put_env("HOME", Path.join(root, "unrelated-home"))
    System.put_env("PATH", root)

    on_exit(fn ->
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider)
      restore_env("HOME", previous_home)
      restore_env("PATH", previous_path)
      File.rm_rf!(root)
    end)

    parent = self()

    start = fn tag, fixture ->
      workspace = Path.join(workspace_root, "TUR-877-#{tag}")
      File.mkdir_p!(workspace)

      issue = %Issue{
        id: "host-resource-#{tag}",
        identifier: "TUR-877-#{tag}",
        title: "Concurrent host resource #{tag}",
        repository: "EmberAGI/symphony",
        repository_source: "linear_label",
        labels: ["implementation-effort:moderate"]
      }

      Task.async(fn ->
        assert {:ok, session} =
                 AgentRuntime.start_session(workspace,
                   issue: issue,
                   role: "reviewer",
                   host_resources: fixture.declaration,
                   execution_generation: fixture.context[:execution_generation],
                   runtime_generation: fixture.context[:runtime_generation],
                   source_ref: fixture.context[:source_ref],
                   tool_config_path: fixture.context[:tool_config_path],
                   tool_config_sha256: fixture.context[:tool_config_sha256]
                 )

        send(parent, {:host_resource_session, tag, session.host_resource_contract})

        receive do
          :stop -> AgentRuntime.stop_session(session)
        end
      end)
    end

    first_task = start.("FIRST", first)
    second_task = start.("SECOND", second)

    assert_receive {:host_resource_session, "FIRST", first_contract}, 5_000
    assert_receive {:host_resource_session, "SECOND", second_contract}, 5_000

    assert first_contract.operations["symphony_runtime_verification"]["elixir"].version ==
             "1.19.5-otp-28"

    assert second_contract.operations["symphony_runtime_verification"]["elixir"].version ==
             "1.18.4-otp-27"

    refute Enum.any?(first_contract.read_paths, &String.starts_with?(&1, second.root <> "/"))
    refute Enum.any?(second_contract.read_paths, &String.starts_with?(&1, first.root <> "/"))

    send(first_task.pid, :stop)
    send(second_task.pid, :stop)
    assert :ok = Task.await(first_task)
    assert :ok = Task.await(second_task)
  end

  test "direct entrypoints cannot bypass raw declaration validation with a typed-looking option" do
    refute function_exported?(CodexAppServer, :start_resolved_session, 3)
    refute function_exported?(ImplementerDelegation, :start_resolved_session, 4)

    invalid_declaration = %{"unexpected" => true}
    typed_looking = %HostResourceContract{}

    assert {:error, {:invalid_host_resource_contract, %{resource: :declaration, reason: :invalid_fields}}} =
             CodexAppServer.start_session(
               "/tmp/selected-workspace",
               host_resources: invalid_declaration,
               resolved_host_resource_contract: typed_looking
             )

    issue = %Issue{
      id: "host-resource-no-bypass",
      identifier: "TUR-877-NO-BYPASS",
      labels: ["implementation-effort:moderate"]
    }

    assert {:ok, runtime_contract} =
             ImplementationEffort.runtime_profile_for_issue(:codex, issue, "implementer")

    assert {:error, {:invalid_host_resource_contract, %{resource: :declaration, reason: :invalid_fields}}} =
             ImplementerDelegation.start_session(
               "/tmp/selected-workspace",
               runtime_contract,
               issue_identifier: issue.identifier,
               run_id: "host-resource-no-bypass",
               host_resources: invalid_declaration,
               resolved_host_resource_contract: typed_looking,
               transport: LaunchProbeTransport,
               transport_context: %{owner: self()}
             )

    refute_received :host_resource_launch_started
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
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "codex")

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

    assert worker_spec.provider == "codex"
    assert worker_spec.env["SYMPHONY_HOST_RESOURCE_CONTRACT"] != nil
    assert Enum.any?(worker_spec.argv, &String.contains?(&1, "permissions.octo_herdr"))

    assert orchestrator_spec.provider == "claude_code"
    assert orchestrator_spec.env["SYMPHONY_HOST_RESOURCE_CONTRACT"] != nil
    refute Enum.any?(orchestrator_spec.argv, &String.contains?(&1, "permissions.octo_herdr"))
    refute Enum.any?(orchestrator_spec.argv, &String.contains?(&1, "gateway"))

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
               host_resources: declaration,
               runtime_generation: 7
             )
  end

  defp host_resource_fixture(opts \\ []) do
    elixir_version = Keyword.get(opts, :elixir_version, "1.19.5-otp-28")
    erlang_version = Keyword.get(opts, :erlang_version, "28.5")
    runtime_generation = Keyword.get(opts, :runtime_generation, 7)
    source_ref = Keyword.get(opts, :source_ref, String.duplicate("a", 40))
    role = Keyword.get(opts, :role, "implementer")
    root = Path.join(System.tmp_dir!(), "host-resource-launch-#{System.unique_integer([:positive])}")
    tool_config = Path.join(root, "mise.toml")
    mise_bin = Path.join([root, "mise", "bin", "mise"])
    mise_target = Path.join([root, "mise", "targets", "mise-2026.09"])
    elixir_install = Path.join([root, "mise", "installs", "elixir", elixir_version])
    erlang_install = Path.join([root, "mise", "installs", "erlang", erlang_version])

    File.mkdir_p!(Path.dirname(mise_bin))
    File.mkdir_p!(Path.dirname(mise_target))
    File.mkdir_p!(Path.join(elixir_install, "bin"))
    File.mkdir_p!(Path.join(erlang_install, "bin"))
    erlang_major = erlang_version |> String.split(".", parts: 2) |> hd()
    File.write!(tool_config, "[tools]\nerlang = \"#{erlang_major}\"\nelixir = \"#{elixir_version}\"\n")
    File.write!(mise_target, "#!/bin/sh\nexit 0\n")
    File.ln_s!(mise_target, mise_bin)
    File.write!(Path.join(elixir_install, "bin/elixir"), "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(erlang_install, "bin/erl"), "#!/bin/sh\nexit 0\n")

    File.chmod!(mise_target, 0o755)
    File.chmod!(Path.join(elixir_install, "bin/elixir"), 0o755)
    File.chmod!(Path.join(erlang_install, "bin/erl"), 0o755)

    declaration = %{
      "schema_version" => 1,
      "role" => role,
      "execution_generation" => "exec-20260906",
      "runtime_generation" => runtime_generation,
      "operations" => %{
        "symphony_runtime_verification" => %{
          "symphony_ref" => source_ref,
          "tool_config" => tool_config,
          "tool_config_sha256" => digest(tool_config),
          "mise" => %{
            "executable" => mise_bin,
            "target" => mise_target,
            "sha256" => digest(mise_target)
          },
          "elixir" => %{
            "version" => elixir_version,
            "install_path" => elixir_install
          },
          "erlang" => %{
            "version" => erlang_version,
            "install_path" => erlang_install
          }
        }
      }
    }

    context = [
      role: role,
      execution_generation: "exec-20260906",
      runtime_generation: runtime_generation,
      source_ref: source_ref,
      tool_config_path: tool_config,
      tool_config_sha256: declaration["operations"]["symphony_runtime_verification"]["tool_config_sha256"]
    ]

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      declaration: declaration,
      context: context,
      root: root,
      mise_target: mise_target,
      elixir_install: elixir_install
    }
  end

  defp digest(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
