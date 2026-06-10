defmodule SymphonyElixir.ClaudeCodeAppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer

  @moduledoc """
  Deterministic contract/smoke checks for the first-party Claude Code shim.

  These tests drive a fake `claude` binary that replays recorded stream-json
  lines, so they assert the shim's protocol contract (flags, normalized events,
  failure classification, secret hygiene) without a live Claude subscription.
  """

  # One JSON object per line, mirroring `claude -p --output-format stream-json
  # --verbose`. Captured from a real Claude Code 2.x invocation.
  defp stream_success do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-success","model":"claude-sonnet-4-6","permissionMode":"bypassPermissions","apiKeySource":"none"}),
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"SHIMOK"}]},"session_id":"sess-success"}),
      ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"sess-success"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"SHIMOK","session_id":"sess-success","usage":{"input_tokens":3,"cache_read_input_tokens":100,"cache_creation_input_tokens":50,"output_tokens":6},"total_cost_usd":0.04})
    ]
  end

  defp stream_auth_failure do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-auth","apiKeySource":"none"}),
      ~s({"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":401,"result":"Invalid credentials","session_id":"sess-auth"})
    ]
  end

  defp stream_max_turns do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-max"}),
      ~s({"type":"result","subtype":"error_max_turns","is_error":true,"api_error_status":null,"session_id":"sess-max","num_turns":2})
    ]
  end

  defp stream_tool_failure do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-tool"}),
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"t1"}]},"session_id":"sess-tool"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]},"session_id":"sess-tool"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-tool","usage":{"input_tokens":1,"output_tokens":1}})
    ]
  end

  # Writes a fake `claude` shell binary that records its argv to a trace file and
  # prints the supplied stream-json lines.
  defp write_fake_claude!(path, trace_file, lines) do
    body = Enum.map_join(lines, "\n", &"printf '%s\\n' #{shell_quote(&1)}")

    File.write!(path, """
    #!/bin/sh
    trace_file="#{trace_file}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"
    printf 'ENV_MAX_THINKING_TOKENS:%s\\n' "${MAX_THINKING_TOKENS}" >> "$trace_file"
    #{body}
    exit 0
    """)

    File.chmod!(path, 0o755)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp setup_workspace(name) do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-claude-shim-#{name}-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, name)
    fake_claude = Path.join(test_root, "fake-claude")
    trace_file = Path.join(test_root, "claude.trace")

    File.mkdir_p!(workspace)

    %{
      test_root: test_root,
      workspace_root: workspace_root,
      workspace: workspace,
      fake_claude: fake_claude,
      trace_file: trace_file
    }
  end

  defp run_shim(ctx, prompt, overrides \\ []) do
    issue = %{id: "issue-#{System.unique_integer([:positive])}", identifier: "MT-CC", title: "Claude shim"}

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_message = fn message -> Agent.update(agent, fn acc -> [message | acc] end) end

    result = ClaudeAppServer.run(ctx.workspace, prompt, issue, on_message: on_message)
    events = agent |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(agent)

    {result, events, Keyword.get(overrides, :trace, File.read!(ctx.trace_file))}
  end

  defp configure!(ctx, lines, claude_overrides) do
    write_fake_claude!(ctx.fake_claude, ctx.trace_file, lines)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      [
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      ] ++ claude_overrides
    )
  end

  test "normalizes a successful turn into Symphony runtime events with usage" do
    ctx = setup_workspace("MT-CC-success")

    try do
      configure!(ctx, stream_success(), claude_code_model: "sonnet", claude_code_effort: "low", claude_code_no_thinking: true)

      {result, events, trace} = run_shim(ctx, "Reply with exactly: SHIMOK")

      assert {:ok, turn} = result
      assert turn.session_id == "sess-success"
      assert turn.tool_failed == false
      # input_tokens + cache_read + cache_creation = 3 + 100 + 50; output = 6.
      assert turn.usage == %{"input_tokens" => 153, "output_tokens" => 6, "total_tokens" => 159}

      event_atoms = Enum.map(events, & &1.event)
      assert event_atoms == [:session_started, :text_delta, :notification, :turn_completed]

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.usage == %{"input_tokens" => 153, "output_tokens" => 6, "total_tokens" => 159}
      assert completed[:usage]

      # Verified flags and the no-thinking env are actually passed to claude.
      # The fake binary records argv after the shell strips the shell-escaping
      # the shim applies, so assert against the resolved argument values.
      assert trace =~ "--print"
      assert trace =~ "--output-format stream-json"
      assert trace =~ "--verbose"
      assert trace =~ "--permission-mode bypassPermissions"
      assert trace =~ "--model sonnet"
      assert trace =~ "--effort low"
      assert trace =~ "ENV_MAX_THINKING_TOKENS:0"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "fails closed with an operator-visible error on auth failure" do
    ctx = setup_workspace("MT-CC-auth")

    try do
      configure!(ctx, stream_auth_failure(), claude_code_model: "sonnet")

      {result, events, _trace} = run_shim(ctx, "do work")

      assert {:error, {:auth_failed, %{api_error_status: 401}}} = result

      failed = Enum.find(events, &(&1.event == :turn_failed))
      assert failed.reason == :auth_failed
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "classifies Claude internal max-turns as input-required rather than success" do
    ctx = setup_workspace("MT-CC-max")

    try do
      configure!(ctx, stream_max_turns(), claude_code_model: "sonnet")

      {result, events, _trace} = run_shim(ctx, "do work")

      assert {:error, {:turn_input_required, %{subtype: "error_max_turns"}}} = result
      assert Enum.any?(events, &(&1.event == :turn_input_required))
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "surfaces a tool failure while still completing the turn" do
    ctx = setup_workspace("MT-CC-tool")

    try do
      configure!(ctx, stream_tool_failure(), claude_code_model: "sonnet")

      {result, events, _trace} = run_shim(ctx, "do work")

      assert {:ok, turn} = result
      assert turn.tool_failed == true
      assert Enum.any?(events, &(&1.event == :tool_failed))

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.tool_failed == true
    after
      File.rm_rf(ctx.test_root)
    end
  end

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

  test "redacts credential-bearing fields from emitted events" do
    ctx = setup_workspace("MT-CC-secret")

    leaky_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-secret","oauth_token":"super-secret-value"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"ok","session_id":"sess-secret","usage":{"input_tokens":1,"output_tokens":1}})
    ]

    try do
      configure!(ctx, leaky_stream, claude_code_model: "sonnet")

      {result, events, _trace} = run_shim(ctx, "do work")

      assert {:ok, _turn} = result

      started = Enum.find(events, &(&1.event == :session_started))
      refute inspect(started) =~ "super-secret-value"
      assert get_in(started, [:payload, "oauth_token"]) == "[REDACTED]"
      assert started.raw == "[REDACTED]"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "rejects a workspace outside the configured workspace root" do
    ctx = setup_workspace("MT-CC-guard")

    try do
      configure!(ctx, stream_success(), claude_code_model: "sonnet")

      outside = Path.join(ctx.test_root, "outside")
      File.mkdir_p!(outside)

      issue = %{id: "guard", identifier: "MT-CC", title: "guard"}

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
               ClaudeAppServer.run(outside, "do work", issue)
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "defaults the runtime provider to codex when agent_runtime is unset" do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert SymphonyElixir.AgentRuntime.provider() == :codex
    assert SymphonyElixir.AgentRuntime.adapter() == SymphonyElixir.Codex.AppServer
  end

  test "selects the Claude Code adapter when configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude"
    )

    assert SymphonyElixir.AgentRuntime.provider() == :claude_code
    assert SymphonyElixir.AgentRuntime.adapter() == SymphonyElixir.ClaudeCode.AppServer
  end

  test "config validation fails closed on an unsupported effort level" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_effort: "ludicrous"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "effort"
  end

  test "config validation fails closed when disabling thinking on a model that cannot" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "claude-fable-5",
      claude_code_no_thinking: true
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "thinking"
  end

  test "config validation rejects an unsupported runtime provider" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      agent_runtime_provider: "pi"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "provider"
  end
end
