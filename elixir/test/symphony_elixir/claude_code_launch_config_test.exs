defmodule SymphonyElixir.ClaudeCodeLaunchConfigTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Launch-configuration behavior of the first-party Claude Code shim: catalog
  implementation-effort row selection, the documented Fable fallback, the
  config-declared no-thinking env propagation, and local provider auth env
  inheritance — all proved against a fake `claude` binary replaying recorded
  stream-json, with no live Claude subscription.
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
      configure!(ctx, stream_success(), claude_code_model: "opus", claude_code_effort: "low", claude_code_no_thinking: true)

      {result, events, trace} =
        run_shim(ctx, "do work", labels: ["implementation-effort:bogus"], role: "implementer")

      assert {:ok, _turn} = result
      assert trace =~ "--model claude-opus-4-8"
      assert trace =~ "--effort high"
      refute trace =~ "ENV_MAX_THINKING_TOKENS:0"

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.implementation_effort == "moderate"
      assert completed.implementation_effort_source == "default_invalid_label"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "falls back from preferred Fable profiles to Opus high at launch" do
    ctx = setup_workspace("MT-CC-fable-fallback")

    try do
      configure!(ctx, stream_success(), claude_code_model: "sonnet", claude_code_effort: "low", claude_code_no_thinking: true)

      {result, events, trace} =
        run_shim(ctx, "do work", labels: ["implementation-effort:extreme"], role: "qa")

      assert {:ok, _turn} = result
      assert trace =~ "--model claude-opus-4-8"
      assert trace =~ "--effort high"
      refute trace =~ "--model fable"
      refute trace =~ "--model claude-fable-5"
      refute trace =~ "--effort xhigh"
      refute trace =~ "ENV_MAX_THINKING_TOKENS:0"

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.implementation_effort == "extreme"
      assert completed.implementation_effort_source == "label"
      assert completed.claude_model == "claude-opus-4-8"
      assert completed.claude_effort == "high"
      assert completed.claude_no_thinking == false
      assert completed.claude_preferred_model == "claude-fable-5"
      assert completed.claude_preferred_effort == "xhigh"
      assert completed.claude_fallback_reason == "fable_unavailable"
    after
      File.rm_rf(ctx.test_root)
    end
  end
end
