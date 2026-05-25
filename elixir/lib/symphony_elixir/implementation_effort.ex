defmodule SymphonyElixir.ImplementationEffort do
  @moduledoc """
  Parses Linear Implementation Effort labels and derives Codex reasoning.
  """

  alias SymphonyElixir.Linear.Issue

  @prefix "implementation-effort:"
  @default_effort "high"
  @dynamic_roles ~w(implementer reviewer qa)
  @profiles %{
    "extreme" => %{reviewer: "xhigh", worker: "high"},
    "high" => %{reviewer: "xhigh", worker: "high"},
    "moderate" => %{reviewer: "high", worker: "medium"},
    "low" => %{reviewer: "medium", worker: "low"},
    "minimal" => %{reviewer: "low", worker: "none"}
  }

  @type profile :: %{
          effort: String.t(),
          source: String.t(),
          role: String.t() | nil,
          reasoning_effort: String.t()
        }

  @spec parse_labels([String.t()]) :: {:ok, profile()} | {:error, term()}
  def parse_labels(labels) when is_list(labels) do
    labels
    |> implementation_effort_labels()
    |> classify_labels()
  end

  def parse_labels(_labels), do: {:ok, default_profile()}

  @spec profile_for_issue(Issue.t(), String.t() | nil) :: {:ok, profile()} | {:error, term()}
  def profile_for_issue(%Issue{labels: labels}, role) do
    with {:ok, profile} <- parse_labels(labels) do
      {:ok, role_profile(profile, role)}
    end
  end

  def profile_for_issue(_issue, role) do
    {:ok, role_profile(default_profile(), role)}
  end

  @spec command_for_issue(String.t(), Issue.t(), String.t() | nil) :: {:ok, {String.t(), profile()}} | {:error, term()}
  def command_for_issue(command, %Issue{} = issue, role) when is_binary(command) do
    with {:ok, profile} <- profile_for_issue(issue, role) do
      normalized_role = normalize_role(role)

      if normalized_role in @dynamic_roles do
        {:ok, {put_reasoning_effort(command, profile.reasoning_effort), profile}}
      else
        {:ok, {command, profile}}
      end
    end
  end

  def command_for_issue(command, _issue, role) when is_binary(command) do
    {:ok, {command, role_profile(default_profile(), role)}}
  end

  @spec valid_labels?(Issue.t()) :: boolean()
  def valid_labels?(%Issue{} = issue) do
    match?({:ok, _profile}, profile_for_issue(issue, nil))
  end

  def valid_labels?(_issue), do: true

  defp implementation_effort_labels(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.filter(&String.starts_with?(&1, @prefix))
  end

  defp classify_labels([]), do: {:ok, default_profile()}

  defp classify_labels(labels) do
    {supported, unsupported} =
      Enum.split_with(labels, fn label ->
        label
        |> String.replace_prefix(@prefix, "")
        |> then(&Map.has_key?(@profiles, &1))
      end)

    cond do
      unsupported != [] ->
        {:error, {:invalid_implementation_effort_labels, unsupported}}

      length(supported) > 1 ->
        {:error, {:ambiguous_implementation_effort_labels, supported}}

      true ->
        [label] = supported
        effort = String.replace_prefix(label, @prefix, "")
        {:ok, profile(effort, "label")}
    end
  end

  defp default_profile, do: profile(@default_effort, "default")

  defp profile(effort, source) do
    %{
      effort: effort,
      source: source,
      role: nil,
      reasoning_effort: Map.fetch!(@profiles, effort).worker
    }
  end

  defp role_profile(profile, role) do
    normalized_role = normalize_role(role)
    reasoning = reasoning_for_role(profile.effort, normalized_role)

    %{profile | role: normalized_role, reasoning_effort: reasoning}
  end

  defp reasoning_for_role(effort, "reviewer"), do: Map.fetch!(@profiles, effort).reviewer
  defp reasoning_for_role(effort, "implementer"), do: Map.fetch!(@profiles, effort).worker
  defp reasoning_for_role(effort, "qa"), do: Map.fetch!(@profiles, effort).worker
  defp reasoning_for_role(effort, _role), do: Map.fetch!(@profiles, effort).worker

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(_label), do: ""

  defp normalize_role(role) when is_binary(role) do
    role
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_role(_role), do: nil

  defp put_reasoning_effort(command, reasoning_effort) do
    replacement = "--config model_reasoning_effort=#{reasoning_effort}"

    cond do
      Regex.match?(~r/--config\s+['"]?model_reasoning_effort=/, command) ->
        Regex.replace(
          ~r/(--config\s+['"]?model_reasoning_effort=)[^'"\s]+(['"]?)/,
          command,
          "\\1#{reasoning_effort}\\2"
        )

      Regex.match?(~r/\sapp-server(\s*)$/, command) ->
        Regex.replace(~r/\sapp-server(\s*)$/, command, " #{replacement} app-server\\1")

      true ->
        "#{command} #{replacement}"
    end
  end
end
