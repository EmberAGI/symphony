defmodule SymphonyElixir.ClaudeCodeLaunchConfigTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Launch-configuration behavior of the first-party Claude Code shim: catalog
  implementation-effort row selection, the exact-profile launch invariant
  (agent-runtime spec: the adapter launches the resolved model and effort or
  fails visibly, never substituting another model), the config-declared
  no-thinking env propagation, and local provider auth env inheritance — all
  proved against a fake `claude` binary replaying recorded stream-json, with
  no live Claude subscription.
  """

  import SymphonyElixir.ClaudeShimFixture

  test "omits the no-thinking env when no_thinking is disabled" do
    ctx = setup_workspace("MT-CC-think")

    try do
      configure!(ctx, stream_success(), claude_code_model: "sonnet", claude_code_no_thinking: false)

      {result, _events, trace} = run_shim(ctx, "do work")

      assert {:ok, _turn} = result
      assert trace =~ "ENV_MAX_THINKING_TOKENS:\n" or trace =~ "ENV_MAX_THINKING_TOKENS:" <> "\n"
      refute trace =~ "ENV_MAX_THINKING_TOKENS:0"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "inherits local Claude OAuth token into the child process without tracing it" do
    ctx = setup_workspace("MT-CC-oauth-env")
    previous = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")

    try do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-secret-value")
      configure!(ctx, stream_success(), claude_code_model: "sonnet")

      {result, _events, trace} = run_shim(ctx, "do work")

      assert {:ok, _turn} = result
      assert trace =~ "ENV_CLAUDE_CODE_OAUTH_TOKEN_PRESENT:present"
      refute trace =~ "test-oauth-secret-value"
    after
      restore_env("CLAUDE_CODE_OAUTH_TOKEN", previous)
      File.rm_rf(ctx.test_root)
    end
  end

  test "uses the Claude implementation-effort row for non-dynamic roles" do
    ctx = setup_workspace("MT-CC-fixed")

    try do
      configure!(ctx, stream_success(), claude_code_model: "sonnet", claude_code_effort: "low", claude_code_no_thinking: true)

      {result, events, trace} =
        run_shim(ctx, "do work", labels: ["implementation-effort:minimal"], role: "landing")

      assert {:ok, _turn} = result
      assert trace =~ "--model claude-opus-4-8"
      assert trace =~ "--effort low"
      assert trace =~ "--append-system-prompt"
      assert trace =~ "Reusable landing instructions"
      # Non-Fable resolved row: the config-declared no_thinking flag propagates
      # as the verified MAX_THINKING_TOKENS=0 invocation (agent-runtime spec).
      assert trace =~ "ENV_MAX_THINKING_TOKENS:0"

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.implementation_effort == "minimal"
      assert completed.claude_model == "claude-opus-4-8"
      assert completed.claude_effort == "low"
      assert completed.claude_no_thinking == true
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "uses the moderate Claude default for malformed implementation-effort labels" do
    ctx = setup_workspace("MT-CC-default-effort")

    try do
      configure!(ctx, stream_success(), claude_code_model: "opus", claude_code_effort: "low", claude_code_no_thinking: false)

      {result, events, trace} =
        run_shim(ctx, "do work", labels: ["implementation-effort:bogus"], role: "implementer")

      assert {:ok, _turn} = result
      assert trace =~ "--model claude-fable-5"
      assert trace =~ "--effort medium"
      refute trace =~ "ENV_MAX_THINKING_TOKENS:0"

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.implementation_effort == "moderate"
      assert completed.implementation_effort_source == "default_invalid_label"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "launches the exact Fable profile row without adapter-side substitution" do
    ctx = setup_workspace("MT-CC-fable-exact")

    try do
      configure!(ctx, stream_success(), claude_code_model: "sonnet", claude_code_effort: "low", claude_code_no_thinking: false)

      {result, events, trace} =
        run_shim(ctx, "do work", labels: ["implementation-effort:extreme"], role: "qa")

      assert {:ok, _turn} = result
      assert trace =~ "--model claude-fable-5"
      assert trace =~ "--effort xhigh"
      refute trace =~ "--model claude-opus-4-8"
      refute trace =~ "ENV_MAX_THINKING_TOKENS:0"

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.implementation_effort == "extreme"
      assert completed.implementation_effort_source == "label"
      assert completed.claude_model == "claude-fable-5"
      assert completed.claude_effort == "xhigh"
      assert completed.claude_no_thinking == false
      refute Map.has_key?(completed, :claude_preferred_model)
      refute Map.has_key?(completed, :claude_preferred_effort)
      refute Map.has_key?(completed, :claude_fallback_reason)
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "fails closed when the resolved Fable row conflicts with config-declared no-thinking" do
    ctx = setup_workspace("MT-CC-fable-no-thinking")

    try do
      configure!(ctx, stream_success(), claude_code_model: "sonnet", claude_code_effort: "low", claude_code_no_thinking: true)

      {result, events, trace} =
        run_shim(ctx, "do work",
          labels: ["implementation-effort:extreme"],
          role: "qa",
          trace: :not_launched
        )

      # Fable cannot disable thinking. A Fable row resolved at runtime cannot
      # be caught by config validation (which sees only the config model), so
      # the adapter fails visibly instead of silently dropping either the
      # selected model or the declared no-thinking invocation.
      assert {:error, {:no_thinking_unsupported, "claude-fable-5"}} = result
      assert events == []
      assert trace == :not_launched
      refute File.exists?(ctx.trace_file)
    after
      File.rm_rf(ctx.test_root)
    end
  end
end
