defmodule SymphonyElixir.ClaudeCode.ProviderAuth do
  @moduledoc false

  @local_env_names ~w(CLAUDE_CODE_OAUTH_TOKEN)

  @doc "Project non-blank allowlisted Claude provider-auth values from the local process."
  @spec local_env() :: %{optional(String.t()) => String.t()}
  def local_env do
    @local_env_names
    |> Enum.flat_map(&local_env_entry/1)
    |> Map.new()
  end

  defp local_env_entry(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        if String.trim(value) == "", do: [], else: [{name, value}]

      _ ->
        []
    end
  end
end
