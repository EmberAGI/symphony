defmodule SymphonyElixir.RuntimeEvidence do
  @moduledoc """
  Owns secret-safe normalization for bounded runtime evidence.

  Callers remain responsible for bounding output before persistence or logging.
  This module removes credential-shaped values consistently at every runtime,
  hook, tracker, and provider boundary.
  """

  @spec sanitize_text(term()) :: term()
  def sanitize_text(value) when is_binary(value) do
    value
    |> String.replace(~r/(?i)\b(authorization)\s*[:=]\s*bearer\s+[^\s,\]}]+/, "\\1=[REDACTED]")
    |> String.replace(
      ~r/(?i)(["']?)(api[_-]?key|refresh[_-]?token|access[_-]?token|oauth[_-]?token|token|secret|password)\1\s*[:=]\s*(["'])[^"']*\3/,
      "credential=[REDACTED]"
    )
    |> String.replace(
      ~r/(?i)\b(api[_-]?key|refresh[_-]?token|access[_-]?token|oauth[_-]?token|token|secret|password)\s*[:=]\s*[^\s,\]}]+/,
      "credential=[REDACTED]"
    )
    |> String.replace(
      ~r/(?i)\b(api[\s_-]?key|refresh[\s_-]?token|access[\s_-]?token|oauth[\s_-]?token)\s+["']?[^\s,\]}]+["']?/,
      "credential=[REDACTED]"
    )
    |> String.replace(~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/-]+=*/, "[REDACTED]")
    |> String.replace(~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, "[REDACTED_EMAIL]")
  end

  def sanitize_text(value), do: value
end
