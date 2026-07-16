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
  @required_version "0.7.3"
  @required_protocol 16

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
    env = isolated_env(context, runtime_root)
    expected_socket = Path.join([runtime_root, "herdr", "sessions", name, "herdr.sock"])

    with :ok <- validate_socket_path(expected_socket),
         :ok <- validate_runtime_root(runtime_root),
         {:ok, worker_launcher} <- materialize_worker_launcher(runtime_root, Map.get(spec, :worker), context) do
      File.mkdir_p!(runtime_root)

      server_task =
        Task.async(fn ->
          command(context, ["--session", name, "server"], env)
        end)

      case await_running(context, name, env, server_task) do
        {:ok, status} ->
          session = %{
            name: name,
            socket: status.socket,
            runtime_root: runtime_root,
            worker_launcher: worker_launcher,
            env: env,
            server_task: server_task
          }

          case validate_runtime(status) do
            :ok ->
              {:ok, session}

            {:error, reason} ->
              cleanup_started_server(session, context)
              {:error, reason}
          end

        {:error, reason} ->
          shutdown_server_task(server_task)
          File.rm_rf(runtime_root)
          {:error, reason}
      end
    end
  end

  def start_session(_spec, _context), do: {:error, :invalid_herdr_isolated_session_spec}

  @impl true
  def start_agent(%{name: session_name, env: env}, %{name: name, cwd: cwd, argv: argv} = spec, context)
      when is_binary(name) and name != "" and is_binary(cwd) and is_list(argv) and argv != [] do
    args =
      ["--session", session_name, "agent", "start", name, "--cwd", cwd] ++
        agent_env_args(Map.get(spec, :env, %{})) ++
        ["--no-focus", "--"] ++
        Enum.map(argv, &to_string/1)

    with {:ok, output} <- command(context, args, env),
         {:ok, payload} <- Jason.decode(output),
         agent when is_map(agent) <- get_in(payload, ["result", "agent"]) do
      {:ok, atomize_known_agent_fields(agent)}
    else
      {:error, reason} -> {:error, {:herdr_agent_start_failed, reason}}
      _ -> {:error, :invalid_herdr_agent_start_response}
    end
  end

  def start_agent(_session, _spec, _context), do: {:error, :invalid_herdr_agent_spec}

  @impl true
  def submit(%{name: session_name, env: env}, %{pane_id: pane_id}, prompt, context)
      when is_binary(pane_id) and is_binary(prompt) and prompt != "" do
    case command(context, ["--session", session_name, "pane", "run", pane_id, prompt], env) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:herdr_submit_failed, reason}}
    end
  end

  def submit(_session, _agent, _prompt, _context), do: {:error, :invalid_herdr_submit}

  @impl true
  def await_agent(%{name: session_name, env: env}, %{name: agent_name}, statuses, timeout_ms, context)
      when is_list(statuses) and statuses != [] and is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_interval_ms = Map.get(context, :poll_interval_ms, @default_poll_interval_ms)
    do_await_agent(context, session_name, env, agent_name, MapSet.new(statuses), deadline, poll_interval_ms)
  end

  def await_agent(_session, _agent, _statuses, _timeout_ms, _context), do: {:error, :invalid_herdr_agent_wait}

  @impl true
  def read_agent(%{name: session_name, env: env}, %{name: agent_name}, opts, context) when is_map(opts) do
    source =
      case Map.get(opts, :source, :recent_unwrapped) do
        :recent_unwrapped -> "recent-unwrapped"
        :recent -> "recent"
        :visible -> "visible"
      end

    lines = Map.get(opts, :lines, 240)

    with {:ok, output} <-
           command(
             context,
             ["--session", session_name, "agent", "read", agent_name, "--source", source, "--lines", to_string(lines)],
             env
           ),
         {:ok, payload} <- Jason.decode(output),
         read when is_map(read) <- get_in(payload, ["result", "read"]),
         text when is_binary(text) <- Map.get(read, "text") do
      {:ok, %{text: text}}
    else
      {:error, reason} -> {:error, {:herdr_agent_read_failed, reason}}
      _ -> {:error, :invalid_herdr_agent_read_response}
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

  defp do_await_agent(context, session_name, env, agent_name, statuses, deadline, poll_interval_ms) do
    case command(context, ["--session", session_name, "agent", "get", agent_name], env) do
      {:ok, output} ->
        with {:ok, payload} <- Jason.decode(output),
             agent when is_map(agent) <- get_in(payload, ["result", "agent"]) do
          normalized = atomize_known_agent_fields(agent)

          if agent_matches?(normalized, statuses) do
            confirm_stable_agent(
              context,
              session_name,
              env,
              agent_name,
              statuses,
              normalized,
              deadline,
              poll_interval_ms
            )
          else
            continue_await_agent(context, session_name, env, agent_name, statuses, deadline, poll_interval_ms)
          end
        else
          _ -> continue_await_agent(context, session_name, env, agent_name, statuses, deadline, poll_interval_ms)
        end

      {:error, _reason} ->
        continue_await_agent(context, session_name, env, agent_name, statuses, deadline, poll_interval_ms)
    end
  end

  defp confirm_stable_agent(
         context,
         session_name,
         env,
         agent_name,
         statuses,
         normalized,
         deadline,
         poll_interval_ms
       ) do
    if MapSet.subset?(statuses, MapSet.new(["idle", "done"])) do
      stability_ms = Map.get(context, :ready_stability_ms, 750)
      Process.sleep(stability_ms)

      case command(context, ["--session", session_name, "agent", "get", agent_name], env) do
        {:ok, output} ->
          with {:ok, payload} <- Jason.decode(output),
               agent when is_map(agent) <- get_in(payload, ["result", "agent"]),
               confirmed = atomize_known_agent_fields(agent),
               true <- agent_matches?(confirmed, statuses),
               true <- confirmed.agent_session == normalized.agent_session do
            {:ok, confirmed}
          else
            _ -> continue_await_agent(context, session_name, env, agent_name, statuses, deadline, poll_interval_ms)
          end

        {:error, _reason} ->
          continue_await_agent(context, session_name, env, agent_name, statuses, deadline, poll_interval_ms)
      end
    else
      {:ok, normalized}
    end
  end

  defp agent_matches?(normalized, statuses) do
    MapSet.member?(statuses, normalized.agent_status) and
      is_binary(normalized.agent)
  end

  defp continue_await_agent(context, session_name, env, agent_name, statuses, deadline, poll_interval_ms) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, {:herdr_agent_status_timeout, agent_name, MapSet.to_list(statuses)}}
    else
      Process.sleep(poll_interval_ms)
      do_await_agent(context, session_name, env, agent_name, statuses, deadline, poll_interval_ms)
    end
  end

  defp do_await_running(context, name, env, server_task, deadline, interval_ms) do
    case Task.yield(server_task, 0) do
      {:ok, {:error, reason}} ->
        {:error, {:herdr_server_start_failed, reason}}

      {:ok, {:ok, output}} ->
        {:error, {:herdr_server_exited_before_ready, output}}

      nil ->
        case command(context, ["--session", name, "status", "server"], env) do
          {:ok, output} ->
            case parse_server_status(output) do
              {:ok, %{status: "running"} = status} ->
                {:ok, status}

              _other ->
                continue_await_running(context, name, env, server_task, deadline, interval_ms)
            end

          {:error, _reason} ->
            continue_await_running(context, name, env, server_task, deadline, interval_ms)
        end
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
    case Task.yield(server_task, timeout_ms) || Task.shutdown(server_task, :brutal_kill) do
      {:ok, {:ok, _output}} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end
  end

  defp shutdown_server_task(server_task) do
    _ = Task.shutdown(server_task, :brutal_kill)
    :ok
  end

  defp command(context, args, env) do
    binary = Map.get(context, :herdr_bin) || System.find_executable("herdr") || "herdr"

    case System.cmd(binary, args, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:port_exit, status, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:command_failed, Exception.message(error)}}
  end

  defp default_env(context), do: Map.get(context, :extra_env, [])

  defp isolated_env(context, runtime_root) do
    context
    |> default_env()
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
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

  defp materialize_worker_launcher(_runtime_root, nil, _context), do: {:ok, nil}

  defp materialize_worker_launcher(runtime_root, %{argv: argv}, context) when is_list(argv) and argv != [] do
    path = Path.join(runtime_root, "launch-worker")
    worker_bin = Path.join(runtime_root, "worker-bin")
    restricted_herdr = Path.join(worker_bin, "herdr")
    real_herdr = Map.get(context, :herdr_bin) || System.find_executable("herdr") || "herdr"

    launcher_body =
      "#!/bin/sh\nset -eu\nexport PATH=#{shell_escape(worker_bin)}:\"${PATH:-}\"\nexec #{Enum.map_join(argv, " ", &shell_escape/1)}\n"

    restricted_body = """
    #!/bin/sh
    set -eu
    case "${1:-}:${2:-}" in
      agent:get|agent:list|agent:wait|pane:run|wait:agent-status)
        exec #{shell_escape(real_herdr)} "$@"
        ;;
      *)
        printf '%s\n' "worker Herdr authority denies: $*" >&2
        exit 64
        ;;
    esac
    """

    with :ok <- File.mkdir_p(worker_bin),
         :ok <- File.write(restricted_herdr, restricted_body),
         :ok <- File.chmod(restricted_herdr, 0o500),
         :ok <- File.write(path, launcher_body),
         :ok <- File.chmod(path, 0o500) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm_rf(runtime_root)
        {:error, {:worker_launcher_materialization_failed, reason}}
    end
  end

  defp materialize_worker_launcher(_runtime_root, _worker, _context),
    do: {:error, :invalid_worker_launcher_spec}

  defp agent_env_args(env) when is_map(env) do
    env
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} -> ["--env", "#{key}=#{value}"] end)
  end

  defp agent_env_args(_env), do: []

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
      agent_session: Map.get(agent, "agent_session")
    }
  end
end
