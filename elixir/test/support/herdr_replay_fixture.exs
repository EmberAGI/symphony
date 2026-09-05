defmodule SymphonyElixir.TestSupport.HerdrReplayFixture do
  @moduledoc """
  Replay seam for recorded Herdr protocol responses (EMB-1244 AC 4a).

  Every protocol read performed by the test double replays a response recorded
  from checksum-verified real Herdr binaries (`test/fixtures/herdr/`). The double
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

  @fixtures_dir Path.expand("../fixtures/herdr/0.8.2", __DIR__)
  @legacy_fixtures_dir Path.expand("../fixtures/herdr/0.7.5", __DIR__)
  @statuses ~w(idle working blocked done unknown)

  def fixtures_dir, do: @fixtures_dir

  def fixture_names do
    @fixtures_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.reject(&(&1 == "release-authority"))
    |> Enum.sort()
  end

  def legacy_fixture_names do
    @legacy_fixtures_dir
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

  def load_legacy!(name) do
    @legacy_fixtures_dir
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

  @doc "Exact JSON envelope shape, retaining every key and value type."
  def json_shape!(output), do: output |> Jason.decode!() |> shape()

  @doc "AgentStarted shape with only optional terminal-title metadata removed."
  def agent_started_shape!(output) do
    output
    |> Jason.decode!()
    |> update_in(["result", "agent"], fn
      agent when is_map(agent) -> Map.drop(agent, ~w(terminal_title terminal_title_stripped))
      agent -> agent
    end)
    |> shape()
  end

  @doc "Stable prompted-agent identity carried by a protocol envelope."
  def agent_identity!(output) do
    output
    |> Jason.decode!()
    |> get_in(["result", "agent"])
    |> Map.take(~w(agent name pane_id agent_session))
  end

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
  exec-style from the pane PATH state, prepends the probe-verified pinned
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
  the recorded stall/timeout recordings),
  `HERDR_REPLAY_PROMPT_STALL` (the recorded prompt error emitted by a
  scheduled stall),
  `HERDR_FAKE_MIN_PROMPT_TIMEOUT_MS` (a busy-target timing boundary below
  which the recorded ordinary prompt timeout is emitted),
  `HERDR_FAKE_WORKING_PROMPT_WAIT_TIMEOUT` (an already-working target whose
  accepted waited prompt emits the recorded ordinary timeout because no
  lifecycle edge follows),
  `HERDR_FAKE_PROMPT_STALE_SETTLED` (a successful prompt receipt that repeats
  the pre-submit settled revision before the real working transition),
  `HERDR_FAKE_POST_PROMPT_SETTLED_TRANSITION` (a successful settled prompt
  receipt followed by one newer settled revision before lifecycle waiting),
  `HERDR_FAKE_PROMPT_STALL_DELAY_SECONDS` (delay before the recorded stall),
  `HERDR_FAKE_STATUS_STALL*`.
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
    agent_revision=
    agent_state_change_seq=

    recall_kind() {
      if [ -f "$state_root/kind.$agent_name" ]; then
        IFS= read -r agent_kind < "$state_root/kind.$agent_name"
      fi
    }

    recall_revision() {
      agent_revision=0
      agent_state_change_seq=1
      if [ -f "$state_root/revision.$agent_name" ]; then
        IFS= read -r agent_revision < "$state_root/revision.$agent_name"
      fi
      if [ -f "$state_root/state-change-seq.$agent_name" ]; then
        IFS= read -r agent_state_change_seq < "$state_root/state-change-seq.$agent_name"
      fi
    }

    replay_stdout() {
      if [ -n "${state_root:-}" ] && [ -f "$state_root/workspace-cwd" ]; then
        IFS= read -r workspace_cwd < "$state_root/workspace-cwd"
      fi
      sed -e "s|{{AGENT_NAME}}|$agent_name|g" \\
          -e "s|{{AGENT_KIND}}|$agent_kind|g" \\
          -e "s|{{SOCKET_PATH}}|$socket_path|g" \\
          -e "s|{{WORKSPACE_CWD}}|$workspace_cwd|g" \\
          -e "s|{{PANE_ID}}|$pane_id|g" \\
          "$REPLAY/$1.stdout"
    }

    # Reported-identity physics (EMB-1353): herdr 0.8.2 has no native claude
    # session derivation — the recorded envelopes carried `agent_session` only
    # because the recording host's claude integration had already reported it
    # over the pane report channel. A claude agent here therefore carries the
    # field only after such a report, and carries exactly the reported value.
    # Codex recordings replay unchanged: the codex integration's ambient
    # report is part of the recorded physics this double replays
    # (differentially validated by the CD-tier harness).
    project_provider_session() {
      if [ "$agent_kind" = "claude" ] && [ -n "${state_root:-}" ]; then
        if [ -f "$state_root/agent-session.$agent_name" ]; then
          IFS= read -r reported_session < "$state_root/agent-session.$agent_name"
          sed "s|\\(\\"agent_session\\":{[^}]*\\"value\\":\\"\\)[^\\"]*|\\1$reported_session|g"
        else
          sed 's|"agent_session":{[^}]*},||g'
        fi
      else
        cat
      fi
    }

    replay() {
      fixture=$1
      if [ -n "$agent_revision" ]; then
        replay_stdout "$fixture" | project_provider_session |
          sed -e "s|\\\"revision\\\":[0-9][0-9]*|\\\"revision\\\":$agent_revision|g" \\
              -e "s|\\\"state_change_seq\\\":[0-9][0-9]*|\\\"state_change_seq\\\":$agent_state_change_seq|g"
      else
        replay_stdout "$fixture" | project_provider_session
      fi
      if [ -s "$REPLAY/$fixture.stderr" ]; then
        if [ -n "$agent_state_change_seq" ]; then
          sed "s|state_change_seq remained [0-9][0-9]*|state_change_seq remained $agent_state_change_seq|g" \\
            "$REPLAY/$fixture.stderr" >&2
        else
          cat "$REPLAY/$fixture.stderr" >&2
        fi
      fi
      exit "$(cat "$REPLAY/$fixture.exit")"
    }

    if [ "$#" -eq 2 ] && [ "$1" = "status" ] && [ "$2" = "server" ]; then
      socket_path=/tmp/operator-default/herdr.sock
      replay status-server-running
    fi

    session=default
    if [ "${1:-}" = "--session" ]; then
      session="$2"
    fi
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
      # Process scaffolding: acknowledge stop only after the owned loop exits.
      # Otherwise cleanup can delete the stop marker before the loop sees it.
      stop_attempts=0
      while [ -f "$running" ]; do
        stop_attempts=$((stop_attempts + 1))
        if [ "$stop_attempts" -ge 200 ]; then
          printf 'fixture server did not stop\\n' >&2
          exit 1
        fi
        sleep 0.01
      done
      exit 0
    fi

    if [ "$1" = "workspace" ] && [ "$2" = "create" ] && [ "$3" = "--cwd" ]; then
      workspace_cwd="$4"
      mkdir -p "$state_root"
      printf '%s\\n' "$workspace_cwd" > "$state_root/workspace-cwd"
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
    path_tmp=\\"\\$HERDR_FAKE_PANE_PATH_FILE.\\$\\$\\"
    printf '%s' \\"\\$PATH\\" > \\"\\$path_tmp\\"
    mv -f \\"\\$path_tmp\\" \\"\\$HERDR_FAKE_PANE_PATH_FILE\\"" || exit 1
      fi
      exit 0
    fi

    # Provider-report physics (EMB-1353): herdr learns an agent's provider
    # session only when an integration reports it against the pane the agent
    # occupies (`pane report-agent-session <PANE_ID> --agent-session-id <ID>
    # ...`, pane id positional as the real 0.8.2 CLI requires). The reported
    # value is stored per agent and projected into every later replayed
    # envelope for that agent. A write acknowledgement is not a protocol read,
    # so no recorded envelope is replayed here.
    if [ "$1" = "pane" ] && [ "$2" = "report-agent-session" ]; then
      if [ "${HERDR_FAKE_REPORT_AGENT_SESSION_FAIL:-}" = "1" ]; then
        printf 'sabotage: report-agent-session refused\\n' >&2
        exit 70
      fi
      report_session=
      report_source=
      report_pane=$3
      previous_arg=
      for arg in "$@"; do
        if [ "$previous_arg" = "--agent-session-id" ]; then
          report_session=$arg
        fi
        if [ "$previous_arg" = "--source" ]; then
          report_source=$arg
        fi
        previous_arg=$arg
      done
      mkdir -p "$state_root"
      for pane_file in "$state_root"/pane.*; do
        [ -e "$pane_file" ] || continue
        IFS= read -r recorded_pane < "$pane_file"
        if [ "$recorded_pane" = "$report_pane" ]; then
          reported_name=$(basename "$pane_file")
          printf '%s\\n' "$report_session" > "$state_root/agent-session.${reported_name#pane.}"
          printf '%s\\n' "${report_source:--}" > "$state_root/agent-source.${reported_name#pane.}"
        fi
      done
      exit 0
    fi

    if [ "$1" = "agent" ] && [ "$2" = "start" ]; then
      agent_name="$3"
      agent_kind="$5"
      pane="$7"
      pane_id="$pane"
      mkdir -p "$state_root"
      printf '%s\\n' "$agent_kind" > "$state_root/kind.$agent_name"
      printf '%s\\n' "$pane" > "$state_root/pane.$agent_name"
      printf '1\\n' > "$state_root/revision.$agent_name"
      printf '1\\n' > "$state_root/state-change-seq.$agent_name"
      recall_revision

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

      # launch-chain physics (EMB-1245, probe-verified against real 0.8.2):
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
        # A started agent runs at its pane's shell prompt, so it starts in the
        # workspace the session was created for — the directory a provider's
        # own trust and project state is keyed by.
        launch_cwd=$PWD
        if [ -f "$state_root/workspace-cwd" ]; then
          IFS= read -r recorded_cwd < "$state_root/workspace-cwd"
          if [ -d "$recorded_cwd" ]; then
            launch_cwd=$recorded_cwd
          fi
        fi
        if ! (cd "$launch_cwd" && HERDR_FAKE_AGENT_NAME="$agent_name" HERDR_PANE_ID="$pane" PATH="$pane_path" "$resolved" "$@") > "${HERDR_FAKE_PROVIDER_OUTPUT:-/dev/null}" 2>&1; then
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
      prompt_timeout=0
      previous_arg=
      for arg in "$@"; do
        if [ "$previous_arg" = "--timeout" ]; then
          prompt_timeout=$arg
          break
        fi
        previous_arg=$arg
      done

      if [ "${HERDR_REPLAY_PROMPT:-}" = "error-agent-prompt-blocked" ]; then
        recall_kind prompt
        replay error-agent-prompt-blocked
      fi

      if [ -n "${HERDR_FAKE_MIN_PROMPT_TIMEOUT_MS:-}" ] &&
         [ "$prompt_timeout" -lt "$HERDR_FAKE_MIN_PROMPT_TIMEOUT_MS" ]; then
        replay error-agent-prompt-timeout-under-window
      fi

      if [ "${HERDR_FAKE_WORKING_PROMPT_WAIT_TIMEOUT:-}" = "1" ]; then
        case " $* " in
          *' --wait '*) replay error-agent-prompt-timeout-under-window ;;
        esac
      fi

      # 5000 ms prompt-effect window: timing physics that cannot be a
      # recording; behavior contract recorded in agent-prompt-help and
      # differentially validated by the CD-tier harness.
      if [ -n "${HERDR_FAKE_PROMPT_STALL_COUNT:-}" ]; then
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
          if [ -n "${HERDR_FAKE_PROMPT_STALL_DELAY_SECONDS:-}" ]; then
            sleep "$HERDR_FAKE_PROMPT_STALL_DELAY_SECONDS"
          fi
          replay "${HERDR_REPLAY_PROMPT_STALL:-error-agent-prompt-stalled}"
        fi
      fi

      recall_revision
      if [ "${HERDR_FAKE_PROMPT_STALE_SETTLED:-}" = "1" ]; then
        recall_kind prompt
        replay "${HERDR_REPLAY_PROMPT:-agent-prompt-idle}"
      fi
      agent_revision=$((agent_revision + 1))
      agent_state_change_seq=$((agent_state_change_seq + 1))
      mkdir -p "$state_root"
      printf '%s\\n' "$agent_revision" > "$state_root/revision.$agent_name"
      printf '%s\\n' "$agent_state_change_seq" > "$state_root/state-change-seq.$agent_name"
      : > "$state_root/prompt-received.$agent_name"
      recall_kind prompt
      replay "${HERDR_REPLAY_PROMPT:-agent-prompt-working}"
    fi

    if [ "$1" = "agent" ] && [ "$2" = "wait" ]; then
      agent_name="$3"
      if [ -n "${HERDR_FAKE_WAIT_STALL_SECONDS:-}" ]; then
        sleep "$HERDR_FAKE_WAIT_STALL_SECONDS"
      fi
      recall_revision
      if [ "${HERDR_FAKE_POST_PROMPT_SETTLED_TRANSITION:-}" = "1" ] &&
         [ -f "$state_root/prompt-received.$agent_name" ] &&
         [ ! -f "$state_root/post-prompt-settled-transition.$agent_name" ]; then
        agent_revision=$((agent_revision + 1))
        agent_state_change_seq=$((agent_state_change_seq + 1))
        printf '%s\\n' "$agent_revision" > "$state_root/revision.$agent_name"
        printf '%s\\n' "$agent_state_change_seq" > "$state_root/state-change-seq.$agent_name"
        : > "$state_root/post-prompt-settled-transition.$agent_name"
      fi
      recall_kind wait
      replay "${HERDR_REPLAY_WAIT:-agent-wait-idle}"
    fi

    if [ "$1" = "agent" ] && [ "$2" = "get" ]; then
      agent_name="$3"
      recall_revision
      recall_kind get
      replay "${HERDR_REPLAY_GET:-agent-get-idle}"
    fi

    if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
      # Live-inventory physics: a session lists exactly the agents it started.
      # The envelope stays the recording — its recorded entries are selected in
      # order and only the declared {{AGENT_NAME}}/{{AGENT_KIND}} placeholders
      # are filled, one entry per agent this session actually started.
      #
      # First-turn physics, visible in the recorded envelopes:
      # `agent_session` is the provider session and does not exist until the
      # agent has been prompted — `agent-start` and `agent-get-idle` carry no
      # such field, `agent-prompt-working` does. The recorded `agent list`
      # entries were captured after both agents had been prompted, so the
      # third emitted field replays that prompt state and an unprompted agent
      # is listed without the recorded `agent_session` object.
      #
      # For claude entries the prompted correlation was a recording-host
      # artifact (EMB-1353): identity follows the integration REPORT, not the
      # prompt, so the fourth field carries the reported value (`-` when no
      # report was recorded) and replaces the recorded placeholder value. The
      # fifth field carries the reported `--source` and likewise replaces the
      # recorded one, so an assertion on the source is an assertion about what
      # the reporter actually sent rather than about the recording.
      started=$( (set -- "$state_root"/kind.*
        if [ -e "$1" ]; then
          for kind_file in "$@"; do
            started_name=$(basename "$kind_file")
            started_name=${started_name#kind.}
            IFS= read -r started_kind < "$kind_file"
            started_prompted=0
            if [ -f "$state_root/prompt-received.$started_name" ]; then
              started_prompted=1
            fi
            started_session=-
            if [ -f "$state_root/agent-session.$started_name" ]; then
              IFS= read -r started_session < "$state_root/agent-session.$started_name"
            fi
            started_source=-
            if [ -f "$state_root/agent-source.$started_name" ]; then
              IFS= read -r started_source < "$state_root/agent-source.$started_name"
            fi
            printf '%s %s %s %s %s\\n' "$started_name" "$started_kind" "$started_prompted" "$started_session" "$started_source"
          done
        fi) | sort)
      agent_name='{{AGENT_NAME}}'
      agent_kind='{{AGENT_KIND}}'
      replay_stdout agent-list | awk -v pairs="$started" '
        function set_json_field(text, key, value,   pat, pre, post) {
          pat = q key q ":" q "[^" q "]*" q
          if (match(text, pat)) {
            pre = substr(text, 1, RSTART - 1)
            post = substr(text, RSTART + RLENGTH)
            return pre q key q ":" q value q post
          }
          return text
        }
        BEGIN { q = sprintf("%c", 34) }
        {
          head_end = index($0, "\\"agents\\":[") + 9
          head = substr($0, 1, head_end)
          rest = substr($0, head_end + 1)
          body_end = index(rest, "],\\"type\\"")
          body = substr(rest, 1, body_end - 1)
          tail = substr(rest, body_end)
          recorded_count = split(body, recorded, "},{")
          listed = split(pairs, rows, "\\n")
          out = ""
          for (i = 1; i <= listed; i++) {
            split(rows[i], field, " ")
            j = ((i - 1) % recorded_count) + 1
            entry = recorded[j]
            if (j > 1) entry = "{" entry
            if (j < recorded_count) entry = entry "}"
            gsub(/\\{\\{AGENT_NAME\\}\\}/, field[1], entry)
            gsub(/\\{\\{AGENT_KIND\\}\\}/, field[2], entry)
            if (field[2] == "claude") {
              if (field[4] == "-" || field[4] == "")
                sub(/"agent_session":\\{[^}]*\\},/, "", entry)
              else if (match(entry, /"agent_session":\\{[^}]*\\}/)) {
                session_prefix = substr(entry, 1, RSTART - 1)
                session_object = substr(entry, RSTART, RLENGTH)
                session_rest = substr(entry, RSTART + RLENGTH)
                session_object = set_json_field(session_object, "value", field[4])
                if (field[5] != "" && field[5] != "-")
                  session_object = set_json_field(session_object, "source", field[5])
                entry = session_prefix session_object session_rest
              }
            } else if (field[3] == "0") sub(/"agent_session":\\{[^}]*\\},/, "", entry)
            if (i > 1) out = out ","
            out = out entry
          }
          printf "%s%s%s\\n", head, out, tail
        }'
      exit "$(cat "$REPLAY/agent-list.exit")"
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

  defp shape(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, shape(value)} end)
  defp shape(list) when is_list(list), do: Enum.map(list, &shape/1)
  defp shape(value) when is_binary(value), do: :string
  defp shape(value) when is_integer(value), do: :integer
  defp shape(value) when is_float(value), do: :float
  defp shape(value) when is_boolean(value), do: :boolean
  defp shape(nil), do: nil
end
