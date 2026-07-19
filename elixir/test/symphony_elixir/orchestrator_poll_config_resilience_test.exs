defmodule SymphonyElixir.OrchestratorPollConfigResilienceTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Poll-cycle resilience at the orchestrator public boundary: a transiently
  invalid WORKFLOW.md (for example an operator or test writing the file
  between validations) must skip the dispatch cycle visibly — logged error
  plus a `candidate_fetch_failure` summary — while the orchestrator process,
  its poll timer, and its snapshot Interface stay alive. A raise here
  previously crash-looped the GenServer until the root supervisor gave up
  and stopped the whole application mid-`make all`.
  """

  test "poll cycle skips visibly and survives a transiently invalid workflow config" do
    orchestrator_name = Module.concat(__MODULE__, :InvalidConfigOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator!(pid)
    end)

    # Invalid claude_code effort fails config validation, so every
    # Config.settings!/0 read in the poll and snapshot paths raises.
    write_workflow_file!(Workflow.workflow_file_path(), claude_code_effort: "bogus")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, :run_poll_cycle)

        wait_until(fn ->
          match?(
            %{
              polling: %{
                checking?: false,
                latest_dispatch_summary: %{
                  result: "candidate_fetch_failure",
                  failure_reason_families: ["invalid_workflow_config"]
                }
              }
            },
            GenServer.call(pid, :snapshot)
          )
        end)
      end)

    assert Process.alive?(pid)
    assert log =~ "Invalid WORKFLOW.md config"

    # The snapshot Interface stays available and the next poll is scheduled,
    # so recovery needs no restart once the config becomes valid again.
    snapshot = GenServer.call(pid, :snapshot)
    assert is_integer(snapshot.polling.next_poll_in_ms)

    write_workflow_file!(Workflow.workflow_file_path())
    send(pid, :run_poll_cycle)

    wait_until(fn ->
      snapshot = GenServer.call(pid, :snapshot)

      snapshot.polling.checking? == false and
        snapshot.polling.latest_dispatch_summary.failure_reason_families != ["invalid_workflow_config"]
    end)

    assert Process.alive?(pid)
  end

  defp wait_until(predicate, timeout_ms \\ 2_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(predicate, deadline_ms)
  end

  defp do_wait_until(predicate, deadline_ms) do
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator poll-cycle state")
      else
        Process.sleep(5)
        do_wait_until(predicate, deadline_ms)
      end
    end
  end
end
