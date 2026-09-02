defmodule SymphonyElixir.ImplementerWorkerEventsSandboxSmokeTest do
  @moduledoc """
  EMB-1302 live proof: the projected recorder can create an observation event
  from inside the real Codex tool sandbox.

  Every non-live path that exercised `record_worker_event` ran it outside a
  provider sandbox — the launch attestation writes `observed.000001` from the
  wrapper's own process — which is exactly why EMB-1303 shipped a launcher
  whose first in-sandbox recorder call died with `Read-only file system`. Only
  a real Codex sandbox can decide this contract, so this test:

    * materializes the real role Herdr wrapper through `HerdrTransport`, so the
      recorder under test is the one production runs rather than a copy,
    * captures the real launch permission projection out of the worker argv
      that public `ImplementerDelegation.start_session/3` hands the transport,
      pinned to that same runtime root — no test-only production API,
    * runs a bounded real `codex exec` under exactly that projection, and
    * asserts the in-sandbox wrapper call recorded an observation while a
      sibling write under the same runtime root stayed denied.

  It never touches Linear and never stops or mutates the operator's default
  Herdr server — the before/after default-server snapshots are compared.

  Opt-in: `RUN_CODEX_REAL_SANDBOX_SMOKE=1` (see `test_helper.exs`). It spends
  one real Codex model call, so it is not part of the deterministic gate.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.{ImplementationEffort, ImplementerDelegation, SkillExecutionContract}
  alias SymphonyElixir.ImplementerDelegation.HerdrTransport
  alias SymphonyElixir.Linear.Issue

  @moduletag :codex_real_sandbox_smoke
  @moduletag timeout: 900_000

  @codex_exec_timeout_s "120"

  # Captures the launcher projection for an already-materialized runtime root.
  # It answers `start_session` with that exact root so the permission config it
  # yields is the one the real session would have been launched under.
  defmodule CaptureTransport do
    def default_server_snapshot(_context),
      do: {:ok, %{status: "running", version: "0.8.2", protocol: 20, socket: "/tmp/capture/herdr.sock"}}

    def start_session(spec, %{owner: owner, runtime_root: runtime_root, socket: socket}) do
      send(owner, {:capture, :start_session, spec})
      {:ok, %{name: spec.name, socket: socket, runtime_root: runtime_root}}
    end

    def prepare_worker(session, spec, %{owner: owner}) do
      send(owner, {:capture, :worker_argv, spec.argv})

      {:ok,
       session
       |> Map.put(:worker_launcher, Path.join(session.runtime_root, "launch-worker"))
       |> Map.put(:orchestrator_bin, Path.join(session.runtime_root, "orchestrator-bin"))}
    end

    def start_agent(_session, spec, %{owner: owner}) do
      send(owner, {:capture, :orchestrator_argv, spec.argv})
      {:ok, %{name: spec.name, pane_id: "w1:p1", profile: spec.profile}}
    end
  end

  setup_all do
    herdr_bin = System.find_executable("herdr")
    codex_bin = System.find_executable("codex")

    assert is_binary(herdr_bin), "RUN_CODEX_REAL_SANDBOX_SMOKE=1 requires a herdr binary on PATH"
    assert is_binary(codex_bin), "RUN_CODEX_REAL_SANDBOX_SMOKE=1 requires a codex binary on PATH"

    %{herdr_bin: herdr_bin, codex_bin: codex_bin}
  end

  test "the projected recorder records an observation inside the real Codex sandbox", %{
    herdr_bin: herdr_bin,
    codex_bin: codex_bin
  } do
    unique = System.unique_integer([:positive])
    root = Path.join(smoke_tmp_root(), "e1302-#{unique}")
    runtime_root = Path.join(root, "rt")
    workspace = Path.join(root, "ws")
    stub_bin = Path.join(root, "stub-bin")
    File.mkdir_p!(workspace)
    File.mkdir_p!(stub_bin)
    on_exit(fn -> File.rm_rf!(root) end)

    # Stub worker provider: keeps `claude` in its cmdline for Herdr agent
    # detection without spending a second model call. The recorder under test
    # is materialized by the transport regardless of what the worker pane runs.
    File.write!(Path.join(stub_bin, "claude"), """
    #!/bin/sh
    printf 'stub claude ready\\n'
    while :; do sleep 1; done
    """)

    File.chmod!(Path.join(stub_bin, "claude"), 0o755)

    context = %{
      herdr_bin: herdr_bin,
      socket_root: runtime_root,
      start_timeout_ms: 15_000,
      agent_start_timeout_ms: 30_000
    }

    assert {:ok, default_before} = HerdrTransport.default_server_snapshot(context)

    session_env = %{"PATH" => stub_bin <> ":" <> (System.get_env("PATH") || "")}
    session_name = "octo-emb-1302-smoke-#{unique}"

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{name: session_name, isolated: true, workspace: workspace, env: session_env},
               context
             )

    # `stop_session/2` yields on the session server Task, which only its owner
    # may query, so the isolated session is stopped from the test process
    # below. `on_exit` only reclaims the tree.
    assert {:ok, session} =
             HerdrTransport.prepare_worker(
               session,
               %{
                 name: "implementer_worker",
                 role: :worker,
                 provider: "claude_code",
                 cwd: workspace,
                 argv: ["claude", "--model", "claude-fable-5"],
                 env: session_env,
                 may_spawn_agents: false
               },
               context
             )

    worker_events = Path.join(session.runtime_root, "worker-events")
    recorder = Path.join([session.runtime_root, "worker-bin", "herdr"])
    assert File.dir?(worker_events), "the transport must materialize the worker-events root"
    assert File.exists?(recorder), "the transport must materialize the worker role Herdr wrapper"

    worker_argv = captured_worker_argv(session, workspace, codex_bin)
    permission_config = projected_permission_config(worker_argv)

    observed_before = MapSet.new(Path.wildcard(Path.join(worker_events, "observed.*")))
    denied_probe = Path.join(session.runtime_root, "emb-1302-denied.probe")

    prompt = """
    Run exactly these two shell commands, each in its own tool call, and report each exit status.
    Do nothing else — no exploration, no retries, no other commands.
    1) #{recorder} agent get implementer_worker
    2) touch #{denied_probe}
    """

    argv =
      [
        "timeout",
        @codex_exec_timeout_s,
        codex_bin,
        "--ask-for-approval",
        "never",
        "--disable",
        "multi_agent",
        "exec",
        # The probe workspace is a bare directory, not a repo checkout.
        "--skip-git-repo-check",
        "--model",
        projected_model(worker_argv),
        "--config",
        "check_for_update_on_startup=false",
        # The probe only needs the sandbox decision, so it runs at the cheapest
        # effort that still drives two tool calls; the permission projection
        # under test is the production one.
        "--config",
        "model_reasoning_effort=low",
        "--config",
        "default_permissions=\"octo_herdr\"",
        "--config",
        permission_config,
        "--config",
        "projects={#{inspect(workspace)}={trust_level=\"trusted\"}}",
        prompt
      ]
      |> Enum.map_join(" ", &shell_escape/1)

    # stdin must be closed: `codex exec` otherwise waits on it for additional
    # prompt input and the probe hangs instead of deciding anything.
    {output, status} =
      System.cmd("sh", ["-c", argv <> " < /dev/null 2>&1"], cd: workspace, stderr_to_stdout: true)

    assert status == 0, "bounded codex exec did not complete (status #{status}):\n#{output}"

    recorded =
      worker_events
      |> Path.join("observed.*")
      |> Path.wildcard()
      |> MapSet.new()
      |> MapSet.difference(observed_before)

    assert MapSet.size(recorded) >= 1,
           "the in-sandbox recorder created no observation event; codex exec output:\n#{output}"

    assert Enum.any?(recorded, &(File.read!(&1) =~ "agent get implementer_worker")),
           "the recorded observation must carry the observed delegation command"

    refute File.exists?(denied_probe),
           "the rest of the session runtime root must stay read-only"

    assert :ok = HerdrTransport.stop_session(session, context)
    refute File.exists?(session.runtime_root)

    # The operator's default Herdr server was never stopped or mutated.
    assert {:ok, ^default_before} = HerdrTransport.default_server_snapshot(context)
  end

  # Drives the public delegation seam against a capture transport pinned to the
  # live runtime root and returns the worker launch argv the launcher
  # projected. Both Codex participants are projected from the same helper, and
  # the deterministic test proves they agree.
  defp captured_worker_argv(session, workspace, codex_bin) do
    assert {:ok, contract} =
             ImplementationEffort.runtime_profile_for_issue(:codex, issue(), "implementer")

    assert {:ok, _captured} =
             ImplementerDelegation.start_session(
               workspace,
               contract,
               issue_identifier: "EMB-1302",
               run_id: "smoke",
               transport: CaptureTransport,
               transport_context: %{
                 owner: self(),
                 runtime_root: session.runtime_root,
                 socket: session.socket
               },
               # The codex install root is a host bootstrap read grant, not part
               # of the Symphony contract: this host runs codex from an npm
               # layout the sandbox `:minimal` read set does not cover, so
               # without it every in-sandbox command fails to exec before any
               # permission is decided. It rides the same read-root seam a
               # skill's tool executable does.
               skill_execution_contracts: [
                 %SkillExecutionContract{
                   skill: "codex_host_bootstrap",
                   package_root: codex_install_root(codex_bin),
                   runtime_inputs: [],
                   tool_executables: []
                 }
               ]
             )

    assert_receive {:capture, :worker_argv, argv}
    argv
  end

  defp projected_permission_config(argv) do
    config =
      Enum.find(argv, fn arg ->
        is_binary(arg) and String.starts_with?(arg, "permissions.octo_herdr.filesystem=")
      end)

    assert is_binary(config), "the launch argv must project an octo_herdr filesystem permission"
    config
  end

  defp projected_model(argv) do
    ["codex", "--model", model | _rest] = argv
    model
  end

  defp shell_escape(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  # Herdr socket paths are length-bounded, so the smoke root stays short.
  defp smoke_tmp_root, do: System.get_env("SYMPHONY_SMOKE_TMP_ROOT") || "/tmp"

  defp codex_install_root(codex_bin) do
    {resolved, 0} = System.cmd("readlink", ["-f", codex_bin])
    resolved = String.trim(resolved)

    # npm ships `codex` as a JS shim at `<package>/bin/codex.js` that execs a
    # native binary vendored elsewhere in the same package.
    if String.ends_with?(resolved, ".js"),
      do: resolved |> Path.dirname() |> Path.dirname(),
      else: Path.dirname(resolved)
  end

  defp issue do
    %Issue{
      id: "issue-1302",
      identifier: "EMB-1302",
      title: "Restore worker observation recording",
      state: "In Progress",
      branch_name: "sebastianvarela/emb-1302-restore-worker-observation",
      url: "https://linear.app/emberai/issue/EMB-1302",
      repository: "EmberAGI/symphony",
      repository_source: "linear_label",
      labels: ["implementation-effort:moderate"]
    }
  end
end
