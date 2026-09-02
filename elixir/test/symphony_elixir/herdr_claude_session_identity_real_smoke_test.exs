defmodule SymphonyElixir.HerdrClaudeSessionIdentityRealSmokeTest do
  @moduledoc """
  Live provider-session identity proof against the real Herdr 0.8.2 binary and
  the real Claude Code role launcher (EMB-1353 AC3).

  Production run EMB-1144 reached a terminal Herdr state carrying no
  `agent_session`, and no fake could have caught it: Herdr derives no Claude
  identity itself, and the recorded envelopes only carried the field because
  the recording host's Claude integration had already reported it.

  This exercises the same transport Interface a real Implementer turn uses —
  isolated session, wrapper-resolved acknowledged projection, real `claude` —
  and asserts one stable nonblank native identity across the prompt
  acknowledgement, the terminal observation, and a subsequent read. It runs
  the handshake repeatedly so a pass cannot be a one-off, and it never touches
  Linear, production admission, or the operator's default Herdr server.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.ImplementerDelegation.HerdrTransport

  @moduletag :herdr_real_smoke
  @moduletag timeout: 600_000

  @handshake_repeats 3

  # Opt-in (RUN_HERDR_REAL_SMOKE=1) is enforced at runtime in test_helper.exs
  # via tag exclusion; binary presence and the pinned 0.8.2 version are
  # resolved here at runtime so a warm _build cannot stale-skip or stale-run.
  setup_all do
    herdr_bin = System.find_executable("herdr")
    assert is_binary(herdr_bin), "RUN_HERDR_REAL_SMOKE=1 requires a herdr binary on PATH"

    version =
      case System.cmd(herdr_bin, ["--version"]) do
        {output, 0} -> output |> String.trim() |> String.split(" ") |> List.last()
        _ -> nil
      end

    assert version == "0.8.2",
           "RUN_HERDR_REAL_SMOKE=1 requires real herdr 0.8.2 (found: #{inspect(version)})"

    claude_bin = System.find_executable("claude")
    assert is_binary(claude_bin), "RUN_HERDR_REAL_SMOKE=1 requires a claude binary on PATH"

    %{herdr_bin: herdr_bin}
  end

  test "every real Claude launch exposes one stable nonblank provider session identity", %{herdr_bin: herdr_bin} do
    identities =
      Enum.map(1..@handshake_repeats, fn attempt ->
        observe_provider_session_identity(herdr_bin, attempt)
      end)

    # Nonblank on every repeat: the handshake is the contract, not a race that
    # happened to land once.
    for identity <- identities do
      assert is_binary(identity.receipt) and String.trim(identity.receipt) != ""
      assert identity.subsequent == identity.receipt
      assert identity.source == "herdr:claude"

      # The provider reports its session when the session starts, which can
      # land after Herdr has already acknowledged the prompt or settled the
      # turn — the bounded receipt window the runtime waits out. Any earlier
      # observation that does carry an identity must carry this one; a second
      # value would describe a different session.
      assert identity.acknowledged in [nil, identity.receipt]
      assert identity.terminal in [nil, identity.receipt]
    end

    # Each run is its own provider session: a stable identity is not a
    # constant one.
    values = Enum.map(identities, & &1.receipt)
    assert length(Enum.uniq(values)) == length(values)
  end

  defp observe_provider_session_identity(herdr_bin, attempt) do
    root = Path.join(System.tmp_dir!(), "emb1353-identity-#{attempt}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    # A provisioned production host, and nothing more: the provider can
    # authenticate, and the Herdr integration this identity used to depend on
    # is absent. Whatever the operator installed in their own Claude config
    # therefore cannot supply the trust or the report on the run's behalf, so
    # a pass here can only come from what the launch itself provisions.
    host_config = install_provisioned_host_config!(root)

    adapter_context = %{
      herdr_bin: herdr_bin,
      start_timeout_ms: 20_000,
      agent_start_timeout_ms: 60_000
    }

    assert {:ok, default_before} = HerdrTransport.default_server_snapshot(adapter_context)

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1353-identity-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: workspace,
                 env: %{
                   "PATH" => System.get_env("PATH") || "",
                   "CLAUDE_CONFIG_DIR" => host_config
                 }
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    # The orchestrator's own Herdr authority shim is materialized by the same
    # worker-launcher preparation a real run performs before it starts any
    # agent. No worker is prestarted here: this proves the orchestrator's
    # identity, and the delegation branch is proven at the runtime seam.
    assert {:ok, session} =
             HerdrTransport.prepare_worker(
               session,
               %{
                 provider: "claude_code",
                 argv: ["claude", "--model", "sonnet"],
                 env: %{}
               },
               adapter_context
             )

    # The production Implementer orchestrator launch shape.
    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 role: :orchestrator,
                 provider: "claude_code",
                 cwd: workspace,
                 argv: [
                   "claude",
                   "--model",
                   "sonnet",
                   "--effort",
                   "low",
                   "--append-system-prompt",
                   "Answer with exactly OK and nothing else.",
                   "--dangerously-skip-permissions",
                   "--disallowed-tools",
                   "Agent"
                 ]
               },
               adapter_context
             )

    assert agent.agent == "claude"

    assert {:ok, turn_start} =
             HerdrTransport.begin_turn(
               session,
               agent,
               "Reply with exactly OK and do nothing else.",
               120_000,
               adapter_context
             )

    acknowledged = provider_session(turn_start.agent)

    {:ok, terminal} =
      case turn_start.phase do
        :completed -> {:ok, turn_start.agent}
        :working -> HerdrTransport.await_agent(session, agent, ["idle", "done", "blocked"], 180_000, adapter_context)
      end

    assert terminal.agent_status in ["idle", "done"]

    # The same bounded provider-session receipt read the Implementer runtime
    # performs, against the same transport Interface and default window.
    receipt = await_provider_session_receipt(session, agent, adapter_context)

    assert {:ok, subsequent} = HerdrTransport.get_agent(session, agent, 30_000, adapter_context)

    identity = %{
      acknowledged: session_value(acknowledged),
      terminal: session_value(provider_session(terminal)),
      receipt: session_value(provider_session(receipt)),
      subsequent: session_value(provider_session(subsequent)),
      source: session_source(provider_session(subsequent))
    }

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
    refute File.exists?(session.runtime_root)
    assert {:ok, ^default_before} = HerdrTransport.default_server_snapshot(adapter_context)

    identity
  end

  # Mirrors `ImplementerDelegation.await_provider_session_receipt/3`: bounded
  # by the runtime's default 60-second window, reading the same live agent
  # through the same transport Interface. Returns the last observation either
  # way so a window that expires without an identity fails on the assertion
  # rather than in the helper.
  defp await_provider_session_receipt(session, agent, adapter_context, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 60_000

    assert {:ok, observed} = HerdrTransport.get_agent(session, agent, 30_000, adapter_context)

    cond do
      is_binary(session_value(provider_session(observed))) ->
        observed

      System.monotonic_time(:millisecond) >= deadline ->
        observed

      true ->
        Process.sleep(500)
        await_provider_session_receipt(session, agent, adapter_context, deadline)
    end
  end

  # Credentials are linked, never copied or read, so the probe authenticates
  # exactly as the operator provisioned this host and no secret is duplicated.
  # The Symphony process sees the same config home, so the launch links its
  # credentials from here rather than from the developer's own installation.
  defp install_provisioned_host_config!(root) do
    host_config = Path.join(root, "host-claude-config")
    File.mkdir_p!(host_config)
    File.chmod!(host_config, 0o700)

    credentials = Path.join(operator_claude_config_dir(), ".credentials.json")

    if File.exists?(credentials) do
      File.ln_s!(credentials, Path.join(host_config, ".credentials.json"))
    end

    previous = System.get_env("CLAUDE_CONFIG_DIR")
    System.put_env("CLAUDE_CONFIG_DIR", host_config)

    on_exit(fn ->
      if previous,
        do: System.put_env("CLAUDE_CONFIG_DIR", previous),
        else: System.delete_env("CLAUDE_CONFIG_DIR")
    end)

    host_config
  end

  defp operator_claude_config_dir do
    case System.get_env("CLAUDE_CONFIG_DIR") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(System.user_home() || "", ".claude")
    end
  end

  defp provider_session(agent), do: Map.get(agent, :agent_session)

  defp session_value(%{"value" => value}), do: value
  defp session_value(%{value: value}), do: value
  defp session_value(_session), do: nil

  defp session_source(%{"source" => source}), do: source
  defp session_source(%{source: source}), do: source
  defp session_source(_session), do: nil
end
