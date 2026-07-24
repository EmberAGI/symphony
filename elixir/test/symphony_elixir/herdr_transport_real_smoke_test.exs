defmodule SymphonyElixir.HerdrTransportRealSmokeTest do
  @moduledoc """
  Live launch smoke against the real Herdr 0.7.5 binary.

  Uses only an isolated named session with a private `XDG_CONFIG_HOME`; the
  operator's default Herdr server is never stopped or mutated, and the test
  proves it by comparing default-server snapshots before and after.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.ImplementerDelegation.HerdrTransport

  @moduletag :herdr_real_smoke

  # Opt-in (RUN_HERDR_REAL_SMOKE=1) is enforced at runtime in test_helper.exs
  # via tag exclusion; binary presence and the pinned 0.7.5 version are
  # resolved here at runtime so a warm _build cannot stale-skip or stale-run.
  setup_all do
    herdr_bin = System.find_executable("herdr")
    assert is_binary(herdr_bin), "RUN_HERDR_REAL_SMOKE=1 requires a herdr binary on PATH"

    version =
      case System.cmd(herdr_bin, ["--version"]) do
        {output, 0} -> output |> String.trim() |> String.split(" ") |> List.last()
        _ -> nil
      end

    assert version == "0.7.5",
           "RUN_HERDR_REAL_SMOKE=1 requires real herdr 0.7.5 (found: #{inspect(version)})"

    %{herdr_bin: herdr_bin}
  end

  test "real herdr launches through the wrapper-resolved acknowledged projection", %{herdr_bin: herdr_bin} do
    root = Path.join(System.tmp_dir!(), "octo-emb1245-smoke-#{System.unique_integer([:positive])}")
    stub_bin = Path.join(root, "stub-bin")
    argv_out = Path.join(root, "provider-argv.out")
    env_out = Path.join(root, "provider-env.out")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(stub_bin)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    # Stub provider: records its exact argv and environment, then stays in the
    # foreground with `claude` in its cmdline so Herdr agent detection holds
    # across both exec transitions (wrapper -> projection -> provider).
    File.write!(Path.join(stub_bin, "claude"), """
    #!/bin/sh
    printf '%s\\n' "$@" > #{argv_out}
    env > #{env_out}
    printf 'stub claude ready\\n'
    while :; do sleep 1; done
    """)

    File.chmod!(Path.join(stub_bin, "claude"), 0o755)

    adapter_context = %{
      herdr_bin: herdr_bin,
      start_timeout_ms: 15_000,
      agent_start_timeout_ms: 30_000
    }

    assert {:ok, default_before} = HerdrTransport.default_server_snapshot(adapter_context)

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1245-smoke-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: workspace,
                 env: %{"PATH" => stub_bin <> ":" <> (System.get_env("PATH") || "")}
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    instructions = "Follow the Symphony implementer profile.\nFinish safely."

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: workspace,
                 argv: ["claude", "--model", "claude-fable-5", "--append-system-prompt", instructions]
               },
               adapter_context
             )

    assert agent.name == "implementer_orchestrator"
    assert agent.agent == "claude"

    # Byte-for-byte provider argv: the native args exactly, with LF projected
    # to U+2028 — never the sentinel, the projection path, or the
    # herdr-injected unattended flag (the wrapper consumed it).
    expected_argv =
      "--model\nclaude-fable-5\n--append-system-prompt\n" <>
        "Follow the Symphony implementer profile.\u2028Finish safely.\n"

    assert File.read!(argv_out) == expected_argv

    provider_env = File.read!(env_out)
    assert provider_env =~ "PATH=#{session.runtime_root}/orchestrator-bin:#{stub_bin}:"

    # Both per-launch acknowledgements carry the launch token.
    [projection_path] = Path.wildcard(Path.join(session.runtime_root, "launch-projections/*.sh"))
    token = Path.basename(projection_path, ".sh")
    ack_dir = Path.join([session.runtime_root, "launch-acks", token])
    assert String.trim(File.read!(Path.join(ack_dir, "wrapper.ack"))) == token
    assert String.trim(File.read!(Path.join(ack_dir, "projection.ack"))) == token

    # Herdr 0.7.5 really injected the kind-specific unattended flag; the
    # wrapper records the exact observed flag as token-local diagnostic
    # evidence before stripping it.
    assert String.trim(File.read!(Path.join(ack_dir, "injected-flag"))) ==
             "--dangerously-skip-permissions"

    # Status detection holds after the full exec chain: the stub renders a
    # prompt-less foreground loop, which Herdr 0.7.5 classifies as idle.
    assert {:ok, observed} =
             HerdrTransport.await_agent(session, agent, ["idle", "done", "blocked"], 10_000, adapter_context)

    assert observed.agent_status == "idle"

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
    refute File.exists?(session.runtime_root)

    # The operator's default server was never touched.
    assert {:ok, ^default_before} = HerdrTransport.default_server_snapshot(adapter_context)
  end
end
