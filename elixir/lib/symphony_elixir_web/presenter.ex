defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          work_admission:
            Map.get(snapshot, :work_admission, %{
              status: "closed",
              target_generation: "unknown",
              drained: false
            }),
          execution_generation: Map.get(snapshot, :execution_generation, "unknown"),
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          polling_diagnostics: polling_diagnostics_payload(Map.get(snapshot, :polling))
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: (retry && retry.error) || (blocked && blocked.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(nil, nil, _blocked), do: "blocked"
  defp issue_status(nil, _retry, _blocked), do: "retrying"
  defp issue_status(_running, _retry, _blocked), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
    |> put_if_present(:process_ownership, process_ownership_payload(Map.get(entry, :process_ownership)))
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
    |> put_if_present(:process_ownership, process_ownership_payload(Map.get(entry, :process_ownership)))
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      family: atom_or_string(Map.get(entry, :family)),
      provider: atom_or_string(Map.get(entry, :provider)),
      subtype: Map.get(entry, :subtype),
      error: entry.error,
      recovery_reason: Map.get(entry, :recovery_reason),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      blocked_at: iso8601(Map.get(entry, :blocked_at))
    }
    |> put_if_present(:process_ownership, process_ownership_payload(Map.get(entry, :process_ownership)))
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
    |> put_if_present(:process_ownership, process_ownership_payload(Map.get(running, :process_ownership)))
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
    |> put_if_present(:process_ownership, process_ownership_payload(Map.get(retry, :process_ownership)))
  end

  defp blocked_issue_payload(blocked), do: blocked_entry_payload(blocked)

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp process_ownership_payload(nil), do: nil

  defp process_ownership_payload(process_ownership) when is_map(process_ownership) do
    %{
      state: Map.get(process_ownership, :state),
      cleanup_status: Map.get(process_ownership, :cleanup_status),
      worker_host: Map.get(process_ownership, :worker_host),
      workspace_path: Map.get(process_ownership, :workspace_path),
      app_server_pid: Map.get(process_ownership, :app_server_pid),
      app_server_pgid: Map.get(process_ownership, :app_server_pgid),
      process_tree_pids: Map.get(process_ownership, :process_tree_pids),
      worker_pid: Map.get(process_ownership, :worker_pid),
      run_id: Map.get(process_ownership, :run_id),
      session_id: Map.get(process_ownership, :session_id),
      updated_at: Map.get(process_ownership, :updated_at),
      quarantine_reason: Map.get(process_ownership, :quarantine_reason),
      live: Map.get(process_ownership, :live?)
    }
  end

  defp polling_diagnostics_payload(polling) when is_map(polling) do
    %{
      checking: Map.get(polling, :checking?) == true,
      status: polling_status(polling),
      next_poll_in_ms: Map.get(polling, :next_poll_in_ms),
      poll_interval_ms: Map.get(polling, :poll_interval_ms),
      last_poll_started_at: Map.get(polling, :last_poll_started_at),
      last_poll_completed_at: Map.get(polling, :last_poll_completed_at),
      last_poll_result: Map.get(polling, :last_poll_result),
      latest_dispatch_summary: Map.get(polling, :latest_dispatch_summary) || %{}
    }
  end

  defp polling_diagnostics_payload(_polling) do
    %{
      checking: false,
      status: "unavailable",
      next_poll_in_ms: nil,
      poll_interval_ms: nil,
      last_poll_started_at: nil,
      last_poll_completed_at: nil,
      last_poll_result: nil,
      latest_dispatch_summary: %{}
    }
  end

  defp polling_status(%{checking?: true}), do: "checking"

  defp polling_status(%{last_poll_result: result}) when is_binary(result) and result != "" do
    "idle"
  end

  defp polling_status(_polling), do: "idle"

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp atom_or_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_or_string(value) when is_binary(value), do: value
  defp atom_or_string(_value), do: nil

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
