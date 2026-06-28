defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Provider-neutral runtime selection for the agent runner.

  Codex remains the default and reference runtime. When
  `agent_runtime.provider` is `claude_code`, role turns run through the
  first-party Claude Code shim instead. Both adapters expose the same logical
  session lifecycle (`start_session/2`, `run_turn/4`, `stop_session/1`) and emit
  the same normalized Symphony runtime events, so the orchestrator, status
  surfaces, and handoff logic are provider-agnostic.
  """

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer
  alias SymphonyElixir.Config

  @type provider :: :codex | :claude_code

  @doc """
  Resolve the configured runtime adapter module.

  Defaults to the Codex adapter so existing Codex-backed workflows are
  unchanged.
  """
  @spec adapter() :: module()
  def adapter, do: adapter(provider())

  @spec adapter(provider()) :: module()
  def adapter(:claude_code), do: ClaudeAppServer
  def adapter(:codex), do: CodexAppServer

  @doc "Return the configured runtime provider atom."
  @spec provider() :: provider()
  def provider do
    case Config.settings!().agent_runtime.provider do
      "claude_code" -> :claude_code
      _ -> :codex
    end
  end

  @doc """
  Start a runtime session with the configured adapter.
  """
  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, opts) do
    adapter().start_session(workspace, opts)
  end

  @doc """
  Run a turn with the configured adapter, threading any provider session id
  forward so continuation turns resume the same conversation.
  """
  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, {map(), map()}} | {:error, term()}
  def run_turn(session, prompt, issue, opts) do
    case adapter().run_turn(session, prompt, issue, opts) do
      {:ok, turn_result} ->
        {:ok, {advance_session(session, turn_result), turn_result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop the runtime session with the configured adapter."
  @spec stop_session(map()) :: :ok
  def stop_session(session), do: adapter().stop_session(session)

  @doc """
  Return true when a runtime error represents provider authentication failure.
  """
  @spec provider_auth_failure?(term()) :: boolean()
  def provider_auth_failure?({:auth_failed, _details}), do: true
  def provider_auth_failure?({:provider_auth_failed, _details}), do: true

  def provider_auth_failure?({:workspace_hook_failed, "before_run", _status, output}) do
    not is_nil(provider_auth_hook_details(output))
  end

  def provider_auth_failure?(_reason), do: false

  @doc """
  Normalize provider authentication failures into the process-exit reason the
  orchestrator understands.
  """
  @spec provider_auth_failure(term()) :: {:provider_auth_failed, map()}
  def provider_auth_failure(reason), do: provider_auth_failure(reason, provider())

  @spec provider_auth_failure(term(), provider()) :: {:provider_auth_failed, map()}
  def provider_auth_failure({:provider_auth_failed, details}, provider) do
    {:provider_auth_failed, provider_auth_details(details, provider)}
  end

  def provider_auth_failure({:auth_failed, details}, provider) do
    {:provider_auth_failed, provider_auth_details(details, provider)}
  end

  def provider_auth_failure({:workspace_hook_failed, "before_run", _status, output}, provider) do
    details = provider_auth_hook_details(output) || %{}
    {:provider_auth_failed, provider_auth_details(details, provider)}
  end

  def provider_auth_failure(_reason, provider) do
    {:provider_auth_failed, provider_auth_details(%{}, provider)}
  end

  @doc """
  Format a redacted provider-auth failure for logs, claim leases, and status.
  """
  @spec provider_auth_failure_summary(term()) :: String.t()
  def provider_auth_failure_summary(reason) do
    details =
      case reason do
        {:provider_auth_failed, details} -> provider_auth_details(details, provider())
        {:auth_failed, details} -> provider_auth_details(details, provider())
        {:workspace_hook_failed, "before_run", _status, _output} -> provider_auth_failure(reason) |> elem(1)
        details when is_map(details) -> provider_auth_details(details, provider())
        _ -> provider_auth_details(%{}, provider())
      end

    provider = Map.get(details, :provider) || "unknown"
    status = Map.get(details, :api_error_status)
    subtype = Map.get(details, :subtype)

    [
      "provider_auth_failed:",
      to_string(provider),
      provider_auth_status_fragment(status),
      provider_auth_subtype_fragment(subtype)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # Carry the provider session id forward for adapters (Claude Code) that run a
  # fresh process per turn and resume by session id. Codex keeps one long-lived
  # thread, so its session struct is returned unchanged.
  defp advance_session(session, %{session_id: session_id})
       when is_map_key(session, :claude_session_id) and is_binary(session_id) do
    %{session | claude_session_id: session_id}
  end

  defp advance_session(session, _turn_result), do: session

  defp provider_auth_details(details, provider) when is_map(details) do
    %{
      provider: provider_auth_provider(Map.get(details, :provider) || Map.get(details, "provider") || provider),
      api_error_status:
        provider_auth_status(
          Map.get(details, :api_error_status) ||
            Map.get(details, "api_error_status") ||
            Map.get(details, :status) ||
            Map.get(details, "status")
        ),
      subtype: provider_auth_subtype(Map.get(details, :subtype) || Map.get(details, "subtype")),
      remediation_hint: provider_auth_safe_fragment(Map.get(details, :remediation_hint) || Map.get(details, "remediation_hint")),
      affected_role: provider_auth_safe_fragment(Map.get(details, :affected_role) || Map.get(details, "affected_role"))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp provider_auth_details(_details, provider), do: provider_auth_details(%{}, provider)

  defp provider_auth_hook_details(output) do
    output
    |> hook_output_lines()
    |> Enum.find_value(fn line ->
      provider_auth_json_details(line) || provider_auth_summary_details(line)
    end)
  end

  defp hook_output_lines(output) do
    binary_output = IO.iodata_to_binary(output)

    binary_output
    |> binary_part(0, min(byte_size(binary_output), 16_384))
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp provider_auth_json_details(line) when is_binary(line) do
    with {:ok, %{} = payload} <- Jason.decode(line),
         true <- provider_auth_payload?(payload) do
      payload
    else
      _ -> nil
    end
  end

  defp provider_auth_payload?(payload) when is_map(payload) do
    marker =
      Map.get(payload, "kind") ||
        Map.get(payload, "type") ||
        Map.get(payload, "event") ||
        Map.get(payload, "reason")

    marker in ["provider_auth_failed", "provider_auth_failure", "auth_failed"]
  end

  defp provider_auth_summary_details(line) when is_binary(line) do
    case Regex.run(~r/provider_auth_failed:\s+([a-zA-Z0-9_.:-]+)(?:\s+status=(\d{3}))?(?:\s+subtype=([a-zA-Z0-9_.:-]+))?/, line) do
      [_, provider, status, subtype] ->
        %{provider: provider, api_error_status: status, subtype: subtype}

      [_, provider, status] ->
        %{provider: provider, api_error_status: status}

      [_, provider] ->
        %{provider: provider}

      _ ->
        nil
    end
  end

  defp provider_auth_provider(provider) when provider in [:codex, :claude_code], do: provider

  defp provider_auth_provider(provider) when is_binary(provider) do
    case String.trim(provider) do
      "claude_code" -> :claude_code
      "codex" -> :codex
      _ -> nil
    end
  end

  defp provider_auth_provider(_provider), do: nil

  defp provider_auth_status(status) when status in [401, 403], do: status

  defp provider_auth_status(status) when is_binary(status) do
    case Integer.parse(String.trim(status)) do
      {status, ""} -> provider_auth_status(status)
      _ -> nil
    end
  end

  defp provider_auth_status(_status), do: nil

  defp provider_auth_subtype(subtype) when is_binary(subtype) do
    subtype
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_.:-]/, "_")
    |> String.slice(0, 80)
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp provider_auth_subtype(_subtype), do: nil

  defp provider_auth_safe_fragment(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9 ._:@\/+-]/, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp provider_auth_safe_fragment(_value), do: nil

  defp provider_auth_status_fragment(status) when is_integer(status), do: "status=#{status}"
  defp provider_auth_status_fragment(_status), do: ""

  defp provider_auth_subtype_fragment(subtype) when is_binary(subtype), do: "subtype=#{subtype}"
  defp provider_auth_subtype_fragment(_subtype), do: ""
end
