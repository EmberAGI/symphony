defmodule SymphonyElixir.TestSupport.HerdrReplayFixture do
  @moduledoc """
  Replay seam for recorded herdr 0.7.5 protocol responses (EMB-1244 AC 4a).

  Every protocol read performed by the test double replays a response recorded
  from the real herdr 0.7.5 binary (`test/fixtures/herdr/0.7.5/`). The double
  script written by `write_fake_herdr!/2` contains no hand-authored protocol
  JSON: it selects a recorded fixture per command (overridable per scenario via
  `HERDR_REPLAY_*` env), fills the declared run-varying placeholders, and exits
  with the recorded exit status. The executable behavior it keeps is exactly:
  the file-based server run loop and status-stall knob (process physics used by
  session lifecycle tests), provider process execution for `agent start`, and
  the 5000 ms prompt-effect stall scheduling whose emitted envelopes are the
  recorded stall/timeout recordings. Provider execution and the stall/timeout
  boundary are differentially validated against the real binary by the opt-in
  harness in `herdr_differential_test.exs`; the server run loop and stall knob
  are test-only process scaffolding that emit no protocol responses of their
  own. `write_replay_mutation!/4` is the test-side seam for statuses/errors the
  real binary will not produce on demand.
  """

  @fixtures_dir Path.expand("../fixtures/herdr/0.7.5", __DIR__)
  @statuses ~w(idle working blocked done unknown)

  def fixtures_dir, do: @fixtures_dir

  def fixture_names do
    @fixtures_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
  end

  def load!(name) do
    @fixtures_dir
    |> Path.join(name <> ".json")
    |> File.read!()
    |> Jason.decode!()
  end

  @doc "Raw recorded stdout of one fixture, for asserting replayed content."
  def stdout!(name), do: load!(name)["stdout"]

  @doc "One field of the replayed agent envelope, for pinning test expectations."
  def agent_field!(name, field, substitutions \\ %{}) do
    substituted =
      Enum.reduce(substitutions, stdout!(name), fn {placeholder, value}, text ->
        String.replace(text, placeholder, value)
      end)

    substituted
    |> Jason.decode!()
    |> get_in(["result", "agent", field])
  end

  @doc "The status enum as documented by the recorded real-binary help output."
  def documented_statuses! do
    [possible] =
      Regex.run(~r/\[possible values: ([a-z, ]+)\]/, stdout!("agent-wait-help"), capture: :all_but_first)

    possible |> String.split(",") |> Enum.map(&String.trim/1)
  end

  def known_statuses, do: @statuses

  @doc """
  Write a test-local replay variant derived from one recorded fixture.

  This is the sanctioned seam for statuses/errors the pinned real binary will
  not produce on demand (for example `unknown`, an out-of-enum status, or a
  protocol mismatch): the mutation lives only in the test run's replay
  directory, never in committed fixtures or production code.
  """
  def write_replay_mutation!(replay_dir, source, name, transform) do
    fixture = load!(source)
    File.write!(Path.join(replay_dir, name <> ".stdout"), transform.(fixture["stdout"]))
    File.write!(Path.join(replay_dir, name <> ".stderr"), transform.(fixture["stderr"]))
    File.write!(Path.join(replay_dir, name <> ".exit"), Integer.to_string(fixture["exit_status"]))
    name
  end

  @doc "Extract stdout/stderr/exit of each fixture into a replay directory."
  def materialize_replay_dir!(dir) do
    File.mkdir_p!(dir)

    for name <- fixture_names() do
      fixture = load!(name)
      File.write!(Path.join(dir, name <> ".stdout"), fixture["stdout"])
      File.write!(Path.join(dir, name <> ".stderr"), fixture["stderr"])
      File.write!(Path.join(dir, name <> ".exit"), Integer.to_string(fixture["exit_status"]))
    end

    dir
  end

  @doc """
  Write the replay-backed herdr test double to `path`.

  Protocol responses replay recorded fixtures from `replay_dir`. Scenario
  overrides: `HERDR_REPLAY_PROMPT`, `HERDR_REPLAY_WAIT`, `HERDR_REPLAY_GET`,
  and `HERDR_REPLAY_WORKSPACE_CREATE` name the recorded fixture replayed for
  the matching command.

  Non-recordable launch physics (EMB-1245, differentially validated): pane
  shells reset to `HERDR_FAKE_LOGIN_PATH` (default `/usr/bin:/bin`) and only
  `pane run` exports persist per pane; `agent start` resolves the kind
  exec-style from the pane PATH state, prepends the probe-verified 0.7.5
  injected unattended flag (`--dangerously-skip-permissions` for claude,
  `--yolo` for codex), and executes the wrapper -> projection -> provider
  chain, which writes the per-token acknowledgement/reject markers. The only
  protocol envelopes these paths emit are replayed recordings (for example
  the recorded `agent_pane_busy` error, bounded by
  `HERDR_FAKE_PANE_BUSY_COUNT`); sabotage knobs (`HERDR_FAKE_PANE_RUN_FAIL`,
  `HERDR_FAKE_PANE_RUN_NO_PERSIST`, `HERDR_FAKE_AGENT_START_ERROR`,
  `HERDR_FAKE_SKIP_LAUNCH`, `HERDR_FAKE_WRAPPER_ACK_ONLY`,
  `HERDR_FAKE_CORRUPT_WRAPPER_ACK`, `HERDR_FAKE_CORRUPT_PROJECTION_ACK`,
  `HERDR_FAKE_TAMPER_PROJECTION`, `HERDR_FAKE_IGNORE_LAUNCH_FAILURE`) use
  plain stderr and exit codes only. Other timing knobs:
  `HERDR_FAKE_PROMPT_STALL_COUNT` (stall scheduling; the emitted envelopes are
  the recorded stall/timeout recordings) and `HERDR_FAKE_STATUS_STALL*`.
  """
  def write_fake_herdr!(path, replay_dir) do
    File.write!(path, fake_herdr_body(replay_dir))
    File.chmod!(path, 0o755)
    path
  end

  defp fake_herdr_body(replay_dir) do
    """
    #!/bin/sh
    set -eu
    printf '%s\\n' "$*" >> "$HERDR_FAKE_LOG"
    REPLAY=#{shell_escape(replay_dir)}

    agent_name=agent
    agent_kind=claude
    socket_path=
    workspace_cwd=
    pane_id=

    recall_kind() {
      if [ -f "$state_root/kind.$agent_name" ]; then
        IFS= read -r agent_kind < "$state_root/kind.$agent_name"
      fi
    }

    replay() {
      fixture=$1
      sed -e "s|{{AGENT_NAME}}|$agent_name|g" \\
          -e "s|{{AGENT_KIND}}|$agent_kind|g" \\
          -e "s|{{SOCKET_PATH}}|$socket_path|g" \\
          -e "s|{{WORKSPACE_CWD}}|$workspace_cwd|g" \\
          -e "s|{{PANE_ID}}|$pane_id|g" \\
          "$REPLAY/$fixture.stdout"
      if [ -s "$REPLAY/$fixture.stderr" ]; then
        cat "$REPLAY/$fixture.stderr" >&2
      fi
      exit "$(cat "$REPLAY/$fixture.exit")"
    }

    if [ "$#" -eq 2 ] && [ "$1" = "status" ] && [ "$2" = "server" ]; then
      socket_path=/tmp/operator-default/herdr.sock
      replay status-server-running
    fi

    session="${2:-default}"
    state_root="$XDG_CONFIG_HOME/herdr/sessions/$session"
    running="$state_root/running"
    stopped="$state_root/stopped"
    socket_path="$state_root/herdr.sock"

    if [ "${1:-}" = "--session" ]; then
      shift 2
    fi

    # server run loop: launch physics, not a protocol read
    if [ "$#" -eq 1 ] && [ "$1" = "server" ]; then
      mkdir -p "$state_root"
      if [ -n "${HERDR_FAKE_SERVER_PID_FILE:-}" ]; then
        printf '%s\\n' "$$" > "$HERDR_FAKE_SERVER_PID_FILE"
      fi
      : > "$running"
      while [ ! -f "$stopped" ]; do sleep 0.02; done
      rm -f "$running"
      exit 0
    fi

    if [ "$#" -eq 2 ] && [ "$1" = "status" ] && [ "$2" = "server" ]; then
      if [ "${HERDR_FAKE_STATUS_STALL:-}" = "1" ]; then
        printf '%s\\n' "$$" > "$HERDR_FAKE_STATUS_PID_FILE"
        sleep "${HERDR_FAKE_STATUS_STALL_SECONDS:-2}"
        exit 1
      fi
      if [ -f "$running" ]; then
        replay "${HERDR_REPLAY_STATUS_RUNNING:-status-server-running}"
      fi
      replay status-server-not-running
    fi

    if [ "$#" -eq 2 ] && [ "$1" = "server" ] && [ "$2" = "stop" ]; then
      : > "$stopped"
      exit 0
    fi

    if [ "$1" = "workspace" ] && [ "$2" = "create" ] && [ "$3" = "--cwd" ]; then
      workspace_cwd="$4"
      replay "${HERDR_REPLAY_WORKSPACE_CREATE:-workspace-create}"
    fi

    if [ "$1" = "pane" ] && [ "$2" = "split" ]; then
      replay pane-split
    fi

    # pane launch physics (EMB-1245): pane shells reset to a login PATH and
    # only pane-run exports persist there. Non-recordable process behavior —
    # differentially validated by the CD-tier harness; emits no protocol
    # envelopes of its own (plain stderr/exit only for sabotage knobs).
    pane_path_file() {
      pane_dir="$XDG_CONFIG_HOME/herdr/panes/$1"
      mkdir -p "$pane_dir"
      if [ ! -f "$pane_dir/path" ]; then
        printf '%s' "${HERDR_FAKE_LOGIN_PATH:-/usr/bin:/bin}" > "$pane_dir/path"
      fi
      printf '%s' "$pane_dir/path"
    }

    if [ "$1" = "pane" ] && [ "$2" = "run" ]; then
      if [ "${HERDR_FAKE_PANE_RUN_FAIL:-}" = "1" ]; then
        printf 'sabotage: pane run refused\\n' >&2
        exit 1
      fi
      pane="$3"
      shift 3
      path_file=$(pane_path_file "$pane")
      pane_path=$(cat "$path_file")
      if [ "${HERDR_FAKE_PANE_RUN_NO_PERSIST:-}" = "1" ]; then
        PATH="$pane_path" sh -c "$*" || exit 1
      else
        HERDR_FAKE_PANE_PATH_FILE="$path_file" PATH="$pane_path" sh -c "$*
    printf '%s' \\"\\$PATH\\" > \\"\\$HERDR_FAKE_PANE_PATH_FILE\\"" || exit 1
      fi
      exit 0
    fi

    if [ "$1" = "agent" ] && [ "$2" = "start" ]; then
      agent_name="$3"
      agent_kind="$5"
      pane="$7"
      pane_id="$pane"
      mkdir -p "$state_root"
      printf '%s\\n' "$agent_kind" > "$state_root/kind.$agent_name"

      if [ "${HERDR_FAKE_AGENT_START_ERROR:-}" = "1" ]; then
        printf 'sabotage: agent start refused\\n' >&2
        exit 1
      fi

      # transient recorded pane-busy: replayed real envelope, bounded by knob
      if [ -n "${HERDR_FAKE_PANE_BUSY_COUNT:-}" ]; then
        busy_file="$state_root/pane-busy-attempts"
        busy_attempts=0
        if [ -f "$busy_file" ]; then
          IFS= read -r busy_attempts < "$busy_file"
        fi
        busy_attempts=$((busy_attempts + 1))
        printf '%s\\n' "$busy_attempts" > "$busy_file"
        if [ "$busy_attempts" -le "$HERDR_FAKE_PANE_BUSY_COUNT" ]; then
          replay error-agent-start-pane-busy
        fi
      fi

      while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
      shift

      # launch-chain physics (EMB-1245, probe-verified against real 0.7.5):
      # exec-style kind resolution from the pane PATH state, kind-specific
      # injected unattended flag, process replacement through the wrapper ->
      # projection -> provider chain (which writes the per-token acks/rejects).
      # Differentially validated; sabotage knobs emit plain stderr only.
      if [ "${HERDR_FAKE_SKIP_LAUNCH:-}" = "1" ]; then
        :
      elif [ "${HERDR_FAKE_WRAPPER_ACK_ONLY:-}" = "1" ]; then
        projection="$2"
        token=$(basename "$projection")
        token="${token%.sh}"
        fake_runtime_root=$(dirname "$(dirname "$projection")")
        mkdir -p "$fake_runtime_root/launch-acks/$token"
        if [ "${HERDR_FAKE_CORRUPT_WRAPPER_ACK:-}" = "1" ]; then
          printf '%s\\n' 'corrupted' > "$fake_runtime_root/launch-acks/$token/wrapper.ack"
        else
          printf '%s\\n' "$token" > "$fake_runtime_root/launch-acks/$token/wrapper.ack"
        fi
        if [ "${HERDR_FAKE_CORRUPT_PROJECTION_ACK:-}" = "1" ]; then
          printf '%s\\n' 'corrupted' > "$fake_runtime_root/launch-acks/$token/projection.ack"
        fi
      else
        if [ "${HERDR_FAKE_TAMPER_PROJECTION:-}" = "1" ]; then
          chmod 755 "$2"
        fi
        path_file=$(pane_path_file "$pane")
        pane_path=$(cat "$path_file")
        resolved=$(PATH="$pane_path" command -v "$agent_kind") || {
          printf 'sabotage-visible physics: agent kind was not resolvable at the pane shell prompt\\n' >&2
          exit 1
        }
        case "$agent_kind" in
          claude) set -- --dangerously-skip-permissions "$@" ;;
          codex) set -- --yolo "$@" ;;
        esac
        if ! HERDR_FAKE_AGENT_NAME="$agent_name" HERDR_PANE_ID="$pane" PATH="$pane_path" "$resolved" "$@" > "${HERDR_FAKE_PROVIDER_OUTPUT:-/dev/null}" 2>&1; then
          if [ "${HERDR_FAKE_IGNORE_LAUNCH_FAILURE:-}" != "1" ]; then
            printf 'pane launch command exited nonzero for %s on %s\\n' "$agent_name" "$pane" >&2
            tail -n 20 "$HERDR_FAKE_LOG" >&2
            exit 1
          fi
        fi
      fi

      replay "${HERDR_REPLAY_AGENT_START:-agent-start}"
    fi

    if [ "$1" = "agent" ] && [ "$2" = "prompt" ]; then
      agent_name="$3"

      # 5000 ms prompt-effect window: timing physics that cannot be a
      # recording; behavior contract recorded in agent-prompt-help and
      # differentially validated by the CD-tier harness.
      if [ -n "${HERDR_FAKE_PROMPT_STALL_COUNT:-}" ]; then
        prompt_timeout=0
        previous_arg=
        for arg in "$@"; do
          if [ "$previous_arg" = "--timeout" ]; then
            prompt_timeout=$arg
            break
          fi
          previous_arg=$arg
        done
        if [ "$prompt_timeout" -le 5000 ]; then
          replay error-agent-prompt-timeout-under-window
        fi
        mkdir -p "$state_root"
        prompt_attempt_file="$state_root/prompt-attempts"
        prompt_attempts=0
        if [ -f "$prompt_attempt_file" ]; then
          IFS= read -r prompt_attempts < "$prompt_attempt_file"
        fi
        prompt_attempts=$((prompt_attempts + 1))
        printf '%s\\n' "$prompt_attempts" > "$prompt_attempt_file"
        if [ "$prompt_attempts" -le "$HERDR_FAKE_PROMPT_STALL_COUNT" ]; then
          replay error-agent-prompt-stalled
        fi
      fi

      recall_kind prompt
      replay "${HERDR_REPLAY_PROMPT:-agent-prompt-working}"
    fi

    if [ "$1" = "agent" ] && [ "$2" = "wait" ]; then
      agent_name="$3"
      recall_kind wait
      replay "${HERDR_REPLAY_WAIT:-agent-wait-idle}"
    fi

    if [ "$1" = "agent" ] && [ "$2" = "get" ]; then
      agent_name="$3"
      recall_kind get
      replay "${HERDR_REPLAY_GET:-agent-get-idle}"
    fi

    if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
      replay agent-list
    fi

    if [ "$1" = "agent" ] && [ "$2" = "read" ]; then
      replay agent-read-recent
    fi

    printf 'unsupported fake Herdr command: %s\\n' "$*" >&2
    exit 64
    """
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end
end
