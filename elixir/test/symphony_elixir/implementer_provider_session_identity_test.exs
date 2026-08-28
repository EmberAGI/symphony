defmodule SymphonyElixir.ImplementerProviderSessionIdentityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduledoc """
  RED (EMB-1353): production run `localhost:1463328:implementer:...:3`
  (EMB-1144, provider claude_code) reached a terminal Herdr state while the
  prompt acknowledgement, the terminal observation, and the entire 60-second
  provider-session receipt window never carried `agent_session`, so the run
  failed closed as `implementer_provider_session_missing`.

  Herdr 0.7.5 has no native Claude session derivation: `agent_session` exists
  only after the Claude Code integration hook reports the provider's own
  session id over the pane report channel. Symphony owns the entire Claude
  launch (wrapper, projection, argv) yet neither provisions nor verifies that
  report, so the identity invariant silently depended on ambient operator
  host state — and no test, fake or real, exercised the Claude path past
  launch.

  These tests pin the new expected behavior at the public runtime seam
  (`AgentRuntime.start_session/2` + `run_turn/4` over the real
  `HerdrTransport`): a Claude-backed Implementer turn must expose one stable
  nonblank native provider session identity at prompt acknowledgement,
  terminal observation, and a subsequent transport read — in the direct-work
  and worker-delegation branches — while missing/blank identity keeps failing
  closed, a conflicting identity is a typed protocol failure, and Codex
  behavior is untouched.
  """

  alias SymphonyElixir.{AgentRuntime, ImplementationEffort, ImplementerDelegation}
  alias SymphonyElixir.ImplementerDelegation.HerdrTransport
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.HerdrReplayFixture

  @correlation_event "Implementer worker result correlated"
  @no_delegation_event "Implementer worker result correlation not required"

  setup do
    root = Path.join(System.tmp_dir!(), "ipsi-#{System.unique_integer([:positive])}")
    provider_bin = Path.join(root, "provider-bin")
    workspace = Path.join(root, "selected-product")

    File.mkdir_p!(provider_bin)
    File.mkdir_p!(workspace)

    codex = Path.join(provider_bin, "codex")
    File.write!(codex, "#!/bin/sh\nexit 0\n")
    File.chmod!(codex, 0o755)

    previous_path = System.get_env("PATH") || ""
    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)

    System.put_env("PATH", provider_bin <> ":" <> previous_path)
    Application.put_env(:symphony_elixir, :delegation_transport_module, HerdrTransport)

    herdr_bin = Path.join(root, "fake-herdr")
    herdr_log = Path.join(root, "herdr.log")
    replay_dir = Path.join(root, "herdr-replay")
    HerdrReplayFixture.materialize_replay_dir!(replay_dir)
    HerdrReplayFixture.write_fake_herdr!(herdr_bin, replay_dir)

    runtime_root = Path.join(System.tmp_dir!(), "ipsi-rt-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      System.put_env("PATH", previous_path)

      if previous_provider,
        do: System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider),
        else: System.delete_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")

      Application.put_env(:symphony_elixir, :delegation_transport_module, previous_transport)
      File.rm_rf(root)
      File.rm_rf(runtime_root)
    end)

    {:ok,
     %{
       provider_bin: provider_bin,
       workspace: workspace,
       herdr_bin: herdr_bin,
       herdr_log: herdr_log,
       replay_dir: replay_dir,
       runtime_root: runtime_root
     }}
  end

  defmodule MismatchedIdentityTransport do
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

    def prepare_worker(session, _spec, _context),
      do:
        {:ok,
         session
         |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
         |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}

    def start_agent(_session, spec, _context),
      do: {:ok, %{name: spec.name, pane_id: "w1:p1", agent_status: "idle", agent_session: nil, revision: 1, state_change_seq: 1}}

    # The acknowledged prompt carries one provider identity...
    def begin_turn(_session, agent, _prompt, _timeout_ms, _context),
      do:
        {:ok,
         %{
           phase: :working,
           agent: %{
             name: agent.name,
             agent_status: "working",
             agent_session: %{value: "acknowledged-identity"},
             revision: 1,
             state_change_seq: 2
           }
         }}

    # ...and the terminal observation carries a different one. One run, two
    # native identities: a runtime-protocol violation, never a choice.
    def get_agent(_session, agent, _timeout_ms, _context),
      do:
        {:ok,
         %{
           name: agent.name,
           agent_status: "idle",
           agent_session: %{value: "terminal-identity"},
           revision: 2,
           state_change_seq: 3
         }}

    def read_agent(_session, _agent, _opts, _context), do: {:ok, %{text: "orchestrator turn finished"}}
    def stop_session(_session, _context), do: :ok
  end

  test "a Claude-backed direct-work turn exposes one stable nonblank provider session identity", context do
    native_id = write_claude_stub!(context, "native-claude-direct-7f3a")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")

    session =
      start_implementer_session(
        context,
        "provider-session-identity-direct",
        [
          {"HERDR_REPLAY_PROMPT", "agent-prompt-idle"},
          {"HERDR_REPLAY_WAIT", "error-agent-wait-timeout"}
        ]
      )

    parent = self()

    {result, _log} =
      with_log(fn ->
        AgentRuntime.run_turn(
          session,
          "Implement the bounded issue.",
          issue(),
          on_message: fn message -> send(parent, {:observation, message}) end,
          provider_session_receipt_timeout_ms: 1_000,
          provider_session_receipt_interval_ms: 10
        )
      end)

    assert {:ok, {_next_session, turn}} = result

    # Nonblank, and the provider's own native identity — never minted by
    # Symphony and never authored by the agent as prose.
    assert is_binary(turn.session_id) and String.trim(turn.session_id) != ""
    assert turn.session_id == native_id

    # Stable at the prompt acknowledgement and the terminal observation.
    assert_received {:observation, %{event: :session_started, session_id: ack_session_id}}
    assert ack_session_id == turn.session_id
    assert_received {:observation, %{event: :turn_completed, session_id: terminal_session_id}}
    assert terminal_session_id == turn.session_id

    # Stable on a subsequent read through the same transport-owned binary,
    # and attributed to the Herdr provider-report channel.
    assert %{"agent_session" => %{"value" => listed_value, "source" => "herdr:claude"}} =
             native_agent_entry(session, context, "implementer_orchestrator")

    assert listed_value == turn.session_id

    stop(session)
  end

  test "the run-owned reporter pins its pane, takes the first session id, and records every invocation", context do
    native_id = write_claude_stub!(context, "native-claude-reporter-7f3a")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")

    session =
      start_implementer_session(
        context,
        "provider-session-identity-reporter",
        [
          {"HERDR_REPLAY_PROMPT", "agent-prompt-idle"},
          {"HERDR_REPLAY_WAIT", "error-agent-wait-timeout"}
        ]
      )

    {result, _log} =
      with_log(fn ->
        AgentRuntime.run_turn(
          session,
          "Implement the bounded issue.",
          issue(),
          provider_session_receipt_timeout_ms: 1_000,
          provider_session_receipt_interval_ms: 10
        )
      end)

    assert {:ok, {_next_session, turn}} = result
    assert turn.session_id == native_id

    # The reporter is materialized per agent, inside the agent's own config
    # dir — not once at the runtime root where every process of the run shares
    # one copy.
    agent_dir = Path.join([session.herdr_session.runtime_root, "provider-session", "implementer_orchestrator"])
    reporter = Path.join(agent_dir, "provider-session-report")
    report_log = Path.join(agent_dir, "report.log")

    assert File.exists?(reporter)
    refute File.exists?(Path.join(session.herdr_session.runtime_root, "provider-session-report"))

    # The pinned pane is baked in, never read from the environment: an
    # invocation announcing a foreign pane reports for nothing at all.
    assert {_out, 0} = run_reporter(reporter, session, context, ~s({"session_id":"forged-foreign-pane"}), [{"HERDR_PANE_ID", "w9:p9"}])

    # Nothing reached Herdr at all: the foreign pane never became an argument.
    refute File.read!(context.herdr_log) =~ "w9:p9"
    assert %{"agent_session" => %{"value" => ^native_id}} = native_agent_entry(session, context, "implementer_orchestrator")
    assert File.read!(report_log) =~ "pane-mismatch"

    # A payload carrying a nested `session_id` yields the FIRST one. A
    # wrong-but-stable identity never trips the mismatch guard, so it silently
    # joins the run's evidence to the wrong session.
    assert {_out, 0} =
             run_reporter(
               reporter,
               session,
               context,
               ~s({"session_id":"first-native-9c21","transcript":{"session_id":"nested-decoy-4b70"}}),
               []
             )

    assert %{"agent_session" => %{"value" => "first-native-9c21"}} =
             native_agent_entry(session, context, "implementer_orchestrator")

    assert File.read!(report_log) =~ "reported"

    # Both silent-failure shapes of EMB-1144 leave a distinguishable line
    # rather than an indistinguishable `exit 0`.
    assert {_out, 0} = run_reporter(reporter, session, context, "not-json-at-all", [])
    assert File.read!(report_log) =~ "no-session-id"

    assert {_out, 0} =
             run_reporter(reporter, session, context, ~s({"session_id":"rejected-by-herdr"}), [
               {"HERDR_FAKE_REPORT_AGENT_SESSION_FAIL", "1"}
             ])

    assert File.read!(report_log) =~ "report-failed"
    assert File.read!(report_log) =~ "exit=70"

    # The rejected report never became an identity.
    assert %{"agent_session" => %{"value" => "first-native-9c21"}} =
             native_agent_entry(session, context, "implementer_orchestrator")

    # Every line stays bounded and carries no hook payload.
    for line <- report_log |> File.read!() |> String.split("\n", trim: true) do
      assert String.length(line) <= 512
      refute line =~ "hook_event_name"
      refute line =~ "transcript"
    end

    # The `source` the double projects is the source that was reported, so the
    # source assertions in this suite are load-bearing rather than decorative.
    assert {_out, 0} =
             System.cmd(
               context.herdr_bin,
               [
                 "--session",
                 session.name,
                 "pane",
                 "report-agent-session",
                 orchestrator_pane(session),
                 "--source",
                 "herdr:forged",
                 "--agent",
                 "claude",
                 "--agent-session-id",
                 "source-probe-1"
               ],
               env: fake_herdr_env(session, context),
               stderr_to_stdout: true
             )

    assert %{"agent_session" => %{"value" => "source-probe-1", "source" => "herdr:forged"}} =
             native_agent_entry(session, context, "implementer_orchestrator")

    stop(session)
  end

  test "worker delegation retains the orchestrator provider identity and worker correlation stays independently decidable",
       context do
    native_id = write_claude_stub!(context, "native-claude-delegation-7f3a")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")

    session =
      start_implementer_session(
        context,
        "provider-session-identity-delegation",
        [
          {"HERDR_REPLAY_PROMPT", "agent-prompt-idle"},
          {"HERDR_REPLAY_WAIT", "error-agent-wait-timeout"}
        ]
      )

    parent = self()

    {result, log} =
      with_log(fn ->
        AgentRuntime.run_turn(
          session,
          "Implement the bounded issue.",
          issue(),
          on_message: fn
            %{event: :session_started} = message ->
              send(parent, {:observation, message})

              assert :ok =
                       orchestrator_prompt(
                         session,
                         context,
                         "implementer_worker",
                         "OCTO_MSG/1 kind=assignment assignment=EMB1353-IDENTITY-1 deliverable=bounded"
                       )

              assert :ok =
                       worker_prompt(
                         session,
                         context,
                         "implementer_orchestrator",
                         "OCTO_MSG/1 kind=result assignment=EMB1353-IDENTITY-1 status=completed"
                       )

            message ->
              send(parent, {:observation, message})
          end,
          provider_session_receipt_timeout_ms: 1_000,
          provider_session_receipt_interval_ms: 10
        )
      end)

    assert {:ok, {_next_session, turn}} = result
    assert turn.session_id == native_id

    # Worker correlation is decided by the assignment envelope, independent of
    # the orchestrator's provider identity.
    assert [%{assignment_id: "EMB1353-IDENTITY-1", status: :completed}] = turn.worker_assignments

    assert_received {:observation, %{event: :session_started, session_id: ^native_id}}

    assert log =~ @correlation_event
    assert log =~ "session_id=#{native_id}"

    stop(session)
  end

  test "a Codex-backed turn keeps its provider session identity behavior unchanged", context do
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")

    session =
      start_implementer_session(
        context,
        "provider-session-identity-codex-parity",
        [
          {"HERDR_REPLAY_PROMPT", "agent-prompt-idle"},
          {"HERDR_REPLAY_WAIT", "error-agent-wait-timeout"}
        ]
      )

    parent = self()

    {result, log} =
      with_log(fn ->
        AgentRuntime.run_turn(
          session,
          "Implement the bounded issue.",
          issue(),
          on_message: fn message -> send(parent, {:observation, message}) end,
          provider_session_receipt_timeout_ms: 1_000,
          provider_session_receipt_interval_ms: 10
        )
      end)

    assert {:ok, {_next_session, turn}} = result
    assert is_binary(turn.session_id) and String.trim(turn.session_id) != ""

    assert_received {:observation, %{event: :session_started, session_id: ack_session_id}}
    assert ack_session_id == turn.session_id

    assert log =~ @no_delegation_event

    stop(session)
  end

  test "a Claude turn whose integration never reports still fails closed without either positive outcome", context do
    for {shape, stub_writer} <- [
          {:missing, fn -> write_hookless_claude_stub!(context) end},
          {:blank, fn -> write_claude_stub!(context, " ") end}
        ] do
      stub_writer.()
      System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")

      session =
        start_implementer_session(
          context,
          "provider-session-identity-#{shape}",
          [
            {"HERDR_REPLAY_PROMPT", "agent-prompt-idle"},
            {"HERDR_REPLAY_WAIT", "error-agent-wait-timeout"}
          ]
        )

      {result, log} =
        with_log(fn ->
          AgentRuntime.run_turn(
            session,
            "Implement the bounded issue.",
            issue(),
            provider_session_receipt_timeout_ms: 300,
            provider_session_receipt_interval_ms: 10
          )
        end)

      assert {:error, {:implementer_provider_session_missing, %{agent: "implementer_orchestrator", provider: "claude_code"}}} =
               result

      assert {:irrecoverable, %{family: :invalid_workspace_or_runtime_protocol, retryable?: false}} =
               AgentRuntime.classify_failure(elem(result, 1), %{provider: :claude_code, role: "implementer"})

      refute log =~ @correlation_event
      refute log =~ @no_delegation_event

      stop(session)
    end
  end

  test "a provider identity that changes between acknowledgement and terminal observation fails closed typed" do
    assert {:ok, session} =
             ImplementerDelegation.start_session(
               "/tmp/symphony-provider-session-identity-ws",
               claude_contract(),
               issue_identifier: "EMB-1353",
               run_id: "run-mismatched-provider-session",
               transport: MismatchedIdentityTransport,
               transport_context: %{}
             )

    {result, log} =
      with_log(fn ->
        ImplementerDelegation.run_turn(
          session,
          "Implement the bounded issue.",
          issue(),
          heartbeat_interval_ms: 1,
          settle_window_ms: 0
        )
      end)

    assert {:error,
            {:implementer_provider_session_mismatched,
             %{
               agent: "implementer_orchestrator",
               provider: "claude_code",
               acknowledged: "acknowledged-identity",
               observed: "terminal-identity"
             }}} = result

    assert {:irrecoverable, %{family: :invalid_workspace_or_runtime_protocol, retryable?: false}} =
             AgentRuntime.classify_failure(elem(result, 1), %{provider: :claude_code, role: "implementer"})

    refute log =~ @correlation_event
    refute log =~ @no_delegation_event
  end

  # A claude-like provider stub faithful to the two physics this seam depends
  # on, both observed against the real 2.1.220 binary:
  #
  #   1. A session only STARTS once the launch's effective Claude config marks
  #      the working directory trusted (`projects[<cwd>].hasTrustDialogAccepted`).
  #      Until then Claude sits on the interactive workspace-trust dialog —
  #      `--dangerously-skip-permissions` does not waive it — so no session
  #      exists and no `SessionStart` hook fires.
  #   2. Identity leaves the process ONLY through a `SessionStart` hook, which
  #      receives the hook input JSON (carrying the native `session_id`) on
  #      stdin. The agent never writes its id as prose.
  #
  # An unset `CLAUDE_CONFIG_DIR` is modeled as an untrusted, hookless config
  # home: that is what a freshly materialized per-issue workspace is under any
  # config home, and it keeps the test independent of the developer's own
  # Claude installation.
  defp write_claude_stub!(context, native_session_id) do
    stub = Path.join(context.provider_bin, "claude")

    File.write!(stub, """
    #!/bin/sh
    config_dir="${CLAUDE_CONFIG_DIR:-}"
    [ -n "$config_dir" ] || exit 0

    cwd=$(pwd -P)
    grep -Fq "\\"$cwd\\"" "$config_dir/.claude.json" 2>/dev/null || exit 0
    grep -Fq '"hasTrustDialogAccepted":true' "$config_dir/.claude.json" 2>/dev/null || exit 0

    hook_command=$(sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' \\
      "$config_dir/settings.json" 2>/dev/null | head -n 1)
    [ -n "$hook_command" ] || exit 0

    printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"#{native_session_id}"}' |
      sh -c "$hook_command" || true
    exit 0
    """)

    File.chmod!(stub, 0o755)
    native_session_id
  end

  # The production failure shape: a Claude that runs but whose identity report
  # never happens — every guard in the real integration exits 0 silently.
  defp write_hookless_claude_stub!(context) do
    stub = Path.join(context.provider_bin, "claude")
    File.write!(stub, "#!/bin/sh\nexit 0\n")
    File.chmod!(stub, 0o755)
    :ok
  end

  defp start_implementer_session(context, run_id, extra_env) do
    assert {:ok, session} =
             AgentRuntime.start_session(context.workspace,
               issue: issue(),
               role: "implementer",
               run_id: run_id,
               delegation_transport_context: %{
                 herdr_bin: context.herdr_bin,
                 extra_env: [{"HERDR_FAKE_LOG", context.herdr_log} | extra_env],
                 socket_root: context.runtime_root,
                 poll_interval_ms: 5,
                 start_timeout_ms: 2_000
               }
             )

    session
  end

  # Invoke the materialized reporter exactly as the provider's SessionStart
  # hook does: payload on stdin, nothing else but the pane environment.
  defp run_reporter(reporter, session, context, payload, extra_env) do
    payload_path = Path.join(context.workspace, "hook-payload-#{System.unique_integer([:positive])}.json")
    File.write!(payload_path, payload)

    # `HERDR_PANE_ID` is whatever this scenario declares and nothing else: the
    # test runner may itself be running inside a Herdr pane.
    env =
      [{"HERDR_PANE_ID", nil} | fake_herdr_env(session, context) ++ extra_env]
      |> Map.new()
      |> Map.to_list()

    System.cmd("/bin/sh", ["-c", "exec #{reporter} < #{payload_path}"], env: env, stderr_to_stdout: true)
  end

  defp fake_herdr_env(session, context) do
    [
      {"HERDR_FAKE_LOG", context.herdr_log},
      {"XDG_CONFIG_HOME", session.herdr_session.runtime_root}
    ]
  end

  # The pane the double recorded for the started agent, i.e. the pane the
  # reporter must have been pinned to.
  defp orchestrator_pane(session) do
    [session.herdr_session.runtime_root, "herdr", "sessions", session.name, "pane.implementer_orchestrator"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end

  defp native_agent_entry(session, context, agent_name) do
    assert {output, 0} =
             System.cmd(context.herdr_bin, ["--session", session.name, "agent", "list"],
               env: fake_herdr_env(session, context),
               stderr_to_stdout: true
             )

    output
    |> Jason.decode!()
    |> get_in(["result", "agents"])
    |> Enum.find(&(&1["name"] == agent_name))
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
    assert {output, status} =
             System.cmd(shim, ["agent", "prompt", agent, message],
               env: [
                 {"HERDR_FAKE_LOG", context.herdr_log},
                 {"XDG_CONFIG_HOME", session.herdr_session.runtime_root}
               ],
               stderr_to_stdout: true
             )

    assert status == 0, output
    :ok
  end

  defp stop(session), do: AgentRuntime.stop_session(session)

  defp claude_contract do
    assert {:ok, contract} = ImplementationEffort.runtime_profile_for_issue(:claude_code, issue(), "implementer")
    contract
  end

  defp issue do
    %Issue{
      id: "issue-1353",
      identifier: "EMB-1353",
      title: "Repair and prove Claude Implementer provider session identity",
      state: "In Progress",
      branch_name: "admin/emb-1353-repair-claude-session-identity",
      url: "https://linear.app/emberai/issue/EMB-1353",
      repository: "EmberAGI/scaling-octo-engine",
      repository_source: "linear_label",
      labels: ["implementation-effort:moderate"]
    }
  end
end
