defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{AgentRuntime, Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  # Per-turn bootstrap inputs the role workflows declare as required. Every
  # role fails closed when one is absent rather than inferring repository or
  # branch metadata, so a nil here is a missing input, not an empty variable:
  # the projection names it and fails at this boundary instead of handing the
  # role an unset variable three layers later, inside the turn.
  @required_bootstrap_env [
    {"SYMPHONY_ISSUE_REPOSITORY", :repository},
    {"SYMPHONY_EXPECTED_BRANCH", :expected_branch}
  ]

  @type worker_host :: String.t() | nil

  @doc """
  Return the non-secret issue context exported to workspace hooks and role
  runtimes.

  This is the single bootstrap projection every role turn goes through. It
  fails typed when a required bootstrap input cannot be supplied.
  """
  @spec issue_environment(map() | String.t() | nil) ::
          {:ok, %{String.t() => String.t()}} | {:error, {:missing_required_bootstrap_input, map()}}
  def issue_environment(issue_or_identifier) do
    with {:ok, env} <- issue_or_identifier |> issue_context() |> hook_env() do
      {:ok, Map.new(env)}
    end
  end

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_workspace_identifier(issue_context)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{} = issue_or_identifier, worker_host) when is_binary(worker_host) do
    safe_id =
      issue_or_identifier
      |> issue_context()
      |> safe_workspace_identifier()

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(issue_or_identifier, worker_host)
      when is_binary(issue_or_identifier) and is_binary(worker_host) do
    safe_id =
      issue_or_identifier
      |> issue_context()
      |> safe_workspace_identifier()

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(%{} = issue_or_identifier, nil) do
    issue_context = issue_context(issue_or_identifier)
    safe_id = safe_workspace_identifier(issue_context)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue_or_identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(issue_or_identifier, nil) when is_binary(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)
    safe_id = safe_workspace_identifier(issue_context)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue_or_identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(
          Path.t(),
          map() | String.t() | nil,
          worker_host(),
          [{String.t(), String.t()}]
        ) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil, extra_env \\ [])
      when is_binary(workspace) and is_list(extra_env) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host, extra_env)
    end
  end

  @spec run_after_run_hook(
          Path.t(),
          map() | String.t() | nil,
          worker_host(),
          [{String.t(), String.t()}]
        ) ::
          :ok | {:error, term()}
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil, extra_env \\ [])
      when is_binary(workspace) and is_list(extra_env) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host, extra_env)
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp safe_workspace_identifier(issue_context) do
    issue_id = safe_identifier(issue_context.issue_identifier)

    case repository_workspace_suffix(issue_context) do
      nil -> issue_id
      suffix -> "#{issue_id}-#{suffix}"
    end
  end

  defp repository_workspace_suffix(%{repository: repository})
       when is_binary(repository) do
    repository
    |> String.split("/", parts: 2)
    |> List.last()
    |> case do
      "" -> nil
      value -> safe_identifier(value)
    end
  end

  defp repository_workspace_suffix(_issue_context), do: nil

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            removal_context = %{issue_id: nil, issue_identifier: Path.basename(workspace)}

            run_hook_with_env(
              command,
              workspace,
              removal_context,
              "before_remove",
              nil,
              workspace_removal_env(removal_context)
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, extra_env \\ []) do
    with {:ok, env} <- hook_env(issue_context, extra_env) do
      run_hook_with_env(command, workspace, issue_context, hook_name, worker_host, env)
    end
  end

  defp run_hook_with_env(command, workspace, issue_context, hook_name, nil, env) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command],
          cd: workspace,
          stderr_to_stdout: true,
          env: env
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook_with_env(command, workspace, issue_context, hook_name, worker_host, env)
       when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      [
        hook_env_exports(env),
        "cd #{shell_escape(workspace)}",
        command
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    failure_reason = {:workspace_hook_failed, hook_name, status, output}
    sanitized_output = hook_failure_output_for_log(failure_reason, output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, failure_reason}
  end

  defp hook_failure_output_for_log(failure_reason, output) do
    case AgentRuntime.provider_auth_failure?(failure_reason) do
      true -> AgentRuntime.provider_auth_failure_summary(failure_reason)
      false -> sanitize_hook_output_for_log(output)
    end
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    sanitized_output =
      case byte_size(binary_output) <= max_bytes do
        true ->
          binary_output

        false ->
          binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
      end

    redact_runtime_text(sanitized_output)
  end

  defp redact_runtime_text(value) when is_binary(value) do
    value
    |> String.replace(~r/(?i)\b(authorization)\s*[:=]\s*bearer\s+[^\s,\]}]+/, "\\1=[REDACTED]")
    |> String.replace(~r/(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,\]}]+/, "credential=[REDACTED]")
    |> String.replace(~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/-]+=*/, "[REDACTED]")
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    title = issue_value(issue, :title)

    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_title: title,
      issue_state: issue_value(issue, :state),
      issue_branch_name: issue_branch_name(issue),
      issue_url: issue_value(issue, :url),
      repository: issue_value(issue, :repository),
      repository_source: issue_value(issue, :repository_source),
      expected_branch: expected_branch_name(identifier, title)
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_title: nil,
      issue_state: nil,
      issue_branch_name: nil,
      issue_url: nil,
      repository: nil,
      repository_source: nil,
      expected_branch: expected_branch_name(identifier, nil)
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_title: nil,
      issue_state: nil,
      issue_branch_name: nil,
      issue_url: nil,
      repository: nil,
      repository_source: nil,
      expected_branch: expected_branch_name("issue", nil)
    }
  end

  defp hook_env(issue_context, extra_env \\ []) do
    optional_env = [
      {"SYMPHONY_ISSUE_ID", issue_context.issue_id},
      {"SYMPHONY_ISSUE_IDENTIFIER", issue_context.issue_identifier},
      {"SYMPHONY_ISSUE_TITLE", Map.get(issue_context, :issue_title)},
      {"SYMPHONY_ISSUE_STATE", Map.get(issue_context, :issue_state)},
      {"SYMPHONY_ISSUE_BRANCH_NAME", Map.get(issue_context, :issue_branch_name)},
      {"SYMPHONY_ISSUE_URL", Map.get(issue_context, :issue_url)},
      {"SYMPHONY_ISSUE_REPOSITORY_SOURCE", Map.get(issue_context, :repository_source)}
    ]

    with {:ok, required_env} <- required_bootstrap_env(issue_context) do
      {:ok,
       optional_env
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)
       |> Kernel.++(required_env)
       |> Enum.map(fn {key, value} -> {key, env_value(value)} end)
       |> Map.new()
       |> Map.merge(Map.new(extra_env))
       |> Map.to_list()}
    end
  end

  # A required bootstrap input is never dropped: it is projected with its
  # value, or the projection fails naming the variable that could not be
  # supplied and the issue it was projected for.
  defp required_bootstrap_env(issue_context) do
    Enum.reduce_while(@required_bootstrap_env, {:ok, []}, fn {key, field}, {:ok, acc} ->
      case Map.get(issue_context, field) do
        value when is_binary(value) and value != "" ->
          {:cont, {:ok, [{key, value} | acc]}}

        _value ->
          {:halt,
           {:error,
            {:missing_required_bootstrap_input,
             %{
               name: key,
               field: field,
               issue_id: issue_context.issue_id,
               issue_identifier: issue_context.issue_identifier
             }}}}
      end
    end)
  end

  # Workspace removal is not a role turn: it carries no issue bootstrap and
  # projects none. Only the identifier the workspace path already encodes is
  # exported, exactly as before.
  defp workspace_removal_env(%{issue_identifier: issue_identifier}) when is_binary(issue_identifier) do
    [{"SYMPHONY_ISSUE_IDENTIFIER", issue_identifier}]
  end

  defp hook_env_exports(env) do
    Enum.map_join(env, "\n", fn {key, value} -> "export #{key}=#{shell_escape(value)}" end)
  end

  defp issue_value(issue, key), do: Map.get(issue, key) || Map.get(issue, to_string(key))

  defp issue_branch_name(issue) do
    issue_value(issue, :branch_name) || Map.get(issue, "branchName")
  end

  defp expected_branch_name(identifier, title) do
    issue_slug =
      identifier
      |> to_string()
      |> String.downcase()
      |> slugify()

    title_slug = slugify(title || "")

    case title_slug do
      "" -> "agent/#{issue_slug}"
      slug -> "agent/#{issue_slug}-#{slug}"
    end
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp env_value(value) when is_binary(value), do: value
  defp env_value(value) when is_atom(value), do: Atom.to_string(value)
  defp env_value(value) when is_integer(value) or is_float(value) or is_boolean(value), do: to_string(value)
  defp env_value(value), do: Jason.encode!(value)

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
