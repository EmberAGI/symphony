defmodule SymphonyElixir.ImplementationEffort do
  @moduledoc """
  Selects an implementation-effort tier from Linear labels and resolves the
  corresponding canonical agent profile.

  Agent identity, reusable instructions, capabilities, models, and provider
  effort matrices belong to `AgentProfileCatalog`; this module owns only
  label selection and role-to-profile routing.
  """

  alias SymphonyElixir.{AgentProfileCatalog, Linear.Issue}

  @prefix "implementation-effort:"
  @tiers ~w(extreme high moderate low minimal)
  @providers ~w(codex claude_code)
  @default_tier "moderate"
  @role_profiles %{
    "implementer" => "implementer-orchestrator",
    "reviewer" => "reviewer",
    "qa" => "qa",
    "landing" => "landing",
    "backlog-processor" => "backlog-processor"
  }

  @type profile :: %{
          required(:name) => String.t(),
          required(:kind) => String.t(),
          required(:role) => String.t(),
          required(:provider) => String.t(),
          required(:effort) => String.t(),
          required(:source) => String.t(),
          required(:model) => String.t(),
          required(:reasoning_effort) => String.t(),
          required(:profile_source) => String.t(),
          required(:instructions) => String.t(),
          required(:capabilities) => map()
        }

  @spec profiles() :: {:ok, AgentProfileCatalog.catalog()} | {:error, term()}
  def profiles do
    case System.get_env("SYMPHONY_AGENT_PROFILES") do
      path when is_binary(path) and path != "" -> AgentProfileCatalog.load(path)
      _ -> {:error, :missing_agent_profiles_path}
    end
  end

  @spec parse_labels([String.t()]) :: {:ok, profile()} | {:error, term()}
  def parse_labels(labels) do
    with {:ok, catalog} <- profiles(),
         {:ok, tier, source} <- label_tier(labels, @default_tier, invalid: :error) do
      resolve(catalog, "default", "codex", tier, source)
    end
  end

  @spec profile_for_issue(Issue.t(), String.t() | nil) :: {:ok, profile()} | {:error, term()}
  def profile_for_issue(issue, role), do: profile_for_issue("codex", issue, role)

  @spec profile_for_issue(String.t() | atom(), term(), String.t() | nil) :: {:ok, profile()} | {:error, term()}
  def profile_for_issue(provider, issue, role) do
    provider = normalize_provider(provider)
    role = normalize_role(role)

    with :ok <- validate_provider(provider),
         {:ok, catalog} <- profiles(),
         {:ok, tier, source} <- issue_tier(provider, issue) do
      resolve(catalog, profile_name(role), provider, tier, source)
    end
  end

  @doc "Resolve the provider-neutral orchestrator/worker contract for one role run."
  @spec runtime_profile_for_issue(String.t() | atom(), term(), String.t() | nil) ::
          {:ok, %{provider: String.t(), role: String.t() | nil, orchestrator: profile(), worker: profile() | nil}}
          | {:error, term()}
  def runtime_profile_for_issue(provider, issue, role) do
    runtime_profile_for_issue(provider, provider, issue, role)
  end

  @doc "Resolve orchestrator and worker providers independently for one role run."
  @spec runtime_profile_for_issue(String.t() | atom(), String.t() | atom(), term(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def runtime_profile_for_issue(orchestrator_provider, worker_provider, issue, role) do
    orchestrator_provider = normalize_provider(orchestrator_provider)
    worker_provider = normalize_provider(worker_provider)
    role = normalize_role(role)

    with :ok <- validate_provider(orchestrator_provider),
         :ok <- validate_provider(worker_provider),
         {:ok, catalog} <- profiles(),
         {:ok, tier, source} <- issue_tier(orchestrator_provider, issue),
         {:ok, orchestrator} <- resolve(catalog, profile_name(role), orchestrator_provider, tier, source),
         {:ok, worker} <- resolve_worker(catalog, role, worker_provider, tier, source) do
      validate_runtime_contract(%{
        provider: orchestrator_provider,
        orchestrator_provider: orchestrator_provider,
        worker_provider: worker_provider,
        role: role,
        orchestrator: orchestrator,
        worker: worker
      })
    end
  end

  @doc "Reject missing or capability-inconsistent delegation contracts."
  @spec validate_runtime_contract(map()) :: {:ok, map()} | {:error, term()}
  def validate_runtime_contract(
        %{
          orchestrator_provider: orchestrator_provider,
          worker_provider: worker_provider,
          role: "implementer",
          orchestrator: %{provider: orchestrator_provider, kind: "orchestrator"} = orchestrator,
          worker: %{provider: worker_provider, kind: "worker"} = worker
        } = contract
      ) do
    cond do
      orchestrator.name != "implementer-orchestrator" ->
        {:error, {:invalid_implementer_orchestrator_profile, orchestrator.name}}

      worker.name != "implementer-worker" ->
        {:error, {:invalid_implementer_worker_profile, worker.name}}

      not orchestrator.capabilities.can_delegate ->
        {:error, :implementer_orchestrator_cannot_delegate}

      worker.capabilities.can_delegate ->
        {:error, :implementer_worker_may_delegate}

      orchestrator.effort != worker.effort ->
        {:error, {:mixed_implementer_effort, orchestrator.effort, worker.effort}}

      true ->
        {:ok, contract}
    end
  end

  def validate_runtime_contract(%{role: "implementer"}),
    do: {:error, :missing_implementer_delegation_contract}

  def validate_runtime_contract(%{orchestrator: orchestrator, worker: nil} = contract) when is_map(orchestrator),
    do: {:ok, contract}

  def validate_runtime_contract(_contract), do: {:error, :invalid_runtime_profile_contract}

  @spec command_for_issue(String.t(), Issue.t(), String.t() | nil) ::
          {:ok, {String.t(), profile()}} | {:error, term()}
  def command_for_issue(command, issue, role) when is_binary(command) do
    with {:ok, profile} <- profile_for_issue("codex", issue, role) do
      {:ok, {apply_codex_orchestrator(command, profile), profile}}
    end
  end

  @doc "Apply one already-resolved Codex orchestrator profile without re-reading the catalog."
  @spec apply_codex_orchestrator(String.t(), profile()) :: String.t()
  def apply_codex_orchestrator(command, profile) when is_binary(command), do: put_codex_profile(command, profile)

  # Compatibility for existing app-server callers while terminology migrates.
  @spec apply_codex_lead(String.t(), profile()) :: String.t()
  def apply_codex_lead(command, profile), do: apply_codex_orchestrator(command, profile)

  @spec valid_labels?(Issue.t()) :: boolean()
  def valid_labels?(%Issue{} = issue), do: match?({:ok, _profile}, profile_for_issue(issue, nil))
  def valid_labels?(_issue), do: true

  defp resolve(catalog, name, provider, tier, source),
    do: AgentProfileCatalog.resolve(catalog, name, provider, tier, source)

  defp resolve_worker(catalog, "implementer", provider, tier, source),
    do: resolve(catalog, "implementer-worker", provider, tier, source)

  defp resolve_worker(_catalog, _role, _provider, _tier, _source), do: {:ok, nil}

  defp profile_name(role), do: Map.get(@role_profiles, role, "default")

  defp issue_tier("claude_code", %Issue{labels: labels}),
    do: label_tier(labels, @default_tier, invalid: :default)

  defp issue_tier(_provider, %Issue{labels: labels}),
    do: label_tier(labels, @default_tier, invalid: :error)

  defp issue_tier(_provider, _issue), do: {:ok, @default_tier, "default"}

  defp label_tier(labels, default_tier, opts) when is_list(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.filter(&String.starts_with?(&1, @prefix))
    |> classify_labels(default_tier, opts)
  end

  defp label_tier(_labels, default_tier, _opts), do: {:ok, default_tier, "default"}

  defp classify_labels([], default_tier, _opts), do: {:ok, default_tier, "default"}

  defp classify_labels(labels, default_tier, opts) do
    {supported, unsupported} =
      Enum.split_with(labels, fn label ->
        label |> String.replace_prefix(@prefix, "") |> then(&(&1 in @tiers))
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

  defp validate_provider(provider) when provider in @providers, do: :ok
  defp validate_provider(provider), do: {:error, {:unsupported_agent_profile_provider, provider}}

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp normalize_label(_label), do: ""

  defp normalize_role(role) when is_binary(role), do: role |> String.trim() |> String.downcase()
  defp normalize_role(_role), do: nil

  defp normalize_provider(provider) when is_atom(provider), do: provider |> Atom.to_string() |> normalize_provider()
  defp normalize_provider(provider) when is_binary(provider), do: provider |> String.trim() |> String.downcase()
  defp normalize_provider(provider), do: provider

  defp put_codex_profile(command, %{
         reasoning_effort: reasoning_effort,
         model: model,
         instructions: instructions
       }) do
    command
    |> put_reasoning_effort(reasoning_effort)
    |> put_model(model)
    |> put_developer_instructions(instructions)
  end

  defp put_developer_instructions(command, instructions) do
    replacement = shell_single_quote("developer_instructions=#{inspect(instructions)}")

    if Regex.match?(~r/\sapp-server(\s*)$/, command) do
      Regex.replace(~r/\sapp-server(\s*)$/, command, " --config #{replacement} app-server\\1")
    else
      "#{command} --config #{replacement}"
    end
  end

  defp shell_single_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp put_model(command, model) do
    replacement = ~s(--config 'model="#{model}"')

    cond do
      Regex.match?(~r/--config\s+['"]model="/, command) ->
        Regex.replace(~r/(--config\s+['"]model=")[^"]+("['"])/, command, "\\1#{model}\\2")

      Regex.match?(~r/--config\s+model="/, command) ->
        Regex.replace(~r/(--config\s+model=")[^"]+(")/, command, "\\1#{model}\\2")

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
