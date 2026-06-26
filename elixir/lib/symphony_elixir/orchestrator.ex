defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    AgentRuntime,
    Config,
    ImplementationEffort,
    RoleTurnRecovery,
    Runtime.ProcessOwnership,
    StatusDashboard,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Notifications.Telegram
  alias SymphonyElixir.Tracker.ClaimLease

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @claim_lease_min_ttl_ms 60_000
  @claim_lease_refresh_interval_ms 30_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :last_poll_started_at,
      :last_poll_completed_at,
      :last_poll_result,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      latest_dispatch_summary: %{
        result: "not_checked",
        candidate_count: 0,
        dispatched_count: 0,
        candidate_identifiers: [],
        dispatched_identifiers: [],
        skip_reason_families: [],
        skipped_candidates: []
      }
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      last_poll_started_at: nil,
      last_poll_completed_at: nil,
      last_poll_result: "not_checked",
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil,
      latest_dispatch_summary: empty_dispatch_summary("not_checked")
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    started_at = DateTime.utc_now()
    state = %{state | last_poll_started_at: started_at}
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)

    completed_at = DateTime.utc_now()

    state = %{
      state
      | poll_check_in_progress: false,
        last_poll_completed_at: completed_at,
        last_poll_result: latest_poll_result(state)
    }

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)
        process_completion_status = record_process_completion(running_entry, reason)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")
              RoleTurnRecovery.clear_turn(issue_id)

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                issue: Map.get(running_entry, :issue),
                claim_lease: Map.get(running_entry, :claim_lease),
                run_id: Map.get(running_entry, :run_id),
                retry_reason: "active-state-continuation-check",
                lease_state: retry_lease_state(process_completion_status)
              })

            {:provider_auth_failed, _details} ->
              RoleTurnRecovery.clear_turn(issue_id)
              block_provider_auth_failure(state, issue_id, running_entry, reason)

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")
              maybe_notify_agent_failed(running_entry, reason)

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                issue: Map.get(running_entry, :issue),
                claim_lease: Map.get(running_entry, :claim_lease),
                run_id: Map.get(running_entry, :run_id),
                retry_reason: "agent exited: #{inspect(reason)}",
                lease_state: retry_lease_state(process_completion_status)
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{task_exit_reason_for_log(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> record_process_ownership(issue_id)
          |> maybe_refresh_claim_lease(issue_id, true)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        updated_running_entry =
          updated_running_entry
          |> record_process_ownership(issue_id)
          |> maybe_refresh_claim_lease(issue_id)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, handle_missing_retry_attempt(state, issue_id)}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    RoleTurnRecovery.recover_pending_turns(active_state_set(), terminal_state_set(), Map.keys(state.running))
    state = reconcile_running_issues(state)
    state = reconcile_orphaned_claims(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        record_dispatch_summary(state, candidate_fetch_failure_summary(:missing_linear_api_token))

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        record_dispatch_summary(state, candidate_fetch_failure_summary(:missing_linear_project_slug))

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        record_dispatch_summary(state, candidate_fetch_failure_summary(:missing_tracker_kind))

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        record_dispatch_summary(state, candidate_fetch_failure_summary(:unsupported_tracker_kind))

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        record_dispatch_summary(state, candidate_fetch_failure_summary(:invalid_workflow_config))

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        record_dispatch_summary(state, candidate_fetch_failure_summary(:missing_workflow_file))

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        record_dispatch_summary(state, candidate_fetch_failure_summary(:workflow_front_matter_not_a_map))

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        record_dispatch_summary(state, candidate_fetch_failure_summary(:workflow_parse_error))

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        record_dispatch_summary(state, candidate_fetch_failure_summary(:tracker_candidate_fetch_failure))
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set(), false)
  end

  @doc false
  @spec handle_retry_issue_for_test(term(), String.t(), pos_integer(), map()) :: {:noreply, term()}
  def handle_retry_issue_for_test(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and is_map(metadata) do
    handle_retry_issue(state, issue_id, attempt, metadata)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec reconcile_claims_for_test(term()) :: term()
  def reconcile_claims_for_test(%State{} = state) do
    reconcile_orphaned_claims(state)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    maybe_notify_human_escalation_label(state, issue)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true, issue)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, issue)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, issue)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp maybe_notify_human_escalation_label(%State{} = state, %Issue{id: issue_id} = issue)
       when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{issue: %Issue{} = previous_issue} ->
        if human_escalation_label?(issue) and !human_escalation_label?(previous_issue) do
          Telegram.notify_human_escalation(issue)
        end

      _ ->
        :ok
    end
  end

  defp maybe_notify_human_escalation_label(_state, _issue), do: :ok

  defp human_escalation_label?(%Issue{labels: labels}) when is_list(labels) do
    Enum.any?(labels, &(normalize_label(&1) == "human escalation"))
  end

  defp human_escalation_label?(_issue), do: false

  defp normalize_label(label) when is_binary(label), do: String.downcase(String.trim(label))
  defp normalize_label(_label), do: ""

  defp maybe_notify_agent_failed(%{issue: %Issue{} = issue}, reason) do
    Telegram.notify_agent_failed(issue, reason)
  end

  defp maybe_notify_agent_failed(_running_entry, _reason), do: :ok

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, release_issue \\ nil) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id, release_issue)

      %{pid: pid, ref: ref} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)
        issue_or_identifier = Map.get(running_entry, :issue) || Map.get(running_entry, :identifier)

        if cleanup_workspace do
          cleanup_issue_workspace(issue_or_identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        record_process_completion(running_entry, :terminated)
        maybe_release_claim_lease(release_issue || Map.get(running_entry, :issue))

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        RoleTurnRecovery.clear_turn(issue_id)

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id, release_issue)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")
      maybe_notify_agent_failed(running_entry, "stalled for #{elapsed_ms}ms without codex activity")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state = terminate_running_issue(state, issue_id, false)
      process_ownership = retry_process_ownership_status(running_entry)

      schedule_issue_retry(state, issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity",
        issue: Map.get(running_entry, :issue),
        claim_lease: Map.get(running_entry, :claim_lease),
        run_id: Map.get(running_entry, :run_id),
        retry_reason: "stalled for #{elapsed_ms}ms without codex activity",
        lease_state: retry_lease_state_from_process_ownership(process_ownership),
        process_ownership: process_ownership
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    sorted_issues = sort_issues_for_dispatch(issues)

    result =
      Enum.reduce(sorted_issues, %{state: state, skipped: [], dispatched: [], failed: [], attempted: 0}, fn issue, acc ->
        case dispatch_skip_summary(issue, acc.state, active_states, terminal_states) do
          nil ->
            {next_state, dispatch_result} = dispatch_issue_with_result(acc.state, issue)

            acc
            |> Map.put(:state, next_state)
            |> record_dispatch_result(issue, dispatch_result)

          skip_summary ->
            Map.update!(acc, :skipped, &[skip_summary | &1])
        end
      end)

    summary =
      sorted_issues
      |> dispatch_cycle_summary(result.skipped, result.dispatched, result.failed, result.attempted)

    record_dispatch_summary(result.state, summary)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {
          sort_order_rank(issue),
          issue_sort_order_sort_key(issue),
          priority_rank(issue.priority),
          issue_created_at_sort_key(issue),
          issue.identifier || issue.id || ""
        }

      _ ->
        {
          sort_order_rank(nil),
          issue_sort_order_sort_key(nil),
          priority_rank(nil),
          issue_created_at_sort_key(nil),
          ""
        }
    end)
  end

  defp sort_order_rank(%Issue{sort_order: sort_order}) when is_number(sort_order), do: 0
  defp sort_order_rank(_issue), do: 1

  defp issue_sort_order_sort_key(%Issue{sort_order: sort_order}) when is_number(sort_order) do
    sort_order
  end

  defp issue_sort_order_sort_key(_issue), do: 0

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{} = state,
         active_states,
         terminal_states
       ) do
    is_nil(dispatch_skip_summary(issue, state, active_states, terminal_states))
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp dispatch_skip_summary(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    cond do
      !candidate_issue?(issue, active_states, terminal_states) ->
        skipped_candidate_summary(issue, "not_candidate")

      !valid_implementation_effort?(issue) ->
        skipped_candidate_summary(issue, "invalid_implementation_effort")

      todo_issue_blocked_by_non_terminal?(issue, terminal_states) ->
        skipped_candidate_summary(issue, "blocked_by_non_terminal")

      blocking_claim_leases(issue) != [] ->
        claim_lease_skipped_candidate_summary(issue, blocking_claim_leases(issue))

      process_ownership_blocks_dispatch?(issue) ->
        skipped_candidate_summary(issue, "process_ownership_blocked")

      MapSet.member?(claimed, issue.id) ->
        skipped_candidate_summary(issue, "already_claimed")

      Map.has_key?(running, issue.id) ->
        skipped_candidate_summary(issue, "already_running")

      available_slots(state) <= 0 ->
        skipped_candidate_summary(issue, "role_capacity_blocked")

      !state_slots_available?(issue, running) ->
        skipped_candidate_summary(issue, "state_capacity_blocked")

      !worker_slots_available?(state) ->
        skipped_candidate_summary(issue, "worker_capacity_blocked")

      true ->
        nil
    end
  end

  defp dispatch_skip_summary(_issue, _state, _active_states, _terminal_states),
    do: skipped_candidate_summary(nil, "not_candidate")

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp valid_implementation_effort?(%Issue{} = issue) do
    provider = AgentRuntime.provider()

    case ImplementationEffort.profile_for_issue(provider, issue, nil) do
      {:ok, _profile} ->
        true

      {:error, reason} ->
        Logger.error("Skipping dispatch; invalid Implementation Effort labels for #{issue_context(issue)} runtime_provider=#{provider}: #{inspect(reason)}")

        false
    end
  end

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    {state, _result} = dispatch_issue_with_result(state, issue, attempt, preferred_worker_host)
    state
  end

  defp dispatch_issue_with_result(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           terminal_state_set(),
           retry_dispatch?(attempt)
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue_with_result(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {state, {:skipped, skipped_candidate_summary(issue, "missing_after_refresh")}}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {state, {:skipped, skipped_candidate_summary(refreshed_issue, "stale_after_refresh")}}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {state, {:failed, "issue_refresh_failed"}}
    end
  end

  defp do_dispatch_issue_with_result(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        {state, {:skipped, skipped_candidate_summary(issue, "worker_capacity_blocked")}}

      worker_host ->
        run_id = new_run_id(issue)

        case upsert_dispatch_claim_lease(issue, attempt, worker_host, run_id) do
          {:ok, %ClaimLease{} = claim_lease} ->
            spawn_issue_on_worker_host_with_result(state, issue, attempt, recipient, worker_host, claim_lease)

          {:ok, nil} ->
            spawn_issue_on_worker_host_with_result(state, issue, attempt, recipient, worker_host, nil)

          {:error, reason} ->
            Logger.warning("Skipping dispatch; claim lease upsert failed for #{issue_context(issue)}: #{inspect(reason)}")
            {state, {:failed, "claim_lease_upsert_failed"}}
        end
    end
  end

  defp spawn_issue_on_worker_host_with_result(%State{} = state, issue, attempt, recipient, worker_host, claim_lease) do
    record_pending_turn_start(issue, worker_host)

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             run_id: claim_lease && claim_lease.run_id
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            claim_lease: claim_lease || Map.get(issue, :claim_lease),
            claim_lease_refreshed_at_ms: System.monotonic_time(:millisecond),
            run_id: claim_lease && claim_lease.run_id,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }
        |> then(&{&1, :dispatched})

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        RoleTurnRecovery.clear_turn(issue.id)
        Telegram.notify_agent_failed(issue, reason)
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        {
          schedule_issue_retry(state, issue.id, next_attempt, %{
            identifier: issue.identifier,
            error: "failed to spawn agent: #{inspect(reason)}",
            worker_host: worker_host
          }),
          {:failed, "spawn_failed"}
        }
    end
  end

  defp record_pending_turn_start(%Issue{} = issue, worker_host) do
    case RoleTurnRecovery.record_turn_start(issue, worker_host: worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to record pending role turn for #{issue_context(issue)}: #{inspect(reason)}")
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states, retry_dispatch?)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) and
             claim_lease_allows_dispatch?(refreshed_issue, retry_dispatch?) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states, _retry_dispatch?), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp upsert_dispatch_claim_lease(%Issue{id: issue_id} = issue, attempt, worker_host, run_id)
       when is_binary(issue_id) do
    attrs =
      build_claim_lease_attrs(
        issue,
        attempt,
        worker_host,
        run_id,
        claim_lease_update_overrides(issue)
      )

    Tracker.upsert_claim_lease(issue_id, attrs)
  end

  defp upsert_dispatch_claim_lease(_issue, _attempt, _worker_host, _run_id), do: {:ok, nil}

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = retry_attempt_for(previous_retry, attempt)
    delay_ms = retry_delay(next_attempt, metadata)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    retry_context = retry_context(issue_id, previous_retry, metadata)

    cancel_retry_timer(previous_retry)

    retry_claim_lease =
      maybe_upsert_retry_claim_lease(issue_id, retry_context.issue, retry_context.claim_lease, next_attempt, delay_ms, %{
        error: retry_context.error,
        worker_host: retry_context.worker_host,
        workspace_path: retry_context.workspace_path,
        run_id: retry_context.run_id,
        process_ownership: retry_context.process_ownership,
        retry_reason: metadata[:retry_reason] || retry_context.error,
        recovery_reason: metadata[:recovery_reason],
        lease_state: metadata[:lease_state] || "retrying"
      })

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{retry_context.identifier} in #{delay_ms}ms (attempt #{next_attempt})#{retry_error_suffix(retry_context.error)}")

    %{
      state
      | retry_attempts:
          Map.put(
            state.retry_attempts,
            issue_id,
            retry_entry(next_attempt, timer_ref, retry_token, due_at_ms, retry_context, retry_claim_lease)
          )
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          issue: Map.get(retry_entry, :issue),
          claim_lease: Map.get(retry_entry, :claim_lease),
          run_id: Map.get(retry_entry, :run_id),
          process_ownership: Map.get(retry_entry, :process_ownership)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_missing_retry_attempt(%State{} = state, issue_id) when is_binary(issue_id) do
    cond do
      Map.has_key?(state.retry_attempts, issue_id) ->
        Logger.warning("Dropping stale retry timer for issue_id=#{issue_id}; newer retry entry is still queued")
        state

      Map.has_key?(state.running, issue_id) ->
        Logger.warning("Dropping retry timer for issue_id=#{issue_id}; issue is already running")
        state

      MapSet.member?(state.claimed, issue_id) ->
        Logger.warning("Retry chain missing for claimed issue_id=#{issue_id}; releasing leaked claim")
        release_issue_claim(state, issue_id)

      true ->
        Logger.debug("Dropping retry timer for unclaimed issue_id=#{issue_id}")
        state
    end
  end

  defp handle_missing_retry_attempt(state, _issue_id), do: state

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [issue | _]} ->
        issue
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:ok, []} ->
        handle_retry_issue_lookup(nil, state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id, issue)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      retry_blocked_by_process_ownership?(issue, terminal_states) ->
        handle_process_blocked_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id, issue)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            cleanup_issue_workspace(issue)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           issue: issue,
           identifier: issue.identifier,
           error: "no available orchestrator slots",
           retry_reason: "no available orchestrator slots",
           lease_state: "retrying"
         })
       )}
    end
  end

  defp handle_process_blocked_retry(state, issue, attempt, metadata) do
    process_ownership = ProcessOwnership.status_for_issue(issue) || metadata[:process_ownership]
    lease_state = retry_lease_state_from_process_ownership(process_ownership)

    Logger.warning("Retry dispatch blocked by live process ownership for #{issue_context(issue)}; preserving #{lease_state} retry ownership")

    {:noreply,
     schedule_issue_retry(
       state,
       issue.id,
       attempt + 1,
       Map.merge(metadata, %{
         issue: issue,
         identifier: issue.identifier,
         error: metadata[:error] || "process ownership blocks retry dispatch",
         retry_reason: metadata[:retry_reason] || metadata[:error] || "process ownership blocks retry dispatch",
         lease_state: lease_state,
         process_ownership: process_ownership
       })
     )}
  end

  defp block_provider_auth_failure(%State{} = state, issue_id, running_entry, reason) do
    summary = AgentRuntime.provider_auth_failure_summary(reason)
    identifier = Map.get(running_entry, :identifier, issue_id)
    issue = Map.get(running_entry, :issue)
    maybe_upsert_provider_auth_blocked_claim_lease(issue_id, issue, running_entry, summary)

    Logger.error(
      "Provider authentication failed for issue_id=#{issue_id} issue_identifier=#{identifier}; blocked ordinary retry status=#{provider_auth_status_for_log(reason)} subtype=#{provider_auth_subtype_for_log(reason)}"
    )

    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp maybe_upsert_provider_auth_blocked_claim_lease(issue_id, %Issue{} = issue, running_entry, summary)
       when is_binary(issue_id) do
    attrs =
      provider_auth_blocked_claim_lease_attrs(issue, running_entry, summary)

    case Tracker.upsert_claim_lease(issue_id, attrs) do
      {:ok, %ClaimLease{} = blocked_lease} ->
        blocked_lease

      {:error, upsert_reason} ->
        Logger.warning("Failed to update provider-auth blocked claim lease for #{issue_context(issue)}: #{inspect(upsert_reason)}")
        nil

      _ ->
        nil
    end
  end

  defp maybe_upsert_provider_auth_blocked_claim_lease(_issue_id, _issue, _running_entry, _summary), do: nil

  defp provider_auth_blocked_claim_lease_attrs(%Issue{} = issue, running_entry, summary) do
    claim_lease = Map.get(running_entry, :claim_lease) || Map.get(issue, :claim_lease)

    build_claim_lease_attrs(
      issue,
      Map.get(running_entry, :retry_attempt),
      Map.get(running_entry, :worker_host),
      Map.get(running_entry, :run_id) || (claim_lease && claim_lease.run_id),
      %{
        comment_id: claim_lease && claim_lease.comment_id,
        started_at: (claim_lease && claim_lease.started_at) || Map.get(running_entry, :started_at),
        workspace_path: Map.get(running_entry, :workspace_path),
        session_id: running_entry_session_id(running_entry),
        retry_reason: summary,
        recovery_reason: "provider-authentication-required",
        state: "blocked"
      }
    )
  end

  defp provider_auth_status_for_log({:provider_auth_failed, details}) when is_map(details) do
    case Map.get(details, :api_error_status) do
      status when is_integer(status) -> Integer.to_string(status)
      _ -> "unknown"
    end
  end

  defp provider_auth_status_for_log(_reason), do: "unknown"

  defp provider_auth_subtype_for_log({:provider_auth_failed, details}) when is_map(details) do
    case Map.get(details, :subtype) do
      subtype when is_binary(subtype) -> subtype
      _ -> "unknown"
    end
  end

  defp provider_auth_subtype_for_log(_reason), do: "unknown"

  defp task_exit_reason_for_log({:provider_auth_failed, _details} = reason) do
    AgentRuntime.provider_auth_failure_summary(reason)
  end

  defp task_exit_reason_for_log(reason), do: inspect(reason)

  defp reconcile_orphaned_claims(%State{} = state) do
    active_claims =
      state.running
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Map.keys(state.retry_attempts)))

    state.claimed
    |> MapSet.difference(active_claims)
    |> Enum.reduce(state, fn issue_id, state_acc ->
      Logger.warning("Claimed issue is neither running nor retrying; releasing leaked claim issue_id=#{issue_id}")
      release_issue_claim(state_acc, issue_id)
    end)
  end

  defp release_issue_claim(%State{} = state, issue_id, issue \\ nil) do
    maybe_release_claim_lease(issue)
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp retry_dispatch?(attempt), do: normalize_retry_attempt(attempt) > 0

  defp retry_attempt_for(_previous_retry, attempt) when is_integer(attempt), do: attempt
  defp retry_attempt_for(previous_retry, _attempt), do: previous_retry.attempt + 1

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp retry_context(issue_id, previous_retry, metadata) do
    %{
      identifier: pick_retry_identifier(issue_id, previous_retry, metadata),
      error: pick_retry_error(previous_retry, metadata),
      worker_host: pick_retry_worker_host(previous_retry, metadata),
      workspace_path: pick_retry_workspace_path(previous_retry, metadata),
      issue: pick_retry_issue(previous_retry, metadata),
      claim_lease: pick_retry_claim_lease(previous_retry, metadata),
      run_id: pick_retry_run_id(previous_retry, metadata),
      process_ownership: pick_retry_process_ownership(previous_retry, metadata)
    }
  end

  defp cancel_retry_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_retry_timer(_previous_retry), do: :ok

  defp retry_error_suffix(error) when is_binary(error), do: " error=#{error}"
  defp retry_error_suffix(_error), do: ""

  defp retry_entry(next_attempt, timer_ref, retry_token, due_at_ms, retry_context, retry_claim_lease) do
    %{
      attempt: next_attempt,
      timer_ref: timer_ref,
      retry_token: retry_token,
      due_at_ms: due_at_ms,
      identifier: retry_context.identifier,
      error: retry_context.error,
      worker_host: retry_context.worker_host,
      workspace_path: retry_context.workspace_path,
      issue: retry_context.issue,
      claim_lease: retry_claim_lease || retry_context.claim_lease,
      run_id: retry_context.run_id || (retry_claim_lease && retry_claim_lease.run_id),
      process_ownership: retry_context.process_ownership
    }
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_issue(previous_retry, metadata) do
    case metadata[:issue] || Map.get(previous_retry, :issue) do
      %Issue{} = issue -> issue
      _ -> nil
    end
  end

  defp pick_retry_claim_lease(previous_retry, metadata) do
    case metadata[:claim_lease] || Map.get(previous_retry, :claim_lease) do
      %ClaimLease{} = claim_lease -> claim_lease
      _ -> nil
    end
  end

  defp pick_retry_run_id(previous_retry, metadata) do
    metadata[:run_id] || Map.get(previous_retry, :run_id)
  end

  defp pick_retry_process_ownership(previous_retry, metadata) do
    metadata[:process_ownership] || Map.get(previous_retry, :process_ownership)
  end

  defp maybe_upsert_retry_claim_lease(_issue_id, nil, _claim_lease, _attempt, _delay_ms, _metadata), do: nil

  defp maybe_upsert_retry_claim_lease(issue_id, %Issue{} = issue, claim_lease, attempt, delay_ms, metadata) do
    now = DateTime.utc_now()
    run_id = retry_claim_run_id(metadata, claim_lease, issue)
    attrs = retry_claim_lease_attrs(issue, claim_lease, attempt, delay_ms, metadata, now, run_id)

    issue_id
    |> Tracker.upsert_claim_lease(attrs)
    |> retry_claim_lease_result(issue)
  end

  defp retry_claim_run_id(metadata, claim_lease, issue) do
    metadata[:run_id] || (claim_lease && claim_lease.run_id) || new_run_id(issue)
  end

  defp retry_claim_lease_attrs(issue, claim_lease, attempt, delay_ms, metadata, now, run_id) do
    build_claim_lease_attrs(issue, attempt, metadata[:worker_host], run_id, %{
      comment_id: claim_lease && claim_lease.comment_id,
      started_at: (claim_lease && claim_lease.started_at) || now,
      workspace_path: metadata[:workspace_path],
      retry_reason: metadata[:retry_reason] || metadata[:error],
      recovery_reason: metadata[:recovery_reason],
      state: metadata[:lease_state] || "retrying"
    })
    |> Map.put(:expires_at, retry_claim_expires_at(now, delay_ms))
  end

  defp retry_claim_expires_at(now, delay_ms) do
    DateTime.add(now, max(delay_ms + claim_lease_ttl_ms(), claim_lease_ttl_ms()), :millisecond)
  end

  defp retry_claim_lease_result(result, issue) do
    case result do
      {:ok, %ClaimLease{} = retry_claim_lease} ->
        retry_claim_lease

      {:error, reason} ->
        Logger.warning("Failed to update retry claim lease for #{issue_context(issue)}: #{inspect(reason)}")
        nil

      _ ->
        nil
    end
  end

  defp maybe_refresh_claim_lease(running_entry, issue_id, force \\ false)

  defp maybe_refresh_claim_lease(%{issue: %Issue{} = issue} = running_entry, issue_id, force)
       when is_binary(issue_id) do
    claim_lease = Map.get(running_entry, :claim_lease) || Map.get(issue, :claim_lease)

    if should_refresh_claim_lease?(claim_lease, running_entry, force) do
      refreshed_attrs =
        build_claim_lease_attrs(
          issue,
          Map.get(running_entry, :retry_attempt),
          Map.get(running_entry, :worker_host),
          Map.get(running_entry, :run_id) || claim_lease.run_id,
          %{
            comment_id: claim_lease.comment_id,
            started_at: claim_lease.started_at || Map.get(running_entry, :started_at),
            workspace_path: Map.get(running_entry, :workspace_path),
            session_id: running_entry_session_id(running_entry)
          }
        )

      case Tracker.upsert_claim_lease(issue_id, refreshed_attrs) do
        {:ok, %ClaimLease{} = refreshed_lease} ->
          running_entry
          |> Map.put(:claim_lease, refreshed_lease)
          |> Map.put(:claim_lease_refreshed_at_ms, System.monotonic_time(:millisecond))

        _ ->
          running_entry
      end
    else
      running_entry
    end
  end

  defp maybe_refresh_claim_lease(running_entry, _issue_id, _force), do: running_entry

  defp should_refresh_claim_lease?(nil, _running_entry, _force), do: false
  defp should_refresh_claim_lease?(_claim_lease, _running_entry, true), do: true

  defp should_refresh_claim_lease?(_claim_lease, running_entry, false) do
    case Map.get(running_entry, :claim_lease_refreshed_at_ms) do
      refreshed_at_ms when is_integer(refreshed_at_ms) ->
        System.monotonic_time(:millisecond) - refreshed_at_ms >= @claim_lease_refresh_interval_ms

      _ ->
        true
    end
  end

  defp build_claim_lease_attrs(%Issue{} = issue, attempt, worker_host, run_id, overrides) do
    now = DateTime.utc_now()

    %{
      holder: ClaimLease.holder_id(),
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      role: ClaimLease.role_name(),
      run_id: run_id,
      worker_host: worker_host,
      workspace_path: nil,
      session_id: nil,
      started_at: now,
      refreshed_at: now,
      expires_at: DateTime.add(now, claim_lease_ttl_ms(), :millisecond),
      attempt: normalize_retry_attempt(attempt),
      state: "active"
    }
    |> Map.merge(claim_lease_overrides(overrides))
  end

  defp claim_lease_overrides(overrides) when is_map(overrides) do
    overrides
    |> Map.take([:comment_id, :workspace_path, :session_id, :started_at, :retry_reason, :recovery_reason, :state])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp claim_lease_update_overrides(%Issue{} = issue) do
    case current_scope_claim_lease(issue) do
      %ClaimLease{} = claim_lease -> %{comment_id: claim_lease.comment_id}
      _ -> %{}
    end
  end

  defp current_scope_claim_lease(%Issue{} = issue) do
    issue
    |> issue_claim_leases()
    |> Enum.find(fn %ClaimLease{} = claim_lease ->
      claim_lease_role_matches?(claim_lease) and claim_lease_workspace_matches?(issue, claim_lease)
    end)
  end

  defp maybe_release_claim_lease(%Issue{} = issue) do
    claim_lease = current_scope_claim_lease(issue)

    if is_nil(claim_lease) do
      :ok
    else
      release_claim_lease(issue, claim_lease)
    end
  end

  defp maybe_release_claim_lease(_issue), do: :ok

  defp release_claim_lease(%Issue{} = issue, %ClaimLease{} = claim_lease) do
    attrs =
      build_claim_lease_attrs(
        issue,
        claim_lease.attempt,
        claim_lease.worker_host,
        claim_lease.run_id || new_run_id(issue),
        %{
          comment_id: claim_lease.comment_id,
          started_at: claim_lease.started_at,
          workspace_path: claim_lease.workspace_path,
          session_id: claim_lease.session_id,
          recovery_reason: "issue-left-active-dispatch",
          state: "released"
        }
      )

    case Tracker.upsert_claim_lease(issue.id, attrs) do
      {:ok, _claim_lease} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to release claim lease for #{issue_context(issue)}: #{inspect(reason)}")
        :ok
    end
  end

  defp claim_lease_ttl_ms do
    config = Config.settings!()
    max(@claim_lease_min_ttl_ms, max(config.codex.stall_timeout_ms, config.polling.interval_ms * 2))
  end

  defp claim_lease_allows_top_level_dispatch?(%Issue{} = issue) do
    blocking_claim_leases(issue) == []
  end

  defp claim_lease_allows_dispatch?(%Issue{} = issue, true) do
    case blocking_claim_leases(issue) do
      [] ->
        true

      claim_leases ->
        Enum.all?(claim_leases, fn %ClaimLease{} = claim_lease ->
          ClaimLease.owned_by_current_holder?(claim_lease) and normalize_claim_lease_state(claim_lease.state) == "retrying"
        end)
    end
  end

  defp claim_lease_allows_dispatch?(%Issue{} = issue, _retry_dispatch?) do
    claim_lease_allows_top_level_dispatch?(issue)
  end

  defp normalize_claim_lease_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp blocking_claim_leases(%Issue{} = issue) do
    now = DateTime.utc_now()

    issue
    |> issue_claim_leases()
    |> Enum.filter(&claim_lease_blocks_current_dispatch?(issue, &1, now))
  end

  defp issue_claim_leases(%Issue{} = issue) do
    leases =
      issue
      |> Map.get(:claim_leases, [])
      |> Enum.filter(&match?(%ClaimLease{}, &1))

    case Map.get(issue, :claim_lease) do
      %ClaimLease{} = claim_lease -> [claim_lease | leases]
      _ -> leases
    end
    |> Enum.uniq_by(&claim_lease_identity/1)
  end

  defp claim_lease_identity(%ClaimLease{} = claim_lease) do
    {claim_lease.comment_id, claim_lease.role, claim_lease.workspace_path, claim_lease.holder, claim_lease.run_id}
  end

  defp claim_lease_blocks_current_dispatch?(%Issue{} = issue, %ClaimLease{} = claim_lease, %DateTime{} = now) do
    ClaimLease.active_or_recoverable?(claim_lease, now) and
      claim_lease_role_matches?(claim_lease) and
      claim_lease_workspace_matches?(issue, claim_lease)
  end

  defp claim_lease_role_matches?(%ClaimLease{role: role}) do
    blank?(role) or role == ClaimLease.role_name()
  end

  defp claim_lease_workspace_matches?(%Issue{} = issue, %ClaimLease{workspace_path: workspace_path}) do
    blank?(workspace_path) or
      workspace_paths_match?(workspace_path, expected_workspace_path(issue))
  end

  defp workspace_paths_match?(workspace_path, expected_workspace_path)
       when is_binary(workspace_path) and is_binary(expected_workspace_path) do
    normalize_workspace_path(workspace_path) == normalize_workspace_path(expected_workspace_path)
  end

  defp workspace_paths_match?(_workspace_path, _expected_workspace_path), do: false

  defp expected_workspace_path(%Issue{} = issue) do
    case issue.identifier || issue.id do
      identifier when is_binary(identifier) and identifier != "" ->
        Path.join(Config.settings!().workspace.root, workspace_basename(identifier, issue.repository))

      _ ->
        nil
    end
  end

  defp workspace_basename(identifier, repository) do
    case repository_workspace_suffix(repository) do
      nil -> safe_workspace_name(identifier)
      "" -> safe_workspace_name(identifier)
      suffix -> "#{safe_workspace_name(identifier)}-#{suffix}"
    end
  end

  defp repository_workspace_suffix(repository) when is_binary(repository) and repository != "" do
    repository
    |> String.split("/", parts: 2)
    |> List.last()
    |> safe_workspace_name()
  end

  defp repository_workspace_suffix(_repository), do: nil

  defp normalize_workspace_path(path) when is_binary(path), do: path |> Path.expand() |> Path.absname()

  defp safe_workspace_name(value) when is_binary(value), do: String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")
  defp safe_workspace_name(_value), do: nil

  defp blank?(value), do: !is_binary(value) or String.trim(value) == ""

  defp process_ownership_blocks_dispatch?(%Issue{} = issue) do
    case ProcessOwnership.blocking_record(issue) do
      nil ->
        false

      record ->
        Logger.warning("Skipping dispatch; process ownership still blocks #{issue_context(issue)} state=#{record["state"]} app_server_pid=#{record["app_server_pid"]}")
        true
    end
  end

  defp record_process_ownership(%{issue: %Issue{} = issue} = running_entry, _issue_id) do
    ProcessOwnership.record_active(issue, process_ownership_attrs(running_entry))
    running_entry
  end

  defp record_process_ownership(running_entry, _issue_id), do: running_entry

  defp record_process_completion(%{issue: %Issue{} = issue} = running_entry, :normal) do
    attrs = process_ownership_attrs(running_entry)

    if ProcessOwnership.owned_process_live?(issue, attrs) do
      ProcessOwnership.record_quarantined(
        issue,
        attrs,
        "app-server process remained live after normal worker exit"
      )

      :quarantined
    else
      ProcessOwnership.record_cleaned(issue, attrs)
      :cleaned
    end
  end

  defp record_process_completion(%{issue: %Issue{} = issue} = running_entry, reason) do
    attrs = process_ownership_attrs(running_entry)

    if ProcessOwnership.owned_process_live?(issue, attrs) do
      ProcessOwnership.record_quarantined(issue, attrs, "agent exited before app-server process cleaned: #{inspect(reason)}")
      :quarantined
    else
      ProcessOwnership.record_cleaned(issue, attrs)
      :cleaned
    end
  end

  defp record_process_completion(_running_entry, _reason), do: :none

  defp retry_lease_state(:quarantined), do: "quarantined"
  defp retry_lease_state(_process_completion_status), do: "retrying"

  defp retry_lease_state_from_process_ownership(%{state: "quarantined"}), do: "quarantined"
  defp retry_lease_state_from_process_ownership(_process_ownership), do: "retrying"

  defp retry_process_ownership_status(%{issue: %Issue{} = issue}), do: ProcessOwnership.status_for_issue(issue)
  defp retry_process_ownership_status(_running_entry), do: nil

  defp retry_process_ownership_snapshot(%{process_ownership: process_ownership})
       when is_map(process_ownership),
       do: process_ownership

  defp retry_process_ownership_snapshot(%{issue: %Issue{} = issue}), do: ProcessOwnership.status_for_issue(issue)
  defp retry_process_ownership_snapshot(_retry), do: nil

  defp process_ownership_attrs(running_entry) when is_map(running_entry) do
    %{
      role: ClaimLease.role_name(),
      run_id: Map.get(running_entry, :run_id),
      holder: ClaimLease.holder_id(),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      app_server_pid: Map.get(running_entry, :codex_app_server_pid)
    }
  end

  defp new_run_id(%Issue{id: issue_id}) do
    unique = System.unique_integer([:positive, :monotonic])
    "#{ClaimLease.holder_id()}:#{issue_id || "issue"}:#{unique}"
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          claim_lease: Map.get(metadata, :claim_lease),
          process_ownership: ProcessOwnership.status_for_issue(metadata.issue),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          claim_lease: Map.get(retry, :claim_lease),
          process_ownership: retry_process_ownership_snapshot(retry)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms,
         last_poll_started_at: iso8601(state.last_poll_started_at),
         last_poll_completed_at: iso8601(state.last_poll_completed_at),
         last_poll_result: state.last_poll_result,
         latest_dispatch_summary: state.latest_dispatch_summary
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp record_dispatch_result(acc, issue, :dispatched) do
    acc
    |> Map.update!(:attempted, &(&1 + 1))
    |> Map.update!(:dispatched, &[safe_issue_identifier(issue) | &1])
  end

  defp record_dispatch_result(acc, _issue, {:failed, reason_family}) do
    acc
    |> Map.update!(:attempted, &(&1 + 1))
    |> Map.update!(:failed, &[reason_family | &1])
  end

  defp record_dispatch_result(acc, _issue, {:skipped, skip_summary}) do
    Map.update!(acc, :skipped, &[skip_summary | &1])
  end

  defp record_dispatch_result(acc, _issue, _result), do: acc

  defp dispatch_cycle_summary(issues, skipped, dispatched, failed, attempted) do
    skipped = Enum.reverse(skipped)
    dispatched = dispatched |> Enum.reverse() |> Enum.reject(&is_nil/1)
    failed = Enum.reverse(failed)
    candidate_identifiers = issues |> Enum.map(&safe_issue_identifier/1) |> Enum.reject(&is_nil/1)

    result =
      cond do
        issues == [] -> "no_candidates"
        dispatched != [] -> "dispatch_succeeded"
        failed != [] -> "dispatch_failed"
        attempted > 0 -> "dispatch_attempted"
        length(skipped) == length(issues) -> "all_candidates_skipped"
        true -> "all_candidates_skipped"
      end

    %{
      result: result,
      candidate_count: length(issues),
      dispatched_count: length(dispatched),
      attempted_count: attempted,
      candidate_identifiers: Enum.take(candidate_identifiers, 10),
      dispatched_identifiers: Enum.take(dispatched, 10),
      skip_reason_families: skipped |> Enum.map(& &1.reason_family) |> Enum.uniq() |> Enum.take(10),
      skipped_candidates: Enum.take(skipped, 10),
      failure_reason_families: failed |> Enum.uniq() |> Enum.take(10)
    }
  end

  defp empty_dispatch_summary(result) do
    %{
      result: result,
      candidate_count: 0,
      dispatched_count: 0,
      attempted_count: 0,
      candidate_identifiers: [],
      dispatched_identifiers: [],
      skip_reason_families: [],
      skipped_candidates: [],
      failure_reason_families: []
    }
  end

  defp candidate_fetch_failure_summary(reason_family) do
    "candidate_fetch_failure"
    |> empty_dispatch_summary()
    |> Map.put(:failure_reason_families, [safe_reason_family(reason_family)])
  end

  defp record_dispatch_summary(%State{} = state, summary) when is_map(summary) do
    log_dispatch_cycle(summary)

    %{
      state
      | latest_dispatch_summary: summary,
        last_poll_result: Map.get(summary, :result, "unknown")
    }
  end

  defp latest_poll_result(%State{latest_dispatch_summary: summary, last_poll_result: last_poll_result}) do
    case summary do
      %{result: result} when is_binary(result) -> result
      _ -> last_poll_result
    end
  end

  defp skipped_candidate_summary(%Issue{} = issue, reason_family) do
    %{
      issue_id: issue.id,
      issue_identifier: safe_issue_identifier(issue),
      reason_family: reason_family
    }
  end

  defp skipped_candidate_summary(_issue, reason_family) do
    %{issue_id: nil, issue_identifier: nil, reason_family: reason_family}
  end

  defp claim_lease_skipped_candidate_summary(%Issue{} = issue, claim_leases) when is_list(claim_leases) do
    claim_lease = List.first(claim_leases)
    reason_family = claim_lease_skip_reason_family(claim_lease)

    issue
    |> skipped_candidate_summary(reason_family)
    |> Map.put(:claim_lease, claim_lease_diagnostic(claim_lease))
  end

  defp claim_lease_skip_reason_family(%ClaimLease{} = claim_lease) do
    cond do
      ClaimLease.owned_by_current_holder?(claim_lease) -> "claim_lease_blocked"
      true -> "stale_claim_lease_blocked"
    end
  end

  defp claim_lease_diagnostic(%ClaimLease{} = claim_lease) do
    %{
      holder: claim_lease.holder,
      role: claim_lease.role,
      state: claim_lease.state,
      expires_at: iso8601(claim_lease.expires_at),
      recovery_decision: claim_lease_recovery_decision(claim_lease)
    }
  end

  defp claim_lease_diagnostic(_claim_lease), do: %{}

  defp claim_lease_recovery_decision(%ClaimLease{} = claim_lease) do
    if ClaimLease.owned_by_current_holder?(claim_lease) do
      "current_holder_retry_or_release"
    else
      "wait_for_expiry_or_dead_holder_recovery"
    end
  end

  defp safe_issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
  defp safe_issue_identifier(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp safe_issue_identifier(_issue), do: nil

  defp safe_reason_family(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason_family(reason) when is_binary(reason), do: reason
  defp safe_reason_family(_reason), do: "unknown"

  defp log_dispatch_cycle(summary) when is_map(summary) do
    Logger.info(
      "Poll dispatch cycle result=#{Map.get(summary, :result)} candidate_count=#{Map.get(summary, :candidate_count)} dispatched_count=#{Map.get(summary, :dispatched_count)} skip_reason_families=#{inspect(Map.get(summary, :skip_reason_families, []))} failure_reason_families=#{inspect(Map.get(summary, :failure_reason_families, []))}"
    )
  end

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !process_ownership_blocks_dispatch?(issue)
  end

  defp retry_blocked_by_process_ownership?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      process_ownership_blocks_dispatch?(issue)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:metadata],
      Map.get(update, "metadata"),
      Map.get(update, :metadata),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &direct_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp direct_token_usage_from_payload(payload) when is_map(payload) do
    if integer_token_map?(payload), do: payload
  end

  defp direct_token_usage_from_payload(_payload), do: nil

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
