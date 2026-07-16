defmodule SymphonyElixir.TestAgentProfileFixture do
  @moduledoc false

  def install! do
    root = Path.join(System.tmp_dir!(), "symphony-agent-profiles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    write!(root, "implementer-orchestrator", "orchestrator", "implementer", true, "gpt-5.6-sol", "claude-fable-5", :implementer)
    write!(root, "implementer-worker", "worker", "implementer", false, "gpt-5.6-luna", "claude-sonnet-5", :implementer)
    write!(root, "reviewer", "orchestrator", "reviewer", false, "gpt-5.5", "claude-opus-4-8", :review)
    write!(root, "qa", "orchestrator", "qa", false, "gpt-5.5", "claude-opus-4-8", :review)
    write!(root, "landing", "orchestrator", "landing", false, "gpt-5.5", "claude-opus-4-8", :standard)
    write!(root, "backlog-processor", "orchestrator", "backlog-processor", false, "gpt-5.5", "claude-opus-4-8", :standard)
    write!(root, "default", "orchestrator", "default", false, "gpt-5.5", "claude-opus-4-8", :standard)

    System.put_env("SYMPHONY_AGENT_PROFILES", root)
    root
  end

  defp write!(root, name, kind, role, can_delegate, codex_model, claude_model, matrix) do
    {codex_efforts, claude_efforts} = efforts(matrix)
    owns_run = kind == "orchestrator" and name != "default"

    File.write!(Path.join(root, "#{name}.agent.md"), """
    +++
    schema_version = 1
    name = "#{name}"
    kind = "#{kind}"
    role = "#{role}"

    [capabilities]
    can_delegate = #{can_delegate}
    max_delegation_depth = #{if(can_delegate, do: 1, else: 0)}
    owns_issue_lifecycle = #{owns_run}
    owns_final_validation = #{owns_run}
    owns_handoff = #{owns_run}

    [providers.codex]
    default_tier = "moderate"
    #{rows(codex_model, codex_efforts, matrix, :codex)}

    [providers.claude_code]
    default_tier = "moderate"
    #{rows(claude_model, claude_efforts, matrix, :claude_code)}
    +++

    # #{name}

    Reusable #{name} instructions.
    """)
  end

  defp efforts(:implementer), do: {~w(xhigh high medium low none), ~w(xhigh high medium low low)}
  defp efforts(:review), do: {~w(xhigh xhigh high medium low), ~w(xhigh high high high medium)}
  defp efforts(:standard), do: {~w(xhigh high medium low none), ~w(xhigh high medium low low)}

  defp rows(model, efforts, matrix, provider) do
    ~w(extreme high moderate low minimal)
    |> Enum.zip(efforts)
    |> Enum.map_join("\n", fn {tier, effort} ->
      resolved_model = tier_model(model, matrix, provider, tier)
      ~s(#{tier} = { model = "#{resolved_model}", reasoning_effort = "#{effort}" })
    end)
  end

  defp tier_model(_model, :review, :claude_code, tier) when tier in ~w(extreme high),
    do: "claude-fable-5"

  defp tier_model(_model, :review, :claude_code, "moderate"), do: "claude-opus-4-8"
  defp tier_model(_model, :review, :claude_code, _tier), do: "claude-sonnet-4-6"
  defp tier_model(model, _matrix, _provider, _tier), do: model
end
