defmodule SymphonyElixir.ClaudeCode.ModelAttestation do
  @moduledoc """
  Verifies the provider-observed Claude model against the exact model selected
  by Symphony's resolved runtime profile.

  Bare Claude aliases are normalized only to their canonical current model.
  Provider routing prefixes and a trailing dated build suffix do not change a
  model's identity. Missing, malformed, or different identities fail closed.
  """

  @aliases %{
    "fable" => "claude-fable-5",
    "opus" => "claude-opus-5",
    "sonnet" => "claude-sonnet-4-6",
    "haiku" => "claude-haiku-4-5"
  }

  @type failure ::
          {:claude_model_missing, %{requested_model: String.t(), observed_model: nil}}
          | {:claude_model_malformed, %{requested_model: String.t(), observed_model: term()}}
          | {:claude_model_mismatched, %{requested_model: String.t(), observed_model: String.t()}}

  @spec verify(term(), term()) :: :ok | {:error, failure()}
  def verify(requested_model, observed_model) do
    with {:ok, requested} <- canonical_requested(requested_model),
         {:ok, observed} <- canonical_observed(requested_model, observed_model) do
      if requested == observed do
        :ok
      else
        {:error, {:claude_model_mismatched, %{requested_model: requested_model, observed_model: observed_model}}}
      end
    end
  end

  defp canonical_requested(model) when is_binary(model) do
    case canonical(model) do
      nil -> {:error, {:claude_model_malformed, %{requested_model: model, observed_model: nil}}}
      canonical -> {:ok, canonical}
    end
  end

  defp canonical_requested(model),
    do: {:error, {:claude_model_malformed, %{requested_model: inspect(model), observed_model: nil}}}

  defp canonical_observed(requested_model, nil),
    do: {:error, {:claude_model_missing, %{requested_model: requested_model, observed_model: nil}}}

  defp canonical_observed(requested_model, observed_model) when is_binary(observed_model) do
    case canonical(observed_model) do
      nil ->
        {:error, {:claude_model_malformed, %{requested_model: requested_model, observed_model: observed_model}}}

      canonical ->
        {:ok, canonical}
    end
  end

  defp canonical_observed(requested_model, observed_model),
    do: {:error, {:claude_model_malformed, %{requested_model: requested_model, observed_model: observed_model}}}

  defp canonical(model) do
    normalized = model |> String.trim() |> String.downcase()
    normalized = Map.get(@aliases, normalized, normalized)

    case Regex.run(~r/(claude-[a-z]+-\d+(?:-\d+)?)(?:-\d{8})?$/, normalized) do
      [_, identity] -> identity
      _ -> nil
    end
  end
end
