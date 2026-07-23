defmodule SymphonyElixir.Tracker.EscalationMarker do
  @moduledoc """
  Bounded, machine-readable identity for an irrecoverable runtime escalation.

  The marker is embedded in the operator note so an Adapter can reconcile a
  previously-created note before issuing any further tracker mutations.
  """

  @marker_start "<!-- symphony-irrecoverable-escalation:v1 -->"
  @marker_end "<!-- /symphony-irrecoverable-escalation -->"
  @kind "symphony_irrecoverable_escalation"
  @version 1
  @max_token_bytes 128
  @max_note_bytes 4_096
  @max_fingerprint_bytes 2_048
  @token_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/-]*\z/

  alias SymphonyElixir.RuntimeEvidence

  defstruct [:key, :failure_fingerprint, :retry_epoch, :run_id, :operator_note]

  @type t :: %__MODULE__{
          key: String.t(),
          failure_fingerprint: String.t(),
          retry_epoch: String.t(),
          run_id: String.t(),
          operator_note: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, failure_fingerprint} <- normalize_fingerprint(value_for(attrs, :failure_fingerprint)),
         {:ok, retry_epoch} <- normalize_token(value_for(attrs, :retry_epoch), :retry_epoch),
         {:ok, run_id} <- normalize_token(value_for(attrs, :run_id), :run_id),
         {:ok, operator_note} <- normalize_note(value_for(attrs, :operator_note)) do
      {:ok,
       %__MODULE__{
         key: digest([failure_fingerprint, retry_epoch]),
         failure_fingerprint: failure_fingerprint,
         retry_epoch: retry_epoch,
         run_id: run_id,
         operator_note: operator_note
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_escalation_attributes}

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = marker) do
    payload = %{
      "kind" => @kind,
      "version" => @version,
      "key" => marker.key,
      "failure_fingerprint" => marker.failure_fingerprint,
      "retry_epoch" => marker.retry_epoch,
      "run_id" => marker.run_id
    }

    marker.operator_note <>
      "\n\n" <>
      @marker_start <>
      "\n" <>
      Jason.encode!(payload, pretty: true) <>
      "\n" <>
      @marker_end
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, atom()}
  def parse(body) when is_binary(body) do
    with [_, encoded_payload] <- Regex.run(marker_regex(), body),
         {:ok, payload} <- Jason.decode(String.trim(encoded_payload)),
         true <- marker_payload?(payload),
         {:ok, marker} <- new(Map.put(payload, "operator_note", "parsed")),
         true <- marker.key == payload["key"] do
      {:ok, marker}
    else
      _ -> {:error, :invalid_escalation_marker}
    end
  end

  def parse(_body), do: {:error, :invalid_escalation_marker}

  @spec find([map()], String.t()) :: t() | nil
  def find(comments, key) when is_list(comments) and is_binary(key) do
    Enum.find_value(comments, &marker_for_key(&1, key))
  end

  def find(_comments, _key), do: nil

  defp marker_for_key(comment, key) do
    with body when is_binary(body) <- comment_body(comment),
         {:ok, %__MODULE__{key: ^key} = marker} <- parse(body) do
      marker
    else
      _ -> nil
    end
  end

  defp marker_regex do
    ~r/#{Regex.escape(@marker_start)}\s*(.*?)\s*#{Regex.escape(@marker_end)}/s
  end

  defp marker_payload?(%{"kind" => @kind, "version" => @version} = payload) do
    is_binary(payload["key"]) and is_binary(payload["failure_fingerprint"]) and
      is_binary(payload["retry_epoch"]) and is_binary(payload["run_id"])
  end

  defp marker_payload?(_payload), do: false

  defp comment_body(%{body: body}), do: body
  defp comment_body(%{"body" => body}), do: body
  defp comment_body(_comment), do: nil

  defp value_for(attrs, key) when is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp normalize_fingerprint(nil), do: {:error, :invalid_failure_fingerprint}

  defp normalize_fingerprint(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :invalid_failure_fingerprint}
      not String.valid?(value) -> {:error, :invalid_failure_fingerprint}
      byte_size(value) > @max_fingerprint_bytes -> {:error, :failure_fingerprint_too_large}
      Regex.match?(@token_pattern, value) -> {:ok, value}
      true -> {:ok, digest([value])}
    end
  end

  defp normalize_fingerprint(value) do
    encoded = :erlang.term_to_binary(value, [:compressed])

    if byte_size(encoded) <= @max_fingerprint_bytes do
      {:ok, digest([encoded])}
    else
      {:error, :failure_fingerprint_too_large}
    end
  catch
    _, _ -> {:error, :invalid_failure_fingerprint}
  end

  defp normalize_token(value, field) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, {:missing_escalation_field, field}}
      not String.valid?(value) -> {:error, {:invalid_escalation_field, field}}
      byte_size(value) > @max_token_bytes -> {:error, {:escalation_field_too_large, field}}
      Regex.match?(@token_pattern, value) -> {:ok, value}
      true -> {:ok, digest([value])}
    end
  end

  defp normalize_token(_value, field), do: {:error, {:missing_escalation_field, field}}

  defp normalize_note(value) when is_binary(value) do
    value = value |> RuntimeEvidence.sanitize_text() |> String.trim()

    cond do
      value == "" -> {:error, :missing_operator_note}
      not String.valid?(value) -> {:error, :invalid_operator_note}
      byte_size(value) > @max_note_bytes -> {:error, :operator_note_too_large}
      true -> {:ok, value}
    end
  end

  defp normalize_note(_value), do: {:error, :missing_operator_note}

  defp digest(parts) do
    parts
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
