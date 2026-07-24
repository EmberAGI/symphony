defmodule SymphonyElixir.RuntimeFailedRunTypingTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  RED: a failed role run must never look like a normal run.

  The Orchestrator's monitored-task seam has exactly one success signal — the
  runner task exiting `:normal`. Everything that reaches
  `handle_info({:DOWN, ref, :process, pid, :normal}, state)` is recorded as a
  completed agent run and scheduled only for an active-state continuation
  check; no failure observation, no retry error, no escalation.

  These tests drive `AgentRunner.run/3` through the same supervised task the
  Orchestrator dispatches and assert the exit reason for five failure kinds:

    * worker launch failure,
    * worker death / missing worker result,
    * worker result timeout,
    * `agent.max_turns` exhaustion with the issue still active, and
    * post-turn routing failure (issue-state routing refresh, and the
      post-turn routing hook).

  Each must exit with a typed failure reason. Any `:normal` exit here is the
  production symptom: a failed run reported as a completed one.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Runtime.ProcessOwnership

  # A delegated session whose orchestrator turn always settles successfully.
  # The only variable is what the session reports about its worker
  # assignments, so a `:normal` exit below means the run's worker outcome was
  # never consulted.
  defmodule WorkerOutcomeTransport do
    def default_server_snapshot(_context),
      do: {:ok, %{status: "running", version: "0.7.5", protocol: 17, socket: "/tmp/default.sock"}}

    def start_session(spec, _context) do
      {:ok,
       %{
         name: spec.name,
         socket: "/tmp/#{spec.name}/herdr.sock",
         runtime_root: "/tmp/#{spec.name}",
         workspace: spec.workspace
       }}
    end

    def prepare_worker(session, _spec, _context) do
      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}
    end

    def start_agent(_session, spec, _context),
      do: {:ok, %{name: spec.name, pane_id: "w1:p1", agent_status: "idle"}}

    def begin_turn(_session, agent, prompt, _timeout_ms, context) do
      if test_pid = Map.get(context, :test_pid) do
        send(test_pid, {:worker_outcome_turn_started, prompt})
      end

      {:ok,
       %{
         phase: :completed,
         agent: %{name: agent.name, agent_status: "idle", agent_session: %{value: "sess"}}
       }}
    end

    def get_agent(_session, agent, _timeout_ms, _context),
      do: {:ok, %{name: agent.name, agent_status: "idle"}}

    def read_agent(_session, _agent, _opts, _context),
      do: {:ok, %{text: "orchestrator turn finished"}}

    def stop_session(_session, %{stop_result: stop_result}), do: stop_result
    def stop_session(_session, _context), do: :ok

    def owned_session_ref(session, context) do
      %{
        cleanup_module: __MODULE__,
        owner: Map.get(context, :test_pid),
        issue_id: Map.get(context, :issue_id),
        session_name: session.name
      }
    end

    def cleanup_owned_session(%{owner: owner, session_name: session_name}) do
      if is_pid(owner), do: send(owner, {:owned_session_cleanup_called, session_name})
      :ok
    end

    def worker_assignments(_session, %{assignments: assignments}), do: {:ok, assignments}
    def worker_assignments(_session, _context), do: {:ok, []}
  end

  setup do
    previous_role = System.get_env("SYMPHONY_ROLE")
    previous_orchestrator = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_worker = System.get_env("OCTO_RUNTIME_WORKER_PROVIDER")
    System.put_env("SYMPHONY_ROLE", "implementer")
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    System.put_env("OCTO_RUNTIME_WORKER_PROVIDER", "codex")

    on_exit(fn ->
      restore_env("SYMPHONY_ROLE", previous_role)
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_orchestrator)
      restore_env("OCTO_RUNTIME_WORKER_PROVIDER", previous_worker)
    end)

    :ok
  end

  test "a worker launch failure exits the monitored runner task with a typed failure" do
    reason =
      run_reason("launch-failed",
        assignments: [
          %{
            assignment_id: "assign-launch-failed",
            status: :launch_failed,
            reason: {:worker_launch_failed, :wrapper_acknowledgement_missing}
          }
        ]
      )

    assert_typed_failed_run(reason)
  end

  test "a dead worker with no result exits the monitored runner task with a typed failure" do
    reason =
      run_reason("worker-died",
        assignments: [
          %{
            assignment_id: "assign-died",
            status: :died,
            reason: {:herdr_agent_closed, "implementer_worker"}
          }
        ]
      )

    assert_typed_failed_run(reason)
  end

  test "a worker result that never arrived exits the monitored runner task with a typed failure" do
    reason =
      run_reason("worker-timeout",
        assignments: [%{assignment_id: "assign-timed-out", status: :timed_out}]
      )

    assert_typed_failed_run(reason)
  end

  test "max-turn exhaustion with the issue still active exits with a typed failure, not :normal" do
    reason =
      run_reason("max-turns",
        max_turns: 1,
        issue_state_fetcher: fn [issue_id] -> {:ok, [%{issue("max-turns") | id: issue_id}]} end
      )

    assert_typed_failed_run(reason)
  end

  test "a post-turn issue routing refresh failure exits with a typed failure, not :normal" do
    reason =
      run_reason("routing-refresh",
        max_turns: 2,
        issue_state_fetcher: fn [_issue_id] -> {:error, :tracker_unavailable} end
      )

    assert_typed_failed_run(reason)
  end

  test "a post-turn routing hook failure exits with a typed failure, not :normal" do
    reason = run_reason("routing-hook", hook_after_run: "exit 3")

    assert_typed_failed_run(reason)
  end

  test "a post-turn routing hook failure stops before normal continuation" do
    reason =
      run_reason("routing-hook-no-continuation",
        hook_after_run: "exit 3",
        max_turns: 2,
        test_pid: self(),
        issue_state_fetcher: fn [issue_id] ->
          {:ok, [%{issue("routing-hook-no-continuation") | id: issue_id}]}
        end
      )

    assert_typed_failed_run(reason)
    assert_receive {:worker_outcome_turn_started, first_prompt}
    refute first_prompt =~ "previous Codex turn completed normally"
    refute_receive {:worker_outcome_turn_started, _continuation_prompt}, 100
  end

  test "the orchestrator acknowledges the Implementer cleanup capability before the first prompt" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-owned-session-ack-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    issue = issue("owned-session-ack")
    test_pid = self()

    assert {:ok, process_ownership} =
             ProcessOwnership.acquire(issue, %{
               role: "implementer",
               run_id: "run-owned-session-ack",
               holder: ProcessOwnership.holder_id()
             })

    {:ok, pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        AgentRunner.run(issue, test_pid,
          run_id: "run-owned-session-ack",
          role: "implementer",
          process_ownership: process_ownership,
          delegation_transport: WorkerOutcomeTransport,
          delegation_transport_context: %{
            assignments: [],
            issue_id: issue.id,
            test_pid: test_pid
          }
        )
      end)

    monitor_ref = Process.monitor(pid)

    assert_receive {:owned_session_runtime_info, issue_id, ownership_ref, ack_recipient, ack_ref},
                   1_000

    assert issue_id == issue.id
    assert ownership_ref.issue_id == issue.id
    assert ownership_ref.session_name =~ "octo-emb-hotfix"
    refute_receive {:worker_outcome_turn_started, _prompt}, 100

    send(ack_recipient, {:owned_session_runtime_info_ack, ack_ref})
    assert_receive {:worker_outcome_turn_started, _prompt}, 1_000
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000
  end

  test "a failed owned-session cleanup exits with a typed failure, not :normal" do
    reason =
      run_reason("cleanup-failed",
        stop_result: {:error, {:herdr_owned_processes_remain, [41_001]}}
      )

    assert_typed_failed_run(reason)
  end

  test "missing process ownership fails before any role hook or provider prompt" do
    {reason, before_marker, after_marker} =
      run_with_invalid_ownership("ownership-missing", nil)

    assert reason ==
             {:agent_runtime_failed, {:process_ownership_publication_failed, :ownership_missing}}

    refute File.exists?(before_marker)
    refute File.exists?(after_marker)
    refute_receive {:worker_outcome_turn_started, _prompt}, 100
  end

  test "mismatched process ownership fails before any role hook or provider prompt" do
    invalid_ownership = fn issue ->
      assert {:ok, ownership} =
               ProcessOwnership.acquire(issue, %{
                 role: "implementer",
                 run_id: "run-ownership-mismatch",
                 holder: ProcessOwnership.holder_id()
               })

      {%{ownership | run_id: "wrong-run"}, ownership}
    end

    {reason, before_marker, after_marker} =
      run_with_invalid_ownership("ownership-mismatch", invalid_ownership)

    assert reason ==
             {:agent_runtime_failed, {:process_ownership_publication_failed, :ownership_mismatch}}

    refute File.exists?(before_marker)
    refute File.exists?(after_marker)
    refute_receive {:worker_outcome_turn_started, _prompt}, 100
  end

  # The Orchestrator has exactly one success signal at its monitored-task
  # seam. A `:normal` exit is recorded as a completed agent run, so a failed
  # run must never produce one, and the reason must be a typed runtime
  # failure the retry/escalation classifier can read.
  defp assert_typed_failed_run(reason) do
    refute reason == :normal,
           "failed run exited :normal; the Orchestrator records that as a completed agent run"

    assert match?({:agent_runtime_failed, _}, reason) or
             match?({:irrecoverable_runtime_failed, _}, reason) or
             match?({:provider_auth_failed, _}, reason),
           "expected a typed runtime failure exit, got: #{inspect(reason)}"
  end

  defp run_reason(label, opts) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-failed-run-typing-#{label}-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      [workspace_root: workspace_root] ++ Keyword.take(opts, [:hook_after_run])
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    runner_opts =
      [
        run_id: "run-#{label}",
        role: "implementer",
        delegation_transport: WorkerOutcomeTransport,
        delegation_transport_context: %{
          assignments: Keyword.get(opts, :assignments, []),
          stop_result: Keyword.get(opts, :stop_result, :ok),
          test_pid: Keyword.get(opts, :test_pid)
        }
      ] ++ Keyword.take(opts, [:max_turns, :issue_state_fetcher])

    issue = issue(label)

    {reason, _log} =
      with_log(fn ->
        {:ok, pid} =
          Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
            AgentRunner.run(issue, nil, runner_opts)
          end)

        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} -> reason
        after
          15_000 -> flunk("runner task for #{label} did not finish")
        end
      end)

    reason
  end

  defp run_with_invalid_ownership(label, ownership_builder) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-ownership-pre-hook-#{label}-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    before_marker = Path.join(test_root, "before-run-called")
    after_marker = Path.join(test_root, "after-run-called")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_run: "touch #{before_marker}",
      hook_after_run: "touch #{after_marker}"
    )

    issue = issue(label)

    {process_ownership, ownership_to_release} =
      case ownership_builder do
        builder when is_function(builder, 1) -> builder.(issue)
        _ -> {nil, nil}
      end

    on_exit(fn ->
      if is_map(ownership_to_release) do
        _ =
          ProcessOwnership.release(issue, %{
            holder: ownership_to_release.holder,
            run_id: ownership_to_release.run_id,
            workspace_path: ownership_to_release.workspace_path
          })
      end

      File.rm_rf(test_root)
    end)

    runner_opts =
      [
        run_id: "run-#{label}",
        role: "implementer",
        delegation_transport: WorkerOutcomeTransport,
        delegation_transport_context: %{assignments: [], test_pid: self()}
      ]
      |> maybe_put_process_ownership(process_ownership)

    {:ok, pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        AgentRunner.run(issue, nil, runner_opts)
      end)

    ref = Process.monitor(pid)

    reason =
      receive do
        {:DOWN, ^ref, :process, ^pid, exit_reason} -> exit_reason
      after
        5_000 -> flunk("runner task for #{label} did not finish")
      end

    {reason, before_marker, after_marker}
  end

  defp maybe_put_process_ownership(opts, nil), do: opts

  defp maybe_put_process_ownership(opts, ownership),
    do: Keyword.put(opts, :process_ownership, ownership)

  defp issue(label) do
    %Issue{
      id: "issue-failed-run-#{label}",
      identifier: "EMB-HOTFIX",
      title: "Typed failed runs",
      description: "A failed run must never look normal",
      state: "In Progress",
      branch_name: "octo/emb-hotfix-typed-failed-runs",
      url: "https://example.org/issues/EMB-HOTFIX",
      labels: ["implementation-effort:moderate"]
    }
  end
end
