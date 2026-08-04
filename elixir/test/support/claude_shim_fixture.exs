defmodule SymphonyElixir.ClaudeShimFixture do
  @moduledoc """
  Shared deterministic fake-`claude` shim fixture: recorded stream-json
  replays, a fake binary writer, and workspace/run/config helpers used by the
  focused Claude Code shim test modules. Fixture plumbing only — no
  production policy lives here.
  """

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  import SymphonyElixir.TestSupport, only: [write_workflow_file!: 2]

  # One JSON object per line, mirroring `claude -p --output-format stream-json
  # --verbose`. Captured from a real Claude Code 2.x invocation.
  def stream_success(model \\ "claude-opus-4-8") do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-success","model":"#{model}","permissionMode":"bypassPermissions","apiKeySource":"none"}),
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"SHIMOK"}]},"session_id":"sess-success"}),
      ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"sess-success"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"SHIMOK","session_id":"sess-success","usage":{"input_tokens":3,"cache_read_input_tokens":100,"cache_creation_input_tokens":50,"output_tokens":6},"total_cost_usd":0.04})
    ]
  end

  def stream_model_mismatch do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-model-mismatch","model":"claude-sonnet-5","permissionMode":"bypassPermissions","apiKeySource":"none"}),
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"work from the wrong model"}]},"session_id":"sess-model-mismatch"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-model-mismatch","usage":{"input_tokens":1,"output_tokens":1}})
    ]
  end

  def stream_model_missing_success do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-model-missing","permissionMode":"bypassPermissions","apiKeySource":"none"}),
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"unattested work"}]},"session_id":"sess-model-missing"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-model-missing","usage":{"input_tokens":1,"output_tokens":1}})
    ]
  end

  def stream_model_malformed do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-model-malformed","model":{"family":"fable"},"permissionMode":"bypassPermissions","apiKeySource":"none"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-model-malformed","usage":{"input_tokens":1,"output_tokens":1}})
    ]
  end

  def stream_auth_failure do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-auth","apiKeySource":"none"}),
      ~s({"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":401,"result":"Invalid credentials","session_id":"sess-auth"})
    ]
  end

  def stream_auth_failure_with_provider_payload do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-auth-payload","apiKeySource":"none"}),
      ~s({"type":"result","subtype":"login_required","is_error":true,"api_error_status":403,"result":"Bearer raw-secret-token expired","session_id":"sess-auth-payload","oauth_token":"raw-oauth-token"})
    ]
  end

  def stream_synthetic_normalized_family_failure do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-synthetic-family","apiKeySource":"none"}),
      ~s({"type":"result","subtype":"provider_authentication_or_revocation","is_error":true,"api_error_status":null,"result":"synthetic normalized family","session_id":"sess-synthetic-family"})
    ]
  end

  def stream_irrecoverable_runtime_result(subtype) do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-#{subtype}","apiKeySource":"none"}),
      ~s({"type":"result","subtype":"#{subtype}","is_error":true,"api_error_status":null,"result":"runtime protocol failure token=adapter-secret","session_id":"sess-#{subtype}"})
    ]
  end

  def stream_max_turns do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-max"}),
      ~s({"type":"result","subtype":"error_max_turns","is_error":true,"api_error_status":null,"session_id":"sess-max","num_turns":2})
    ]
  end

  def stream_tool_failure do
    [
      ~s({"type":"system","subtype":"init","session_id":"sess-tool","model":"claude-opus-4-8"}),
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"t1"}]},"session_id":"sess-tool"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]},"session_id":"sess-tool"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-tool","usage":{"input_tokens":1,"output_tokens":1}})
    ]
  end

  # Writes a fake `claude` shell binary that records its argv to a trace file and
  # prints the supplied stream-json lines.
  def write_fake_claude!(path, trace_file, lines) do
    body = Enum.map_join(lines, "\n", &"printf '%s\\n' #{shell_quote(&1)}")

    File.write!(path, """
    #!/bin/sh
    trace_file="#{trace_file}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"
    printf 'ENV_MAX_THINKING_TOKENS:%s\\n' "${MAX_THINKING_TOKENS}" >> "$trace_file"
    printf 'ENV_SYMPHONY_ROLE_RUN_ID:%s\\n' "${SYMPHONY_ROLE_RUN_ID}" >> "$trace_file"
    printf 'ENV_SYMPHONY_ROLE_ISSUE_ID:%s\\n' "${SYMPHONY_ROLE_ISSUE_ID}" >> "$trace_file"
    printf 'ENV_SYMPHONY_ROLE_ISSUE_IDENTIFIER:%s\\n' "${SYMPHONY_ROLE_ISSUE_IDENTIFIER}" >> "$trace_file"
    printf 'ENV_SYMPHONY_ROLE_NAME:%s\\n' "${SYMPHONY_ROLE_NAME}" >> "$trace_file"
    printf 'ENV_SYMPHONY_ROLE_WORKSPACE_PATH:%s\\n' "${SYMPHONY_ROLE_WORKSPACE_PATH}" >> "$trace_file"
    printf 'ENV_SYMPHONY_ISSUE_REPOSITORY:%s\\n' "${SYMPHONY_ISSUE_REPOSITORY}" >> "$trace_file"
    printf 'ENV_SYMPHONY_EXPECTED_BRANCH:%s\\n' "${SYMPHONY_EXPECTED_BRANCH}" >> "$trace_file"
    printf 'ENV_SYMPHONY_SKILL_EXECUTION_CONTRACTS:%s\\n' "${SYMPHONY_SKILL_EXECUTION_CONTRACTS}" >> "$trace_file"
    printf 'ENV_CLAUDE_CODE_OAUTH_TOKEN_PRESENT:%s\\n' "${CLAUDE_CODE_OAUTH_TOKEN:+present}" >> "$trace_file"
    #{body}
    exit 0
    """)

    File.chmod!(path, 0o755)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  def setup_workspace(name) do
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

  def run_shim(ctx, prompt, overrides \\ []) do
    issue = %Issue{
      id: Keyword.get(overrides, :issue_id, "issue-#{System.unique_integer([:positive])}"),
      identifier: "MT-CC",
      title: "Claude shim",
      state: "Todo",
      labels: Keyword.get(overrides, :labels, [])
    }

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_message = fn message -> Agent.update(agent, fn acc -> [message | acc] end) end

    result =
      ClaudeAppServer.run(ctx.workspace, prompt, issue,
        on_message: on_message,
        role: Keyword.get(overrides, :role),
        run_id: Keyword.get(overrides, :run_id),
        skill_execution_contracts: Keyword.get(overrides, :skill_execution_contracts, [])
      )

    events = agent |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(agent)

    {result, events, Keyword.get_lazy(overrides, :trace, fn -> File.read!(ctx.trace_file) end)}
  end

  def configure!(ctx, lines, claude_overrides) do
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
end
