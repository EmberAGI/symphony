defmodule SymphonyElixir.HostResourceRealSandboxTest do
  @moduledoc """
  TUR-877 opt-in acceptance proof for the actual installed Codex sandbox.

  This test crosses the public Implementer delegation Interface to obtain the
  ordinary generated Codex permission projection, then runs `codex sandbox`
  directly. It makes no model request. The operator supplies only the
  exact installed resources and two existing negative-read probes; the
  production consumer still validates every declared path, digest, version,
  generation, and source value before the sandbox command can run.

  Opt in with `RUN_TUR877_HOST_RESOURCE_SANDBOX=1` and the required
  `TUR877_*` paths named by `required_env!/1` below.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentRuntime, HostResourceContract}
  alias SymphonyElixir.Linear.Issue

  @moduletag :host_resource_real_sandbox
  @moduletag timeout: 120_000

  defmodule CaptureTransport do
    @moduledoc false

    def default_server_snapshot(_context),
      do: {:ok, %{status: "running", version: "0.8.2", protocol: 20, socket: "/tmp/default/herdr.sock"}}

    def start_session(spec, %{runtime_root: runtime_root}) do
      {:ok,
       %{
         name: spec.name,
         socket: Path.join(runtime_root, "herdr.sock"),
         runtime_root: runtime_root
       }}
    end

    def prepare_worker(session, spec, %{owner: owner}) do
      send(owner, {:worker_spec, spec})

      {:ok,
       session
       |> Map.put(:worker_launcher, Path.join(session.runtime_root, "launch-worker"))
       |> Map.put(:orchestrator_bin, Path.join(session.runtime_root, "orchestrator-bin"))}
    end

    def start_agent(_session, spec, %{owner: owner}) do
      send(owner, {:orchestrator_spec, spec})
      {:ok, %{name: spec.name, pane_id: "w1:p1", profile: spec.profile}}
    end

    def stop_session(_session, %{owner: owner}) do
      send(owner, :session_stopped)
      :ok
    end
  end

  test "the generated host-resource projection executes exact tools and DNS while preserving denials" do
    codex_bin = required_regular!("TUR877_CODEX_BIN", executable?: true)
    mise_executable = required_regular!("TUR877_MISE_EXECUTABLE", executable?: true)
    mise_target = required_regular!("TUR877_MISE_TARGET", executable?: true)
    elixir_install = required_directory!("TUR877_ELIXIR_INSTALL")
    erlang_install = required_directory!("TUR877_ERLANG_INSTALL")
    resolver_target = required_regular!("TUR877_RESOLVER_TARGET")
    denied_sibling = required_regular!("TUR877_DENIED_SIBLING_PATH")
    denied_private = required_regular!("TUR877_DENIED_PRIVATE_HOME_PATH")

    source_root = Path.expand("../..", __DIR__)
    tool_config = Path.join(source_root, "mise.toml")
    {source_ref, 0} = System.cmd("git", ["-C", source_root, "rev-parse", "--verify", "HEAD"])
    source_ref = String.trim(source_ref)

    root =
      Path.join(smoke_tmp_root(), "tur877-host-resource-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    runtime_root = Path.join(root, "runtime")
    worker_events = Path.join(runtime_root, "worker-events")
    File.mkdir_p!(Path.join(workspace, ".git"))
    File.mkdir_p!(worker_events)

    assignment = "TUR877-REAL-SANDBOX-#{System.unique_integer([:positive])}"
    event = Path.join(worker_events, "#{assignment}.json")
    denied_runtime_write = Path.join(runtime_root, "runtime-control.probe")
    denied_host_write = Path.join(source_root, ".tur877-host-write.probe")

    on_exit(fn ->
      File.rm(denied_host_write)
      File.rm_rf(root)
    end)

    declaration = %{
      "schema_version" => 1,
      "role" => "implementer",
      "execution_generation" => required_execution_generation_fixture!(),
      "runtime_generation" => required_positive_integer!("OCTO_RUNTIME_CONFIG_GENERATION"),
      "operations" => %{
        "symphony_runtime_verification" => %{
          "symphony_ref" => source_ref,
          "tool_config" => tool_config,
          "tool_config_sha256" => digest(tool_config),
          "mise" => %{
            "executable" => mise_executable,
            "target" => mise_target,
            "sha256" => digest(mise_target)
          },
          "elixir" => %{
            "version" => "1.19.5-otp-28",
            "install_path" => elixir_install
          },
          "erlang" => %{"version" => "28.5", "install_path" => erlang_install}
        },
        "host_dns" => %{"resolver_target" => resolver_target}
      }
    }

    context = [
      role: "implementer",
      execution_generation: declaration["execution_generation"],
      runtime_generation: declaration["runtime_generation"],
      source_ref: source_ref,
      tool_config_path: tool_config,
      tool_config_sha256: declaration["operations"]["symphony_runtime_verification"]["tool_config_sha256"]
    ]

    assert {:ok, session} =
             AgentRuntime.start_session(
               workspace,
               context ++
                 [
                   issue: issue(),
                   role: "implementer",
                   run_id: assignment,
                   host_resources: declaration,
                   skill_execution_contracts: [],
                   delegation_transport: CaptureTransport,
                   delegation_transport_context: %{owner: self(), runtime_root: runtime_root}
                 ]
             )

    assert_receive {:worker_spec, worker_spec}
    assert_receive {:orchestrator_spec, orchestrator_spec}

    for spec <- [worker_spec, orchestrator_spec] do
      assert spec.provider == "codex"

      assert spec.env["SYMPHONY_HOST_RESOURCE_CONTRACT"] ==
               HostResourceContract.encode!(session.herdr_session.host_resource_contract)
    end

    command = session.herdr_session.host_resource_contract.commands

    script = """
    set -eu
    mise_output=$(#{shell_word(command.mise)} --version)
    elixir_output=$(#{shell_word(command.elixir)} --version)
    erlang_output=$(#{shell_word(command.erlang)} -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')
    dns_output=$(/usr/bin/getent ahosts example.com | /usr/bin/head -n 1)
    /usr/bin/printf '{"assignment":"%s","status":"completed"}\\n' #{shell_word(assignment)} > #{shell_word(event)}
    if /usr/bin/touch #{shell_word(denied_runtime_write)} 2>/dev/null; then exit 41; fi
    if /usr/bin/head -c 1 #{shell_word(denied_sibling)} >/dev/null 2>&1; then exit 42; fi
    if /usr/bin/head -c 1 #{shell_word(denied_private)} >/dev/null 2>&1; then exit 43; fi
    if /usr/bin/touch #{shell_word(denied_host_write)} 2>/dev/null; then exit 44; fi
    /usr/bin/printf 'MISE=%s\\nELIXIR=%s\\nERLANG=%s\\nDNS=%s\\n' "$mise_output" "$elixir_output" "$erlang_output" "$dns_output"
    """

    argv =
      projected_configs(worker_spec.argv) ++
        ["sandbox", "--", "/bin/sh", "-c", script]

    {output, status} =
      System.cmd("/usr/bin/timeout", ["60", codex_bin | argv],
        cd: workspace,
        env: Map.to_list(worker_spec.env),
        stderr_to_stdout: true
      )

    assert status == 0, "real Codex sandbox proof failed with status #{status}:\n#{output}"
    assert output =~ "MISE="
    assert output =~ "ELIXIR=Erlang/OTP 28"
    assert output =~ "Elixir 1.19.5"
    assert output =~ "ERLANG=28"
    assert output =~ "DNS="
    assert File.read!(event) =~ assignment
    refute File.exists?(denied_runtime_write)
    refute File.exists?(denied_host_write)

    assert :ok = AgentRuntime.stop_session(session)
    assert_receive :session_stopped
    assert {:ok, _removed} = File.rm_rf(root)
    refute File.exists?(root)
  end

  defp projected_configs(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["--config", value] -> ["--config", value]
      _other -> []
    end)
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _other -> flunk("RUN_TUR877_HOST_RESOURCE_SANDBOX=1 requires #{name}")
    end
  end

  defp required_execution_generation_fixture! do
    case :persistent_term.get(:symphony_elixir_boot_seal, %{}) do
      %{host_resource_real_sandbox_execution_generation: value}
      when is_binary(value) and value != "" ->
        value

      _other ->
        flunk("RUN_TUR877_HOST_RESOURCE_SANDBOX=1 requires SYMPHONY_EXECUTION_GENERATION")
    end
  end

  defp required_positive_integer!(name) do
    case Integer.parse(required_env!(name)) do
      {value, ""} when value > 0 -> value
      _other -> flunk("#{name} must be a positive integer")
    end
  end

  defp required_regular!(name, opts \\ []) do
    path = required_env!(name)
    assert Path.type(path) == :absolute, "#{name} must be absolute"
    assert File.regular?(path), "#{name} must name an existing regular file"

    if Keyword.get(opts, :executable?, false),
      do: assert(File.stat!(path).mode |> Bitwise.band(0o111) != 0, "#{name} must be executable")

    path
  end

  defp required_directory!(name) do
    path = required_env!(name)
    assert Path.type(path) == :absolute, "#{name} must be absolute"
    assert File.dir?(path), "#{name} must name an existing directory"
    path
  end

  defp digest(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp shell_word(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  defp smoke_tmp_root, do: System.get_env("SYMPHONY_SMOKE_TMP_ROOT") || "/tmp"

  defp issue do
    %Issue{
      id: "tur-877-real-sandbox",
      identifier: "TUR-877",
      title: "Run declared host tools and DNS through sandboxed Symphony participants",
      state: "Agent Fixes",
      repository: "EmberAGI/symphony",
      repository_source: "linear_label",
      labels: ["implementation-effort:high"]
    }
  end
end
