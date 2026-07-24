defmodule SymphonyElixir.TestSupport.FakeHerdr do
  @moduledoc """
  Behavior-faithful Herdr 0.7.5 launch-physics double shared by the transport
  and delegation suites: pane shells reset to a login PATH, `pane run` exports
  persist per pane, `agent start` resolves the kind from pane PATH state,
  injects the kind-specific unattended flag, and executes the launch chain.
  """

  @spec write!(Path.t()) :: :ok
  def write!(path) do
    File.write!(path, script())
    File.chmod!(path, 0o755)
    :ok
  end

  defp script do
    """
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
      if [ -f "$running" ]; then
        printf '%s\n' \
          'status: running' \
          "version: ${HERDR_FAKE_VERSION:-0.7.5}" \
          "protocol: ${HERDR_FAKE_PROTOCOL:-17}" \
          'compatible: yes' \
          "socket: $state_root/herdr.sock"
      else
        printf '%s\n' 'status: not running' "socket: $state_root/herdr.sock"
      fi
      exit 0
    fi

    if [ "$#" -eq 2 ] && [ "$1" = "server" ] && [ "$2" = "stop" ]; then
      : > "$stopped"
      exit 0
    fi

    if [ "$#" -eq 5 ] && [ "$1" = "workspace" ] && [ "$2" = "create" ] && [ "$3" = "--cwd" ] && [ "$5" = "--no-focus" ]; then
      printf '{"id":"cli:workspace:create","result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"}}}\n'
      exit 0
    fi

    if [ "$#" -eq 6 ] && [ "$1" = "pane" ] && [ "$2" = "split" ] && [ "$3" = "--current" ] && [ "$4" = "--direction" ] && [ "$5" = "right" ] && [ "$6" = "--no-focus" ]; then
      printf '{"id":"cli:pane:split","result":{"pane":{"pane_id":"w7:p42"}}}\n'
      exit 0
    fi

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
        printf '{"id":"cli:pane:run","error":{"code":"pane_command_failed","message":"fake pane failure"}}\n' >&2
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
    printf '%s' \"\\$PATH\" > \"\\$HERDR_FAKE_PANE_PATH_FILE\"" || exit 1
      fi
      printf '{"id":"cli:pane:run","result":{"ok":true}}\n'
      exit 0
    fi

    if [ "$1" = "agent" ] && [ "$2" = "start" ]; then
      name="$3"
      kind="$5"
      pane="$7"

      if [ "${HERDR_FAKE_AGENT_START_ERROR:-}" = "1" ]; then
        printf '{"id":"cli:agent:start","error":{"code":"agent_start_failed","message":"fake start failure"}}\n' >&2
        exit 1
      fi

      if [ -n "${HERDR_FAKE_PANE_BUSY_COUNT:-}" ]; then
        mkdir -p "$state_root"
        busy_file="$state_root/pane-busy-attempts"
        busy_attempts=0
        if [ -f "$busy_file" ]; then
          IFS= read -r busy_attempts < "$busy_file"
        fi
        busy_attempts=$((busy_attempts + 1))
        printf '%s\n' "$busy_attempts" > "$busy_file"
        if [ "$busy_attempts" -le "$HERDR_FAKE_PANE_BUSY_COUNT" ]; then
          printf '{"id":"cli:agent:start","error":{"code":"agent_pane_busy","message":"agent target pane is not an available shell"}}\n' >&2
          exit 1
        fi
      fi

      while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
      shift

      if [ "${HERDR_FAKE_SKIP_LAUNCH:-}" = "1" ]; then
        :
      elif [ "${HERDR_FAKE_WRAPPER_ACK_ONLY:-}" = "1" ]; then
        projection="$2"
        token=$(basename "$projection")
        token="${token%.sh}"
        fake_runtime_root=$(dirname "$(dirname "$projection")")
        mkdir -p "$fake_runtime_root/launch-acks/$token"
        if [ "${HERDR_FAKE_CORRUPT_WRAPPER_ACK:-}" = "1" ]; then
          printf '%s\n' 'corrupted' > "$fake_runtime_root/launch-acks/$token/wrapper.ack"
        else
          printf '%s\n' "$token" > "$fake_runtime_root/launch-acks/$token/wrapper.ack"
        fi
        if [ "${HERDR_FAKE_CORRUPT_PROJECTION_ACK:-}" = "1" ]; then
          printf '%s\n' 'corrupted' > "$fake_runtime_root/launch-acks/$token/projection.ack"
        fi
      else
        if [ "${HERDR_FAKE_TAMPER_PROJECTION:-}" = "1" ]; then
          chmod 755 "$2"
        fi
        path_file=$(pane_path_file "$pane")
        pane_path=$(cat "$path_file")
        resolved=$(PATH="$pane_path" command -v "$kind") || {
          printf '{"id":"cli:agent:start","error":{"code":"agent_kind_not_resolvable","message":"agent kind was not resolvable at the pane shell prompt"}}\n' >&2
          exit 1
        }
        case "$kind" in
          claude) set -- --dangerously-skip-permissions "$@" ;;
          codex) set -- --yolo "$@" ;;
        esac
        HERDR_FAKE_AGENT_NAME="$name" HERDR_PANE_ID="$pane" PATH="$pane_path" "$resolved" "$@" > "${HERDR_FAKE_PROVIDER_OUTPUT:-/dev/null}" 2>&1 || {
          if [ "${HERDR_FAKE_IGNORE_LAUNCH_FAILURE:-}" != "1" ]; then
            printf '{"id":"cli:agent:start","error":{"code":"agent_launch_command_failed","message":"pane launch command exited nonzero"}}\n' >&2
            exit 1
          fi
        }
      fi

      printf '{"id":"cli:agent:start","result":{"agent":{"name":"%s","pane_id":"%s","agent":"%s","agent_status":"idle","interactive_ready":true,"revision":1}}}\n' "$name" "$pane" "$kind"
      exit 0
    fi

    if [ "$1" = "agent" ] && [ "$2" = "prompt" ]; then
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
          printf '{"id":"cli:agent:prompt","error":{"code":"timeout","message":"timed out before prompt effect could be classified"}}\n' >&2
          exit 1
        fi
        mkdir -p "$state_root"
        prompt_attempt_file="$state_root/prompt-attempts"
        prompt_attempts=0
        if [ -f "$prompt_attempt_file" ]; then
          IFS= read -r prompt_attempts < "$prompt_attempt_file"
        fi
        prompt_attempts=$((prompt_attempts + 1))
        printf '%s\n' "$prompt_attempts" > "$prompt_attempt_file"
        if [ "$prompt_attempts" -le "$HERDR_FAKE_PROMPT_STALL_COUNT" ]; then
          printf '{"id":"cli:agent:prompt","error":{"code":"agent_prompt_stalled","message":"agent state_change_seq did not change","details":{"before_state_change_seq":1,"after_state_change_seq":1}}}\n' >&2
          exit 1
        fi
      fi
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
      printf '{"id":"cli:agent:get","result":{"agent":{"name":"%s","pane_id":"w1:p1","agent":"codex","agent_status":"idle","revision":1}}}\n' "$3"
      exit 0
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
    """
  end
end
