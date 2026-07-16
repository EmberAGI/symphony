defmodule SymphonyElixir.ImplementationEffortTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ImplementationEffort

  test "resolves the complete twenty-cell Implementer matrix from two agent profiles" do
    tiers = ~w(extreme high moderate low minimal)

    for {provider, orchestrator_model, worker_model, efforts} <- [
          {:codex, "gpt-5.6-sol", "gpt-5.6-luna", ~w(xhigh high medium low none)},
          {:claude_code, "claude-fable-5", "claude-sonnet-5", ~w(xhigh high medium low low)}
        ],
        {tier, effort} <- Enum.zip(tiers, efforts) do
      assert {:ok, %{orchestrator: orchestrator, worker: worker}} =
               ImplementationEffort.runtime_profile_for_issue(
                 provider,
                 issue_with_labels(["implementation-effort:#{tier}"]),
                 "implementer"
               )

      assert %{
               name: "implementer-orchestrator",
               kind: "orchestrator",
               effort: ^tier,
               model: ^orchestrator_model,
               reasoning_effort: ^effort
             } = orchestrator

      assert %{
               name: "implementer-worker",
               kind: "worker",
               effort: ^tier,
               model: ^worker_model,
               reasoning_effort: ^effort
             } = worker

      assert orchestrator.instructions =~ "Reusable implementer-orchestrator instructions"
      assert worker.instructions =~ "Reusable implementer-worker instructions"
    end
  end

  test "every role defaults to the moderate tier for both providers" do
    for provider <- [:codex, :claude_code], role <- ~w(implementer reviewer qa landing backlog-processor) do
      assert {:ok, %{effort: "moderate", source: "default", role: ^role}} =
               ImplementationEffort.profile_for_issue(provider, issue_with_labels([]), role)
    end
  end

  test "non-Implementer roles resolve one orchestrator and no worker" do
    for provider <- [:codex, :claude_code], role <- ~w(reviewer qa landing backlog-processor) do
      assert {:ok, %{role: ^role, orchestrator: orchestrator, worker: nil}} =
               ImplementationEffort.runtime_profile_for_issue(
                 provider,
                 issue_with_labels(["implementation-effort:high"]),
                 role
               )

      assert orchestrator.name == role
      assert orchestrator.kind == "orchestrator"
    end
  end

  test "unknown roles use the default profile without issue authority" do
    assert {:ok, profile} =
             ImplementationEffort.profile_for_issue(:codex, issue_with_labels([]), "unconfigured-role")

    assert profile.name == "default"
    assert profile.role == "default"
    refute profile.capabilities.owns_issue_lifecycle
  end

  test "labels are case-insensitive and Codex rejects invalid or ambiguous selection" do
    assert {:ok, %{effort: "moderate", source: "label"}} =
             ImplementationEffort.profile_for_issue(
               issue_with_labels(["Implementation-Effort:MoDeRaTe"]),
               "implementer"
             )

    assert {:error, {:ambiguous_implementation_effort_labels, labels}} =
             ImplementationEffort.profile_for_issue(
               issue_with_labels(["implementation-effort:low", "implementation-effort:minimal"]),
               "implementer"
             )

    assert labels == ["implementation-effort:low", "implementation-effort:minimal"]

    assert {:error, {:invalid_implementation_effort_labels, ["implementation-effort:medium"]}} =
             ImplementationEffort.profile_for_issue(
               issue_with_labels(["implementation-effort:medium"]),
               "implementer"
             )
  end

  test "Claude invalid or ambiguous selection uses the moderate default" do
    for labels <- [
          ["implementation-effort:bogus"],
          ["implementation-effort:low", "implementation-effort:minimal"]
        ] do
      assert {:ok, %{effort: "moderate", source: source}} =
               ImplementationEffort.profile_for_issue(:claude_code, issue_with_labels(labels), "qa")

      assert source in ["default_invalid_label", "default_ambiguous_label"]
    end
  end

  test "profile catalog path is required and malformed catalogs fail closed" do
    previous = System.get_env("SYMPHONY_AGENT_PROFILES")
    System.delete_env("SYMPHONY_AGENT_PROFILES")

    try do
      assert {:error, :missing_agent_profiles_path} = ImplementationEffort.profiles()
    after
      restore_env("SYMPHONY_AGENT_PROFILES", previous)
    end
  end

  test "runtime contract rejects missing and capability-inconsistent profiles" do
    assert {:error, :missing_implementer_delegation_contract} =
             ImplementationEffort.validate_runtime_contract(%{role: "implementer"})

    assert {:ok, contract} =
             ImplementationEffort.runtime_profile_for_issue(
               :codex,
               issue_with_labels(["implementation-effort:moderate"]),
               "implementer"
             )

    assert {:error, :implementer_worker_may_delegate} =
             contract
             |> put_in([:worker, :capabilities, :can_delegate], true)
             |> ImplementationEffort.validate_runtime_contract()
  end

  test "Codex command projection applies complete agent profiles" do
    issue = issue_with_labels(["implementation-effort:minimal"])
    command = "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' app-server"

    assert {:ok, {implementer, %{reasoning_effort: "none"}}} =
             ImplementationEffort.command_for_issue(command, issue, "implementer")

    assert implementer =~ "--config 'model=\"gpt-5.6-sol\"'"
    assert implementer =~ "--config model_reasoning_effort=none"
    assert implementer =~ "developer_instructions=\"# implementer-orchestrator"

    assert {:ok, {landing, %{role: "landing", reasoning_effort: "none"}}} =
             ImplementationEffort.command_for_issue(command, issue, "landing")

    assert landing =~ "--config 'model=\"gpt-5.5\"'"
    assert landing =~ "--config model_reasoning_effort=none"
    assert landing =~ "developer_instructions=\"# landing"
  end

  test "resolved profiles retain source provenance after catalog changes" do
    assert {:ok, %{orchestrator: orchestrator}} =
             ImplementationEffort.runtime_profile_for_issue(
               :codex,
               issue_with_labels(["implementation-effort:moderate"]),
               "implementer"
             )

    previous = System.get_env("SYMPHONY_AGENT_PROFILES")
    System.put_env("SYMPHONY_AGENT_PROFILES", "/definitely/missing/profiles")

    try do
      projected = ImplementationEffort.apply_codex_orchestrator("codex app-server", orchestrator)

      assert projected =~ "--config model_reasoning_effort=medium"
      assert projected =~ "--config 'model=\"gpt-5.6-sol\"'"
      assert projected =~ "developer_instructions=\"# implementer-orchestrator"
      assert projected =~ "Reusable implementer-orchestrator instructions."
    after
      restore_env("SYMPHONY_AGENT_PROFILES", previous)
    end
  end

  defp issue_with_labels(labels) do
    %Issue{
      id: "issue-id",
      identifier: "EMB-1",
      title: "Implementation effort fixture",
      state: "Todo",
      labels: labels
    }
  end
end
