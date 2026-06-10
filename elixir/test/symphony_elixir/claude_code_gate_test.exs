defmodule SymphonyElixir.ClaudeCodeGateTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Non-negotiable skills/tools gate smoke and contract checks for the Claude
  Code runtime (EMB-1029).

  These tests prove the four gate dimensions required before Claude Code may be
  enabled for unattended Octo roles (ADR 0001, `spec/domains/agent-runtime.md`):

  1. Role skill materialization — role workflow/prompt/skill material from
     Symphony remains the source of truth and loads correctly in the Claude Code
     runtime context.
  2. Octo tool bundle — at minimum Linear GraphQL access, workpad operations,
     artifact/proof capture, repository status, and PR status execute through
     the shim or controlled runtime-native mechanisms.
  3. Secret non-leakage — Linear tokens, OAuth credentials, and other secrets
     must not appear in prompts, transcripts, or logs.
  4. Tool failure normalization — tool failures are normalized for Octo review,
     QA, landing, status, and handoff behavior.

  All checks use a fake `claude` binary that replays recorded stream-json lines,
  matching the conventions of the existing shim contract suite. No live Claude
  subscription, Linear API key, or other external service is required.
  """

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.Codex.DynamicTool

  @repo_root Path.expand("../../..", __DIR__)
  @role_skills_dir Path.join(@repo_root, ".codex/role-skills")

  # Minimum Octo tool names required by the gate (spec/domains/agent-runtime.md).
  @required_tool_names ~w(linear_graphql)

  # Plaintext sentinel values that must never appear in a built prompt. Used by
  # the secret non-leakage checks below; they are obviously fake tokens that
  # would never appear in a real deployment.
  @fake_tracker_token "fake-linear-token-do-not-leak"

  # ---------------------------------------------------------------------------
  # Gate dimension 1: Role skill materialization
  # ---------------------------------------------------------------------------

  @doc false
  # The implementer role-skills manifest must be present, reference valid skill
  # directories, and contain SKILL.md files. This proves Symphony role material
  # is loaded correctly as the source of truth.

  test "implementer role-skills manifest resolves all declared skill paths" do
    manifest = read_manifest!("implementer")

    assert manifest["role"] == "implementer"
    assert is_list(manifest["skills"]) and manifest["skills"] != []

    for skill <- manifest["skills"] do
      skill_path = Path.expand(skill["path"], @role_skills_dir)

      assert File.dir?(skill_path),
             "skill #{inspect(skill["name"])} path #{inspect(skill_path)} must be a directory"

      assert File.regular?(Path.join(skill_path, "SKILL.md")),
             "skill #{inspect(skill["name"])} must have SKILL.md"
    end
  end

  test "qa role-skills manifest resolves all declared skill paths" do
    manifest = read_manifest!("qa")

    assert manifest["role"] == "qa"
    assert is_list(manifest["skills"]) and manifest["skills"] != []

    for skill <- manifest["skills"] do
      skill_path = Path.expand(skill["path"], @role_skills_dir)

      assert File.dir?(skill_path),
             "QA skill #{inspect(skill["name"])} path #{inspect(skill_path)} must be a directory"

      assert File.regular?(Path.join(skill_path, "SKILL.md")),
             "QA skill #{inspect(skill["name"])} must have SKILL.md"
    end
  end

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
      kind: linear
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

  test "role-skills manifests explicitly record Octo workflow authority boundaries" do
    # Both manifests must carry Octo authority boundaries so skill consumers
    # know what they may not override.
    for role <- ["implementer", "qa"] do
      manifest = read_manifest!(role)

      assert is_list(manifest["octo_authority_boundaries"]),
             "#{role} manifest must declare octo_authority_boundaries"

      assert manifest["octo_authority_boundaries"] != [],
             "#{role} manifest octo_authority_boundaries must not be empty"
    end
  end

  # ---------------------------------------------------------------------------
  # Gate dimension 2: Octo tool bundle
  # ---------------------------------------------------------------------------

  test "DynamicTool tool_specs exposes all required Octo tool names" do
    advertised_names = DynamicTool.tool_specs() |> Enum.map(& &1["name"])

    for required <- @required_tool_names do
      assert required in advertised_names,
             "DynamicTool.tool_specs() must include required Octo tool #{inspect(required)}"
    end
  end

  test "DynamicTool linear_graphql tool schema satisfies the minimum Octo contract" do
    specs = DynamicTool.tool_specs()
    linear_spec = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert linear_spec != nil, "linear_graphql spec must be present"
    assert is_binary(linear_spec["description"]) and linear_spec["description"] =~ "Linear"
    assert get_in(linear_spec, ["inputSchema", "required"]) == ["query"]

    properties = get_in(linear_spec, ["inputSchema", "properties"])
    assert is_map(properties)
    assert Map.has_key?(properties, "query"), "linear_graphql must declare a query property"
  end

  test "Claude Code shim emits tool_failed event when a tool call returns an error result" do
    # Proves gate dimension 2 (tool execution) and gate dimension 4 (tool
    # failure normalization) together: a stream where Claude calls a tool and
    # the tool result carries is_error:true must produce a tool_failed event and
    # a turn_completed event with tool_failed: true.
    ctx = setup_gate_workspace("GT-tool-gate")

    tool_failure_stream = [
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-tool","apiKeySource":"none"}),
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
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-oauth","oauth_token":"super-secret-oauth-value","apiKeySource":"none"}),
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
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-apikey","apiKeySource":"none"}),
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
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-tracker","apiKeySource":"none"}),
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
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-norm","apiKeySource":"none"}),
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
      ~s({"type":"system","subtype":"init","session_id":"sess-gate-ok-tool","apiKeySource":"none"}),
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
    spec = File.read!(Path.join(@repo_root, "spec/domains/agent-runtime.md"))

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

  defp read_manifest!(role) do
    [@role_skills_dir, "#{role}.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end
end
