defmodule SymphonyElixir.HerdrTransportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ImplementerDelegation.HerdrTransport
  alias SymphonyElixir.TestSupport.HerdrReplayFixture

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-herdr-transport-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "fake-herdr")
    log = Path.join(root, "herdr.log")

    deliberately_long_runtime_root =
      Path.join(root, "runtime-artifacts-that-must-not-determine-the-unix-socket-location")

    File.mkdir_p!(root)
    replay_dir = HerdrReplayFixture.materialize_replay_dir!(Path.join(root, "herdr-replay"))
    HerdrReplayFixture.write_fake_herdr!(bin, replay_dir)

    resolvable_provider_bin = Path.join(root, "resolvable-provider-bin")
    File.mkdir_p!(resolvable_provider_bin)

    for provider <- ["codex", "claude"] do
      fake = Path.join(resolvable_provider_bin, provider)
      File.write!(fake, "#!/bin/sh\nexit 0\n")
      File.chmod!(fake, 0o755)
    end

    previous_path = System.get_env("PATH") || ""
    System.put_env("PATH", resolvable_provider_bin <> ":" <> previous_path)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      File.rm_rf!(root)
    end)

    %{bin: bin, log: log, replay_dir: replay_dir, runtime_root: deliberately_long_runtime_root}
  end

  test "pane-shell launch resolves the session wrapper instead of sending the bare projection path", context do
    root = Path.dirname(context.bin)
    session_name = "octo-emb-1245-sentinel-#{System.unique_integer([:positive])}"

    # A provider on the pane-shell login PATH: this is what a bare-path launch
    # mis-resolves to. It must never be entered.
    login_bin = Path.join(root, "login-bin")
    login_out = Path.join(root, "login-claude.out")
    File.mkdir_p!(login_bin)

    File.write!(Path.join(login_bin, "claude"), """
    #!/bin/sh
    printf '%s\n' "$@" > #{login_out}
    """)

    File.chmod!(Path.join(login_bin, "claude"), 0o755)

    # The real provider executable resolved by the launch projection.
    provider_bin = Path.join(root, "sentinel-provider-bin")
    provider_out = Path.join(root, "sentinel-provider.out")
    File.mkdir_p!(provider_bin)

    File.write!(Path.join(provider_bin, "claude"), """
    #!/bin/sh
    printf '%s\n' "$@"
    """)

    File.chmod!(Path.join(provider_bin, "claude"), 0o755)

    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_LOGIN_PATH", login_bin <> ":/usr/bin:/bin"},
        {"HERDR_FAKE_PROVIDER_OUTPUT", provider_out}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: session_name,
                 isolated: true,
                 workspace: "/tmp/selected-workspace",
                 env: %{"PATH" => provider_bin <> ":" <> (System.get_env("PATH") || "")}
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, _agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: [
                   "claude",
                   "--model",
                   "claude-fable-5",
                   "--append-system-prompt",
                   "Follow the Symphony implementer profile."
                 ]
               },
               adapter_context
             )

    # The login-PATH provider (bare-path mis-launch target) was never entered.
    refute File.exists?(login_out),
           "bare-path mis-launch: login-PATH provider received #{inspect(File.read(login_out))}"

    # The provider received the exact native argv, byte for byte — never the
    # projection path as a positional argument.
    assert File.read!(provider_out) ==
             "--model\nclaude-fable-5\n--append-system-prompt\nFollow the Symphony implementer profile.\n"

    commands = File.read!(context.log)

    assert commands =~
             "agent start implementer_orchestrator --kind claude --pane w1:p1 --timeout 120000 -- --symphony-launch-projection #{session.runtime_root}/launch-projections/"

    assert commands =~ "pane run w1:p1 export PATH="

    # The wrapper observed, recorded, and stripped the kind-specific
    # herdr-injected unattended flag.
    [ack_dir] = Path.wildcard(Path.join(session.runtime_root, "launch-acks/*"))

    assert String.trim(File.read!(Path.join(ack_dir, "injected-flag"))) ==
             "--dangerously-skip-permissions"

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "start_agent fails closed when the session wrapper artifact was tampered", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10,
      launch_handshake_timeout_ms: 300
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1245-tamper-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    claude_spec = %{
      name: "implementer_orchestrator",
      provider: "claude_code",
      cwd: "/tmp/selected-workspace",
      argv: ["claude", "--model", "claude-fable-5"]
    }

    assert {:ok, session} =
             HerdrTransport.prepare_worker(session, claude_spec, adapter_context)

    tampered_wrapper = Path.join(session.orchestrator_bin, "claude")
    File.chmod!(tampered_wrapper, 0o755)

    assert {:error, {:herdr_wrapper_resolution_failed, %{reason: :invalid_mode}}} =
             HerdrTransport.start_agent(session, claude_spec, adapter_context)

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "retries a transient busy pane within the startup window, then fails typed at the deadline", context do
    claude_spec = %{
      name: "implementer_orchestrator",
      provider: "claude_code",
      cwd: "/tmp/selected-workspace",
      argv: ["claude", "--model", "claude-fable-5"]
    }

    # Busy twice, then available: the launch succeeds within the window.
    recovering_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}, {"HERDR_FAKE_PANE_BUSY_COUNT", "2"}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10,
      launch_handshake_timeout_ms: 2_000
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1245-busy-recover-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               recovering_context
             )

    assert {:ok, _agent} = HerdrTransport.start_agent(session, claude_spec, recovering_context)

    start_attempts =
      context.log
      |> File.read!()
      |> :binary.matches("agent start implementer_orchestrator")
      |> length()

    assert start_attempts == 3
    assert :ok = HerdrTransport.stop_session(session, recovering_context)
    File.write!(context.log, "")

    # Busy past the whole startup window: a distinct typed provider-start failure.
    exhausted_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}, {"HERDR_FAKE_PANE_BUSY_COUNT", "99"}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10,
      launch_handshake_timeout_ms: 300
    }

    assert {:ok, exhausted_session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1245-busy-exhausted-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               exhausted_context
             )

    assert {:error, {:herdr_provider_start_failed, _reason}} =
             HerdrTransport.start_agent(exhausted_session, claude_spec, exhausted_context)

    assert :ok = HerdrTransport.stop_session(exhausted_session, exhausted_context)
  end

  test "a projection tampered after the transport precheck is a typed wrapper-side validation failure",
       context do
    # Both real Herdr timings: the wrapper rejection surfaces whether Herdr
    # reports the start as failed or as already-successful.
    for extra_sabotage <- [[], [{"HERDR_FAKE_IGNORE_LAUNCH_FAILURE", "1"}]] do
      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [{"HERDR_FAKE_LOG", context.log}, {"HERDR_FAKE_TAMPER_PROJECTION", "1"}] ++ extra_sabotage,
        start_timeout_ms: 2_000,
        poll_interval_ms: 10,
        launch_handshake_timeout_ms: 300
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: "octo-emb-1245-toctou-#{System.unique_integer([:positive])}",
                   isolated: true,
                   workspace: "/tmp/selected-workspace"
                 },
                 adapter_context
               )

      assert {:error, {:herdr_projection_validation_failed, %{stage: :wrapper, reason: "launch projection ownership or mode is invalid"}}} =
               HerdrTransport.start_agent(
                 session,
                 %{
                   name: "implementer_orchestrator",
                   provider: "claude_code",
                   cwd: "/tmp/selected-workspace",
                   argv: ["claude", "--model", "claude-fable-5"]
                 },
                 adapter_context
               )

      assert :ok = HerdrTransport.stop_session(session, adapter_context)
    end
  end

  test "returns distinct typed failures for each launch stage", context do
    stages = [
      {[{"HERDR_FAKE_PANE_RUN_FAIL", "1"}], :herdr_pane_preparation_failed},
      {[{"HERDR_FAKE_PANE_RUN_NO_PERSIST", "1"}], :herdr_wrapper_resolution_failed},
      {[{"HERDR_FAKE_SKIP_LAUNCH", "1"}], :herdr_wrapper_ack_failed},
      {[{"HERDR_FAKE_WRAPPER_ACK_ONLY", "1"}, {"HERDR_FAKE_CORRUPT_WRAPPER_ACK", "1"}], :herdr_wrapper_ack_failed},
      {[{"HERDR_FAKE_WRAPPER_ACK_ONLY", "1"}], :herdr_projection_ack_failed},
      {[{"HERDR_FAKE_WRAPPER_ACK_ONLY", "1"}, {"HERDR_FAKE_CORRUPT_PROJECTION_ACK", "1"}], :herdr_projection_ack_failed},
      {[{"HERDR_FAKE_AGENT_START_ERROR", "1"}], :herdr_provider_start_failed}
    ]

    for {{sabotage_env, expected_stage}, index} <- Enum.with_index(stages) do
      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [{"HERDR_FAKE_LOG", context.log}] ++ sabotage_env,
        start_timeout_ms: 2_000,
        poll_interval_ms: 10,
        launch_handshake_timeout_ms: 300
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: "octo-emb-1245-stage-#{index}-#{System.unique_integer([:positive])}",
                   isolated: true,
                   workspace: "/tmp/selected-workspace"
                 },
                 adapter_context
               )

      assert {:error, {^expected_stage, _details}} =
               HerdrTransport.start_agent(
                 session,
                 %{
                   name: "implementer_orchestrator",
                   provider: "claude_code",
                   cwd: "/tmp/selected-workspace",
                   argv: ["claude", "--model", "claude-fable-5"]
                 },
                 adapter_context
               )

      assert :ok = HerdrTransport.stop_session(session, adapter_context)
    end
  end

  test "corrupted acknowledgements surface the observed content", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_WRAPPER_ACK_ONLY", "1"},
        {"HERDR_FAKE_CORRUPT_WRAPPER_ACK", "1"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10,
      launch_handshake_timeout_ms: 300
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1245-corrupt-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    assert {:error, {:herdr_wrapper_ack_failed, %{expected: expected_token, observed: "corrupted"}}} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: ["claude", "--model", "claude-fable-5"]
               },
               adapter_context
             )

    assert is_binary(expected_token)
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "concurrent launches use launch-scoped tokens and stale acks cannot cross-satisfy", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10,
      launch_handshake_timeout_ms: 300
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1245-scoped-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    start_results =
      ["implementer_orchestrator", "implementer_worker"]
      |> Enum.map(fn agent_name ->
        Task.async(fn ->
          HerdrTransport.start_agent(
            session,
            %{
              name: agent_name,
              provider: "claude_code",
              cwd: "/tmp/selected-workspace",
              argv: ["claude", "--model", "claude-fable-5"]
            },
            adapter_context
          )
        end)
      end)
      |> Task.await_many(15_000)

    assert [{:ok, _}, {:ok, _}] = start_results

    ack_dirs = Path.wildcard(Path.join(session.runtime_root, "launch-acks/*"))
    assert length(ack_dirs) == 2

    for ack_dir <- ack_dirs do
      token = Path.basename(ack_dir)
      assert String.trim(File.read!(Path.join(ack_dir, "wrapper.ack"))) == token
      assert String.trim(File.read!(Path.join(ack_dir, "projection.ack"))) == token
    end

    assert :ok = HerdrTransport.stop_session(session, adapter_context)

    # A later launch mints a fresh token, so acknowledgements persisted by
    # earlier launches can never satisfy it: with the launch chain suppressed,
    # pre-seeded stale acks still leave the handshake unsatisfied.
    assert {:ok, stale_session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1245-stale-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace",
                 env: %{"HERDR_FAKE_SKIP_LAUNCH" => "1"}
               },
               adapter_context
             )

    stale_dir = Path.join(stale_session.runtime_root, "launch-acks/stale-token")
    File.mkdir_p!(stale_dir)
    File.write!(Path.join(stale_dir, "wrapper.ack"), "stale-token\n")
    File.write!(Path.join(stale_dir, "projection.ack"), "stale-token\n")

    assert {:error, {:herdr_wrapper_ack_failed, %{observed: nil}}} =
             HerdrTransport.start_agent(
               stale_session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: ["claude", "--model", "claude-fable-5"]
               },
               adapter_context
             )

    assert :ok = HerdrTransport.stop_session(stale_session, adapter_context)
  end

  test "generated role projections expose only the native live-agent controls", context do
    session_name = "octo-emb-1201-native-projection-#{System.unique_integer([:positive])}"
    provider_bin = Path.join(Path.dirname(context.bin), "provider-bin")
    fake_claude = Path.join(provider_bin, "claude")
    File.mkdir_p!(provider_bin)

    File.write!(fake_claude, """
    #!/bin/sh
    printf 'PATH=%s\nSKILLS=%s\n' "$PATH" "${SYMPHONY_SKILL_EXECUTION_CONTRACTS:-}"
    """)

    File.chmod!(fake_claude, 0o755)

    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10,
      launch_handshake_timeout_ms: 300
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: session_name,
                 isolated: true,
                 workspace: "/tmp/selected-workspace",
                 env: %{"PATH" => provider_bin <> ":" <> (System.get_env("PATH") || "")}
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, session} =
             HerdrTransport.prepare_worker(
               session,
               %{
                 provider: "claude_code",
                 argv: ["claude", "--model", "claude-sonnet-5"],
                 env: %{"SYMPHONY_SKILL_EXECUTION_CONTRACTS" => "worker-contract"}
               },
               adapter_context
             )

    worker_herdr = Path.join(session.runtime_root, "worker-bin/herdr")
    orchestrator_herdr = Path.join(session.orchestrator_bin, "herdr")
    claude_projection = Path.join(session.orchestrator_bin, "claude")
    base_env = [{"HERDR_FAKE_LOG", context.log}, {"XDG_CONFIG_HOME", session.runtime_root}]
    default_state_root = Path.join([session.runtime_root, "herdr", "sessions", "default"])

    generated_unknown_fixture =
      HerdrReplayFixture.write_replay_mutation!(
        context.replay_dir,
        "agent-wait-working",
        "agent-wait-unknown-generated",
        &String.replace(&1, ~s("agent_status":"working"), ~s("agent_status":"unknown"))
      )

    # The wrapper fails closed for any invocation other than the exact
    # sentinel plus one projection path: no default-bootstrap escape hatch.
    assert {wrapper_denial, 64} =
             System.cmd(claude_projection, ["--model", "claude-sonnet-5"],
               env: [
                 {"HERDR_PANE_ID", "w1:p1"},
                 {"SYMPHONY_SKILL_EXECUTION_CONTRACTS", ""}
               ],
               stderr_to_stdout: true
             )

    assert wrapper_denial =~ "provider wrapper only accepts the launch projection sentinel"

    assert {trailing_denial, 64} =
             System.cmd(
               claude_projection,
               [
                 "--symphony-launch-projection",
                 Path.join(session.runtime_root, "launch-projections/any.sh"),
                 "trailing"
               ],
               env: [{"HERDR_PANE_ID", "w1:p1"}],
               stderr_to_stdout: true
             )

    assert trailing_denial =~ "exactly one projection path"

    assert {containment_denial, 64} =
             System.cmd(claude_projection, ["--symphony-launch-projection", "/tmp/outside.sh"],
               env: [{"HERDR_PANE_ID", "w1:p1"}],
               stderr_to_stdout: true
             )

    assert containment_denial =~ "outside the session runtime root"

    escape_target = Path.join(Path.dirname(context.bin), "escape-target.sh")
    File.write!(escape_target, "#!/bin/sh\nexit 0\n")
    File.chmod!(escape_target, 0o500)
    symlink_projection = Path.join(session.runtime_root, "launch-projections/escape.sh")
    File.mkdir_p!(Path.join(session.runtime_root, "launch-projections"))
    File.ln_s!(escape_target, symlink_projection)

    assert {symlink_denial, 64} =
             System.cmd(claude_projection, ["--symphony-launch-projection", symlink_projection],
               env: [{"HERDR_PANE_ID", "w1:p1"}],
               stderr_to_stdout: true
             )

    assert symlink_denial =~ "symlink"
    File.rm!(symlink_projection)

    loose_projection = Path.join(session.runtime_root, "launch-projections/loose.sh")
    File.write!(loose_projection, "#!/bin/sh\nexit 0\n")
    File.chmod!(loose_projection, 0o755)

    assert {mode_denial, 64} =
             System.cmd(claude_projection, ["--symphony-launch-projection", loose_projection],
               env: [{"HERDR_PANE_ID", "w1:p1"}],
               stderr_to_stdout: true
             )

    assert mode_denial =~ "ownership or mode is invalid"
    File.rm!(loose_projection)

    provider_output = Path.join(Path.dirname(context.bin), "worker-provider.out")
    commands_before_substitution = File.read!(context.log)

    assert {substitution_error, 64} =
             System.cmd(session.worker_launcher, ["replacement_worker", "w1:p2"],
               env: base_env,
               stderr_to_stdout: true
             )

    assert substitution_error =~ "worker name must be implementer_worker"
    assert File.read!(context.log) == commands_before_substitution

    assert {_native_response, 0} =
             System.cmd(session.worker_launcher, ["implementer_worker", "w1:p2"],
               env: [
                 {"HERDR_FAKE_EXEC_PROVIDER", "1"},
                 {"HERDR_FAKE_LOG", context.log},
                 {"HERDR_FAKE_PROVIDER_OUTPUT", provider_output},
                 {"PATH", session.orchestrator_bin <> ":" <> provider_bin <> ":" <> (System.get_env("PATH") || "")},
                 {"SYMPHONY_SKILL_EXECUTION_CONTRACTS", ""},
                 {"XDG_CONFIG_HOME", session.runtime_root}
               ],
               stderr_to_stdout: true
             )

    worker_projection = File.read!(provider_output)
    assert worker_projection =~ "PATH=#{session.runtime_root}/worker-bin:#{provider_bin}:"
    assert worker_projection =~ "SKILLS=worker-contract"

    # The worker launch completed the acknowledged handshake: both acks carry
    # the launch token of the worker projection.
    [worker_ack_dir] =
      session.runtime_root
      |> Path.join("launch-acks/*")
      |> Path.wildcard()
      |> Enum.filter(&File.exists?(Path.join(&1, "wrapper.ack")))

    worker_token = Path.basename(worker_ack_dir)
    assert String.trim(File.read!(Path.join(worker_ack_dir, "wrapper.ack"))) == worker_token
    assert String.trim(File.read!(Path.join(worker_ack_dir, "projection.ack"))) == worker_token

    # A launch whose chain never ran cannot be satisfied by the acks of the
    # earlier successful launch: the launcher clears them and re-requires both.
    assert {missing_wrapper_ack, 67} =
             System.cmd(session.worker_launcher, ["implementer_worker", "w1:p2"],
               env: [
                 {"HERDR_FAKE_SKIP_LAUNCH", "1"},
                 {"HERDR_FAKE_LOG", context.log},
                 {"PATH", session.orchestrator_bin <> ":" <> provider_bin <> ":" <> (System.get_env("PATH") || "")},
                 {"XDG_CONFIG_HOME", session.runtime_root}
               ],
               stderr_to_stdout: true
             )

    assert missing_wrapper_ack =~ "worker launch wrapper acknowledgement missing or malformed"

    assert {missing_projection_ack, 68} =
             System.cmd(session.worker_launcher, ["implementer_worker", "w1:p2"],
               env: [
                 {"HERDR_FAKE_WRAPPER_ACK_ONLY", "1"},
                 {"HERDR_FAKE_LOG", context.log},
                 {"PATH", session.orchestrator_bin <> ":" <> provider_bin <> ":" <> (System.get_env("PATH") || "")},
                 {"XDG_CONFIG_HOME", session.runtime_root}
               ],
               stderr_to_stdout: true
             )

    assert missing_projection_ack =~ "worker launch projection acknowledgement missing or malformed"

    # Concurrent launcher invocations mint distinct launch tokens: each gets
    # its own projection copy, preflight, and ack pair — no cross-satisfaction
    # and no clearing of each other's launch state.
    ack_dirs_before = Path.wildcard(Path.join(session.runtime_root, "launch-acks/*"))

    concurrent_results =
      ["w1:p8", "w1:p9"]
      |> Enum.map(fn pane ->
        Task.async(fn ->
          System.cmd(session.worker_launcher, ["implementer_worker", pane],
            env: [
              {"HERDR_FAKE_LOG", context.log},
              {"PATH", session.orchestrator_bin <> ":" <> provider_bin <> ":" <> (System.get_env("PATH") || "")},
              {"XDG_CONFIG_HOME", session.runtime_root}
            ],
            stderr_to_stdout: true
          )
        end)
      end)
      |> Task.await_many(15_000)

    assert [{_, 0}, {_, 0}] = concurrent_results

    new_ack_dirs =
      Path.wildcard(Path.join(session.runtime_root, "launch-acks/*")) -- ack_dirs_before

    assert length(new_ack_dirs) == 2

    for ack_dir <- new_ack_dirs do
      token = Path.basename(ack_dir)
      assert String.trim(File.read!(Path.join(ack_dir, "wrapper.ack"))) == token
      assert String.trim(File.read!(Path.join(ack_dir, "projection.ack"))) == token
    end

    for role_herdr <- [worker_herdr, orchestrator_herdr] do
      File.write!(context.log, "")

      assert {_native_response, 0} =
               System.cmd(
                 role_herdr,
                 ["agent", "prompt", "implementer_orchestrator", "line one\nline two"],
                 env: base_env
               )

      commands = File.read!(context.log)
      assert length(:binary.matches(commands, "agent prompt implementer_orchestrator")) == 1
      refute commands =~ "pane run"
      refute commands =~ "pane send-text"
      refute commands =~ "pane send-keys"
    end

    recovery_cases = [
      {worker_herdr, "implementer_orchestrator", "OCTO_MSG/1 kind=result assignment=emb1312 status=completed", "result.*"},
      {orchestrator_herdr, "implementer_worker", "OCTO_MSG/1 kind=assignment assignment=emb1312", "assignment.*"}
    ]

    for {role_herdr, target, message, correlation_glob} <- recovery_cases do
      File.write!(context.log, "")
      File.rm(Path.join([session.runtime_root, "herdr", "sessions", "default", "prompt-attempts"]))

      correlations_before =
        Path.wildcard(Path.join([session.runtime_root, "worker-events", correlation_glob]))

      assert {_native_response, 0} =
               System.cmd(
                 role_herdr,
                 ["agent", "prompt", target, message],
                 env:
                   base_env ++
                     [
                       {"HERDR_FAKE_PROMPT_STALL_COUNT", "1"},
                       {"HERDR_FAKE_DELAYED_PROMPT_TRANSITION_SECONDS", "0.05"},
                       {"HERDR_REPLAY_WAIT", "agent-wait-working"}
                     ],
                 stderr_to_stdout: true
               )

      prompt_commands =
        context.log
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "agent prompt #{target}"))

      assert length(prompt_commands) == 1
      assert Enum.any?(prompt_commands, &String.contains?(&1, "#{message} --wait"))
      assert Enum.all?(prompt_commands, &String.contains?(&1, "--timeout 5001"))

      commands = File.read!(context.log)
      assert length(:binary.matches(commands, "agent send-keys #{target} enter")) == 1
      assert length(:binary.matches(commands, "agent wait #{target}")) == 1
      assert commands =~ "--until working --until blocked --timeout 750"

      [correlation] =
        Path.wildcard(Path.join([session.runtime_root, "worker-events", correlation_glob])) --
          correlations_before

      assert File.read!(correlation) == message <> "\n"

      File.write!(context.log, "")
      File.rm(Path.join([session.runtime_root, "herdr", "sessions", "default", "prompt-attempts"]))

      assert {failure, 70} =
               System.cmd(
                 role_herdr,
                 ["agent", "prompt", target, message],
                 env:
                   base_env ++
                     [
                       {"HERDR_FAKE_PROMPT_STALL_COUNT", "1"},
                       {"HERDR_FAKE_SEND_KEYS_FAIL", "1"}
                     ],
                 stderr_to_stdout: true
               )

      assert failure =~ "sabotage: agent send-keys refused"

      commands = File.read!(context.log)
      assert length(:binary.matches(commands, "agent prompt #{target}")) == 1
      assert length(:binary.matches(commands, "agent send-keys #{target} enter")) == 1
    end

    File.write!(context.log, "")
    File.rm(Path.join(default_state_root, "prompt-attempts"))
    File.rm(Path.join(default_state_root, "delayed-prompt-transition.implementer_worker"))
    fast_message = "OCTO_MSG/1 kind=assignment assignment=emb1312-fast"
    assignments_before = Path.wildcard(Path.join([session.runtime_root, "worker-events", "assignment.*"]))

    assert {fast_settled, 0} =
             System.cmd(
               orchestrator_herdr,
               ["agent", "prompt", "implementer_worker", fast_message],
               env:
                 base_env ++
                   [
                     {"HERDR_FAKE_PROMPT_STALL_COUNT", "1"},
                     {"HERDR_FAKE_DELAYED_PROMPT_TRANSITION_SECONDS", "0.05"},
                     {"HERDR_REPLAY_WAIT", "error-agent-wait-timeout"}
                   ],
               stderr_to_stdout: true
             )

    assert fast_settled =~ ~s("agent_status":"idle")
    commands = File.read!(context.log)
    assert length(:binary.matches(commands, "agent prompt implementer_worker")) == 1
    assert length(:binary.matches(commands, "agent send-keys implementer_worker enter")) == 1
    assert length(:binary.matches(commands, "agent wait implementer_worker")) == 1
    assert length(:binary.matches(commands, "agent get implementer_worker")) == 1

    [fast_assignment] =
      Path.wildcard(Path.join([session.runtime_root, "worker-events", "assignment.*"])) --
        assignments_before

    assert File.read!(fast_assignment) == fast_message <> "\n"

    for {fixture, expected_status} <- [
          {"agent-wait-blocked", "blocked"},
          {generated_unknown_fixture, "unknown"}
        ] do
      File.write!(context.log, "")
      File.rm(Path.join(default_state_root, "prompt-attempts"))
      results_before = Path.wildcard(Path.join([session.runtime_root, "worker-events", "result.*"]))
      assert results_before != []

      assert {non_success, 1} =
               System.cmd(
                 worker_herdr,
                 [
                   "agent",
                   "prompt",
                   "implementer_orchestrator",
                   "OCTO_MSG/1 kind=result assignment=emb1312-#{expected_status} status=failed"
                 ],
                 env:
                   base_env ++
                     [
                       {"HERDR_FAKE_PROMPT_STALL_COUNT", "1"},
                       {"HERDR_REPLAY_WAIT", fixture}
                     ],
                 stderr_to_stdout: true
               )

      assert non_success =~ ~s("agent_status":"#{expected_status}")
      assert Path.wildcard(Path.join([session.runtime_root, "worker-events", "result.*"])) == results_before
      commands = File.read!(context.log)
      assert length(:binary.matches(commands, "agent send-keys implementer_orchestrator enter")) == 1
      refute commands =~ "agent get implementer_orchestrator"
    end

    for args <- [
          ["agent", "list"],
          ["agent", "get", "implementer_orchestrator"],
          ["agent", "read", "implementer_orchestrator"],
          ["agent", "prompt", "implementer_orchestrator", "worker result"],
          ["agent", "wait", "implementer_orchestrator", "--until", "idle", "--timeout", "100"]
        ] do
      assert {_native_response, 0} = System.cmd(worker_herdr, args, env: base_env, stderr_to_stdout: true)
    end

    for role_herdr <- [worker_herdr, orchestrator_herdr],
        args <- [
          ["agent", "send-keys", "implementer_orchestrator", "enter"],
          ["pane", "send-keys", "w1:p2", "enter"]
        ] do
      assert {denied, 64} = System.cmd(role_herdr, args, env: base_env, stderr_to_stdout: true)
      assert denied =~ "Herdr authority denies"
    end

    for args <- [
          ["agent", "start", "descendant"],
          ["pane", "run", "w1:p2", "legacy"],
          ["pane", "send-text", "w1:p2", "raw"],
          ["pane", "split", "w1:p2", "--direction", "right"],
          ["workspace", "create"],
          ["server", "stop"]
        ] do
      assert {denied, 64} = System.cmd(worker_herdr, args, env: base_env, stderr_to_stdout: true)
      assert denied =~ "worker Herdr authority denies"
    end

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "large provider instructions stay out of orchestrator and worker pane commands", context do
    instructions =
      String.duplicate(
        """
        Follow the role's "quoted" instructions.
        Preserve 'single quotes', $shell tokens, and \\literal escapes.
        """,
        80
      )

    for {provider, executable, instruction_args} <- [
          {"codex", "codex", ["--config", "developer_instructions=#{inspect(instructions)}"]},
          {"claude_code", "claude", ["--append-system-prompt", instructions]}
        ] do
      session_name = "octo-emb-1234-#{provider}-#{System.unique_integer([:positive])}"
      provider_bin = Path.join([Path.dirname(context.bin), provider, "provider-bin"])
      provider_output = Path.join(Path.dirname(context.bin), "#{provider}-provider.out")
      fake_provider = Path.join(provider_bin, executable)
      File.mkdir_p!(provider_bin)

      File.write!(fake_provider, """
      #!/bin/sh
      printf '%s\n' "$@"
      """)

      File.chmod!(fake_provider, 0o755)

      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [{"HERDR_FAKE_LOG", context.log}],
        start_timeout_ms: 2_000,
        poll_interval_ms: 10
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: session_name,
                   isolated: true,
                   workspace: "/tmp/selected-workspace",
                   env: %{
                     "HERDR_FAKE_EXEC_PROVIDER" => "1",
                     "HERDR_FAKE_PROVIDER_OUTPUT" => provider_output,
                     "PATH" => provider_bin <> ":" <> (System.get_env("PATH") || "")
                   }
                 },
                 adapter_context
               )

      on_exit(fn ->
        if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
      end)

      argv = [executable, "--model", "test-model"] ++ instruction_args

      assert {:ok, prepared} =
               HerdrTransport.prepare_worker(
                 session,
                 %{provider: provider, argv: argv, env: %{}},
                 adapter_context
               )

      File.write!(context.log, "")

      assert {:ok, _agent} =
               HerdrTransport.start_agent(
                 prepared,
                 %{
                   name: "implementer_orchestrator",
                   cwd: "/tmp/selected-workspace",
                   provider: provider,
                   argv: argv
                 },
                 adapter_context
               )

      orchestrator_command = File.read!(context.log)
      assert byte_size(orchestrator_command) < 1_024
      refute orchestrator_command =~ instructions

      expected_provider_instruction =
        if provider == "codex",
          do: "developer_instructions=#{inspect(instructions)}",
          else: String.replace(instructions, "\n", "\u2028")

      assert File.read!(provider_output) =~ expected_provider_instruction

      File.write!(context.log, "")

      assert {_response, 0} =
               System.cmd(prepared.worker_launcher, ["implementer_worker", "w1:p2"],
                 env: [
                   {"HERDR_FAKE_EXEC_PROVIDER", "1"},
                   {"HERDR_FAKE_LOG", context.log},
                   {"HERDR_FAKE_PROVIDER_OUTPUT", provider_output},
                   {"PATH", prepared.orchestrator_bin <> ":" <> provider_bin <> ":" <> (System.get_env("PATH") || "")},
                   {"XDG_CONFIG_HOME", prepared.runtime_root}
                 ],
                 stderr_to_stdout: true
               )

      worker_command = File.read!(context.log)
      assert byte_size(worker_command) < 1_024
      refute worker_command =~ instructions
      assert File.read!(provider_output) =~ expected_provider_instruction

      assert :ok = HerdrTransport.stop_session(prepared, adapter_context)
    end
  end

  test "creates, controls, and cleans up only the named isolated session", context do
    adapter_context = %{
      herdr_bin: context.bin,
      runtime_root: context.runtime_root,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10
    }

    assert {:ok, default_before} = HerdrTransport.default_server_snapshot(adapter_context)
    assert default_before.socket == "/tmp/operator-default/herdr.sock"

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1141-run-7",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert session.name == "octo-emb-1141-run-7"
    assert String.starts_with?(session.runtime_root, "/tmp/octo-herdr-")
    assert String.length(session.socket) <= 103
    assert session.socket == Path.join(session.runtime_root, "herdr/sessions/octo-emb-1141-run-7/herdr.sock")
    assert session.pane_id == "w1:p1"
    refute Map.has_key?(session, :worker_launcher)

    assert File.read!(Path.join(session.runtime_root, "herdr/config.toml")) =~
             """
             [update]
             version_check = false
             manifest_check = false
             """

    worker_argv = [
      "codex",
      "--config",
      "default_permissions=\"octo_herdr\"",
      "--config",
      "permissions.octo_herdr.network={enabled=true,unix_sockets={#{inspect(session.socket)}=\"allow\"}}"
    ]

    contract_json = ~s([{"skill":"linear"}])

    assert {:ok, session} =
             HerdrTransport.prepare_worker(
               session,
               %{
                 provider: "codex",
                 argv: worker_argv,
                 env: %{"SYMPHONY_SKILL_EXECUTION_CONTRACTS" => contract_json}
               },
               adapter_context
             )

    assert File.exists?(session.worker_launcher)
    assert File.exists?(Path.join(session.orchestrator_bin, "herdr"))
    launcher = File.read!(session.worker_launcher)
    provider_wrapper = File.read!(Path.join(session.orchestrator_bin, "codex"))
    [worker_projection_path] = Path.wildcard(Path.join(session.runtime_root, "launch-projections/*.sh"))
    worker_projection = File.read!(worker_projection_path)

    assert launcher =~ "agent start \"$1\" --kind 'codex' --pane \"$2\""
    refute launcher =~ "default_permissions=\"octo_herdr\""
    refute launcher =~ session.socket
    assert worker_projection =~ "default_permissions=\"octo_herdr\""
    assert worker_projection =~ session.socket
    refute launcher =~ "exec 'codex'"
    assert provider_wrapper =~ "export SYMPHONY_SKILL_EXECUTION_CONTRACTS="
    assert provider_wrapper =~ contract_json
    assert provider_wrapper =~ "export PATH='#{session.runtime_root}/worker-bin':"

    restricted_herdr = Path.join(session.runtime_root, "worker-bin/herdr")
    assert File.exists?(restricted_herdr)
    assert {output, 64} = System.cmd(restricted_herdr, ["agent", "start", "descendant"], stderr_to_stdout: true)
    assert output =~ "worker Herdr authority denies"

    assert {_native_response, 0} =
             System.cmd(
               restricted_herdr,
               [
                 "agent",
                 "prompt",
                 "implementer_orchestrator",
                 "OCTO_MSG/1 kind=result assignment=assignment-1 status=completed"
               ],
               env: [{"HERDR_FAKE_LOG", context.log}, {"XDG_CONFIG_HOME", session.runtime_root}]
             )

    orchestrator_herdr = Path.join(session.orchestrator_bin, "herdr")

    assert {_native_response, 0} =
             System.cmd(
               orchestrator_herdr,
               [
                 "agent",
                 "prompt",
                 "implementer_worker",
                 "OCTO_MSG/1 kind=assignment assignment=assignment-1 deliverable=bounded"
               ],
               env: [{"HERDR_FAKE_LOG", context.log}, {"XDG_CONFIG_HOME", session.runtime_root}]
             )

    assert {:ok,
            [
              %{
                assignment_id: "assignment-1",
                status: :completed,
                result: %{
                  assignment_id: "assignment-1",
                  status: "completed"
                }
              }
            ]} = HerdrTransport.worker_assignments(session, adapter_context)

    assert {_native_response, 0} =
             System.cmd(
               restricted_herdr,
               ["agent", "wait", "implementer_orchestrator", "--until", "idle", "--timeout", "100"],
               env: [{"HERDR_FAKE_LOG", context.log}, {"XDG_CONFIG_HOME", session.runtime_root}]
             )

    orchestrator_spec = %{
      name: "implementer_orchestrator",
      provider: "codex",
      cwd: "/tmp/selected-workspace",
      argv: ["codex", "--model", "gpt-5.6-sol", "--config", "model_reasoning_effort=medium"]
    }

    assert {:ok, orchestrator} = HerdrTransport.start_agent(session, orchestrator_spec, adapter_context)
    assert orchestrator.name == "implementer_orchestrator"
    assert orchestrator.pane_id == "w1:p1"
    assert orchestrator.provider == "codex"

    assert {:ok, %{phase: :working, agent: started_turn}} =
             HerdrTransport.begin_turn(
               session,
               orchestrator,
               "Codex assignment",
               3_000,
               adapter_context
             )

    assert started_turn.provider == "codex"

    assert {:ok, ready_orchestrator} =
             HerdrTransport.await_agent(session, orchestrator, ["idle", "done", "blocked"], 3_000, adapter_context)

    assert ready_orchestrator.agent == "codex"
    assert ready_orchestrator.agent_status == "idle"

    assert ready_orchestrator.agent_session ==
             HerdrReplayFixture.agent_field!("agent-wait-idle", "agent_session", %{"{{AGENT_KIND}}" => "codex"})

    recorded_read_text = HerdrReplayFixture.stdout!("agent-read-recent")

    assert {:ok, %{text: ^recorded_read_text}} =
             HerdrTransport.read_agent(
               session,
               ready_orchestrator,
               %{source: :recent_unwrapped, lines: 240},
               adapter_context
             )

    # Deterministic Codex coverage: the fake injects `--yolo` for kind codex,
    # and the wrapper records the exact observed flag before stripping it.
    [codex_ack_dir] = Path.wildcard(Path.join(session.runtime_root, "launch-acks/*"))
    assert String.trim(File.read!(Path.join(codex_ack_dir, "injected-flag"))) == "--yolo"

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
    refute File.exists?(session.runtime_root)

    assert {:ok, ^default_before} = HerdrTransport.default_server_snapshot(adapter_context)

    commands = File.read!(context.log)
    assert commands =~ "--session octo-emb-1141-run-7 server\n"
    assert commands =~ "--session octo-emb-1141-run-7 workspace create --cwd /tmp/selected-workspace --no-focus"

    assert commands =~
             "--session octo-emb-1141-run-7 agent start implementer_orchestrator --kind codex --pane w1:p1 --timeout 120000 -- --symphony-launch-projection /"

    refute commands =~ "model_reasoning_effort=medium"

    assert commands =~
             "--session octo-emb-1141-run-7 agent prompt implementer_orchestrator Codex assignment --wait --until working --until idle --until done --until blocked --timeout 5001"

    assert commands =~
             "--session octo-emb-1141-run-7 agent wait implementer_orchestrator --until idle --until done --until blocked --timeout 3000"

    assert commands =~
             "agent prompt implementer_orchestrator OCTO_MSG/1 kind=result assignment=assignment-1 status=completed"

    assert commands =~
             "agent prompt implementer_worker OCTO_MSG/1 kind=assignment assignment=assignment-1 deliverable=bounded"

    assert_pane_runs_only_prepare_launch(commands)
    refute commands =~ "pane send-text"
    assert commands =~ "--session octo-emb-1141-run-7 server stop\n"
  end

  test "rejects an incompatible isolated Herdr server and removes its runtime root", context do
    HerdrReplayFixture.write_replay_mutation!(
      context.replay_dir,
      "status-server-running",
      "status-server-0.8.0",
      &String.replace(&1, "version: 0.7.5", "version: 0.8.0")
    )

    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_REPLAY_STATUS_RUNNING", "status-server-0.8.0"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10
    }

    incompatible_runtime = %{
      expected_version: "0.7.5",
      expected_protocol: 17,
      actual_version: "0.8.0",
      actual_protocol: 17
    }

    session_name = "octo-emb-1244-i-#{System.unique_integer([:positive])}"

    assert {:error, {:incompatible_herdr_runtime, ^incompatible_runtime}} =
             HerdrTransport.start_session(
               %{name: session_name, isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    commands = File.read!(context.log)
    assert commands =~ "--session #{session_name} status server"
  end

  test "a native protocol mismatch is a typed incompatible-runtime failure", context do
    HerdrReplayFixture.write_replay_mutation!(
      context.replay_dir,
      "error-agent-wait-not-found",
      "error-protocol-mismatch",
      &String.replace(&1, ~s("code":"agent_not_found"), ~s("code":"protocol_mismatch"))
    )

    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_REPLAY_WAIT", "error-protocol-mismatch"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1244-pm-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:error,
            {:incompatible_herdr_runtime,
             %{
               expected_version: "0.7.5",
               expected_protocol: 17,
               actual_version: nil,
               actual_protocol: nil,
               error_code: "protocol_mismatch"
             }}} =
             HerdrTransport.await_agent(
               session,
               %{name: "implementer_orchestrator"},
               ["idle", "done", "blocked"],
               1_000,
               adapter_context
             )

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "unknown and unsettled or out-of-enum statuses never read as completion", context do
    for {source, mutation, target, expected} <- [
          {"agent-wait-idle", ~s("agent_status":"unknown"), {"HERDR_REPLAY_WAIT", "agent-wait-unknown"}, {:herdr_agent_status_unknown, "implementer_orchestrator"}},
          {"agent-wait-idle", ~s("agent_status":"working"), {"HERDR_REPLAY_WAIT", "agent-wait-working-settle"}, {:herdr_agent_wait_unsettled, "implementer_orchestrator", "working"}},
          {"agent-wait-idle", ~s("agent_status":"resting"), {"HERDR_REPLAY_WAIT", "agent-wait-out-of-enum"},
           {:incompatible_herdr_runtime,
            %{
              error_code: "unrecognized_agent_status",
              actual_status: "resting",
              expected_statuses: ["idle", "working", "blocked", "done", "unknown"]
            }}}
        ] do
      {env_key, replay_name} = target

      HerdrReplayFixture.write_replay_mutation!(
        context.replay_dir,
        source,
        replay_name,
        &String.replace(&1, ~s("agent_status":"idle"), mutation)
      )

      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [{"HERDR_FAKE_LOG", context.log}, {env_key, replay_name}],
        start_timeout_ms: 2_000,
        poll_interval_ms: 5
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: "octo-emb-1244-u#{System.unique_integer([:positive])}",
                   isolated: true,
                   workspace: "/tmp/selected-workspace"
                 },
                 adapter_context
               )

      assert {:error, ^expected} =
               HerdrTransport.await_agent(
                 session,
                 %{name: "implementer_orchestrator"},
                 ["idle", "done", "blocked"],
                 1_000,
                 adapter_context
               )

      assert :ok = HerdrTransport.stop_session(session, adapter_context)
    end
  end

  test "a prompt observation of unknown is the typed unknown outcome, never turn start or completion",
       context do
    HerdrReplayFixture.write_replay_mutation!(
      context.replay_dir,
      "agent-prompt-working",
      "agent-prompt-unknown",
      &String.replace(&1, ~s("agent_status":"working"), ~s("agent_status":"unknown"))
    )

    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_REPLAY_PROMPT", "agent-prompt-unknown"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1244-pu-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: ["claude", "--model", "claude-fable-5"]
               },
               adapter_context
             )

    assert {:error, {:herdr_agent_status_unknown, "implementer_orchestrator"}} =
             HerdrTransport.begin_turn(session, agent, "Complete the assignment.", 6_000, adapter_context)

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "rejects a session whose workspace creation replays a recorded error and removes its runtime root",
       context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_REPLAY_WORKSPACE_CREATE", "error-agent-get-not-found"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10
    }

    session_name = "octo-emb-1244-reject-#{System.unique_integer([:positive])}"

    assert {:error, {:herdr_workspace_create_failed, _reason}} =
             HerdrTransport.start_session(
               %{name: session_name, isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    commands = File.read!(context.log)
    assert commands =~ "--session #{session_name} workspace create"
    assert commands =~ "--session #{session_name} server stop"
  end

  test "bounds a stalled readiness probe and cleans the isolated runtime", context do
    status_pid_file = Path.join(Path.dirname(context.bin), "stalled-status.pid")
    server_pid_file = Path.join(Path.dirname(context.bin), "stalled-server.pid")
    runtime_root = Path.join(System.tmp_dir!(), "octo-herdr-stall-#{System.unique_integer([:positive])}")

    adapter_context = %{
      herdr_bin: context.bin,
      socket_root: runtime_root,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_STATUS_STALL", "1"},
        {"HERDR_FAKE_STATUS_STALL_SECONDS", "2"},
        {"HERDR_FAKE_STATUS_PID_FILE", status_pid_file},
        {"HERDR_FAKE_SERVER_PID_FILE", server_pid_file}
      ],
      start_timeout_ms: 250,
      poll_interval_ms: 5
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :herdr_server_start_timeout} =
             HerdrTransport.start_session(
               %{name: "octo-emb-1201-stalled-status", isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 750
    refute File.exists?(runtime_root)
    refute process_alive?(File.read!(status_pid_file))
    refute process_alive?(File.read!(server_pid_file))
  end

  test "begins a turn through one atomic native prompt", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{name: "octo-emb-1141-confirm", isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: ["claude", "--model", "claude-fable-5"]
               },
               adapter_context
             )

    assert {:ok, ready} =
             HerdrTransport.await_agent(session, agent, ["idle", "done", "blocked"], 3_000, adapter_context)

    assert {:ok, %{phase: :working, agent: observed}} =
             HerdrTransport.begin_turn(session, ready, "Complete the assignment.", 1_000, adapter_context)

    assert observed.agent_status == "working"
    assert observed.revision == HerdrReplayFixture.agent_field!("agent-prompt-working", "revision")
    assert observed.provider == "claude_code"

    commands = File.read!(context.log)
    assert length(:binary.matches(commands, "agent prompt implementer_orchestrator")) == 1
    assert_pane_runs_only_prepare_launch(commands)
    refute commands =~ "pane send-text"
    refute commands =~ "pane send-keys"
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "recovers a stalled prompt with one Enter for both providers", context do
    for provider <- ["codex", "claude_code"] do
      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_PROMPT_STALL_COUNT", "1"},
          {"HERDR_FAKE_DELAYED_PROMPT_TRANSITION_SECONDS", "0.01"},
          {"HERDR_REPLAY_WAIT", "agent-wait-working"}
        ],
        start_timeout_ms: 2_000,
        poll_interval_ms: 5
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: "octo-emb-1231-recover-#{provider}",
                   isolated: true,
                   workspace: "/tmp/selected-workspace"
                 },
                 adapter_context
               )

      on_exit(fn ->
        if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
      end)

      executable = if provider == "codex", do: "codex", else: "claude"

      assert {:ok, agent} =
               HerdrTransport.start_agent(
                 session,
                 %{
                   name: "implementer_orchestrator",
                   provider: provider,
                   cwd: "/tmp/selected-workspace",
                   argv: [executable, "--model", "test-model"]
                 },
                 adapter_context
               )

      assert {:ok, %{phase: :working, agent: observed}} =
               HerdrTransport.begin_turn(
                 session,
                 agent,
                 "Complete the assignment.",
                 6_000,
                 adapter_context
               )

      assert observed.agent_status == "working"

      prompt_commands =
        context.log
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "agent prompt implementer_orchestrator"))

      assert Enum.any?(prompt_commands, &String.contains?(&1, "Complete the assignment."))
      assert length(prompt_commands) == 1
      assert Enum.all?(prompt_commands, &String.contains?(&1, "--timeout 5001"))

      commands = File.read!(context.log)
      assert length(:binary.matches(commands, "agent send-keys implementer_orchestrator enter")) == 1
      assert length(:binary.matches(commands, "agent wait implementer_orchestrator")) == 1
      assert commands =~ "--until working --until blocked --timeout 750"
      refute commands =~ "agent get implementer_orchestrator"
      refute commands =~ "agent prompt implementer_orchestrator   --wait"
      assert :ok = HerdrTransport.stop_session(session, adapter_context)
      File.write!(context.log, "")
    end
  end

  test "returns a typed failure when the one Enter recovery fails", context do
    for provider <- ["codex", "claude_code"] do
      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_PROMPT_STALL_COUNT", "1"},
          {"HERDR_FAKE_SEND_KEYS_FAIL", "1"}
        ],
        start_timeout_ms: 2_000,
        poll_interval_ms: 5
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: "octo-emb-1231-exhausted-#{provider}",
                   isolated: true,
                   workspace: "/tmp/selected-workspace"
                 },
                 adapter_context
               )

      executable = if provider == "codex", do: "codex", else: "claude"

      assert {:ok, agent} =
               HerdrTransport.start_agent(
                 session,
                 %{
                   name: "implementer_orchestrator",
                   provider: provider,
                   cwd: "/tmp/selected-workspace",
                   argv: [executable, "--model", "test-model"]
                 },
                 adapter_context
               )

      assert {:error, {:herdr_agent_send_keys_failed, "implementer_orchestrator", {:port_exit, 70, failure}}} =
               HerdrTransport.begin_turn(
                 session,
                 agent,
                 "Complete the assignment.",
                 6_000,
                 adapter_context
               )

      assert failure =~ "sabotage: agent send-keys refused"

      commands = File.read!(context.log)
      assert length(:binary.matches(commands, "agent prompt implementer_orchestrator")) == 1
      assert length(:binary.matches(commands, "agent send-keys implementer_orchestrator enter")) == 1
      assert :ok = HerdrTransport.stop_session(session, adapter_context)
      File.write!(context.log, "")
    end
  end

  test "accepts a delayed Herdr revision transition inside the turn-start deadline", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_PROMPT_STALL_COUNT", "1"},
        {"HERDR_FAKE_DELAYED_PROMPT_TRANSITION_SECONDS", "0.05"},
        {"HERDR_REPLAY_WAIT", "error-agent-wait-timeout"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1312-delayed-transition-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "codex",
                 cwd: "/tmp/selected-workspace",
                 argv: ["codex", "--model", "gpt-5.6-sol"]
               },
               adapter_context
             )

    assert {:ok, %{phase: :completed, agent: observed}} =
             HerdrTransport.begin_turn(
               session,
               agent,
               "Complete the assignment.",
               1_000,
               adapter_context
             )

    assert observed.agent_status == "idle"
    assert observed.revision == agent.revision + 1
    assert observed.provider == "codex"

    commands = File.read!(context.log)
    assert length(:binary.matches(commands, "agent prompt implementer_orchestrator")) == 1
    assert length(:binary.matches(commands, "agent send-keys implementer_orchestrator enter")) == 1
    assert length(:binary.matches(commands, "agent wait implementer_orchestrator")) == 1
    assert commands =~ "--until working --until blocked --timeout 750"
    assert length(:binary.matches(commands, "agent get implementer_orchestrator")) == 1
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "prompt submissions settle on the upstream default set plus working and exceed the prompt-effect window",
       context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1244-prompt-settle-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: ["claude", "--model", "claude-fable-5"]
               },
               adapter_context
             )

    assert {:ok, %{phase: :working}} =
             HerdrTransport.begin_turn(session, agent, "Complete the assignment.", 5_000, adapter_context)

    [prompt_command] =
      context.log
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "agent prompt implementer_orchestrator"))

    assert prompt_command =~ "--until working --until idle --until done --until blocked"
    refute prompt_command =~ "--until unknown"
    assert prompt_command =~ "--timeout 5001"
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "one 5001ms deadline bounds prompt and recovery without restarting", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_PROMPT_STALL_COUNT", "1"},
        {"HERDR_FAKE_PROMPT_STALL_DELAY_SECONDS", "4.2"},
        {"HERDR_FAKE_DELAYED_PROMPT_TRANSITION_SECONDS", "1"},
        {"HERDR_REPLAY_WAIT", "agent-wait-working"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1244-stall-boundary-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "codex",
                 cwd: "/tmp/selected-workspace",
                 argv: ["codex", "--model", "gpt-5.6-sol"]
               },
               adapter_context
             )

    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:herdr_agent_status_timeout, "implementer_orchestrator", ["working", "idle", "done"]}} =
             HerdrTransport.begin_turn(session, agent, "Complete the assignment.", 5_000, adapter_context)

    assert System.monotonic_time(:millisecond) - started_at < 5_500
    commands = File.read!(context.log)
    assert length(:binary.matches(commands, "agent prompt implementer_orchestrator")) == 1
    assert length(:binary.matches(commands, "agent send-keys implementer_orchestrator enter")) == 1
    assert length(:binary.matches(commands, "agent wait implementer_orchestrator")) == 1
    refute commands =~ "agent get implementer_orchestrator"
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "an agent started on a worker pane replays that pane in the observed envelope", context do
    state_root = Path.join(Path.dirname(context.bin), "pane-replay-state")
    File.mkdir_p!(state_root)

    assert {start_output, 0} =
             System.cmd(
               context.bin,
               ["--session", "s1", "agent", "start", "implementer_worker", "--kind", "claude"] ++
                 ["--pane", "w1:p2", "--timeout", "1000", "--", "claude", "--model", "haiku"],
               env: [
                 {"HERDR_FAKE_LOG", context.log},
                 {"XDG_CONFIG_HOME", state_root},
                 {"HERDR_FAKE_SKIP_LAUNCH", "1"}
               ],
               stderr_to_stdout: true
             )

    assert start_output =~ ~s("pane_id":"w1:p2")
    refute start_output =~ ~s("pane_id":"w1:p1")
  end

  test "the status vocabulary documented by the recorded real-binary help output is the pinned five-state enum" do
    assert HerdrReplayFixture.documented_statuses!() == HerdrReplayFixture.known_statuses()
    assert HerdrReplayFixture.known_statuses() == ["idle", "working", "blocked", "done", "unknown"]
  end

  test "a prompt that settles blocked is a typed blocked outcome, never success", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_REPLAY_PROMPT", "agent-get-blocked"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1244-pb-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: ["claude", "--model", "claude-fable-5"]
               },
               adapter_context
             )

    assert {:error, {:herdr_agent_blocked, "implementer_orchestrator"}} =
             HerdrTransport.begin_turn(session, agent, "Complete the assignment.", 6_000, adapter_context)

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "an await that settles blocked is a typed blocked outcome under the upstream default settle set", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_REPLAY_WAIT", "agent-wait-blocked"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1244-await-blocked-#{System.unique_integer([:positive])}",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: ["claude", "--model", "claude-fable-5"]
               },
               adapter_context
             )

    assert {:error, {:herdr_agent_blocked, "implementer_orchestrator"}} =
             HerdrTransport.await_agent(session, agent, ["idle", "done", "blocked"], 3_000, adapter_context)

    [wait_command] =
      context.log
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "agent wait implementer_orchestrator"))

    assert wait_command =~ "--until idle --until done --until blocked"
    refute wait_command =~ "--until unknown"
    refute wait_command =~ "--until working"
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "recognizes a prompt that completes before the caller observes working", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_REPLAY_PROMPT", "agent-prompt-idle"}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{name: "octo-emb-1141-fast", isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: ["claude", "--model", "claude-fable-5"]
               },
               adapter_context
             )

    assert {:ok, ready} =
             HerdrTransport.await_agent(session, agent, ["idle", "done", "blocked"], 3_000, adapter_context)

    assert {:ok, %{phase: :completed, agent: observed}} =
             HerdrTransport.begin_turn(session, ready, "Complete immediately.", 1_000, adapter_context)

    assert observed.agent_status == "idle"
    assert observed.revision == HerdrReplayFixture.agent_field!("agent-prompt-idle", "revision")

    commands = File.read!(context.log)
    assert length(:binary.matches(commands, "agent prompt implementer_orchestrator")) == 1
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "starts Claude with multiline-preserving control-safe native args", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      agent_start_timeout_ms: 45_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1201-claude-kind",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    assert {:ok, agent} =
             HerdrTransport.start_agent(
               session,
               %{
                 name: "implementer_orchestrator",
                 provider: "claude_code",
                 cwd: "/tmp/selected-workspace",
                 argv: [
                   "claude",
                   "--model",
                   "claude-fable-5",
                   "--effort",
                   "high",
                   "--append-system-prompt",
                   "Follow the profile.\r\n\tDo not delegate.\rFinish safely."
                 ]
               },
               adapter_context
             )

    assert agent.provider == "claude_code"

    commands = File.read!(context.log)

    assert commands =~
             "agent start implementer_orchestrator --kind claude --pane w1:p1 --timeout 45000 -- "

    refute commands =~ "Follow the profile."

    [projection_path] = Path.wildcard(Path.join(session.runtime_root, "launch-projections/*.sh"))
    projection = File.read!(projection_path)
    assert projection =~ "--model"
    assert projection =~ "claude-fable-5"
    assert projection =~ "--append-system-prompt"
    assert projection =~ "Follow the profile.\u2028    Do not delegate.\u2028Finish safely."

    refute commands =~ "-- -- claude"

    launched_command =
      commands
      |> String.trim_trailing()
      |> String.split("\n")
      |> List.last()

    refute Regex.match?(~r/\p{Cc}/u, launched_command)
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "shares the 120-second cold-start budget across orchestrator and worker startup", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1227-shared-cold-start-budget",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    claude_spec = %{
      name: "implementer_orchestrator",
      provider: "claude_code",
      cwd: "/tmp/selected-workspace",
      argv: ["claude", "--model", "claude-sonnet-5"]
    }

    assert {:ok, _agent} = HerdrTransport.start_agent(session, claude_spec, adapter_context)
    assert {:ok, prepared} = HerdrTransport.prepare_worker(session, claude_spec, adapter_context)

    commands = File.read!(context.log)
    launcher = File.read!(prepared.worker_launcher)

    assert commands =~ "agent start implementer_orchestrator --kind claude --pane w1:p1 --timeout 120000"
    assert launcher =~ ~s(agent start "$1" --kind 'claude' --pane "$2" --timeout 120000)
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "rejects unrepresentable Claude controls before invoking Herdr", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1227-unrepresentable-control",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(session.runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    for control <- ["\0", "\u0085"] do
      claude_spec = %{
        name: "implementer_orchestrator",
        provider: "claude_code",
        cwd: "/tmp/selected-workspace",
        argv: ["claude", "--append-system-prompt", "unsafe#{control}instruction"]
      }

      commands_before = File.read!(context.log)
      invalid_control = {:invalid_herdr_agent_argument, :unrepresentable_control_character}

      assert {:error, {:herdr_agent_start_failed, ^invalid_control}} =
               HerdrTransport.start_agent(session, claude_spec, adapter_context)

      assert {:error, ^invalid_control} =
               HerdrTransport.prepare_worker(session, claude_spec, adapter_context)

      assert File.read!(context.log) == commands_before
    end

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "returns a typed closed-agent prompt failure", context do
    for {scenario, extra_env, expected} <- [
          {"closed", [{"HERDR_REPLAY_PROMPT", "error-agent-prompt-not-found"}], :herdr_agent_closed}
        ] do
      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [{"HERDR_FAKE_LOG", context.log}] ++ extra_env,
        start_timeout_ms: 2_000,
        poll_interval_ms: 5
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: "octo-emb-1201-#{scenario}",
                   isolated: true,
                   workspace: "/tmp/selected-workspace"
                 },
                 adapter_context
               )

      assert {:ok, agent} =
               HerdrTransport.start_agent(
                 session,
                 %{
                   name: "implementer_orchestrator",
                   provider: "codex",
                   cwd: "/tmp/selected-workspace",
                   argv: ["codex", "--model", "gpt-5.6-sol"]
                 },
                 adapter_context
               )

      assert {:error, {^expected, "implementer_orchestrator"}} =
               HerdrTransport.begin_turn(
                 session,
                 agent,
                 "Complete the assignment.",
                 6_000,
                 adapter_context
               )

      assert :ok = HerdrTransport.stop_session(session, adapter_context)
    end
  end

  test "maps bounded native wait timeout and closed-agent errors", context do
    for {fixture, expected} <- [
          {"error-agent-wait-timeout", {:herdr_agent_status_timeout, "implementer_orchestrator", ["idle", "done", "blocked"]}},
          {"error-agent-wait-not-found", {:herdr_agent_closed, "implementer_orchestrator"}}
        ] do
      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_REPLAY_WAIT", fixture}
        ],
        start_timeout_ms: 2_000,
        poll_interval_ms: 5
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: "octo-emb-1201-wait-#{if fixture =~ "timeout", do: "t", else: "c"}",
                   isolated: true,
                   workspace: "/tmp/selected-workspace"
                 },
                 adapter_context
               )

      assert {:ok, agent} =
               HerdrTransport.start_agent(
                 session,
                 %{
                   name: "implementer_orchestrator",
                   provider: "codex",
                   cwd: "/tmp/selected-workspace",
                   argv: ["codex", "--model", "gpt-5.6-sol"]
                 },
                 adapter_context
               )

      assert {:error, ^expected} =
               HerdrTransport.await_agent(
                 session,
                 agent,
                 ["idle", "done", "blocked"],
                 1_000,
                 adapter_context
               )

      assert :ok = HerdrTransport.stop_session(session, adapter_context)
    end
  end

  test "an ownership reference stops an abandoned run idempotently", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 10
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{name: "octo-emb-1141-abandoned", isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    ownership_ref = HerdrTransport.owned_session_ref(session, adapter_context)

    assert ownership_ref.kind == "herdr"
    assert ownership_ref.session_name == "octo-emb-1141-abandoned"
    assert :ok = HerdrTransport.cleanup_owned_session(ownership_ref)
    assert :ok = HerdrTransport.cleanup_owned_session(ownership_ref)

    refute File.exists?(session.runtime_root)

    commands = File.read!(context.log)
    assert commands =~ "--session octo-emb-1141-abandoned server stop"
  end

  test "an ownership reference recovers an explicitly owned custom socket root", context do
    runtime_root =
      Path.join(System.tmp_dir!(), "octo-herdr-custom-#{System.unique_integer([:positive])}")

    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      socket_root: runtime_root,
      start_timeout_ms: 2_000,
      poll_interval_ms: 10
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{name: "octo-emb-1201-custom-owned", isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    on_exit(fn ->
      if File.exists?(runtime_root), do: HerdrTransport.stop_session(session, adapter_context)
    end)

    ownership_ref = HerdrTransport.owned_session_ref(session, adapter_context)

    assert ownership_ref.cleanup_context.socket_root == runtime_root
    assert :ok = HerdrTransport.cleanup_owned_session(ownership_ref)
    refute File.exists?(runtime_root)
  end

  # `pane run` is permitted solely for launch PATH preparation and wrapper
  # preflight; prompts and raw input must never travel through it.
  defp assert_pane_runs_only_prepare_launch(commands) do
    pane_run_lines =
      commands
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "pane run"))

    assert pane_run_lines != []

    assert Enum.all?(pane_run_lines, fn line ->
             String.contains?(line, "export PATH=") or String.contains?(line, "command -v")
           end)
  end

  defp process_alive?(pid) do
    case System.cmd("kill", ["-0", String.trim(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
