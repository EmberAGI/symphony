defmodule SymphonyElixir.RoleBootstrapEnvironmentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime

  import SymphonyElixir.ClaudeShimFixture, only: [stream_success: 0, write_fake_claude!: 3]

  @moduledoc """
  Every role's per-turn bootstrap projection, asserted at the public runtime
  seam (`AgentRuntime.start_session/2` + `AgentRuntime.run_turn/4`).

  The observable is the environment of the process the runtime actually
  launches, recorded by the fake provider binary itself. That read works
  identically on macOS and Linux: nothing here depends on `/proc`, on
  `ProcessOwnership.process_env/1`, or on any other mechanism that is inert off
  the Linux role hosts, so these assertions cannot degrade into tautologies on
  a dev host (see the warning in
  `orchestrator_terminal_settlement_evidence_test.exs`).
  """

  @non_implementer_roles ["reviewer", "qa", "landing", "backlog-processor"]

  @repository "EmberAGI/scaling-octo-engine"
  @expected_branch "agent/emb-1270-role-bootstrap-projection"

  defp bootstrap_issue(overrides \\ []) do
    struct(
      %Issue{
        id: "issue-emb-1270",
        identifier: "EMB-1270",
        title: "Role bootstrap projection",
        state: "In Progress",
        url: "https://linear.app/emberai/issue/EMB-1270",
        repository: @repository,
        repository_source: "linear_label",
        labels: ["implementation-effort:moderate"]
      },
      overrides
    )
  end

  defp setup_root(name) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-role-bootstrap-#{name}-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "EMB-1270")
    File.mkdir_p!(workspace)

    %{
      test_root: test_root,
      workspace_root: workspace_root,
      workspace: workspace,
      trace_file: Path.join(test_root, "provider.trace")
    }
  end

  # Records the bootstrap inputs the launched turn process actually received,
  # then replays the recorded Codex app-server handshake.
  defp write_fake_codex!(path, trace_file) do
    File.write!(path, """
    #!/bin/sh
    trace_file="#{trace_file}"
    printf 'ENV_SYMPHONY_ISSUE_REPOSITORY:%s\\n' "${SYMPHONY_ISSUE_REPOSITORY}" >> "$trace_file"
    printf 'ENV_SYMPHONY_EXPECTED_BRANCH:%s\\n' "${SYMPHONY_EXPECTED_BRANCH}" >> "$trace_file"
    printf 'ENV_SYMPHONY_ISSUE_IDENTIFIER:%s\\n' "${SYMPHONY_ISSUE_IDENTIFIER}" >> "$trace_file"
    count=0

    while IFS= read -r line; do
      count=$((count + 1))

      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1270"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1270"}}}'
          printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"BOOTSTRAP_OK"}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
        *) exit 0 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp env_values(trace, key) do
    ~r/^ENV_#{key}:(.*)$/m
    |> Regex.scan(trace)
    |> Enum.map(fn [_line, value] -> value end)
  end

  test "every non-Implementer Codex role turn is launched with its declared bootstrap inputs" do
    ctx = setup_root("codex")
    codex_binary = Path.join(ctx.test_root, "fake-codex")
    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")

    on_exit(fn ->
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider)
      File.rm_rf(ctx.test_root)
    end)

    write_fake_codex!(codex_binary, ctx.trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: ctx.workspace_root,
      agent_runtime_provider: "codex",
      codex_command: "#{codex_binary} app-server"
    )

    issue = bootstrap_issue()

    for role <- @non_implementer_roles do
      assert {:ok, session} =
               AgentRuntime.start_session(ctx.workspace,
                 issue: issue,
                 role: role,
                 run_id: "run-#{role}"
               )

      assert {:ok, {next_session, _turn}} = AgentRuntime.run_turn(session, "Bootstrap probe", issue, [])
      assert :ok = AgentRuntime.stop_session(next_session)
    end

    trace = File.read!(ctx.trace_file)
    role_count = length(@non_implementer_roles)

    assert env_values(trace, "SYMPHONY_ISSUE_REPOSITORY") == List.duplicate(@repository, role_count)
    assert env_values(trace, "SYMPHONY_EXPECTED_BRANCH") == List.duplicate(@expected_branch, role_count)
    assert env_values(trace, "SYMPHONY_ISSUE_IDENTIFIER") == List.duplicate("EMB-1270", role_count)
  end

  test "every non-Implementer Claude role turn is launched with its declared bootstrap inputs" do
    ctx = setup_root("claude")
    claude_binary = Path.join(ctx.test_root, "fake-claude")
    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "claude_code")

    on_exit(fn ->
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider)
      File.rm_rf(ctx.test_root)
    end)

    write_fake_claude!(claude_binary, ctx.trace_file, stream_success())

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: ctx.workspace_root,
      agent_runtime_provider: "claude_code",
      claude_code_command: claude_binary,
      claude_code_model: "sonnet"
    )

    issue = bootstrap_issue()

    for role <- @non_implementer_roles do
      assert {:ok, session} =
               AgentRuntime.start_session(ctx.workspace,
                 issue: issue,
                 role: role,
                 run_id: "run-#{role}"
               )

      assert {:ok, {next_session, _turn}} = AgentRuntime.run_turn(session, "Bootstrap probe", issue, [])
      assert :ok = AgentRuntime.stop_session(next_session)
    end

    trace = File.read!(ctx.trace_file)
    role_count = length(@non_implementer_roles)

    assert env_values(trace, "SYMPHONY_ISSUE_REPOSITORY") == List.duplicate(@repository, role_count)
    assert env_values(trace, "SYMPHONY_EXPECTED_BRANCH") == List.duplicate(@expected_branch, role_count)
  end

  test "a role turn that cannot be supplied a required bootstrap input fails typed and named" do
    ctx = setup_root("missing")
    codex_binary = Path.join(ctx.test_root, "fake-codex")
    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")

    on_exit(fn ->
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider)
      File.rm_rf(ctx.test_root)
    end)

    write_fake_codex!(codex_binary, ctx.trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: ctx.workspace_root,
      agent_runtime_provider: "codex",
      codex_command: "#{codex_binary} app-server"
    )

    issue = bootstrap_issue(repository: nil, repository_source: nil)

    for role <- @non_implementer_roles ++ ["implementer"] do
      assert {:error, {:missing_required_bootstrap_input, details}} =
               AgentRuntime.start_session(ctx.workspace,
                 issue: issue,
                 role: role,
                 run_id: "run-#{role}"
               )

      assert details.name == "SYMPHONY_ISSUE_REPOSITORY"
      assert details.issue_identifier == "EMB-1270"

      # The failure must be irrecoverable and name the missing input, so the
      # run escalates on runtime evidence rather than on agent judgement.
      assert {:irrecoverable, failure} =
               AgentRuntime.classify_failure(
                 {:missing_required_bootstrap_input, details},
                 %{issue_id: issue.id, role: role, workspace_path: ctx.workspace}
               )

      assert failure.family == :missing_required_runtime_configuration
      assert failure.summary =~ "SYMPHONY_ISSUE_REPOSITORY"
      assert failure.irrecoverable?
    end

    # Nothing was launched: the projection failed before any turn process ran.
    refute File.exists?(ctx.trace_file)
  end
end
