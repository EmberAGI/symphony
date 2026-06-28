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
  @type failure_family ::
          :provider_authentication_or_revocation
          | :missing_required_runtime_configuration
          | :missing_required_tool_or_cli
          | :permission_denied
          | :invalid_workspace_or_runtime_protocol
          | :unsupported_app_server_contract
          | :malformed_provider_event_schema
          | :repeated_identical_no_progress_failure

  @type failure_decision :: %{
          required(:family) => failure_family() | :retryable_runtime_failure,
          required(:summary) => String.t(),
          required(:retry_reason) => String.t(),
          required(:recovery_reason) => String.t() | nil,
          required(:retryable?) => boolean(),
          required(:irrecoverable?) => boolean(),
          optional(:provider) => provider(),
          optional(:subtype) => String.t(),
          optional(:fingerprint) => map()
        }
  @type failure_observation :: %{
          required(:fingerprint) => map() | nil,
          required(:count) => non_neg_integer(),
          required(:reset_marker) => map()
        }

  @irrecoverable_families [
    :provider_authentication_or_revocation,
    :missing_required_runtime_configuration,
    :missing_required_tool_or_cli,
    :permission_denied,
    :invalid_workspace_or_runtime_protocol,
    :unsupported_app_server_contract,
    :malformed_provider_event_schema,
    :repeated_identical_no_progress_failure
  ]

  @transient_markers [
    "transient",
    "network",
    "service_unavailable",
    "service unavailable",
    "rate_limit",
    "rate limit",
    "rate_limited",
    "timeout",
    "capacity",
    "operator_interrupted",
    "operator interrupted"
  ]

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
  Classify a provider/runtime failure before retry policy is applied.

  The returned decision is provider-neutral and safe for logs, claim leases,
  status surfaces, and Operator Notes. Provider adapters should still parse
  provider-native payloads at their own seam; callers should make retry versus
  escalation decisions from this typed result rather than raw process text.
  """
  @spec classify_failure(term(), map()) :: {:irrecoverable, failure_decision()} | {:retryable, failure_decision()}
  def classify_failure(reason, context \\ %{}) when is_map(context) do
    provider = runtime_provider(context)

    cond do
      irrecoverable_runtime_failed?(reason) ->
        {:irrecoverable, normalize_irrecoverable_runtime_failure(reason, context)}

      provider_auth_failure?(reason) ->
        {:irrecoverable,
         reason
         |> provider_auth_failure(provider)
         |> provider_auth_failure_decision(context)}

      real_irrecoverable_runtime_reason(reason) != nil ->
        {family, details} = real_irrecoverable_runtime_reason(reason)
        {:irrecoverable, irrecoverable_decision(family, details, context)}

      irrecoverable_family_reason?(reason) ->
        {family, details} = irrecoverable_family_reason(reason)
        {:irrecoverable, irrecoverable_decision(family, details, context)}

      transient_failure?(reason) ->
        {:retryable, retryable_decision(reason, context, :transient_runtime_failure)}

      true ->
        {:retryable, retryable_decision(reason, context, :retryable_runtime_failure)}
    end
  end

  @doc """
  Record a failed runtime observation and apply the persistent no-progress rule.

  The third consecutive identical no-progress fingerprint escalates immediately.
  Transient failures, different fingerprints, and changed reset markers restart
  the sequence.
  """
  @spec record_failure_observation(failure_observation() | nil, term(), map()) ::
          {failure_observation(), {:irrecoverable, failure_decision()} | {:retryable, failure_decision()}}
  def record_failure_observation(previous_observation, reason, context \\ %{}) when is_map(context) do
    case classify_failure(reason, context) do
      {:irrecoverable, failure} ->
        {observation_for(failure, context, 1), {:irrecoverable, failure}}

      {:retryable, failure} ->
        record_retryable_failure_observation(previous_observation, reason, failure, context)
    end
  end

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
    readiness_status = Map.get(details, :readiness_status)
    affected_roles = Map.get(details, :affected_roles) || Map.get(details, :affected_role)
    affected_provider = Map.get(details, :affected_provider)
    remediation_hint = Map.get(details, :remediation_hint)

    [
      "provider_auth_failed:",
      to_string(provider),
      provider_auth_status_fragment(status),
      provider_auth_subtype_fragment(subtype),
      provider_auth_named_fragment("readiness_status", readiness_status),
      provider_auth_named_fragment("affected_roles", affected_roles),
      provider_auth_named_fragment("affected_provider", affected_provider),
      provider_auth_named_fragment("remediation", remediation_hint)
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
    provider_value = provider_auth_detail(details, [:provider, "provider"]) || provider

    %{
      provider: provider_auth_provider(provider_value),
      api_error_status: provider_auth_status(provider_auth_detail(details, [:api_error_status, "api_error_status", :status, "status"])),
      subtype: provider_auth_subtype(provider_auth_detail(details, [:subtype, "subtype"])),
      remediation_hint: provider_auth_safe_fragment(provider_auth_detail(details, [:remediation_hint, "remediation_hint"])),
      affected_role: provider_auth_safe_fragment(provider_auth_detail(details, [:affected_role, "affected_role"])),
      affected_roles: provider_auth_safe_fragment(provider_auth_detail(details, [:affected_roles, "affected_roles"])),
      affected_provider: provider_auth_safe_fragment(provider_auth_detail(details, [:affected_provider, "affected_provider"])),
      readiness_status: provider_auth_subtype(provider_auth_detail(details, [:readiness_status, "readiness_status"]))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp provider_auth_details(_details, provider), do: provider_auth_details(%{}, provider)

  defp provider_auth_detail(details, keys) when is_map(details) and is_list(keys) do
    Enum.find_value(keys, &Map.get(details, &1))
  end

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
    cond do
      match = Regex.run(~r/provider_auth_failed:\s+([a-zA-Z0-9_.:-]+)(?:\s+status=(\d{3}))?(?:\s+subtype=([a-zA-Z0-9_.:-]+))?/, line) ->
        case match do
          [_, provider, status, subtype] ->
            %{provider: provider, api_error_status: status, subtype: subtype}

          [_, provider, status] ->
            %{provider: provider, api_error_status: status}

          [_, provider] ->
            %{provider: provider}
        end

      Regex.match?(~r/provider-auth/i, line) ->
        provider_auth_key_value_details(line)

      true ->
        nil
    end
  end

  defp provider_auth_key_value_details(line) do
    fields = provider_auth_key_values(line)
    provider = Map.get(fields, "provider")

    case provider_auth_provider(provider) do
      nil ->
        nil

      _provider ->
        %{
          provider: provider,
          readiness_status: Map.get(fields, "status"),
          affected_roles: Map.get(fields, "affected_roles"),
          affected_role: Map.get(fields, "affected_role"),
          affected_provider: Map.get(fields, "affected_provider") || Map.get(fields, "role_provider"),
          remediation_hint: Map.get(fields, "remediation") || Map.get(fields, "remediation_hint")
        }
    end
  end

  defp provider_auth_key_values(line) do
    ~r/(?:^|\s)([a-zA-Z_][a-zA-Z0-9_]*)=(.*?)(?=\s+[a-zA-Z_][a-zA-Z0-9_]*=|$)/
    |> Regex.scan(line)
    |> Enum.reduce(%{}, fn [_match, key, value], acc ->
      Map.put(acc, key, String.trim(value))
    end)
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
    |> String.replace(~r/[^a-zA-Z0-9 ._:@\/+,-]/, "_")
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

  defp provider_auth_named_fragment(key, value) when is_binary(value), do: "#{key}=#{value}"
  defp provider_auth_named_fragment(_key, _value), do: ""

  defp provider_auth_failure_decision({:provider_auth_failed, details}, context) do
    family = :provider_authentication_or_revocation
    provider = Map.get(details, :provider) || runtime_provider(context)
    subtype = Map.get(details, :subtype)
    retry_reason = provider_auth_failure_summary({:provider_auth_failed, details})

    summary =
      family
      |> Atom.to_string()
      |> Kernel.<>(": ")
      |> Kernel.<>(retry_reason)
      |> redact_runtime_text()

    decision(family, summary, context,
      provider: provider,
      subtype: subtype,
      retryable?: false,
      retry_reason: retry_reason,
      recovery_reason: "provider-authentication-required"
    )
  end

  defp irrecoverable_family_reason?({family, _details}) when family in @irrecoverable_families, do: true
  defp irrecoverable_family_reason?(family) when family in @irrecoverable_families, do: true
  defp irrecoverable_family_reason?({:workspace_hook_failed, _hook, status, output}), do: workspace_hook_irrecoverable_family(status, output) != nil
  defp irrecoverable_family_reason?(_reason), do: false

  defp irrecoverable_family_reason({family, details}) when family in @irrecoverable_families, do: {family, details}
  defp irrecoverable_family_reason(family) when family in @irrecoverable_families, do: {family, %{}}

  defp irrecoverable_family_reason({:workspace_hook_failed, hook, status, output}) do
    family = workspace_hook_irrecoverable_family(status, output)

    {family,
     %{
       subtype: "workspace_hook_failed",
       method: hook,
       message: workspace_hook_summary(output)
     }}
  end

  defp real_irrecoverable_runtime_reason({:invalid_workspace_cwd, subtype, worker_host, workspace}) do
    details =
      case subtype do
        :invalid_remote_workspace ->
          %{
            subtype: subtype,
            path: workspace,
            message: "remote runtime workspace path is invalid for #{safe_detail_fragment(worker_host)}"
          }

        _ ->
          %{
            subtype: subtype,
            path: worker_host,
            message: "runtime workspace path is outside the configured workspace root #{safe_detail_fragment(workspace)}"
          }
      end

    {:invalid_workspace_or_runtime_protocol, details}
  end

  defp real_irrecoverable_runtime_reason({:invalid_workspace_cwd, subtype, path}) do
    {:invalid_workspace_or_runtime_protocol,
     %{
       subtype: subtype,
       path: path,
       message: "runtime workspace path is invalid"
     }}
  end

  defp real_irrecoverable_runtime_reason(:bash_not_found) do
    {:missing_required_tool_or_cli, %{tool: "bash", message: "bash executable not found"}}
  end

  defp real_irrecoverable_runtime_reason({:port_exit, 127, output}) do
    if missing_tool_output?(output) do
      {:missing_required_tool_or_cli, %{message: workspace_hook_summary(output)}}
    end
  end

  defp real_irrecoverable_runtime_reason({:port_exit, 126, output}) do
    if permission_denied_output?(output) do
      {:permission_denied, %{message: workspace_hook_summary(output)}}
    end
  end

  defp real_irrecoverable_runtime_reason({:unsupported_runtime_provider, provider}) do
    {:missing_required_runtime_configuration, %{name: "agent_runtime.provider", message: "unsupported runtime provider #{safe_detail_fragment(provider)}"}}
  end

  defp real_irrecoverable_runtime_reason({:unsafe_turn_sandbox_policy, details}) do
    {:missing_required_runtime_configuration,
     %{
       name: "agent_runtime.permission_policy",
       subtype: "unsafe_turn_sandbox_policy",
       message: detail_summary(details)
     }}
  end

  defp real_irrecoverable_runtime_reason({:turn_failed, details}) when is_map(details) do
    subtype = subtype_from_details(details)

    cond do
      subtype == "unsupported_app_server_contract" ->
        {:unsupported_app_server_contract, details}

      subtype == "malformed_provider_event_schema" ->
        {:malformed_provider_event_schema, details}

      true ->
        nil
    end
  end

  defp real_irrecoverable_runtime_reason(_reason), do: nil

  defp irrecoverable_decision(family, details, context) do
    provider = provider_from_details(details) || runtime_provider(context)
    subtype = subtype_from_details(details)
    summary = irrecoverable_summary(family, details, provider, subtype)

    decision(family, summary, context,
      provider: provider,
      subtype: subtype,
      retryable?: false,
      recovery_reason: recovery_reason(family)
    )
  end

  defp retryable_decision(reason, context, family) do
    summary =
      [
        Atom.to_string(family),
        detail_summary(reason)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(": ")
      |> redact_runtime_text()

    decision(family, summary, context,
      provider: runtime_provider(context),
      subtype: subtype_from_details(reason),
      retryable?: true,
      recovery_reason: nil
    )
  end

  defp record_retryable_failure_observation(previous_observation, reason, failure, context) do
    cond do
      transient_failure?(reason) ->
        {reset_observation(context), {:retryable, failure}}

      no_progress_failure?(reason) ->
        no_progress_failure =
          irrecoverable_decision(:repeated_identical_no_progress_failure, no_progress_details(reason), context)

        count = next_observation_count(previous_observation, no_progress_failure, context)
        observation = observation_for(no_progress_failure, context, count)

        if count >= 3 do
          {observation, {:irrecoverable, no_progress_failure}}
        else
          {observation, {:retryable, failure}}
        end

      true ->
        {observation_for(failure, context, 1), {:retryable, failure}}
    end
  end

  defp next_observation_count(previous_observation, failure, context) when is_map(previous_observation) do
    reset_marker = reset_marker(context)

    if Map.get(previous_observation, :fingerprint) == failure.fingerprint and
         Map.get(previous_observation, :reset_marker) == reset_marker do
      Map.get(previous_observation, :count, 0) + 1
    else
      1
    end
  end

  defp next_observation_count(_previous_observation, _failure, _context), do: 1

  defp observation_for(failure, context, count) when is_map(failure) do
    %{
      fingerprint: Map.get(failure, :fingerprint),
      count: max(count, 0),
      reset_marker: reset_marker(context)
    }
  end

  defp reset_observation(context) do
    %{fingerprint: nil, count: 0, reset_marker: reset_marker(context)}
  end

  defp reset_marker(context) do
    %{
      retry_epoch: context_string(context, :retry_epoch),
      claim_lease_run_id: context_string(context, :claim_lease_run_id) || context_string(context, :run_id),
      input_fingerprint: context_string(context, :input_fingerprint),
      operator_repair_id: context_string(context, :operator_repair_id)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp decision(family, summary, context, opts) do
    provider = Keyword.get(opts, :provider)
    subtype = Keyword.get(opts, :subtype)
    retryable? = Keyword.fetch!(opts, :retryable?)

    %{
      family: family,
      provider: provider,
      subtype: subtype,
      summary: summary,
      retry_reason: Keyword.get(opts, :retry_reason, summary),
      recovery_reason: Keyword.get(opts, :recovery_reason),
      retryable?: retryable?,
      irrecoverable?: !retryable?,
      fingerprint: failure_fingerprint(family, provider, subtype, summary, context)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp failure_fingerprint(family, provider, subtype, summary, context) do
    %{
      issue_id: context_string(context, :issue_id),
      workspace_path: context_string(context, :workspace_path),
      role: context_string(context, :role) || role_name(),
      runtime_provider: provider,
      family: family,
      subtype: subtype,
      summary: summary
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp irrecoverable_summary(family, details, provider, subtype) do
    [
      Atom.to_string(family),
      provider && to_string(provider),
      subtype && "subtype=#{subtype}",
      detail_summary(details)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> redact_runtime_text()
  end

  defp detail_summary(details) when is_map(details) do
    [
      value_for_any(details, [:name, "name"]),
      value_for_any(details, [:tool, "tool", :cli, "cli"]),
      value_for_any(details, [:path, "path"]),
      value_for_any(details, [:method, "method"]),
      value_for_any(details, [:event, "event"]),
      value_for_any(details, [:summary, "summary"]),
      value_for_any(details, [:message, "message"])
    ]
    |> Enum.map(&safe_detail_fragment/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp detail_summary({reason, details}) when is_atom(reason) do
    [Atom.to_string(reason), detail_summary(details)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp detail_summary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp detail_summary(reason) when is_binary(reason), do: safe_detail_fragment(reason)
  defp detail_summary(reason), do: reason |> inspect(limit: 20, printable_limit: 200) |> safe_detail_fragment()

  defp safe_detail_fragment(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.slice(0, 180)
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp safe_detail_fragment(nil), do: nil
  defp safe_detail_fragment(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_detail_fragment(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_detail_fragment(_value), do: nil

  defp transient_failure?(:turn_timeout), do: true
  defp transient_failure?({:turn_timeout, _details}), do: true
  defp transient_failure?({:network_error, _details}), do: true
  defp transient_failure?({:service_unavailable, _details}), do: true
  defp transient_failure?({:rate_limited, _details}), do: true
  defp transient_failure?({:capacity_unavailable, _details}), do: true
  defp transient_failure?({:operator_interrupted, _details}), do: true

  defp transient_failure?(reason) do
    reason
    |> detail_summary()
    |> String.downcase()
    |> then(fn summary -> Enum.any?(@transient_markers, &String.contains?(summary, &1)) end)
  end

  defp no_progress_failure?({:empty_turn_completed, _details}), do: true
  defp no_progress_failure?({:turn_input_required, _details}), do: true
  defp no_progress_failure?({:approval_required, _details}), do: true
  defp no_progress_failure?(:empty_turn_completed), do: true
  defp no_progress_failure?(:turn_input_required), do: true
  defp no_progress_failure?(:approval_required), do: true
  defp no_progress_failure?(_reason), do: false

  defp no_progress_details({subtype, details}) when is_atom(subtype) and is_map(details) do
    Map.put(details, :subtype, Atom.to_string(subtype))
  end

  defp no_progress_details(subtype) when is_atom(subtype), do: %{subtype: Atom.to_string(subtype)}

  defp irrecoverable_runtime_failed?({:irrecoverable_runtime_failed, failure}) when is_map(failure), do: true
  defp irrecoverable_runtime_failed?(_reason), do: false

  defp normalize_irrecoverable_runtime_failure({:irrecoverable_runtime_failed, failure}, context) when is_map(failure) do
    failure
    |> Map.put_new(:retryable?, false)
    |> Map.put_new(:irrecoverable?, true)
    |> Map.put_new(:fingerprint, failure_fingerprint(failure.family, Map.get(failure, :provider), Map.get(failure, :subtype), failure.retry_reason, context))
  end

  defp workspace_hook_irrecoverable_family(127, output) do
    if missing_tool_output?(output), do: :missing_required_tool_or_cli
  end

  defp workspace_hook_irrecoverable_family(126, output) do
    if permission_denied_output?(output), do: :permission_denied
  end

  defp workspace_hook_irrecoverable_family(_status, output) do
    cond do
      missing_tool_output?(output) -> :missing_required_tool_or_cli
      permission_denied_output?(output) -> :permission_denied
      true -> nil
    end
  end

  defp missing_tool_output?(output) do
    output
    |> workspace_hook_summary()
    |> String.downcase()
    |> then(&(String.contains?(&1, "command not found") or String.contains?(&1, "no such file or directory")))
  end

  defp permission_denied_output?(output) do
    output
    |> workspace_hook_summary()
    |> String.downcase()
    |> String.contains?("permission denied")
  end

  defp workspace_hook_summary(output) do
    output
    |> hook_output_lines()
    |> List.first("")
  end

  defp recovery_reason(:provider_authentication_or_revocation), do: "provider-authentication-required"
  defp recovery_reason(family), do: family |> Atom.to_string() |> String.replace("_", "-") |> Kernel.<>("-repair-required")

  defp provider_from_details(details) when is_map(details) do
    details
    |> value_for_any([:provider, "provider", :runtime_provider, "runtime_provider"])
    |> provider_auth_provider()
  end

  defp provider_from_details(_details), do: nil

  defp subtype_from_details(details) when is_map(details) do
    details
    |> value_for_any([:subtype, "subtype", :reason, "reason", :code, "code"])
    |> provider_auth_subtype()
  end

  defp subtype_from_details({_reason, details}), do: subtype_from_details(details)
  defp subtype_from_details(_details), do: nil

  defp runtime_provider(context) when is_map(context) do
    context
    |> value_for_any([:provider, "provider", :runtime_provider, "runtime_provider"])
    |> provider_auth_provider()
    |> case do
      nil -> provider()
      provider -> provider
    end
  end

  defp context_string(context, key) when is_map(context) do
    context
    |> value_for_any([key, Atom.to_string(key)])
    |> safe_detail_fragment()
  end

  defp value_for_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp redact_runtime_text(value) when is_binary(value) do
    value
    |> String.replace(~r/(?i)\b(authorization)\s*[:=]\s*bearer\s+[^\s,\]}]+/, "\\1=[REDACTED]")
    |> String.replace(~r/(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,\]}]+/, "credential=[REDACTED]")
    |> String.replace(~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/-]+=*/, "[REDACTED]")
    |> String.replace(~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, "[REDACTED_EMAIL]")
  end

  defp redact_runtime_text(value), do: value

  defp role_name do
    case System.get_env("SYMPHONY_ROLE") do
      role when is_binary(role) and role != "" -> role
      _ -> "implementer"
    end
  end
end
