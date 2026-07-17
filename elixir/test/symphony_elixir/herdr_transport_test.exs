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
      printf '%s\n' \
        'status: running' \
        'version: 0.7.4' \
        'protocol: 16' \
        'compatible: yes' \
        'socket: /tmp/operator-default/herdr.sock'
      exit 0
    fi

    session="$2"
    state_root="$XDG_CONFIG_HOME/herdr/sessions/$session"
    running="$state_root/running"
    stopped="$state_root/stopped"

    if [ "$#" -eq 3 ] && [ "$1" = "--session" ] && [ "$3" = "server" ]; then
      mkdir -p "$state_root"
      : > "$running"
      while [ ! -f "$stopped" ]; do sleep 0.02; done
      rm -f "$running"
      exit 0
    fi

    if [ "$#" -eq 4 ] && [ "$1" = "--session" ] && [ "$3" = "status" ] && [ "$4" = "server" ]; then
      if [ -f "$running" ]; then
        printf '%s\n' \
          'status: running' \
          "version: ${HERDR_FAKE_VERSION:-0.7.4}" \
          "protocol: ${HERDR_FAKE_PROTOCOL:-16}" \
          'compatible: yes' \
          "socket: $state_root/herdr.sock"
      else
        printf '%s\n' 'status: not running' "socket: $state_root/herdr.sock"
      fi
      exit 0
    fi

    if [ "$#" -eq 4 ] && [ "$1" = "--session" ] && [ "$3" = "server" ] && [ "$4" = "stop" ]; then
      : > "$stopped"
      exit 0
    fi

    if [ "$1" = "--session" ] && [ "$3" = "agent" ] && [ "$4" = "start" ]; then
      name="$5"
      printf '{"id":"cli:agent:start","result":{"agent":{"name":"%s","pane_id":"w1:p1","agent_status":"idle"}}}\n' "$name"
      exit 0
    fi

    if [ "$#" -eq 5 ] && [ "$1" = "--session" ] && [ "$3" = "agent" ] && [ "$4" = "get" ]; then
      printf '{"id":"cli:agent:get","result":{"agent":{"name":"%s","pane_id":"w1:p1","agent":"codex","agent_status":"idle"}}}\n' "$5"
      exit 0
    fi

    if [ "$1" = "--session" ] && [ "$3" = "pane" ] && { [ "$4" = "run" ] || [ "$4" = "send-text" ]; }; then
      exit 0
    fi

    if [ "$#" -eq 3 ] && [ "$1" = "agent" ] && [ "$2" = "get" ]; then
      agent=codex
      if [ "$3" = "w1:p2" ]; then agent=claude; fi
      printf '{"id":"cli:agent:get","result":{"agent":{"name":"target","pane_id":"%s","agent":"%s","agent_status":"idle"}}}\n' "$3" "$agent"
      exit 0
    fi

    if [ "$1" = "pane" ] && { [ "$2" = "run" ] || [ "$2" = "send-text" ]; }; then
      exit 0
    fi

    printf 'unsupported fake Herdr command: %s\n' "$*" >&2
    exit 64
    """)

    File.chmod!(bin, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    %{bin: bin, log: log, runtime_root: deliberately_long_runtime_root}
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
    refute Map.has_key?(session, :worker_launcher)

    worker_argv = [
      "codex",
      "--config",
      "default_permissions=\"octo_herdr\"",
      "--config",
      "permissions.octo_herdr.network={enabled=true,unix_sockets={#{inspect(session.socket)}=\"allow\"}}"
    ]

    assert {:ok, session} =
             HerdrTransport.prepare_worker(session, %{argv: worker_argv}, adapter_context)

    assert File.exists?(session.worker_launcher)
    assert File.exists?(Path.join(session.orchestrator_bin, "herdr"))
    launcher = File.read!(session.worker_launcher)
    assert launcher =~ "default_permissions=\"octo_herdr\""
    assert launcher =~ session.socket

    restricted_herdr = Path.join(session.runtime_root, "worker-bin/herdr")
    assert File.exists?(restricted_herdr)
    assert {output, 64} = System.cmd(restricted_herdr, ["agent", "start", "descendant"], stderr_to_stdout: true)
    assert output =~ "worker Herdr authority denies"

    assert {"", 0} =
             System.cmd(
               restricted_herdr,
               ["pane", "run", "w1:p2", "worker result"],
               env: [{"HERDR_FAKE_LOG", context.log}, {"XDG_CONFIG_HOME", session.runtime_root}]
             )

    orchestrator_herdr = Path.join(session.orchestrator_bin, "herdr")

    assert {"", 0} =
             System.cmd(
               orchestrator_herdr,
               ["pane", "run", "w1:p2", "orchestrator advice"],
               env: [{"HERDR_FAKE_LOG", context.log}, {"XDG_CONFIG_HOME", session.runtime_root}]
             )

    assert {wait_output, 64} =
             System.cmd(
               restricted_herdr,
               ["wait", "agent-status", "w1:p1", "--status", "working", "--timeout", "100"],
               env: [{"HERDR_FAKE_LOG", context.log}, {"XDG_CONFIG_HOME", session.runtime_root}],
               stderr_to_stdout: true
             )

    refute wait_output =~ "worker Herdr authority denies"
    assert wait_output =~ "unsupported fake Herdr command"

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

    assert :ok = HerdrTransport.submit(session, orchestrator, "Codex assignment", adapter_context)

    claude_spec = %{
      name: "claude_orchestrator",
      provider: "claude_code",
      cwd: "/tmp/selected-workspace",
      argv: ["claude", "--model", "claude-fable-5", "--effort", "medium"]
    }

    assert {:ok, claude} = HerdrTransport.start_agent(session, claude_spec, adapter_context)
    assert claude.provider == "claude_code"

    assert {:ok, ready_claude} =
             HerdrTransport.await_agent(session, claude, ["idle", "done"], 3_000, adapter_context)

    assert ready_claude.provider == "claude_code"
    assert :ok = HerdrTransport.submit(session, ready_claude, "Claude assignment", adapter_context)

    ready_started_at = System.monotonic_time(:millisecond)

    assert {:ok, ready_orchestrator} =
             HerdrTransport.await_agent(session, orchestrator, ["idle", "done"], 3_000, adapter_context)

    assert System.monotonic_time(:millisecond) - ready_started_at >= 1_900
    assert ready_orchestrator.agent == "codex"
    assert ready_orchestrator.agent_status == "idle"
    assert ready_orchestrator.agent_session == nil

    assert :ok = HerdrTransport.stop_session(session, adapter_context)
    refute File.exists?(session.runtime_root)

    assert {:ok, ^default_before} = HerdrTransport.default_server_snapshot(adapter_context)

    commands = File.read!(context.log)
    assert commands =~ "--session octo-emb-1141-run-7 server\n"
    assert commands =~ "--session octo-emb-1141-run-7 agent start implementer_orchestrator"
    assert commands =~ "-- codex --model gpt-5.6-sol --config model_reasoning_effort=medium"
    assert commands =~ "--session octo-emb-1141-run-7 pane run w1:p1 Codex assignment\n"
    assert commands =~ "--session octo-emb-1141-run-7 pane run w1:p1 Claude assignment\n"
    assert commands =~ "--session octo-emb-1141-run-7 pane send-text w1:p1 \e[13;1u\n"
    assert commands =~ "pane run w1:p2 worker result\n"
    assert commands =~ "pane run w1:p2 orchestrator advice\n"
    assert length(:binary.matches(commands, "pane send-text w1:p2 \e[13;1u\n")) == 2
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
      expected_version: "0.7.4",
      expected_protocol: 16,
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

    assert :ok =
             HerdrTransport.cleanup_owned_session(%{
               kind: "herdr",
               session_name: ownership_ref.session_name
             })

    refute File.exists?(session.runtime_root)

    commands = File.read!(context.log)
    assert commands =~ "--session octo-emb-1141-abandoned server stop"
  end
end
