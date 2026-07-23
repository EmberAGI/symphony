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
        {:ok, session |> Map.put(:worker_launcher, worker_launcher) |> Map.put(:orchestrator_bin, orchestrator_bin)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def prepare_worker(_session, _worker, _context), do: {:error, :invalid_herdr_worker_session}

  @impl true
  def start_agent(
        %{name: session_name, env: env, pane_id: pane_id},
        %{name: name, cwd: cwd, argv: argv} = spec,
        context
      )
      when is_binary(name) and name != "" and is_binary(cwd) and is_binary(pane_id) and
             is_list(argv) and argv != [] do
    timeout_ms = Map.get(context, :agent_start_timeout_ms, @default_agent_start_timeout_ms)

    with {:ok, kind, native_args} <- native_agent_launch(spec, argv),
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
             "--"
           ] ++ native_args,
         {:ok, output} <- command(context, args, env),
         {:ok, payload} <- Jason.decode(output),
         agent when is_map(agent) <- get_in(payload, ["result", "agent"]) do
      {:ok, agent |> atomize_known_agent_fields() |> Map.put(:provider, Map.get(spec, :provider))}
    else
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
         {:ok, phase} <- prompt_phase(observed) do
      {:ok, %{phase: phase, agent: preserve_provider(observed, agent)}}
    else
      {:error, reason} -> prompt_error(reason, agent_name)
    end
  end

  def begin_turn(_session, _agent, _prompt, _timeout_ms, _context),
    do: {:error, :invalid_herdr_begin_turn}

  defp submit_prompt(context, session_name, env, agent_name, prompt, timeout_ms, recoveries_left) do
    args =
      ["--session", session_name, "agent", "prompt", agent_name, prompt, "--wait"] ++
        until_args(["working", "idle", "done"]) ++ ["--timeout", to_string(timeout_ms)]

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
    args =
      ["--session", session_name, "agent", "wait", agent_name] ++
        until_args(statuses) ++ ["--timeout", to_string(timeout_ms)]

    with {:ok, output} <- command(context, args, env),
         {:ok, observed} <- decode_agent_response(output) do
      {:ok, preserve_provider(observed, agent)}
    else
      {:error, reason} -> wait_error(reason, agent_name, statuses)
    end
  end

  def await_agent(_session, _agent, _statuses, _timeout_ms, _context), do: {:error, :invalid_herdr_agent_wait}

  defp preserve_provider(observed, %{provider: provider}) when is_binary(provider),
    do: Map.put(observed, :provider, provider)

  defp preserve_provider(observed, _agent), do: observed

  defp until_args(statuses), do: Enum.flat_map(statuses, &["--until", &1])

  defp prompt_phase(%{agent_status: "working"}), do: {:ok, :working}
  defp prompt_phase(%{agent_status: status}) when status in ["idle", "done"], do: {:ok, :completed}
  defp prompt_phase(%{agent_status: status}), do: {:error, {:unexpected_herdr_agent_status, status}}

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

    with {:ok, kind, native_args} <- native_agent_launch(worker, argv) do
      provider_command = hd(argv)
      provider_wrapper = Path.join(orchestrator_bin, provider_command)
      inherited_path = inherited_provider_path(session_env, orchestrator_bin)
      timeout_ms = Map.get(context, :agent_start_timeout_ms, @default_agent_start_timeout_ms)

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
      #{shell_escape(orchestrator_herdr)} --session #{shell_escape(session_name)} agent start "$1" --kind #{shell_escape(kind)} --pane "$2" --timeout #{timeout_ms} -- #{Enum.map_join(native_args, " ", &shell_escape/1)}
      """

      restricted_body = role_herdr_body(real_herdr, :worker)
      orchestrator_body = role_herdr_body(real_herdr, :orchestrator)

      provider_body = """
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
      exec "$provider_executable" "$@"
      """

      with :ok <- File.mkdir_p(worker_bin),
           :ok <- File.mkdir_p(worker_panes),
           :ok <- File.mkdir_p(orchestrator_bin),
           :ok <- File.write(restricted_herdr, restricted_body),
           :ok <- File.chmod(restricted_herdr, 0o500),
           :ok <- File.write(orchestrator_herdr, orchestrator_body),
           :ok <- File.chmod(orchestrator_herdr, 0o500),
           :ok <- File.write(provider_wrapper, provider_body),
           :ok <- File.chmod(provider_wrapper, 0o500),
           :ok <- File.write(path, launcher_body),
           :ok <- File.chmod(path, 0o500) do
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

  defp inherited_provider_path(session_env, orchestrator_bin) do
    path = session_env |> Map.new() |> Map.get("PATH", System.get_env("PATH") || "")
    String.replace_prefix(path, orchestrator_bin <> ":", "")
  end

  defp launcher_env_exports(env) when is_map(env) do
    env
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(fn {key, value} -> "export #{key}=#{shell_escape(value)}\n" end)
  end

  defp launcher_env_exports(_env), do: ""

  defp role_herdr_body(real_herdr, role) do
    authorization =
      case role do
        :worker ->
          """
          case "${1:-}:${2:-}" in
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
    #{authorization}
    if [ "${1:-}" = "agent" ] && [ "${2:-}" = "prompt" ] && [ "$#" -ge 4 ]; then
      agent_name=$3
      recovery_attempt=0
      while :; do
        if [ "$recovery_attempt" -eq 0 ]; then
          set -- "$@" --wait --until working --until idle --until done --timeout #{@generated_prompt_timeout_ms}
        else
          set -- agent prompt "$agent_name" ' ' --wait --until working --until idle --until done --timeout #{@generated_prompt_timeout_ms}
        fi

        set +e
        output=$(#{shell_escape(real_herdr)} "$@" 2>&1)
        status=$?
        set -e

        if [ "$status" -eq 0 ]; then
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

    exec #{shell_escape(real_herdr)} "$@"
    """
  end

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
