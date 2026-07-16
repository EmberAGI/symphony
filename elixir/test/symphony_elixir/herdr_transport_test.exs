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
        'version: 0.7.3' \
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
          "version: ${HERDR_FAKE_VERSION:-0.7.3}" \
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
                 workspace: "/tmp/selected-workspace",
                 worker: %{argv: ["/bin/sh"]}
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
    assert File.exists?(session.worker_launcher)

    restricted_herdr = Path.join(session.runtime_root, "worker-bin/herdr")
    assert File.exists?(restricted_herdr)
    assert {output, 64} = System.cmd(restricted_herdr, ["agent", "start", "descendant"], stderr_to_stdout: true)
    assert output =~ "worker Herdr authority denies"

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
      cwd: "/tmp/selected-workspace",
      argv: ["codex", "--model", "gpt-5.6-sol", "--config", "model_reasoning_effort=medium"]
    }

    assert {:ok, orchestrator} = HerdrTransport.start_agent(session, orchestrator_spec, adapter_context)
    assert orchestrator.name == "implementer_orchestrator"
    assert orchestrator.pane_id == "w1:p1"

    assert {:ok, ready_orchestrator} =
             HerdrTransport.await_agent(session, orchestrator, ["idle", "done"], 1_000, adapter_context)

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

    assert {:error, {:incompatible_herdr_runtime, %{expected_version: "0.7.3", expected_protocol: 16, actual_version: "0.8.0", actual_protocol: 17}}} =
             HerdrTransport.start_session(
               %{name: "octo-emb-1141-incompatible", isolated: true, workspace: "/tmp/selected-workspace"},
               adapter_context
             )

    commands = File.read!(context.log)
    assert commands =~ "--session octo-emb-1141-incompatible status server"
  end
end
