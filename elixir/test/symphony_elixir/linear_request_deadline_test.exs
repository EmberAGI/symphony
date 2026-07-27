defmodule SymphonyElixir.LinearRequestDeadlineTest do
  @moduledoc """
  RED: every Linear tracker request is bound by a total request deadline.

  Production canary EMB-1313 (pinned Symphony 96e410b0ac24). The provider run
  had completed, `AgentRunner.continue_with_issue?/1` entered
  `Tracker.fetch_issue_states_by_ids/2` synchronously, and
  `Linear.Client.graphql/3` invoked its configured `request_fun` with no total
  deadline. The request never returned, so the runner never exited, no terminal
  `DOWN` reached the Orchestrator, settlement never ran, the ownership registry
  stayed active around a dead app-server PID, role state/admission endpoints
  became unserviceable, and an operator restart was required.

  These are public-interface contracts on `Linear.Client.graphql/3`:

    * the configured total deadline bounds the injected/configured
      `request_fun` itself — not merely an HTTP connect timeout, and not
      extendable by a peer that connects and then dribbles;
    * the deadline returns an exact typed timeout through the existing Linear
      API error boundary, carrying operation context;
    * the request runs as an `async_nolink` task under the existing
      `SymphonyElixir.TaskSupervisor` and is `:brutal_kill`ed on deadline, so
      no request task, link, or monitor survives the call;
    * successful requests, non-200 statuses, and GraphQL error payloads are
      unchanged.

  Every stall is a causal barrier (the request function signals entry, then
  blocks on a message that never arrives); no test sleeps to reach the wedge.
  """
  use SymphonyElixir.TestSupport

  # Small enough that the whole suite stays fast, large enough that the
  # serviceability probes below run while the request is genuinely in flight.
  @deadline_ms 300

  # A missing deadline shows up as "never returns", so the bound on every
  # result wait is what makes these tests non-vacuous.
  @result_wait_ms 5_000

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_request_timeout_ms: @deadline_ms)
    :ok
  end

  describe "total request deadline" do
    test "a request function that never returns fails with a typed Linear request timeout" do
      test_pid = self()

      request_fun = fn _payload, _headers ->
        send(test_pid, {:request_entered, self()})

        receive do
          :never_sent -> {:ok, %{status: 200, body: %{}}}
        end
      end

      %{result: result, elapsed_ms: elapsed_ms, request_pid: request_pid} =
        bounded_call(request_fun, "query SymphonyLinearPoll { issues { nodes { id } } }", [])

      assert {:error,
              {:linear_api_request,
               {:linear_request_timeout, %{operation: "SymphonyLinearPoll", timeout_ms: @deadline_ms}}}} = result,
             "expected an exact typed Linear request timeout carrying operation context, got #{inspect(result)}"

      assert elapsed_ms < 2_000,
             "the request returned after #{elapsed_ms}ms; the configured #{@deadline_ms}ms total deadline did not bound it"

      refute Process.alive?(request_pid),
             "the stalled request process survived the deadline; it must be shut down with :brutal_kill"
    end

    test "a peer that connects and dribbles cannot extend the total deadline" do
      test_pid = self()

      # Stands in for a peer that accepts the request and keeps the socket
      # busy forever: the request function stays alive and reports progress,
      # so a connect-only or inactivity-only timeout would never fire.
      request_fun = fn _payload, _headers ->
        send(test_pid, {:request_entered, self()})
        dribble(test_pid, 1)
      end

      %{result: result, elapsed_ms: elapsed_ms} =
        bounded_call(request_fun, "query SymphonyLinearIssuesById { issues { nodes { id } } }",
          operation_name: "SymphonyLinearIssuesById"
        )

      assert {:error,
              {:linear_api_request,
               {:linear_request_timeout,
                %{operation: "SymphonyLinearIssuesById", timeout_ms: @deadline_ms}}}} = result,
             "a dribbling peer must still hit the total deadline, got #{inspect(result)}"

      assert_receive {:dribble, 1}, 100
      assert_receive {:dribble, 2}, 100

      assert elapsed_ms < 2_000,
             "a dribbling peer extended the request to #{elapsed_ms}ms past the #{@deadline_ms}ms total deadline"
    end

    test "the deadline leaves no request task, link, or monitor behind" do
      test_pid = self()

      request_fun = fn _payload, _headers ->
        send(test_pid, {:request_entered, self()})

        receive do
          :never_sent -> {:ok, %{status: 200, body: %{}}}
        end
      end

      %{
        result: result,
        request_pid: request_pid,
        caller_pid: caller_pid,
        caller_links: caller_links,
        caller_monitors: caller_monitors,
        caller_messages: caller_messages
      } = bounded_call(request_fun, "query SymphonyLinearPoll { issues { nodes { id } } }", [])

      assert match?({:error, {:linear_api_request, {:linear_request_timeout, _context}}}, result)

      assert Process.alive?(caller_pid),
             "the caller died with the request task; the request must run async_nolink"

      refute request_pid in caller_links,
             "the caller stayed linked to the request task; async_nolink semantics are required"

      assert caller_monitors == [],
             "a monitor on the shut-down request task survived the call: #{inspect(caller_monitors)}"

      refute Enum.any?(caller_messages, &match?({:DOWN, _ref, :process, ^request_pid, _reason}, &1)),
             "an unflushed :DOWN for the shut-down request task was left in the caller's mailbox"

      assert_eventually(fn -> request_pid not in supervised_task_pids() end)

      send(caller_pid, :stop)
    end

    test "a request function that exits does not take the caller down" do
      test_pid = self()

      request_fun = fn _payload, _headers ->
        send(test_pid, {:request_entered, self()})
        exit(:transport_died)
      end

      %{result: result, caller_pid: caller_pid} =
        bounded_call(request_fun, "query SymphonyLinearPoll { issues { nodes { id } } }", [])

      assert {:error, {:linear_api_request, {:linear_request_exited, :transport_died}}} = result,
             "an exiting request transport must surface as a typed Linear request failure, got #{inspect(result)}"

      assert Process.alive?(caller_pid), "the caller was killed by its own request task"
      send(caller_pid, :stop)
    end
  end

  describe "unchanged request behavior" do
    test "a request that completes inside the deadline returns its body unchanged" do
      body = %{"data" => %{"viewer" => %{"id" => "user-1315"}}}

      assert {:ok, ^body} =
               Client.graphql("query SymphonyLinearViewer { viewer { id } }", %{},
                 request_fun: fn _payload, _headers -> {:ok, %{status: 200, body: body}} end
               )
    end

    test "a non-200 status and a GraphQL error payload keep their existing typed contracts" do
      capture_log(fn ->
        assert {:error, {:linear_api_status, 503}} =
                 Client.graphql("query SymphonyLinearViewer { viewer { id } }", %{},
                   request_fun: fn _payload, _headers -> {:ok, %{status: 503, body: "unavailable"}} end
                 )
      end)

      errors = [%{"message" => "Argument Validation Error"}]

      assert {:error, {:linear_graphql_errors, ^errors}} =
               Client.fetch_issue_states_by_ids_for_test(["issue-1315"], fn _query, _variables ->
                 {:ok, %{"errors" => errors}}
               end)
    end

    test "a transport error reason is still reported unclassified through the request boundary" do
      capture_log(fn ->
        assert {:error, {:linear_api_request, :econnrefused}} =
                 Client.graphql("query SymphonyLinearViewer { viewer { id } }", %{},
                   request_fun: fn _payload, _headers -> {:error, :econnrefused} end
                 )
      end)
    end
  end

  describe "configuration" do
    test "the total tracker request timeout defaults to 30 seconds in production config" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_request_timeout_ms: nil)

      assert Config.settings!().tracker.request_timeout_ms == 30_000
    end

    test "a non-positive or non-integer total request timeout fails configuration validation" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_request_timeout_ms: 0)
      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "tracker.request_timeout_ms"

      write_workflow_file!(Workflow.workflow_file_path(), tracker_request_timeout_ms: -1)
      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "tracker.request_timeout_ms"

      write_workflow_file!(Workflow.workflow_file_path(), tracker_request_timeout_ms: "soon")
      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "tracker.request_timeout_ms"

      write_workflow_file!(Workflow.workflow_file_path(), tracker_request_timeout_ms: 1_500)
      assert :ok = Config.validate!()
      assert Config.settings!().tracker.request_timeout_ms == 1_500
    end
  end

  # Runs `graphql/3` in an isolated caller so the deadline, the caller's own
  # links/monitors, and the request task's fate are all observable from the
  # test process. The request function signals entry causally; the wait bound
  # is what fails when no deadline exists at all.
  defp bounded_call(request_fun, query, opts) do
    test_pid = self()
    opts = Keyword.put(opts, :request_fun, request_fun)

    caller_pid =
      spawn(fn ->
        started_at = System.monotonic_time(:millisecond)
        result = Client.graphql(query, %{}, opts)
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        {:links, links} = Process.info(self(), :links)
        {:monitors, monitors} = Process.info(self(), :monitors)
        {:messages, messages} = Process.info(self(), :messages)

        send(
          test_pid,
          {:graphql_result, result, elapsed_ms, links, Enum.map(monitors, fn {_kind, pid} -> pid end), messages}
        )

        receive do
          :stop -> :ok
        after
          @result_wait_ms -> :ok
        end
      end)

    assert_receive {:request_entered, request_pid}, @result_wait_ms

    receive do
      {:graphql_result, result, elapsed_ms, links, monitors, messages} ->
        %{
          result: result,
          elapsed_ms: elapsed_ms,
          request_pid: request_pid,
          caller_pid: caller_pid,
          caller_links: links,
          caller_monitors: monitors,
          caller_messages: messages
        }
    after
      @result_wait_ms ->
        flunk("Linear.Client.graphql/3 never returned; the total request deadline is missing")
    end
  end

  defp dribble(test_pid, chunk) do
    send(test_pid, {:dribble, chunk})

    receive do
      :never_sent -> {:ok, %{status: 200, body: %{}}}
    after
      10 -> dribble(test_pid, chunk + 1)
    end
  end

  defp supervised_task_pids do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      nil -> []
      _pid -> Task.Supervisor.children(SymphonyElixir.TaskSupervisor)
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, 0), do: assert(fun.(), "condition was never met")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
