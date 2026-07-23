defmodule SymphonyElixir.Workspace.HookResult do
  @moduledoc """
  Bounded machine-readable failure emitted by a Symphony workspace hook.

  Wrapper hooks may print this JSON payload as one output line. Legacy hook
  output remains supported and is classified by the existing runtime rules.
  """

  @kind "symphony_workspace_hook_result"
  @version 1
  @max_summary_bytes 512
  @default_retry_limit 3
  @max_retry_limit 10
  @deterministic_families [
    :provider_authentication_or_revocation,
    :missing_required_runtime_configuration,
    :missing_required_tool_or_cli,
    :permission_denied,
    :invalid_workspace_or_runtime_protocol,
    :unsupported_app_server_contract,
    :malformed_provider_event_schema,
    :human_input_required
  ]

  @enforce_keys [:hook, :classification, :family, :summary, :retry_limit]
  defstruct @enforce_keys

  @type classification :: :deterministic | :transient
  @type t :: %__MODULE__{
          hook: String.t(),
          classification: classification(),
          family: atom(),
          summary: String.t(),
          retry_limit: pos_integer()
        }

  @doc "Parse a typed hook failure from bounded command output when present."
  @spec parse_failure(String.t(), integer(), iodata()) :: {:ok, t()} | :not_typed
  def parse_failure(hook, _status, output) when is_binary(hook) do
    output = output |> IO.iodata_to_binary() |> truncate_output()

    case typed_payload(output) do
      {:ok, payload} -> normalize_payload(payload, hook)
      :not_typed -> :not_typed
      :malformed -> {:ok, malformed_result(hook)}
    end
  end

  @doc "Return true when this transient hook result has exhausted its retry ceiling."
  @spec retry_exhausted?(t(), non_neg_integer()) :: boolean()
  def retry_exhausted?(%__MODULE__{classification: :transient, retry_limit: limit}, count),
    do: count >= limit

  def retry_exhausted?(%__MODULE__{}, _count), do: false

  defp typed_payload(output) do
    typed_payloads =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(String.trim(line)) do
          {:ok, %{"kind" => @kind} = payload} -> [payload]
          _ -> []
        end
      end)

    case typed_payloads do
      [payload] -> {:ok, payload}
      [] -> if String.contains?(output, @kind), do: :malformed, else: :not_typed
      _duplicates -> :malformed
    end
  end

  defp normalize_payload(payload, hook) do
    with @version <- Map.get(payload, "version"),
         ^hook <- normalize_hook(Map.get(payload, "hook")),
         {:ok, classification} <- normalize_classification(Map.get(payload, "classification")),
         {:ok, family} <- normalize_family(Map.get(payload, "family"), classification),
         {:ok, summary} <- normalize_summary(Map.get(payload, "summary")),
         {:ok, retry_limit} <- normalize_retry_limit(Map.get(payload, "retry_limit")) do
      {:ok,
       %__MODULE__{
         hook: hook,
         classification: classification,
         family: family,
         summary: summary,
         retry_limit: retry_limit
       }}
    else
      _ -> {:ok, malformed_result(hook)}
    end
  end

  defp normalize_hook(value) when is_binary(value), do: String.trim(value)
  defp normalize_hook(_value), do: nil

  defp normalize_classification("deterministic"), do: {:ok, :deterministic}
  defp normalize_classification("transient"), do: {:ok, :transient}
  defp normalize_classification(_value), do: {:error, :invalid_classification}

  defp normalize_family(value, :deterministic) when is_binary(value) do
    family = Enum.find(@deterministic_families, &(Atom.to_string(&1) == value))
    if family, do: {:ok, family}, else: {:error, :invalid_family}
  end

  defp normalize_family("transient_workspace_hook_failure", :transient),
    do: {:ok, :transient_workspace_hook_failure}

  defp normalize_family(_value, :transient), do: {:error, :invalid_family}
  defp normalize_family(_value, _classification), do: {:error, :invalid_family}

  defp normalize_summary(value) when is_binary(value) do
    summary = value |> String.trim() |> redact()

    cond do
      summary == "" -> {:error, :missing_summary}
      not String.valid?(summary) -> {:error, :invalid_summary}
      byte_size(summary) > @max_summary_bytes -> {:error, :summary_too_large}
      true -> {:ok, summary}
    end
  end

  defp normalize_summary(_value), do: {:error, :missing_summary}

  defp normalize_retry_limit(nil), do: {:ok, @default_retry_limit}

  defp normalize_retry_limit(value)
       when is_integer(value) and value > 0 and value <= @max_retry_limit,
       do: {:ok, value}

  defp normalize_retry_limit(_value), do: {:error, :invalid_retry_limit}

  defp malformed_result(hook) do
    %__MODULE__{
      hook: hook,
      classification: :deterministic,
      family: :malformed_provider_event_schema,
      summary: "workspace hook emitted an invalid typed result",
      retry_limit: 1
    }
  end

  defp truncate_output(output) when byte_size(output) <= 4_096, do: output
  defp truncate_output(output), do: binary_part(output, 0, 4_096)

  defp redact(value) do
    value
    |> String.replace(~r/(?i)\b(authorization)\s*[:=]\s*bearer\s+[^\s,\]}]+/, "\\1=[REDACTED]")
    |> String.replace(~r/(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,\]}]+/, "credential=[REDACTED]")
    |> String.replace(~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/-]+=*/, "[REDACTED]")
  end
end
