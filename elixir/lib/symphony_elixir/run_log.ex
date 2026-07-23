defmodule SymphonyElixir.RunLog do
  @moduledoc """
  Writes compact JSONL artifacts scoped by issue and run id.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Runtime.ProcessOwnership

  @redacted "[REDACTED]"

  @spec record_agent_retry_scheduled(String.t(), map(), map() | nil, map(), map()) :: :ok
  def record_agent_retry_scheduled(issue_id, retry_context, process_ownership, metadata, retry)
      when is_binary(issue_id) and is_map(retry_context) and is_map(metadata) and is_map(retry) do
    case {configured_root(), run_id(retry_context, process_ownership)} do
      {root, run_id} when is_binary(root) and is_binary(run_id) ->
        issue_identifier = issue_identifier(issue_id, retry_context, process_ownership)
        path = Path.join([root, safe_segment(issue_identifier), "#{safe_segment(run_id)}.jsonl"])

        payload =
          agent_retry_scheduled_payload(
            issue_id,
            issue_identifier,
            run_id,
            retry_context,
            process_ownership,
            metadata,
            retry
          )

        :ok = File.mkdir_p(Path.dirname(path))
        :ok = File.write(path, Jason.encode!(payload) <> "\n", [:append])
        :ok

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("Failed to write run log artifact for issue_id=#{issue_id}: #{Exception.message(error)}")
      :ok
  end

  @spec record_irrecoverable_runtime_failure(String.t(), map(), map() | nil, map()) :: :ok
  def record_irrecoverable_runtime_failure(issue_id, running_entry, process_ownership, failure)
      when is_binary(issue_id) and is_map(running_entry) and is_map(failure) do
    case {configured_root(), run_id(running_entry, process_ownership)} do
      {root, run_id} when is_binary(root) and is_binary(run_id) ->
        issue_identifier = issue_identifier(issue_id, running_entry, process_ownership)
        path = Path.join([root, safe_segment(issue_identifier), "#{safe_segment(run_id)}.jsonl"])

        payload =
          irrecoverable_runtime_failure_payload(
            issue_id,
            issue_identifier,
            run_id,
            running_entry,
            process_ownership,
            failure
          )

        :ok = File.mkdir_p(Path.dirname(path))
        :ok = File.write(path, Jason.encode!(payload) <> "\n", [:append])
        :ok

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("Failed to write irrecoverable run log artifact for issue_id=#{issue_id}: #{Exception.message(error)}")
      :ok
  end

  defp configured_root do
    case Application.get_env(:symphony_elixir, :run_log_root) do
      root when is_binary(root) ->
        root = String.trim(root)
        if root == "", do: nil, else: Path.expand(root)

      _ ->
        nil
    end
  end

  defp run_id(_retry_context, %{run_id: run_id}) when is_binary(run_id) and run_id != "",
    do: run_id

  defp run_id(%{run_id: run_id}, _process_ownership) when is_binary(run_id) and run_id != "",
    do: run_id

  defp run_id(_retry_context, _process_ownership), do: nil

  defp issue_identifier(_issue_id, _retry_context, %{issue_identifier: identifier})
       when is_binary(identifier) and identifier != "",
       do: identifier

  defp issue_identifier(_issue_id, %{issue: %Issue{identifier: identifier}}, _process_ownership)
       when is_binary(identifier) and identifier != "",
       do: identifier

  defp issue_identifier(_issue_id, %{identifier: identifier}, _process_ownership)
       when is_binary(identifier) and identifier != "",
       do: identifier

  defp issue_identifier(issue_id, _retry_context, _process_ownership), do: issue_id

  defp agent_retry_scheduled_payload(issue_id, issue_identifier, run_id, retry_context, process_ownership, metadata, retry) do
    %{
      event: "agent_retry_scheduled",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      issue_state: issue_state(retry_context),
      role: ProcessOwnership.current_role(),
      run_id: run_id,
      session_id: metadata[:session_id],
      attempt: metadata[:attempt],
      started_at: iso8601(metadata[:started_at]),
      worker_host: retry_context[:worker_host],
      workspace_path: retry_context[:workspace_path],
      reason: redact_runtime_text(retry_context[:error]),
      retry: %{
        attempt: retry[:attempt],
        delay_ms: retry[:delay_ms],
        due_at_ms: retry[:due_at_ms],
        scheduled_for: iso8601(retry[:scheduled_for]),
        lease_state: retry[:lease_state],
        # Preserve the established JSONL schema while changing only the
        # in-memory authority that supplies this compatibility value.
        claim_lease_state: process_ownership_state(process_ownership)
      }
    }
  end

  defp irrecoverable_runtime_failure_payload(issue_id, issue_identifier, run_id, running_entry, process_ownership, failure) do
    %{
      event: "irrecoverable_runtime_failure_escalated",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      issue_state: issue_state(running_entry),
      role: ProcessOwnership.current_role(),
      run_id: run_id,
      session_id: Map.get(running_entry, :session_id),
      attempt: Map.get(running_entry, :retry_attempt),
      started_at: iso8601(Map.get(running_entry, :started_at)),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      failure: %{
        family: atom_or_string(failure[:family]),
        provider: atom_or_string(failure[:provider]),
        subtype: failure[:subtype],
        reason: redact_runtime_text(failure[:retry_reason] || failure[:summary]),
        recovery_reason: failure[:recovery_reason],
        # Preserve the established JSONL schema; do not expand telemetry.
        claim_lease_state: process_ownership_state(process_ownership)
      }
    }
  end

  defp issue_state(%{issue: %Issue{state: state}}), do: state
  defp issue_state(_retry_context), do: nil

  defp process_ownership_state(%{state: state}), do: state
  defp process_ownership_state(_process_ownership), do: nil

  defp atom_or_string(nil), do: nil
  defp atom_or_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_or_string(value) when is_binary(value), do: value
  defp atom_or_string(_value), do: nil

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp safe_segment(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.trim("._-")
    |> case do
      "" -> "unknown"
      segment -> String.slice(segment, 0, 180)
    end
  end

  defp redact_runtime_text(value) when is_binary(value) do
    value
    |> String.replace(~r/(?i)\b(authorization)\s*[:=]\s*bearer\s+[^\s,\]}]+/, "\\1=[REDACTED]")
    |> String.replace(~r/(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,\]}]+/, "\\1=[REDACTED]")
    |> String.replace(~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/-]+=*/, "Bearer #{@redacted}")
  end

  defp redact_runtime_text(value), do: value
end
