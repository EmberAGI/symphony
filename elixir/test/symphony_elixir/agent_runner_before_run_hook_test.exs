defmodule SymphonyElixir.AgentRunnerBeforeRunHookTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Failure classification for the workspace `before_run` hook through the
  public `AgentRunner.run/3` boundary, and the non-live seal that keeps a
  bypassed hook from ever reaching the real implementer delegation
  transport.
  """

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    System.put_env("SYMPHONY_ROLE", "implementer")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
    end)

    :ok
  end

  test "agent runner classifies provider auth before_run hook failure as provider auth exit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-before-run-auth-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: """
        printf '%s\\n' 'Provider-auth pre-turn withheld: provider-auth provider=claude_code status=unhealthy affected_roles=implementer,reviewer remediation=run claude setup-token raw=Bearer hook-secret-token'
        exit 17
        """
      )

      issue = %Issue{
        id: "issue-before-run-auth",
        identifier: "EMB-1128",
        title: "Classify pre-turn provider auth",
        description: "Runtime auth failure",
        state: "In Progress",
        url: "https://example.org/issues/EMB-1128",
        labels: []
      }

      log =
        capture_log(fn ->
          assert catch_exit(run_agent_with_ownership(issue, nil, run_id: "run-before-run-auth")) ==
                   {:provider_auth_failed,
                    %{
                      provider: :claude_code,
                      readiness_status: "unhealthy",
                      affected_roles: "implementer,reviewer",
                      remediation_hint: "run claude setup-token"
                    }}
        end)

      assert log =~ "provider_auth_failed: claude_code readiness_status=unhealthy affected_roles=implementer,reviewer remediation=run claude setup-token"
      refute log =~ "hook-secret-token"
      refute log =~ "Bearer"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner fails closed for non-allowlisted before_run hook failures with redacted output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-before-run-ordinary-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: """
        printf '%s\\n' 'ordinary setup failure token=ordinary-hook-secret'
        exit 19
        """
      )

      issue = %Issue{
        id: "issue-before-run-ordinary",
        identifier: "EMB-1128",
        title: "Keep ordinary hook failures ordinary",
        description: "Ordinary hook failure",
        state: "In Progress",
        url: "https://example.org/issues/EMB-1128",
        labels: []
      }

      log =
        capture_log(fn ->
          assert {:irrecoverable_runtime_failed,
                  %{
                    family: :unclassified_runtime_failure,
                    subtype: "workspace_hook_failed",
                    retryable?: false
                  }} =
                   catch_exit(
                     run_agent_with_ownership(
                       issue,
                       nil,
                       run_id: "run-before-run-ordinary"
                     )
                   )
        end)

      assert log =~ "unclassified_runtime_failure"
      refute log =~ "ordinary-hook-secret"
      refute log =~ "token="
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner classifies missing tool before_run hook failure as irrecoverable runtime exit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-before-run-missing-tool-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: """
        printf '%s\\n' 'claude: command not found token=hook-secret-token'
        exit 127
        """
      )

      # The fixture write above is the seam the EMB-1180 review saw bypassed
      # under load: prove the effective configuration is the one just
      # written before exercising the public boundary.
      assert Config.settings!().hooks.before_run =~ "exit 127"

      issue = %Issue{
        id: "issue-before-run-missing-tool",
        identifier: "EMB-1127",
        title: "Classify missing tool",
        description: "Runtime missing tool",
        state: "In Progress",
        url: "https://example.org/issues/EMB-1127",
        labels: []
      }

      log =
        capture_log(fn ->
          assert {:irrecoverable_runtime_failed, failure} =
                   catch_exit(
                     run_agent_with_ownership(
                       issue,
                       nil,
                       run_id: "run-before-run-missing-tool"
                     )
                   )

          assert failure.family == :missing_required_tool_or_cli
          assert failure.retryable? == false
          refute failure.retry_reason =~ "hook-secret-token"
          refute failure.retry_reason =~ "token="
        end)

      assert log =~ "missing_required_tool_or_cli"
      refute log =~ "hook-secret-token"
      refute log =~ "token="
    after
      File.rm_rf(test_root)
    end
  end

  @tag timeout: 15_000
  test "a run whose workflow lost its before_run hook cannot reach real delegation transport" do
    # The EMB-1180 review observed this exact fall-through under suite load:
    # the missing-tool test's hook was bypassed (the effective workflow had
    # no before_run hook) and the run entered the real default Herdr
    # transport, hanging in continue_await_agent/7. This test reproduces the
    # bypassed shape deterministically — a workflow with no hooks at all —
    # and proves the non-live suite default transport rejects the run
    # immediately, before any real herdr process, session, or socket root
    # can exist.
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-non-live-seal-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-non-live-delegation-seal",
        identifier: "EMB-1180",
        repository: "EmberAGI/scaling-octo-engine",
        repository_source: "linear_label",
        title: "Sealed non-live delegation transport",
        description: "Hook-less workflow must not reach real herdr",
        state: "In Progress",
        url: "https://example.org/issues/EMB-1180",
        labels: []
      }

      capture_log(fn ->
        assert {:irrecoverable_runtime_failed,
                %{
                  family: :unclassified_runtime_failure,
                  subtype: "non_live_delegation_transport",
                  retryable?: false
                }} =
                 catch_exit(
                   run_agent_with_ownership(
                     issue,
                     nil,
                     run_id: "run-non-live-delegation-seal"
                   )
                 )
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "the suite installs the non-live delegation transport as the runtime default" do
    assert Application.get_env(:symphony_elixir, :delegation_transport_module) ==
             SymphonyElixir.TestSupport.NonLiveDelegationTransport
  end
end
