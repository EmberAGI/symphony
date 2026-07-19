defmodule SymphonyElixir.ImplementationEffortContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ImplementationEffort

  test "parse_labels/1 resolves the codex default profile straight from Linear labels" do
    assert {:ok, %{effort: "moderate", source: "default", provider: "codex"}} = ImplementationEffort.parse_labels([])

    assert {:ok, %{effort: "high", source: "label", provider: "codex"}} =
             ImplementationEffort.parse_labels(["implementation-effort:high"])
  end

  test "runtime contract rejects an orchestrator profile whose name was substituted" do
    assert {:ok, contract} =
             ImplementationEffort.runtime_profile_for_issue(
               :codex,
               issue_with_labels(["implementation-effort:moderate"]),
               "implementer"
             )

    assert {:error, {:invalid_implementer_orchestrator_profile, "renamed-orchestrator"}} =
             contract
             |> put_in([:orchestrator, :name], "renamed-orchestrator")
             |> ImplementationEffort.validate_runtime_contract()
  end

  test "runtime contract rejects a worker profile whose name was substituted" do
    assert {:ok, contract} =
             ImplementationEffort.runtime_profile_for_issue(
               :codex,
               issue_with_labels(["implementation-effort:moderate"]),
               "implementer"
             )

    assert {:error, {:invalid_implementer_worker_profile, "renamed-worker"}} =
             contract
             |> put_in([:worker, :name], "renamed-worker")
             |> ImplementationEffort.validate_runtime_contract()
  end

  test "runtime contract rejects mismatched orchestrator/worker effort tiers" do
    assert {:ok, contract} =
             ImplementationEffort.runtime_profile_for_issue(
               :codex,
               issue_with_labels(["implementation-effort:moderate"]),
               "implementer"
             )

    assert {:error, {:mixed_implementer_effort, "moderate", "high"}} =
             contract
             |> put_in([:worker, :effort], "high")
             |> ImplementationEffort.validate_runtime_contract()
  end

  test "runtime contract catch-all rejects shapes that are neither Implementer nor single-orchestrator contracts" do
    assert {:error, :invalid_runtime_profile_contract} =
             ImplementationEffort.validate_runtime_contract(%{
               role: "reviewer",
               orchestrator: %{name: "reviewer"},
               worker: %{name: "implementer-worker"}
             })
  end

  test "apply_codex_lead/2 is a compatibility alias for apply_codex_orchestrator/2" do
    assert {:ok, %{orchestrator: orchestrator}} =
             ImplementationEffort.runtime_profile_for_issue(
               :codex,
               issue_with_labels(["implementation-effort:moderate"]),
               "implementer"
             )

    assert ImplementationEffort.apply_codex_lead("codex app-server", orchestrator) ==
             ImplementationEffort.apply_codex_orchestrator("codex app-server", orchestrator)
  end

  test "valid_labels?/1 validates an Issue's labels and defaults true for non-Issue terms" do
    assert ImplementationEffort.valid_labels?(issue_with_labels(["implementation-effort:high"]))
    refute ImplementationEffort.valid_labels?(issue_with_labels(["implementation-effort:bogus"]))
    assert ImplementationEffort.valid_labels?(nil)
    assert ImplementationEffort.valid_labels?(%{})
  end

  test "issue_tier defaults to moderate when an issue's labels are not a list" do
    issue = %Issue{id: "issue-x", identifier: "EMB-9", title: "No labels list", state: "Todo", labels: nil}

    assert {:ok, %{effort: "moderate", source: "default"}} =
             ImplementationEffort.profile_for_issue(:codex, issue, "implementer")
  end

  test "profile_for_issue rejects an unsupported atom provider" do
    assert {:error, {:unsupported_agent_profile_provider, "bogus"}} =
             ImplementationEffort.profile_for_issue(:bogus, issue_with_labels([]), "implementer")
  end

  test "profile_for_issue rejects a provider that is neither an atom nor a string" do
    assert {:error, {:unsupported_agent_profile_provider, 123}} =
             ImplementationEffort.profile_for_issue(123, issue_with_labels([]), "implementer")
  end

  test "non-string labels are normalized to blank and ignored during selection" do
    issue = issue_with_labels([123, "implementation-effort:moderate"])

    assert {:ok, %{effort: "moderate", source: "label"}} =
             ImplementationEffort.profile_for_issue(:codex, issue, "implementer")
  end

  test "Codex command projection appends configuration when no app-server suffix or prior config exists" do
    issue = issue_with_labels(["implementation-effort:minimal"])
    command = "codex"

    assert {:ok, {projected, profile}} = ImplementationEffort.command_for_issue(command, issue, "implementer")

    assert projected =~ "codex --config model_reasoning_effort=#{profile.reasoning_effort}"
    assert projected =~ "--config 'model=\"#{profile.model}\"'"
    assert projected =~ "--config 'developer_instructions="
  end

  test "Codex command projection rewrites a bare --config model=\"...\" flag in place" do
    issue = issue_with_labels(["implementation-effort:minimal"])
    command = ~s(codex --config model="gpt-5.5")

    assert {:ok, {projected, profile}} = ImplementationEffort.command_for_issue(command, issue, "implementer")

    assert projected =~ ~s(--config model="#{profile.model}")
    refute projected =~ "gpt-5.5"
  end

  defp issue_with_labels(labels) do
    %Issue{
      id: "issue-id",
      identifier: "EMB-1",
      title: "Implementation effort contract fixture",
      state: "Todo",
      labels: labels
    }
  end
end
