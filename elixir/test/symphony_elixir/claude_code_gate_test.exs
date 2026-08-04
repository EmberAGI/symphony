defmodule SymphonyElixir.ClaudeCodeGateTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Non-negotiable skills/tools gate smoke and contract checks for the Claude
  Code runtime (EMB-1029).

  These tests prove the four gate dimensions required before Claude Code may be
  enabled for unattended Octo roles (ADR 0001, `docs/specs/domains/agent-runtime.md`):

  1. Role workflow materialization — the Symphony workflow prompt template
     loads correctly in the Claude Code runtime context. Octo-owned skills and
     provider projections are validated in scaling-octo-engine.
  2. Octo tool bundle — all five required tool surfaces execute through
     runtime-native mechanisms: Linear GraphQL access, workpad operations,
     artifact/proof capture, repository status, and PR status are each driven by
     Claude Code via the Bash tool (available under bypassPermissions) calling
     the role's skill CLIs (linear-macro/linear-cli for Linear GraphQL and
     workpad; file writes for artifact capture; `git status` for repository
     status; `gh pr view` for PR status). Each surface is proven by driving the
     fake `claude` binary with recorded stream-json carrying tool_use/tool_result
     events for both success and failure, then asserting the shim normalizes each
     surface correctly. A static assertion on the invocation flags confirms that
     `--permission-mode bypassPermissions` is present in the shim command,
     proving the Bash tool is available to the Claude Code runtime.
  3. Secret non-leakage — Linear tokens, OAuth credentials, and other secrets
     must not appear in prompts, transcripts, or logs.
  4. Tool failure normalization — tool failures are normalized for Octo review,
     QA, landing, status, and handoff behavior.

  All checks use a fake `claude` binary that replays recorded stream-json lines,
  matching the conventions of the existing shim contract suite. No live Claude
  subscription, Linear API key, or other external service is required.
  """

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer

  @repo_root Path.expand("../../..", __DIR__)
  # Plaintext sentinel values that must never appear in a built prompt. Used by
  # the secret non-leakage checks below; they are obviously fake tokens that
  # would never appear in a real deployment.
  @fake_tracker_token "fake-linear-token-do-not-leak"

  # ---------------------------------------------------------------------------
  # Gate dimension 1: Role workflow materialization
  # ---------------------------------------------------------------------------

  test "role workflow WORKFLOW.md is present and parseable as the role prompt template" do
    workflow_path = Path.join(@repo_root, "elixir/WORKFLOW.md")
    assert File.regular?(workflow_path), "elixir/WORKFLOW.md must exist as the role prompt source"

    content = File.read!(workflow_path)

    # The WORKFLOW.md must carry the Liquid/Solid template placeholders that
    # PromptBuilder uses to inject issue context into the role prompt.
    assert content =~ "{{ issue.identifier }}", "WORKFLOW.md must contain issue.identifier placeholder"
    assert content =~ "{{ issue.title }}", "WORKFLOW.md must contain issue.title placeholder"
    assert content =~ "{{ issue.description }}", "WORKFLOW.md must contain issue.description placeholder"
    assert content =~ "{% if issue.description %}", "WORKFLOW.md must contain issue.description conditional"
  end

  test "PromptBuilder renders role prompt template with issue variables for Claude Code runtime" do
    # The TestSupport write_workflow_file! uses a fixed minimal prompt. To prove
    # that the Liquid/Solid template mechanism works with issue variables, we
    # write a workflow file that contains a minimal prompt with the same
    # {{ issue.* }} placeholders used by the real WORKFLOW.md and confirm
    # PromptBuilder substitutes them correctly.
    workflow_root = Path.join(System.tmp_dir!(), "symphony-gate-prompt-#{System.unique_integer([:positive])}")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    File.mkdir_p!(workflow_root)

    on_exit(fn -> File.rm_rf(workflow_root) end)

    minimal_prompt_template = """
    ---
    tracker:
      kind: memory
      endpoint: "http://127.0.0.1:9/graphql"
      api_key: "#{@fake_tracker_token}"
    workspace:
      root: "#{Path.join(System.tmp_dir!(), "symphony_workspaces")}"
    ---
    You are working on {{ issue.identifier }}: {{ issue.title }}

    {% if issue.description %}
    Description: {{ issue.description }}
    {% else %}
    No description.
    {% endif %}
    """

    File.write!(workflow_file, minimal_prompt_template)
    Workflow.set_workflow_file_path(workflow_file)

    issue = %SymphonyElixir.Linear.Issue{
      id: "issue-gate-prompt",
      identifier: "GT-1",
      title: "Gate skill materialization check",
      description: "Verify prompt template renders issue fields correctly.",
      state: "In Progress",
      url: "https://example.org/issues/GT-1",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "GT-1", "prompt must contain issue identifier"
    assert prompt =~ "Gate skill materialization check", "prompt must contain issue title"
    assert prompt =~ "Verify prompt template renders issue fields correctly.", "prompt must contain issue description"
  end

  # ---------------------------------------------------------------------------
  # Gate dimension 2: Octo tool bundle — all five surfaces, Claude-runtime path
  #
  # Under Claude Code with bypassPermissions, Octo roles execute tools via
  # runtime-native mechanisms: the Bash tool (available in bypassPermissions mode)
  # calls skill CLIs — linear-macro/linear-cli for Linear GraphQL and workpad
  # operations, file writes for artifact/proof capture, `git status` for
  # repository status, and `gh pr view` for PR status. These tests prove the
  # shim normalizes success and failure for each surface's Bash tool_use events.
  #
  # One static assertion also confirms the shim invocation carries
  # `--permission-mode bypassPermissions` (proven by the trace check), which is
  # the mechanism that grants the Bash tool to the Claude Code runtime. This is
  # cross-labeled as a Claude-runtime proof, not a Codex DynamicTool assertion.
  # ---------------------------------------------------------------------------

  test "shim invocation carries bypassPermissions granting runtime-native Bash tool access" do
    # Proves the controlled runtime-native mechanism: the Claude Code shim always
    # invokes `claude --permission-mode bypassPermissions`, which makes the Bash
    # tool (and file tools) available to the running agent. This is the mechanism
    # through which all five Octo tool surfaces are reachable without MCP or
    # DynamicTool wiring.
    ctx = setup_gate_workspace("GT-bypass-perms")

    init_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-bypass","model":"claude-opus-4-8","apiKeySource":"none"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"ok","session_id":"sess-bypass","usage":{"input_tokens":1,"output_tokens":1}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, init_stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, _events, trace} = run_gate_shim(ctx, "check invocation flags")

      assert {:ok, _turn} = result

      # The shim must always pass bypassPermissions so the Bash tool is available.
      assert trace =~ "--permission-mode bypassPermissions",
             "shim must invoke claude with --permission-mode bypassPermissions to grant Bash tool access"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "shim normalizes Linear GraphQL surface: Bash tool_use success and failure via stream-json" do
    # Surface 1: Linear GraphQL access — the Claude Code role calls linear-macro
    # or linear-cli via the Bash tool. This test drives the fake claude with a
    # Bash tool_use for `linear-macro graphql ...` and asserts that the shim
    # emits tool_finished on success and tool_failed on failure.
    ctx = setup_gate_workspace("GT-surface-linear-graphql")

    stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-linear","model":"claude-opus-4-8","apiKeySource":"none"}),
      # Bash call simulating `linear-macro graphql ...` succeeding
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"linear-t1","input":{"command":"linear-macro graphql --query viewer-id"}}]},"session_id":"sess-linear"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"linear-t1","is_error":false,"content":"viewer id abc"}]},"session_id":"sess-linear"}),
      # Bash call simulating `linear-macro graphql ...` failing (network timeout)
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"linear-t2","input":{"command":"linear-macro graphql --query viewer-id"}}]},"session_id":"sess-linear"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"linear-t2","is_error":true,"content":"linear-macro: network timeout"}]},"session_id":"sess-linear"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-linear","usage":{"input_tokens":6,"output_tokens":4}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "linear graphql surface")

      assert {:ok, turn} = result
      # Turn flagged because one of the two Bash calls failed.
      assert turn.tool_failed == true

      event_atoms = Enum.map(events, & &1.event)
      assert :tool_finished in event_atoms, "tool_finished expected for successful linear-graphql Bash call"
      assert :tool_failed in event_atoms, "tool_failed expected for failed linear-graphql Bash call"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "shim normalizes workpad operations surface: Bash tool_use success and failure via stream-json" do
    # Surface 2: Workpad operations — the Claude Code role calls linear-macro
    # workpad sub-commands via the Bash tool. This test proves the shim
    # normalizes both success and failure for a workpad Bash tool_use event.
    ctx = setup_gate_workspace("GT-surface-workpad")

    stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-workpad","model":"claude-opus-4-8","apiKeySource":"none"}),
      # Bash call simulating `linear-macro workpad read ...` succeeding
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"workpad-t1","input":{"command":"linear-macro workpad read EMB-1029"}}]},"session_id":"sess-workpad"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"workpad-t1","is_error":false,"content":"## Workpad - Content here."}]},"session_id":"sess-workpad"}),
      # Bash call simulating `linear-macro workpad update ...` failing
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"workpad-t2","input":{"command":"linear-macro workpad update EMB-1029 --body new-content"}}]},"session_id":"sess-workpad"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"workpad-t2","is_error":true,"content":"linear-macro: workpad update failed: 403 Forbidden"}]},"session_id":"sess-workpad"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-workpad","usage":{"input_tokens":6,"output_tokens":4}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "workpad surface")

      assert {:ok, turn} = result
      assert turn.tool_failed == true

      event_atoms = Enum.map(events, & &1.event)
      assert :tool_finished in event_atoms, "tool_finished expected for successful workpad Bash call"
      assert :tool_failed in event_atoms, "tool_failed expected for failed workpad Bash call"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "shim normalizes artifact/proof capture surface: Bash file-write success and failure via stream-json" do
    # Surface 3: Artifact/proof capture — the Claude Code role writes proof
    # artifacts via Bash file-write or the Write tool. This test proves the shim
    # normalizes both success and failure for an artifact-capture tool_use event.
    ctx = setup_gate_workspace("GT-surface-artifact")

    stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-artifact","model":"claude-opus-4-8","apiKeySource":"none"}),
      # Bash call simulating a file write for artifact capture succeeding
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"artifact-t1","input":{"command":"printf '%s' 'proof content' > /tmp/proof.md"}}]},"session_id":"sess-artifact"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"artifact-t1","is_error":false,"content":""}]},"session_id":"sess-artifact"}),
      # Bash call simulating artifact capture failing (permission denied)
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"artifact-t2","input":{"command":"printf '%s' 'proof' > /read-only/proof.md"}}]},"session_id":"sess-artifact"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"artifact-t2","is_error":true,"content":"bash: /read-only/proof.md: Permission denied"}]},"session_id":"sess-artifact"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-artifact","usage":{"input_tokens":6,"output_tokens":4}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "artifact capture surface")

      assert {:ok, turn} = result
      assert turn.tool_failed == true

      event_atoms = Enum.map(events, & &1.event)
      assert :tool_finished in event_atoms, "tool_finished expected for successful artifact-capture Bash call"
      assert :tool_failed in event_atoms, "tool_failed expected for failed artifact-capture Bash call"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "shim normalizes repository status surface: Bash git-status success and failure via stream-json" do
    # Surface 4: Repository status — the Claude Code role calls `git status`
    # (or `git diff`) via the Bash tool. This test proves the shim normalizes
    # both success and failure for a repository-status tool_use event.
    ctx = setup_gate_workspace("GT-surface-repo-status")

    stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-repo","model":"claude-opus-4-8","apiKeySource":"none"}),
      # Bash call simulating `git status` succeeding
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"repo-t1","input":{"command":"git status --short"}}]},"session_id":"sess-repo"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"repo-t1","is_error":false,"content":"M elixir/mix.exs"}]},"session_id":"sess-repo"}),
      # Bash call simulating `git status` failing (not a git repo)
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"repo-t2","input":{"command":"git status --short"}}]},"session_id":"sess-repo"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"repo-t2","is_error":true,"content":"fatal: not a git repository"}]},"session_id":"sess-repo"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-repo","usage":{"input_tokens":6,"output_tokens":4}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "repository status surface")

      assert {:ok, turn} = result
      assert turn.tool_failed == true

      event_atoms = Enum.map(events, & &1.event)
      assert :tool_finished in event_atoms, "tool_finished expected for successful git-status Bash call"
      assert :tool_failed in event_atoms, "tool_failed expected for failed git-status Bash call"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "shim normalizes PR status surface: Bash gh-pr-view success and failure via stream-json" do
    # Surface 5: PR status — the Claude Code role calls `gh pr view` via the
    # Bash tool. This test proves the shim normalizes both success and failure
    # for a PR-status tool_use event.
    ctx = setup_gate_workspace("GT-surface-pr-status")

    stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-pr","model":"claude-opus-4-8","apiKeySource":"none"}),
      # Bash call simulating `gh pr view` succeeding
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"pr-t1","input":{"command":"gh pr view --json state,title"}}]},"session_id":"sess-pr"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"pr-t1","is_error":false,"content":"state:OPEN title:EMB-1029 gate checks"}]},"session_id":"sess-pr"}),
      # Bash call simulating `gh pr view` failing (no PR for branch)
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"pr-t2","input":{"command":"gh pr view --json state,title"}}]},"session_id":"sess-pr"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"pr-t2","is_error":true,"content":"gh: no pull requests found for branch"}]},"session_id":"sess-pr"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done","session_id":"sess-pr","usage":{"input_tokens":6,"output_tokens":4}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "PR status surface")

      assert {:ok, turn} = result
      assert turn.tool_failed == true

      event_atoms = Enum.map(events, & &1.event)
      assert :tool_finished in event_atoms, "tool_finished expected for successful gh-pr-view Bash call"
      assert :tool_failed in event_atoms, "tool_failed expected for failed gh-pr-view Bash call"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "Claude Code shim emits tool_failed event when a tool call returns an error result" do
    # Proves gate dimension 2 (tool execution) and gate dimension 4 (tool
    # failure normalization) together: a stream where Claude calls a tool and
    # the tool result carries is_error:true must produce a tool_failed event and
    # a turn_completed event with tool_failed: true.
    ctx = setup_gate_workspace("GT-tool-gate")

    tool_failure_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-tool","model":"claude-opus-4-8","apiKeySource":"none"}),
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"gate-t1"}]},"session_id":"sess-gate-tool"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"gate-t1","is_error":true,"content":"linear_graphql transport error: timeout"}]},"session_id":"sess-gate-tool"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"done with tool error","session_id":"sess-gate-tool","usage":{"input_tokens":5,"output_tokens":3}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, tool_failure_stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "trigger tool failure")

      # The turn itself still completes (tool failure != turn failure).
      assert {:ok, turn} = result
      assert turn.tool_failed == true

      # The event stream must carry exactly one tool_failed event.
      tool_failed_events = Enum.filter(events, &(&1.event == :tool_failed))
      assert length(tool_failed_events) == 1, "exactly one tool_failed event expected"

      # The turn_completed event must also carry tool_failed: true so downstream
      # reviewers, QA, and status surfaces see the failure flag.
      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed != nil, "turn_completed event must be emitted"
      assert completed.tool_failed == true, "turn_completed must carry tool_failed: true"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  # ---------------------------------------------------------------------------
  # Gate dimension 3: Secret non-leakage
  # ---------------------------------------------------------------------------

  test "PromptBuilder does not include the tracker API key in the rendered role prompt" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
      tracker_api_token: @fake_tracker_token
    )

    issue = %SymphonyElixir.Linear.Issue{
      id: "issue-gate-secret",
      identifier: "GT-2",
      title: "Gate secret non-leakage check",
      description: "Prompt must not contain tracker credentials.",
      state: "In Progress",
      url: "https://example.org/issues/GT-2",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    refute prompt =~ @fake_tracker_token,
           "tracker API key must not appear in the rendered role prompt"
  end

  test "shim redacts oauth_token fields in session init events" do
    ctx = setup_gate_workspace("GT-oauth-redact")

    # A stream that carries an oauth_token in the init event; the shim must
    # strip it before emitting the session_started event so credentials never
    # reach the orchestrator, status surfaces, or handoff logic.
    leaky_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-oauth","model":"claude-opus-4-8","oauth_token":"super-secret-oauth-value","apiKeySource":"none"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"ok","session_id":"sess-gate-oauth","usage":{"input_tokens":1,"output_tokens":1}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, leaky_stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "check oauth redaction")

      assert {:ok, _turn} = result

      started = Enum.find(events, &(&1.event == :session_started))
      assert started != nil, "session_started event must be emitted"

      # The emitted event must not contain the raw credential value anywhere.
      refute inspect(started) =~ "super-secret-oauth-value",
             "oauth_token value must not appear in emitted event"

      # The payload must carry the redacted placeholder.
      assert get_in(started, [:payload, "oauth_token"]) == "[REDACTED]",
             "oauth_token field must be redacted to [REDACTED]"

      # The raw JSON line is also redacted when it carries credential keys.
      assert started.raw == "[REDACTED]",
             "raw line must be [REDACTED] when the line contains a credential key"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "shim redacts api_key fields in result events" do
    ctx = setup_gate_workspace("GT-apikey-redact")

    # A result event carrying an api_key field; the shim must strip it.
    leaky_result_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-apikey","model":"claude-opus-4-8","apiKeySource":"none"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"ok","session_id":"sess-gate-apikey","api_key":"secret-api-key-value","usage":{"input_tokens":1,"output_tokens":1}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, leaky_result_stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "check api_key redaction in result")

      assert {:ok, _turn} = result

      # The turn_completed event payload must not carry the raw api_key value.
      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed != nil

      refute inspect(completed) =~ "secret-api-key-value",
             "api_key value must not appear in turn_completed event"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "shim does not forward tracker API key from WORKFLOW.md into events or logs" do
    ctx = setup_gate_workspace("GT-tracker-token-redact")

    # A stream that has a benign init; we verify the tracker API key configured
    # in WORKFLOW.md never appears in any emitted event. The shim learns the
    # tracker token from WORKFLOW.md through Config.settings!(), but must never
    # echo it back through events.
    benign_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-tracker","model":"claude-opus-4-8","apiKeySource":"none"}),
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"tracker-key-check-ok"}]},"session_id":"sess-gate-tracker"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"ok","session_id":"sess-gate-tracker","usage":{"input_tokens":1,"output_tokens":1}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, benign_stream)

      # Configure the workflow with a clearly fake tracker token.
      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude,
        tracker_api_token: @fake_tracker_token
      )

      {result, events, _trace} = run_gate_shim(ctx, "check tracker token non-leakage")

      assert {:ok, _turn} = result

      all_events_text = Enum.map_join(events, "\n", &inspect/1)

      refute all_events_text =~ @fake_tracker_token,
             "tracker API key must not appear in any emitted runtime event"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  # ---------------------------------------------------------------------------
  # Gate dimension 4: Tool failure normalization
  # ---------------------------------------------------------------------------

  test "tool failure in a Claude turn normalizes to a tool_failed event without aborting the turn" do
    # This check proves the full tool-failure normalization pipeline from a
    # Claude-native is_error tool_result in the stream to the normalized
    # :tool_failed event and the :turn_completed event that downstream
    # orchestrator, QA, review, and handoff surfaces consume.
    ctx = setup_gate_workspace("GT-normalize-tool")

    multi_tool_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-norm","model":"claude-opus-4-8","apiKeySource":"none"}),
      # Tool call 1 succeeds.
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"norm-t1"}]},"session_id":"sess-gate-norm"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"norm-t1","is_error":false,"content":"file contents"}]},"session_id":"sess-gate-norm"}),
      # Tool call 2 fails (e.g. linear_graphql timeout).
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"linear_graphql","id":"norm-t2"}]},"session_id":"sess-gate-norm"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"norm-t2","is_error":true,"content":"linear_graphql: network timeout"}]},"session_id":"sess-gate-norm"}),
      # Turn still completes after tool failure.
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"completed with tool error","session_id":"sess-gate-norm","usage":{"input_tokens":10,"output_tokens":5}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, multi_tool_stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "normalize multi-tool failure")

      # Turn completes despite tool failure.
      assert {:ok, turn} = result
      assert turn.tool_failed == true

      event_atoms = Enum.map(events, & &1.event)

      # Session started, two assistant text_delta events, one tool_finished
      # (success), one tool_failed (failure), then turn_completed.
      assert :session_started in event_atoms
      assert :tool_finished in event_atoms
      assert :tool_failed in event_atoms
      assert :turn_completed in event_atoms

      # The failed event must not be :turn_failed — tool failures do not abort
      # the turn at the normalization layer.
      refute :turn_failed in event_atoms,
             "a tool failure must not produce a turn_failed event; it normalizes to tool_failed"

      # The turn_completed event must carry the tool_failed flag.
      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed.tool_failed == true

      # Usage is still reported on a tool-failure turn.
      assert completed.usage != nil
      assert completed.usage["input_tokens"] == 10
      assert completed.usage["output_tokens"] == 5
    after
      File.rm_rf(ctx.test_root)
    end
  end

  test "tool_finished event is emitted for a successful tool call without marking the turn failed" do
    ctx = setup_gate_workspace("GT-tool-success-norm")

    success_tool_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-ok-tool","model":"claude-opus-4-8","apiKeySource":"none"}),
      ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"ok-t1"}]},"session_id":"sess-gate-ok-tool"}),
      ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"ok-t1","is_error":false,"content":"command output"}]},"session_id":"sess-gate-ok-tool"}),
      ~s({"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"ok","session_id":"sess-gate-ok-tool","usage":{"input_tokens":3,"output_tokens":2}})
    ]

    try do
      write_fake_claude!(ctx.fake_claude, ctx.trace_file, success_tool_stream)

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_runtime_provider: "claude_code",
        claude_code_command: ctx.fake_claude
      )

      {result, events, _trace} = run_gate_shim(ctx, "successful tool normalization")

      assert {:ok, turn} = result
      assert turn.tool_failed == false

      assert Enum.any?(events, &(&1.event == :tool_finished)),
             "tool_finished event expected for a successful tool call"

      refute Enum.any?(events, &(&1.event == :tool_failed)),
             "tool_failed event must not appear when all tool calls succeed"

      completed = Enum.find(events, &(&1.event == :turn_completed))
      # The shim only adds :tool_failed to the turn_completed event when a tool
      # failure was flagged; absence of the key is equivalent to false here.
      refute Map.get(completed, :tool_failed, false),
             "turn_completed must not carry tool_failed: true when all tools succeeded"
    after
      File.rm_rf(ctx.test_root)
    end
  end

  # ---------------------------------------------------------------------------
  # Gate result: Spec contract check
  # ---------------------------------------------------------------------------

  test "agent-runtime spec records the skills/tools gate contract and check locations" do
    # Proves the gate result is durably recorded so EMB-1030 (end-to-end slice)
    # and operator enablement can rely on it.
    spec = File.read!(Path.join(@repo_root, "docs/specs/domains/agent-runtime.md"))

    # Spec must describe the fake binary test convention (already in the original
    # implementation section and the new gate contract section).
    assert spec =~ "fake `claude` binary",
           "agent-runtime spec must describe the fake binary test convention"

    # Spec must name both test modules.
    assert spec =~ "claude_code_app_server_test",
           "agent-runtime spec must name the shim contract test file"

    assert spec =~ "claude_code_gate_test",
           "agent-runtime spec must name the gate test file"

    # Spec must reference the gate contract section.
    assert spec =~ "Skills/tools release gate contract",
           "agent-runtime spec must carry the gate contract section"

    # Spec must name the gate dimensions.
    assert spec =~ "Skill materialization",
           "agent-runtime spec must name the skill materialization gate dimension"

    assert spec =~ "Octo tool bundle",
           "agent-runtime spec must name the Octo tool bundle gate dimension"

    assert spec =~ "Secret non-leakage",
           "agent-runtime spec must name the secret non-leakage gate dimension"

    assert spec =~ "Tool failure normalization",
           "agent-runtime spec must name the tool failure normalization gate dimension"

    # Spec must reference the key check behaviors so reviewers and operators
    # know what each test module proves.
    assert spec =~ "no-thinking",
           "agent-runtime spec must reference the no-thinking invocation check"

    assert spec =~ "secret redaction",
           "agent-runtime spec must reference secret redaction"

    assert spec =~ "tool failure",
           "agent-runtime spec must reference tool failure normalization"

    assert spec =~ "Skill materialization",
           "agent-runtime spec must reference skill materialization"

    # Gate enablement policy must be stated.
    assert spec =~ "MUST NOT be enabled for unattended Octo roles",
           "agent-runtime spec must state the enablement gate condition"
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp setup_gate_workspace(name) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-gate-#{name}-#{System.unique_integer([:positive])}"
      )

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

  defp run_gate_shim(ctx, prompt) do
    issue = %{id: "gate-#{System.unique_integer([:positive])}", identifier: "GT-GATE", title: "Claude gate check"}

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_message = fn message -> Agent.update(agent, fn acc -> [message | acc] end) end

    result = ClaudeAppServer.run(ctx.workspace, prompt, issue, on_message: on_message)
    events = agent |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(agent)

    trace =
      case File.read(ctx.trace_file) do
        {:ok, content} -> content
        {:error, _} -> ""
      end

    {result, events, trace}
  end
end
