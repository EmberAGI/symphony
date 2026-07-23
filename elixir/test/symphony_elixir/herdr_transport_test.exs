defmodule SymphonyElixir.HerdrTransportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ImplementerDelegation.HerdrTransport

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-herdr-transport-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "fake-herdr")
    log = Path.join(root, "herdr.log")

    deliberately_long_runtime_root =
      Path.join(root, "runtime-artifacts-that-must-not-determine-the-unix-socket-location")

    File.mkdir_p!(root)

    File.write!(bin, """
    #!/bin/sh
    set -eu
    printf '%s\n' "$*" >> "$HERDR_FAKE_LOG"

    if [ "$#" -eq 2 ] && [ "$1" = "status" ] && [ "$2" = "server" ]; then
      if [ "${HERDR_FAKE_PROTOCOL_MISMATCH:-}" = "1" ]; then
        printf '{"id":"cli:status:server","error":{"code":"protocol_mismatch","message":"client protocol 17 is newer than server protocol 16"}}\n' >&2
        exit 1
      fi
      printf '%s\n' \
        'status: running' \
        'version: 0.7.5' \
        'protocol: 17' \
        'compatible: yes' \
        'socket: /tmp/operator-default/herdr.sock'
      exit 0
    fi

    session="${2:-default}"
    state_root="$XDG_CONFIG_HOME/herdr/sessions/$session"
    running="$state_root/running"
    stopped="$state_root/stopped"

    if [ "${1:-}" = "--session" ]; then
      shift 2
    fi

    if [ "$#" -eq 1 ] && [ "$1" = "server" ]; then
      mkdir -p "$state_root"
      if [ -n "${HERDR_FAKE_SERVER_PID_FILE:-}" ]; then
        printf '%s\n' "$$" > "$HERDR_FAKE_SERVER_PID_FILE"
      fi
      : > "$running"
      while [ ! -f "$stopped" ]; do sleep 0.02; done
      rm -f "$running"
      exit 0
    fi

    if [ "$#" -eq 2 ] && [ "$1" = "status" ] && [ "$2" = "server" ]; then
      if [ "${HERDR_FAKE_STATUS_STALL:-}" = "1" ]; then
        printf '%s\n' "$$" > "$HERDR_FAKE_STATUS_PID_FILE"
        sleep "${HERDR_FAKE_STATUS_STALL_SECONDS:-2}"
        exit 1
      fi
      if [ -f "$running" ] || [ "${HERDR_FAKE_STATUS_FORCE_RUNNING:-}" = "1" ]; then
        printf '%s\n' \
          'status: running' \
          "version: ${HERDR_FAKE_VERSION:-0.7.5}" \
          "protocol: ${HERDR_FAKE_PROTOCOL:-17}" \
          'compatible: yes' \
          "socket: $state_root/herdr.sock"
      else
        printf '%s\n' "status: ${HERDR_FAKE_STATUS:-not running}"
        if [ -n "${HERDR_FAKE_NON_RUNNING_VERSION:-}" ]; then
          printf '%s\n' "version: $HERDR_FAKE_NON_RUNNING_VERSION"
        fi
        if [ -n "${HERDR_FAKE_NON_RUNNING_PROTOCOL:-}" ]; then
          printf '%s\n' "protocol: $HERDR_FAKE_NON_RUNNING_PROTOCOL"
        fi
        printf '%s\n' "socket: $state_root/herdr.sock"
      fi
      exit 0
    fi

    if [ "$#" -eq 2 ] && [ "$1" = "server" ] && [ "$2" = "stop" ]; then
      if [ "${HERDR_FAKE_STOP_NOOP:-}" != "1" ]; then
        : > "$stopped"
      fi
      exit 0
    fi

    if [ "$#" -eq 5 ] && [ "$1" = "workspace" ] && [ "$2" = "create" ] && [ "$3" = "--cwd" ] && [ "$5" = "--no-focus" ]; then
      printf '{"id":"cli:workspace:create","result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"}}}\n'
      exit 0
    fi

    if [ "$1" = "agent" ] && [ "$2" = "start" ]; then
      name="$3"
      kind="$5"
      pane="$7"

      if [ "${HERDR_FAKE_EXEC_PROVIDER:-}" = "1" ]; then
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift
        HERDR_PANE_ID="$pane" "$kind" "$@" > "$HERDR_FAKE_PROVIDER_OUTPUT"
      fi

      printf '{"id":"cli:agent:start","result":{"agent":{"name":"%s","pane_id":"w1:p1","agent":"%s","agent_status":"idle","interactive_ready":true,"revision":1}}}\n' "$name" "$kind"
      exit 0
    fi

    if [ "$1" = "agent" ] && [ "$2" = "prompt" ]; then
      if [ -n "${HERDR_FAKE_PROMPT_ERROR:-}" ]; then
        printf '{"id":"cli:agent:prompt","error":{"code":"%s","message":"fake prompt failure"}}\n' "$HERDR_FAKE_PROMPT_ERROR" >&2
        exit 1
      fi
      status="${HERDR_FAKE_PROMPT_STATUS:-working}"
      printf '{"id":"cli:agent:prompt","result":{"agent":{"name":"%s","pane_id":"w1:p1","agent":"codex","agent_status":"%s","revision":2}}}\n' "$3" "$status"
      exit 0
    fi

    if [ "$1" = "agent" ] && [ "$2" = "wait" ]; then
      if [ -n "${HERDR_FAKE_WAIT_ERROR:-}" ]; then
        printf '{"id":"cli:agent:wait","error":{"code":"%s","message":"fake wait failure"}}\n' "$HERDR_FAKE_WAIT_ERROR" >&2
        exit 1
      fi
      status="${HERDR_FAKE_WAIT_STATUS:-idle}"
      printf '{"id":"cli:agent:wait","result":{"agent":{"name":"%s","pane_id":"w1:p1","agent":"codex","agent_status":"%s","revision":3}}}\n' "$3" "$status"
      exit 0
    fi

    if [ "$1" = "agent" ] && [ "$2" = "get" ]; then
      case "${HERDR_FAKE_AGENT_GET_MODE:-live}" in
        absent)
          printf '{"id":"cli:agent:get","error":{"code":"agent_not_found","message":"agent not found"}}\n' >&2
          exit 1
          ;;
        malformed)
          printf 'not-json\n'
          exit 0
          ;;
        unreachable)
          printf 'connection refused\n' >&2
          exit 1
          ;;
        protocol_mismatch)
          printf '{"id":"cli:agent:get","error":{"code":"protocol_mismatch","message":"protocol 16 is incompatible with 17"}}\n' >&2
          exit 1
          ;;
        stalled)
          sleep 2
          printf '{"id":"cli:agent:get","result":{"agent":{"name":"%s","pane_id":"w1:p1","agent":"codex","agent_status":"idle","revision":1}}}\n' "$3"
          exit 0
          ;;
        *)
          status="${HERDR_FAKE_AGENT_GET_STATUS:-idle}"
          printf '{"id":"cli:agent:get","result":{"agent":{"name":"%s","pane_id":"w1:p1","agent":"codex","agent_status":"%s","revision":1}}}\n' "$3" "$status"
          exit 0
          ;;
      esac
    fi

    if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
      printf '{"id":"cli:agent:list","result":{"agents":[]}}\n'
      exit 0
    fi

    if [ "$1" = "agent" ] && [ "$2" = "read" ]; then
      printf 'IMPLEMENTER_TURN_COMPLETE'
      exit 0
    fi

    printf 'unsupported fake Herdr command: %s\n' "$*" >&2
    exit 64
    """)

    File.chmod!(bin, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    %{bin: bin, log: log, runtime_root: deliberately_long_runtime_root}
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

    assert {orchestrator_projection, 0} =
             System.cmd(claude_projection, ["--model", "claude-sonnet-5"],
               env: [
                 {"HERDR_PANE_ID", "w1:p1"},
                 {"SYMPHONY_SKILL_EXECUTION_CONTRACTS", ""}
               ],
               stderr_to_stdout: true
             )

    assert orchestrator_projection =~ "PATH=#{session.orchestrator_bin}:#{provider_bin}:"
    assert orchestrator_projection =~ "SKILLS="

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

    for args <- [
          ["agent", "list"],
          ["agent", "get", "implementer_orchestrator"],
          ["agent", "read", "implementer_orchestrator"],
          ["agent", "prompt", "implementer_orchestrator", "worker result"],
          ["agent", "wait", "implementer_orchestrator", "--until", "idle", "--timeout", "100"]
        ] do
      assert {_native_response, 0} = System.cmd(worker_herdr, args, env: base_env, stderr_to_stdout: true)
    end

    for args <- [
          ["agent", "start", "descendant"],
          ["agent", "send-keys", "implementer_orchestrator", "enter"],
          ["pane", "run", "w1:p2", "legacy"],
          ["pane", "send-text", "w1:p2", "raw"],
          ["pane", "send-keys", "w1:p2", "enter"],
          ["pane", "split", "w1:p2", "--direction", "right"],
          ["workspace", "create"],
          ["server", "stop"]
        ] do
      assert {denied, 64} = System.cmd(worker_herdr, args, env: base_env, stderr_to_stdout: true)
      assert denied =~ "worker Herdr authority denies"
    end

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
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

    assert launcher =~ "agent start \"$1\" --kind 'codex' --pane \"$2\""
    assert launcher =~ "default_permissions=\"octo_herdr\""
    assert launcher =~ session.socket
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
               ["agent", "prompt", "implementer_orchestrator", "worker result"],
               env: [{"HERDR_FAKE_LOG", context.log}, {"XDG_CONFIG_HOME", session.runtime_root}]
             )

    orchestrator_herdr = Path.join(session.orchestrator_bin, "herdr")

    assert {_native_response, 0} =
             System.cmd(
               orchestrator_herdr,
               ["agent", "prompt", "implementer_worker", "orchestrator advice"],
               env: [{"HERDR_FAKE_LOG", context.log}, {"XDG_CONFIG_HOME", session.runtime_root}]
             )

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
             HerdrTransport.await_agent(session, orchestrator, ["idle", "done"], 3_000, adapter_context)

    assert ready_orchestrator.agent == "codex"
    assert ready_orchestrator.agent_status == "idle"
    assert ready_orchestrator.agent_session == nil

    assert {:ok, %{text: "IMPLEMENTER_TURN_COMPLETE"}} =
             HerdrTransport.read_agent(
               session,
               ready_orchestrator,
               %{source: :recent_unwrapped, lines: 240},
               adapter_context
             )

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
    refute File.exists?(session.runtime_root)

    assert {:ok, ^default_before} = HerdrTransport.default_server_snapshot(adapter_context)

    commands = File.read!(context.log)
    assert commands =~ "--session octo-emb-1141-run-7 server\n"
    assert commands =~ "--session octo-emb-1141-run-7 workspace create --cwd /tmp/selected-workspace --no-focus"

    assert commands =~
             "--session octo-emb-1141-run-7 agent start implementer_orchestrator --kind codex --pane w1:p1 --timeout 120000 -- --model gpt-5.6-sol --config model_reasoning_effort=medium"

    assert commands =~
             "--session octo-emb-1141-run-7 agent prompt implementer_orchestrator Codex assignment --wait --until working --until idle --until done --timeout 3000"

    assert commands =~
             "--session octo-emb-1141-run-7 agent wait implementer_orchestrator --until idle --until done --timeout 3000"

    assert commands =~ "agent prompt implementer_orchestrator worker result"
    assert commands =~ "agent prompt implementer_worker orchestrator advice"
    refute commands =~ "pane run"
    refute commands =~ "pane send-text"
    assert commands =~ "--session octo-emb-1141-run-7 server stop\n"
  end

  test "rejects an incompatible isolated Herdr server and removes its runtime root", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_VERSION", "0.8.0"},
        {"HERDR_FAKE_PROTOCOL", "17"}
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

    assert {:error, {:incompatible_herdr_runtime, ^incompatible_runtime}} =
             HerdrTransport.start_session(
               %{name: "octo-emb-1141-incompatible", isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    commands = File.read!(context.log)
    assert commands =~ "--session octo-emb-1141-incompatible status server"
  end

  test "surfaces an owned cleanup capability when startup rejection cannot stop Herdr", context do
    session_name = "octo-emb-1217-startup-quarantine"

    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_VERSION", "0.8.0"},
        {"HERDR_FAKE_PROTOCOL", "17"},
        {"HERDR_FAKE_STOP_NOOP", "1"}
      ],
      start_timeout_ms: 2_000,
      stop_timeout_ms: 50,
      poll_interval_ms: 5
    }

    assert {:error,
            {:owned_session_cleanup_unverified,
             %{
               subtype: "herdr_session_start",
               startup_failure: {:incompatible_herdr_runtime, _details},
               cleanup_failure: {:herdr_server_exit_failed, :timeout},
               owned_session_ref: %{
                 kind: "herdr",
                 session_name: ^session_name,
                 cleanup_module: HerdrTransport
               }
             }}} =
             HerdrTransport.start_session(
               %{name: session_name, isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )
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
      start_timeout_ms: 100,
      poll_interval_ms: 5
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :herdr_server_start_timeout} =
             HerdrTransport.start_session(
               %{name: "octo-emb-1201-stalled-status", isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 1_500
    refute File.exists?(runtime_root)
    refute process_alive?(File.read!(status_pid_file))
    refute process_alive?(File.read!(server_pid_file))
  end

  test "normalizes the native protocol mismatch before session startup", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_PROTOCOL_MISMATCH", "1"}
      ]
    }

    assert {:error,
            {:incompatible_herdr_runtime,
             %{
               expected_version: "0.7.5",
               expected_protocol: 17,
               actual_version: nil,
               actual_protocol: nil,
               error_code: "protocol_mismatch"
             }}} = HerdrTransport.default_server_snapshot(adapter_context)
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
             HerdrTransport.await_agent(session, agent, ["idle", "done"], 3_000, adapter_context)

    assert {:ok, %{phase: :working, agent: observed}} =
             HerdrTransport.begin_turn(session, ready, "Complete the assignment.", 1_000, adapter_context)

    assert observed.agent_status == "working"
    assert observed.revision == 2
    assert observed.provider == "claude_code"

    commands = File.read!(context.log)
    assert length(:binary.matches(commands, "agent prompt implementer_orchestrator")) == 1
    refute commands =~ "pane run"
    refute commands =~ "pane send-text"
    refute commands =~ "pane send-keys"
    assert :ok = HerdrTransport.stop_session(session, adapter_context)
  end

  test "recognizes a prompt that completes before the caller observes working", context do
    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_PROMPT_STATUS", "idle"}
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
             HerdrTransport.await_agent(session, agent, ["idle", "done"], 3_000, adapter_context)

    assert {:ok, %{phase: :completed, agent: observed}} =
             HerdrTransport.begin_turn(session, ready, "Complete immediately.", 1_000, adapter_context)

    assert observed.agent_status == "idle"
    assert observed.revision == 2

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
             "agent start implementer_orchestrator --kind claude --pane w1:p1 --timeout 45000 -- --model claude-fable-5 --effort high --append-system-prompt Follow the profile.\u2028    Do not delegate.\u2028Finish safely."

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
    session_name =
      "octo-emb-1227-shared-cold-start-budget-#{System.unique_integer([:positive])}"

    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [{"HERDR_FAKE_LOG", context.log}],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: session_name,
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

  test "returns typed prompt-stall and closed-agent failures", context do
    for {code, expected} <- [
          {"agent_prompt_stalled", :herdr_agent_prompt_stalled},
          {"agent_not_running", :herdr_agent_closed}
        ] do
      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_PROMPT_ERROR", code}
        ],
        start_timeout_ms: 2_000,
        poll_interval_ms: 5
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: "octo-emb-1201-#{String.replace(code, "_", "-")}",
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
    for {code, expected} <- [
          {"timeout", {:herdr_agent_status_timeout, "implementer_orchestrator", ["idle", "done"]}},
          {"agent_not_running", {:herdr_agent_closed, "implementer_orchestrator"}}
        ] do
      adapter_context = %{
        herdr_bin: context.bin,
        extra_env: [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_WAIT_ERROR", code}
        ],
        start_timeout_ms: 2_000,
        poll_interval_ms: 5
      }

      assert {:ok, session} =
               HerdrTransport.start_session(
                 %{
                   name: "octo-emb-1201-wait-#{String.replace(code, "_", "-")}",
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
                 ["idle", "done"],
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

    ownership_ref =
      session
      |> HerdrTransport.owned_session_ref(adapter_context)
      |> Map.put(:agent_name, "implementer_orchestrator")

    assert ownership_ref.kind == "herdr"
    assert ownership_ref.session_name == "octo-emb-1141-abandoned"
    assert {:ok, :live} = HerdrTransport.owned_session_liveness(ownership_ref)
    assert {:ok, :absent} = HerdrTransport.cleanup_owned_session(ownership_ref)

    assert {:ok, :absent} =
             HerdrTransport.cleanup_owned_session(ownership_ref)

    refute File.exists?(session.runtime_root)

    commands = File.read!(context.log)
    assert commands =~ "--session octo-emb-1141-abandoned server stop"
  end

  test "native agent liveness distinguishes absence and fails closed on malformed or unreachable responses", context do
    base_ref = %{
      kind: "herdr",
      session_name: "octo-emb-1217-liveness",
      agent_name: "implementer_orchestrator",
      runtime_root: context.runtime_root,
      cleanup_context: %{
        herdr_bin: context.bin,
        extra_env: [{"HERDR_FAKE_LOG", context.log}],
        socket_root: context.runtime_root
      }
    }

    for {mode, expected} <- [
          {"absent", :absent},
          {"malformed", :unknown},
          {"protocol_mismatch", :unknown},
          {"unreachable", :unreachable}
        ] do
      ownership_ref =
        put_in(
          base_ref,
          [:cleanup_context, :extra_env],
          [
            {"HERDR_FAKE_LOG", context.log},
            {"HERDR_FAKE_STATUS_FORCE_RUNNING", "1"},
            {"HERDR_FAKE_AGENT_GET_MODE", mode}
          ]
        )

      assert {:ok, ^expected} = HerdrTransport.owned_session_liveness(ownership_ref)
    end

    incompatible_ref =
      put_in(
        base_ref,
        [:cleanup_context, :extra_env],
        [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_STATUS_FORCE_RUNNING", "1"},
          {"HERDR_FAKE_VERSION", "0.7.4"}
        ]
      )

    assert {:ok, :unknown} = HerdrTransport.owned_session_liveness(incompatible_ref)
  end

  test "native server liveness treats malformed status and incompatible non-running runtime as unknown", context do
    base_ref = %{
      kind: "herdr",
      session_name: "octo-emb-1217-non-running-classification",
      agent_name: "implementer_orchestrator",
      runtime_root: context.runtime_root,
      cleanup_context: %{
        herdr_bin: context.bin,
        extra_env: [{"HERDR_FAKE_LOG", context.log}],
        socket_root: context.runtime_root
      }
    }

    malformed_status_ref =
      put_in(
        base_ref,
        [:cleanup_context, :extra_env],
        [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_STATUS", "not-a-herdr-status"}
        ]
      )

    incompatible_runtime_ref =
      put_in(
        base_ref,
        [:cleanup_context, :extra_env],
        [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_NON_RUNNING_VERSION", "0.7.4"},
          {"HERDR_FAKE_NON_RUNNING_PROTOCOL", "16"}
        ]
      )

    assert {:ok, :unknown} = HerdrTransport.owned_session_liveness(malformed_status_ref)
    assert {:ok, :unknown} = HerdrTransport.owned_session_liveness(incompatible_runtime_ref)
  end

  test "native server liveness treats a compatible non-running runtime as absent", context do
    ownership_ref = %{
      kind: "herdr",
      session_name: "octo-emb-1217-compatible-non-running",
      agent_name: "implementer_orchestrator",
      runtime_root: context.runtime_root,
      cleanup_context: %{
        herdr_bin: context.bin,
        extra_env: [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_NON_RUNNING_VERSION", "0.7.5"},
          {"HERDR_FAKE_NON_RUNNING_PROTOCOL", "17"}
        ],
        socket_root: context.runtime_root
      }
    }

    assert {:ok, :absent} = HerdrTransport.owned_session_liveness(ownership_ref)
  end

  test "native agent liveness bounds a stalled Herdr query", context do
    ownership_ref = %{
      kind: "herdr",
      session_name: "octo-emb-1217-liveness-timeout",
      agent_name: "implementer_orchestrator",
      runtime_root: context.runtime_root,
      cleanup_context: %{
        herdr_bin: context.bin,
        extra_env: [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_STATUS_FORCE_RUNNING", "1"},
          {"HERDR_FAKE_AGENT_GET_MODE", "stalled"}
        ],
        socket_root: context.runtime_root,
        liveness_timeout_ms: 25
      }
    }

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, :unreachable} = HerdrTransport.owned_session_liveness(ownership_ref)
    assert System.monotonic_time(:millisecond) - started_at < 500
  end

  test "owned-session cleanup bounds a stalled native status query", context do
    runtime_root =
      Path.join(System.tmp_dir!(), "octo-herdr-cleanup-timeout-#{System.unique_integer([:positive])}")

    File.mkdir_p!(runtime_root)
    on_exit(fn -> File.rm_rf!(runtime_root) end)

    ownership_ref = %{
      kind: "herdr",
      session_name: "octo-emb-1217-cleanup-timeout",
      runtime_root: runtime_root,
      cleanup_context: %{
        herdr_bin: context.bin,
        extra_env: [
          {"HERDR_FAKE_LOG", context.log},
          {"HERDR_FAKE_STATUS_STALL", "1"},
          {"HERDR_FAKE_STATUS_STALL_SECONDS", "2"},
          {"HERDR_FAKE_STATUS_PID_FILE", Path.join(Path.dirname(context.bin), "cleanup-status.pid")}
        ],
        socket_root: runtime_root,
        stop_timeout_ms: 25
      }
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:herdr_owned_session_status_failed, :command_timeout}} =
             HerdrTransport.cleanup_owned_session(ownership_ref)

    assert System.monotonic_time(:millisecond) - started_at < 1_500
    assert File.exists?(runtime_root)
  end

  test "owned-session cleanup verifies native server absence after stop acknowledgement", context do
    runtime_root =
      Path.join(System.tmp_dir!(), "octo-herdr-cleanup-verify-#{System.unique_integer([:positive])}")

    adapter_context = %{
      herdr_bin: context.bin,
      extra_env: [
        {"HERDR_FAKE_LOG", context.log},
        {"HERDR_FAKE_STOP_NOOP", "1"}
      ],
      socket_root: runtime_root,
      start_timeout_ms: 2_000,
      stop_timeout_ms: 50,
      poll_interval_ms: 10
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{
                 name: "octo-emb-1217-cleanup-verify",
                 isolated: true,
                 workspace: "/tmp/selected-workspace"
               },
               adapter_context
             )

    on_exit(fn ->
      stopped =
        Path.join([
          runtime_root,
          "herdr",
          "sessions",
          "octo-emb-1217-cleanup-verify",
          "stopped"
        ])

      File.mkdir_p!(Path.dirname(stopped))
      File.touch!(stopped)
      Process.sleep(50)
      if Process.alive?(session.server_task.pid), do: Process.exit(session.server_task.pid, :kill)
      File.rm_rf(runtime_root)
    end)

    ownership_ref = HerdrTransport.owned_session_ref(session, adapter_context)

    assert {:error, {:herdr_owned_session_stop_verification_failed, :timeout}} =
             HerdrTransport.cleanup_owned_session(ownership_ref)

    assert File.exists?(runtime_root)
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
    assert {:ok, :absent} = HerdrTransport.cleanup_owned_session(ownership_ref)
    refute File.exists?(runtime_root)
  end

  defp process_alive?(pid) do
    case System.cmd("kill", ["-0", String.trim(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
