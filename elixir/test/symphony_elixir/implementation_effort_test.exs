defmodule SymphonyElixir.ImplementationEffortTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ImplementationEffort

  test "maps every supported effort label to reviewer and worker reasoning" do
    cases = [
      {"implementation-effort:extreme", "xhigh", "high"},
      {"implementation-effort:high", "xhigh", "high"},
      {"implementation-effort:moderate", "high", "medium"},
      {"implementation-effort:low", "medium", "low"},
      {"implementation-effort:minimal", "low", "none"}
    ]

    Enum.each(cases, fn {label, reviewer_reasoning, worker_reasoning} ->
      issue = issue_with_labels([label])

      assert {:ok, %{source: "label", reasoning_effort: ^reviewer_reasoning}} =
               ImplementationEffort.profile_for_issue(issue, "reviewer")

      assert {:ok, %{source: "label", reasoning_effort: ^worker_reasoning}} =
               ImplementationEffort.profile_for_issue(issue, "implementer")

      assert {:ok, %{source: "label", reasoning_effort: ^worker_reasoning}} =
               ImplementationEffort.profile_for_issue(issue, "qa")
    end)
  end

  test "parses implementation effort labels case-insensitively" do
    issue = issue_with_labels(["Implementation-Effort:MoDeRaTe"])

    assert {:ok, %{effort: "moderate", source: "label", reasoning_effort: "medium"}} =
             ImplementationEffort.profile_for_issue(issue, "IMPLEMENTER")
  end

  test "missing effort label uses visible default high profile" do
    issue = issue_with_labels(["backend"])

    assert {:ok, %{effort: "high", source: "default", role: "qa", reasoning_effort: "high"}} =
             ImplementationEffort.profile_for_issue(issue, "qa")

    assert {:ok, %{effort: "high", source: "default", role: "reviewer", reasoning_effort: "xhigh"}} =
             ImplementationEffort.profile_for_issue(issue, "reviewer")
  end

  test "multiple supported effort labels fail closed" do
    issue = issue_with_labels(["implementation-effort:low", "implementation-effort:minimal"])

    assert {:error, {:ambiguous_implementation_effort_labels, labels}} =
             ImplementationEffort.profile_for_issue(issue, "implementer")

    assert labels == ["implementation-effort:low", "implementation-effort:minimal"]
  end

  test "unsupported or malformed effort labels fail closed" do
    unsupported = issue_with_labels(["implementation-effort:medium"])
    malformed = issue_with_labels(["implementation-effort:"])

    assert {:error, {:invalid_implementation_effort_labels, ["implementation-effort:medium"]}} =
             ImplementationEffort.profile_for_issue(unsupported, "implementer")

    assert {:error, {:invalid_implementation_effort_labels, ["implementation-effort:"]}} =
             ImplementationEffort.profile_for_issue(malformed, "implementer")
  end

  test "rewrites role launch commands with the effective reasoning value" do
    issue = issue_with_labels(["implementation-effort:low"])
    command = "codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=high app-server"

    assert {:ok, {updated, %{reasoning_effort: "medium"}}} =
             ImplementationEffort.command_for_issue(command, issue, "reviewer")

    assert updated ==
             "codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=medium app-server"
  end

  test "minimal implementer and QA launch commands use Codex no-reasoning none" do
    issue = issue_with_labels(["implementation-effort:minimal"])
    command = "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' app-server"

    for role <- ["implementer", "qa"] do
      assert {:ok, {updated, %{reasoning_effort: "none"}}} =
               ImplementationEffort.command_for_issue(command, issue, role)

      assert updated ==
               "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=none app-server"
    end
  end

  test "non dynamic roles keep the workflow command while still validating labels" do
    issue = issue_with_labels(["implementation-effort:low"])
    command = "codex --config model_reasoning_effort=high app-server"

    assert {:ok, {^command, %{effort: "low", reasoning_effort: "low"}}} =
             ImplementationEffort.command_for_issue(command, issue, "landing")
  end

  test "appends reasoning config when the command has neither an existing flag nor an app-server suffix" do
    issue = issue_with_labels(["implementation-effort:moderate"])
    command = "codex exec --json"

    assert {:ok, {"codex exec --json --config model_reasoning_effort=medium", %{reasoning_effort: "medium"}}} =
             ImplementationEffort.command_for_issue(command, issue, "implementer")
  end

  test "non-list labels fall back to the default profile" do
    assert {:ok, %{effort: "high", source: "default", reasoning_effort: "high"}} =
             ImplementationEffort.parse_labels(:not_a_list)
  end

  test "legacy list label parser returns the Codex worker profile" do
    assert {:ok, %{provider: "codex", effort: "low", source: "label", reasoning_effort: "low"}} =
             ImplementationEffort.parse_labels(["implementation-effort:low"])
  end

  test "non-issue inputs fall back to the default role profile" do
    assert {:ok, %{effort: "high", source: "default", role: "reviewer", reasoning_effort: "xhigh"}} =
             ImplementationEffort.profile_for_issue(%{not: "an issue"}, "reviewer")

    assert {:ok, %{effort: "high", source: "default", role: nil, reasoning_effort: "high"}} =
             ImplementationEffort.profile_for_issue(%{not: "an issue"}, nil)
  end

  test "command_for_issue falls back to the default profile for non-issue inputs" do
    command = "codex app-server"

    assert {:ok, {^command, %{effort: "high", source: "default", role: "implementer"}}} =
             ImplementationEffort.command_for_issue(command, %{not: "an issue"}, "implementer")
  end

  test "valid_labels? accepts a valid issue and tolerates non-issue inputs" do
    assert ImplementationEffort.valid_labels?(issue_with_labels(["implementation-effort:low"]))
    refute ImplementationEffort.valid_labels?(issue_with_labels(["implementation-effort:bogus"]))
    assert ImplementationEffort.valid_labels?(%{not: "an issue"})
  end

  test "non-binary labels and roles normalize to safe defaults" do
    # A non-binary label normalizes to "" and is ignored, leaving the default
    # profile; a non-binary role normalizes to nil and keeps the worker tier.
    issue = issue_with_labels([:not_a_string, "implementation-effort:moderate"])

    assert {:ok, %{effort: "moderate", role: nil, reasoning_effort: "medium"}} =
             ImplementationEffort.profile_for_issue(issue, :not_a_string)
  end

  test "maps every supported effort label to Claude reviewer and worker rows" do
    cases = [
      {"implementation-effort:extreme", "fable", "xhigh", "opus", "xhigh", false},
      {"implementation-effort:high", "fable", "high", "opus", "high", false},
      {"implementation-effort:moderate", "opus", "high", "sonnet", "high", false},
      {"implementation-effort:low", "sonnet", "high", "sonnet", "medium", false},
      {"implementation-effort:minimal", "sonnet", "medium", "sonnet", "low", true}
    ]

    Enum.each(cases, fn {label, reviewer_model, reviewer_effort, worker_model, worker_effort, worker_no_thinking} ->
      issue = issue_with_labels([label])

      assert {:ok, %{source: "label", model: ^reviewer_model, reasoning_effort: ^reviewer_effort}} =
               ImplementationEffort.profile_for_issue("claude_code", issue, "reviewer")

      assert {:ok,
              %{
                source: "label",
                model: ^worker_model,
                reasoning_effort: ^worker_effort,
                no_thinking: ^worker_no_thinking
              }} =
               ImplementationEffort.profile_for_issue("claude_code", issue, "implementer")
    end)
  end

  test "Claude missing malformed and unsupported labels use the moderate default tier" do
    for labels <- [[], ["implementation-effort:"], ["implementation-effort:bogus"]] do
      assert {:ok,
              %{
                provider: "claude_code",
                effort: "moderate",
                model: "sonnet",
                reasoning_effort: "high"
              }} = ImplementationEffort.profile_for_issue("claude_code", issue_with_labels(labels), "qa")
    end
  end

  test "Claude landing and backlog processor use the fixed row" do
    issue = issue_with_labels(["implementation-effort:minimal"])

    for role <- ["landing", "backlog-processor"] do
      assert {:ok,
              %{
                provider: "claude_code",
                effort: "minimal",
                role: ^role,
                model: "opus",
                reasoning_effort: "high",
                no_thinking: false
              }} = ImplementationEffort.profile_for_issue("claude_code", issue, role)
    end
  end

  test "loads provider profiles from SYMPHONY_REASONING_PROFILES TOML" do
    previous = System.get_env("SYMPHONY_REASONING_PROFILES")
    path = write_profiles_toml!("custom", "minimal_worker_effort = \"low\"")

    try do
      System.put_env("SYMPHONY_REASONING_PROFILES", path)

      assert {:ok, %{reasoning_effort: "medium"}} =
               ImplementationEffort.profile_for_issue("codex", issue_with_labels(["implementation-effort:moderate"]), "qa")

      assert {:ok, %{model: "sonnet", reasoning_effort: "low", no_thinking: true}} =
               ImplementationEffort.profile_for_issue("claude_code", issue_with_labels(["implementation-effort:minimal"]), "qa")
    after
      restore_env("SYMPHONY_REASONING_PROFILES", previous)
      File.rm(path)
    end
  end

  test "TOML profile validation fails closed for unknown provider keys" do
    previous = System.get_env("SYMPHONY_REASONING_PROFILES")
    path = write_profiles_toml!("unknown-provider", "[providers.pi]\ndefault_tier = \"moderate\"\n")

    try do
      System.put_env("SYMPHONY_REASONING_PROFILES", path)

      assert {:error, {:unknown_reasoning_profile_provider, ^path, ["pi"]}} = ImplementationEffort.profiles()
    after
      restore_env("SYMPHONY_REASONING_PROFILES", previous)
      File.rm(path)
    end
  end

  test "TOML profile validation fails closed for missing default tier" do
    previous = System.get_env("SYMPHONY_REASONING_PROFILES")
    path = write_profiles_toml!("missing-default", "remove_claude_default = true")

    try do
      System.put_env("SYMPHONY_REASONING_PROFILES", path)

      assert {:error, {:missing_reasoning_profile_default_tier, ^path, "claude_code"}} =
               ImplementationEffort.profiles()
    after
      restore_env("SYMPHONY_REASONING_PROFILES", previous)
      File.rm(path)
    end
  end

  test "TOML profile validation fails closed for unsupported Claude model effort and no-thinking rows" do
    previous = System.get_env("SYMPHONY_REASONING_PROFILES")
    sonnet_xhigh = write_profiles_toml!("sonnet-xhigh", "minimal_worker_effort = \"xhigh\"")

    fable_no_thinking =
      write_profiles_toml!("fable-no-thinking", "minimal_worker_model = \"fable\"\nminimal_worker_no_thinking = true")

    try do
      System.put_env("SYMPHONY_REASONING_PROFILES", sonnet_xhigh)

      expected_model_effort_error =
        {:unsupported_reasoning_profile_model_effort, sonnet_xhigh, "claude_code", ["minimal", "worker"], "sonnet", "xhigh"}

      assert {:error, ^expected_model_effort_error} = ImplementationEffort.profiles()

      System.put_env("SYMPHONY_REASONING_PROFILES", fable_no_thinking)

      expected_no_thinking_error =
        {:unsupported_reasoning_profile_no_thinking, fable_no_thinking, "claude_code", ["minimal", "worker"], "fable"}

      assert {:error, ^expected_no_thinking_error} = ImplementationEffort.profiles()
    after
      restore_env("SYMPHONY_REASONING_PROFILES", previous)
      File.rm(sonnet_xhigh)
      File.rm(fable_no_thinking)
    end
  end

  test "TOML parse errors fail closed" do
    previous = System.get_env("SYMPHONY_REASONING_PROFILES")
    path = Path.join(System.tmp_dir!(), "bad-reasoning-profiles-#{System.unique_integer([:positive])}.toml")
    File.write!(path, "[providers.codex\n")

    try do
      System.put_env("SYMPHONY_REASONING_PROFILES", path)

      assert {:error, {:invalid_reasoning_profiles_toml, ^path, _reason}} = ImplementationEffort.profiles()
    after
      restore_env("SYMPHONY_REASONING_PROFILES", previous)
      File.rm(path)
    end
  end

  test "TOML profile validation rejects malformed provider tier and row shapes" do
    with_profiles_toml!(
      ~S"""
      [providers]
      codex = "bad"
      claude_code = "bad"
      """,
      fn path ->
        assert {:error, {:invalid_reasoning_profile_provider_shape, ^path, "codex"}} = ImplementationEffort.profiles()
      end
    )

    with_profiles_toml!(replace_once(profiles_toml(""), "default_tier = \"high\"", "default_tier = \"medium\""), fn path ->
      assert {:error, {:invalid_reasoning_profile_default_tier, ^path, "codex", "medium"}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!("[providers.codex]\ndefault_tier = \"high\"\n\n" <> claude_profiles_toml(), fn path ->
      assert {:error, {:missing_reasoning_profile_tiers, ^path, "codex"}} = ImplementationEffort.profiles()
    end)

    tier_shape =
      """
      [providers.codex]
      default_tier = "high"
      [providers.codex.tiers]
      extreme = "bad"
      high = "bad"
      moderate = "bad"
      low = "bad"
      minimal = "bad"

      #{claude_profiles_toml()}
      """

    with_profiles_toml!(tier_shape, fn path ->
      assert {:error, {:invalid_reasoning_profile_tier_shape, ^path, "codex", "extreme"}} =
               ImplementationEffort.profiles()
    end)

    row_shape =
      replace_once(profiles_toml(""), "[providers.codex.tiers.extreme.reviewer]\neffort = \"xhigh\"", """
      [providers.codex.tiers.extreme]
      reviewer = "bad"
      """)

    with_profiles_toml!(row_shape, fn path ->
      assert {:error, {:invalid_reasoning_profile_row_shape, ^path, "codex", ["extreme", "reviewer"]}} =
               ImplementationEffort.profiles()
    end)
  end

  test "TOML profile validation rejects malformed row values" do
    missing_effort =
      replace_once(profiles_toml(""), "[providers.codex.tiers.extreme.reviewer]\neffort = \"xhigh\"", """
      [providers.codex.tiers.extreme.reviewer]
      model = "ignored"
      """)

    with_profiles_toml!(missing_effort, fn path ->
      assert {:error, {:missing_reasoning_profile_effort, ^path, "codex", ["extreme", "reviewer"]}} =
               ImplementationEffort.profiles()
    end)

    invalid_model = replace_once(profiles_toml(""), "model = \"sonnet\"\neffort = \"low\"", "model = 1\neffort = \"low\"")

    with_profiles_toml!(invalid_model, fn path ->
      assert {:error, {:invalid_reasoning_profile_model, ^path, "claude_code", ["minimal", "worker"]}} =
               ImplementationEffort.profiles()
    end)

    invalid_no_thinking =
      replace_once(profiles_toml(""), "no_thinking = true", "no_thinking = \"yes\"")

    with_profiles_toml!(invalid_no_thinking, fn path ->
      assert {:error, {:invalid_reasoning_profile_no_thinking, ^path, "claude_code", ["minimal", "worker"]}} =
               ImplementationEffort.profiles()
    end)

    no_model_no_thinking =
      replace_once(profiles_toml(""), "model = \"sonnet\"\neffort = \"low\"\nno_thinking = true", """
      effort = "low"
      no_thinking = true
      """)

    with_profiles_toml!(no_model_no_thinking, fn path ->
      assert {:error, {:unsupported_reasoning_profile_no_thinking, ^path, "claude_code", ["minimal", "worker"], nil}} =
               ImplementationEffort.profiles()
    end)
  end

  test "TOML profile validation covers restricted Claude max effort model checks" do
    supported_max =
      replace_once(profiles_toml(""), "model = \"sonnet\"\neffort = \"low\"", """
      model = "us.anthropic.claude-sonnet-4-6"
      effort = "max"
      """)

    with_profiles_toml!(supported_max, fn _path ->
      assert {:ok, _profiles} = ImplementationEffort.profiles()
    end)

    no_model_max =
      replace_once(profiles_toml(""), "model = \"sonnet\"\neffort = \"low\"\nno_thinking = true", """
      effort = "max"
      """)

    with_profiles_toml!(no_model_max, fn path ->
      assert {:error, {:unsupported_reasoning_profile_model_effort, ^path, "claude_code", ["minimal", "worker"], nil, "max"}} =
               ImplementationEffort.profiles()
    end)

    blank_model_max =
      replace_once(profiles_toml(""), "model = \"sonnet\"\neffort = \"low\"", """
      model = "   "
      effort = "max"
      """)

    with_profiles_toml!(blank_model_max, fn path ->
      expected = {:unsupported_reasoning_profile_model_effort, path, "claude_code", ["minimal", "worker"], "   ", "max"}

      assert {:error, ^expected} = ImplementationEffort.profiles()
    end)

    unknown_model_max =
      replace_once(profiles_toml(""), "model = \"sonnet\"\neffort = \"low\"", """
      model = "some-future-model"
      effort = "max"
      """)

    with_profiles_toml!(unknown_model_max, fn path ->
      expected =
        {:unsupported_reasoning_profile_model_effort, path, "claude_code", ["minimal", "worker"], "some-future-model", "max"}

      assert {:error, ^expected} = ImplementationEffort.profiles()
    end)
  end

  test "Claude profile lookup normalizes providers and non-list labels" do
    issue = issue_with_labels(:not_a_list)

    assert {:ok, %{provider: "claude_code", effort: "moderate", source: "default"}} =
             ImplementationEffort.profile_for_issue(:claude_code, issue, "qa")

    assert {:ok, %{provider: "claude_code", effort: "moderate", source: "default"}} =
             ImplementationEffort.profile_for_issue(" CLAUDE_CODE ", issue, "qa")
  end

  test "Claude ambiguous labels use the moderate default tier" do
    issue = issue_with_labels(["implementation-effort:low", "implementation-effort:minimal"])

    assert {:ok, %{provider: "claude_code", effort: "moderate", source: "default_ambiguous_label"}} =
             ImplementationEffort.profile_for_issue("claude_code", issue, "qa")
  end

  defp issue_with_labels(labels) do
    %Issue{
      id: "issue-effort",
      identifier: "MT-200",
      title: "Effort test",
      state: "Todo",
      labels: labels
    }
  end

  defp write_profiles_toml!(name, mutations) do
    path = Path.join(System.tmp_dir!(), "reasoning-profiles-#{name}-#{System.unique_integer([:positive])}.toml")
    File.write!(path, profiles_toml(mutations))
    path
  end

  defp with_profiles_toml!(toml, fun) do
    previous = System.get_env("SYMPHONY_REASONING_PROFILES")
    path = Path.join(System.tmp_dir!(), "reasoning-profiles-#{System.unique_integer([:positive])}.toml")
    File.write!(path, toml)

    try do
      System.put_env("SYMPHONY_REASONING_PROFILES", path)
      fun.(path)
    after
      restore_env("SYMPHONY_REASONING_PROFILES", previous)
      File.rm(path)
    end
  end

  defp replace_once(value, pattern, replacement) do
    String.replace(value, pattern, replacement, global: false)
  end

  defp claude_profiles_toml do
    [_, claude] = String.split(profiles_toml(""), "[providers.claude_code]", parts: 2)
    "[providers.claude_code]" <> claude
  end

  defp profiles_toml(mutations) do
    minimal_worker_model = mutation_value(mutations, "minimal_worker_model", "sonnet")
    minimal_worker_effort = mutation_value(mutations, "minimal_worker_effort", "low")
    minimal_worker_no_thinking = mutation_value(mutations, "minimal_worker_no_thinking", "true")
    claude_default = if String.contains?(mutations, "remove_claude_default"), do: "", else: "default_tier = \"moderate\""

    """
    [providers.codex]
    default_tier = "high"

    [providers.codex.tiers.extreme.reviewer]
    effort = "xhigh"
    [providers.codex.tiers.extreme.worker]
    effort = "high"
    [providers.codex.tiers.high.reviewer]
    effort = "xhigh"
    [providers.codex.tiers.high.worker]
    effort = "high"
    [providers.codex.tiers.moderate.reviewer]
    effort = "high"
    [providers.codex.tiers.moderate.worker]
    effort = "medium"
    [providers.codex.tiers.low.reviewer]
    effort = "medium"
    [providers.codex.tiers.low.worker]
    effort = "low"
    [providers.codex.tiers.minimal.reviewer]
    effort = "low"
    [providers.codex.tiers.minimal.worker]
    effort = "none"

    [providers.claude_code]
    #{claude_default}
    [providers.claude_code.fixed]
    model = "opus"
    effort = "high"

    [providers.claude_code.tiers.extreme.reviewer]
    model = "fable"
    effort = "xhigh"
    [providers.claude_code.tiers.extreme.worker]
    model = "opus"
    effort = "xhigh"
    [providers.claude_code.tiers.high.reviewer]
    model = "fable"
    effort = "high"
    [providers.claude_code.tiers.high.worker]
    model = "opus"
    effort = "high"
    [providers.claude_code.tiers.moderate.reviewer]
    model = "opus"
    effort = "high"
    [providers.claude_code.tiers.moderate.worker]
    model = "sonnet"
    effort = "high"
    [providers.claude_code.tiers.low.reviewer]
    model = "sonnet"
    effort = "high"
    [providers.claude_code.tiers.low.worker]
    model = "sonnet"
    effort = "medium"
    [providers.claude_code.tiers.minimal.reviewer]
    model = "sonnet"
    effort = "medium"
    [providers.claude_code.tiers.minimal.worker]
    model = "#{minimal_worker_model}"
    effort = "#{minimal_worker_effort}"
    no_thinking = #{minimal_worker_no_thinking}

    #{if String.contains?(mutations, "[providers.pi]"), do: mutations, else: ""}
    """
  end

  defp mutation_value(mutations, key, default) do
    case Regex.run(~r/#{key}\s*=\s*"?([^"\n]+)"?/, mutations) do
      [_, value] -> value
      _ -> default
    end
  end
end
