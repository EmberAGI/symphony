defmodule SymphonyElixir.RoleTurnRecovery do
  @moduledoc """
  Filesystem-backed recovery markers for role turns that disappear mid-flight.

  The orchestrator has no durable database. A small pending-turn marker lets a
  restarted role process distinguish a fresh candidate issue from a role turn
  that had already started but died before it could leave a final handoff.
  """

  require Logger

  alias SymphonyElixir.{AgentRuntime, Linear.Issue, Tracker}
  alias SymphonyElixir.Runtime.{LifecycleVerdict, ProcessOwnership}
  alias SymphonyElixir.Tracker.ClaimLease

  @marker_version 1
  @comment_marker "symphony:aborted-role-turn-recovery"

  @type marker :: map()

  @spec record_turn_start(Issue.t()) :: :ok | {:error, term()}
  def record_turn_start(issue), do: record_turn_start(issue, [])

  @spec record_turn_start(Issue.t(), keyword()) :: :ok | {:error, term()}
  def record_turn_start(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    marker = %{
      "version" => @marker_version,
      "issue_id" => issue_id,
      "identifier" => issue.identifier,
      "state" => issue.state,
      "role" => role_name(),
      "branch" => issue.branch_name,
      "url" => issue.url,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "worker_host" => Keyword.get(opts, :worker_host),
      "workspace_path" => Keyword.get(opts, :workspace_path)
    }

    with {:ok, path} <- marker_path(issue_id),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, body} <- Jason.encode(marker) do
      File.write(path, body <> "\n")
    end
  end

  def record_turn_start(_issue, _opts), do: {:error, :missing_issue_id}

  @spec clear_turn(String.t()) :: :ok
  def clear_turn(issue_id) when is_binary(issue_id) do
    {:ok, path} = marker_path(issue_id)
    File.rm(path)

    :ok
  end

  def clear_turn(_issue_id), do: :ok

  @spec recover_pending_turns(MapSet.t(), MapSet.t()) :: :ok
  def recover_pending_turns(active_states, terminal_states)
      when is_struct(active_states, MapSet) and is_struct(terminal_states, MapSet) do
    recover_pending_turns(active_states, terminal_states, MapSet.new())
  end

  def recover_pending_turns(_active_states, _terminal_states), do: :ok

  @spec recover_pending_turns(MapSet.t(), MapSet.t(), Enumerable.t()) :: :ok
  def recover_pending_turns(active_states, terminal_states, live_issue_ids)
      when is_struct(active_states, MapSet) and is_struct(terminal_states, MapSet) do
    markers = read_pending_markers()
    live_issue_ids = normalize_issue_id_list(live_issue_ids)
    orphaned_markers = Enum.reject(markers, &live_marker?(&1, live_issue_ids))
    issue_ids = Enum.flat_map(orphaned_markers, &marker_issue_id/1)
    recover_pending_issue_ids(issue_ids, orphaned_markers, active_states, terminal_states)
  end

  def recover_pending_turns(_active_states, _terminal_states, _live_issue_ids), do: :ok

  defp recover_pending_issue_ids([], _markers, _active_states, _terminal_states), do: :ok

  defp recover_pending_issue_ids(issue_ids, markers, active_states, terminal_states) do
    case Tracker.fetch_issue_states_by_ids(issue_ids) do
      {:ok, issues} ->
        issues_by_id = Map.new(issues, fn %Issue{id: issue_id} = issue -> {issue_id, issue} end)

        Enum.each(markers, fn marker ->
          recover_marker(marker, Map.get(issues_by_id, marker["issue_id"]), active_states, terminal_states)
        end)

      {:error, reason} ->
        Logger.warning("Skipping aborted role-turn recovery; issue refresh failed: #{inspect(reason)}")
    end

    :ok
  end

  @doc false
  @spec recovery_plan_for_test(Issue.t() | nil, marker(), MapSet.t(), MapSet.t()) ::
          :clear | :skip | :already_recovered | {:recover, String.t(), String.t()}
  def recovery_plan_for_test(issue, marker, active_states, terminal_states) do
    recovery_plan(issue, marker, active_states, terminal_states)
  end

  @doc false
  @spec recovery_comment_for_test(Issue.t(), marker(), String.t()) :: String.t()
  def recovery_comment_for_test(%Issue{} = issue, marker, target_state) do
    recovery_comment(issue, marker, target_state)
  end

  defp recover_marker(marker, issue, active_states, terminal_states) do
    case recovery_lifecycle_verdict(issue) do
      %LifecycleVerdict{workflow_mutation: :refuse} = verdict ->
        Logger.warning(
          "Skipping aborted role-turn recovery while lifecycle authority is quarantined " <>
            "issue_id=#{marker["issue_id"]} session_liveness=#{verdict.session} " <>
            "lease_liveness=#{verdict.lease}"
        )

        :ok

      _allow_or_not_applicable ->
        execute_recovery_plan(marker, issue, active_states, terminal_states)
    end
  end

  defp execute_recovery_plan(marker, issue, active_states, terminal_states) do
    case recovery_plan(issue, marker, active_states, terminal_states) do
      :clear ->
        clear_turn(marker["issue_id"])

      :skip ->
        :ok

      :already_recovered ->
        maybe_update_recovery_state(issue, target_state_for(issue))

        if recovered_state?(issue) do
          clear_turn(marker["issue_id"])
        end

      {:recover, target_state, body} ->
        with :ok <- Tracker.create_comment(issue.id, body),
             :ok <- maybe_update_recovery_state(issue, target_state) do
          clear_turn(issue.id)
        else
          {:error, reason} ->
            Logger.warning("Aborted role-turn recovery failed for issue_identifier=#{issue.identifier}: #{inspect(reason)}")
        end
    end
  end

  defp recovery_lifecycle_verdict(%Issue{} = issue) do
    lease = recovery_lease_liveness(issue)

    case ProcessOwnership.blocking_owned_session_record(
           issue,
           &AgentRuntime.owned_session_liveness/1
         ) do
      {_record, :live} ->
        LifecycleVerdict.evaluate(session: :live, lease: lease, provider_turn: :working)

      {_record, status} when status in [:unknown, :unreachable] ->
        LifecycleVerdict.evaluate(session: status, lease: lease, provider_turn: :failed)

      nil ->
        LifecycleVerdict.evaluate(session: :absent, lease: lease, provider_turn: :failed)
    end
  end

  defp recovery_lifecycle_verdict(_issue), do: nil

  defp recovery_lease_liveness(%Issue{claim_lease: %ClaimLease{} = claim_lease}) do
    if ClaimLease.expired?(claim_lease, DateTime.utc_now()), do: :expired, else: :live
  end

  defp recovery_lease_liveness(_issue), do: :missing

  defp recovery_plan(nil, _marker, _active_states, _terminal_states), do: :clear

  defp recovery_plan(%Issue{} = issue, marker, active_states, terminal_states) do
    normalized_state = normalize_state(issue.state)

    cond do
      normalized_state == "" ->
        :skip

      MapSet.member?(terminal_states, normalized_state) ->
        :clear

      !MapSet.member?(active_states, normalized_state) ->
        :clear

      recovery_marker_present?(issue) ->
        :already_recovered

      true ->
        target_state = target_state_for(issue)
        {:recover, target_state, recovery_comment(issue, marker, target_state)}
    end
  end

  defp target_state_for(%Issue{state: state}) do
    case normalize_state(state) do
      "in progress" -> "Agent Fixes"
      _ -> state
    end
  end

  defp maybe_update_recovery_state(%Issue{state: state}, target_state)
       when not is_binary(target_state) or target_state == "" or state == target_state,
       do: :ok

  defp maybe_update_recovery_state(%Issue{id: issue_id}, target_state)
       when is_binary(issue_id) and is_binary(target_state) do
    Tracker.update_issue_state(issue_id, target_state)
  end

  defp recovered_state?(%Issue{} = issue) do
    normalize_state(issue.state) == normalize_state(target_state_for(issue))
  end

  defp recovery_marker_present?(%Issue{comments: comments}) when is_list(comments) do
    Enum.any?(comments, fn
      %{body: body} when is_binary(body) -> String.contains?(body, @comment_marker)
      %{"body" => body} when is_binary(body) -> String.contains?(body, @comment_marker)
      _ -> false
    end)
  end

  defp recovery_marker_present?(_issue), do: false

  defp recovery_comment(%Issue{} = issue, marker, target_state) do
    role = marker["role"] || role_name()
    source_state = marker["state"] || issue.state || "unknown"
    started_at = marker["started_at"] || "unknown"
    branch = issue.branch_name || marker["branch"] || "not recorded"
    marker_line = "<!-- #{@comment_marker} issue=#{issue.identifier || issue.id} role=#{role} state=#{source_state} target=#{target_state} -->"

    [
      "## Operator Note",
      "",
      marker_line,
      "",
      "Detected an aborted Symphony role turn before a final handoff.",
      "",
      "- Role: `#{role}`.",
      "- Detected issue state: `#{issue.state}`.",
      "- Pending turn started at: `#{started_at}`.",
      "- Recovery route: `#{target_state}`.",
      "- Branch context preserved: `#{branch}`.",
      "- Existing Codex Workpad, Symphony Handoff trail, PR attachments, and branch state were left intact.",
      "- Next expected action: Octo will continue the issue from `#{target_state}` without creating duplicate recovery evidence."
    ]
    |> Enum.join("\n")
  end

  defp read_pending_markers do
    with {:ok, dir} <- marker_dir(),
         {:ok, paths} <- File.ls(dir) do
      paths
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.flat_map(fn path ->
        dir
        |> Path.join(path)
        |> read_marker_file()
      end)
    else
      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Skipping aborted role-turn recovery marker read: #{inspect(reason)}")
        []
    end
  end

  defp read_marker_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, marker} <- Jason.decode(body),
         [issue_id] <- marker_issue_id(marker) do
      [Map.put(marker, "issue_id", issue_id)]
    else
      _ ->
        Logger.warning("Ignoring unreadable aborted role-turn marker: #{path}")
        []
    end
  end

  @spec marker_issue_id(marker()) :: [String.t()]
  defp marker_issue_id(%{"issue_id" => issue_id}) when is_binary(issue_id) and issue_id != "",
    do: [issue_id]

  defp marker_issue_id(_marker), do: []

  @spec live_marker?(marker(), [String.t()]) :: boolean()
  defp live_marker?(marker, live_issue_ids) do
    marker
    |> marker_issue_id()
    |> Enum.any?(&Enum.member?(live_issue_ids, &1))
  end

  @spec normalize_issue_id_list(Enumerable.t()) :: [String.t()]
  defp normalize_issue_id_list(issue_ids) do
    issue_ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  rescue
    Protocol.UndefinedError -> []
  end

  defp marker_path(issue_id) when is_binary(issue_id) do
    with {:ok, dir} <- marker_dir() do
      {:ok, Path.join(dir, safe_filename(issue_id) <> ".json")}
    end
  end

  defp marker_dir do
    cond do
      path = Application.get_env(:symphony_elixir, :role_turn_recovery_dir) ->
        {:ok, Path.expand(path)}

      root = System.get_env("SYMPHONY_ORCHESTRATION_ROOT") ->
        {:ok, Path.join([root, ".runtime", "symphony", "role-turn-recovery", role_name()])}

      true ->
        {:ok, Path.join([File.cwd!(), ".symphony", "role-turn-recovery", role_name()])}
    end
  end

  defp safe_filename(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "issue"
      sanitized -> sanitized
    end
  end

  defp role_name do
    System.get_env("SYMPHONY_ROLE") || "unknown"
  end

  defp normalize_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
