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

  @spec ownership_env(Issue.t() | nil, map()) :: [{String.t(), String.t()}]
  def ownership_env(issue, attrs) when is_map(attrs) do
    normalized_attrs = normalize_attrs(attrs)

    [
      {"SYMPHONY_ROLE_RUN_ID", normalized_attrs.run_id},
      {"SYMPHONY_ROLE_ISSUE_ID", issue_id(issue, normalized_attrs)},
      {"SYMPHONY_ROLE_ISSUE_IDENTIFIER", issue_identifier(issue, normalized_attrs)},
      {"SYMPHONY_ROLE_NAME", normalized_attrs.role || current_role()},
      {"SYMPHONY_ROLE_HOLDER", normalized_attrs.holder || ClaimLease.holder_id()},
      {"SYMPHONY_ROLE_WORKSPACE_PATH", normalized_attrs.workspace_path}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @spec blocking_record(Issue.t()) :: map() | nil
  def blocking_record(%Issue{} = issue) do
    issue
    |> candidate_record_paths()
    |> Enum.flat_map(&read_record/1)
    |> Enum.find(&blocking_record?(&1, issue))
  end

  @doc "Return scoped ownership whose native session is not verifiably absent."
  @spec blocking_owned_session_record(
          Issue.t(),
          (map() -> :live | :absent | :unknown | :unreachable)
        ) :: {map(), :live | :unknown | :unreachable} | nil
  def blocking_owned_session_record(%Issue{} = issue, liveness_fun)
      when is_function(liveness_fun, 1) do
    issue
    |> candidate_record_paths()
    |> Enum.flat_map(&read_record/1)
    |> Enum.filter(fn record ->
      record["state"] in ["active", "quarantined"] and
        record_scope_matches?(record, issue)
    end)
    |> Enum.find_value(&blocking_owned_session_evidence(&1, liveness_fun))
  end

  defp blocking_owned_session_evidence(record, liveness_fun) do
    case owned_session_ref_value(record) do
      ownership_ref when is_map(ownership_ref) ->
        blocking_liveness_evidence(record, safe_owned_session_liveness(liveness_fun, ownership_ref))

      nil ->
        nil
    end
  end

  defp blocking_liveness_evidence(record, status) when status in [:live, :unknown, :unreachable],
    do: {record, status}

  defp blocking_liveness_evidence(_record, :absent), do: nil
  defp blocking_liveness_evidence(record, _malformed), do: {record, :unknown}

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

  @doc "Recover stale local run-owned sessions left by a previous role process generation."
  @spec recover_stale_owned_sessions(
          (map() -> :ok | {:error, term()}),
          (map() -> :live | :absent | :unknown | :unreachable)
        ) :: {:ok, non_neg_integer()}
  def recover_stale_owned_sessions(cleanup_fun, liveness_fun)
      when is_function(cleanup_fun, 1) and is_function(liveness_fun, 1) do
    recovered =
      Config.settings!().workspace.root
      |> owned_record_paths()
      |> Enum.reduce(0, fn path, count ->
        case read_record(path) do
          [record] ->
            recover_stale_owned_session(path, record, cleanup_fun, liveness_fun, count)

          _ ->
            count
        end
      end)

    {:ok, recovered}
  end

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
        "owned_session_ref" => normalized_attrs.owned_session_ref,
        "ownership_env" => Map.new(ownership_env(issue, normalized_attrs)),
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

  defp owned_record_paths(workspace_root) when is_binary(workspace_root) do
    Path.wildcard(
      Path.join([workspace_root, "**", ".symphony", "process-ownership", "*.json"]),
      match_dot: true
    )
  end

  defp recover_stale_owned_session(path, record, cleanup_fun, liveness_fun, count) do
    if stale_owned_session_record?(record) do
      ownership_ref = owned_session_ref_value(record)
      cleanup_result = safe_cleanup(cleanup_fun, ownership_ref)
      liveness = safe_owned_session_liveness(liveness_fun, ownership_ref)

      case {cleanup_result, liveness} do
        {:ok, :absent} ->
          mark_record_cleaned(path, record)
          count + 1

        {result, status} ->
          reason =
            "startup cleanup=#{inspect(result)}; native session liveness=#{status}"

          mark_record_quarantined(path, record, reason)

          Logger.warning("Failed to verify stale run-owned session cleanup #{ownership_ref.session_name}: #{reason}")

          count
      end
    else
      count
    end
  rescue
    error ->
      Logger.warning("Failed to recover stale run-owned session record #{path}: #{Exception.message(error)}")
      count
  end

  defp stale_owned_session_record?(record) when is_map(record) do
    record["state"] in ["active", "quarantined"] and
      record["role"] == current_role() and
      blank_string?(record["worker_host"]) and
      record["worker_host_id"] == current_host() and
      is_map(owned_session_ref_value(record)) and
      not holder_process_live?(record["holder"])
  end

  defp stale_owned_session_record?(_record), do: false

  defp holder_process_live?(holder) when is_binary(holder) do
    case holder |> String.split(":") |> Enum.reverse() do
      [_role, pid | _host_parts] -> pid_live?(pid)
      _ -> false
    end
  end

  defp holder_process_live?(_holder), do: false

  defp blank_string?(value), do: !is_binary(value) or String.trim(value) == ""

  defp safe_owned_session_liveness(liveness_fun, ownership_ref) do
    liveness_fun.(ownership_ref)
  rescue
    _error -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp safe_cleanup(cleanup_fun, ownership_ref) do
    cleanup_fun.(ownership_ref)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp mark_record_cleaned(path, record) do
    updated =
      record
      |> Map.put("state", "cleaned")
      |> Map.put("cleanup_status", "cleaned")
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

    with {:ok, body} <- Jason.encode(updated) do
      File.write!(path, body <> "\n")
    end
  end

  defp mark_record_quarantined(path, record, reason) do
    updated =
      record
      |> Map.put("state", "quarantined")
      |> Map.put("cleanup_status", "quarantined")
      |> Map.put("quarantine_reason", reason)
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

    with {:ok, body} <- Jason.encode(updated) do
      File.write!(path, body <> "\n")
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    %{
      role: attr_string(attrs, :role),
      run_id: attr_string(attrs, :run_id),
      holder: attr_string(attrs, :holder),
      issue_id: attr_string(attrs, :issue_id),
      issue_identifier: attr_string(attrs, :issue_identifier),
      worker_host: attr_string(attrs, :worker_host),
      workspace_path: attr_string(attrs, :workspace_path),
      session_id: attr_string(attrs, :session_id),
      quarantine_reason: attr_string(attrs, :quarantine_reason),
      worker_pid: attr_pid(attrs, :worker_pid),
      app_server_pid: attr_pid(attrs, :app_server_pid),
      app_server_pgid: attr_pid(attrs, :app_server_pgid),
      process_tree_pids: attr_pid_list(attrs, :process_tree_pids),
      owned_session_ref: owned_session_ref_value(attrs)
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

  defp blocking_record?(%{"state" => "active"} = record, %Issue{} = issue) do
    record_scope_matches?(record, issue) and active_record_blocks?(record)
  end

  defp blocking_record?(%{"state" => "quarantined"} = record, %Issue{} = issue) do
    record_scope_matches?(record, issue) and quarantined_record_blocks?(record)
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

    process_pids == [] or Enum.any?(process_pids, &pid_live?/1) or
      process_group_live?(record["app_server_pgid"]) or ownership_env_process_live?(record)
  end

  defp quarantined_record_blocks?(%{"worker_host" => worker_host})
       when is_binary(worker_host) and worker_host != "",
       do: true

  defp quarantined_record_blocks?(record), do: local_process_live?(record)

  defp local_process_live?(record) do
    Enum.any?(record_process_pids(record), &pid_live?/1) or
      process_group_live?(record["app_server_pgid"]) or ownership_env_process_live?(record)
  end

  @spec owned_process_live?(map()) :: boolean()
  def owned_process_live?(attrs) when is_map(attrs) do
    normalized_attrs = normalize_attrs(attrs)
    app_server_pgid = normalized_attrs.app_server_pgid || process_group_id(normalized_attrs.app_server_pid)
    process_tree_pids = process_tree_pids(normalized_attrs.app_server_pid, normalized_attrs.process_tree_pids)

    Enum.any?([normalized_attrs.app_server_pid, normalized_attrs.worker_pid | process_tree_pids], &pid_live?/1) or
      process_group_live?(app_server_pgid) or ownership_env_process_live?(normalized_attrs)
  end

  @spec owned_process_live?(Issue.t(), map()) :: boolean()
  def owned_process_live?(%Issue{} = issue, attrs) when is_map(attrs) do
    attrs
    |> Map.put_new(:issue_id, issue.id)
    |> Map.put_new(:issue_identifier, issue.identifier)
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
      role: record["role"],
      holder: record["holder"],
      issue_id: record["issue_id"],
      issue_identifier: record["issue_identifier"],
      worker_host: record["worker_host"],
      workspace_path: record["workspace_path"],
      app_server_pid: record["app_server_pid"],
      app_server_pgid: record["app_server_pgid"],
      process_tree_pids: record["process_tree_pids"] || [],
      ownership_env_pids: ownership_env_pids(record),
      worker_pid: record["worker_pid"],
      run_id: record["run_id"],
      session_id: record["session_id"],
      owned_session_ref: owned_session_ref_value(record),
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

  defp owned_session_ref_value(attrs) when is_map(attrs) do
    ref = value_for(attrs, :owned_session_ref)

    if is_map(ref) do
      kind = string_value(value_for(ref, :kind))
      session_name = string_value(value_for(ref, :session_name))
      agent_name = string_value(value_for(ref, :agent_name))
      runtime_root = string_value(value_for(ref, :runtime_root))

      if kind == "herdr" and valid_owned_herdr_session_name?(session_name) do
        %{kind: kind, session_name: session_name}
        |> maybe_put_owned_agent_name(agent_name)
        |> maybe_put_owned_runtime_root(runtime_root, value_for(ref, :cleanup_context))
      end
    end
  end

  defp owned_session_ref_value(_attrs), do: nil

  defp valid_owned_herdr_session_name?(session_name) when is_binary(session_name) do
    byte_size(session_name) <= 44 and Regex.match?(~r/^octo-[a-z0-9][a-z0-9-]*$/, session_name)
  end

  defp valid_owned_herdr_session_name?(_session_name), do: false

  defp maybe_put_owned_agent_name(ref, agent_name)
       when agent_name in ["implementer_orchestrator"],
       do: Map.put(ref, :agent_name, agent_name)

  defp maybe_put_owned_agent_name(ref, _agent_name), do: ref

  defp maybe_put_owned_runtime_root(ref, runtime_root, cleanup_context)
       when is_binary(runtime_root) and is_map(cleanup_context) do
    expanded_root = Path.expand(runtime_root)
    expanded_tmp = Path.expand(System.tmp_dir!())

    if String.starts_with?(expanded_root, expanded_tmp <> "/octo-herdr-") and
         value_for(cleanup_context, :socket_root) == runtime_root do
      safe_context =
        %{socket_root: runtime_root}
        |> maybe_put_owned_timeout(:stop_timeout_ms, value_for(cleanup_context, :stop_timeout_ms))
        |> maybe_put_owned_timeout(
          :liveness_timeout_ms,
          value_for(cleanup_context, :liveness_timeout_ms)
        )

      ref
      |> Map.put(:runtime_root, runtime_root)
      |> Map.put(:cleanup_context, safe_context)
    else
      ref
    end
  end

  defp maybe_put_owned_runtime_root(ref, _runtime_root, _cleanup_context), do: ref

  defp maybe_put_owned_timeout(context, key, value)
       when is_integer(value) and value > 0 and value <= 60_000,
       do: Map.put(context, key, value)

  defp maybe_put_owned_timeout(context, _key, _value), do: context

  defp merge_existing_process_tree(attrs, nil), do: attrs

  defp merge_existing_process_tree(attrs, existing) when is_map(attrs) and is_map(existing) do
    attrs
    |> put_existing_value(:app_server_pgid, existing[:app_server_pgid])
    |> put_existing_value(:process_tree_pids, existing[:process_tree_pids])
    |> put_existing_value(:role, existing[:role])
    |> put_existing_value(:holder, existing[:holder])
    |> put_existing_value(:issue_id, existing[:issue_id])
    |> put_existing_value(:issue_identifier, existing[:issue_identifier])
    |> put_existing_value(:run_id, existing[:run_id])
    |> put_existing_value(:workspace_path, existing[:workspace_path])
    |> put_existing_value(:owned_session_ref, existing[:owned_session_ref])
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

  defp ownership_env_process_live?(attrs_or_record), do: ownership_env_pids(attrs_or_record) != []

  defp ownership_env_pids(attrs_or_record) when is_map(attrs_or_record) do
    criteria = ownership_env_criteria(attrs_or_record)

    if ownership_env_criteria_scoped?(criteria) do
      process_table()
      |> Enum.map(fn {pid, _ppid, _pgid} -> pid end)
      |> Enum.filter(&process_env_matches?(&1, criteria))
    else
      []
    end
  end

  defp ownership_env_criteria(attrs_or_record) when is_map(attrs_or_record) do
    attrs =
      case attrs_or_record do
        %{"version" => 1} = record ->
          %{
            run_id: record["run_id"],
            issue_id: record["issue_id"],
            issue_identifier: record["issue_identifier"],
            role: record["role"],
            holder: record["holder"],
            workspace_path: record["workspace_path"]
          }

        attrs ->
          normalize_attrs(attrs)
      end

    [
      {"SYMPHONY_ROLE_RUN_ID", string_value(attrs[:run_id])},
      {"SYMPHONY_ROLE_ISSUE_ID", string_value(attrs[:issue_id])},
      {"SYMPHONY_ROLE_ISSUE_IDENTIFIER", string_value(attrs[:issue_identifier])},
      {"SYMPHONY_ROLE_NAME", string_value(attrs[:role])},
      {"SYMPHONY_ROLE_HOLDER", string_value(attrs[:holder])},
      {"SYMPHONY_ROLE_WORKSPACE_PATH", string_value(attrs[:workspace_path])}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp ownership_env_criteria_scoped?(criteria) when is_list(criteria) do
    criteria_has_key?(criteria, "SYMPHONY_ROLE_RUN_ID") and
      criteria_has_key?(criteria, "SYMPHONY_ROLE_ISSUE_ID") and
      criteria_has_key?(criteria, "SYMPHONY_ROLE_NAME")
  end

  defp criteria_has_key?(criteria, key), do: Enum.any?(criteria, fn {candidate, _value} -> candidate == key end)

  defp process_env_matches?(pid, criteria) when is_integer(pid) do
    case process_env(pid) do
      {:ok, env} ->
        Enum.all?(criteria, fn
          {"SYMPHONY_ROLE_WORKSPACE_PATH", workspace_path} ->
            workspace_paths_match?(Map.get(env, "SYMPHONY_ROLE_WORKSPACE_PATH"), workspace_path)

          {key, value} ->
            Map.get(env, key) == value
        end)

      :error ->
        false
    end
  end

  # Late-detached descendant detection reads /proc, which only exists on the
  # Linux role hosts that run production dispatch. On other supported dev
  # platforms the read fails and detection degrades gracefully to the
  # pid/pgid liveness checks above.
  defp process_env(pid) when is_integer(pid) and pid > 0 do
    path = Path.join(["/proc", Integer.to_string(pid), "environ"])

    case File.read(path) do
      {:ok, body} ->
        env =
          body
          |> String.split(<<0>>, trim: true)
          |> Enum.flat_map(&parse_env_entry/1)
          |> Map.new()

        {:ok, env}

      _ ->
        :error
    end
  end

  defp parse_env_entry(entry) when is_binary(entry) do
    case String.split(entry, "=", parts: 2) do
      [key, value] when key != "" -> [{key, value}]
      _ -> []
    end
  end

  defp issue_id(%Issue{id: id}, _attrs) when is_binary(id), do: id
  defp issue_id(_issue, attrs), do: attrs.issue_id

  defp issue_identifier(%Issue{identifier: identifier}, _attrs) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue, attrs), do: attrs.issue_identifier

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
