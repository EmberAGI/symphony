defmodule SymphonyElixir.ImplementerDelegation.HerdrTransport do
  @moduledoc """
  Production transport adapter for run-owned isolated Herdr sessions.

  The adapter scopes every mutating command to a named session and a private
  `XDG_CONFIG_HOME`. Default-server inspection deliberately omits that private
  environment so `ImplementerDelegation` can prove non-interference.
  """

  @behaviour SymphonyElixir.ImplementerDelegation.Transport

  @default_start_timeout_ms 10_000
  @default_poll_interval_ms 50
  @default_stop_timeout_ms 5_000
  @default_agent_start_timeout_ms 120_000
  @generated_prompt_timeout_ms 6_000
  @prompt_recovery_attempts 2
  @required_version "0.7.5"
  @required_protocol 17
  @launch_projection_sentinel "--symphony-launch-projection"
  @default_launch_handshake_timeout_ms 5_000
  @worker_assignment_prefix "OCTO_MSG/1 kind=assignment "
  @worker_result_prefix "OCTO_MSG/1 kind=result "
  @launch_stage_failures [
    :herdr_pane_preparation_failed,
    :herdr_wrapper_resolution_failed,
    :herdr_wrapper_ack_failed,
    :herdr_projection_ack_failed,
    :herdr_projection_validation_failed,
    :herdr_provider_start_failed
  ]

  # Herdr 0.7.5 live-agent status vocabulary (recorded from `agent wait --help`).
  @herdr_agent_statuses ~w(idle working blocked done unknown)
  # Herdr 0.7.5 classifies an unchanged state_change_seq within this window as
  # agent_prompt_stalled; a shorter --timeout returns a generic timeout instead.
  @prompt_effect_window_ms 5_000

  @impl true
  def default_server_snapshot(context) when is_map(context) do
    with {:ok, output} <- command(context, ["status", "server"], default_env(context)) do
      parse_server_status(output)
    end
  end

  @impl true
  def start_session(%{name: name, isolated: true, workspace: workspace} = spec, context)
      when is_binary(name) and name != "" and is_binary(workspace) and is_map(context) do
    runtime_root = Map.get(context, :socket_root, short_socket_root(name))
    env = isolated_env(context, runtime_root, Map.get(spec, :env, %{}))
    expected_socket = Path.join([runtime_root, "herdr", "sessions", name, "herdr.sock"])

    with :ok <- validate_socket_path(expected_socket),
         :ok <- validate_runtime_root(runtime_root) do
      File.mkdir_p!(runtime_root)
      File.mkdir_p!(Path.join(runtime_root, "herdr"))

      File.write!(
        Path.join(runtime_root, "herdr/config.toml"),
        """
        [update]
        version_check = false
        manifest_check = false
        """
      )

      server_task =
        Task.async(fn ->
          command_in_port(context, ["--session", name, "server"], env, :infinity)
        end)

      case await_running(context, name, env, server_task) do
        {:ok, status} ->
          finish_session_start(status, name, workspace, runtime_root, env, server_task, context)

        {:error, reason} ->
          shutdown_server_task(server_task)
          File.rm_rf(runtime_root)
          {:error, reason}
      end
    end
  end

  def start_session(_spec, _context), do: {:error, :invalid_herdr_isolated_session_spec}

  defp finish_session_start(status, name, workspace, runtime_root, env, server_task, context) do
    session = %{
      name: name,
      socket: status.socket,
      runtime_root: runtime_root,
      workspace: workspace,
      env: env,
      server_task: server_task
    }

    with :ok <- validate_runtime(status),
         {:ok, pane_id} <- create_workspace(session, workspace, context) do
      {:ok, Map.put(session, :pane_id, pane_id)}
    else
      {:error, reason} -> reject_started_session(session, context, reason)
    end
  end

  defp create_workspace(%{name: name, env: env}, workspace, context) do
    with {:ok, output} <-
           command(context, ["--session", name, "workspace", "create", "--cwd", workspace, "--no-focus"], env),
         {:ok, payload} <- Jason.decode(output),
         pane_id when is_binary(pane_id) <- get_in(payload, ["result", "root_pane", "pane_id"]) do
      {:ok, pane_id}
    else
      {:error, reason} -> {:error, {:herdr_workspace_create_failed, reason}}
      _ -> {:error, :invalid_herdr_workspace_create_response}
    end
  end

  defp reject_started_session(session, context, reason) do
    cleanup_started_server(session, context)
    {:error, reason}
  end

  @impl true
  def prepare_worker(%{runtime_root: runtime_root} = session, worker, context)
      when is_binary(runtime_root) and is_map(context) do
    case materialize_worker_launcher(session, worker, context) do
      {:ok, worker_launcher, orchestrator_bin} ->
        prepared =
          session
          |> Map.put(:worker_launcher, worker_launcher)
          |> Map.put(:orchestrator_bin, orchestrator_bin)

        File.mkdir_p!(worker_events_root(runtime_root))
        prestart_worker(prepared, worker, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def prepare_worker(_session, _worker, _context), do: {:error, :invalid_herdr_worker_session}

  defp prestart_worker(
         prepared,
         %{name: name, cwd: cwd, argv: argv} = worker,
         context
       )
       when is_binary(name) and name != "" and is_binary(cwd) and is_list(argv) and
              argv != [] do
    with {:ok, worker_pane_id} <- create_worker_pane(prepared, context),
         {:ok, worker_agent} <-
           start_agent(
             Map.put(prepared, :pane_id, worker_pane_id),
             worker,
             context
           ) do
      {:ok,
       prepared
       |> Map.put(:worker, worker_agent)
       |> Map.put(:worker_pane_id, worker_pane_id)}
    else
      {:error, reason} -> {:error, {:implementer_worker_launch_failed, reason}}
    end
  end

  # Existing direct Adapter callers use prepare_worker/3 only to materialize
  # and inspect the compatibility launcher. Runtime contracts always include
  # the full name/cwd/argv shape and therefore take the deterministic prestart.
  defp prestart_worker(prepared, _worker, _context), do: {:ok, prepared}

  @impl true
  def start_agent(
        %{name: session_name, env: env, pane_id: pane_id, runtime_root: runtime_root},
        %{name: name, cwd: cwd, argv: argv} = spec,
        context
      )
      when is_binary(name) and name != "" and is_binary(cwd) and is_binary(pane_id) and
             is_list(argv) and argv != [] do
    timeout_ms = Map.get(context, :agent_start_timeout_ms, @default_agent_start_timeout_ms)

    orchestrator_bin = Path.join(runtime_root, "orchestrator-bin")
    orchestrator_path = orchestrator_bin <> ":" <> inherited_provider_path(env, orchestrator_bin)

    with {:ok, kind, native_args} <- native_agent_launch(spec, argv),
         :ok <- ensure_provider_wrapper(runtime_root, hd(argv), env, context),
         {:ok, launch_token, projection_path} <-
           materialize_launch_projection(
             runtime_root,
             name,
             kind,
             hd(argv),
             native_args,
             %{"PATH" => orchestrator_path},
             %{"PATH" => inherited_provider_path(env, orchestrator_bin)}
           ),
         :ok <- validate_launch_projection(runtime_root, projection_path),
         :ok <- prepare_launch_pane(context, session_name, env, pane_id, kind, orchestrator_bin, runtime_root),
         args =
           [
             "--session",
             session_name,
             "agent",
             "start",
             name,
             "--kind",
             kind,
             "--pane",
             pane_id,
             "--timeout",
             to_string(timeout_ms),
             "--",
             @launch_projection_sentinel,
             projection_path
           ],
         {:ok, output} <- start_agent_command(context, args, env, runtime_root, launch_token),
         :ok <- await_launch_acks(runtime_root, launch_token, context),
         {:ok, payload} <- Jason.decode(output),
         agent when is_map(agent) <- get_in(payload, ["result", "agent"]),
         observed = atomize_known_agent_fields(agent),
         {:ok, _status} <- classify_agent_status(observed.agent_status) do
      {:ok, Map.put(observed, :provider, Map.get(spec, :provider))}
    else
      {:error, {stage, _details} = reason} when stage in @launch_stage_failures -> {:error, reason}
      {:error, {:incompatible_herdr_runtime, _details} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:herdr_agent_start_failed, reason}}
      _ -> {:error, :invalid_herdr_agent_start_response}
    end
  end

  def start_agent(_session, _spec, _context), do: {:error, :invalid_herdr_agent_spec}

  defp native_agent_launch(%{provider: "codex"}, ["codex" | args]),
    do: {:ok, "codex", Enum.map(args, &to_string/1)}

  defp native_agent_launch(%{provider: "claude_code"}, ["claude" | args]),
    do: encode_claude_native_args(args)

  defp native_agent_launch(_spec, _argv), do: {:error, :invalid_herdr_agent_provider_launch}

  defp encode_claude_native_args(args) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, encoded} ->
      case control_safe_native_arg(arg) do
        {:ok, value} -> {:cont, {:ok, [value | encoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, "claude", Enum.reverse(encoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp control_safe_native_arg(arg) do
    value =
      arg
      |> to_string()
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.replace("\n", "\u2028")
      |> String.replace("\t", "    ")

    if Regex.match?(~r/\p{Cc}/u, value) do
      {:error, {:invalid_herdr_agent_argument, :unrepresentable_control_character}}
    else
      {:ok, value}
    end
  end

  @impl true
  def begin_turn(
        %{name: session_name, env: env},
        %{name: agent_name} = agent,
        prompt,
        timeout_ms,
        context
      )
      when is_binary(agent_name) and agent_name != "" and
             is_binary(prompt) and prompt != "" and is_integer(timeout_ms) and timeout_ms >= 0 and
             is_map(context) do
    with {:ok, output} <-
           submit_prompt(
             context,
             session_name,
             env,
             agent_name,
             prompt,
             timeout_ms,
             @prompt_recovery_attempts
           ),
         {:ok, observed} <- decode_agent_response(output),
         {:ok, phase} <- prompt_outcome(observed, agent_name) do
      {:ok, %{phase: phase, agent: preserve_provider(observed, agent)}}
    else
      {:error, reason} -> prompt_error(reason, agent_name)
    end
  end

  def begin_turn(_session, _agent, _prompt, _timeout_ms, _context),
    do: {:error, :invalid_herdr_begin_turn}

  defp submit_prompt(context, session_name, env, agent_name, prompt, timeout_ms, recoveries_left) do
    # The wait must exceed the 5000 ms prompt-effect window so an unchanged
    # state_change_seq is the typed agent_prompt_stalled result, never an
    # ordinary timeout. The until set is the upstream default settle set plus
    # working, so a started turn is observed without waiting for completion.
    effective_timeout_ms = max(timeout_ms, @prompt_effect_window_ms + 1)

    args =
      ["--session", session_name, "agent", "prompt", agent_name, prompt, "--wait"] ++
        until_args(["working", "idle", "done", "blocked"]) ++
        ["--timeout", to_string(effective_timeout_ms)]

    case command(context, args, env) do
      {:error, reason} when recoveries_left > 0 ->
        if cli_error_code(reason) == "agent_prompt_stalled" do
          submit_prompt(context, session_name, env, agent_name, " ", timeout_ms, recoveries_left - 1)
        else
          {:error, reason}
        end

      result ->
        result
    end
  end

  @impl true
  def await_agent(%{name: session_name, env: env}, %{name: agent_name} = agent, statuses, timeout_ms, context)
      when is_list(statuses) and statuses != [] and is_integer(timeout_ms) and timeout_ms >= 0 do
    # The requested settle set must be exactly the upstream default
    # (idle|done|blocked): never re-narrowed below it, never widened with
    # unknown. The set is passed explicitly so the wire request states what
    # the caller asked for.
    with :ok <- validate_wait_statuses(statuses),
         args =
           ["--session", session_name, "agent", "wait", agent_name] ++
             until_args(statuses) ++ ["--timeout", to_string(timeout_ms)],
         {:ok, output} <- command(context, args, env),
         {:ok, observed} <- decode_agent_response(output),
         :ok <- wait_outcome(observed, agent_name) do
      {:ok, preserve_provider(observed, agent)}
    else
      {:error, {:herdr_agent_blocked, _name} = reason} -> {:error, reason}
      {:error, {:herdr_agent_status_unknown, _name} = reason} -> {:error, reason}
      {:error, {:herdr_agent_wait_unsettled, _name, _status} = reason} -> {:error, reason}
      {:error, reason} -> wait_error(reason, agent_name, statuses)
    end
  end

  def await_agent(_session, _agent, _statuses, _timeout_ms, _context), do: {:error, :invalid_herdr_agent_wait}

  @impl true
  def get_agent(%{name: session_name, env: env}, %{name: agent_name} = agent, timeout_ms, context)
      when is_binary(agent_name) and agent_name != "" and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    context
    |> command_in_port(["--session", session_name, "agent", "get", agent_name], env, deadline)
    |> get_agent_result(agent, agent_name)
  end

  def get_agent(_session, _agent, _timeout_ms, _context), do: {:error, :invalid_herdr_agent_get}

  defp get_agent_result({:ok, output}, agent, _agent_name) do
    # Decode then classify: an out-of-enum status from a get read stays a
    # typed protocol/version error, never coerced to unknown.
    with {:ok, observed} <- decode_agent_response(output),
         {:ok, _status} <- classify_agent_status(observed.agent_status) do
      {:ok, preserve_provider(observed, agent)}
    end
  end

  defp get_agent_result({:error, :command_timeout}, _agent, agent_name),
    do: {:error, {:herdr_agent_get_timeout, agent_name}}

  defp get_agent_result({:error, {:incompatible_herdr_runtime, _details} = reason}, _agent, _agent_name),
    do: {:error, reason}

  defp get_agent_result({:error, reason}, _agent, agent_name) do
    case cli_error_code(reason) do
      code when code in ["agent_not_running", "agent_not_found", "agent_name_not_found"] ->
        {:error, {:herdr_agent_closed, agent_name}}

      _ ->
        {:error, {:herdr_agent_get_failed, reason}}
    end
  end

  defp validate_wait_statuses(statuses) do
    if Enum.sort(statuses) == ["blocked", "done", "idle"],
      do: :ok,
      else: {:error, {:invalid_herdr_wait_settle_set, statuses}}
  end

  # Classify one observed Herdr 0.7.5 agent status string. The five statuses
  # are first-class outcomes. Any other string is a typed protocol/version
  # error, never coerced to `unknown`; command failures remain a distinct
  # class handled by the CLI error mapping.
  defp classify_agent_status(status) when status in @herdr_agent_statuses, do: {:ok, status}

  defp classify_agent_status(status) do
    {:error,
     {:incompatible_herdr_runtime,
      %{
        error_code: "unrecognized_agent_status",
        actual_status: status,
        expected_statuses: @herdr_agent_statuses
      }}}
  end

  # Typed outcome of one verified prompt submission observation. `working`
  # starts a turn; `idle`/`done` complete it. `blocked` settles but is never
  # success. `unknown` never proves completion or turn start. Out-of-enum
  # statuses are typed protocol/version errors.
  defp prompt_outcome(%{agent_status: status} = _observed, agent_name) do
    with {:ok, status} <- classify_agent_status(status) do
      case status do
        "working" -> {:ok, :working}
        settled when settled in ["idle", "done"] -> {:ok, :completed}
        "blocked" -> {:error, {:herdr_agent_blocked, agent_name}}
        "unknown" -> {:error, {:herdr_agent_status_unknown, agent_name}}
      end
    end
  end

  # Typed outcome of one settled `agent wait` observation. Only `idle` and
  # `done` are successful completion. `blocked` settles but is never success.
  # `unknown` never proves completion and is surfaced immediately as the typed
  # unknown outcome; Stage 2 supervision owns transient-vs-persistent behavior.
  # A `working` settle is typed unsettled — it is never completion.
  defp wait_outcome(%{agent_status: status} = _observed, agent_name) do
    with {:ok, status} <- classify_agent_status(status) do
      case status do
        settled when settled in ["idle", "done"] -> :ok
        "working" -> {:error, {:herdr_agent_wait_unsettled, agent_name, "working"}}
        "blocked" -> {:error, {:herdr_agent_blocked, agent_name}}
        "unknown" -> {:error, {:herdr_agent_status_unknown, agent_name}}
      end
    end
  end

  defp preserve_provider(observed, %{provider: provider}) when is_binary(provider),
    do: Map.put(observed, :provider, provider)

  defp preserve_provider(observed, _agent), do: observed

  defp until_args(statuses), do: Enum.flat_map(statuses, &["--until", &1])

  defp decode_agent_response(output) do
    with {:ok, payload} <- Jason.decode(output),
         agent when is_map(agent) <- get_in(payload, ["result", "agent"]) do
      {:ok, atomize_known_agent_fields(agent)}
    else
      _ -> {:error, :invalid_herdr_agent_response}
    end
  end

  defp prompt_error({:incompatible_herdr_runtime, _details} = reason, _agent_name),
    do: {:error, reason}

  defp prompt_error({:herdr_agent_blocked, _name} = reason, _agent_name), do: {:error, reason}

  defp prompt_error({:herdr_agent_status_unknown, _name} = reason, _agent_name),
    do: {:error, reason}

  defp prompt_error(reason, agent_name) do
    case cli_error_code(reason) do
      "agent_prompt_stalled" ->
        {:error, {:herdr_agent_prompt_stalled, agent_name}}

      code when code in ["agent_not_running", "agent_not_found", "agent_name_not_found"] ->
        {:error, {:herdr_agent_closed, agent_name}}

      "timeout" ->
        {:error, {:herdr_agent_status_timeout, agent_name, ["working", "idle", "done"]}}

      _ ->
        {:error, {:herdr_agent_prompt_failed, reason}}
    end
  end

  defp wait_error({:incompatible_herdr_runtime, _details} = reason, _agent_name, _statuses),
    do: {:error, reason}

  defp wait_error(reason, agent_name, statuses) do
    case cli_error_code(reason) do
      code when code in ["agent_not_running", "agent_not_found", "agent_name_not_found"] ->
        {:error, {:herdr_agent_closed, agent_name}}

      "timeout" ->
        {:error, {:herdr_agent_status_timeout, agent_name, statuses}}

      _ ->
        {:error, {:herdr_agent_wait_failed, reason}}
    end
  end

  defp cli_error_code({:port_exit, _status, output}) when is_binary(output) do
    with {:ok, payload} <- Jason.decode(output),
         code when is_binary(code) <- get_in(payload, ["error", "code"]) do
      code
    else
      _ -> nil
    end
  end

  defp cli_error_code(_reason), do: nil

  @impl true
  def read_agent(%{name: session_name, env: env}, %{name: agent_name}, opts, context) when is_map(opts) do
    source =
      case Map.get(opts, :source, :recent_unwrapped) do
        :recent_unwrapped -> "recent-unwrapped"
        :recent -> "recent"
        :visible -> "visible"
      end

    lines = Map.get(opts, :lines, 240)

    case command(
           context,
           ["--session", session_name, "agent", "read", agent_name, "--source", source, "--lines", to_string(lines)],
           env
         ) do
      {:ok, output} -> {:ok, %{text: output}}
      {:error, {:incompatible_herdr_runtime, _details} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:herdr_agent_read_failed, reason}}
    end
  end

  def read_agent(_session, _agent, _opts, _context), do: {:error, :invalid_herdr_agent_read}

  @doc """
  Report what this session can prove about its worker delegations.

  An empty list means the recording was readable and the orchestrator
  delivered nothing to the worker. Anything that prevents that observation —
  a session without a runtime root, a runtime root whose worker-event recording
  was never materialized, or a delegation issued in a Herdr command form the
  recorder could not classify — is a typed `:worker_assignments_unobservable`
  error, never a silent `[]`.
  """
  @impl true
  def worker_assignments(%{runtime_root: runtime_root} = session, context)
      when is_binary(runtime_root) and is_map(context) do
    worker_events = worker_events_root(runtime_root)

    if File.dir?(worker_events) do
      worker = Map.get(session, :worker, %{name: "implementer_worker"})

      with :ok <- validate_recordable_commands(worker_events),
           {:ok, assignment_messages} <-
             read_worker_messages(runtime_root, "assignment.*", @worker_assignment_prefix),
           {:ok, result_messages} <-
             read_worker_messages(runtime_root, "result.*", @worker_result_prefix) do
        assignments =
          assignment_messages
          |> Enum.map(&message_fields/1)
          |> Enum.filter(&(is_binary(Map.get(&1, "assignment")) and Map.get(&1, "assignment") != ""))

        results = Enum.map(result_messages, &message_fields/1)

        {:ok,
         observed_worker_assignments(
           assignments,
           results,
           channel_records(worker_events),
           session,
           worker,
           context
         )}
      end
    else
      {:error, {:worker_assignments_unobservable, %{reason: :worker_events_root_missing, runtime_root: runtime_root}}}
    end
  end

  def worker_assignments(_session, _context),
    do: {:error, {:worker_assignments_unobservable, %{reason: :session_runtime_root_missing}}}

  @impl true
  def stop_session(%{name: name, env: env, server_task: server_task, runtime_root: runtime_root}, context) do
    stop_result = command(context, ["--session", name, "server", "stop"], env)
    task_result = await_server_stop(server_task, Map.get(context, :stop_timeout_ms, @default_stop_timeout_ms))
    File.rm_rf(runtime_root)

    case {stop_result, task_result} do
      {{:ok, _output}, :ok} -> :ok
      {{:error, reason}, _} -> {:error, {:herdr_session_stop_failed, reason}}
      {_, {:error, reason}} -> {:error, {:herdr_server_exit_failed, reason}}
    end
  end

  def stop_session(_session, _context), do: {:error, :invalid_herdr_session_ref}

  @doc "Return the narrow capability needed to clean up this run-owned server outside its owner task."
  @spec owned_session_ref(map(), map()) :: map()
  def owned_session_ref(%{name: name, runtime_root: runtime_root}, context)
      when is_binary(name) and is_binary(runtime_root) and is_map(context) do
    %{
      kind: "herdr",
      session_name: name,
      runtime_root: runtime_root,
      cleanup_module: __MODULE__,
      cleanup_context: Map.take(context, [:herdr_bin, :extra_env, :socket_root, :stop_timeout_ms])
    }
  end

  @doc "Idempotently stop one explicitly owned Herdr server without relying on its owner task finalizer."
  @spec cleanup_owned_session(map()) :: :ok | {:error, term()}
  def cleanup_owned_session(%{kind: "herdr", session_name: name} = ownership_ref)
      when is_binary(name) do
    runtime_root = Map.get(ownership_ref, :runtime_root, short_socket_root(name))
    context = Map.get(ownership_ref, :cleanup_context, %{})

    with :ok <- validate_owned_runtime_root(name, runtime_root, context),
         :ok <- stop_owned_server_if_running(context, name, runtime_root) do
      File.rm_rf(runtime_root)
      :ok
    end
  end

  def cleanup_owned_session(_ownership_ref), do: {:error, :invalid_herdr_ownership_ref}

  defp await_running(context, name, env, server_task) do
    timeout_ms = Map.get(context, :start_timeout_ms, @default_start_timeout_ms)
    interval_ms = Map.get(context, :poll_interval_ms, @default_poll_interval_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_running(context, name, env, server_task, deadline, interval_ms)
  end

  defp validate_runtime(%{version: @required_version, protocol: @required_protocol}), do: :ok

  defp validate_runtime(status) do
    {:error,
     {:incompatible_herdr_runtime,
      %{
        expected_version: @required_version,
        expected_protocol: @required_protocol,
        actual_version: Map.get(status, :version),
        actual_protocol: Map.get(status, :protocol)
      }}}
  end

  defp cleanup_started_server(%{name: name, env: env, server_task: server_task, runtime_root: runtime_root}, context) do
    _ = command(context, ["--session", name, "server", "stop"], env)
    _ = await_server_stop(server_task, Map.get(context, :stop_timeout_ms, @default_stop_timeout_ms))
    File.rm_rf(runtime_root)
    :ok
  end

  defp do_await_running(context, name, env, server_task, deadline, interval_ms) do
    case Task.yield(server_task, 0) do
      {:ok, {:error, reason}} ->
        {:error, {:herdr_server_start_failed, reason}}

      {:ok, {:ok, output}} ->
        {:error, {:herdr_server_exited_before_ready, output}}

      nil ->
        await_running_status(context, name, env, server_task, deadline, interval_ms)
    end
  end

  defp await_running_status(context, name, env, server_task, deadline, interval_ms) do
    with {:ok, output} <-
           command_before_deadline(context, ["--session", name, "status", "server"], env, deadline),
         {:ok, %{status: "running"} = status} <- parse_server_status(output) do
      {:ok, status}
    else
      _ -> continue_await_running(context, name, env, server_task, deadline, interval_ms)
    end
  end

  defp continue_await_running(context, name, env, server_task, deadline, interval_ms) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :herdr_server_start_timeout}
    else
      Process.sleep(interval_ms)
      do_await_running(context, name, env, server_task, deadline, interval_ms)
    end
  end

  defp await_server_stop(server_task, timeout_ms) do
    case Task.yield(server_task, timeout_ms) do
      {:ok, {:ok, _output}} ->
        :ok

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, reason} ->
        {:error, reason}

      nil ->
        shutdown_server_task(server_task)
        {:error, :timeout}
    end
  end

  defp shutdown_server_task(server_task) do
    if Process.alive?(server_task.pid) do
      send(server_task.pid, :shutdown_command)
      _ = Task.yield(server_task, 1_000) || Task.shutdown(server_task, :brutal_kill)
    end

    :ok
  end

  defp command(context, args, env) do
    binary = Map.get(context, :herdr_bin) || System.find_executable("herdr") || "herdr"

    case System.cmd(binary, args, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> normalize_command_error(status, String.trim(output))
    end
  rescue
    error in ErlangError -> {:error, {:command_failed, Exception.message(error)}}
  end

  defp command_before_deadline(context, args, env, deadline) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: {:error, :command_timeout},
      else: command_in_port(context, args, env, deadline)
  end

  defp command_in_port(context, args, env, timeout) do
    binary = Map.get(context, :herdr_bin) || System.find_executable("herdr") || "herdr"

    with executable when is_binary(executable) <- executable_path(binary),
         port <-
           Port.open(
             {:spawn_executable, executable},
             [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args, env: port_env(env)]
           ) do
      try do
        receive_command_output(port, timeout, [])
      after
        if Port.info(port) != nil, do: terminate_port_process(port)
      end
    else
      nil -> {:error, {:command_failed, "executable not found: #{binary}"}}
    end
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:command_failed, Exception.message(error)}}
  end

  defp executable_path(binary) do
    if Path.type(binary) == :absolute, do: binary, else: System.find_executable(binary)
  end

  defp port_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp receive_command_output(port, :infinity, output) do
    receive do
      {^port, {:data, data}} ->
        receive_command_output(port, :infinity, [data | output])

      {^port, {:exit_status, status}} ->
        command_result(status, output)

      :shutdown_command ->
        terminate_port_process(port)
        {:error, :command_terminated}
    end
  end

  defp receive_command_output(port, deadline, output) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        receive_command_output(port, deadline, [data | output])

      {^port, {:exit_status, 0}} ->
        command_result_before_deadline(0, output, deadline)

      {^port, {:exit_status, status}} ->
        command_result_before_deadline(status, output, deadline)
    after
      remaining_ms ->
        terminate_port_process(port)
        {:error, :command_timeout}
    end
  end

  defp command_result_before_deadline(status, output, deadline) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: {:error, :command_timeout},
      else: command_result(status, output)
  end

  defp command_result(status, output) do
    output = output |> Enum.reverse() |> IO.iodata_to_binary()

    if status == 0,
      do: {:ok, output},
      else: normalize_command_error(status, String.trim(output))
  end

  defp terminate_port_process(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        await_port_exit(port)

      nil ->
        :ok
    end
  end

  defp await_port_exit(port) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      100 ->
        if Port.info(port) != nil, do: Port.close(port)
        :ok
    end
  end

  defp normalize_command_error(status, output) do
    reason = {:port_exit, status, output}

    case cli_error_code(reason) do
      "protocol_mismatch" ->
        {:error,
         {:incompatible_herdr_runtime,
          %{
            expected_version: @required_version,
            expected_protocol: @required_protocol,
            actual_version: nil,
            actual_protocol: nil,
            error_code: "protocol_mismatch"
          }}}

      _ ->
        {:error, reason}
    end
  end

  defp default_env(context), do: Map.get(context, :extra_env, [])

  defp isolated_env(context, runtime_root, session_env \\ %{}) do
    orchestrator_bin = Path.join(runtime_root, "orchestrator-bin")
    inherited_path = Map.get(session_env, "PATH") || System.get_env("PATH") || ""

    context
    |> default_env()
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Map.merge(Map.new(session_env, fn {key, value} -> {to_string(key), to_string(value)} end))
    |> Map.put("PATH", orchestrator_bin <> ":" <> inherited_path)
    |> Map.put("OCTO_HERDR_WORKER_LAUNCHER", Path.join(runtime_root, "launch-worker"))
    |> Map.put("XDG_CONFIG_HOME", runtime_root)
    |> Map.put("HERDR_DISABLE_SOUND", "1")
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp short_socket_root(name) do
    digest =
      :sha256
      |> :crypto.hash(name)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "/tmp/octo-herdr-#{digest}"
  end

  defp validate_socket_path(path) do
    if byte_size(path) <= 103,
      do: :ok,
      else: {:error, {:herdr_socket_path_too_long, byte_size(path)}}
  end

  defp validate_runtime_root(runtime_root) do
    if File.exists?(runtime_root),
      do: {:error, {:herdr_runtime_root_exists, runtime_root}},
      else: :ok
  end

  defp validate_owned_runtime_root(name, runtime_root, context) do
    expected_root = Map.get(context, :socket_root, short_socket_root(name))

    if runtime_root == expected_root,
      do: :ok,
      else: {:error, :invalid_herdr_owned_runtime_root}
  end

  defp stop_owned_server_if_running(context, name, runtime_root) do
    env = isolated_env(context, runtime_root)

    case command(context, ["--session", name, "status", "server"], env) do
      {:ok, output} ->
        case parse_server_status(output) do
          {:ok, %{status: "running"}} -> stop_owned_server(context, name, env)
          {:ok, _status} -> :ok
          {:error, reason} -> {:error, {:herdr_owned_session_status_failed, reason}}
        end

      {:error, {:port_exit, _status, output}} ->
        if String.contains?(String.downcase(output), "not running"),
          do: :ok,
          else: {:error, {:herdr_owned_session_status_failed, output}}

      {:error, reason} ->
        {:error, {:herdr_owned_session_status_failed, reason}}
    end
  end

  defp stop_owned_server(context, name, env) do
    case command(context, ["--session", name, "server", "stop"], env) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:herdr_owned_session_stop_failed, reason}}
    end
  end

  defp materialize_worker_launcher(_session, nil, _context), do: {:ok, nil, nil}

  defp materialize_worker_launcher(
         %{name: session_name, runtime_root: runtime_root, env: session_env},
         %{argv: argv} = worker,
         context
       )
       when is_binary(session_name) and is_list(session_env) and is_list(argv) and argv != [] do
    path = Path.join(runtime_root, "launch-worker")
    worker_bin = Path.join(runtime_root, "worker-bin")
    worker_panes = Path.join(runtime_root, "worker-panes")
    orchestrator_bin = Path.join(runtime_root, "orchestrator-bin")
    restricted_herdr = Path.join(worker_bin, "herdr")
    orchestrator_herdr = Path.join(orchestrator_bin, "herdr")
    real_herdr = Map.get(context, :herdr_bin) || System.find_executable("herdr") || "herdr"
    worker_env = Map.get(worker, :env, %{})

    with {:ok, kind, native_args} <- native_agent_launch(worker, argv),
         {:ok, worker_token, worker_projection_path} <-
           materialize_launch_projection(
             runtime_root,
             "implementer_worker",
             kind,
             hd(argv),
             native_args,
             Map.put(
               worker_env,
               "PATH",
               worker_bin <> ":" <> inherited_provider_path(session_env, orchestrator_bin)
             ),
             %{"PATH" => inherited_provider_path(session_env, orchestrator_bin)}
           ) do
      provider_command = hd(argv)
      provider_wrapper = Path.join(orchestrator_bin, provider_command)
      inherited_path = inherited_provider_path(session_env, orchestrator_bin)
      timeout_ms = Map.get(context, :agent_start_timeout_ms, @default_agent_start_timeout_ms)

      worker_wrapper = Path.join(orchestrator_bin, kind)
      projection_dir = Path.join(runtime_root, "launch-projections")
      preflight_dir = Path.join(runtime_root, "pane-preflight")
      launch_acks = Path.join(runtime_root, "launch-acks")

      # 50 ms poll cadence over the fixed startup ack deadline (5 s default;
      # test contexts may shorten it through the same override).
      handshake_attempts = max(div(launch_handshake_timeout_ms(context), 50), 1)

      pane_export_command = ~s(export PATH=#{shell_escape(orchestrator_bin)}:"$PATH")

      launcher_body = """
      #!/bin/sh
      set -eu
      if [ "$#" -ne 2 ]; then
        printf '%s\n' 'usage: launch-worker <name> <pane-id>' >&2
        exit 64
      fi
      if [ "$1" != "implementer_worker" ]; then
        printf '%s\n' 'worker name must be implementer_worker' >&2
        exit 64
      fi
      marker=$(mktemp #{shell_escape(Path.join(worker_panes, "pending.XXXXXX"))})
      printf '%s\n' "$2" > "$marker"
      trap 'rm -f "$marker"' EXIT HUP INT TERM
      mkdir -p #{shell_escape(preflight_dir)} #{shell_escape(launch_acks)}
      staging=$(mktemp #{shell_escape(Path.join(projection_dir, "staging.XXXXXX"))})
      launch_token=#{shell_escape(worker_token)}-"${staging##*.}"
      launch_projection=#{shell_escape(projection_dir)}/"$launch_token".sh
      cat #{shell_escape(worker_projection_path)} > "$staging"
      chmod 500 "$staging"
      mv -f "$staging" "$launch_projection"
      preflight_file=#{shell_escape(preflight_dir)}/"$launch_token"
      ack_dir=#{shell_escape(launch_acks)}/"$launch_token"
      #{shell_escape(orchestrator_herdr)} --session #{shell_escape(session_name)} pane run "$2" #{shell_escape(pane_export_command)} || {
        printf '%s\n' 'worker pane preparation failed' >&2
        exit 65
      }
      #{shell_escape(orchestrator_herdr)} --session #{shell_escape(session_name)} pane run "$2" "sh -c 'command -v #{kind}' > \\"$preflight_file.tmp\\" 2>&1 && mv -f \\"$preflight_file.tmp\\" \\"$preflight_file\\"" || {
        printf '%s\n' 'worker wrapper resolution failed' >&2
        exit 66
      }
      attempt=0
      while [ ! -f "$preflight_file" ] && [ "$attempt" -lt #{handshake_attempts} ]; do
        sleep 0.05
        attempt=$((attempt + 1))
      done
      resolved=$(cat "$preflight_file" 2>/dev/null || printf '%s' '')
      if [ "$resolved" != #{shell_escape(worker_wrapper)} ]; then
        printf '%s\n' "worker wrapper resolution failed: ${resolved:-unresolved}" >&2
        exit 66
      fi
      #{shell_escape(orchestrator_herdr)} --session #{shell_escape(session_name)} agent start "$1" --kind #{shell_escape(kind)} --pane "$2" --timeout #{timeout_ms} -- #{@launch_projection_sentinel} "$launch_projection"
      attempt=0
      while { [ ! -f "$ack_dir/wrapper.ack" ] || [ ! -f "$ack_dir/projection.ack" ]; } && [ "$attempt" -lt #{handshake_attempts} ]; do
        sleep 0.05
        attempt=$((attempt + 1))
      done
      wrapper_ack=$(cat "$ack_dir/wrapper.ack" 2>/dev/null || printf '%s' '')
      if [ "$wrapper_ack" != "$launch_token" ]; then
        printf '%s\n' "worker launch wrapper acknowledgement missing or malformed: ${wrapper_ack:-absent}" >&2
        exit 67
      fi
      projection_ack=$(cat "$ack_dir/projection.ack" 2>/dev/null || printf '%s' '')
      if [ "$projection_ack" != "$launch_token" ]; then
        printf '%s\n' "worker launch projection acknowledgement missing or malformed: ${projection_ack:-absent}" >&2
        exit 68
      fi
      """

      restricted_body = role_herdr_body(real_herdr, :worker, runtime_root)
      orchestrator_body = role_herdr_body(real_herdr, :orchestrator, runtime_root)

      provider_body = provider_wrapper_body(runtime_root, provider_command, inherited_path, worker_env)

      with :ok <- File.mkdir_p(worker_bin),
           :ok <- File.mkdir_p(worker_panes),
           :ok <- File.mkdir_p(orchestrator_bin),
           :ok <- write_executable(restricted_herdr, restricted_body),
           :ok <- write_executable(orchestrator_herdr, orchestrator_body),
           :ok <- write_executable(provider_wrapper, provider_body),
           :ok <- write_executable(path, launcher_body) do
        {:ok, path, orchestrator_bin}
      else
        {:error, reason} ->
          File.rm_rf(runtime_root)
          {:error, {:worker_launcher_materialization_failed, reason}}
      end
    end
  end

  defp materialize_worker_launcher(_session, _worker, _context),
    do: {:error, :invalid_worker_launcher_spec}

  defp provider_wrapper_body(runtime_root, provider_command, inherited_path, worker_env) do
    worker_bin = Path.join(runtime_root, "worker-bin")
    worker_panes = Path.join(runtime_root, "worker-panes")
    orchestrator_bin = Path.join(runtime_root, "orchestrator-bin")

    """
    #!/bin/sh
    set -eu
    provider_executable=$(PATH=#{shell_escape(inherited_path)} command -v #{shell_escape(provider_command)}) || {
      printf '%s\n' 'required worker provider executable is unavailable' >&2
      exit 127
    }
    worker_projection=false
    for marker in #{shell_escape(worker_panes)}/pending.*; do
      [ -f "$marker" ] || continue
      IFS= read -r expected_pane < "$marker" || continue
      [ "$expected_pane" = "${HERDR_PANE_ID:-}" ] || continue
      claimed_marker="${marker}.claimed.$$"
      if mv "$marker" "$claimed_marker" 2>/dev/null; then
        rm -f "$claimed_marker"
        worker_projection=true
        break
      fi
    done
    if [ "$worker_projection" = true ]; then
      export PATH=#{shell_escape(worker_bin)}:#{shell_escape(inherited_path)}
      #{launcher_env_exports(worker_env)}
    else
      export PATH=#{shell_escape(orchestrator_bin)}:#{shell_escape(inherited_path)}
    fi
    #{strip_herdr_injected_flag(provider_command)}if [ "${1:-}" != "#{@launch_projection_sentinel}" ]; then
      printf '%s\n' 'provider wrapper only accepts the launch projection sentinel' >&2
      exit 64
    fi
    if [ "$#" -ne 2 ]; then
      printf '%s\n' 'launch projection sentinel requires exactly one projection path' >&2
      exit 64
    fi
    projection="$2"
    launch_token=$(basename -- "$projection")
    launch_token="${launch_token%.sh}"
    ack_dir=#{shell_escape(Path.join(runtime_root, "launch-acks"))}/"$launch_token"
    mkdir -p "$ack_dir"
    if [ -n "${observed_injected_flag:-}" ]; then
      printf '%s\n' "$observed_injected_flag" > "$ack_dir/injected-flag.tmp"
      mv -f "$ack_dir/injected-flag.tmp" "$ack_dir/injected-flag"
    fi
    reject() {
      printf '%s\n' "$1" >&2
      printf '%s\n' "$1" > "$ack_dir/wrapper.reject"
      exit 64
    }
    if [ -L "$projection" ]; then
      reject 'launch projection must not be a symlink'
    fi
    projection_dir=$(CDPATH= cd -- "$(dirname -- "$projection")" 2>/dev/null && pwd -P) || reject 'launch projection directory is unresolvable'
    launch_dir=$(CDPATH= cd -- #{shell_escape(Path.join(runtime_root, "launch-projections"))} 2>/dev/null && pwd -P) || reject 'launch projection directory is unresolvable'
    canonical_projection="$projection_dir/$(basename -- "$projection")"
    case "$canonical_projection" in
      "$launch_dir"/*) ;;
      *)
        reject 'launch projection is outside the session runtime root'
        ;;
    esac
    if [ ! -f "$canonical_projection" ] || [ -L "$canonical_projection" ]; then
      reject 'launch projection is not a regular file'
    fi
    projection_stat=$(stat -c '%u %a' "$canonical_projection" 2>/dev/null || stat -f '%u %Lp' "$canonical_projection" 2>/dev/null) || reject 'launch projection metadata is unreadable'
    if [ "$projection_stat" != "$(id -u) 500" ]; then
      reject 'launch projection ownership or mode is invalid'
    fi
    printf '%s\n' "$launch_token" > "$ack_dir/wrapper.ack"
    exec "$canonical_projection" "$provider_executable"
    """
  end

  # Herdr 0.7.5 may prepend one kind-specific unattended-mode flag to the typed
  # AGENT_ARGs (observed on macOS and absent on Linux). The wrapper strips
  # exactly that flag when present before requiring the exact sentinel
  # invocation.
  defp strip_herdr_injected_flag(provider_command) do
    case herdr_injected_launch_flag(provider_command) do
      nil ->
        ""

      flag ->
        """
        if [ "${1:-}" = #{shell_escape(flag)} ]; then
          observed_injected_flag="$1"
          shift
        fi
        """
    end
  end

  defp herdr_injected_launch_flag("claude"), do: "--dangerously-skip-permissions"
  defp herdr_injected_launch_flag("codex"), do: "--yolo"
  defp herdr_injected_launch_flag(_provider_command), do: nil

  defp ensure_provider_wrapper(runtime_root, provider_command, session_env, _context) do
    orchestrator_bin = Path.join(runtime_root, "orchestrator-bin")
    provider_wrapper = Path.join(orchestrator_bin, provider_command)

    if File.exists?(provider_wrapper) or File.lstat(provider_wrapper) != {:error, :enoent} do
      case validate_launch_artifact(runtime_root, orchestrator_bin, provider_wrapper) do
        :ok -> :ok
        {:error, details} -> {:error, {:herdr_wrapper_resolution_failed, details}}
      end
    else
      inherited_path = inherited_provider_path(session_env, orchestrator_bin)
      body = provider_wrapper_body(runtime_root, provider_command, inherited_path, %{})

      with :ok <- File.mkdir_p(orchestrator_bin),
           :ok <- write_executable(provider_wrapper, body) do
        :ok
      else
        {:error, reason} ->
          {:error, {:herdr_wrapper_resolution_failed, %{reason: {:materialization_failed, reason}}}}
      end
    end
  end

  # Transport-side mirror of the wrapper's launch-artifact validation:
  # canonicalized containment (symlink escapes rejected), regular
  # non-symlink file, owned by the runtime-root owner, mode 0500.
  defp validate_launch_artifact(runtime_root, expected_dir, path) do
    with {:ok, canonical_path} <- canonicalize_path(path),
         {:ok, canonical_dir} <- canonicalize_path(expected_dir),
         :ok <- validate_artifact_containment(canonical_path, canonical_dir),
         {:ok, %File.Stat{type: :regular, mode: mode, uid: uid}} <- artifact_lstat(path),
         {:ok, %File.Stat{uid: root_uid}} <- artifact_lstat(runtime_root) do
      cond do
        Bitwise.band(mode, 0o7777) != 0o500 -> {:error, %{path: path, reason: :invalid_mode}}
        uid != root_uid -> {:error, %{path: path, reason: :invalid_owner}}
        true -> :ok
      end
    else
      {:ok, %File.Stat{type: type}} -> {:error, %{path: path, reason: {:not_a_regular_file, type}}}
      {:error, %{} = details} -> {:error, details}
    end
  end

  defp validate_launch_projection(runtime_root, projection_path) do
    case validate_launch_artifact(runtime_root, Path.join(runtime_root, "launch-projections"), projection_path) do
      :ok -> :ok
      {:error, details} -> {:error, {:herdr_projection_validation_failed, details}}
    end
  end

  defp artifact_lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, %{path: path, reason: {:unreadable, reason}}}
    end
  end

  defp validate_artifact_containment(canonical_path, canonical_dir) do
    if String.starts_with?(canonical_path, canonical_dir <> "/"),
      do: :ok,
      else: {:error, %{path: canonical_path, reason: :outside_session_runtime_root}}
  end

  defp canonicalize_path(path) do
    script = ~S|CDPATH= cd -- "$(dirname -- "$1")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$1")"|

    case System.cmd("/bin/sh", ["-c", script, "sh", path], stderr_to_stdout: true) do
      {canonical, 0} -> {:ok, canonical}
      {_output, _status} -> {:error, %{path: path, reason: :uncanonicalizable}}
    end
  end

  # Atomic temp+chmod+rename: a concurrent preflight or launch never observes
  # a remove/write gap or a not-yet-0500 artifact.
  defp write_executable(path, body) do
    staging = path <> ".staging." <> launch_nonce()

    with :ok <- File.write(staging, body),
         :ok <- File.chmod(staging, 0o500) do
      File.rename(staging, path)
    end
  end

  defp prepare_launch_pane(context, session_name, env, pane_id, kind, orchestrator_bin, runtime_root) do
    preflight_dir = Path.join(runtime_root, "pane-preflight")
    File.mkdir_p!(preflight_dir)
    preflight_file = Path.join(preflight_dir, launch_nonce())
    export_command = ~s(export PATH=#{shell_escape(orchestrator_bin)}:"$PATH")

    resolve_command =
      "sh -c #{shell_escape("command -v " <> shell_escape(kind))} > #{shell_escape(preflight_file <> ".tmp")} 2>&1 && " <>
        "mv -f #{shell_escape(preflight_file <> ".tmp")} #{shell_escape(preflight_file)}"

    with :ok <- pane_run(context, session_name, env, pane_id, export_command, :herdr_pane_preparation_failed),
         :ok <- pane_run(context, session_name, env, pane_id, resolve_command, :herdr_wrapper_resolution_failed) do
      verify_wrapper_resolution(preflight_file, Path.join(orchestrator_bin, kind), context)
    end
  end

  defp start_agent_command(context, args, env, runtime_root, launch_token) do
    deadline = System.monotonic_time(:millisecond) + launch_handshake_timeout_ms(context)
    start_agent_command(context, args, env, runtime_root, launch_token, deadline)
  end

  defp start_agent_command(context, args, env, runtime_root, launch_token, deadline) do
    case command(context, args, env) do
      {:ok, output} ->
        {:ok, output}

      {:error, {:incompatible_herdr_runtime, _details} = reason} ->
        {:error, reason}

      {:error, reason} ->
        # The pane shell can still be settling from the preparation commands
        # when start is issued; retry the transient busy state within the
        # startup window only.
        if cli_error_code(reason) == "agent_pane_busy" and
             System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          start_agent_command(context, args, env, runtime_root, launch_token, deadline)
        else
          {:error, provider_start_failure(runtime_root, launch_token, reason)}
        end
    end
  end

  # A wrapper-side projection rejection (for example a projection tampered
  # after the transport precheck) leaves a token-bound reject marker; surface
  # it as the projection-validation stage rather than a generic start failure.
  defp provider_start_failure(runtime_root, launch_token, reason) do
    case File.read(Path.join([runtime_root, "launch-acks", launch_token, "wrapper.reject"])) do
      {:ok, message} ->
        {:herdr_projection_validation_failed, %{stage: :wrapper, reason: String.trim(message)}}

      {:error, _read_error} ->
        {:herdr_provider_start_failed, reason}
    end
  end

  defp pane_run(context, session_name, env, pane_id, pane_command, failure_stage) do
    case command(context, ["--session", session_name, "pane", "run", pane_id, pane_command], env) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {failure_stage, reason}}
    end
  end

  defp verify_wrapper_resolution(preflight_file, expected_wrapper, context) do
    deadline = System.monotonic_time(:millisecond) + launch_handshake_timeout_ms(context)
    await_wrapper_resolution(preflight_file, expected_wrapper, deadline)
  end

  defp await_wrapper_resolution(preflight_file, expected_wrapper, deadline) do
    case File.read(preflight_file) do
      {:ok, resolved} ->
        resolved = String.trim(resolved)

        if resolved == expected_wrapper do
          :ok
        else
          {:error, {:herdr_wrapper_resolution_failed, %{expected: expected_wrapper, resolved: resolved}}}
        end

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:herdr_wrapper_resolution_failed, %{expected: expected_wrapper, resolved: nil}}}
        else
          Process.sleep(25)
          await_wrapper_resolution(preflight_file, expected_wrapper, deadline)
        end
    end
  end

  defp launch_nonce do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp launch_handshake_timeout_ms(context),
    do: Map.get(context, :launch_handshake_timeout_ms, @default_launch_handshake_timeout_ms)

  defp materialize_launch_projection(
         runtime_root,
         agent_name,
         kind,
         provider_command,
         native_args,
         extra_env,
         session_env
       )
       when is_binary(runtime_root) and is_binary(agent_name) and is_binary(kind) and
              is_binary(provider_command) and is_list(native_args) and is_map(extra_env) do
    projection_dir = Path.join(runtime_root, "launch-projections")

    digest =
      :sha256
      |> :crypto.hash(agent_name <> ":" <> kind)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    token = digest <> "-" <> launch_nonce()
    path = Path.join(projection_dir, token <> ".sh")

    case resolve_provider_executable(provider_command, session_env) do
      provider_executable when is_binary(provider_executable) ->
        body = """
        #!/bin/sh
        set -eu
        self_token=$(basename -- "$0")
        self_token="${self_token%.sh}"
        ack_dir=#{shell_escape(Path.join(runtime_root, "launch-acks"))}/"$self_token"
        mkdir -p "$ack_dir"
        printf '%s\\n' "$self_token" > "$ack_dir/projection.ack"
        #{launcher_env_exports(extra_env)}
        exec #{shell_escape(provider_executable)} #{Enum.map_join(native_args, " ", &shell_escape/1)}
        """

        with :ok <- File.mkdir_p(projection_dir),
             :ok <- write_executable(path, body) do
          {:ok, token, path}
        else
          {:error, reason} -> {:error, {:launch_projection_materialization_failed, reason}}
        end

      _ ->
        {:error, {:launch_projection_provider_unavailable, provider_command}}
    end
  end

  defp materialize_launch_projection(_root, _agent, _kind, _provider, _args, _extra, _session),
    do: {:error, :invalid_launch_projection}

  defp await_launch_acks(runtime_root, token, context) do
    ack_dir = Path.join([runtime_root, "launch-acks", token])
    reject_path = Path.join(ack_dir, "wrapper.reject")
    deadline = System.monotonic_time(:millisecond) + launch_handshake_timeout_ms(context)

    with :ok <- await_ack(Path.join(ack_dir, "wrapper.ack"), reject_path, token, deadline, :herdr_wrapper_ack_failed) do
      await_ack(Path.join(ack_dir, "projection.ack"), reject_path, token, deadline, :herdr_projection_ack_failed)
    end
  end

  defp await_ack(path, reject_path, token, deadline, failure_stage) do
    # A wrapper-side rejection can land after Herdr already reported start
    # success; surface it as the projection-validation stage rather than an
    # acknowledgement timeout.
    case File.read(reject_path) do
      {:ok, message} ->
        {:error, {:herdr_projection_validation_failed, %{stage: :wrapper, reason: String.trim(message)}}}

      {:error, _reason} ->
        await_ack_content(path, reject_path, token, deadline, failure_stage)
    end
  end

  defp await_ack_content(path, reject_path, token, deadline, failure_stage) do
    case File.read(path) do
      {:ok, content} ->
        observed = String.trim(content)

        if observed == token do
          :ok
        else
          {:error, {failure_stage, %{expected: token, observed: observed}}}
        end

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {failure_stage, %{expected: token, observed: nil}}}
        else
          Process.sleep(25)
          await_ack(path, reject_path, token, deadline, failure_stage)
        end
    end
  end

  defp resolve_provider_executable(provider_command, session_env) do
    search_path =
      session_env
      |> normalize_env_map()
      |> Map.get("PATH", System.get_env("PATH") || "")

    search_path
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, provider_command))
    |> Enum.find(fn candidate ->
      case File.stat(candidate) do
        {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
        _ -> false
      end
    end)
  end

  defp normalize_env_map(env),
    do: Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp inherited_provider_path(session_env, orchestrator_bin) do
    path = session_env |> Map.new() |> Map.get("PATH", System.get_env("PATH") || "")
    String.replace_prefix(path, orchestrator_bin <> ":", "")
  end

  defp launcher_env_exports(env) when is_map(env) do
    env
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(fn {key, value} -> "export #{key}=#{shell_escape(value)}\n" end)
  end

  defp role_herdr_body(real_herdr, role, runtime_root) do
    authorization =
      case role do
        :worker ->
          """
          case "$herdr_subcommand:$herdr_action" in
            agent:get|agent:list|agent:read|agent:prompt|agent:wait)
              ;;
            *)
              printf '%s\n' "worker Herdr authority denies: $*" >&2
              exit 64
              ;;
          esac
          """

        :orchestrator ->
          ""
      end

    """
    #!/bin/sh
    set -eu
    #{worker_event_recorder(runtime_root)}
    #{herdr_command_parser(role)}
    parse_herdr_command "$@"
    #{authorization}
    if [ "$herdr_prompt_parsed" -eq 1 ]; then
      agent_name=$herdr_prompt_target
      message=$herdr_prompt_message
      recovery_attempt=0
      while :; do
        if [ "$recovery_attempt" -eq 0 ]; then
          outbound=$message
        else
          outbound=' '
        fi

        if [ -n "$herdr_prompt_session" ]; then
          set -- --session "$herdr_prompt_session" agent prompt "$agent_name" "$outbound" --wait --until working --until idle --until done --until blocked --timeout #{@generated_prompt_timeout_ms}
        else
          set -- agent prompt "$agent_name" "$outbound" --wait --until working --until idle --until done --until blocked --timeout #{@generated_prompt_timeout_ms}
        fi

        set +e
        output=$(#{shell_escape(real_herdr)} "$@" 2>&1)
        status=$?
        set -e

        if [ "$status" -eq 0 ]; then
          #{worker_message_recording(role, runtime_root)}
          printf '%s' "$output"
          exit 0
        fi

        case "$output" in
          *'"code":"agent_prompt_stalled"'*)
            if [ "$recovery_attempt" -lt #{@prompt_recovery_attempts} ]; then
              recovery_attempt=$((recovery_attempt + 1))
              continue
            fi
            ;;
        esac

        printf '%s\n' "$output" >&2
        exit "$status"
      done
    fi

    if [ "$herdr_prompt_unrecordable" -eq 1 ]; then
      record_worker_event unparsed "$*"
    fi

    exec #{shell_escape(real_herdr)} "$@"
    """
  end

  # Herdr accepts its global options before the subcommand, so the delegation
  # is spelled `agent prompt <name> <message>` or
  # `--session <name> agent prompt <name> <message>` interchangeably. Position
  # alone cannot classify it. Options this parser does not model may or may not
  # consume a value, so any argv containing one is reported as unrecordable
  # rather than mis-parsed — an evidence recorder has to know its own blind
  # spots.
  defp herdr_command_parser(role) do
    counterpart =
      case role do
        :orchestrator -> "implementer_worker"
        :worker -> "implementer_orchestrator"
      end

    """
    parse_herdr_command() {
      herdr_subcommand=
      herdr_action=
      herdr_prompt_target=
      herdr_prompt_message=
      herdr_prompt_session=
      herdr_prompt_parsed=0
      herdr_prompt_unrecordable=0
      _unmodelled=0
      _positional=0
      _have_message=0
      _saw_prompt=0
      _saw_counterpart=0

      for _arg in "$@"; do
        if [ "$_arg" = prompt ]; then _saw_prompt=1; fi
        if [ "$_arg" = #{counterpart} ]; then _saw_counterpart=1; fi
      done

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --session)
            if [ "$#" -lt 2 ]; then _unmodelled=1; break; fi
            herdr_prompt_session=$2
            shift 2
            ;;
          --until|--timeout|--source|--lines|--kind|--pane|--direction)
            if [ "$#" -lt 2 ]; then _unmodelled=1; break; fi
            shift 2
            ;;
          --wait|--no-focus|--)
            shift
            ;;
          --*=*)
            shift
            ;;
          -*)
            _unmodelled=1
            shift
            ;;
          *)
            _positional=$((_positional + 1))
            case "$_positional" in
              1) herdr_subcommand=$1 ;;
              2) herdr_action=$1 ;;
              3) herdr_prompt_target=$1 ;;
              4) herdr_prompt_message=$1; _have_message=1 ;;
            esac
            shift
            ;;
        esac
      done

      if [ "$_unmodelled" -eq 0 ] && [ "$herdr_subcommand" = agent ] && [ "$herdr_action" = prompt ] &&
         [ -n "$herdr_prompt_target" ] && [ "$_have_message" -eq 1 ]; then
        herdr_prompt_parsed=1
      elif [ "$_unmodelled" -eq 1 ] && [ "$_saw_prompt" -eq 1 ] && [ "$_saw_counterpart" -eq 1 ]; then
        herdr_prompt_unrecordable=1
      fi
    }
    """
  end

  # Sequence-numbered so the read side recovers delivery order from a lexical
  # sort. Each role writes its own prefixes, and one agent's prompts are
  # serial, so the count-then-create step needs no cross-process locking.
  defp worker_event_recorder(runtime_root) do
    worker_events = worker_events_root(runtime_root)

    """
    record_worker_event() {
      _prefix=$1
      _seq=$( (set -- #{shell_escape(worker_events)}/"$_prefix".*; if [ -e "$1" ]; then printf '%s' "$#"; else printf '0'; fi) )
      _file=$(mktemp #{shell_escape(worker_events)}/"$_prefix"."$(printf '%06d' "$((_seq + 1))")".XXXXXX)
      printf '%s\\n' "$2" > "$_file"
    }
    """
  end

  # The channel itself is the record. Every prompt the orchestrator sends to
  # the worker is a delivery and every prompt the worker sends back is a reply,
  # whether or not either side used the `OCTO_MSG` envelope. The envelope stays
  # the richer record — it carries the agent's own assignment id and status —
  # but the evidence contract no longer depends on an agent remembering it.
  defp worker_message_recording(:orchestrator, _runtime_root) do
    """
    case "$agent_name" in
      implementer_worker)
        record_worker_event delivery "$message"
        ;;
    esac
    case "$agent_name:$message" in
      implementer_worker:'#{@worker_assignment_prefix}'*)
        record_worker_event assignment "$message"
        ;;
    esac
    """
  end

  defp worker_message_recording(:worker, _runtime_root) do
    """
    case "$agent_name" in
      implementer_orchestrator)
        record_worker_event reply "$message"
        ;;
    esac
    case "$agent_name:$message" in
      implementer_orchestrator:'#{@worker_result_prefix}'*)
        record_worker_event result "$message"
        ;;
    esac
    """
  end

  defp create_worker_pane(
         %{name: session_name, env: env, pane_id: root_pane_id},
         context
       )
       when is_binary(root_pane_id) do
    with {:ok, output} <-
           command(
             context,
             [
               "--session",
               session_name,
               "pane",
               "split",
               root_pane_id,
               "--direction",
               "right",
               "--no-focus"
             ],
             env
           ),
         {:ok, payload} <- Jason.decode(output),
         pane_id when is_binary(pane_id) <-
           get_in(payload, ["result", "pane", "pane_id"]) do
      {:ok, pane_id}
    else
      {:error, reason} -> {:error, {:herdr_worker_pane_create_failed, reason}}
      _ -> {:error, :invalid_herdr_worker_pane_response}
    end
  end

  defp read_worker_messages(runtime_root, pattern, prefix) do
    messages =
      runtime_root
      |> worker_events_root()
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce_while([], &read_worker_message(&1, prefix, &2))

    case messages do
      {:error, reason} -> {:error, reason}
      messages when is_list(messages) -> {:ok, Enum.reverse(messages)}
    end
  end

  defp read_worker_message(path, prefix, messages) do
    case File.read(path) do
      {:ok, message} ->
        continue_worker_message(path, prefix, String.trim(message), messages)

      {:error, reason} ->
        {:halt, {:error, {:worker_message_read_failed, reason}}}
    end
  end

  defp continue_worker_message(path, prefix, message, messages) do
    if String.starts_with?(message, prefix),
      do: {:cont, [message | messages]},
      else: {:halt, {:error, {:invalid_worker_message, Path.basename(path)}}}
  end

  defp message_fields(message) do
    message
    |> String.split(~r/\s+/, trim: true)
    |> Enum.drop(2)
    |> Enum.reduce(%{}, fn field, fields ->
      case String.split(field, "=", parts: 2) do
        [key, value] -> Map.put(fields, key, value)
        _ -> fields
      end
    end)
  end

  # The shim reports the argv shapes it could not classify. One of those is
  # proof that a delegation happened and was not recorded, which is exactly the
  # observation this contract must never round down to "no worker assignments".
  defp validate_recordable_commands(worker_events) do
    case worker_events |> Path.join("unparsed.*") |> Path.wildcard() |> length() do
      0 ->
        :ok

      unparsed ->
        {:error, {:worker_assignments_unobservable, %{reason: :unrecognized_herdr_command_form, unparsed: unparsed}}}
    end
  end

  defp channel_records(worker_events) do
    %{
      deliveries: sequenced_worker_events(worker_events, "delivery.*"),
      replies: sequenced_worker_events(worker_events, "reply.*")
    }
  end

  defp sequenced_worker_events(worker_events, pattern) do
    worker_events
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&Path.basename/1)
  end

  # The `OCTO_MSG` envelope is preferred where an agent used it, because it
  # carries the agent's own assignment id and status. Where it was not used the
  # channel still proves the delegation, so a delivered assignment is never
  # read back as a run that had no worker.
  defp observed_worker_assignments(assignments, results, channel, session, worker, context) do
    correlated = correlate_worker_assignments(assignments, results, session, worker, context)

    case correlated ++ unrecorded_assignment_results(assignments, results) do
      [] -> channel_worker_assignments(channel, session, worker, context)
      observed -> Enum.map(observed, &Map.put(&1, :evidence, :envelope))
    end
  end

  defp channel_worker_assignments(%{deliveries: deliveries, replies: replies}, session, worker, context) do
    correlated =
      deliveries
      |> Enum.with_index()
      |> Enum.map(fn {delivery, index} ->
        assignment_id = channel_assignment_id(session, delivery)

        case Enum.at(replies, index) do
          nil ->
            assignment_id
            |> worker_assignment_status(nil, session, worker, context)
            |> Map.put(:evidence, :channel)

          _reply ->
            %{
              assignment_id: assignment_id,
              status: :completed,
              evidence: :channel,
              result: %{assignment_id: assignment_id, status: "returned"}
            }
        end
      end)

    correlated ++ unmatched_worker_replies(deliveries, replies)
  end

  # A reply can only exist because the worker was prompted. One with no
  # delivery behind it means the orchestrator side of the channel was not
  # recorded — the run delegated and Symphony cannot say to what.
  defp unmatched_worker_replies(deliveries, replies) do
    replies
    |> Enum.drop(length(deliveries))
    |> Enum.map(fn _reply -> %{assignment_id: nil, status: :delivery_unrecorded, evidence: :channel} end)
  end

  defp channel_assignment_id(session, delivery),
    do: "#{Map.get(session, :name)}/#{delivery}"

  defp unrecorded_assignment_results(assignments, results) do
    assigned = MapSet.new(assignments, &Map.get(&1, "assignment"))

    results
    |> Enum.reject(&MapSet.member?(assigned, Map.get(&1, "assignment")))
    |> Enum.map(fn result ->
      %{
        assignment_id: Map.get(result, "assignment"),
        status: :assignment_unrecorded,
        result: %{
          assignment_id: Map.get(result, "assignment"),
          status: Map.get(result, "status"),
          message: Map.get(result, "message")
        }
      }
    end)
  end

  defp correlate_worker_assignments(assignments, results, session, worker, context) do
    Enum.map(assignments, fn assignment ->
      assignment_id = Map.fetch!(assignment, "assignment")

      result =
        Enum.find(results, &(Map.get(&1, "assignment") == assignment_id)) ||
          List.first(results)

      worker_assignment_status(
        assignment_id,
        result,
        session,
        worker,
        context
      )
    end)
  end

  defp worker_assignment_status(assignment_id, %{} = result, _session, _worker, _context) do
    %{
      assignment_id: assignment_id,
      status: result_status(result),
      result: %{
        assignment_id: Map.get(result, "assignment"),
        status: Map.get(result, "status"),
        message: Map.get(result, "message")
      }
    }
  end

  defp worker_assignment_status(assignment_id, nil, session, worker, context) do
    case get_agent(session, worker, @default_poll_interval_ms * 20, context) do
      {:ok, %{agent_status: status}} when status in ["working", "unknown"] ->
        %{assignment_id: assignment_id, status: :timed_out}

      {:ok, _worker} ->
        %{assignment_id: assignment_id, status: :launched}

      {:error, {:herdr_agent_closed, _name} = reason} ->
        %{assignment_id: assignment_id, status: :died, reason: reason}

      {:error, reason} ->
        %{assignment_id: assignment_id, status: :died, reason: reason}
    end
  end

  defp result_status(%{"status" => "completed"}), do: :completed
  defp result_status(%{"status" => "failed"}), do: :failed
  defp result_status(_result), do: :failed

  defp worker_events_root(runtime_root), do: Path.join(runtime_root, "worker-events")

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  defp parse_server_status(output) when is_binary(output) do
    fields =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, fields ->
        case String.split(line, ":", parts: 2) do
          [key, value] -> Map.put(fields, String.trim(key), String.trim(value))
          _ -> fields
        end
      end)

    with status when is_binary(status) <- Map.get(fields, "status"),
         socket when is_binary(socket) <- Map.get(fields, "socket") do
      {:ok,
       %{
         status: status,
         version: Map.get(fields, "version"),
         protocol: parse_integer(Map.get(fields, "protocol")),
         socket: socket
       }}
    else
      _ -> {:error, :invalid_herdr_server_status}
    end
  end

  defp parse_integer(nil), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp atomize_known_agent_fields(agent) do
    %{
      name: Map.get(agent, "name"),
      pane_id: Map.get(agent, "pane_id"),
      agent_status: Map.get(agent, "agent_status"),
      agent: Map.get(agent, "agent"),
      agent_session: Map.get(agent, "agent_session"),
      revision: Map.get(agent, "revision")
    }
  end
end
