defmodule SymphonyElixir.ImplementationEffort do
  @moduledoc """
  Parses Linear Implementation Effort labels and derives provider reasoning rows.
  """

  alias SymphonyElixir.Linear.Issue

  @prefix "implementation-effort:"
  @tiers ~w(extreme high moderate low minimal)
  @dynamic_roles ~w(implementer reviewer qa)
  @providers ~w(codex claude_code)
  @required_provider_keys ~w(default default_tier)
  @known_role_keys ~w(default implementer reviewer qa landing backlog-processor)
  @shared_efforts ~w(none low medium high xhigh max)
  @codex_supported_efforts ~w(none low medium high xhigh)
  @claude_xhigh_supported_models ~w(fable-5 mythos-5 opus-4-8 opus-4-7)
  @claude_max_supported_models ~w(fable-5 mythos-5 opus-4-8 opus-4-7 opus-4-6 sonnet-4-6)
  @claude_no_thinking_effort "low"
  @claude_model_alias_resolution %{
    "fable" => "claude-fable-5",
    "opus" => "claude-opus-4-8",
    "sonnet" => "claude-sonnet-4-6",
    "haiku" => "claude-haiku-4-5"
  }

  @built_in_profiles %{
    "codex" => %{
      "default_tier" => "high",
      "default" => "high",
      "implementer" => %{"extreme" => "high", "high" => "high", "moderate" => "medium", "low" => "low", "minimal" => "none"},
      "reviewer" => %{"extreme" => "xhigh", "high" => "xhigh", "moderate" => "high", "low" => "medium", "minimal" => "low"},
      "qa" => %{"extreme" => "xhigh", "high" => "xhigh", "moderate" => "high", "low" => "medium", "minimal" => "low"}
    },
    "claude_code" => %{
      "default_tier" => "moderate",
      "default" => "opus/high",
      "implementer" => %{
        "extreme" => "opus/xhigh",
        "high" => "opus/high",
        "moderate" => "sonnet/high",
        "low" => "sonnet/medium",
        "minimal" => "sonnet/none"
      },
      "reviewer" => %{
        "extreme" => "fable/xhigh",
        "high" => "fable/high",
        "moderate" => "opus/high",
        "low" => "sonnet/high",
        "minimal" => "sonnet/medium"
      },
      "qa" => %{
        "extreme" => "fable/xhigh",
        "high" => "fable/high",
        "moderate" => "opus/high",
        "low" => "sonnet/high",
        "minimal" => "sonnet/medium"
      }
    }
  }

  @type profile :: %{
          effort: String.t(),
          source: String.t(),
          role: String.t() | nil,
          reasoning_effort: String.t(),
          provider: String.t(),
          model: String.t() | nil,
          no_thinking: boolean()
        }

  @spec profiles() :: {:ok, map()} | {:error, term()}
  def profiles do
    case System.get_env("SYMPHONY_REASONING_PROFILES") do
      path when is_binary(path) and path != "" -> load_profiles(path)
      _ -> validate_profiles(@built_in_profiles, "built_in")
    end
  end

  @spec parse_labels([String.t()]) :: {:ok, profile()} | {:error, term()}
  def parse_labels(labels) when is_list(labels) do
    with {:ok, profiles} <- profiles(),
         {:ok, tier, source} <- label_tier(labels, default_tier(profiles, "codex"), invalid: :error) do
      {:ok, row_profile(profiles, "codex", tier, nil, source)}
    end
  end

  def parse_labels(_labels) do
    with {:ok, profiles} <- profiles() do
      tier = default_tier(profiles, "codex")
      {:ok, row_profile(profiles, "codex", tier, nil, "default")}
    end
  end

  @spec profile_for_issue(Issue.t(), String.t() | nil) :: {:ok, profile()} | {:error, term()}
  def profile_for_issue(issue, role), do: profile_for_issue("codex", issue, role)

  @spec profile_for_issue(String.t() | atom(), term(), String.t() | nil) :: {:ok, profile()} | {:error, term()}
  def profile_for_issue(provider, %Issue{labels: labels}, role) do
    provider = normalize_provider(provider)

    with {:ok, profiles} <- profiles(),
         {:ok, tier, source} <- issue_tier(provider, profiles, labels) do
      {:ok, row_profile(profiles, provider, tier, normalize_role(role), source)}
    end
  end

  def profile_for_issue(provider, _issue, role) do
    provider = normalize_provider(provider)

    with {:ok, profiles} <- profiles() do
      tier = default_tier(profiles, provider)
      {:ok, row_profile(profiles, provider, tier, normalize_role(role), "default")}
    end
  end

  @spec command_for_issue(String.t(), Issue.t(), String.t() | nil) :: {:ok, {String.t(), profile()}} | {:error, term()}
  def command_for_issue(command, %Issue{} = issue, role) when is_binary(command) do
    with {:ok, profile} <- profile_for_issue("codex", issue, role) do
      if profile.role in @dynamic_roles do
        {:ok, {put_codex_profile(command, profile), profile}}
      else
        {:ok, {command, profile}}
      end
    end
  end

  def command_for_issue(command, _issue, role) when is_binary(command) do
    with {:ok, profile} <- profile_for_issue("codex", nil, role) do
      {:ok, {command, profile}}
    end
  end

  @spec valid_labels?(Issue.t()) :: boolean()
  def valid_labels?(%Issue{} = issue) do
    match?({:ok, _profile}, profile_for_issue(issue, nil))
  end

  def valid_labels?(_issue), do: true

  defp load_profiles(path) do
    case Toml.decode_file(path) do
      {:ok, decoded} -> validate_profiles(decoded, path)
      {:error, reason} -> {:error, {:invalid_reasoning_profiles_toml, path, reason}}
    end
  end

  defp validate_profiles(%{"providers" => providers}, source) when is_map(providers) do
    with :ok <- validate_keys(Map.keys(providers), @providers, {:unknown_reasoning_profile_provider, source}),
         :ok <- validate_required_keys(Map.keys(providers), @providers, {:missing_reasoning_profile_provider, source}) do
      reduce_validated(@providers, fn provider ->
        validate_provider(provider, Map.fetch!(providers, provider), source)
      end)
    end
  end

  defp validate_profiles(profiles, source), do: validate_profiles(%{"providers" => profiles}, source)

  defp validate_provider(provider, config, source) when is_map(config) do
    keys = Map.keys(config)
    unknown_key_error = {:unknown_reasoning_profile_key, source, provider}
    missing_key_error = {:missing_reasoning_profile_key, source, provider}

    with :ok <- validate_keys(keys, @known_role_keys ++ ["default_tier"], unknown_key_error),
         :ok <- validate_required_keys(keys, @required_provider_keys, missing_key_error),
         {:ok, default_tier} <- fetch_default_tier(config, source, provider),
         {:ok, roles} <- validate_roles(provider, Map.drop(config, ["default_tier"]), source) do
      {:ok, Map.put(roles, "default_tier", default_tier)}
    end
  end

  defp validate_provider(provider, _config, source), do: {:error, {:invalid_reasoning_profile_provider_shape, source, provider}}

  defp fetch_default_tier(config, source, provider) do
    case Map.get(config, "default_tier") do
      tier when tier in @tiers -> {:ok, tier}
      tier -> {:error, {:invalid_reasoning_profile_default_tier, source, provider, tier}}
    end
  end

  defp validate_roles(provider, roles, source) do
    reduce_validated(Map.keys(roles), fn role ->
      validate_role(provider, role, Map.fetch!(roles, role), source)
    end)
  end

  defp validate_role(provider, role, cell, source) when is_binary(cell) do
    validate_cell(provider, cell, source, [role])
  end

  defp validate_role(provider, role, table, source) when is_map(table) do
    with :ok <- validate_keys(Map.keys(table), @tiers, {:unknown_reasoning_profile_tier, source, provider, role}),
         :ok <- validate_required_keys(Map.keys(table), @tiers, {:missing_reasoning_profile_tier, source, provider, role}) do
      reduce_validated(@tiers, fn tier ->
        validate_cell(provider, Map.fetch!(table, tier), source, [role, tier])
      end)
    end
  end

  defp validate_role(provider, role, _value, source),
    do: {:error, {:invalid_reasoning_profile_role_shape, source, provider, role}}

  defp validate_cell(provider, cell, source, path) when is_binary(cell) do
    with {:ok, model, effort} <- parse_cell(cell, source, provider, path),
         :ok <- validate_effort(provider, model, effort, source, path),
         :ok <- validate_model_effort(provider, model, effort, source, path),
         :ok <- validate_no_thinking(provider, model, effort, source, path) do
      {:ok, translated_cell(provider, model, effort)}
    end
  end

  defp validate_cell(provider, _cell, source, path), do: {:error, {:invalid_reasoning_profile_cell, source, provider, path}}

  defp parse_cell(cell, source, provider, path) do
    parts = String.split(cell, "/", parts: 3)

    case parts do
      [effort] ->
        parse_effort_cell(effort, nil, source, provider, path)

      [model, effort] ->
        with {:ok, model} <- parse_model(model, source, provider, path) do
          parse_effort_cell(effort, model, source, provider, path)
        end

      _ ->
        {:error, {:invalid_reasoning_profile_cell, source, provider, path}}
    end
  end

  defp parse_model(model, source, provider, path) do
    trimmed = String.trim(model)

    if trimmed == "" do
      {:error, {:invalid_reasoning_profile_model, source, provider, path}}
    else
      {:ok, trimmed}
    end
  end

  defp parse_effort_cell(effort, model, source, provider, path) do
    trimmed = String.trim(effort)

    cond do
      trimmed == "" -> {:error, {:missing_reasoning_profile_effort, source, provider, path}}
      trimmed in @shared_efforts -> {:ok, model, trimmed}
      true -> {:error, {:unsupported_reasoning_profile_effort, source, provider, path, trimmed}}
    end
  end

  defp validate_effort("codex", _model, effort, source, path) do
    if effort in @codex_supported_efforts do
      :ok
    else
      {:error, {:unsupported_reasoning_profile_effort, source, "codex", path, effort}}
    end
  end

  defp validate_effort("claude_code", _model, _effort, _source, _path), do: :ok

  defp validate_model_effort("claude_code", model, effort, source, path) when effort in ~w(xhigh max) do
    supported =
      case effort do
        "xhigh" -> @claude_xhigh_supported_models
        "max" -> @claude_max_supported_models
      end

    if claude_effort_model_supported?(model, supported) do
      :ok
    else
      {:error, {:unsupported_reasoning_profile_model_effort, source, "claude_code", path, model, effort}}
    end
  end

  defp validate_model_effort(_provider, _model, _effort, _source, _path), do: :ok

  defp validate_no_thinking("claude_code", model, "none", source, path) do
    cond do
      not is_binary(model) ->
        {:error, {:unsupported_reasoning_profile_no_thinking, source, "claude_code", path, model}}

      model |> String.downcase() |> String.contains?("fable") ->
        {:error, {:unsupported_reasoning_profile_no_thinking, source, "claude_code", path, model}}

      true ->
        :ok
    end
  end

  defp validate_no_thinking(_provider, _model, _effort, _source, _path), do: :ok

  defp translated_cell("claude_code", model, "none"),
    do: %{"model" => model, "effort" => @claude_no_thinking_effort, "no_thinking" => true, "cell_effort" => "none"}

  defp translated_cell(_provider, model, effort),
    do: %{"model" => model, "effort" => effort, "no_thinking" => false, "cell_effort" => effort}

  defp validate_keys(keys, allowed, error_tuple) do
    unknown = Enum.reject(keys, &(&1 in allowed))

    if unknown == [] do
      :ok
    else
      {:error, append_tuple(error_tuple, unknown)}
    end
  end

  defp validate_required_keys(keys, required, error_tuple) do
    missing = Enum.reject(required, &(&1 in keys))

    if missing == [] do
      :ok
    else
      {:error, append_tuple(error_tuple, missing)}
    end
  end

  defp append_tuple(tuple, value), do: Tuple.insert_at(tuple, tuple_size(tuple), value)

  defp reduce_validated(keys, fun) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case fun.(key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp issue_tier("claude_code", profiles, labels) do
    label_tier(labels, default_tier(profiles, "claude_code"), invalid: :default)
  end

  defp issue_tier(provider, profiles, labels) do
    label_tier(labels, default_tier(profiles, provider), invalid: :error)
  end

  defp label_tier(labels, default_tier, opts) when is_list(labels) do
    labels
    |> implementation_effort_labels()
    |> classify_labels(default_tier, opts)
  end

  defp label_tier(_labels, default_tier, _opts), do: {:ok, default_tier, "default"}

  defp implementation_effort_labels(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.filter(&String.starts_with?(&1, @prefix))
  end

  defp classify_labels([], default_tier, _opts), do: {:ok, default_tier, "default"}

  defp classify_labels(labels, default_tier, opts) do
    {supported, unsupported} =
      Enum.split_with(labels, fn label ->
        label
        |> String.replace_prefix(@prefix, "")
        |> then(&(&1 in @tiers))
      end)

    cond do
      unsupported != [] and Keyword.get(opts, :invalid) == :default ->
        {:ok, default_tier, "default_invalid_label"}

      unsupported != [] ->
        {:error, {:invalid_implementation_effort_labels, unsupported}}

      length(supported) > 1 and Keyword.get(opts, :invalid) == :default ->
        {:ok, default_tier, "default_ambiguous_label"}

      length(supported) > 1 ->
        {:error, {:ambiguous_implementation_effort_labels, supported}}

      true ->
        [label] = supported
        {:ok, String.replace_prefix(label, @prefix, ""), "label"}
    end
  end

  defp row_profile(profiles, provider, tier, role, source) do
    provider_config = Map.fetch!(profiles, provider)
    role_key = if is_binary(role) and Map.has_key?(provider_config, role), do: role, else: "default"
    role_profile = Map.fetch!(provider_config, role_key)
    row = if Map.has_key?(role_profile, tier), do: Map.fetch!(role_profile, tier), else: role_profile

    effort = Map.fetch!(row, "effort")

    %{
      provider: provider,
      effort: tier,
      source: source,
      role: role,
      model: Map.get(row, "model"),
      no_thinking: Map.get(row, "no_thinking", false),
      reasoning_effort: effort
    }
  end

  defp default_tier(profiles, provider), do: get_in(profiles, [provider, "default_tier"])

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

  defp normalize_provider(provider) when is_atom(provider), do: provider |> Atom.to_string() |> normalize_provider()
  defp normalize_provider(provider) when provider in @providers, do: provider
  defp normalize_provider(provider) when is_binary(provider), do: provider |> String.trim() |> String.downcase()

  defp claude_effort_model_supported?(model, supported_models) when is_binary(model) do
    case normalize_claude_model_id(model) do
      nil -> false
      normalized -> normalized in supported_models
    end
  end

  defp claude_effort_model_supported?(_model, _supported_models), do: false

  defp normalize_claude_model_id(model) when is_binary(model) do
    normalized =
      model
      |> String.downcase()
      |> String.trim()

    if Map.has_key?(@claude_model_alias_resolution, normalized) do
      @claude_model_alias_resolution[normalized] |> strip_model_prefix() |> family_version()
    else
      normalized |> strip_model_prefix() |> family_version()
    end
  end

  defp strip_model_prefix(model) do
    case Regex.run(~r/(claude-[a-z0-9.-]+)$/, model) do
      [_, captured] -> captured
      _ -> model
    end
  end

  defp family_version(model) do
    case Regex.run(~r/^claude-([a-z]+)-(\d+)(?:-(\d+))?/, model) do
      [_, family, major, minor] -> "#{family}-#{major}-#{minor}"
      [_, family, major] -> "#{family}-#{major}"
      _ -> nil
    end
  end

  defp put_codex_profile(command, %{reasoning_effort: reasoning_effort, model: model}) do
    command
    |> put_reasoning_effort(reasoning_effort)
    |> put_model(model)
  end

  defp put_model(command, nil), do: command

  defp put_model(command, model) do
    replacement = ~s(--config 'model="#{model}"')

    cond do
      Regex.match?(~r/--config\s+['"]model="/, command) ->
        Regex.replace(
          ~r/(--config\s+['"]model=")[^"]+("['"])/,
          command,
          "\\1#{model}\\2"
        )

      Regex.match?(~r/--config\s+model="/, command) ->
        Regex.replace(
          ~r/(--config\s+model=")[^"]+(")/,
          command,
          "\\1#{model}\\2"
        )

      Regex.match?(~r/\sapp-server(\s*)$/, command) ->
        Regex.replace(~r/\sapp-server(\s*)$/, command, " #{replacement} app-server\\1")

      true ->
        "#{command} #{replacement}"
    end
  end

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
