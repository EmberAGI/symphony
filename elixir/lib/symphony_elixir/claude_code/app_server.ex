defmodule SymphonyElixir.ClaudeCode.AppServer do
  @moduledoc """
  First-party `claude-app-server` shim that runs Claude Code behind the same
  logical app-server contract Symphony already uses for Codex.

  This adapter is owned by Symphony (informed by reviewed Claude app-server
  work, not rebased onto an external fork). It drives the local `claude` CLI in
  non-interactive print mode with the streaming JSON protocol and normalizes
  Claude Code events into the same Symphony runtime event vocabulary the Codex
  adapter emits, so orchestrator, status, review, QA, landing, and handoff
  behavior do not need to know which runtime produced a turn.

  ## Verified invocation (Claude Code 2.x, `claude --help`)

  - `claude -p <prompt>` runs fully non-interactively (`--print`); the workspace
    trust dialog is skipped in print mode.
  - `--output-format stream-json --verbose` emits one JSON object per line:
    `{"type":"system","subtype":"init",...}` (session start),
    `{"type":"assistant",...}` / `{"type":"user",...}` (turn deltas and tool
    results), `{"type":"rate_limit_event",...}` (usage/notification), and a
    terminal `{"type":"result","subtype":...,"is_error":bool,...}`.
  - `--permission-mode bypassPermissions` runs with no interactive permission
    approval and no extra sandbox layer (ADR 0002).
  - `--model <alias|id>` selects the model and `--effort <low|medium|high|xhigh|max>`
    selects the reasoning effort.
  - No-thinking is the verified env invocation `MAX_THINKING_TOKENS=0`, the
    Claude-Code CLI equivalent of the API-level `thinking: {type: "disabled"}`.
    (Fable 5 cannot disable thinking; that combination is rejected at config
    validation in `SymphonyElixir.Config.Schema.ClaudeCode`.)

  Authentication uses operator-managed Claude subscription OAuth that lives on
  the role host (ADR 0002). This adapter never provisions, reads, or logs an
  `ANTHROPIC_API_KEY`, OAuth token, or other credential. An expired or missing
  credential fails closed with an operator-visible `{:error, {:auth_failed, _}}`
  result that routes to Human Escalation; it never hangs or silently degrades.
  """

  require Logger

  alias SymphonyElixir.{Config, ImplementationEffort, Linear.Issue, PathSafety, SSH}
  alias SymphonyElixir.Runtime.ProcessOwnership

  # `claude` exits non-zero when it cannot reach a usable model/auth at all; the
  # streaming protocol also surfaces auth failures as a terminal `result` with
  # an HTTP auth status. Both paths must fail closed.
  @auth_error_statuses [401, 403]

  @fable_fallback_model "claude-opus-4-8"
  @fable_fallback_effort "high"
  @fable_fallback_reason "fable_unavailable"

  @no_thinking_env "MAX_THINKING_TOKENS"
  @local_provider_auth_env_names ~w(CLAUDE_CODE_OAUTH_TOKEN)
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          required(:port) => port() | nil,
          required(:metadata) => map(),
          required(:workspace) => Path.t(),
          required(:worker_host) => String.t() | nil,
          required(:launch) => map(),
          optional(:claude_session_id) => String.t() | nil
        }

  @doc """
  Run a single Claude Code turn end to end: start the session, run the turn,
  and stop the session.
  """
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, Keyword.put(opts, :issue, issue)) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @doc """
  Validate the workspace and resolve the launch configuration for a Claude Code
  session.

  No process is started until `run_turn/4`, because the `claude` CLI in print
  mode is one process per turn (prompt in, stream out, exit). The session struct
  carries the validated workspace and resolved launch command so each turn in
  the run reuses the same configuration and (for continuations) resumes the same
  Claude session id.
  """
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    issue = Keyword.get(opts, :issue)
    role = Keyword.get(opts, :role, runtime_role())

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, launch} <- launch_config(issue, role) do
      ownership_env = ownership_env(issue, role, expanded_workspace, opts)
      provider_auth_env = local_provider_auth_env(worker_host)

      {:ok,
       %{
         port: nil,
         metadata: launch.metadata,
         workspace: expanded_workspace,
         worker_host: worker_host,
         launch: %{launch | env: launch.env ++ provider_auth_env ++ ownership_env},
         claude_session_id: nil
       }}
    end
  end

  @doc """
  Run one Claude Code turn for the session, normalizing streamed Claude events
  into Symphony runtime events through `on_message`.
  """
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{workspace: workspace, worker_host: worker_host, launch: launch, metadata: session_metadata} = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    command = turn_command(launch, Map.get(session, :claude_session_id), prompt)

    case start_port(workspace, worker_host, command, launch.env) do
      {:ok, port} ->
        metadata = port_metadata(port, worker_host) |> Map.merge(session_metadata)

        try do
          state = %{
            session_id: nil,
            usage: nil,
            tool_failed?: false
          }

          await_turn_completion(port, on_message, metadata, issue, state, launch.timeout_ms)
        after
          stop_port(port)
        end

      {:error, reason} ->
        Logger.error("Claude Code session failed to launch for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, port_metadata(nil, worker_host))
        {:error, reason}
    end
  end

  @doc """
  Stop the session. Print-mode turns own their own process lifecycle, so this is
  a no-op for an idle session and only closes a still-open port.
  """
  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port), do: stop_port(port)
  def stop_session(_session), do: :ok

  # --- Workspace validation (mirrors Codex.AppServer cwd guard) ---

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  # --- Launch configuration ---

  @doc false
  @spec launch_command_for_test(Issue.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, term()}
  def launch_command_for_test(issue \\ nil, role \\ nil), do: launch_config(issue, role)

  defp launch_config(issue, role) do
    with {:ok, settings} <- Config.settings(),
         {:ok, profile} <- ImplementationEffort.profile_for_issue("claude_code", issue, role) do
      claude = settings.claude_code
      {model, effort, no_thinking, fallback_metadata} = resolve_fallback(profile, claude)

      env =
        []
        |> maybe_put_no_thinking_env(no_thinking)

      {:ok,
       %{
         base_command: claude.command,
         model: model,
         effort: effort,
         no_thinking: no_thinking,
         instructions: profile.instructions,
         permission_mode: claude.permission_mode,
         env: env,
         timeout_ms: claude.turn_timeout_ms,
         metadata:
           %{
             implementation_effort: profile.effort,
             implementation_effort_source: profile.source,
             claude_model: model,
             claude_effort: effort,
             claude_no_thinking: no_thinking
           }
           |> Map.merge(fallback_metadata)
       }}
    end
  end

  defp resolve_fallback(profile, claude) do
    preferred_model = profile.model || claude.model
    preferred_effort = profile.reasoning_effort
    preferred_no_thinking = profile.no_thinking

    if fable_model?(preferred_model) do
      {@fable_fallback_model, @fable_fallback_effort, false,
       %{
         claude_preferred_model: preferred_model,
         claude_preferred_effort: preferred_effort,
         claude_preferred_no_thinking: preferred_no_thinking,
         claude_fallback_reason: @fable_fallback_reason
       }}
    else
      {preferred_model, preferred_effort, preferred_no_thinking, %{}}
    end
  end

  defp fable_model?(model) when is_binary(model) do
    normalized =
      model
      |> String.trim()
      |> String.downcase()

    normalized == "fable" or String.contains?(normalized, "claude-fable-")
  end

  defp fable_model?(_model), do: false

  defp maybe_put_no_thinking_env(env, true), do: [{@no_thinking_env, "0"} | env]
  defp maybe_put_no_thinking_env(env, _false), do: env

  defp local_provider_auth_env(nil) do
    Enum.flat_map(@local_provider_auth_env_names, &local_provider_auth_env_value/1)
  end

  # Remote worker launches render env values into an SSH command line, so local
  # provider auth must be materialized on the worker host instead.
  defp local_provider_auth_env(_worker_host), do: []

  defp local_provider_auth_env_value(name) do
    case System.get_env(name) do
      value when is_binary(value) -> local_provider_auth_env_pair(name, String.trim(value), value)
      _ -> []
    end
  end

  defp local_provider_auth_env_pair(_name, "", _value), do: []
  defp local_provider_auth_env_pair(name, _trimmed, value), do: [{name, value}]

  # Build the full `claude` invocation for a turn. The prompt is passed as the
  # last positional argument (`claude -p <prompt>`) so the process needs no
  # stdin handling. Resumes the Claude session id for continuation turns so a
  # run stays one conversation, mirroring the Codex thread/turn lifecycle.
  defp turn_command(launch, claude_session_id, prompt) do
    [
      launch.base_command,
      "--print",
      "--output-format stream-json",
      "--verbose",
      "--permission-mode #{shell_escape(launch.permission_mode)}",
      model_flag(launch.model),
      effort_flag(launch.effort),
      system_prompt_flag(launch.instructions),
      resume_flag(claude_session_id),
      "--",
      shell_escape(prompt)
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join(" ")
  end

  defp model_flag(nil), do: nil
  defp model_flag(model) when is_binary(model), do: "--model #{shell_escape(model)}"

  defp effort_flag(nil), do: nil
  defp effort_flag(effort) when is_binary(effort), do: "--effort #{shell_escape(effort)}"

  defp system_prompt_flag(instructions) when is_binary(instructions),
    do: "--append-system-prompt #{shell_escape(instructions)}"

  defp resume_flag(nil), do: nil
  defp resume_flag(session_id) when is_binary(session_id), do: "--resume #{shell_escape(session_id)}"

  # --- Process management ---

  defp start_port(workspace, nil, command, env) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            env: port_env(env),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, command, env) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, command, env)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp port_env(env) when is_list(env) do
    Enum.map(env, fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp remote_launch_command(workspace, command, env) when is_binary(workspace) and is_binary(command) do
    env_prefix = Enum.map_join(env, " ", fn {key, value} -> "#{key}=#{shell_escape(value)}" end)

    exec =
      case env_prefix do
        "" -> "exec #{command}"
        prefix -> "exec env #{prefix} #{command}"
      end

    [
      "cd #{shell_escape(workspace)}",
      exec
    ]
    |> Enum.join(" && ")
  end

  defp ownership_env(issue, role, workspace, opts) do
    ProcessOwnership.ownership_env(issue, %{
      role: role,
      run_id: Keyword.get(opts, :run_id),
      workspace_path: workspace
    })
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
        _ -> %{}
      end

    maybe_put_worker_host(base_metadata, worker_host)
  end

  defp port_metadata(_port, worker_host), do: maybe_put_worker_host(%{}, worker_host)

  defp maybe_put_worker_host(metadata, host) when is_binary(host), do: Map.put(metadata, :worker_host, host)
  defp maybe_put_worker_host(metadata, _host), do: metadata

  # --- Streaming receive loop ---

  defp await_turn_completion(port, on_message, metadata, issue, state, timeout_ms) do
    receive_loop(port, on_message, metadata, issue, state, timeout_ms, "")
  end

  defp receive_loop(port, on_message, metadata, issue, state, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        handle_line(port, on_message, metadata, issue, state, timeout_ms, line)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, metadata, issue, state, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, 0}} ->
        # Stream ended without a terminal result object; treat as a failed turn
        # so the run never silently succeeds without a completion signal.
        {:error, :turn_incomplete}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, metadata, issue, state, timeout_ms, line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        process_event(port, on_message, metadata, issue, state, timeout_ms, event, line)

      {:error, _reason} ->
        log_non_json_stream_line(line)
        receive_loop(port, on_message, metadata, issue, state, timeout_ms, "")
    end
  end

  # `{"type":"system","subtype":"init"}` — session started.
  defp process_event(
         port,
         on_message,
         metadata,
         issue,
         state,
         timeout_ms,
         %{"type" => "system", "subtype" => "init"} = event,
         line
       ) do
    session_id = Map.get(event, "session_id")
    Logger.info("Claude Code session started for #{issue_context(issue)} session_id=#{inspect(session_id)}")

    emit_message(
      on_message,
      :session_started,
      %{session_id: session_id, payload: redact(event), raw: redact_raw(line)},
      metadata
    )

    receive_loop(port, on_message, metadata, issue, %{state | session_id: session_id}, timeout_ms, "")
  end

  # Assistant text/tool-use deltas.
  defp process_event(
         port,
         on_message,
         metadata,
         issue,
         state,
         timeout_ms,
         %{"type" => "assistant"} = event,
         line
       ) do
    emit_message(on_message, :text_delta, %{payload: redact(event), raw: redact_raw(line)}, metadata)
    receive_loop(port, on_message, metadata, issue, state, timeout_ms, "")
  end

  # User events carry tool results; a tool error here marks the turn as having a
  # tool failure so the normalized completion reflects it.
  defp process_event(
         port,
         on_message,
         metadata,
         issue,
         state,
         timeout_ms,
         %{"type" => "user"} = event,
         line
       ) do
    tool_failed? = tool_result_error?(event)

    event_atom = if tool_failed?, do: :tool_failed, else: :tool_finished
    emit_message(on_message, event_atom, %{payload: redact(event), raw: redact_raw(line)}, metadata)

    receive_loop(
      port,
      on_message,
      metadata,
      issue,
      %{state | tool_failed?: state.tool_failed? or tool_failed?},
      timeout_ms,
      ""
    )
  end

  # Rate-limit / usage notification events.
  defp process_event(
         port,
         on_message,
         metadata,
         issue,
         state,
         timeout_ms,
         %{"type" => "rate_limit_event"} = event,
         line
       ) do
    emit_message(
      on_message,
      :notification,
      %{payload: redact(event), raw: redact_raw(line), rate_limits: Map.get(event, "rate_limit_info")},
      metadata
    )

    receive_loop(port, on_message, metadata, issue, state, timeout_ms, "")
  end

  # Terminal result object — classify into completed / failed / cancelled /
  # input-required, with auth failures failing closed.
  defp process_event(
         _port,
         on_message,
         metadata,
         issue,
         state,
         _timeout_ms,
         %{"type" => "result"} = event,
         line
       ) do
    handle_result(on_message, metadata, issue, state, event, line)
  end

  # Any other event type is surfaced as a generic notification and the loop
  # continues; an unknown shape must not stall an unattended run.
  defp process_event(port, on_message, metadata, issue, state, timeout_ms, event, line) do
    emit_message(on_message, :notification, %{payload: redact(event), raw: redact_raw(line)}, metadata)
    receive_loop(port, on_message, metadata, issue, state, timeout_ms, "")
  end

  defp handle_result(on_message, metadata, issue, state, event, line) do
    session_id = Map.get(event, "session_id") || state.session_id
    usage = normalized_usage(Map.get(event, "usage"))
    subtype = Map.get(event, "subtype")
    is_error = Map.get(event, "is_error") == true
    api_error_status = Map.get(event, "api_error_status")

    result_metadata = maybe_put_usage(metadata, usage)

    details = %{
      session_id: session_id,
      payload: redact(event),
      raw: redact_raw(line),
      subtype: subtype,
      usage: usage
    }

    cond do
      auth_error?(is_error, api_error_status, event) ->
        Logger.error("Claude Code authentication failed for #{issue_context(issue)} status=#{inspect(api_error_status)}")

        emit_message(
          on_message,
          :turn_failed,
          provider_auth_failure_details(session_id, api_error_status, subtype, usage),
          result_metadata
        )

        {:error, {:auth_failed, %{api_error_status: api_error_status, subtype: subtype}}}

      subtype == "error_max_turns" ->
        # Claude reached its internal turn cap without finishing; surface as an
        # input-required style stall so the orchestrator can continue or
        # escalate rather than treating it as a clean completion.
        emit_message(on_message, :turn_input_required, details, result_metadata)
        {:error, {:turn_input_required, %{subtype: subtype}}}

      is_error ->
        emit_message(on_message, :turn_failed, details, result_metadata)
        {:error, {:turn_failed, %{subtype: subtype, api_error_status: api_error_status}}}

      state.tool_failed? ->
        # The turn completed, but at least one tool call failed. Report the
        # completion with usage but flag the tool failure for review/QA.
        emit_message(on_message, :turn_completed, Map.put(details, :tool_failed, true), result_metadata)
        {:ok, completion_result(event, session_id, usage, state)}

      true ->
        Logger.info("Claude Code session completed for #{issue_context(issue)} session_id=#{inspect(session_id)}")
        emit_message(on_message, :turn_completed, details, result_metadata)
        {:ok, completion_result(event, session_id, usage, state)}
    end
  end

  defp completion_result(event, session_id, usage, state) do
    %{
      result: Map.get(event, "subtype"),
      session_id: session_id,
      usage: usage,
      tool_failed: state.tool_failed?
    }
  end

  defp provider_auth_failure_details(session_id, api_error_status, subtype, usage) do
    %{
      session_id: session_id,
      reason: :auth_failed,
      api_error_status: api_error_status,
      subtype: subtype,
      usage: usage
    }
  end

  # --- Classification helpers ---

  defp auth_error?(is_error, api_error_status, event) do
    (is_error and api_error_status in @auth_error_statuses) or auth_subtype?(event)
  end

  defp auth_subtype?(%{"subtype" => subtype}) when is_binary(subtype) do
    normalized = String.downcase(subtype)

    normalized != "provider_authentication_or_revocation" and
      (String.contains?(normalized, "auth") or String.contains?(normalized, "login") or
         String.contains?(normalized, "credential"))
  end

  defp auth_subtype?(_event), do: false

  defp tool_result_error?(%{"message" => %{"content" => content}}) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "tool_result", "is_error" => true} -> true
      _ -> false
    end)
  end

  defp tool_result_error?(_event), do: false

  # Claude reports input/output tokens but not a total; compute the total so the
  # orchestrator's provider-neutral token accounting works unchanged.
  defp normalized_usage(usage) when is_map(usage) do
    input =
      integer_field(usage, "input_tokens") + integer_field(usage, "cache_read_input_tokens") +
        integer_field(usage, "cache_creation_input_tokens")

    output = integer_field(usage, "output_tokens")

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => input + output
    }
  end

  defp normalized_usage(_usage), do: nil

  defp integer_field(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp maybe_put_usage(metadata, usage) when is_map(usage), do: Map.put(metadata, :usage, usage)
  defp maybe_put_usage(metadata, _usage), do: metadata

  # --- Secret hygiene ---

  # Defense in depth: even though subscription OAuth tokens are not part of the
  # stream-json protocol, never echo a field that could carry a credential.
  @redacted_keys ~w(apiKey api_key authorization auth_token oauth oauth_token token credentials secret)

  defp redact(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested} ->
      if redacted_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact(nested)}
      end
    end)
  end

  defp redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  defp redact(value), do: value

  defp redacted_key?(key) do
    normalized = key |> to_string() |> String.downcase()
    Enum.any?(@redacted_keys, &(normalized == String.downcase(&1)))
  end

  # The raw line is kept for status surfaces but truncated; if it contains a
  # redacted key we drop it rather than risk leaking the original JSON.
  defp redact_raw(line) when is_binary(line) do
    if Enum.any?(@redacted_keys, &String.contains?(String.downcase(line), String.downcase(&1))) do
      "[REDACTED]"
    else
      String.slice(line, 0, @max_stream_log_bytes)
    end
  end

  defp log_non_json_stream_line(line) do
    text = line |> to_string() |> String.trim() |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception|auth|login)\b/i) do
        Logger.warning("Claude Code stream output: #{redact_raw(text)}")
      else
        Logger.debug("Claude Code stream output: #{redact_raw(text)}")
      end
    end
  end

  # --- Shared helpers ---

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp runtime_role do
    case System.get_env("SYMPHONY_ROLE") do
      role when is_binary(role) and role != "" -> role
      _ -> nil
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue_id=unknown"
end
