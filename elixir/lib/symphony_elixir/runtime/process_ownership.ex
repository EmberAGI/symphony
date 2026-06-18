defmodule SymphonyElixir.Runtime.ProcessOwnership do
  @moduledoc """
  Local runtime process ownership registry for top-level role runs.

  The registry is intentionally scoped to Symphony-owned role metadata. It never
  scans or kills by command/package name.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}
  alias SymphonyElixir.Tracker.ClaimLease

  @registry_dir ".symphony/process-ownership"

  @spec registry_path(Issue.t(), String.t() | nil) :: Path.t()
  def registry_path(%Issue{} = issue, workspace_path \\ nil) do
    base = workspace_path || Config.settings!().workspace.root
    Path.join([base, @registry_dir, safe_name(issue.id || issue.identifier || "issue") <> ".json"])
  end

  @spec record_active(Issue.t(), map()) :: :ok | {:error, term()}
  def record_active(%Issue{} = issue, attrs) when is_map(attrs) do
    write_record(issue, attrs, "active")
  end

  @spec record_cleaned(Issue.t(), map()) :: :ok | {:error, term()}
  def record_cleaned(%Issue{} = issue, attrs) when is_map(attrs) do
    write_record(issue, attrs, "cleaned")
  end

  @spec record_quarantined(Issue.t(), map(), String.t()) :: :ok | {:error, term()}
  def record_quarantined(%Issue{} = issue, attrs, reason) when is_map(attrs) and is_binary(reason) do
    write_record(issue, Map.put(attrs, :quarantine_reason, reason), "quarantined")
  end

  @spec blocking_record(Issue.t()) :: map() | nil
  def blocking_record(%Issue{} = issue) do
    issue
    |> candidate_paths()
    |> Enum.flat_map(&read_record/1)
    |> Enum.find(&blocking_record?/1)
  end

  @spec status_for_issue(Issue.t()) :: map() | nil
  def status_for_issue(%Issue{} = issue) do
    issue
    |> candidate_paths()
    |> Enum.flat_map(&read_record/1)
    |> Enum.max_by(&record_sort_key/1, fn -> nil end)
    |> normalize_status()
  end

  @spec current_host() :: String.t()
  def current_host do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

  @spec current_role() :: String.t()
  def current_role, do: ClaimLease.role_name()

  defp write_record(%Issue{} = issue, attrs, state) do
    normalized_attrs = normalize_attrs(attrs)
    workspace_path = normalized_attrs.workspace_path
    path = registry_path(issue, workspace_path)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      %{
        "version" => 1,
        "issue_id" => issue.id,
        "issue_identifier" => issue.identifier,
        "role" => normalized_attrs.role || current_role(),
        "run_id" => normalized_attrs.run_id,
        "holder" => normalized_attrs.holder || ClaimLease.holder_id(),
        "worker_host" => normalized_attrs.worker_host,
        "worker_host_id" => current_host(),
        "workspace_path" => workspace_path,
        "session_id" => normalized_attrs.session_id,
        "worker_pid" => normalized_attrs.worker_pid,
        "app_server_pid" => normalized_attrs.app_server_pid,
        "state" => state,
        "cleanup_status" => state,
        "quarantine_reason" => normalized_attrs.quarantine_reason,
        "updated_at" => now
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, body} <- Jason.encode(record) do
      File.write(path, body <> "\n")
    end
  rescue
    error ->
      Logger.warning("Failed to write process ownership record for issue_id=#{issue.id}: #{Exception.message(error)}")
      {:error, error}
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    %{
      role: attr_string(attrs, :role),
      run_id: attr_string(attrs, :run_id),
      holder: attr_string(attrs, :holder),
      worker_host: attr_string(attrs, :worker_host),
      workspace_path: attr_string(attrs, :workspace_path),
      session_id: attr_string(attrs, :session_id),
      quarantine_reason: attr_string(attrs, :quarantine_reason),
      worker_pid: attr_pid(attrs, :worker_pid),
      app_server_pid: attr_pid(attrs, :app_server_pid)
    }
  end

  defp attr_string(attrs, key) when is_atom(key) do
    string_value(attrs[key]) || string_value(attrs[Atom.to_string(key)])
  end

  defp attr_pid(attrs, key) when is_atom(key) do
    pid_value(attrs[key]) || pid_value(attrs[Atom.to_string(key)])
  end

  defp candidate_paths(%Issue{} = issue) do
    workspace_root_path = registry_path(issue, nil)
    workspace = expected_workspace_path(issue)

    [workspace_root_path, registry_path(issue, workspace)]
    |> Enum.uniq()
  end

  defp expected_workspace_path(%Issue{} = issue) do
    suffix =
      case issue.repository do
        repository when is_binary(repository) ->
          repository
          |> String.split("/", parts: 2)
          |> List.last()
          |> safe_name()

        _ ->
          nil
      end

    issue_id = safe_name(issue.identifier || issue.id || "issue")
    basename = if suffix in [nil, ""], do: issue_id, else: "#{issue_id}-#{suffix}"
    Path.join(Config.settings!().workspace.root, basename)
  end

  defp read_record(path) when is_binary(path) do
    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, record} <- Jason.decode(body),
         true <- record["version"] == 1 do
      [record]
    else
      _ -> []
    end
  end

  defp blocking_record?(%{"state" => state} = record) when state in ["active", "quarantined"] do
    state == "quarantined" or active_record_blocks?(record)
  end

  defp blocking_record?(_record), do: false

  defp active_record_blocks?(%{"worker_host" => worker_host}) when is_binary(worker_host) and worker_host != "",
    do: true

  defp active_record_blocks?(record) do
    process_pids =
      record
      |> Map.take(["app_server_pid", "worker_pid"])
      |> Map.values()

    process_pids == [] or Enum.any?(process_pids, &pid_live?/1)
  end

  defp local_process_live?(record) do
    record
    |> Map.take(["app_server_pid", "worker_pid"])
    |> Map.values()
    |> Enum.any?(&pid_live?/1)
  end

  defp pid_live?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp pid_live?(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {integer, ""} -> pid_live?(integer)
      _ -> false
    end
  end

  defp pid_live?(_pid), do: false

  defp normalize_status(nil), do: nil

  defp normalize_status(record) do
    %{
      state: record["state"],
      cleanup_status: record["cleanup_status"],
      worker_host: record["worker_host"],
      workspace_path: record["workspace_path"],
      app_server_pid: record["app_server_pid"],
      worker_pid: record["worker_pid"],
      run_id: record["run_id"],
      session_id: record["session_id"],
      updated_at: record["updated_at"],
      quarantine_reason: record["quarantine_reason"],
      live?: local_process_live?(record)
    }
  end

  defp record_sort_key(%{"updated_at" => updated_at}) when is_binary(updated_at), do: updated_at
  defp record_sort_key(_record), do: ""

  defp safe_name(value) when is_binary(value), do: String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")
  defp safe_name(_value), do: nil

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(_value), do: nil

  defp pid_value(value) when is_integer(value) and value > 0, do: value

  defp pid_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp pid_value(_value), do: nil
end
