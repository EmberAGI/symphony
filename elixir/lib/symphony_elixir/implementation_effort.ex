defmodule SymphonyElixir.ImplementationEffort do
  @moduledoc """
  Parses Linear Implementation Effort labels and derives provider reasoning rows.
  """

  alias SymphonyElixir.Linear.Issue

  @prefix "implementation-effort:"
  @tiers ~w(extreme high moderate low minimal)
  @dynamic_roles ~w(implementer reviewer qa)
  @providers ~w(codex claude_code)
  @row_keys ~w(model effort no_thinking)
  @role_keys ~w(reviewer worker)
  @supported_efforts %{
    "codex" => ~w(none low medium high xhigh),
    "claude_code" => ~w(low medium high xhigh max)
  }
  @claude_unrestricted_efforts ~w(low medium high)
  @claude_xhigh_supported_models ~w(fable-5 mythos-5 opus-4-8 opus-4-7)
  @claude_max_supported_models ~w(fable-5 mythos-5 opus-4-8 opus-4-7 opus-4-6 sonnet-4-6)
  @claude_model_alias_resolution %{
    "fable" => "claude-fable-5",
    "opus" => "claude-opus-4-8",
    "sonnet" => "claude-sonnet-4-6",
    "haiku" => "claude-haiku-4-5"
  }

  @built_in_profiles %{
    "codex" => %{
      "default_tier" => "high",
      "tiers" => %{
        "extreme" => %{"reviewer" => %{"effort" => "xhigh"}, "worker" => %{"effort" => "high"}},
        "high" => %{"reviewer" => %{"effort" => "xhigh"}, "worker" => %{"effort" => "high"}},
        "moderate" => %{"reviewer" => %{"effort" => "high"}, "worker" => %{"effort" => "medium"}},
        "low" => %{"reviewer" => %{"effort" => "medium"}, "worker" => %{"effort" => "low"}},
        "minimal" => %{"reviewer" => %{"effort" => "low"}, "worker" => %{"effort" => "none"}}
      }
    },
    "claude_code" => %{
      "default_tier" => "moderate",
      "fixed" => %{"model" => "opus", "effort" => "high"},
      "tiers" => %{
        "extreme" => %{
          "reviewer" => %{"model" => "fable", "effort" => "xhigh"},
          "worker" => %{"model" => "opus", "effort" => "xhigh"}
        },
        "high" => %{
          "reviewer" => %{"model" => "fable", "effort" => "high"},
          "worker" => %{"model" => "opus", "effort" => "high"}
        },
        "moderate" => %{
          "reviewer" => %{"model" => "opus", "effort" => "high"},
          "worker" => %{"model" => "sonnet", "effort" => "high"}
        },
        "low" => %{
          "reviewer" => %{"model" => "sonnet", "effort" => "high"},
          "worker" => %{"model" => "sonnet", "effort" => "medium"}
        },
        "minimal" => %{
          "reviewer" => %{"model" => "sonnet", "effort" => "medium"},
          "worker" => %{"model" => "sonnet", "effort" => "low", "no_thinking" => true}
        }
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
      {:ok, row_profile(profiles, "codex", tier, "worker", nil, source)}
    end
  end

  def parse_labels(_labels) do
    with {:ok, profiles} <- profiles() do
      tier = default_tier(profiles, "codex")
      {:ok, row_profile(profiles, "codex", tier, "worker", nil, "default")}
    end
  end

  @spec profile_for_issue(Issue.t(), String.t() | nil) :: {:ok, profile()} | {:error, term()}
  def profile_for_issue(issue, role), do: profile_for_issue("codex", issue, role)

  @spec profile_for_issue(String.t() | atom(), term(), String.t() | nil) :: {:ok, profile()} | {:error, term()}
  def profile_for_issue(provider, %Issue{labels: labels}, role) do
    provider = normalize_provider(provider)

    with {:ok, profiles} <- profiles(),
         {:ok, tier, source} <- issue_tier(provider, profiles, labels) do
      {:ok, row_profile(profiles, provider, tier, role_key(role), normalize_role(role), source)}
    end
  end

  def profile_for_issue(provider, _issue, role) do
    provider = normalize_provider(provider)

    with {:ok, profiles} <- profiles() do
      tier = default_tier(profiles, provider)
      {:ok, row_profile(profiles, provider, tier, role_key(role), normalize_role(role), "default")}
    end
  end

  @spec command_for_issue(String.t(), Issue.t(), String.t() | nil) :: {:ok, {String.t(), profile()}} | {:error, term()}
  def command_for_issue(command, %Issue{} = issue, role) when is_binary(command) do
    with {:ok, profile} <- profile_for_issue("codex", issue, role) do
      if profile.role in @dynamic_roles do
        {:ok, {put_reasoning_effort(command, profile.reasoning_effort), profile}}
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
    allowed = ~w(default_tier tiers fixed)

    with :ok <- validate_keys(Map.keys(config), allowed, {:unknown_reasoning_profile_key, source, provider}),
         {:ok, default_tier} <- fetch_default_tier(config, source, provider),
         {:ok, tiers} <- fetch_tiers(config, source, provider),
         {:ok, fixed} <- validate_optional_fixed(provider, Map.get(config, "fixed"), source) do
      {:ok, %{"default_tier" => default_tier, "tiers" => tiers, "fixed" => fixed}}
    end
  end

  defp validate_provider(provider, _config, source), do: {:error, {:invalid_reasoning_profile_provider_shape, source, provider}}

  defp fetch_default_tier(config, source, provider) do
    case Map.get(config, "default_tier") do
      tier when tier in @tiers -> {:ok, tier}
      nil -> {:error, {:missing_reasoning_profile_default_tier, source, provider}}
      tier -> {:error, {:invalid_reasoning_profile_default_tier, source, provider, tier}}
    end
  end

  defp fetch_tiers(config, source, provider) do
    case Map.get(config, "tiers") do
      tiers when is_map(tiers) -> validate_tiers(provider, tiers, source)
      _ -> {:error, {:missing_reasoning_profile_tiers, source, provider}}
    end
  end

  defp validate_tiers(provider, tiers, source) do
    with :ok <- validate_keys(Map.keys(tiers), @tiers, {:unknown_reasoning_profile_tier, source, provider}),
         :ok <- validate_required_keys(Map.keys(tiers), @tiers, {:missing_reasoning_profile_tier, source, provider}) do
      reduce_validated(@tiers, fn tier ->
        validate_tier(provider, tier, Map.fetch!(tiers, tier), source)
      end)
    end
  end

  defp validate_tier(provider, tier, rows, source) when is_map(rows) do
    with :ok <- validate_keys(Map.keys(rows), @role_keys, {:unknown_reasoning_profile_role, source, provider, tier}),
         :ok <- validate_required_keys(Map.keys(rows), @role_keys, {:missing_reasoning_profile_role, source, provider, tier}) do
      reduce_validated(@role_keys, fn role ->
        validate_row(provider, Map.fetch!(rows, role), source, [tier, role])
      end)
    end
  end

  defp validate_tier(provider, tier, _rows, source), do: {:error, {:invalid_reasoning_profile_tier_shape, source, provider, tier}}

  defp validate_optional_fixed(_provider, nil, _source), do: {:ok, nil}

  defp validate_optional_fixed(provider, row, source) do
    validate_row(provider, row, source, ["fixed"])
  end

  defp validate_row(provider, row, source, path) when is_map(row) do
    with :ok <- validate_keys(Map.keys(row), @row_keys, {:unknown_reasoning_profile_row_key, source, provider, path}),
         {:ok, effort} <- required_string(row, "effort", {:missing_reasoning_profile_effort, source, provider, path}),
         :ok <- validate_effort(provider, effort, source, path),
         {:ok, model} <- optional_string(row, "model", {:invalid_reasoning_profile_model, source, provider, path}),
         {:ok, no_thinking} <-
           optional_boolean(row, "no_thinking", {:invalid_reasoning_profile_no_thinking, source, provider, path}),
         :ok <- validate_model_effort(provider, model, effort, source, path),
         :ok <- validate_no_thinking(provider, model, no_thinking, source, path) do
      {:ok, %{"model" => model, "effort" => effort, "no_thinking" => no_thinking}}
    end
  end

  defp validate_row(provider, _row, source, path), do: {:error, {:invalid_reasoning_profile_row_shape, source, provider, path}}

  defp validate_effort(provider, effort, source, path) do
    if effort in Map.fetch!(@supported_efforts, provider) do
      :ok
    else
      {:error, {:unsupported_reasoning_profile_effort, source, provider, path, effort}}
    end
  end

  defp validate_model_effort("claude_code", model, effort, source, path) when effort not in @claude_unrestricted_efforts do
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

  defp validate_no_thinking("claude_code", model, true, source, path) do
    cond do
      not is_binary(model) ->
        {:error, {:unsupported_reasoning_profile_no_thinking, source, "claude_code", path, model}}

      model |> String.downcase() |> String.contains?("fable") ->
        {:error, {:unsupported_reasoning_profile_no_thinking, source, "claude_code", path, model}}

      true ->
        :ok
    end
  end

  defp validate_no_thinking(_provider, _model, _no_thinking, _source, _path), do: :ok

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

  defp required_string(row, key, error) do
    case Map.get(row, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp optional_string(row, key, error) do
    case Map.get(row, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp optional_boolean(row, key, error) do
    case Map.get(row, key) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, error}
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

  defp row_profile(profiles, provider, tier, role_key, role, source) do
    provider_config = Map.fetch!(profiles, provider)

    row =
      case {role, Map.get(provider_config, "fixed")} do
        {role, fixed} when role not in @dynamic_roles and is_map(fixed) -> fixed
        _ -> get_in(provider_config, ["tiers", tier, role_key])
      end

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

  defp role_key("reviewer"), do: "reviewer"
  defp role_key(_role), do: "worker"

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

    cond do
      normalized == "" ->
        nil

      Map.has_key?(@claude_model_alias_resolution, normalized) ->
        @claude_model_alias_resolution[normalized] |> strip_model_prefix() |> family_version()

      true ->
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
