defmodule SymphonyElixir.Runtime.ProcessOwnership do
  @moduledoc """
  Local runtime process ownership registry for top-level role runs.

  The registry is intentionally scoped to Symphony-owned role metadata. It never
  scans or kills by command/package name.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @registry_dir ".symphony/process-ownership"
  @lock_owner_file "owner.json"
  @malformed_lock_stale_after_ms 60_000
  @owned_process_exit_attempts 25
  @owned_process_exit_interval_ms 10
  @valid_states ~w(active retrying blocked quarantined cleaned released)
  @required_record_strings ~w(issue_id role run_id holder worker_host_id workspace_path updated_at)

  @spec registry_path(Issue.t(), String.t() | nil) :: Path.t()
  def registry_path(%Issue{} = issue, workspace_path \\ nil) do
    base = local_registry_root()
    attrs = scope_attrs(issue, normalize_attrs(%{role: current_role(), workspace_path: workspace_path}))
    Path.join([base, @registry_dir, scoped_registry_filename(issue, attrs)])
  end

  @doc """
  Atomically acquires the local issue/workspace/role ownership scope.

  Acquisition is idempotent for the same holder/run. A stale local holder may
  be replaced only while holding the scope lock and after the exact observed
  record has been archived. Malformed records and remote workers fail closed.
  """
  @spec acquire(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def acquire(%Issue{} = issue, attrs) when is_map(attrs) do
    normalized_attrs = scope_attrs(issue, normalize_attrs(attrs))

    with :ok <- validate_local_attrs(normalized_attrs),
         path <- scoped_registry_path(issue, normalized_attrs),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      with_scope_lock(path, fn -> acquire_locked(path, issue, normalized_attrs) end)
      |> case do
        {:error, :ownership_lock_held} -> {:error, :ownership_held}
        result -> result
      end
    end
  rescue
    error ->
      Logger.warning("Failed to acquire process ownership for issue_id=#{issue.id}: #{Exception.message(error)}")
      {:error, error}
  end

  @doc """
  Updates ownership only when the current holder and run match `expected`.
  """
  @spec verify_and_update(Issue.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def verify_and_update(%Issue{} = issue, expected, attrs)
      when is_map(expected) and is_map(attrs) do
    expected = scope_attrs(issue, normalize_attrs(expected))
    update_attrs = normalize_attrs(attrs)
    workspace_path = expected.workspace_path || update_attrs.workspace_path
    path = scoped_registry_path(issue, %{expected | workspace_path: workspace_path})

    case validate_identity(expected) do
      :ok -> with_scope_lock(path, fn -> update_locked(path, issue, expected, attrs) end)
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      Logger.warning("Failed to update process ownership for issue_id=#{issue.id}: #{Exception.message(error)}")
      {:error, error}
  end

  @doc """
  Reads the exact ownership scope and verifies its immutable identity without
  taking the mutation lock.
  """
  @spec verify(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify(%Issue{} = issue, expected) when is_map(expected) do
    expected = scope_attrs(issue, normalize_attrs(expected))
    path = scoped_registry_path(issue, expected)

    with :ok <- validate_identity(expected),
         {:ok, record} <- read_exact_record(path),
         :ok <- verify_owner(record, expected),
         :ok <- validate_identity_updates(record, expected) do
      {:ok, normalize_status(record)}
    end
  rescue
    error ->
      Logger.warning("Failed to verify process ownership for issue_id=#{issue.id}: #{Exception.message(error)}")

      {:error, error}
  end

  @doc """
  Terminates only local OS processes that still carry the exact verified
  issue/role/run ownership environment.

  Every PID is rechecked immediately before signaling. TERM receives a bounded
  grace period; exact-marker survivors receive KILL and a second bounded wait.
  A process-table read that fails is never read as "nothing is live": the
  termination then fails typed as `:settlement_evidence_unavailable`.
  """
  @spec terminate_owned_processes(Issue.t(), map()) ::
          {:ok, %{term_pids: [pos_integer()], kill_pids: [pos_integer()], live_after: 0}}
          | {:error, term()}
  def terminate_owned_processes(%Issue{} = issue, expected) when is_map(expected) do
    with {:ok, ownership} <- verify(issue, expected),
         criteria <- ownership_env_criteria(ownership),
         true <- ownership_env_criteria_scoped?(criteria),
         {:ok, term_pids} <- signal_matching_processes(criteria, "TERM"),
         {:ok, _term_survivors} <- await_matching_processes(criteria, term_pids, @owned_process_exit_attempts),
         {:ok, kill_pids} <- signal_matching_processes(criteria, "KILL", term_pids),
         {:ok, []} <- await_matching_processes(criteria, kill_pids, @owned_process_exit_attempts) do
      {:ok, %{term_pids: term_pids, kill_pids: kill_pids, live_after: 0}}
    else
      false -> {:error, :unscoped_ownership_environment}
      {:ok, live_pids} when is_list(live_pids) -> {:error, {:owned_processes_remain, live_pids}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      Logger.warning("Failed to terminate owned processes for issue_id=#{issue.id}: #{Exception.message(error)}")

      {:error, error}
  end

  defp update_locked(path, issue, expected, attrs) do
    with {:ok, record} <- read_exact_record(path),
         :ok <- verify_owner(record, expected),
         :ok <- validate_identity_updates(record, attrs),
         merged_attrs <- merge_record_attrs(record, attrs),
         :ok <- validate_local_attrs(merged_attrs),
         state <- string_value(value_for(attrs, :state)) || record["state"] || "active",
         :ok <- validate_state(state),
         {:ok, updated} <- replace_record(path, issue, merged_attrs, state) do
      {:ok, normalize_status(updated)}
    end
  end

  @doc "Releases ownership only for the matching holder and run."
  @spec release(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  @spec release(Issue.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def release(%Issue{} = issue, expected, extra_attrs \\ %{}) when is_map(expected) and is_map(extra_attrs) do
    verify_and_update(
      issue,
      expected,
      Map.merge(extra_attrs, %{state: "cleaned", cleanup_status: "cleaned"})
    )
  end

  @doc """
  Releases successful ownership, applying an explicit failure-observation
  clear only when the orchestrator verified changed reset evidence.
  """
  @spec release_completed(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  @spec release_completed(Issue.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def release_completed(%Issue{} = issue, expected, extra_attrs \\ %{})
      when is_map(expected) and is_map(extra_attrs) do
    verify_and_update(
      issue,
      expected,
      Map.merge(extra_attrs, %{
        state: "cleaned",
        cleanup_status: "cleaned"
      })
    )
  end

  @doc """
  Captures the owned PID set for one role run BEFORE terminal teardown
  destroys the records that identify it.

  The snapshot is settlement's own evidence source: the exact ownership
  record's recorded process tree plus a single live scan for processes still
  carrying the run's complete ownership environment. Terminal settlement
  verifies liveness against this snapshot after teardown instead of
  re-deriving evidence from state teardown may already have removed.

  Capture is evidence, so it fails typed. A capture whose machinery failed
  (process-table read failure, or an exception anywhere in the capture path)
  returns `{:error, :settlement_evidence_unavailable}` and never an empty
  snapshot a caller could mistake for "the run owned nothing".
  """
  @spec settlement_snapshot(Issue.t() | nil, map() | nil, [pos_integer()]) ::
          {:ok, %{owned_pids: [pos_integer()], criteria: [{String.t(), String.t()}], captured_at: String.t()}}
          | {:error, :settlement_evidence_unavailable}
  def settlement_snapshot(issue, ownership, extra_pids \\ []) do
    ownership = if is_map(ownership), do: ownership, else: %{}
    record_status = settlement_record_status(issue, ownership)

    criteria =
      case ownership_env_criteria(record_status) do
        [] -> ownership_env_criteria(ownership)
        criteria -> criteria
      end

    case scoped_matching_processes(criteria) do
      {:ok, env_pids} ->
        owned_pids =
          (status_process_pids(record_status) ++ status_process_pids(ownership) ++ env_pids ++ extra_pids)
          |> Enum.map(&pid_value/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        {:ok,
         %{
           owned_pids: owned_pids,
           criteria: criteria,
           captured_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:error, reason} ->
        Logger.warning("Failed to capture settlement snapshot: #{inspect(reason)}")
        {:error, :settlement_evidence_unavailable}
    end
  rescue
    error ->
      Logger.warning("Failed to capture settlement snapshot: #{Exception.message(error)}")

      {:error, :settlement_evidence_unavailable}
  end

  @doc """
  Verifies post-teardown liveness against a pre-teardown settlement snapshot.

  One batched process-table read decides snapshot-pid liveness; one bounded
  ownership-environment sweep still catches late-detached descendants. No
  per-PID signalling or probing is performed here.

  Liveness is evidence, so it fails typed: a verification whose machinery
  failed returns `{:error, :settlement_evidence_unavailable}` rather than the
  `live_after: 0` a caller would read as proof that nothing survived.
  """
  @spec settlement_liveness(%{
          required(:owned_pids) => [pos_integer()],
          required(:criteria) => [{String.t(), String.t()}],
          optional(atom()) => term()
        }) ::
          {:ok, %{live_after: non_neg_integer(), live_pids: [pos_integer()]}}
          | {:error, :settlement_evidence_unavailable}
  def settlement_liveness(%{owned_pids: owned_pids, criteria: criteria}) do
    with {:ok, processes} <- checked_process_table(),
         {:ok, env_survivors} <- scoped_matching_processes(criteria) do
      live_table = MapSet.new(processes, fn {pid, _ppid, _pgid} -> pid end)
      live_snapshot_pids = Enum.filter(owned_pids, &MapSet.member?(live_table, &1))
      live_pids = Enum.uniq(live_snapshot_pids ++ env_survivors)

      {:ok, %{live_after: length(live_pids), live_pids: live_pids}}
    else
      {:error, reason} ->
        Logger.warning("Failed to verify settlement liveness: #{inspect(reason)}")
        {:error, :settlement_evidence_unavailable}
    end
  rescue
    error ->
      Logger.warning("Failed to verify settlement liveness: #{Exception.message(error)}")
      {:error, :settlement_evidence_unavailable}
  end

  defp settlement_record_status(%Issue{} = issue, ownership) do
    identity = %{
      role: value_for(ownership, :role),
      run_id: value_for(ownership, :run_id),
      holder: value_for(ownership, :holder),
      workspace_path: value_for(ownership, :workspace_path)
    }

    case verify(issue, identity) do
      {:ok, status} -> status
      {:error, _reason} -> ownership
    end
  end

  defp settlement_record_status(_issue, ownership), do: ownership

  defp status_process_pids(status) when is_map(status) do
    pid_list_value(value_for(status, :process_tree_pids)) ++
      pid_list_value(value_for(status, :app_server_pid)) ++
      pid_list_value(value_for(status, :worker_pid))
  end

  defp status_process_pids(_status), do: []

  @spec ownership_env(Issue.t() | nil, map()) :: [{String.t(), String.t()}]
  def ownership_env(issue, attrs) when is_map(attrs) do
    normalized_attrs = normalize_attrs(attrs)

    [
      {"SYMPHONY_ROLE_RUN_ID", normalized_attrs.run_id},
      {"SYMPHONY_ROLE_ISSUE_ID", issue_id(issue, normalized_attrs)},
      {"SYMPHONY_ROLE_ISSUE_IDENTIFIER", issue_identifier(issue, normalized_attrs)},
      {"SYMPHONY_ROLE_NAME", normalized_attrs.role || current_role()},
      {"SYMPHONY_ROLE_HOLDER", normalized_attrs.holder || holder_id()},
      {"SYMPHONY_ROLE_WORKSPACE_PATH", normalized_attrs.workspace_path}
    ]
    |> Kernel.++(ownership_path_env(issue, normalized_attrs))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp ownership_path_env(%Issue{} = issue, attrs) do
    [{"SYMPHONY_ROLE_OWNERSHIP_PATH", scoped_registry_path(issue, scope_attrs(issue, attrs))}]
  end

  defp ownership_path_env(_issue, _attrs), do: []

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
  def current_role do
    case System.get_env("SYMPHONY_ROLE") do
      role when is_binary(role) and role != "" -> role
      _ -> "implementer"
    end
  end

  @spec holder_id() :: String.t()
  def holder_id do
    Application.get_env(:symphony_elixir, :process_ownership_holder) ||
      System.get_env("SYMPHONY_PROCESS_OWNERSHIP_HOLDER") ||
      "#{current_host()}:#{System.pid()}:#{current_role()}"
  end

  @doc "Recover stale local run-owned sessions left by a previous role process generation."
  @spec recover_stale_owned_sessions((map() -> :ok | {:error, term()})) :: {:ok, non_neg_integer()}
  def recover_stale_owned_sessions(cleanup_fun) when is_function(cleanup_fun, 1) do
    recovered =
      local_registry_root()
      |> owned_record_paths()
      |> Enum.reduce(0, fn path, count ->
        recover_stale_owned_session(path, cleanup_fun, count)
      end)

    {:ok, recovered}
  end

  defp acquire_locked(path, %Issue{} = issue, attrs) do
    case read_exact_record(path) do
      {:error, :enoent} ->
        case create_record_exclusive(path, issue, attrs, "active") do
          {:ok, record} -> {:ok, normalize_status(record)}
          {:error, reason} -> {:error, reason}
        end

      {:ok, record} ->
        cond do
          same_owner?(record, attrs) ->
            refresh_owned_record(path, issue, record, attrs)

          stale_record?(record) ->
            replace_stale_record(path, record, issue, attrs)

          true ->
            {:error, :ownership_held}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_owned_record(path, issue, record, attrs) do
    case replace_record(path, issue, merge_record_attrs(record, attrs), "active") do
      {:ok, updated} -> {:ok, normalize_status(updated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_stale_record(path, record, %Issue{} = issue, attrs) do
    attrs =
      if Map.get(attrs, :failure_observation) do
        attrs
      else
        Map.put(attrs, :failure_observation, failure_observation_value(record))
      end

    with {:ok, observed_body} <- Jason.encode(record),
         digest <- :crypto.hash(:sha256, observed_body) |> Base.encode16(case: :lower),
         archive_path <- path <> ".stale-" <> binary_part(digest, 0, 16),
         :ok <- File.rename(path, archive_path) do
      case create_record_exclusive(path, issue, attrs, "active") do
        {:ok, replacement} ->
          prune_stale_archives(path, archive_path)
          {:ok, normalize_status(replacement)}

        {:error, reason} ->
          _ = File.rename(archive_path, path)
          {:error, reason}
      end
    end
  end

  defp prune_stale_archives(path, archive_path_to_keep) do
    path
    |> Kernel.<>(".stale-*")
    |> Path.wildcard()
    |> Enum.reject(&(&1 == archive_path_to_keep))
    |> Enum.each(fn stale_path ->
      case File.rm(stale_path) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to prune stale process ownership archive #{stale_path}: #{inspect(reason)}")
      end
    end)
  end

  defp create_record_exclusive(path, %Issue{} = issue, attrs, state) do
    record = build_record(issue, attrs, state)

    with {:ok, body} <- Jason.encode(record),
         {:ok, io} <- File.open(path, [:write, :exclusive]) do
      result = write_synced(io, body <> "\n")

      close_result = File.close(io)

      case {result, close_result} do
        {:ok, :ok} -> {:ok, record}
        {{:error, reason}, _close_result} -> {:error, reason}
        {:ok, {:error, reason}} -> {:error, reason}
      end
    end
  end

  defp write_synced(io, body) do
    :ok = IO.binwrite(io, body)
    :file.sync(io)
  end

  defp replace_record(path, %Issue{} = issue, attrs, state) do
    record = build_record(issue, attrs, state)
    temporary_path = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    with {:ok, body} <- Jason.encode(record),
         :ok <- File.write(temporary_path, body <> "\n", [:exclusive, :sync]),
         :ok <- File.rename(temporary_path, path) do
      {:ok, record}
    else
      {:error, reason} ->
        _ = File.rm(temporary_path)
        {:error, reason}
    end
  end

  defp build_record(%Issue{} = issue, attrs, state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    app_server_pgid = attrs.app_server_pgid || process_group_id(attrs.app_server_pid)
    process_tree_pids = process_tree_pids(attrs.app_server_pid, attrs.process_tree_pids)

    %{
      "version" => 1,
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "role" => attrs.role || current_role(),
      "run_id" => attrs.run_id,
      "holder" => attrs.holder || holder_id(),
      "worker_host" => attrs.worker_host,
      "worker_host_id" => current_host(),
      "workspace_path" => attrs.workspace_path,
      "session_id" => attrs.session_id,
      "worker_pid" => attrs.worker_pid,
      "app_server_pid" => attrs.app_server_pid,
      "app_server_pgid" => app_server_pgid,
      "process_tree_pids" => process_tree_pids,
      "owned_session_ref" => attrs.owned_session_ref,
      "ownership_env" => Map.new(ownership_env(issue, attrs)),
      "state" => state,
      "cleanup_status" => state,
      "cleanup_evidence" => settlement_evidence_record(attrs.cleanup_evidence),
      "quarantine_reason" => attrs.quarantine_reason,
      "failure_observation" =>
        if(Map.get(attrs, :failure_observation) == :clear,
          do: nil,
          else: Map.get(attrs, :failure_observation)
        ),
      "updated_at" => now
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp with_scope_lock(path, fun) when is_binary(path) and is_function(fun, 0) do
    lock_path = path <> ".lock"

    case acquire_scope_lock(lock_path) do
      {:ok, token} ->
        run_with_scope_lock(lock_path, token, fun)

      {:error, :ownership_lock_held} ->
        recover_and_retry_scope_lock(lock_path, fun)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_with_scope_lock(lock_path, token, fun) do
    fun.()
  after
    release_scope_lock(lock_path, token)
  end

  defp recover_and_retry_scope_lock(lock_path, fun) do
    case recover_stale_scope_lock(lock_path) do
      :recovered ->
        case acquire_scope_lock(lock_path) do
          {:ok, token} -> run_with_scope_lock(lock_path, token, fun)
          {:error, reason} -> {:error, reason}
        end

      :not_stale ->
        {:error, :ownership_lock_held}
    end
  end

  defp acquire_scope_lock(lock_path) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    case File.mkdir(lock_path) do
      :ok ->
        owner = %{
          "version" => 1,
          "token" => token,
          "worker_host_id" => current_host(),
          "owner_pid" => System.pid(),
          "created_at_ms" => System.system_time(:millisecond)
        }

        case File.write(Path.join(lock_path, @lock_owner_file), Jason.encode!(owner) <> "\n", [:exclusive, :sync]) do
          :ok ->
            {:ok, token}

          {:error, reason} ->
            _ = File.rmdir(lock_path)
            {:error, reason}
        end

      {:error, :eexist} ->
        {:error, :ownership_lock_held}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_scope_lock(lock_path, token) do
    owner_path = Path.join(lock_path, @lock_owner_file)

    case read_scope_lock_owner(owner_path) do
      {:ok, %{"token" => ^token}} ->
        _ = File.rm(owner_path)
        _ = File.rmdir(lock_path)

      _ ->
        :ok
    end
  end

  defp recover_stale_scope_lock(lock_path) do
    if stale_scope_lock?(lock_path) do
      stale_path =
        lock_path <>
          ".stale-" <>
          Integer.to_string(System.unique_integer([:positive, :monotonic]))

      case File.rename(lock_path, stale_path) do
        :ok ->
          _ = File.rm_rf(stale_path)
          :recovered

        {:error, :enoent} ->
          :recovered

        {:error, _reason} ->
          :not_stale
      end
    else
      :not_stale
    end
  end

  defp stale_scope_lock?(lock_path) do
    case read_scope_lock_owner(Path.join(lock_path, @lock_owner_file)) do
      {:ok, %{"version" => 1, "worker_host_id" => host, "owner_pid" => pid}} ->
        host == current_host() and not pid_live?(pid)

      {:ok, _owner} ->
        false

      {:error, _reason} ->
        scope_lock_age_ms(lock_path) >= @malformed_lock_stale_after_ms
    end
  end

  defp read_scope_lock_owner(path) do
    with {:ok, body} <- File.read(path),
         {:ok, owner} <- Jason.decode(body),
         true <- is_map(owner) do
      {:ok, owner}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_lock_owner}
    end
  end

  defp scope_lock_age_ms(lock_path) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) ->
        max(System.system_time(:millisecond) - mtime * 1_000, 0)

      _ ->
        0
    end
  end

  defp validate_local_attrs(attrs) do
    with :ok <- validate_identity(attrs) do
      if blank_string?(attrs.worker_host), do: :ok, else: {:error, :remote_worker_not_supported}
    end
  end

  defp validate_identity(%{holder: holder, run_id: run_id})
       when is_binary(holder) and holder != "" and is_binary(run_id) and run_id != "",
       do: :ok

  defp validate_identity(_attrs), do: {:error, :invalid_ownership_identity}

  defp validate_state(state) when state in @valid_states, do: :ok
  defp validate_state(_state), do: {:error, :invalid_ownership_state}

  defp verify_owner(record, attrs) do
    if same_owner?(record, attrs), do: :ok, else: {:error, :ownership_mismatch}
  end

  defp validate_identity_updates(record, attrs) do
    updates = normalize_attrs(attrs)

    immutable_matches? =
      optional_equal?(updates.holder, record["holder"]) and
        optional_equal?(updates.run_id, record["run_id"]) and
        optional_equal?(updates.role, record["role"]) and
        optional_workspace_equal?(updates.workspace_path, record["workspace_path"])

    if immutable_matches?, do: :ok, else: {:error, :ownership_identity_change}
  end

  defp optional_equal?(nil, _existing), do: true
  defp optional_equal?(value, existing), do: value == existing

  defp optional_workspace_equal?(nil, _existing), do: true

  defp optional_workspace_equal?(value, existing) when is_binary(value) and is_binary(existing) do
    normalize_workspace_path(value) == normalize_workspace_path(existing)
  end

  defp optional_workspace_equal?(_value, _existing), do: false

  defp same_owner?(record, attrs) do
    record["holder"] == attrs.holder and record["run_id"] == attrs.run_id
  end

  defp stale_record?(%{"worker_host" => worker_host}) when is_binary(worker_host) and worker_host != "",
    do: false

  defp stale_record?(%{"state" => state}) when state in ["cleaned", "released"],
    do: true

  defp stale_record?(%{"state" => state} = record)
       when state in ["active", "retrying", "quarantined", "blocked"] do
    holder_has_dead_pid?(record["holder"]) and not local_process_live?(record)
  end

  defp stale_record?(_record), do: false

  defp holder_has_dead_pid?(holder) when is_binary(holder) do
    case holder |> String.split(":") |> Enum.reverse() do
      [_role, pid | _host_parts] ->
        case Integer.parse(pid) do
          {integer, ""} when integer > 0 -> not pid_live?(integer)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp holder_has_dead_pid?(_holder), do: false

  defp merge_record_attrs(record, attrs) do
    updates = normalize_attrs(attrs)

    %{
      role: prefer_update(updates.role, string_value(record["role"])),
      run_id: prefer_update(updates.run_id, string_value(record["run_id"])),
      holder: prefer_update(updates.holder, string_value(record["holder"])),
      issue_id: prefer_update(updates.issue_id, string_value(record["issue_id"])),
      issue_identifier: prefer_update(updates.issue_identifier, string_value(record["issue_identifier"])),
      worker_host: prefer_update(updates.worker_host, string_value(record["worker_host"])),
      workspace_path: prefer_update(updates.workspace_path, string_value(record["workspace_path"])),
      session_id: prefer_update(updates.session_id, string_value(record["session_id"])),
      quarantine_reason: prefer_update(updates.quarantine_reason, string_value(record["quarantine_reason"])),
      cleanup_evidence: prefer_update(updates.cleanup_evidence, settlement_evidence_value(record)),
      failure_observation:
        merge_failure_observation(
          updates.failure_observation,
          failure_observation_value(record)
        ),
      worker_pid: prefer_update(updates.worker_pid, pid_value(record["worker_pid"])),
      app_server_pid: prefer_update(updates.app_server_pid, pid_value(record["app_server_pid"])),
      app_server_pgid: prefer_update(updates.app_server_pgid, pid_value(record["app_server_pgid"])),
      process_tree_pids: prefer_pid_list(updates.process_tree_pids, record["process_tree_pids"]),
      owned_session_ref: prefer_update(updates.owned_session_ref, owned_session_ref_value(record))
    }
  end

  defp prefer_update(nil, existing), do: existing
  defp prefer_update(value, _existing), do: value
  defp merge_failure_observation(:clear, _existing), do: nil
  defp merge_failure_observation(nil, existing), do: existing
  defp merge_failure_observation(observation, _existing), do: observation
  defp prefer_pid_list([], existing), do: pid_list_value(existing)
  defp prefer_pid_list(values, _existing), do: values

  defp owned_record_paths(workspace_root) when is_binary(workspace_root) do
    [
      Path.join([workspace_root, ".symphony", "process-ownership", "*.json"]),
      Path.join([workspace_root, "*", ".symphony", "process-ownership", "*.json"])
    ]
    |> Enum.flat_map(&Path.wildcard(&1, match_dot: true))
    |> Enum.uniq()
  end

  defp recover_stale_owned_session(path, cleanup_fun, count) do
    with_scope_lock(path, fn ->
      case read_exact_record(path) do
        {:ok, record} -> recover_stale_record_locked(path, record, cleanup_fun, count)
        {:error, _reason} -> count
      end
    end)
    |> case do
      result when is_integer(result) -> result
      _ -> count
    end
  rescue
    error ->
      Logger.warning("Failed to recover stale run-owned session record #{path}: #{Exception.message(error)}")
      count
  end

  defp recover_stale_record_locked(path, record, cleanup_fun, count) do
    if stale_owned_session_record?(record) do
      recover_stale_session(path, record, cleanup_fun, count)
    else
      count
    end
  end

  defp recover_stale_session(path, record, cleanup_fun, count) do
    ownership_ref = owned_session_ref_value(record)

    case cleanup_fun.(ownership_ref) do
      :ok ->
        :ok = mark_record_cleaned(path, record)
        count + 1

      {:error, reason} ->
        Logger.warning("Failed to recover stale run-owned session #{ownership_ref.session_name}: #{inspect(reason)}")
        count
    end
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

  defp mark_record_cleaned(path, record) do
    updated =
      record
      |> Map.put("state", "cleaned")
      |> Map.put("cleanup_status", "cleaned")
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

    with {:ok, body} <- Jason.encode(updated) do
      File.write(path, body <> "\n")
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
      cleanup_evidence: settlement_evidence_value(attrs),
      failure_observation: failure_observation_value(attrs),
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

  defp failure_observation_value(attrs) when is_map(attrs) do
    case value_for(attrs, :failure_observation) do
      :clear ->
        :clear

      %{} = observation ->
        fingerprint = value_for(observation, :fingerprint)
        reset_marker = value_for(observation, :reset_marker)
        count = value_for(observation, :count)

        if is_map(fingerprint) and is_map(reset_marker) and is_integer(count) and count > 0 do
          %{
            fingerprint: normalize_failure_fingerprint(fingerprint),
            count: count,
            reset_marker: normalize_failure_reset_marker(reset_marker)
          }
        end

      _ ->
        nil
    end
  end

  defp failure_observation_value(_attrs), do: nil

  defp normalize_failure_fingerprint(fingerprint) do
    %{
      issue_id: value_for(fingerprint, :issue_id),
      workspace_path: value_for(fingerprint, :workspace_path),
      role: value_for(fingerprint, :role),
      runtime_provider: controlled_atom_value(value_for(fingerprint, :runtime_provider)),
      family: controlled_atom_value(value_for(fingerprint, :family)),
      subtype: value_for(fingerprint, :subtype),
      summary: value_for(fingerprint, :summary)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_failure_reset_marker(reset_marker) do
    %{
      execution_generation: value_for(reset_marker, :execution_generation),
      retry_epoch: value_for(reset_marker, :retry_epoch),
      input_fingerprint: value_for(reset_marker, :input_fingerprint),
      operator_repair_id: value_for(reset_marker, :operator_repair_id)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp controlled_atom_value(value) when is_atom(value), do: value

  defp controlled_atom_value(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp controlled_atom_value(value), do: value

  defp value_for(attrs, key) when is_atom(key), do: attrs[key] || attrs[Atom.to_string(key)]

  defp scoped_registry_path(%Issue{} = issue, normalized_attrs) when is_map(normalized_attrs) do
    base = local_registry_root()
    Path.join([base, @registry_dir, scoped_registry_filename(issue, normalized_attrs)])
  end

  defp local_registry_root do
    Config.settings!().workspace.root
    |> Path.expand()
  end

  defp scope_attrs(%Issue{} = issue, attrs) when is_map(attrs) do
    if blank_string?(attrs.workspace_path) do
      %{attrs | workspace_path: expected_workspace_path(issue)}
    else
      attrs
    end
  end

  defp scoped_registry_filename(%Issue{} = issue, attrs) do
    issue_scope = safe_name(issue.id || issue.identifier || "issue")
    role_scope = safe_name(attrs.role || current_role() || "role")
    workspace_scope = safe_name(workspace_scope_name(attrs.workspace_path))

    [issue_scope, role_scope, workspace_scope]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("--")
    |> Kernel.<>(".json")
  end

  defp workspace_scope_name(nil), do: "default"

  defp workspace_scope_name(path) when is_binary(path) do
    normalized = normalize_workspace_path(path)
    digest = :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    "#{Path.basename(normalized)}-#{digest}"
  end

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
    case read_exact_record(path) do
      {:ok, record} -> [record]
      {:error, :enoent} -> []
      {:error, :malformed_ownership_record} -> [malformed_record(path)]
    end
  end

  defp read_exact_record(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, record} <- Jason.decode(body),
         true <- valid_record?(record) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :malformed_ownership_record}
    end
  end

  defp valid_record?(
         %{
           "version" => 1,
           "state" => state,
           "cleanup_status" => cleanup_status
         } = record
       ) do
    state in @valid_states and
      cleanup_status in @valid_states and
      Enum.all?(@required_record_strings, &nonblank_string?(record[&1]))
  end

  defp valid_record?(_record), do: false

  defp nonblank_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp malformed_record(path) do
    %{
      "version" => 1,
      "state" => "malformed",
      "cleanup_status" => "malformed",
      "path" => path,
      "updated_at" => ""
    }
  end

  defp blocking_record?(%{"state" => "malformed"}, %Issue{}), do: true

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
    table = checked_process_table()

    cond do
      any_pid_live_in_table?(process_pids, table) ->
        true

      process_group_live_in_snapshot?(record["app_server_pgid"], table) or ownership_env_process_live?(record) ->
        true

      process_pids == [] and holder_has_dead_pid?(record["holder"]) ->
        false

      process_pids == [] ->
        true

      true ->
        false
    end
  end

  defp quarantined_record_blocks?(%{"worker_host" => worker_host})
       when is_binary(worker_host) and worker_host != "",
       do: true

  defp quarantined_record_blocks?(record), do: local_process_live?(record)

  defp local_process_live?(record) do
    table = checked_process_table()

    any_pid_live_in_table?(record_process_pids(record), table) or
      process_group_live_in_snapshot?(record["app_server_pgid"], table) or ownership_env_process_live?(record)
  end

  @spec owned_process_live?(map()) :: boolean()
  def owned_process_live?(attrs) when is_map(attrs) do
    normalized_attrs = normalize_attrs(attrs)
    app_server_pgid = normalized_attrs.app_server_pgid || process_group_id(normalized_attrs.app_server_pid)
    process_tree_pids = process_tree_pids(normalized_attrs.app_server_pid, normalized_attrs.process_tree_pids)
    table = checked_process_table()

    any_pid_live_in_table?(
      [normalized_attrs.app_server_pid, normalized_attrs.worker_pid | process_tree_pids],
      table
    ) or
      process_group_live_in_snapshot?(app_server_pgid, table) or ownership_env_process_live?(normalized_attrs)
  end

  @spec owned_process_live?(Issue.t(), map()) :: boolean()
  def owned_process_live?(%Issue{} = issue, attrs) when is_map(attrs) do
    attrs
    |> Map.put_new(:issue_id, issue.id)
    |> Map.put_new(:issue_identifier, issue.identifier)
    |> merge_existing_process_tree(status_for_issue(issue))
    |> owned_process_live?()
  end

  # Liveness feeds the dispatch-admission gates, so it obeys the same
  # invariant as the settlement evidence path (66-F1): a process-table read
  # that failed is never evidence that an owned process died. Liveness is
  # therefore resolved from ONE checked process-table read — never from a
  # per-PID `kill -0`, whose non-zero exit cannot distinguish "dead" from
  # "kill is unusable" or "not permitted" — and an unusable read reports the
  # recorded PIDs LIVE. Failing the other way is what lets a second run start
  # over a live one.
  defp any_pid_live?(pids) when is_list(pids) do
    candidates = pids |> Enum.map(&pid_value/1) |> Enum.reject(&is_nil/1)

    case {candidates, checked_process_table()} do
      {[], _process_table} ->
        false

      {candidates, {:ok, processes}} ->
        live = MapSet.new(processes, fn {pid, _ppid, _pgid} -> pid end)
        Enum.any?(candidates, &MapSet.member?(live, &1))

      {candidates, {:error, reason}} ->
        Logger.warning("Process table unreadable (#{inspect(reason)}); treating owned pids #{inspect(candidates)} as live")

        true
    end
  end

  defp pid_live?(pid) when is_integer(pid) and pid > 0, do: any_pid_live?([pid])

  defp pid_live?(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {integer, ""} -> pid_live?(integer)
      _ -> false
    end
  end

  defp pid_live?(_pid), do: false

  # Batched liveness: decide a recorded pid set against ONE process-table
  # snapshot instead of forking `kill -0` per pid. Production records carried
  # hundreds of stale pids, so the per-pid fan-out shelled `System.cmd` hundreds
  # of times per evaluation and wedged the caller (EMB-1260).
  # The snapshot is the TYPED read (`checked_process_table/0`), so batching never
  # costs the fail-closed guarantee: an unusable read is not evidence of an empty
  # table (EMB-1259), it reports the recorded pids LIVE and blocks admission.
  defp any_pid_live_in_table?([], _table), do: false

  defp any_pid_live_in_table?(pids, {:ok, processes}) when is_list(pids) do
    live = live_pid_set(processes)
    Enum.any?(pids, fn pid -> MapSet.member?(live, pid_value(pid)) end)
  end

  defp any_pid_live_in_table?(pids, {:error, reason}) when is_list(pids) do
    case pids |> Enum.map(&pid_value/1) |> Enum.reject(&is_nil/1) do
      [] ->
        false

      candidates ->
        Logger.warning("Process table unreadable (#{inspect(reason)}); treating owned pids #{inspect(candidates)} as live")

        true
    end
  end

  defp live_pid_set(table) when is_list(table) do
    MapSet.new(table, fn {pid, _ppid, _pgid} -> pid end)
  end

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
      cleanup_evidence: settlement_evidence_value(record),
      failure_observation: failure_observation_value(record),
      live?: local_process_live?(record)
    }
  end

  defp settlement_evidence_value(attrs) when is_map(attrs) do
    case value_for(attrs, :cleanup_evidence) do
      %{} = evidence ->
        owned_pids = pid_list_value(value_for(evidence, :owned_pids))
        verified = boolean_value_for(evidence, :verified)
        captured_at = string_value(value_for(evidence, :captured_at))

        status = settlement_evidence_status(evidence)
        live_after = settlement_live_after(status, value_for(evidence, :live_after))

        if is_boolean(verified) and settlement_live_after_valid?(status, live_after) do
          %{
            owned_pids: owned_pids,
            live_after: live_after,
            verified: verified,
            captured_at: captured_at,
            evidence_status: status
          }
        end

      _ ->
        nil
    end
  end

  defp settlement_evidence_value(_attrs), do: nil

  # Evidence a settlement could not capture stays marked as such: only an
  # explicit `captured` status (or evidence written before the status
  # existed) reads back as captured, so an unrecognized value can never
  # upgrade unverifiable evidence into a settled observation. `live_after`
  # carries no meaning for `:unavailable` evidence — nothing was observed.
  defp settlement_evidence_status(evidence) when is_map(evidence) do
    case value_for(evidence, :evidence_status) do
      nil -> :captured
      :captured -> :captured
      "captured" -> :captured
      _unavailable -> :unavailable
    end
  end

  # Evidence that observed nothing carries no survivor count. A `live_after`
  # written next to an `:unavailable` status — including the fabricated `0`
  # persisted by pre-66-F1 builds — is read back as absent, so no consumer can
  # mistake "nothing was counted" for "0 survivors confirmed".
  defp settlement_live_after(:unavailable, _live_after), do: nil
  defp settlement_live_after(:captured, live_after), do: live_after

  defp settlement_live_after_valid?(:unavailable, live_after), do: is_nil(live_after)
  defp settlement_live_after_valid?(:captured, live_after), do: is_integer(live_after) and live_after >= 0

  # `value_for/2` folds legitimate `false` into the string-key fallback, so
  # boolean evidence fields need explicit key resolution.
  defp boolean_value_for(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> nil
        end
    end
  end

  defp settlement_evidence_record(nil), do: nil

  defp settlement_evidence_record(%{} = evidence) do
    %{
      "owned_pids" => evidence.owned_pids,
      "live_after" => evidence.live_after,
      "verified" => evidence.verified,
      "captured_at" => evidence.captured_at,
      "evidence_status" => evidence |> settlement_evidence_status() |> Atom.to_string()
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

      if kind == "herdr" and valid_owned_herdr_session_name?(session_name),
        do: %{kind: kind, session_name: session_name},
        else: nil
    end
  end

  defp owned_session_ref_value(_attrs), do: nil

  defp valid_owned_herdr_session_name?(session_name) when is_binary(session_name) do
    byte_size(session_name) <= 44 and Regex.match?(~r/^octo-[a-z0-9][a-z0-9-]*$/, session_name)
  end

  defp valid_owned_herdr_session_name?(_session_name), do: false

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
    # One table snapshot serves both descendant discovery and pruning: recorded
    # pids that are dead in this same snapshot are dropped so a rebuilt record
    # stops accumulating stale trees across active refreshes (the production
    # record had ~300 dead pids). The app-server anchor is always retained;
    # terminal settlement captures its own evidence pre-teardown (EMB-1259), so
    # dropping dead pids here never changes cleanup_evidence semantics.
    #
    # Pruning is an optimisation over a SUCCESSFUL observation, so it reads the
    # table through the TYPED reader. A failed read is never evidence of an
    # empty table (see `checked_process_table/0`); pruning against one would
    # silently empty the recorded pid set and discard the very evidence a
    # settlement needs. On an unusable read the recorded pids are therefore
    # retained unpruned, alongside the always-retained app-server anchor.
    case checked_process_table() do
      {:ok, table} -> pruned_process_tree_pids(app_server_pid, existing_pids, table)
      {:error, _unavailable} -> normalize_tree_pids([app_server_pid] ++ existing_pids)
    end
  end

  defp pruned_process_tree_pids(app_server_pid, existing_pids, table) do
    live = live_pid_set(table)
    anchor = pid_value(app_server_pid)

    live_existing = Enum.filter(existing_pids, fn pid -> MapSet.member?(live, pid_value(pid)) end)

    normalize_tree_pids([app_server_pid] ++ live_existing ++ descendants_from_process_table(table, anchor))
  end

  defp normalize_tree_pids(pids) do
    pids
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

  defp descendants_from_process_table(processes, root_pid) when is_list(processes) and not is_integer(root_pid),
    do: []

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

  # Normalises the recorded pgid, then decides it against a snapshot the caller
  # already read, so one evaluation forks `ps` once (EMB-1260) without giving up
  # the typed fail-closed behaviour below (EMB-1259). A record with no recorded
  # pgid is not "live via its group" — the pid and env checks still run.
  # (Replaces the former `process_group_live?/1`, which was exactly this over an
  # unshared `checked_process_table/0` read.)
  defp process_group_live_in_snapshot?(pgid, table) do
    case pid_value(pgid) do
      nil -> false
      integer -> process_group_live_in_table?(integer, table)
    end
  end

  defp process_group_live_in_table?(pgid, {:ok, processes}),
    do: Enum.any?(processes, fn {_pid, _ppid, process_pgid} -> process_pgid == pgid end)

  defp process_group_live_in_table?(pgid, {:error, reason}) do
    Logger.warning("Process table unreadable (#{inspect(reason)}); treating owned process group #{pgid} as live")

    true
  end

  # Admission-side liveness, so a failed sweep is not "no process matches".
  defp ownership_env_process_live?(attrs_or_record) do
    criteria = ownership_env_criteria(attrs_or_record)

    if ownership_env_criteria_scoped?(criteria) do
      case checked_matching_processes(criteria) do
        {:ok, pids} ->
          pids != []

        {:error, reason} ->
          Logger.warning("Process table unreadable (#{inspect(reason)}); treating the run's ownership environment as live")

          true
      end
    else
      false
    end
  end

  defp ownership_env_pids(attrs_or_record) when is_map(attrs_or_record) do
    criteria = ownership_env_criteria(attrs_or_record)

    if ownership_env_criteria_scoped?(criteria) do
      matching_processes(criteria)
    else
      []
    end
  end

  defp matching_processes(criteria) when is_list(criteria) do
    case checked_matching_processes(criteria) do
      {:ok, pids} -> pids
      {:error, _reason} -> []
    end
  end

  # The settlement variants keep a failed process-table read typed instead of
  # degrading it to "no process matches", which reads identically to a clean
  # run and would forge the cleanup-verified marker.
  defp checked_matching_processes(criteria) when is_list(criteria) do
    case checked_process_table() do
      {:ok, processes} ->
        {:ok,
         processes
         |> Enum.map(fn {pid, _ppid, _pgid} -> pid end)
         |> Enum.filter(&process_env_matches?(&1, criteria))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An unscoped criteria set is never swept, so no machinery runs and no
  # machinery can fail: that is a successful empty scan, not an unavailable
  # one.
  defp scoped_matching_processes(criteria) when is_list(criteria) do
    if ownership_env_criteria_scoped?(criteria) do
      checked_matching_processes(criteria)
    else
      {:ok, []}
    end
  end

  # With a candidate list (the KILL pass over TERM survivors, EMB-1260) only
  # those pids are env-rechecked before signalling; without one the initial
  # TERM pass discovers candidates from a checked table read that stays typed
  # on failure (EMB-1259 66-F1).
  #
  # ACCEPTED GAP — the KILL pass can only ever cover pids discovered and
  # env-matched during the TERM pass. An owned process that becomes
  # discoverable only AFTER that snapshot (forked late by a surviving
  # descendant, or whose ownership environment was not yet readable when the
  # snapshot was taken) is never reached by THIS settlement's KILL. The
  # narrowing is deliberate: it bounds teardown to one host-wide scan instead
  # of re-scanning every process's environment per pass, which is what keeps
  # settlement bounded. The residue is not dropped — it is left to the
  # ownership record's own liveness evidence (which still reports it live) and
  # to later reconciliation of orphaned claims. A settlement that still
  # observes live owned processes fails typed, so this gap can never be
  # laundered into a forged clean settlement.
  #
  # `process_env_matches?/2` widens the gap off Linux: it reads
  # /proc/<pid>/environ, so on a host without /proc the read fails, the matcher
  # is false for EVERY pid, and the whole env-scoped sweep is inert — teardown
  # signals nothing and the narrowing is trivially total. Containment there
  # rests entirely on liveness evidence and reconciliation, and any test
  # asserting owned-pid set CONTENT on such a host is asserting a tautology.
  # See docs/specs/domains/agent-runtime.md, "Rules and invariants".
  defp signal_matching_processes(criteria, signal, candidates \\ nil)
       when is_list(criteria) and signal in ["TERM", "KILL"] do
    candidates_result =
      if is_list(candidates), do: {:ok, candidates}, else: checked_matching_processes(criteria)

    case candidates_result do
      {:ok, pids} ->
        matching_pids = Enum.filter(pids, &process_env_matches?(&1, criteria))
        Enum.each(matching_pids, &signal_process(&1, signal))

        {:ok, matching_pids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp signal_process(pid, signal) when is_integer(pid) and signal in ["TERM", "KILL"] do
    _ =
      System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)

    :ok
  rescue
    _ -> :ok
  end

  # Re-check only the still-live candidate pids each iteration, not the whole
  # process table's environs: one table read decides which candidates are still
  # alive, and the ownership-environment re-check runs only for those survivors
  # (EMB-1260). A failed table read stays typed instead of reading as "all
  # candidates exited" (EMB-1259 66-F1): teardown then fails
  # settlement_evidence_unavailable rather than forging a clean wait.
  defp await_matching_processes(criteria, candidates, 0),
    do: still_matching_candidates(criteria, candidates)

  defp await_matching_processes(criteria, candidates, attempts) when attempts > 0 do
    case still_matching_candidates(criteria, candidates) do
      {:ok, []} ->
        {:ok, []}

      {:ok, survivors} ->
        Process.sleep(@owned_process_exit_interval_ms)
        await_matching_processes(criteria, survivors, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp still_matching_candidates(_criteria, []), do: {:ok, []}

  defp still_matching_candidates(criteria, candidates) when is_list(candidates) do
    case checked_process_table() do
      {:ok, processes} ->
        live = live_pid_set(processes)

        {:ok,
         Enum.filter(candidates, fn pid ->
           MapSet.member?(live, pid) and process_env_matches?(pid, criteria)
         end)}

      {:error, reason} ->
        {:error, reason}
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

  # The untyped view, kept ONLY for the two record-construction readers that
  # widen what a record knows and never narrow it: `process_group_id/1` and
  # `descendant_pids/1`. Both union newly discovered PIDs into the recorded
  # tree, so an unusable read records less than the host could have shown but
  # never discards a PID the record already carries, and never reports a live
  # process dead. Every liveness decision — settlement evidence and the
  # dispatch-admission gates alike — goes through `checked_process_table/0`
  # and fails closed instead (66-F1).
  defp process_table do
    case checked_process_table() do
      {:ok, processes} -> processes
      {:error, _reason} -> []
    end
  end

  # A failed process-table read is never evidence of an empty table.
  # `ps -eo pid=,ppid=,pgid=` on a live host always lists at least this BEAM
  # process, so all three failure shapes — a non-zero exit, a raised call
  # (no readable `ps`), and output without a single parseable row — mean the
  # read is unusable rather than empty.
  defp checked_process_table do
    case System.cmd("ps", ["-eo", "pid=,ppid=,pgid="], stderr_to_stdout: true) do
      {output, 0} ->
        case parse_process_table(output) do
          [] -> {:error, :settlement_evidence_unavailable}
          processes -> {:ok, processes}
        end

      _failed_read ->
        {:error, :settlement_evidence_unavailable}
    end
  rescue
    _error -> {:error, :settlement_evidence_unavailable}
  end

  defp parse_process_table(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_process_table_line/1)
  end

  defp parse_process_table_line(line) when is_binary(line) do
    case line |> String.split(~r/\s+/, trim: true) |> Enum.map(&Integer.parse/1) do
      [{pid, ""}, {ppid, ""}, {pgid, ""}] -> [{pid, ppid, pgid}]
      _ -> []
    end
  end
end
