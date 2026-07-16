defmodule SymphonyElixir.AgentProfileCatalog do
  @moduledoc """
  Loads canonical TOML-frontmatter Markdown agent profiles and resolves complete
  provider launch contracts.

  The catalog owns profile shape, reusable agent instructions, capabilities,
  and per-provider implementation-effort matrices. Callers select a profile,
  provider, and optional tier without reproducing those policies.
  """

  @profile_suffix ".agent.md"
  @top_level_keys ~w(schema_version name kind role capabilities providers)
  @capability_keys ~w(can_delegate max_delegation_depth owns_issue_lifecycle owns_final_validation owns_handoff)
  @providers ~w(codex claude_code)
  @provider_keys ~w(default_tier extreme high moderate low minimal)
  @tiers ~w(extreme high moderate low minimal)
  @cell_keys ~w(model reasoning_effort)
  @kinds ~w(orchestrator worker)
  @codex_efforts ~w(none low medium high xhigh)
  @claude_efforts ~w(low medium high xhigh max)
  @claude_xhigh_models ~w(claude-fable-5 claude-mythos-5 claude-opus-4-8 claude-opus-4-7 claude-sonnet-5)
  @claude_max_models ~w(claude-fable-5 claude-mythos-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 claude-sonnet-5 claude-sonnet-4-6)

  @type catalog :: %{required(String.t()) => map()}

  @spec load(Path.t()) :: {:ok, catalog()} | {:error, term()}
  def load(root) when is_binary(root) do
    result =
      root
      |> Path.join("*#{@profile_suffix}")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce_while({:ok, %{}}, &load_catalog_entry/2)

    case result do
      {:ok, catalog} when map_size(catalog) == 0 -> {:error, :empty_agent_profile_catalog}
      other -> other
    end
  end

  def load(root), do: {:error, {:invalid_agent_profile_root, root}}

  defp load_catalog_entry(path, {:ok, catalog}) do
    case load_profile(path) do
      {:ok, %{name: name} = profile} -> put_catalog_profile(catalog, name, profile)
      {:error, reason} -> {:halt, {:error, {:invalid_agent_profile, path, reason}}}
    end
  end

  defp put_catalog_profile(catalog, name, profile) do
    if Map.has_key?(catalog, name) do
      {:halt, {:error, {:duplicate_agent_profile, name}}}
    else
      {:cont, {:ok, Map.put(catalog, name, profile)}}
    end
  end

  @spec resolve(catalog(), String.t(), String.t() | atom(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve(catalog, name, provider, requested_tier, source)
      when is_map(catalog) and is_binary(name) and is_binary(source) do
    provider = normalize_provider(provider)

    with {:ok, profile} <- fetch(catalog, name, :unknown_agent_profile),
         {:ok, provider_profile} <- fetch(profile.providers, provider, :unsupported_agent_profile_provider),
         {:ok, tier} <- resolve_tier(provider_profile, requested_tier),
         {:ok, cell} <- fetch(provider_profile.tiers, tier, :unsupported_implementation_effort) do
      {:ok,
       %{
         name: profile.name,
         kind: profile.kind,
         role: profile.role,
         capabilities: profile.capabilities,
         provider: provider,
         effort: tier,
         model: cell.model,
         reasoning_effort: cell.reasoning_effort,
         source: source,
         profile_source: profile.profile_source,
         instructions: profile.instructions
       }}
    end
  end

  def resolve(_catalog, _name, provider, _requested_tier, _source),
    do: {:error, {:invalid_agent_profile_provider, provider}}

  defp load_profile(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, frontmatter, instructions} <- split_document(contents),
         {:ok, decoded} <- decode_frontmatter(frontmatter),
         :ok <- exact_keys(decoded, @top_level_keys),
         :ok <- validate_identity(decoded, path),
         {:ok, capabilities} <- validate_capabilities(decoded["capabilities"], decoded["kind"]),
         {:ok, providers} <- validate_providers(decoded["providers"]),
         {:ok, instructions} <- validate_instructions(instructions) do
      {:ok,
       %{
         name: decoded["name"],
         kind: decoded["kind"],
         role: decoded["role"],
         capabilities: capabilities,
         providers: providers,
         instructions: instructions,
         profile_source: path
       }}
    end
  end

  defp split_document(contents) when is_binary(contents) do
    normalized = String.replace(contents, "\r\n", "\n")

    case String.split(normalized, "+++", parts: 3) do
      [prefix, frontmatter, instructions] when prefix in ["", "\n"] ->
        {:ok, String.trim(frontmatter), instructions}

      _ ->
        {:error, :missing_toml_frontmatter}
    end
  end

  defp decode_frontmatter(frontmatter) do
    case Toml.decode(frontmatter) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_toml_frontmatter, reason}}
    end
  end

  defp validate_identity(
         %{
           "schema_version" => 1,
           "name" => name,
           "kind" => kind,
           "role" => role
         },
         path
       )
       when is_binary(name) and is_binary(role) do
    expected_name = path |> Path.basename(@profile_suffix)

    cond do
      name == "" or name != String.trim(name) -> {:error, {:invalid_name, name}}
      name != expected_name -> {:error, {:filename_name_mismatch, expected_name, name}}
      kind not in @kinds -> {:error, {:invalid_kind, kind}}
      role == "" or role != String.trim(role) -> {:error, {:invalid_role, role}}
      true -> :ok
    end
  end

  defp validate_identity(%{"schema_version" => version}, _path),
    do: {:error, {:unsupported_schema_version, version}}

  defp validate_identity(_decoded, _path), do: {:error, :invalid_identity}

  defp validate_capabilities(capabilities, kind) when is_map(capabilities) do
    with :ok <- exact_keys(capabilities, @capability_keys),
         {:ok, can_delegate} <- boolean(capabilities, "can_delegate"),
         {:ok, max_depth} <- nonnegative_integer(capabilities, "max_delegation_depth"),
         {:ok, owns_issue_lifecycle} <- boolean(capabilities, "owns_issue_lifecycle"),
         {:ok, owns_final_validation} <- boolean(capabilities, "owns_final_validation"),
         {:ok, owns_handoff} <- boolean(capabilities, "owns_handoff"),
         :ok <- validate_delegation_depth(can_delegate, max_depth),
         :ok <- validate_worker_authority(kind, owns_issue_lifecycle, owns_final_validation, owns_handoff) do
      {:ok,
       %{
         can_delegate: can_delegate,
         max_delegation_depth: max_depth,
         owns_issue_lifecycle: owns_issue_lifecycle,
         owns_final_validation: owns_final_validation,
         owns_handoff: owns_handoff
       }}
    end
  end

  defp validate_capabilities(_capabilities, _kind), do: {:error, :invalid_capabilities}

  defp validate_worker_authority("worker", false, false, false), do: :ok
  defp validate_worker_authority("worker", _issue, _validation, _handoff), do: {:error, :worker_cannot_own_run_authority}
  defp validate_worker_authority(_kind, _issue, _validation, _handoff), do: :ok

  defp validate_delegation_depth(false, 0), do: :ok
  defp validate_delegation_depth(false, depth), do: {:error, {:non_delegating_profile_has_depth, depth}}
  defp validate_delegation_depth(true, depth) when depth > 0, do: :ok
  defp validate_delegation_depth(true, depth), do: {:error, {:delegating_profile_requires_depth, depth}}

  defp validate_providers(providers) when is_map(providers) do
    with :ok <- exact_keys(providers, @providers) do
      reduce_validated(@providers, fn provider ->
        validate_provider(provider, Map.fetch!(providers, provider))
      end)
    end
  end

  defp validate_providers(_providers), do: {:error, :invalid_providers}

  defp validate_provider(provider, config) when is_map(config) do
    with :ok <- exact_keys(config, @provider_keys),
         "moderate" <- Map.get(config, "default_tier"),
         {:ok, tiers} <-
           reduce_validated(@tiers, fn tier ->
             validate_cell(provider, tier, Map.fetch!(config, tier))
           end) do
      {:ok, %{default_tier: "moderate", tiers: tiers}}
    else
      tier when is_binary(tier) -> {:error, {:default_tier_must_be_moderate, provider, tier}}
      nil -> {:error, {:missing_keys, ["default_tier"]}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_provider(provider, _config), do: {:error, {:invalid_provider, provider}}

  defp validate_cell(provider, tier, cell) when is_map(cell) do
    with :ok <- exact_keys(cell, @cell_keys),
         {:ok, model} <- nonempty_string(cell, "model"),
         {:ok, effort} <- nonempty_string(cell, "reasoning_effort"),
         :ok <- validate_effort(provider, tier, effort),
         :ok <- validate_model_effort(provider, tier, model, effort) do
      {:ok, %{model: model, reasoning_effort: effort}}
    end
  end

  defp validate_cell(provider, tier, _cell), do: {:error, {:invalid_provider_tier, provider, tier}}

  defp validate_effort("codex", _tier, effort) when effort in @codex_efforts, do: :ok
  defp validate_effort("claude_code", _tier, effort) when effort in @claude_efforts, do: :ok

  defp validate_effort(provider, tier, effort),
    do: {:error, {:unsupported_reasoning_effort, provider, tier, effort}}

  defp validate_model_effort("claude_code", tier, model, "xhigh") do
    if model in @claude_xhigh_models,
      do: :ok,
      else: {:error, {:unsupported_model_reasoning_effort, "claude_code", tier, model, "xhigh"}}
  end

  defp validate_model_effort("claude_code", tier, model, "max") do
    if model in @claude_max_models,
      do: :ok,
      else: {:error, {:unsupported_model_reasoning_effort, "claude_code", tier, model, "max"}}
  end

  defp validate_model_effort(_provider, _tier, _model, _effort), do: :ok

  defp validate_instructions(instructions) do
    case String.trim(instructions) do
      "" -> {:error, :empty_instructions}
      trimmed -> {:ok, trimmed <> "\n"}
    end
  end

  defp exact_keys(map, expected) do
    keys = Map.keys(map)
    unknown = Enum.sort(keys -- expected)
    missing = Enum.sort(expected -- keys)

    cond do
      unknown != [] -> {:error, {:unknown_keys, unknown}}
      missing != [] -> {:error, {:missing_keys, missing}}
      true -> :ok
    end
  end

  defp boolean(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_boolean, key, value}}
      :error -> {:error, {:missing_keys, [key]}}
    end
  end

  defp nonnegative_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_nonnegative_integer, key, value}}
      :error -> {:error, {:missing_keys, [key]}}
    end
  end

  defp nonempty_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if value != "" and value == String.trim(value),
          do: {:ok, value},
          else: {:error, {:invalid_string, key, value}}

      {:ok, value} ->
        {:error, {:invalid_string, key, value}}

      :error ->
        {:error, {:missing_keys, [key]}}
    end
  end

  defp resolve_tier(%{default_tier: tier}, nil), do: {:ok, tier}
  defp resolve_tier(_provider, tier) when tier in @tiers, do: {:ok, tier}
  defp resolve_tier(_provider, tier), do: {:error, {:unsupported_implementation_effort, tier}}

  defp normalize_provider(provider) when is_atom(provider), do: provider |> Atom.to_string() |> normalize_provider()
  defp normalize_provider(provider) when is_binary(provider), do: provider |> String.trim() |> String.downcase()
  defp normalize_provider(provider), do: provider

  defp fetch(map, key, error) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {error, key}}
    end
  end

  defp reduce_validated(keys, fun) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case fun.(key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
