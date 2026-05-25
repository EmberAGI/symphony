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

  defp issue_with_labels(labels) do
    %Issue{
      id: "issue-effort",
      identifier: "MT-200",
      title: "Effort test",
      state: "Todo",
      labels: labels
    }
  end
end
