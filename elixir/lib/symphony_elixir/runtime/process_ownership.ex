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
    |> candidate_record_paths()
    |> Enum.flat_map(&read_record/1)
    |> Enum.find(&blocking_record?(&1, issue))
  end

  @spec status_for_issue(Issue.t()) :: map() | nil
  def status_for_issue(%Issue{} = issue) do
    records =
      issue
      |> candidate_record_paths()
      |> Enum.flat_map(&read_record/1)

    scoped_records = Enum.filter(records, &record_scope_matches?(&1, issue))

    case scoped_records do
      [] -> records
      records -> records
    end
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
    path = scoped_registry_path(issue, normalized_attrs)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    app_server_pgid = normalized_attrs.app_server_pgid || process_group_id(normalized_attrs.app_server_pid)
    process_tree_pids = process_tree_pids(normalized_attrs.app_server_pid, normalized_attrs.process_tree_pids)

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
        "app_server_pgid" => app_server_pgid,
        "process_tree_pids" => process_tree_pids,
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
      app_server_pid: attr_pid(attrs, :app_server_pid),
      app_server_pgid: attr_pid(attrs, :app_server_pgid),
      process_tree_pids: attr_pid_list(attrs, :process_tree_pids)
    }
  end

  defp attr_string(attrs, key) when is_atom(key) do
    string_value(attrs[key]) || string_value(attrs[Atom.to_string(key)])
  end

  defp attr_pid(attrs, key) when is_atom(key) do
    pid_value(attrs[key]) || pid_value(attrs[Atom.to_string(key)])
  end

  defp attr_pid_list(attrs, key) when is_atom(key) do
    attrs
    |> value_for(key)
    |> pid_list_value()
  end

  defp value_for(attrs, key) when is_atom(key), do: attrs[key] || attrs[Atom.to_string(key)]

  defp scoped_registry_path(%Issue{} = issue, normalized_attrs) when is_map(normalized_attrs) do
    base = normalized_attrs.workspace_path || Config.settings!().workspace.root
    Path.join([base, @registry_dir, scoped_registry_filename(issue, normalized_attrs)])
  end

  defp scoped_registry_filename(%Issue{} = issue, attrs) do
    issue_scope = safe_name(issue.id || issue.identifier || "issue")
    role_scope = safe_name(attrs.role || current_role() || "role")
    workspace_scope = safe_name(workspace_scope_name(attrs.workspace_path))
    run_scope = safe_name(attrs.run_id || attrs.holder || "run")

    [issue_scope, role_scope, workspace_scope, run_scope]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("--")
    |> Kernel.<>(".json")
  end

  defp workspace_scope_name(nil), do: "default"
  defp workspace_scope_name(path) when is_binary(path), do: Path.basename(path)

  defp candidate_record_paths(%Issue{} = issue) do
    workspace_root_path = registry_path(issue, nil)
    workspace = expected_workspace_path(issue)
    issue_scope = safe_name(issue.id || issue.identifier || "issue")

    [Path.dirname(workspace_root_path), Path.dirname(registry_path(issue, workspace))]
    |> Enum.uniq()
    |> Enum.flat_map(fn dir ->
      legacy_path = Path.join(dir, issue_scope <> ".json")
      scoped_paths = Path.wildcard(Path.join(dir, issue_scope <> "--*.json"))
      [legacy_path | scoped_paths]
    end)
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

  defp blocking_record?(%{"state" => state} = record, %Issue{} = issue) when state in ["active", "quarantined"] do
    record_scope_matches?(record, issue) and active_record_blocks?(record)
  end

  defp blocking_record?(_record, _issue), do: false

  defp record_scope_matches?(record, %Issue{} = issue) do
    record_role_matches?(record) and record_workspace_matches?(record, issue)
  end

  defp record_role_matches?(record) do
    case string_value(record["role"]) do
      nil -> true
      role -> role == current_role()
    end
  end

  defp record_workspace_matches?(record, %Issue{} = issue) do
    case string_value(record["workspace_path"]) do
      nil ->
        true

      workspace_path ->
        workspace_paths_match?(workspace_path, expected_workspace_path(issue))
    end
  end

  defp workspace_paths_match?(workspace_path, expected_workspace_path)
       when is_binary(workspace_path) and is_binary(expected_workspace_path) do
    normalize_workspace_path(workspace_path) == normalize_workspace_path(expected_workspace_path)
  end

  defp workspace_paths_match?(_workspace_path, _expected_workspace_path), do: false

  defp active_record_blocks?(%{"worker_host" => worker_host}) when is_binary(worker_host) and worker_host != "",
    do: true

  defp active_record_blocks?(record) do
    process_pids = record_process_pids(record)

    process_pids == [] or Enum.any?(process_pids, &pid_live?/1) or process_group_live?(record["app_server_pgid"])
  end

  defp local_process_live?(record) do
    Enum.any?(record_process_pids(record), &pid_live?/1) or process_group_live?(record["app_server_pgid"])
  end

  @spec owned_process_live?(map()) :: boolean()
  def owned_process_live?(attrs) when is_map(attrs) do
    normalized_attrs = normalize_attrs(attrs)
    app_server_pgid = normalized_attrs.app_server_pgid || process_group_id(normalized_attrs.app_server_pid)
    process_tree_pids = process_tree_pids(normalized_attrs.app_server_pid, normalized_attrs.process_tree_pids)

    Enum.any?([normalized_attrs.app_server_pid, normalized_attrs.worker_pid | process_tree_pids], &pid_live?/1) or
      process_group_live?(app_server_pgid)
  end

  @spec owned_process_live?(Issue.t(), map()) :: boolean()
  def owned_process_live?(%Issue{} = issue, attrs) when is_map(attrs) do
    attrs
    |> merge_existing_process_tree(status_for_issue(issue))
    |> owned_process_live?()
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
      app_server_pgid: record["app_server_pgid"],
      process_tree_pids: record["process_tree_pids"] || [],
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

  defp normalize_workspace_path(path) when is_binary(path), do: path |> Path.expand() |> Path.absname()

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

  defp merge_existing_process_tree(attrs, nil), do: attrs

  defp merge_existing_process_tree(attrs, existing) when is_map(attrs) and is_map(existing) do
    attrs
    |> put_existing_value(:app_server_pgid, existing[:app_server_pgid])
    |> put_existing_value(:process_tree_pids, existing[:process_tree_pids])
  end

  defp put_existing_value(attrs, _key, nil), do: attrs
  defp put_existing_value(attrs, _key, []), do: attrs

  defp put_existing_value(attrs, key, value) when is_atom(key) do
    if value_for(attrs, key) in [nil, []] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp pid_list_value(values) when is_list(values) do
    values
    |> Enum.map(&pid_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp pid_list_value(value) do
    case pid_value(value) do
      nil -> []
      pid -> [pid]
    end
  end

  defp process_tree_pids(nil, existing_pids), do: existing_pids

  defp process_tree_pids(app_server_pid, existing_pids) do
    ([app_server_pid] ++ existing_pids ++ descendant_pids(app_server_pid))
    |> Enum.map(&pid_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp record_process_pids(record) when is_map(record) do
    (Map.get(record, "process_tree_pids", []) ++ [record["app_server_pid"], record["worker_pid"]])
    |> Enum.map(&pid_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp descendant_pids(pid) do
    pid
    |> pid_value()
    |> case do
      nil -> []
      integer -> descendants_from_process_table(integer)
    end
  end

  defp descendants_from_process_table(root_pid) when is_integer(root_pid) do
    process_table()
    |> descendants_from_process_table(root_pid)
  end

  defp descendants_from_process_table(processes, root_pid) when is_list(processes) and is_integer(root_pid) do
    children_by_parent =
      Enum.group_by(processes, fn {_pid, ppid, _pgid} -> ppid end, fn {pid, _ppid, _pgid} -> pid end)

    [root_pid]
    |> collect_descendants(children_by_parent, %{})
    |> Map.delete(root_pid)
    |> Map.keys()
  end

  defp collect_descendants([], _children_by_parent, seen), do: seen

  defp collect_descendants([pid | rest], children_by_parent, seen) do
    children = Map.get(children_by_parent, pid, [])
    unseen_children = Enum.reject(children, &Map.has_key?(seen, &1))
    collect_descendants(rest ++ unseen_children, children_by_parent, Map.put(seen, pid, true))
  end

  defp process_group_id(pid) do
    pid
    |> pid_value()
    |> case do
      nil ->
        nil

      integer ->
        Enum.find_value(process_table(), fn
          {^integer, _ppid, pgid} -> pgid
          _process -> nil
        end)
    end
  end

  defp process_group_live?(pgid) do
    case pid_value(pgid) do
      nil -> false
      integer -> Enum.any?(process_table(), fn {_pid, _ppid, process_pgid} -> process_pgid == integer end)
    end
  end

  defp process_table do
    case System.cmd("ps", ["-eo", "pid=,ppid=,pgid="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_process_table_line/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp parse_process_table_line(line) when is_binary(line) do
    case line |> String.split(~r/\s+/, trim: true) |> Enum.map(&Integer.parse/1) do
      [{pid, ""}, {ppid, ""}, {pgid, ""}] -> [{pid, ppid, pgid}]
      _ -> []
    end
  end
end
