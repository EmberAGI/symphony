defmodule SymphonyElixir.ImplementationEffortTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ImplementationEffort

  setup do
    previous = System.get_env("SYMPHONY_REASONING_PROFILES")
    System.delete_env("SYMPHONY_REASONING_PROFILES")

    on_exit(fn -> restore_env("SYMPHONY_REASONING_PROFILES", previous) end)
  end

  test "built-in Codex policy resolves actual roles with default fallback" do
    cases = [
      {"implementation-effort:extreme", "high", "xhigh", "xhigh"},
      {"implementation-effort:high", "high", "xhigh", "xhigh"},
      {"implementation-effort:moderate", "medium", "high", "high"},
      {"implementation-effort:low", "low", "medium", "medium"},
      {"implementation-effort:minimal", "none", "low", "low"}
    ]

    Enum.each(cases, fn {label, implementer, reviewer, qa} ->
      issue = issue_with_labels([label])

      assert {:ok, %{source: "label", reasoning_effort: ^implementer}} =
               ImplementationEffort.profile_for_issue(issue, "implementer")

      assert {:ok, %{source: "label", reasoning_effort: ^reviewer}} =
               ImplementationEffort.profile_for_issue(issue, "reviewer")

      assert {:ok, %{source: "label", reasoning_effort: ^qa}} =
               ImplementationEffort.profile_for_issue(issue, "qa")
    end)

    assert {:ok, %{role: "landing", reasoning_effort: "high"}} =
             ImplementationEffort.profile_for_issue(issue_with_labels(["implementation-effort:minimal"]), "landing")
  end

  test "built-in Claude policy resolves actual roles with default fallback" do
    cases = [
      {"implementation-effort:extreme", "opus", "xhigh", false, "fable", "xhigh", "fable", "xhigh"},
      {"implementation-effort:high", "opus", "high", false, "fable", "high", "fable", "high"},
      {"implementation-effort:moderate", "sonnet", "high", false, "opus", "high", "opus", "high"},
      {"implementation-effort:low", "sonnet", "medium", false, "sonnet", "high", "sonnet", "high"},
      {"implementation-effort:minimal", "sonnet", "low", true, "sonnet", "medium", "sonnet", "medium"}
    ]

    Enum.each(cases, fn {label, implementer_model, implementer_effort, implementer_no_thinking, reviewer_model, reviewer_effort, qa_model, qa_effort} ->
      issue = issue_with_labels([label])

      assert {:ok,
              %{
                source: "label",
                model: ^implementer_model,
                reasoning_effort: ^implementer_effort,
                no_thinking: ^implementer_no_thinking
              }} =
               ImplementationEffort.profile_for_issue("claude_code", issue, "implementer")

      assert {:ok, %{source: "label", model: ^reviewer_model, reasoning_effort: ^reviewer_effort}} =
               ImplementationEffort.profile_for_issue("claude_code", issue, "reviewer")

      assert {:ok, %{source: "label", model: ^qa_model, reasoning_effort: ^qa_effort, no_thinking: false}} =
               ImplementationEffort.profile_for_issue("claude_code", issue, "qa")
    end)

    assert {:ok, %{role: "landing", model: "opus", reasoning_effort: "high"}} =
             ImplementationEffort.profile_for_issue(
               "claude_code",
               issue_with_labels(["implementation-effort:minimal"]),
               "landing"
             )
  end

  test "parses implementation effort labels case-insensitively" do
    issue = issue_with_labels(["Implementation-Effort:MoDeRaTe"])

    assert {:ok, %{effort: "moderate", source: "label", reasoning_effort: "medium"}} =
             ImplementationEffort.profile_for_issue(issue, "IMPLEMENTER")
  end

  test "missing effort label uses the provider default tier" do
    issue = issue_with_labels(["backend"])

    assert {:ok, %{effort: "high", source: "default", role: "qa", reasoning_effort: "xhigh"}} =
             ImplementationEffort.profile_for_issue(issue, "qa")

    assert {:ok, %{effort: "moderate", source: "default", model: "sonnet", reasoning_effort: "high"}} =
             ImplementationEffort.profile_for_issue("claude_code", issue, "implementer")
  end

  test "Codex invalid and ambiguous effort labels fail closed" do
    assert {:error, {:ambiguous_implementation_effort_labels, labels}} =
             ImplementationEffort.profile_for_issue(
               issue_with_labels(["implementation-effort:low", "implementation-effort:minimal"]),
               "implementer"
             )

    assert labels == ["implementation-effort:low", "implementation-effort:minimal"]

    for label <- ["implementation-effort:medium", "implementation-effort:"] do
      assert {:error, {:invalid_implementation_effort_labels, [^label]}} =
               ImplementationEffort.profile_for_issue(issue_with_labels([label]), "implementer")
    end
  end

  test "Claude missing malformed unsupported and ambiguous labels use the default tier" do
    for labels <- [
          [],
          ["implementation-effort:"],
          ["implementation-effort:bogus"],
          ["implementation-effort:low", "implementation-effort:minimal"]
        ] do
      assert {:ok,
              %{
                provider: "claude_code",
                effort: "moderate",
                model: "opus",
                reasoning_effort: "high"
              }} = ImplementationEffort.profile_for_issue("claude_code", issue_with_labels(labels), "qa")
    end
  end

  test "Codex command rewrite applies only to dynamic roles" do
    issue = issue_with_labels(["implementation-effort:minimal"])
    command = "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' app-server"

    assert {:ok, {implementer, %{reasoning_effort: "none"}}} =
             ImplementationEffort.command_for_issue(command, issue, "implementer")

    assert implementer ==
             "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=none app-server"

    assert {:ok, {qa, %{reasoning_effort: "low"}}} =
             ImplementationEffort.command_for_issue(command, issue, "qa")

    assert qa ==
             "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=low app-server"

    assert {:ok, {^command, %{role: "landing", reasoning_effort: "high"}}} =
             ImplementationEffort.command_for_issue(command, issue, "landing")
  end

  test "Codex model cells rewrite model config while effort-only cells keep the base model" do
    issue = issue_with_labels(["implementation-effort:low"])

    with_profiles_toml!(replace_once(profiles_toml(), "low = \"low\"", "low = \"gpt-5.4/low\""), fn _path ->
      cases = [
        {"codex --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=high app-server", "codex --config 'model=\"gpt-5.4\"' --config model_reasoning_effort=low app-server"},
        {~s(codex --config model="gpt-5.5" --config model_reasoning_effort=high app-server), ~s(codex --config model="gpt-5.4" --config model_reasoning_effort=low app-server)},
        {"codex --config shell_environment_policy.inherit=all app-server",
         "codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=low --config 'model=\"gpt-5.4\"' app-server"},
        {"codex exec --json", "codex exec --json --config model_reasoning_effort=low --config 'model=\"gpt-5.4\"'"}
      ]

      Enum.each(cases, fn {command, expected} ->
        assert {:ok, {^expected, %{model: "gpt-5.4", reasoning_effort: "low"}}} =
                 ImplementationEffort.command_for_issue(command, issue, "implementer")
      end)
    end)

    assert {:ok, {"codex --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=low app-server", %{model: nil, reasoning_effort: "low"}}} =
             ImplementationEffort.command_for_issue(
               "codex --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=high app-server",
               issue,
               "implementer"
             )
  end

  test "Codex reasoning rewrite appends to commands without app-server suffix" do
    assert {:ok, {"codex exec --json --config model_reasoning_effort=medium", %{reasoning_effort: "medium"}}} =
             ImplementationEffort.command_for_issue(
               "codex exec --json",
               issue_with_labels(["implementation-effort:moderate"]),
               "implementer"
             )
  end

  test "loads role-first profiles from SYMPHONY_REASONING_PROFILES TOML" do
    with_profiles_toml!(profiles_toml(), fn _path ->
      assert {:ok, %{reasoning_effort: "high"}} =
               ImplementationEffort.profile_for_issue("codex", issue_with_labels(["implementation-effort:moderate"]), "qa")

      assert {:ok, %{model: "sonnet", reasoning_effort: "low", no_thinking: true}} =
               ImplementationEffort.profile_for_issue(
                 "claude_code",
                 issue_with_labels(["implementation-effort:minimal"]),
                 "implementer"
               )
    end)
  end

  test "role scalar cells are tier invariant" do
    toml =
      profiles_toml()
      |> replace_once("default = \"high\"", "default = \"low\"")
      |> replace_once("default = \"opus/high\"", "default = \"sonnet/medium\"")

    with_profiles_toml!(toml, fn _path ->
      for tier <- ["extreme", "minimal"] do
        assert {:ok, %{reasoning_effort: "low"}} =
                 ImplementationEffort.profile_for_issue("codex", issue_with_labels(["implementation-effort:#{tier}"]), "landing")

        assert {:ok, %{model: "sonnet", reasoning_effort: "medium"}} =
                 ImplementationEffort.profile_for_issue(
                   "claude_code",
                   issue_with_labels(["implementation-effort:#{tier}"]),
                   "backlog-processor"
                 )
      end
    end)
  end

  test "profile validation rejects legacy provider shape" do
    legacy = """
    [providers.codex]
    default_tier = "high"
    default = "high"
    [providers.codex.tiers.moderate.worker]
    effort = "medium"

    #{claude_profiles_toml()}
    """

    with_profiles_toml!(legacy, fn path ->
      assert {:error, {:unknown_reasoning_profile_key, ^path, "codex", ["tiers"]}} = ImplementationEffort.profiles()
    end)
  end

  test "profile validation rejects malformed provider and default keys" do
    with_profiles_toml!("[providers]\ncodex = \"bad\"\n\n#{claude_profiles_toml()}", fn path ->
      assert {:error, {:invalid_reasoning_profile_provider_shape, ^path, "codex"}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(String.replace(profiles_toml(), "[providers.claude_code]", "[providers.pi]", global: false), fn path ->
      assert {:error, {:unknown_reasoning_profile_provider, ^path, ["pi"]}} = ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "default_tier = \"high\"", ""), fn path ->
      assert {:error, {:missing_reasoning_profile_key, ^path, "codex", ["default_tier"]}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "default = \"high\"", ""), fn path ->
      assert {:error, {:missing_reasoning_profile_key, ^path, "codex", ["default"]}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "default_tier = \"high\"", "default_tier = \"medium\""), fn path ->
      assert {:error, {:invalid_reasoning_profile_default_tier, ^path, "codex", "medium"}} =
               ImplementationEffort.profiles()
    end)
  end

  test "profile validation rejects unknown roles and unknown or incomplete tier tables" do
    with_profiles_toml!(profiles_toml() <> "\n[providers.codex.worker]\nlow = \"low\"\n", fn path ->
      assert {:error, {:unknown_reasoning_profile_key, ^path, "codex", ["worker"]}} = ImplementationEffort.profiles()
    end)

    unknown_tier = replace_once(profiles_toml(), "minimal = \"none\"", "minimal = \"none\", tiny = \"none\"")

    with_profiles_toml!(unknown_tier, fn path ->
      assert {:error, {:unknown_reasoning_profile_tier, ^path, "codex", "implementer", ["tiny"]}} =
               ImplementationEffort.profiles()
    end)

    incomplete_table = replace_once(profiles_toml(), "minimal = \"none\"", "")

    with_profiles_toml!(incomplete_table, fn path ->
      assert {:error, {:missing_reasoning_profile_tier, ^path, "codex", "implementer", ["minimal"]}} =
               ImplementationEffort.profiles()
    end)
  end

  test "profile validation rejects invalid cells" do
    cases = [
      {replace_once(profiles_toml(), "default = \"high\"", "default = \"\""), {:missing_reasoning_profile_effort, "codex", ["default"]}},
      {replace_once(profiles_toml(), "default = \"high\"", "default = \"/high\""), {:invalid_reasoning_profile_model, "codex", ["default"]}},
      {replace_once(profiles_toml(), "default = \"high\"", "default = \"model/high/extra\""), {:invalid_reasoning_profile_cell, "codex", ["default"]}},
      {replace_once(profiles_toml(), "default = \"high\"", "default = \"ludicrous\""), {:unsupported_reasoning_profile_effort, "codex", ["default"], "ludicrous"}},
      {replace_once(profiles_toml(), "default = \"high\"", "default = 1"), {:invalid_reasoning_profile_role_shape, "codex", "default"}},
      {replace_once(profiles_toml(), "minimal = \"none\"", "minimal = 1"), {:invalid_reasoning_profile_cell, "codex", ["implementer", "minimal"]}}
    ]

    Enum.each(cases, fn {toml, expected} ->
      with_profiles_toml!(toml, fn path ->
        expected = Tuple.insert_at(expected, 1, path)
        assert {:error, ^expected} = ImplementationEffort.profiles()
      end)
    end)
  end

  test "profile validation gates provider-specific unsupported combinations" do
    with_profiles_toml!(replace_once(profiles_toml(), "default = \"high\"", "default = \"max\""), fn path ->
      assert {:error, {:unsupported_reasoning_profile_effort, ^path, "codex", ["default"], "max"}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "minimal = \"sonnet/none\"", "minimal = \"fable/none\""), fn path ->
      assert {:error, {:unsupported_reasoning_profile_no_thinking, ^path, "claude_code", ["implementer", "minimal"], "fable"}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "minimal = \"sonnet/none\"", "minimal = \"none\""), fn path ->
      assert {:error, {:unsupported_reasoning_profile_no_thinking, ^path, "claude_code", ["implementer", "minimal"], nil}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "minimal = \"sonnet/none\"", "minimal = \"some-future-model/none\""), fn path ->
      assert {:error, {:unsupported_reasoning_profile_no_thinking, ^path, "claude_code", ["implementer", "minimal"], "some-future-model"}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "minimal = \"sonnet/none\"", "minimal = \"claude-sonnet-4-6/none\""), fn _path ->
      assert {:ok, _profiles} = ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "minimal = \"sonnet/none\"", "minimal = \"haiku/max\""), fn path ->
      assert {:error, {:unsupported_reasoning_profile_model_effort, ^path, "claude_code", ["implementer", "minimal"], "haiku", "max"}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "minimal = \"sonnet/none\"", "minimal = \"some-future-model/max\""), fn path ->
      assert {:error, {:unsupported_reasoning_profile_model_effort, ^path, "claude_code", ["implementer", "minimal"], "some-future-model", "max"}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "minimal = \"sonnet/none\"", "minimal = \"max\""), fn path ->
      assert {:error, {:unsupported_reasoning_profile_model_effort, ^path, "claude_code", ["implementer", "minimal"], nil, "max"}} =
               ImplementationEffort.profiles()
    end)

    with_profiles_toml!(replace_once(profiles_toml(), "minimal = \"sonnet/none\"", "minimal = \"sonnet/max\""), fn _path ->
      assert {:ok, _profiles} = ImplementationEffort.profiles()
    end)
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

  test "legacy parser and non-issue inputs use the Codex default profile" do
    assert {:ok, %{provider: "codex", effort: "high", source: "default", reasoning_effort: "high"}} =
             ImplementationEffort.parse_labels(:not_a_list)

    assert {:ok, %{provider: "codex", effort: "low", source: "label", reasoning_effort: "high"}} =
             ImplementationEffort.parse_labels(["implementation-effort:low"])

    assert {:ok, %{effort: "high", source: "default", role: "reviewer", reasoning_effort: "xhigh"}} =
             ImplementationEffort.profile_for_issue(%{not: "an issue"}, "reviewer")

    assert {:ok, %{effort: "high", source: "default", role: nil, reasoning_effort: "high"}} =
             ImplementationEffort.profile_for_issue(%{not: "an issue"}, nil)

    assert {:ok, {"codex app-server", %{role: "implementer", reasoning_effort: "high"}}} =
             ImplementationEffort.command_for_issue("codex app-server", %{not: "an issue"}, "implementer")
  end

  test "normalizes non-list labels non-binary labels non-binary roles and provider strings" do
    assert {:ok, %{effort: "high", source: "default"}} =
             ImplementationEffort.profile_for_issue(issue_with_labels(:not_a_list), "implementer")

    assert {:ok, %{effort: "moderate", role: nil, reasoning_effort: "high"}} =
             ImplementationEffort.profile_for_issue(issue_with_labels([:not_a_string, "implementation-effort:moderate"]), :role)

    assert {:ok, %{provider: "claude_code", effort: "moderate", source: "default"}} =
             ImplementationEffort.profile_for_issue(" CLAUDE_CODE ", issue_with_labels(:not_a_list), "qa")

    assert {:ok, %{provider: "claude_code", effort: "moderate", source: "default"}} =
             ImplementationEffort.profile_for_issue(:claude_code, issue_with_labels(:not_a_list), "qa")
  end

  test "valid_labels? accepts a valid issue and tolerates non-issue inputs" do
    assert ImplementationEffort.valid_labels?(issue_with_labels(["implementation-effort:low"]))
    refute ImplementationEffort.valid_labels?(issue_with_labels(["implementation-effort:bogus"]))
    assert ImplementationEffort.valid_labels?(%{not: "an issue"})
  end

  defp issue_with_labels(labels) do
    %SymphonyElixir.Linear.Issue{
      id: "issue-effort",
      identifier: "MT-200",
      title: "Effort test",
      state: "Todo",
      labels: labels
    }
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

  defp replace_once(value, pattern, replacement), do: String.replace(value, pattern, replacement, global: false)

  defp claude_profiles_toml do
    [_, claude] = String.split(profiles_toml(), "[providers.claude_code]", parts: 2)
    "[providers.claude_code]" <> claude
  end

  defp profiles_toml do
    """
    [providers.codex]
    default_tier = "high"
    default = "high"
    implementer = { extreme = "high", high = "high", moderate = "medium", low = "low", minimal = "none" }
    reviewer = { extreme = "xhigh", high = "xhigh", moderate = "high", low = "medium", minimal = "low" }
    qa = { extreme = "xhigh", high = "xhigh", moderate = "high", low = "medium", minimal = "low" }

    [providers.claude_code]
    default_tier = "moderate"
    default = "opus/high"
    implementer = { extreme = "opus/xhigh", high = "opus/high", moderate = "sonnet/high", low = "sonnet/medium", minimal = "sonnet/none" }
    reviewer = { extreme = "fable/xhigh", high = "fable/high", moderate = "opus/high", low = "sonnet/high", minimal = "sonnet/medium" }
    qa = { extreme = "fable/xhigh", high = "fable/high", moderate = "opus/high", low = "sonnet/high", minimal = "sonnet/medium" }
    """
  end
end
