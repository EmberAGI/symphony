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
    RunLog,
    Runtime.CurrentRun,
    Runtime.ProcessOwnership,
    StatusDashboard,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Notifications.Telegram

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Terminal settlement runs off the serial path but must still reach a typed
  # outcome in bounded time: on timeout the settlement task is killed and the
  # ownership record is quarantined typed via one cheap write, never left
  # silently active because teardown hung (EMB-1260). Generous default,
  # overridable for tests via app env.
  @default_terminal_settlement_timeout_ms 60_000
  # How long a settling Implementer turn may go WITHOUT runtime activity before
  # forced cleanup — not how long the whole turn may take. Delegation
  # supervision emits `turn_heartbeat` while the Herdr orchestrator is working,
  # and every such update refreshes this window (EMB-1307), so a legitimately
  # progressing turn is never raced no matter how long it runs; a genuinely
  # live-but-stale provider turn stays owned by Supervision's stale-working
  # threshold and hard turn budget.
  #
  # The window only has to outlive one silent stretch of a healthy turn: one
  # normal observation cycle (a 30s heartbeat interval plus a 5s bounded status
  # read) plus the terminal evidence path the turn still owes after supervision
  # returns. 90s gives a practical margin over the normal cycle while staying a
  # finite escape hatch if terminal evidence collection itself hangs — the real
  # Herdr transport's `read_agent` shells out through an unbounded `System.cmd`,
  # so the normal-cycle estimate is deliberately not a total-turn bound.
  @default_implementer_handoff_settlement_inactivity_ms 90_000
  # Ownership states that mean settlement already reached its terminal write.
  # A record in one of these has LEFT active on its own observed evidence, so
  # the settlement deadline must never overwrite it with a fabricated failure.
  #
  # `quarantined` belongs here UNCONDITIONALLY, not only when its evidence shows
  # a physically clean runtime. The question this list answers is "did the
  # settlement already land a terminal typed write?", not "is the runtime
  # clean?". A quarantine carrying evidence marked unavailable is still a true
  # statement about what the settlement could observe; replacing it with a
  # fabricated `terminal_settlement_timed_out` reason would destroy true
  # evidence and substitute a claim that may be false (EMB-1260 67-SF4b,
  # preserving the 67-F1 property). A settled record still hands off to the
  # ordinary retry lease, so nothing is left unreconciled.
  @settled_ownership_states ~w(cleaned released quarantined)
  @work_admission_marker_version 1
  @max_generation_length 128
  @settlement_evidence_unavailable_reason "settlement_evidence_unavailable: terminal cleanup evidence could not be captured"
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
      :execution_generation,
      :work_admission_marker_path,
      :last_poll_started_at,
      :last_poll_completed_at,
      :last_poll_result,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      failure_observations: %{},
      blocked_failures: %{},
      # In-flight terminal settlements moved OFF the serial GenServer path
      # (EMB-1260): token -> settlement context. The issue stays claimed while
      # settling so it cannot be re-dispatched, and the expensive OS teardown
      # runs in a supervised task while the GenServer keeps answering.
      settlements: %{},
      # At most one routine durable refresh runs per issue. New observations
      # coalesce into one follow-up snapshot while the exact-run task is busy.
      routine_persistence: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      work_admission: %{status: "open", target_generation: nil},
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
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()
    execution_generation = execution_generation(opts)
    marker_path = work_admission_marker_path(opts)
    work_admission = load_work_admission(marker_path, execution_generation)

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      execution_generation: execution_generation,
      work_admission_marker_path: marker_path,
      work_admission: work_admission,
      last_poll_started_at: nil,
      last_poll_completed_at: nil,
      last_poll_result: "not_checked",
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil,
      latest_dispatch_summary: empty_dispatch_summary("not_checked")
    }

    recover_stale_owned_sessions()
    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def terminate(reason, %State{} = state) do
    state =
      Enum.reduce(Map.keys(state.running), state, fn issue_id, state ->
        fence_routine_process_ownership(state, issue_id)
      end)

    Enum.each(state.running, fn {issue_id, running_entry} ->
      safely_settle_on_shutdown(issue_id, running_entry, reason)
    end)

    Enum.each(abandoned_settlements(state), fn settlement ->
      settle_abandoned_settlement(settlement, reason)
    end)

    :ok
  end

  # A run popped out of `state.running` and handed to off-loop settlement is
  # still mid-teardown. Iterating `running` alone meant shutdown dropped every
  # in-flight settlement on the floor and left its ownership record parked
  # non-terminal forever — the observed production failure (EMB-1258's QA record
  # stuck at state=retrying / cleanup=retrying with 306 pids).
  #
  # `running` and `settlements` are disjoint by construction (the :DOWN handler
  # pops before it dispatches), but the filter makes that obvious and makes a
  # double-settle impossible rather than merely unlikely.
  defp abandoned_settlements(%State{} = state) do
    state.settlements
    |> Map.values()
    |> Enum.filter(fn
      %{issue_id: issue_id} when is_binary(issue_id) -> not Map.has_key?(state.running, issue_id)
      _settlement -> true
    end)
  end

  # Bounded and non-raising: this runs inside the GenServer shutdown budget, so
  # it kills the racer rather than waiting on it. The settlement task and its
  # deadline timer both write the same ownership record, so both must be gone
  # before the terminal write below — otherwise a dying task can clobber it.
  # Nothing here reads `:snapshot`, which is populated asynchronously.
  defp settle_abandoned_settlement(settlement, reason) when is_map(settlement) do
    cancel_settlement_timer(settlement)
    kill_settlement_task(settlement)

    safely_settle_on_shutdown(
      Map.get(settlement, :issue_id),
      Map.get(settlement, :running_entry),
      reason
    )
  end

  defp settle_abandoned_settlement(_settlement, _reason), do: :ok

  # One entry failing to settle must never abort the shutdown sweep over the
  # rest. `settle_cancelled_role_run/3` already logs typed cleanup failures
  # instead of raising; this is the belt-and-braces boundary for anything the
  # OS-facing teardown throws or exits with on the way down.
  defp safely_settle_on_shutdown(issue_id, running_entry, reason) do
    settle_cancelled_role_run(issue_id, running_entry, reason)
  catch
    kind, value ->
      Logger.error(
        "Shutdown settlement raised issue_id=#{inspect(issue_id)} " <>
          "stop_reason=#{inspect(reason)} kind=#{inspect(kind)} error=#{inspect(value)}"
      )

      :ok
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
        {:noreply, finish_routine_process_ownership_exit(state, ref, reason)}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)

        # Move the expensive, shell-forking terminal settlement OFF the serial
        # GenServer path (EMB-1260): the OS teardown + ownership record write
        # run in a supervised task while the GenServer stays serviceable. The
        # issue stays claimed so it cannot be re-dispatched while settling; the
        # result is finalized in handle_info({:settlement_result, ...}).
        state = dispatch_terminal_settlement(state, issue_id, running_entry, reason)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:settlement_result, token, result}, %State{} = state) do
    {:noreply, finalize_terminal_settlement(state, token, result)}
  end

  # The settlement task reports its pre-teardown snapshot back to the loop (the
  # loop itself never forks `ps`). Storing it is a cheap map write; an unknown
  # or already-settled token is a no-op so a report that raced the deadline can
  # never resurrect a popped settlement entry.
  def handle_info({:settlement_snapshot, token, snapshot}, %State{} = state) do
    {:noreply, store_settlement_snapshot(state, token, snapshot)}
  end

  def handle_info({:settlement_timeout, token}, %State{} = state) do
    {:noreply, time_out_terminal_settlement(state, token)}
  end

  def handle_info(
        {:worker_runtime_info, issue_id, envelope, runtime_info},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_map(envelope) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        if current_run_matches?(running_entry, envelope) do
          updated_running_entry =
            running_entry
            |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
            |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
            |> record_process_ownership(issue_id)
            |> Map.put(:process_ownership_refreshed_at_ms, System.monotonic_time(:millisecond))

          notify_dashboard()
          {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info(
        {:owned_session_runtime_info, issue_id, envelope, ownership_ref, ack_recipient, ack_ref},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_map(envelope) and is_map(ownership_ref) and
             is_pid(ack_recipient) and is_reference(ack_ref) do
    case record_owned_session_runtime_info(running, state, issue_id, envelope, ownership_ref) do
      {:registered, state} ->
        send(ack_recipient, {:owned_session_runtime_info_ack, ack_ref})
        {:noreply, state}

      {:missing, state} ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:owned_session_runtime_info, issue_id, envelope, ownership_ref},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_map(envelope) and is_map(ownership_ref) do
    {_registration, state} =
      record_owned_session_runtime_info(running, state, issue_id, envelope, ownership_ref)

    {:noreply, state}
  end

  def handle_info(
        {:codex_worker_update, issue_id, envelope, update},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_map(envelope) and is_map(update) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {:noreply, integrate_current_run_update(state, issue_id, running_entry, envelope, update)}
    end
  end

  def handle_info({ref, result}, %State{} = state) when is_reference(ref) do
    case Enum.find(state.routine_persistence, fn {_issue_id, routine} ->
           Map.get(routine, :token) == ref
         end) do
      {issue_id, %{run_id: run_id}} ->
        {:noreply, finish_routine_process_ownership(state, issue_id, ref, run_id, result)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _envelope, _update}, state),
    do: {:noreply, state}

  # Issue-only notifications are intentionally not upgraded to whichever run
  # happens to own the issue when they finally leave the mailbox.
  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info(
        {:retry_issue, issue_id, retry_token},
        %State{work_admission: %{status: "closed"}} = state
      ) do
    notify_dashboard()
    {:noreply, hold_fired_retry_attempt(state, issue_id, retry_token)}
  end

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

  defp integrate_current_run_update(state, issue_id, running_entry, envelope, update) do
    if current_run_matches?(running_entry, envelope) do
      activity_at_ms = accepted_activity_at_ms(running_entry.current_run, envelope, update)

      {updated_running_entry, token_delta} =
        integrate_codex_update(running_entry, update, activity_at_ms)

      state =
        state
        |> apply_codex_token_delta(token_delta)
        |> apply_codex_rate_limits(update)

      state = %{state | running: Map.put(state.running, issue_id, updated_running_entry)}
      CurrentRun.acknowledge_update(running_entry.current_run)
      state = schedule_routine_process_ownership(state, issue_id)

      notify_dashboard()
      state
    else
      state
    end
  end

  defp accepted_activity_at_ms(current_run, envelope, update) do
    case CurrentRun.accepted_activity(current_run, envelope, update) do
      {:ok, ingress_at_ms} -> ingress_at_ms
      :invalid -> nil
    end
  end

  defp record_owned_session_runtime_info(running, state, issue_id, envelope, ownership_ref) do
    case Map.get(running, issue_id) do
      nil ->
        # The issue can leave the active state between session startup and this
        # message. Clean the now-unclaimed capability immediately.
        _ = AgentRuntime.cleanup_owned_session(ownership_ref)
        {:missing, state}

      running_entry ->
        if current_run_matches?(running_entry, envelope) do
          ownership_ref = Map.put_new(ownership_ref, :issue_id, issue_id)

          updated_running_entry =
            running_entry
            |> Map.put(:owned_session_ref, ownership_ref)
            |> record_process_ownership(issue_id)

          {:registered, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
        else
          _ = AgentRuntime.cleanup_owned_session(ownership_ref)
          {:missing, state}
        end
    end
  end

  # Config.settings!/0 raise sites inside the dispatch path (state-set reads,
  # tracker fetch, agent dispatch) can observe a WORKFLOW.md rewritten into an
  # invalid state after this cycle's own validation passed. That transient
  # invalidity skips the cycle visibly instead of terminating the
  # orchestrator: a raise here crash-loops the GenServer until the root
  # supervisor gives up and stops the whole application.
  defp maybe_dispatch(%State{} = state) do
    dispatch_candidates(state)
  rescue
    error in ArgumentError ->
      message = Exception.message(error)

      if String.starts_with?(message, "Invalid WORKFLOW.md config:") do
        Logger.error("Skipping poll dispatch cycle; #{message}")
        record_dispatch_summary(state, candidate_fetch_failure_summary(:invalid_workflow_config))
      else
        reraise error, __STACKTRACE__
      end
  end

  defp dispatch_candidates(%State{} = state) do
    RoleTurnRecovery.recover_pending_turns(
      active_state_set(),
      terminal_state_set(),
      Map.keys(state.running)
    )

    state = reconcile_running_issues(state)
    state = reconcile_orphaned_claims(state)

    if work_admission_open?(state) do
      with :ok <- Config.validate!(),
           {:ok, issues} <- Tracker.fetch_candidate_issues() do
        choose_issues(issues, state)
      else
        {:error, :missing_linear_api_token} ->
          Logger.error("Linear API token missing in WORKFLOW.md")

          record_dispatch_summary(
            state,
            candidate_fetch_failure_summary(:missing_linear_api_token)
          )

        {:error, :missing_linear_project_slug} ->
          Logger.error("Linear project slug missing in WORKFLOW.md")

          record_dispatch_summary(
            state,
            candidate_fetch_failure_summary(:missing_linear_project_slug)
          )

        {:error, :missing_tracker_kind} ->
          Logger.error("Tracker kind missing in WORKFLOW.md")

          record_dispatch_summary(state, candidate_fetch_failure_summary(:missing_tracker_kind))

        {:error, {:unsupported_tracker_kind, kind}} ->
          Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

          record_dispatch_summary(
            state,
            candidate_fetch_failure_summary(:unsupported_tracker_kind)
          )

        {:error, {:invalid_workflow_config, message}} ->
          Logger.error("Invalid WORKFLOW.md config: #{message}")

          record_dispatch_summary(
            state,
            candidate_fetch_failure_summary(:invalid_workflow_config)
          )

        {:error, {:missing_workflow_file, path, reason}} ->
          Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
          record_dispatch_summary(state, candidate_fetch_failure_summary(:missing_workflow_file))

        {:error, :workflow_front_matter_not_a_map} ->
          Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")

          record_dispatch_summary(
            state,
            candidate_fetch_failure_summary(:workflow_front_matter_not_a_map)
          )

        {:error, {:workflow_parse_error, reason}} ->
          Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
          record_dispatch_summary(state, candidate_fetch_failure_summary(:workflow_parse_error))

        {:error, reason} ->
          Logger.error("Failed to fetch from Linear: #{inspect(reason)}")

          record_dispatch_summary(
            state,
            candidate_fetch_failure_summary(:tracker_candidate_fetch_failure)
          )
      end
    else
      record_dispatch_summary(state, empty_dispatch_summary("admission_closed"))
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
  @spec handle_retry_issue_for_test(term(), String.t(), pos_integer(), map()) ::
          {:noreply, term()}
  def handle_retry_issue_for_test(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and is_map(metadata) do
    handle_retry_issue(state, issue_id, attempt, metadata)
  end

  @doc false
  @spec classify_task_exit_for_test(term(), map(), String.t(), term()) :: term()
  def classify_task_exit_for_test(reason, running_entry, issue_id, %State{} = state)
      when is_map(running_entry) and is_binary(issue_id) do
    classify_task_exit(reason, running_entry, issue_id, state)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec dispatch_summary_for_test([Issue.t()], [term()]) :: map()
  def dispatch_summary_for_test(issues, dispatch_results)
      when is_list(issues) and is_list(dispatch_results) do
    result =
      issues
      |> Enum.zip(dispatch_results)
      |> Enum.reduce(%{skipped: [], dispatched: [], failed: [], attempted: 0}, fn {issue, dispatch_result}, acc ->
        record_dispatch_result(acc, issue, dispatch_result)
      end)

    dispatch_cycle_summary(
      issues,
      result.skipped,
      result.dispatched,
      result.failed,
      result.attempted
    )
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
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
        settle_or_terminate_non_active_issue(state, issue)
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
        updated_entry =
          running_entry
          |> Map.put(:issue, issue)
          |> Map.delete(:handoff_settlement_last_activity_at_ms)

        %{state | running: Map.put(state.running, issue.id, updated_entry)}

      _ ->
        state
    end
  end

  # An Implementer normally performs its own In Progress -> Agent Review
  # handoff before its provider turn has returned. The turn's terminal path
  # reads and validates the run-owned worker-event cursor, emits correlation
  # evidence, runs post-turn gates, and then stops the Herdr session. Killing
  # it on the first downstream-state observation races all of that evidence
  # while still allowing generic cleanup to look successful.
  #
  # The retention window is anchored on the turn's LAST OBSERVED ACTIVITY, not
  # on when the handoff was first seen (EMB-1307). Any fixed wall-clock bound
  # measured from the handoff eventually races a turn that is still legitimately
  # working: the production canary was force-cleaned ~44s after the route with
  # eight live owned PIDs and no correlation evidence. Every worker update
  # refreshes the anchor, so runtime activity keeps the already-running task
  # alive and only genuine silence expires it.
  #
  # Only the Implementer runtime opts into this grace through its narrow
  # ownership reference. Terminal states, reassignment, missing issues, and
  # every other runtime keep their existing immediate-stop semantics.
  defp settle_or_terminate_non_active_issue(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{owned_session_ref: %{handoff_settlement: :implementer_turn}} = running_entry ->
        settle_or_expire_implementer_handoff(state, issue, running_entry)

      _running_entry ->
        Logger.info(
          "Issue moved to non-active state: #{issue_context(issue)} " <>
            "state=#{issue.state}; stopping active agent"
        )

        terminate_running_issue(state, issue.id, false, issue)
    end
  end

  defp settle_or_expire_implementer_handoff(state, issue, running_entry) do
    now_ms = System.monotonic_time(:millisecond)

    last_activity_at_ms =
      nondecreasing_activity_ms(
        Map.get(running_entry, :handoff_settlement_last_activity_at_ms),
        current_run_activity_ms(running_entry)
      )

    grace_ms = implementer_handoff_settlement_grace_ms()

    cond do
      is_nil(last_activity_at_ms) ->
        Logger.info(
          "Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; " <>
            "allowing bounded Implementer handoff settlement inactivity_grace_ms=#{grace_ms}"
        )

        retain_implementer_handoff(state, issue, running_entry, now_ms)

      is_integer(last_activity_at_ms) and now_ms - last_activity_at_ms < grace_ms ->
        retain_implementer_handoff(state, issue, running_entry, last_activity_at_ms)

      true ->
        Logger.warning(
          "Implementer handoff settlement grace expired: #{issue_context(issue)} " <>
            "state=#{issue.state} inactivity_grace_ms=#{grace_ms} " <>
            "inactive_ms=#{now_ms - last_activity_at_ms}; stopping active agent"
        )

        terminate_running_issue(state, issue.id, false, issue)
    end
  end

  defp retain_implementer_handoff(state, issue, running_entry, last_activity_at_ms) do
    updated_entry =
      running_entry
      |> Map.put(:issue, issue)
      |> Map.put(:handoff_settlement_last_activity_at_ms, last_activity_at_ms)

    %{state | running: Map.put(state.running, issue.id, updated_entry)}
  end

  defp implementer_handoff_settlement_grace_ms do
    case Application.get_env(:symphony_elixir, :implementer_handoff_settlement_grace_ms) do
      value when is_integer(value) and value > 0 ->
        value

      _other ->
        @default_implementer_handoff_settlement_inactivity_ms
    end
  end

  defp terminate_running_issue(
         %State{} = state,
         issue_id,
         cleanup_workspace,
         release_issue \\ nil
       ) do
    {state, _termination_outcome} =
      terminate_running_issue_with_result(state, issue_id, cleanup_workspace, release_issue)

    state
  end

  defp terminate_running_issue_with_result(
         %State{} = state,
         issue_id,
         cleanup_workspace,
         release_issue \\ nil
       ) do
    case Map.get(state.running, issue_id) do
      nil ->
        {release_issue_claim(state, issue_id, release_issue), :ok}

      %{pid: _pid, ref: _ref} = running_entry ->
        terminate_running_entry(state, issue_id, cleanup_workspace, running_entry)

      _ ->
        {release_issue_claim(state, issue_id, release_issue), :ok}
    end
  end

  defp terminate_running_entry(
         state,
         issue_id,
         cleanup_workspace,
         %{pid: pid, ref: ref} = running_entry
       ) do
    state = fence_routine_process_ownership(state, issue_id)
    state = record_session_completion_totals(state, running_entry)
    worker_host = Map.get(running_entry, :worker_host)
    issue_or_identifier = Map.get(running_entry, :issue) || Map.get(running_entry, :identifier)

    if cleanup_workspace do
      cleanup_issue_workspace(issue_or_identifier, worker_host)
    end

    if is_pid(pid) do
      terminate_task(pid)
    end

    {cleanup_result, cleanup_evidence} = cleanup_terminal_owned_runtime(running_entry)
    termination_reason = cleanup_task_exit_reason(:terminated, cleanup_result)
    log_terminal_cleanup_failure(issue_id, cleanup_result)

    termination_outcome =
      classify_forced_terminal_cleanup(cleanup_result, running_entry, issue_id, state)

    record_forced_process_completion(
      running_entry,
      termination_reason,
      termination_outcome,
      cleanup_evidence
    )

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    RoleTurnRecovery.clear_turn(issue_id)

    state =
      %{
        state
        | running: Map.delete(state.running, issue_id),
          claimed: MapSet.delete(state.claimed, issue_id),
          retry_attempts: Map.delete(state.retry_attempts, issue_id)
      }
      |> maybe_record_forced_cleanup_observation(issue_id, termination_outcome)

    {state, termination_outcome}
  end

  defp record_forced_process_completion(running_entry, termination_reason, :ok, cleanup_evidence) do
    record_process_completion(running_entry, termination_reason, cleanup_evidence)
  end

  defp record_forced_process_completion(
         running_entry,
         _termination_reason,
         {_classification, failure, failure_observation},
         cleanup_evidence
       ) do
    quarantine_forced_terminal_cleanup_failure(
      running_entry,
      failure,
      failure_observation,
      cleanup_evidence
    )
  end

  defp classify_forced_terminal_cleanup(:ok, _running_entry, _issue_id, _state), do: :ok

  defp classify_forced_terminal_cleanup(
         {:error, _cleanup_reason} = cleanup_result,
         running_entry,
         issue_id,
         state
       ) do
    case classify_task_exit(
           cleanup_task_exit_reason(:terminated, cleanup_result),
           running_entry,
           issue_id,
           state
         ) do
      {:retryable, failure, observation} -> {:retryable, failure, observation}
      {:irrecoverable, failure, observation} -> {:irrecoverable, failure, observation}
    end
  end

  defp quarantine_forced_terminal_cleanup_failure(
         %{issue: %Issue{} = issue} = running_entry,
         failure,
         failure_observation,
         cleanup_evidence
       ) do
    attrs = %{
      quarantine_reason: Map.fetch!(failure, :retry_reason),
      failure_observation: failure_observation,
      cleanup_evidence: cleanup_evidence,
      session_id: running_entry_session_id(running_entry)
    }

    case update_owned_state(issue, running_entry, "quarantined", attrs) do
      nil -> :quarantined
      _ownership -> :quarantined
    end
  end

  defp quarantine_forced_terminal_cleanup_failure(
         _running_entry,
         _failure,
         _failure_observation,
         _cleanup_evidence
       ),
       do: :quarantined

  defp maybe_record_forced_cleanup_observation(state, _issue_id, :ok), do: state

  defp maybe_record_forced_cleanup_observation(
         state,
         issue_id,
         {_classification, _failure, observation}
       ) do
    put_failure_observation(state, issue_id, observation)
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now_ms = System.monotonic_time(:millisecond)

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now_ms, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now_ms, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now_ms)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      maybe_notify_agent_failed(
        running_entry,
        "stalled for #{elapsed_ms}ms without codex activity"
      )

      next_attempt = next_retry_attempt_from_running(running_entry)

      {state, termination_outcome} =
        terminate_running_issue_with_result(state, issue_id, false)

      process_ownership = retry_process_ownership_status(running_entry)

      schedule_stalled_issue_after_termination(
        state,
        issue_id,
        running_entry,
        identifier,
        elapsed_ms,
        next_attempt,
        process_ownership,
        termination_outcome
      )
    else
      state
    end
  end

  defp schedule_stalled_issue_after_termination(
         state,
         issue_id,
         running_entry,
         identifier,
         elapsed_ms,
         next_attempt,
         process_ownership,
         :ok
       ) do
    retry_reason = "stalled for #{elapsed_ms}ms without codex activity"

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: identifier,
      error: retry_reason,
      issue: Map.get(running_entry, :issue),
      run_id: Map.get(running_entry, :run_id),
      retry_reason: retry_reason,
      lease_state: retry_lease_state_from_process_ownership(process_ownership),
      process_ownership: process_ownership
    })
  end

  defp schedule_stalled_issue_after_termination(
         state,
         issue_id,
         running_entry,
         identifier,
         _elapsed_ms,
         next_attempt,
         process_ownership,
         {:retryable, failure, failure_observation}
       ) do
    retry_reason = Map.fetch!(failure, :retry_reason)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: identifier,
      error: retry_reason,
      issue: Map.get(running_entry, :issue),
      run_id: Map.get(running_entry, :run_id),
      retry_reason: retry_reason,
      failure_observation: failure_observation,
      lease_state: "quarantined",
      process_ownership: process_ownership
    })
  end

  defp schedule_stalled_issue_after_termination(
         state,
         issue_id,
         running_entry,
         _identifier,
         _elapsed_ms,
         _next_attempt,
         _process_ownership,
         {:irrecoverable, failure, failure_observation}
       ) do
    state
    |> put_failure_observation(issue_id, failure_observation)
    |> block_irrecoverable_runtime_failure(issue_id, running_entry, failure)
  end

  defp stall_elapsed_ms(running_entry, now_ms) when is_integer(now_ms) do
    case current_run_activity_ms(running_entry) do
      activity_at_ms when is_integer(activity_at_ms) -> max(0, now_ms - activity_at_ms)
      _ -> legacy_stall_elapsed_ms(running_entry)
    end
  end

  defp legacy_stall_elapsed_ms(running_entry) do
    case Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at) do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(DateTime.utc_now(), timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp current_run_activity_ms(%{current_run: %CurrentRun{} = current_run}),
    do: CurrentRun.activity_ms(current_run)

  defp current_run_activity_ms(%{last_activity_at_ms: activity_at_ms})
       when is_integer(activity_at_ms),
       do: activity_at_ms

  defp current_run_activity_ms(%{started_at_ms: started_at_ms}) when is_integer(started_at_ms),
    do: started_at_ms

  defp current_run_activity_ms(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
        :ok
    end
  end

  defp terminate_task(_pid), do: :ok

  defp settle_cancelled_role_run(issue_id, running_entry, reason)
       when is_binary(issue_id) and is_map(running_entry) do
    with :ok <- terminate_registered_task(running_entry),
         {:ok, evidence} <- cancelled_terminal_cleanup(running_entry),
         {:ok, _ownership} <- release_cancelled_owned_state(running_entry, evidence) do
      Logger.info("Role-run cancellation cleanup verified issue_id=#{issue_id} owned_pids=[] live_after=0")
    else
      {:error, cleanup_reason} ->
        Logger.error(
          "Role-run cancellation cleanup failed issue_id=#{issue_id} " <>
            "stop_reason=#{inspect(reason)} cleanup_reason=#{inspect(cleanup_reason)}"
        )
    end
  end

  defp settle_cancelled_role_run(issue_id, _running_entry, reason) do
    Logger.error(
      "Role-run cancellation cleanup failed issue_id=#{inspect(issue_id)} " <>
        "stop_reason=#{inspect(reason)} cleanup_reason=:invalid_running_entry"
    )
  end

  defp cancelled_terminal_cleanup(running_entry) do
    case cleanup_terminal_owned_runtime(running_entry, true) do
      {:ok, %{live_after: 0} = evidence} ->
        {:ok, evidence}

      {:ok, evidence} ->
        {:error, {:owned_session_processes_remain, evidence}}

      {{:error, cleanup_reason}, _evidence} ->
        {:error, cleanup_reason}
    end
  end

  defp terminate_registered_task(%{pid: pid}) when is_pid(pid) do
    :ok = terminate_task(pid)

    if Process.alive?(pid),
      do: {:error, {:registered_task_still_live, pid}},
      else: :ok
  end

  defp terminate_registered_task(_running_entry), do: :ok

  # ---------------------------------------------------------------------------
  # Off-loop terminal settlement (EMB-1260)
  #
  # The expensive teardown/liveness/record-write work runs in a supervised task
  # so the GenServer mailbox stays serviceable (state snapshot + work admission).
  # The issue remains claimed while settling; classification, retry scheduling,
  # and notification — all of which need State — happen back on the loop when
  # the settlement result arrives, or on a bounded timeout that quarantines the
  # record typed via one cheap write.
  # ---------------------------------------------------------------------------
  defp dispatch_terminal_settlement(%State{} = state, issue_id, running_entry, reason) do
    token = make_ref()
    server = self()

    # The pre-teardown owned-PID snapshot is captured by the TASK, as its first
    # action, and reported back via {:settlement_snapshot, token, snapshot}: the
    # loop must not fork `ps` — that is the head-of-line blocking this whole
    # change exists to remove. `:snapshot` therefore starts nil and stays a
    # PRESENT key, so every reader sees a well-formed entry; if settlement times
    # out before the report lands, timed_out_settlement_evidence/1 degrades it to
    # typed-unavailable rather than inventing an observation (EMB-1259 66-F1).
    settlement_context = %{
      issue_id: issue_id,
      running_entry: running_entry,
      reason: reason,
      snapshot: nil,
      execution_generation: state.execution_generation,
      started_at_ms: System.monotonic_time(:millisecond)
    }

    task_pid =
      case start_settlement_task(
             issue_id,
             running_entry,
             reason,
             state.execution_generation,
             server,
             token
           ) do
        {:ok, pid} when is_pid(pid) -> pid
        {:ok, pid, _info} when is_pid(pid) -> pid
        _degenerate -> nil
      end

    if is_nil(task_pid) do
      # The task could not start; settle synchronously so the record never
      # stays silently active. This is the rare degenerate path.
      result = run_terminal_settlement(running_entry, reason, nil, state.execution_generation)
      finalize_terminal_settlement(state, token, result, settlement_context)
    else
      timeout_ms = terminal_settlement_timeout_ms()
      timer_ref = Process.send_after(server, {:settlement_timeout, token}, timeout_ms)

      settlement = Map.merge(settlement_context, %{task_pid: task_pid, timer_ref: timer_ref})
      %{state | settlements: Map.put(state.settlements, token, settlement)}
    end
  end

  # Task.Supervisor.start_child/2 returns DynamicSupervisor.on_start_child():
  # {:ok, pid} | {:ok, pid, info} | :ignore | {:error, reason}. It also EXITS
  # :noproc when SymphonyElixir.TaskSupervisor is not running (shutdown race).
  # Every one of those must be survivable on the Orchestrator loop: an
  # unmatched shape or a propagated exit would crash the GenServer and lose the
  # settlement outright. Non-started outcomes are returned to the caller, which
  # routes them into the synchronous fallback.
  defp start_settlement_task(
         issue_id,
         running_entry,
         reason,
         execution_generation,
         server,
         token
       ) do
    outcome =
      try do
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          # FIRST action, before any teardown: the pre-teardown evidence the
          # timeout path preserves. Threaded into the settlement so the same
          # run never reads the process table twice.
          snapshot = capture_settlement_snapshot(running_entry)
          send(server, {:settlement_snapshot, token, snapshot})

          result =
            run_terminal_settlement(
              running_entry,
              reason,
              snapshot,
              execution_generation
            )

          send(server, {:settlement_result, token, result})
        end)
      catch
        kind, caught -> {:error, {kind, caught}}
      end

    case outcome do
      {:ok, pid} when is_pid(pid) ->
        outcome

      {:ok, pid, _info} when is_pid(pid) ->
        outcome

      degenerate ->
        Logger.error(
          "Terminal settlement task could not start issue_id=#{issue_id} " <>
            "session_id=#{running_entry_session_id(running_entry)} " <>
            "reason=#{inspect(degenerate)}; settling synchronously on the orchestrator loop"
        )

        degenerate
    end
  end

  defp store_settlement_snapshot(%State{} = state, token, snapshot) do
    case Map.fetch(state.settlements, token) do
      {:ok, settlement} ->
        settlement = Map.put(settlement, :snapshot, snapshot)
        %{state | settlements: Map.put(state.settlements, token, settlement)}

      :error ->
        # Unknown or already-settled token: the deadline popped this entry and
        # already settled it typed. Re-creating it here would strand a
        # settlement that nothing will ever finalize.
        state
    end
  end

  # The OS-heavy half that needs no State: physical teardown, liveness against
  # the pre-teardown snapshot, and the terminal ownership record write.
  defp run_terminal_settlement(running_entry, reason, snapshot, execution_generation) do
    {cleanup_result, cleanup_evidence} =
      cleanup_terminal_owned_runtime(running_entry, false, snapshot)

    {adjusted_reason, completion_attrs} =
      reason
      |> cleanup_task_exit_reason(cleanup_result)
      |> preserve_failed_retry_completion(running_entry, execution_generation)

    process_completion_status =
      record_process_completion(
        running_entry,
        adjusted_reason,
        cleanup_evidence,
        completion_attrs
      )

    ownership = ProcessOwnership.status_for_issue(Map.get(running_entry, :issue))

    %{
      cleanup_result: cleanup_result,
      cleanup_evidence: cleanup_evidence,
      adjusted_reason: adjusted_reason,
      process_completion_status: process_completion_status,
      process_ownership: ownership
    }
  end

  defp preserve_failed_retry_completion(:normal, running_entry, execution_generation) do
    observation = get_in(running_entry, [:process_ownership, :failure_observation])

    context =
      runtime_failure_context(
        running_entry_issue_id(running_entry),
        running_entry,
        execution_generation
      )

    case AgentRuntime.retried_completion_failure(observation, context) do
      {:block, failure} -> {{:irrecoverable_runtime_failed, failure}, %{}}
      :clear -> {:normal, %{failure_observation: :clear}}
      :none -> {:normal, %{}}
    end
  end

  defp preserve_failed_retry_completion(reason, _running_entry, _execution_generation),
    do: {reason, %{}}

  defp running_entry_issue_id(%{issue: %Issue{id: issue_id}}), do: issue_id
  defp running_entry_issue_id(_running_entry), do: nil

  defp finalize_terminal_settlement(%State{} = state, token, result) do
    case Map.pop(state.settlements, token) do
      {nil, _settlements} ->
        # Already timed out (or unknown token); the timeout path settled it.
        state

      {settlement, settlements} ->
        cancel_settlement_timer(settlement)

        finalize_terminal_settlement(
          %{state | settlements: settlements},
          token,
          result,
          settlement
        )
    end
  end

  defp finalize_terminal_settlement(%State{} = state, _token, result, settlement) do
    issue_id = settlement.issue_id
    running_entry = settlement.running_entry
    reason = result.adjusted_reason
    session_id = running_entry_session_id(running_entry)

    log_terminal_cleanup_failure(issue_id, result.cleanup_result)

    state =
      case classify_task_exit(reason, running_entry, issue_id, state) do
        :normal ->
          Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

          RoleTurnRecovery.clear_turn(issue_id)

          state
          |> clear_failure_observation(issue_id)
          |> complete_issue(issue_id)
          |> schedule_issue_retry(issue_id, 1, %{
            identifier: running_entry.identifier,
            delay_type: :continuation,
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            issue: Map.get(running_entry, :issue),
            run_id: Map.get(running_entry, :run_id),
            process_ownership: result.process_ownership,
            session_id: session_id,
            attempt: Map.get(running_entry, :retry_attempt) || 1,
            started_at: Map.get(running_entry, :started_at),
            retry_reason: "active-state-continuation-check",
            lease_state: retry_lease_state(result.process_completion_status)
          })

        {:irrecoverable, failure, failure_observation} ->
          RoleTurnRecovery.clear_turn(issue_id)

          state
          |> put_failure_observation(issue_id, failure_observation)
          |> block_irrecoverable_runtime_failure(issue_id, running_entry, failure)

        {:retryable, failure, failure_observation} ->
          exit_reason = retryable_task_exit_reason(reason, failure)

          Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{exit_reason}; scheduling retry")

          maybe_notify_agent_failed(running_entry, reason)

          next_attempt = next_retry_attempt_from_running(running_entry)

          state
          |> put_failure_observation(issue_id, failure_observation)
          |> schedule_issue_retry(issue_id, next_attempt, %{
            identifier: running_entry.identifier,
            error: "agent exited: #{exit_reason}",
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            issue: Map.get(running_entry, :issue),
            run_id: Map.get(running_entry, :run_id),
            process_ownership: result.process_ownership,
            session_id: session_id,
            attempt: Map.get(running_entry, :retry_attempt) || 1,
            started_at: Map.get(running_entry, :started_at),
            retry_reason: "agent exited: #{exit_reason}",
            failure_observation: failure_observation,
            lease_state: retry_lease_state(result.process_completion_status)
          })
      end

    Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{task_exit_reason_for_log(reason)}")

    notify_dashboard()
    state
  end

  defp time_out_terminal_settlement(%State{} = state, token) do
    case Map.pop(state.settlements, token) do
      {nil, _settlements} ->
        state

      {settlement, settlements} ->
        state = %{state | settlements: settlements}
        issue_id = settlement.issue_id
        running_entry = settlement.running_entry
        elapsed_ms = System.monotonic_time(:millisecond) - settlement.started_at_ms

        kill_settlement_task(settlement)

        # The settlement task may have landed its terminal record write in the
        # microseconds before this deadline message reached the mailbox head. The
        # quarantine write below verifies IDENTITY, not state, so without this
        # one cheap read it would overwrite a completed settlement's real outcome
        # with a fabricated timeout failure.
        case settled_settlement_record(running_entry) do
          {:settled, record_state} ->
            settle_late_terminal_settlement(
              state,
              issue_id,
              running_entry,
              record_state,
              elapsed_ms
            )

          :unsettled ->
            quarantine_timed_out_settlement(
              state,
              issue_id,
              running_entry,
              settlement,
              elapsed_ms
            )
        end
    end
  end

  # The record is still active/retrying at the deadline: settle it typed.
  defp quarantine_timed_out_settlement(
         %State{} = state,
         issue_id,
         running_entry,
         settlement,
         elapsed_ms
       ) do
    Logger.error(
      "Terminal settlement timed out issue_id=#{issue_id} " <>
        "session_id=#{running_entry_session_id(running_entry)} elapsed_ms=#{elapsed_ms}; " <>
        "quarantining ownership record typed and scheduling retry"
    )

    quarantine_reason = "terminal_settlement_timed_out elapsed_ms=#{elapsed_ms}"

    # ONE cheap write, no scans: quarantine the record typed using the held
    # ownership identity so it leaves active instead of hanging forever. The
    # pre-teardown snapshot captured on dispatch is preserved as unverified
    # cleanup_evidence (settlement never got to confirm liveness).
    _ =
      update_owned_state(
        Map.get(running_entry, :issue),
        running_entry,
        "quarantined",
        %{
          quarantine_reason: quarantine_reason,
          session_id: running_entry_session_id(running_entry),
          cleanup_evidence: timed_out_settlement_evidence(settlement)
        }
      )

    finalize_settlement_deadline(
      state,
      issue_id,
      running_entry,
      {:terminal_settlement_timed_out, quarantine_reason},
      "quarantined"
    )
  end

  # The settlement task already wrote its terminal outcome — the record LEFT
  # active on its own observed evidence. A completed settlement is never
  # replaced by a fabricated failure: skip the quarantine write entirely and
  # finalize the issue lifecycle on a plain retry lease whose error says the
  # settlement landed late. (The task is killed either way; its
  # {:settlement_result, ...} may still race the kill and arrive afterwards,
  # where finalize_terminal_settlement/3 no-ops on the now-unknown token.)
  defp settle_late_terminal_settlement(
         %State{} = state,
         issue_id,
         running_entry,
         record_state,
         elapsed_ms
       ) do
    Logger.warning(
      "Terminal settlement completed at its deadline issue_id=#{issue_id} " <>
        "session_id=#{running_entry_session_id(running_entry)} elapsed_ms=#{elapsed_ms} " <>
        "record_state=#{record_state}; keeping the settled record and scheduling retry"
    )

    late_reason =
      "terminal_settlement_completed_late elapsed_ms=#{elapsed_ms} record_state=#{record_state}"

    finalize_settlement_deadline(
      state,
      issue_id,
      running_entry,
      {:terminal_settlement_completed_late, late_reason},
      "retrying"
    )
  end

  # Reads the CURRENT state of the record this settlement owns through the held
  # ownership identity: one exact-scope read, no process scans. A read that
  # cannot confirm a settled record fails closed to :unsettled, keeping the
  # existing typed-quarantine behaviour.
  defp settled_settlement_record(running_entry) when is_map(running_entry) do
    with %Issue{} = issue <- Map.get(running_entry, :issue),
         ownership when is_map(ownership) <- Map.get(running_entry, :process_ownership),
         {:ok, %{state: record_state}} when record_state in @settled_ownership_states <-
           ProcessOwnership.verify(issue, ownership_identity(ownership)) do
      {:settled, record_state}
    else
      _ -> :unsettled
    end
  end

  defp settled_settlement_record(_running_entry), do: :unsettled

  # A settlement that reached its deadline is a typed retryable failure either
  # way: schedule a retry carrying the typed observation so the existing
  # fingerprint machinery sees an identical repeat rather than treating it as
  # fresh work. The lease reflects what the record actually shows — quarantined
  # for a genuinely unsettled record, a plain retry lease for one the settlement
  # already completed.
  defp finalize_settlement_deadline(
         %State{} = state,
         issue_id,
         running_entry,
         {_tag, reason_text} = typed_reason,
         lease_state
       ) do
    maybe_notify_agent_failed(running_entry, reason_text)
    RoleTurnRecovery.clear_turn(issue_id)

    reason = {:agent_runtime_failed, typed_reason}
    next_attempt = next_retry_attempt_from_running(running_entry)

    state =
      case classify_task_exit(reason, running_entry, issue_id, state) do
        {:irrecoverable, failure, failure_observation} ->
          state
          |> put_failure_observation(issue_id, failure_observation)
          |> block_irrecoverable_runtime_failure(issue_id, running_entry, failure)

        {:retryable, failure, failure_observation} ->
          state
          |> put_failure_observation(issue_id, failure_observation)
          |> schedule_issue_retry(issue_id, next_attempt, %{
            identifier: Map.get(running_entry, :identifier, issue_id),
            error: reason_text,
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            issue: Map.get(running_entry, :issue),
            run_id: Map.get(running_entry, :run_id),
            process_ownership: retry_process_ownership_status(running_entry),
            retry_reason: Map.fetch!(failure, :retry_reason),
            failure_observation: failure_observation,
            lease_state: lease_state
          })
      end

    notify_dashboard()
    state
  end

  # A timed-out settlement never confirmed liveness, so the evidence is the
  # captured owned-PID set marked unverified: live_after reflects the owned set
  # (we cannot claim they died), verified is false. No scans are performed here.
  # The on-loop capture is typed (EMB-1259 66-F1): a capture that failed its
  # machinery carries no observed pids and stays marked unavailable rather than
  # reading as an empty owned set.
  defp timed_out_settlement_evidence(%{snapshot: {:ok, %{owned_pids: owned_pids} = snapshot}}) do
    %{
      owned_pids: owned_pids,
      live_after: length(owned_pids),
      verified: false,
      captured_at: Map.get(snapshot, :captured_at),
      evidence_status: :captured
    }
  end

  defp timed_out_settlement_evidence(_settlement) do
    %{
      owned_pids: [],
      live_after: 0,
      verified: false,
      captured_at: nil,
      evidence_status: :unavailable
    }
  end

  defp cancel_settlement_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_settlement_timer(_settlement), do: :ok

  defp kill_settlement_task(%{task_pid: pid}) when is_pid(pid) do
    _ = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp kill_settlement_task(_settlement), do: :ok

  @doc """
  Resolves the terminal settlement deadline in milliseconds.

  Precedence is explicit app-env override > configured value > compiled
  default. The app-env entry is the existing TEST seam and keeps winning; the
  production surface is `agent_runtime.terminal_settlement_timeout_ms` in the
  workflow configuration (EMB-1260 67-SF4c). Configuration that cannot be read
  or carries no usable value falls back to the compiled default rather than
  raising: this runs on the settlement dispatch path, where a config problem
  must not take out the orchestrator.
  """
  @spec terminal_settlement_timeout_ms() :: pos_integer()
  def terminal_settlement_timeout_ms do
    case Application.get_env(:symphony_elixir, :terminal_settlement_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> configured_terminal_settlement_timeout_ms()
    end
  end

  defp configured_terminal_settlement_timeout_ms do
    case Config.settings!().agent_runtime.terminal_settlement_timeout_ms do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_terminal_settlement_timeout_ms
    end
  rescue
    _error -> @default_terminal_settlement_timeout_ms
  end

  # Marker-step failures stay typed: a mismatched or missing ownership
  # identity means settlement can neither signal nor write evidence for the
  # run it believes it owns — genuine inability, not the self-inflicted
  # post-teardown re-read EMB-1259 removed from the session step.
  defp cleanup_owned_marker_processes(%{issue: %Issue{} = issue, process_ownership: ownership})
       when is_map(ownership) do
    case ProcessOwnership.terminate_owned_processes(issue, ownership_identity(ownership)) do
      {:ok, %{live_after: 0}} -> :ok
      {:error, :enoent} -> {:error, :ownership_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_owned_marker_processes(_running_entry), do: {:error, :ownership_missing}

  # Terminal settlement self-produces its process evidence: the owned PID
  # set is captured BEFORE teardown destroys the records that identify it,
  # and liveness is verified against that snapshot AFTER teardown. The
  # settlement never re-derives its evidence from mutable global state a
  # completed teardown may already have removed (EMB-1259).
  #
  # Physical teardown runs on every path, including one whose capture
  # failed: evidence that cannot be produced is a typed settlement failure,
  # never a reason to skip the cleanup it is evidence for.
  #
  # `pre_captured` lets the terminal settlement pass the snapshot its task
  # already took before teardown, so one settlement reads the process table
  # once. Every other caller (including cancelled_terminal_cleanup/1) passes
  # nil and captures here exactly as before.
  defp cleanup_terminal_owned_runtime(
         running_entry,
         require_ownership \\ false,
         pre_captured \\ nil
       )
       when is_map(running_entry) do
    snapshot = pre_captured || capture_settlement_snapshot(running_entry)
    session_result = teardown_owned_session(running_entry)

    marker_result =
      if require_ownership or is_map(Map.get(running_entry, :process_ownership)) do
        cleanup_owned_marker_processes(running_entry)
      else
        :ok
      end

    cleanup_result = combine_terminal_cleanup_results(session_result, marker_result)
    {outcome, evidence, liveness} = settle_terminal_evidence(snapshot, cleanup_result)

    log_terminal_cleanup_evidence(running_entry, outcome, evidence, liveness)
    {outcome, evidence}
  end

  # Capture-machinery failure settles TYPED. A settlement that observed
  # nothing because its evidence machinery broke must never write the
  # `verified: true, owned_pids: [], live_after: 0` marker a physically
  # clean run writes — that marker would forge a cleanup verification the
  # settlement never performed.
  defp settle_terminal_evidence({:ok, snapshot}, cleanup_result) do
    case ProcessOwnership.settlement_liveness(snapshot) do
      {:ok, liveness} ->
        evidence = %{
          owned_pids: snapshot.owned_pids,
          live_after: liveness.live_after,
          verified: cleanup_result == :ok and liveness.live_after == 0,
          captured_at: snapshot.captured_at,
          evidence_status: :captured
        }

        {cleanup_result, evidence, liveness}

      {:error, reason} ->
        unavailable_settlement_evidence(
          cleanup_result,
          :liveness,
          reason,
          snapshot.owned_pids,
          snapshot.captured_at
        )
    end
  end

  defp settle_terminal_evidence({:error, reason}, cleanup_result) do
    unavailable_settlement_evidence(
      cleanup_result,
      :capture,
      reason,
      [],
      DateTime.utc_now() |> DateTime.to_iso8601()
    )
  end

  # Nothing was observed, so there is no survivor count to record. `live_after`
  # stays absent rather than carrying the `0` a dashboard or log query keyed on
  # that field alone would read as "0 survivors confirmed" — the same forged
  # reading `verified: true` was removed for.
  defp unavailable_settlement_evidence(cleanup_result, step, reason, owned_pids, captured_at) do
    evidence = %{
      owned_pids: owned_pids,
      live_after: nil,
      verified: false,
      captured_at: captured_at,
      evidence_status: :unavailable
    }

    {settlement_evidence_failure(cleanup_result, step, reason), evidence, %{live_after: nil, live_pids: []}}
  end

  defp settlement_evidence_failure(:ok, step, reason),
    do: {:error, {:settlement_evidence_unavailable, %{step: step, reason: reason}}}

  defp settlement_evidence_failure({:error, cleanup_reason}, step, reason),
    do: {:error, {:settlement_evidence_unavailable, %{step: step, reason: reason, cleanup: cleanup_reason}}}

  defp capture_settlement_snapshot(running_entry) when is_map(running_entry) do
    issue =
      case Map.get(running_entry, :issue) do
        %Issue{} = issue -> issue
        _ -> nil
      end

    extra_pids =
      [Map.get(running_entry, :codex_app_server_pid)]
      |> Enum.filter(&is_integer/1)

    ProcessOwnership.settlement_snapshot(
      issue,
      Map.get(running_entry, :process_ownership),
      extra_pids
    )
  end

  defp teardown_owned_session(%{owned_session_ref: ownership_ref}) when is_map(ownership_ref) do
    case AgentRuntime.cleanup_owned_session(ownership_ref) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to clean up run-owned runtime during terminal settlement: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp teardown_owned_session(_running_entry), do: :ok

  defp log_terminal_cleanup_evidence(
         running_entry,
         _outcome,
         %{evidence_status: :unavailable} = evidence,
         _liveness
       ) do
    Logger.error(
      "Run-owned runtime cleanup evidence unavailable " <>
        "issue_id=#{settlement_issue_id(running_entry)} " <>
        "session_name=#{settlement_session_name(running_entry)} " <>
        "captured_owned_pids=#{length(evidence.owned_pids)} " <>
        "cleanup_reason=settlement_evidence_unavailable"
    )
  end

  defp log_terminal_cleanup_evidence(running_entry, :ok, %{live_after: 0} = evidence, _liveness) do
    Logger.info(
      "Run-owned runtime cleanup verified " <>
        "issue_id=#{settlement_issue_id(running_entry)} " <>
        "session_name=#{settlement_session_name(running_entry)} " <>
        "captured_owned_pids=#{length(evidence.owned_pids)} " <>
        "owned_pids=[] live_after=0"
    )
  end

  defp log_terminal_cleanup_evidence(running_entry, _outcome, evidence, liveness) do
    Logger.warning(
      "Run-owned runtime cleanup unverified " <>
        "issue_id=#{settlement_issue_id(running_entry)} " <>
        "session_name=#{settlement_session_name(running_entry)} " <>
        "captured_owned_pids=#{length(evidence.owned_pids)} " <>
        "owned_pids=#{inspect(liveness.live_pids)} live_after=#{evidence.live_after}"
    )
  end

  defp settlement_issue_id(running_entry) do
    case Map.get(running_entry, :issue) do
      %Issue{id: issue_id} when is_binary(issue_id) -> issue_id
      _ -> Map.get(running_entry, :identifier, "unknown")
    end
  end

  defp settlement_session_name(running_entry) do
    case Map.get(running_entry, :owned_session_ref) do
      %{session_name: session_name} when is_binary(session_name) -> session_name
      _ -> "none"
    end
  end

  defp combine_terminal_cleanup_results(:ok, :ok), do: :ok

  defp combine_terminal_cleanup_results({:error, session_reason}, :ok),
    do: {:error, {:owned_session_cleanup_failed, session_reason}}

  defp combine_terminal_cleanup_results(:ok, {:error, marker_reason}),
    do: {:error, {:owned_process_cleanup_failed, marker_reason}}

  defp combine_terminal_cleanup_results(
         {:error, session_reason},
         {:error, marker_reason}
       ) do
    {:error, {:terminal_cleanup_failed, %{owned_session: session_reason, owned_processes: marker_reason}}}
  end

  defp log_terminal_cleanup_failure(_issue_id, :ok), do: :ok

  defp log_terminal_cleanup_failure(issue_id, {:error, reason}) do
    Logger.error("Role-run terminal cleanup failed issue_id=#{issue_id} cleanup_reason=#{inspect(reason)}")
  end

  defp release_cancelled_owned_state(%{issue: %Issue{} = issue} = running_entry, evidence) do
    case release_owned_state(issue, running_entry, %{cleanup_evidence: evidence}) do
      {:error, :enoent} -> {:error, :ownership_missing}
      result -> result
    end
  end

  defp release_cancelled_owned_state(_running_entry, _evidence), do: {:error, :ownership_missing}

  defp recover_stale_owned_sessions do
    case ProcessOwnership.recover_stale_owned_sessions(&AgentRuntime.cleanup_owned_session/1) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Recovered #{count} stale run-owned runtime session(s) from a previous role generation")

        :ok
    end
  end

  defp cleanup_task_exit_reason(reason, :ok), do: reason

  defp cleanup_task_exit_reason(
         _original_reason,
         {:error, {:owned_process_cleanup_failed, _cleanup_reason} = failure}
       ) do
    {:agent_runtime_failed, failure}
  end

  defp cleanup_task_exit_reason(
         _reason,
         {:error, {:terminal_cleanup_failed, _reasons} = failure}
       ) do
    {:agent_runtime_failed, failure}
  end

  defp cleanup_task_exit_reason(
         _reason,
         {:error, {:settlement_evidence_unavailable, _details} = failure}
       ) do
    {:agent_runtime_failed, failure}
  end

  defp cleanup_task_exit_reason(_reason, {:error, cleanup_reason}) do
    {:agent_runtime_failed, {:owned_session_cleanup_failed, cleanup_reason}}
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    sorted_issues = sort_issues_for_dispatch(issues)

    result =
      Enum.reduce(
        sorted_issues,
        %{state: state, skipped: [], dispatched: [], failed: [], attempted: 0},
        &choose_issue(&1, &2, active_states, terminal_states)
      )

    summary =
      sorted_issues
      |> dispatch_cycle_summary(
        result.skipped,
        result.dispatched,
        result.failed,
        result.attempted
      )

    record_dispatch_summary(result.state, summary)
  end

  defp choose_issue(issue, acc, active_states, terminal_states) do
    case dispatch_skip_summary(issue, acc.state, active_states, terminal_states) do
      nil ->
        attempt = if blocked_failure_reset_changed?(acc.state, issue), do: 1
        {next_state, dispatch_result} = dispatch_issue_with_result(acc.state, issue, attempt)

        acc
        |> Map.put(:state, next_state)
        |> record_dispatch_result(issue, dispatch_result)

      skip_summary ->
        Map.update!(acc, :skipped, &[skip_summary | &1])
    end
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

      true ->
        dispatch_capacity_skip_summary(issue, state, running, claimed)
    end
  end

  defp dispatch_skip_summary(_issue, _state, _active_states, _terminal_states),
    do: skipped_candidate_summary(nil, "not_candidate")

  defp dispatch_capacity_skip_summary(issue, state, running, claimed) do
    cond do
      MapSet.member?(claimed, issue.id) and
          !blocked_failure_reset_changed?(state, issue) ->
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

  defp dispatch_issue_with_result(%State{} = state, issue, attempt, preferred_worker_host \\ nil) do
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

        {state, :attempted}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {state, :attempted}

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

      worker_host when is_binary(worker_host) and worker_host != "" ->
        Logger.warning("Skipping dispatch; remote worker ownership is unsupported for #{issue_context(issue)} worker_host=#{worker_host}")

        {state, {:failed, "remote_worker_not_supported"}}

      worker_host ->
        run_id = dispatch_run_id(issue, attempt)

        ownership_attrs =
          dispatch_ownership_attrs(
            issue,
            run_id,
            worker_host,
            current_failure_reset_marker(state, issue),
            retry_predecessor_run_id(issue, attempt)
          )

        case ProcessOwnership.acquire(issue, ownership_attrs) do
          {:ok, process_ownership} ->
            spawn_issue_on_worker_host_with_result(
              state,
              issue,
              attempt,
              recipient,
              worker_host,
              process_ownership
            )

          {:error, reason} ->
            Logger.warning("Skipping dispatch; process ownership acquisition failed for #{issue_context(issue)}: #{inspect(reason)}")

            {state, {:failed, "process_ownership_acquire_failed"}}
        end
    end
  end

  defp spawn_issue_on_worker_host_with_result(
         %State{} = state,
         issue,
         attempt,
         recipient,
         worker_host,
         process_ownership
       ) do
    record_pending_turn_start(issue, worker_host)
    current_run = CurrentRun.new(issue, process_ownership)

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             role: ProcessOwnership.current_role(),
             execution_generation: state.execution_generation,
             run_id: process_ownership.run_id,
             process_ownership: process_ownership,
             current_run: current_run
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
            process_ownership: process_ownership,
            run_id: process_ownership.run_id,
            current_run: current_run,
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
            started_at: DateTime.utc_now(),
            started_at_ms: CurrentRun.activity_ms(current_run)
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id),
            blocked_failures: Map.delete(state.blocked_failures, issue.id)
        }
        |> then(&{&1, :dispatched})

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        _ = ProcessOwnership.release(issue, ownership_identity(process_ownership))
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

  defp revalidate_issue_for_dispatch(
         %Issue{id: issue_id},
         issue_fetcher,
         terminal_states,
         retry_dispatch?
       )
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) and
             process_ownership_allows_dispatch?(refreshed_issue, retry_dispatch?) do
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

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states, _retry_dispatch?),
    do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = retry_attempt_for(previous_retry, attempt)
    delay_ms = retry_delay(next_attempt, metadata)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    retry_context = retry_context(issue_id, previous_retry, metadata)

    cancel_retry_timer(previous_retry)

    retry_process_ownership =
      update_retry_process_ownership(issue_id, retry_context.issue, next_attempt, delay_ms, %{
        error: retry_context.error,
        worker_host: retry_context.worker_host,
        workspace_path: retry_context.workspace_path,
        run_id: retry_context.run_id,
        process_ownership: retry_context.process_ownership,
        retry_reason: metadata[:retry_reason] || retry_context.error,
        failure_observation: metadata[:failure_observation],
        recovery_reason: metadata[:recovery_reason],
        lease_state: metadata[:lease_state] || "retrying"
      })

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{retry_context.identifier} in #{delay_ms}ms (attempt #{next_attempt})#{retry_error_suffix(retry_context.error)}")

    RunLog.record_agent_retry_scheduled(
      issue_id,
      retry_context,
      retry_process_ownership,
      metadata,
      %{
        attempt: next_attempt,
        delay_ms: delay_ms,
        due_at_ms: due_at_ms,
        scheduled_for: DateTime.add(DateTime.utc_now(), delay_ms, :millisecond),
        lease_state: metadata[:lease_state] || "retrying"
      }
    )

    %{
      state
      | retry_attempts:
          Map.put(
            state.retry_attempts,
            issue_id,
            retry_entry(
              next_attempt,
              timer_ref,
              retry_token,
              due_at_ms,
              retry_context,
              retry_process_ownership
            )
          )
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
       when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          issue: Map.get(retry_entry, :issue),
          run_id: Map.get(retry_entry, :run_id),
          process_ownership: Map.get(retry_entry, :process_ownership),
          failure_observation: Map.get(retry_entry, :failure_observation),
          delay_type: Map.get(retry_entry, :delay_type)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  # A closed admission only holds a retry after its own timer has fired.  Other
  # queued retries keep their original timer and deadline while admission is
  # closed, so reopening cannot turn an unexpired backoff into immediate work.
  defp hold_fired_retry_attempt(%State{} = state, issue_id, retry_token)
       when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{retry_token: ^retry_token} = retry ->
        held_retry =
          retry
          |> Map.put(:timer_ref, nil)
          |> Map.put(:held_by_admission, true)

        %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, held_retry)}

      _ ->
        state
    end
  end

  defp hold_fired_retry_attempt(%State{} = state, _issue_id, _retry_token), do: state

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
    case equivalent_retry_blocker(state, issue, metadata) do
      {:block, failure, observation, durable_ownership} ->
        running_entry =
          metadata
          |> Map.put(:issue, issue)
          |> Map.put(:identifier, issue.identifier)
          |> Map.put(:process_ownership, durable_ownership)

        blocked_state =
          state
          |> put_failure_observation(issue.id, observation)
          |> block_irrecoverable_runtime_failure(issue.id, running_entry, failure)

        {:noreply, blocked_state}

      :allow ->
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
  end

  defp equivalent_retry_blocker(_state, %Issue{}, %{delay_type: :continuation}), do: :allow

  defp equivalent_retry_blocker(%State{} = state, %Issue{} = issue, metadata) do
    durable_ownership = ProcessOwnership.status_for_issue(issue)
    queued_observation = metadata[:failure_observation]

    durable_observation = get_in(durable_ownership || %{}, [:failure_observation])

    running_entry =
      metadata
      |> Map.put(:issue, issue)
      |> Map.put(
        :workspace_path,
        metadata[:workspace_path] || Map.get(durable_ownership || %{}, :workspace_path)
      )

    context = runtime_failure_context(issue.id, running_entry, state.execution_generation)

    case AgentRuntime.equivalent_redispatch_failure(
           queued_observation,
           durable_observation,
           context
         ) do
      {:block, failure} ->
        Logger.error(
          "Equivalent retry dispatch blocked for #{issue_context(issue)}; " <>
            "durable checkpoint and failure fingerprint are unchanged"
        )

        {:block, failure, durable_observation, durable_ownership}

      :allow ->
        :allow
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
         retry_reason:
           metadata[:retry_reason] || metadata[:error] ||
             "process ownership blocks retry dispatch",
         lease_state: lease_state,
         process_ownership: process_ownership
       })
     )}
  end

  defp classify_task_exit(:normal, _running_entry, _issue_id, _state), do: :normal

  defp classify_task_exit(reason, running_entry, issue_id, %State{} = state) do
    previous_observation =
      Map.get(state.failure_observations, issue_id) ||
        get_in(running_entry, [:process_ownership, :failure_observation])

    context = runtime_failure_context(issue_id, running_entry, state.execution_generation)

    {failure_observation, classification} =
      AgentRuntime.record_failure_observation(previous_observation, reason, context)

    case classification do
      {:irrecoverable, failure} -> {:irrecoverable, failure, failure_observation}
      {:retryable, failure} -> {:retryable, failure, failure_observation}
    end
  end

  defp runtime_failure_context(issue_id, running_entry, execution_generation) do
    issue = Map.get(running_entry, :issue)

    workspace_path =
      Map.get(running_entry, :workspace_path) ||
        get_in(running_entry, [:process_ownership, :workspace_path])

    %{
      issue_id: issue_id,
      execution_generation: execution_generation,
      workspace_path: workspace_path,
      role: ProcessOwnership.current_role(),
      provider: AgentRuntime.provider(),
      run_id: Map.get(running_entry, :run_id),
      process_ownership_run_id: Map.get(running_entry, :run_id),
      input_fingerprint: runtime_input_fingerprint(issue, workspace_path)
    }
  end

  defp current_failure_reset_marker(%State{} = state, %Issue{} = issue) do
    blocked_failure = Map.get(state.blocked_failures, issue.id, %{})

    running_entry = %{
      issue: issue,
      workspace_path: Map.get(blocked_failure, :workspace_path) || expected_workspace_path(issue),
      process_ownership: Map.get(blocked_failure, :process_ownership)
    }

    issue.id
    |> runtime_failure_context(running_entry, state.execution_generation)
    |> AgentRuntime.failure_reset_marker()
  end

  defp blocked_failure_reset_changed?(%State{} = state, %Issue{} = issue) do
    observation =
      Map.get(state.failure_observations, issue.id) ||
        get_in(state.blocked_failures, [issue.id, :process_ownership, :failure_observation])

    case observation do
      %{reset_marker: stored_marker} when is_map(stored_marker) ->
        stored_marker != current_failure_reset_marker(state, issue)

      _ ->
        false
    end
  end

  defp runtime_input_fingerprint(%Issue{} = issue, workspace_path) do
    [
      issue.id,
      issue.identifier,
      issue.title,
      issue.description,
      issue.branch_name,
      issue.labels
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(normalize_label(&1) == "human escalation"))
      |> Enum.sort(),
      workspace_path
    ]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp runtime_input_fingerprint(_issue, workspace_path) when is_binary(workspace_path) do
    :sha256
    |> :crypto.hash(workspace_path)
    |> Base.encode16(case: :lower)
  end

  defp runtime_input_fingerprint(_issue, _workspace_path), do: nil

  defp put_failure_observation(%State{} = state, issue_id, observation)
       when is_binary(issue_id) and is_map(observation) do
    %{state | failure_observations: Map.put(state.failure_observations, issue_id, observation)}
  end

  defp clear_failure_observation(%State{} = state, issue_id) when is_binary(issue_id) do
    %{
      state
      | failure_observations: Map.delete(state.failure_observations, issue_id),
        blocked_failures: Map.delete(state.blocked_failures, issue_id)
    }
  end

  defp block_irrecoverable_runtime_failure(%State{} = state, issue_id, running_entry, failure) do
    summary = Map.fetch!(failure, :retry_reason)
    identifier = Map.get(running_entry, :identifier, issue_id)
    issue = Map.get(running_entry, :issue)

    failure_observation =
      Map.get(state.failure_observations, issue_id) ||
        get_in(running_entry, [:process_ownership, :failure_observation])

    blocked_ownership =
      update_irrecoverable_blocked_ownership(
        issue,
        running_entry,
        failure,
        failure_observation
      )

    RunLog.record_irrecoverable_runtime_failure(
      issue_id,
      running_entry,
      blocked_ownership,
      failure
    )

    maybe_escalate_irrecoverable_runtime_failure(issue_id, issue, failure)

    Logger.error("Irrecoverable runtime failure for issue_id=#{issue_id} issue_identifier=#{identifier}; blocked ordinary retry family=#{failure.family} summary=#{summary}")

    if failure.family == :provider_authentication_or_revocation do
      Logger.error("Provider authentication failed for issue_id=#{issue_id} issue_identifier=#{identifier}; blocked ordinary retry")
    end

    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        blocked_failures:
          Map.put(
            state.blocked_failures,
            issue_id,
            blocked_failure_entry(issue_id, running_entry, failure, blocked_ownership)
          )
    }
  end

  defp update_irrecoverable_blocked_ownership(
         %Issue{} = issue,
         running_entry,
         failure,
         failure_observation
       ) do
    update_owned_state(issue, running_entry, "blocked", %{
      quarantine_reason: Map.fetch!(failure, :retry_reason),
      session_id: running_entry_session_id(running_entry),
      failure_observation: failure_observation
    })
  end

  defp maybe_escalate_irrecoverable_runtime_failure(issue_id, %Issue{} = issue, _failure)
       when is_binary(issue_id) do
    label_result = Tracker.add_issue_label(issue_id, "Human Escalation")
    state_result = Tracker.update_issue_state(issue_id, "Human Escalation")

    log_irrecoverable_escalation_result(:label, label_result, issue)
    log_irrecoverable_escalation_result(:state, state_result, issue)

    if label_result == :ok do
      issue
      |> human_escalated_issue()
      |> Telegram.notify_human_escalation()
    end

    :ok
  end

  defp log_irrecoverable_escalation_result(_kind, :ok, _issue), do: :ok

  defp log_irrecoverable_escalation_result(kind, {:error, reason}, %Issue{} = issue) do
    Logger.warning("Failed irrecoverable Human Escalation #{kind} update for #{issue_context(issue)}: #{inspect(reason)}")
  end

  defp human_escalated_issue(%Issue{} = issue) do
    labels =
      issue.labels
      |> List.wrap()
      |> Kernel.++(["Human Escalation"])
      |> Enum.uniq_by(&normalize_label/1)

    %{issue | state: "Human Escalation", labels: labels}
  end

  defp blocked_failure_entry(issue_id, running_entry, failure, blocked_ownership) do
    %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      process_ownership: blocked_ownership || Map.get(running_entry, :process_ownership),
      family: Map.get(failure, :family),
      provider: Map.get(failure, :provider),
      subtype: Map.get(failure, :subtype),
      summary: Map.get(failure, :summary),
      error: Map.get(failure, :retry_reason),
      recovery_reason: Map.get(failure, :recovery_reason),
      started_at: Map.get(running_entry, :started_at),
      blocked_at: DateTime.utc_now()
    }
  end

  defp task_exit_reason_for_log({:provider_auth_failed, _details} = reason) do
    AgentRuntime.provider_auth_failure_summary(reason)
  end

  defp task_exit_reason_for_log(:normal), do: ":normal"

  defp task_exit_reason_for_log(reason) do
    case AgentRuntime.classify_failure(reason, %{}) do
      {:irrecoverable, failure} -> Map.get(failure, :retry_reason)
      {:retryable, failure} -> Map.get(failure, :retry_reason)
    end
  end

  defp retryable_task_exit_reason(reason, failure) when is_map(failure) do
    retry_reason = Map.get(failure, :retry_reason)

    cond do
      no_progress_retry_reason?(retry_reason) ->
        retry_reason

      safe_compact_reason?(reason) ->
        inspect(reason)

      is_binary(retry_reason) and retry_reason != "" ->
        retry_reason

      true ->
        "retryable_runtime_failure"
    end
  end

  defp safe_compact_reason?(reason) when is_atom(reason), do: true
  defp safe_compact_reason?(_reason), do: false

  defp no_progress_retry_reason?(retry_reason) when is_binary(retry_reason) do
    String.contains?(retry_reason, "empty_turn_completed") or
      String.contains?(retry_reason, "turn_input_required") or
      String.contains?(retry_reason, "approval_required")
  end

  defp no_progress_retry_reason?(_retry_reason), do: false

  defp reconcile_orphaned_claims(%State{} = state) do
    active_claims =
      state.running
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Map.keys(state.retry_attempts)))
      |> MapSet.union(MapSet.new(Map.keys(state.blocked_failures)))
      |> MapSet.union(settling_issue_ids(state))

    state.claimed
    |> MapSet.difference(active_claims)
    |> Enum.reduce(state, fn issue_id, state_acc ->
      Logger.warning("Claimed issue is neither running, retrying nor settling; releasing leaked claim issue_id=#{issue_id}")

      release_issue_claim(state_acc, issue_id)
    end)
  end

  # An issue whose terminal settlement is in flight has been popped out of
  # `state.running` but is emphatically NOT free: its predecessor run is still
  # tearing down. Reading claims from running ∪ retry_attempts alone made such
  # an issue look orphaned, released its claim, and made it re-dispatchable
  # mid-teardown — the canary contract's "no equivalent redispatch" violated.
  #
  # Settlement contexts are read defensively: a context without a usable issue
  # id contributes nothing rather than crashing the reconciliation pass that
  # every poll cycle depends on. Nothing here reads `:snapshot`, which is
  # populated asynchronously and may still be nil.
  defp settling_issue_ids(%State{} = state) do
    state.settlements
    |> Map.values()
    |> Enum.flat_map(fn
      %{issue_id: issue_id} when is_binary(issue_id) -> [issue_id]
      _settlement -> []
    end)
    |> MapSet.new()
  end

  defp release_issue_claim(%State{} = state, issue_id, issue \\ nil) do
    maybe_release_process_ownership(issue)
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata)
       when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
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
      run_id: pick_retry_run_id(previous_retry, metadata),
      process_ownership: pick_retry_process_ownership(previous_retry, metadata),
      failure_observation: metadata[:failure_observation],
      delay_type: metadata[:delay_type]
    }
  end

  defp cancel_retry_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_retry_timer(_previous_retry), do: :ok

  defp retry_error_suffix(error) when is_binary(error), do: " error=#{error}"
  defp retry_error_suffix(_error), do: ""

  defp retry_entry(
         next_attempt,
         timer_ref,
         retry_token,
         due_at_ms,
         retry_context,
         process_ownership
       ) do
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
      run_id: retry_context.run_id || (process_ownership && process_ownership.run_id),
      process_ownership: process_ownership || retry_context.process_ownership,
      failure_observation: retry_context.failure_observation,
      delay_type: retry_context.delay_type
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

  defp pick_retry_run_id(previous_retry, metadata) do
    metadata[:run_id] || Map.get(previous_retry, :run_id)
  end

  defp pick_retry_process_ownership(previous_retry, metadata) do
    metadata[:process_ownership] || Map.get(previous_retry, :process_ownership)
  end

  defp update_retry_process_ownership(_issue_id, nil, _attempt, _delay_ms, _metadata), do: nil

  defp update_retry_process_ownership(_issue_id, %Issue{} = issue, _attempt, _delay_ms, metadata) do
    state = metadata[:lease_state] || "retrying"

    attrs = %{
      workspace_path: metadata[:workspace_path],
      failure_observation: metadata[:failure_observation]
    }

    attrs =
      if state == "quarantined",
        do: attrs,
        else: Map.put(attrs, :quarantine_reason, metadata[:retry_reason] || metadata[:error])

    update_owned_state(issue, metadata, state, attrs)
  end

  # Routine active-state refreshes run outside the serial Orchestrator path.
  # One exact-run writer per issue is in flight; additional updates only mark
  # one follow-up snapshot dirty. Terminal paths retire the producer and fence
  # this task before settlement can write a terminal ownership state.
  defp schedule_routine_process_ownership(%State{} = state, issue_id) when is_binary(issue_id) do
    case {Map.get(state.running, issue_id), Map.get(state.routine_persistence, issue_id)} do
      {%{run_id: run_id}, %{run_id: run_id} = routine} ->
        put_in(state.routine_persistence[issue_id], %{routine | dirty?: true})

      {%{run_id: _run_id} = running_entry, nil} ->
        start_routine_process_ownership(state, issue_id, running_entry)

      _ ->
        state
    end
  end

  defp start_routine_process_ownership(%State{} = state, issue_id, running_entry) do
    issue = Map.get(running_entry, :issue)
    ownership = Map.get(running_entry, :process_ownership)
    run_id = Map.get(running_entry, :run_id)
    attrs = Map.put(process_ownership_attrs(running_entry), :state, "active")

    outcome =
      try do
        Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
          case {issue, ownership} do
            {%Issue{} = owned_issue, %{holder: _holder}} ->
              ProcessOwnership.refresh_active(
                owned_issue,
                ownership_identity(ownership),
                attrs
              )

            _ ->
              {:error, :ownership_missing}
          end
        end)
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case outcome do
      %Task{pid: task_pid, ref: task_ref} ->
        routine = %{
          task_pid: task_pid,
          token: task_ref,
          run_id: run_id,
          dirty?: false
        }

        %{state | routine_persistence: Map.put(state.routine_persistence, issue_id, routine)}

      failure ->
        Logger.warning("Failed to start routine process ownership refresh for issue_id=#{issue_id}: #{inspect(failure)}")

        state
    end
  end

  defp finish_routine_process_ownership(state, issue_id, token, run_id, result) do
    case Map.get(state.routine_persistence, issue_id) do
      %{token: ^token, run_id: ^run_id} = routine ->
        _ = Process.demonitor(routine.token, [:flush])
        state = %{state | routine_persistence: Map.delete(state.routine_persistence, issue_id)}
        state = apply_routine_process_ownership_result(state, issue_id, run_id, result)

        case {routine.dirty?, Map.get(state.running, issue_id)} do
          {true, %{run_id: ^run_id} = running_entry} ->
            start_routine_process_ownership(state, issue_id, running_entry)

          _ ->
            state
        end

      _stale_or_fenced ->
        state
    end
  end

  defp finish_routine_process_ownership_exit(state, ref, reason) when is_reference(ref) do
    case Enum.find(state.routine_persistence, fn {_issue_id, routine} ->
           Map.get(routine, :token) == ref
         end) do
      {issue_id, %{run_id: run_id} = routine} ->
        Logger.warning("Routine process ownership refresh exited for issue_id=#{issue_id} run_id=#{run_id}: #{inspect(reason)}")

        state = %{state | routine_persistence: Map.delete(state.routine_persistence, issue_id)}

        state =
          apply_routine_process_ownership_result(
            state,
            issue_id,
            run_id,
            {:error, {:task_exit, reason}}
          )

        case {routine.dirty?, Map.get(state.running, issue_id)} do
          {true, %{run_id: ^run_id} = running_entry} ->
            start_routine_process_ownership(state, issue_id, running_entry)

          _ ->
            state
        end

      nil ->
        state
    end
  end

  defp apply_routine_process_ownership_result(
         state,
         issue_id,
         run_id,
         {:ok, process_ownership}
       ) do
    case Map.get(state.running, issue_id) do
      %{run_id: ^run_id} = running_entry ->
        updated =
          running_entry
          |> Map.put(:process_ownership, process_ownership)
          |> Map.put(:process_ownership_refreshed_at_ms, System.monotonic_time(:millisecond))

        %{state | running: Map.put(state.running, issue_id, updated)}

      _ ->
        state
    end
  end

  defp apply_routine_process_ownership_result(state, issue_id, run_id, {:error, reason}) do
    Logger.warning("Failed routine process ownership refresh for issue_id=#{issue_id} run_id=#{run_id}: #{inspect(reason)}")

    state
  end

  defp apply_routine_process_ownership_result(state, _issue_id, _run_id, _result), do: state

  defp fence_routine_process_ownership(%State{} = state, issue_id) do
    state.running
    |> Map.get(issue_id)
    |> retire_current_run()

    case Map.get(state.routine_persistence, issue_id) do
      %{task_pid: task_pid, token: token} when is_pid(task_pid) and is_reference(token) ->
        Process.exit(task_pid, :shutdown)

        receive do
          {:DOWN, ^token, :process, ^task_pid, _reason} -> :ok
        end

      _ ->
        :ok
    end

    %{state | routine_persistence: Map.delete(state.routine_persistence, issue_id)}
  end

  defp retire_current_run(%{current_run: %CurrentRun{} = current_run}),
    do: CurrentRun.retire(current_run)

  defp retire_current_run(_running_entry), do: :ok

  defp current_run_matches?(%{current_run: %CurrentRun{} = current_run}, envelope),
    do: CurrentRun.matches?(current_run, envelope)

  defp current_run_matches?(_running_entry, _envelope), do: false

  defp maybe_release_process_ownership(%Issue{} = issue) do
    case ProcessOwnership.status_for_issue(issue) do
      %{holder: _holder} = ownership -> release_current_ownership(issue, ownership)
      _ -> :ok
    end
  end

  defp maybe_release_process_ownership(_issue), do: :ok

  defp release_current_ownership(issue, ownership) do
    if ownership.holder == ProcessOwnership.holder_id() do
      case ProcessOwnership.release(issue, ownership_identity(ownership)) do
        {:ok, _released} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to release process ownership for #{issue_context(issue)}: #{inspect(reason)}")
      end
    else
      :ok
    end
  end

  defp update_owned_state(%Issue{} = issue, context, state, attrs)
       when is_map(context) and is_binary(state) and is_map(attrs) do
    ownership = Map.get(context, :process_ownership) || ProcessOwnership.status_for_issue(issue)

    case ownership do
      %{holder: _holder} -> update_current_ownership(issue, ownership, state, attrs)
      _ -> nil
    end
  end

  defp update_owned_state(_issue, _context, _state, _attrs), do: nil

  defp update_current_ownership(issue, ownership, state, attrs) do
    if ownership.holder == ProcessOwnership.holder_id() do
      updates =
        attrs
        |> Map.put(:state, state)
        |> Map.put_new(:workspace_path, Map.get(ownership, :workspace_path))

      verify_ownership_update(issue, ownership, updates)
    end
  end

  defp verify_ownership_update(issue, ownership, updates) do
    case ProcessOwnership.verify_and_update(issue, ownership_identity(ownership), updates) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning("Failed to update process ownership for #{issue_context(issue)}: #{inspect(reason)}")

        nil
    end
  end

  defp process_ownership_allows_dispatch?(%Issue{}, _retry_dispatch?), do: true

  defp dispatch_run_id(%Issue{} = issue, _attempt), do: new_run_id(issue)

  defp retry_predecessor_run_id(%Issue{} = issue, attempt) when is_integer(attempt) do
    case ProcessOwnership.status_for_issue(issue) do
      %{state: state, holder: holder, run_id: run_id}
      when state in ["retrying", "quarantined"] and is_binary(run_id) ->
        if holder == ProcessOwnership.holder_id(), do: run_id

      _ ->
        nil
    end
  end

  defp retry_predecessor_run_id(%Issue{}, _attempt), do: nil

  defp dispatch_ownership_attrs(
         %Issue{} = issue,
         run_id,
         worker_host,
         reset_marker,
         replaces_run_id
       ) do
    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      role: ProcessOwnership.current_role(),
      run_id: run_id,
      holder: ProcessOwnership.holder_id(),
      worker_host: worker_host,
      workspace_path: expected_workspace_path(issue),
      reset_marker: reset_marker,
      replaces_run_id: replaces_run_id
    }
  end

  defp ownership_identity(ownership) when is_map(ownership) do
    %{
      role: Map.get(ownership, :role),
      run_id: Map.get(ownership, :run_id),
      holder: Map.get(ownership, :holder),
      workspace_path: Map.get(ownership, :workspace_path)
    }
  end

  defp expected_workspace_path(%Issue{} = issue) do
    case issue.identifier || issue.id do
      identifier when is_binary(identifier) and identifier != "" ->
        Path.join(
          Config.settings!().workspace.root,
          workspace_basename(identifier, issue.repository)
        )

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

  defp safe_workspace_name(value) when is_binary(value),
    do: String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")

  defp safe_workspace_name(_value), do: nil

  defp record_process_ownership(%{issue: %Issue{} = issue} = running_entry, _issue_id) do
    case update_owned_state(
           issue,
           running_entry,
           "active",
           process_ownership_attrs(running_entry)
         ) do
      nil -> running_entry
      process_ownership -> Map.put(running_entry, :process_ownership, process_ownership)
    end
  end

  defp record_process_ownership(running_entry, _issue_id), do: running_entry

  defp record_process_completion(running_entry, reason, cleanup_evidence) do
    record_process_completion(running_entry, reason, cleanup_evidence, %{})
  end

  defp record_process_completion(
         %{issue: %Issue{} = issue} = running_entry,
         :normal,
         cleanup_evidence,
         completion_attrs
       ) do
    attrs =
      running_entry
      |> process_ownership_attrs()
      |> Map.put(:cleanup_evidence, cleanup_evidence)

    cond do
      !blank_worker_host?(Map.get(running_entry, :worker_host)) ->
        _ =
          update_owned_state(
            issue,
            running_entry,
            "quarantined",
            Map.put(
              attrs,
              :quarantine_reason,
              "remote worker completion cannot be verified locally"
            )
          )

        :quarantined

      settlement_processes_remain?(cleanup_evidence) ->
        _ =
          update_owned_state(
            issue,
            running_entry,
            "quarantined",
            Map.put(
              attrs,
              :quarantine_reason,
              "app-server process remained live after normal worker exit"
            )
          )

        :quarantined

      settlement_evidence_unavailable?(cleanup_evidence) ->
        _ =
          update_owned_state(
            issue,
            running_entry,
            "quarantined",
            Map.put(attrs, :quarantine_reason, @settlement_evidence_unavailable_reason)
          )

        :quarantined

      true ->
        release_attrs = Map.put(completion_attrs, :cleanup_evidence, cleanup_evidence)
        _ = release_completed_owned_state(issue, running_entry, release_attrs)
        :cleaned
    end
  end

  defp record_process_completion(
         %{issue: %Issue{} = issue} = running_entry,
         reason,
         cleanup_evidence,
         _completion_attrs
       ) do
    attrs =
      running_entry
      |> process_ownership_attrs()
      |> Map.put(:cleanup_evidence, cleanup_evidence)

    cond do
      !blank_worker_host?(Map.get(running_entry, :worker_host)) or
          settlement_processes_remain?(cleanup_evidence) ->
        _ =
          update_owned_state(
            issue,
            running_entry,
            "quarantined",
            Map.put(
              attrs,
              :quarantine_reason,
              "agent exited before app-server process cleaned: #{inspect(reason)}"
            )
          )

        :quarantined

      # A run whose settlement could not capture its evidence is never
      # released: an unobserved run is quarantined for an operator, not
      # recorded as verified clean.
      settlement_evidence_unavailable?(cleanup_evidence) ->
        _ =
          update_owned_state(
            issue,
            running_entry,
            "quarantined",
            Map.put(
              attrs,
              :quarantine_reason,
              "#{@settlement_evidence_unavailable_reason}: #{inspect(reason)}"
            )
          )

        :quarantined

      true ->
        _ = release_owned_state(issue, running_entry, %{cleanup_evidence: cleanup_evidence})
        :cleaned
    end
  end

  # Evidence with no survivor count observed nothing; it is handled by
  # `settlement_evidence_unavailable?/1`, never read as "no survivors".
  defp settlement_processes_remain?(%{live_after: live_after}) when is_integer(live_after),
    do: live_after > 0

  defp settlement_processes_remain?(_cleanup_evidence), do: false

  defp settlement_evidence_unavailable?(%{evidence_status: :unavailable}), do: true
  defp settlement_evidence_unavailable?(_cleanup_evidence), do: false

  defp retry_lease_state(:quarantined), do: "quarantined"
  defp retry_lease_state(_process_completion_status), do: "retrying"

  defp retry_lease_state_from_process_ownership(%{state: "quarantined"}), do: "quarantined"
  defp retry_lease_state_from_process_ownership(_process_ownership), do: "retrying"

  defp retry_process_ownership_status(%{issue: %Issue{} = issue}),
    do: ProcessOwnership.status_for_issue(issue)

  defp retry_process_ownership_status(_running_entry), do: nil

  defp retry_process_ownership_snapshot(%{process_ownership: process_ownership})
       when is_map(process_ownership),
       do: process_ownership

  defp retry_process_ownership_snapshot(%{issue: %Issue{} = issue}),
    do: ProcessOwnership.status_for_issue(issue)

  defp retry_process_ownership_snapshot(_retry), do: nil

  # Prefer the running entry's cached ownership (refreshed on the codex-update
  # path and 30s cadence). Only when it is genuinely absent fall back to a
  # read, which is now cheap: liveness is batched (single process-table read),
  # not per-pid fork fan-out (EMB-1260).
  defp snapshot_process_ownership(%{process_ownership: process_ownership})
       when is_map(process_ownership),
       do: process_ownership

  defp snapshot_process_ownership(%{issue: %Issue{} = issue}),
    do: ProcessOwnership.status_for_issue(issue)

  defp snapshot_process_ownership(_metadata), do: nil

  defp process_ownership_attrs(running_entry) when is_map(running_entry) do
    %{
      role: ProcessOwnership.current_role(),
      run_id: Map.get(running_entry, :run_id),
      holder: ProcessOwnership.holder_id(),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      app_server_pid: Map.get(running_entry, :codex_app_server_pid),
      owned_session_ref: Map.get(running_entry, :owned_session_ref)
    }
  end

  defp release_owned_state(%Issue{} = issue, context, extra_attrs) when is_map(context) do
    ownership = Map.get(context, :process_ownership) || ProcessOwnership.status_for_issue(issue)

    case ownership do
      %{holder: holder} ->
        if holder == ProcessOwnership.holder_id(),
          do: ProcessOwnership.release(issue, ownership_identity(ownership), extra_attrs),
          else: {:error, :ownership_mismatch}

      _ ->
        {:error, :ownership_missing}
    end
  end

  defp release_completed_owned_state(%Issue{} = issue, context, extra_attrs)
       when is_map(context) do
    ownership = Map.get(context, :process_ownership) || ProcessOwnership.status_for_issue(issue)

    case ownership do
      %{holder: holder} ->
        if holder == ProcessOwnership.holder_id(),
          do: ProcessOwnership.release_completed(issue, ownership_identity(ownership), extra_attrs),
          else: {:error, :ownership_mismatch}

      _ ->
        {:error, :ownership_missing}
    end
  end

  defp blank_worker_host?(value), do: !is_binary(value) or String.trim(value) == ""

  defp new_run_id(%Issue{id: issue_id}) do
    unique = System.unique_integer([:positive, :monotonic])
    "#{ProcessOwnership.holder_id()}:#{issue_id || "issue"}:#{unique}"
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

  defp running_worker_host_count(running, worker_host)
       when is_map(running) and is_binary(worker_host) do
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

  @doc "Closes work admission for a target deployment generation."
  @spec close_work_admission(String.t()) ::
          {:ok, map()} | {:error, :invalid_generation | :marker_unavailable | :unavailable}
  def close_work_admission(target_generation) do
    close_work_admission(__MODULE__, target_generation)
  end

  @spec close_work_admission(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, :invalid_generation | :marker_unavailable | :unavailable}
  def close_work_admission(server, target_generation) do
    work_admission_call(server, {:close_work_admission, target_generation})
  end

  @doc "Opens work admission when the target equals this process execution generation."
  @spec open_work_admission(String.t()) ::
          {:ok, map()}
          | {:error,
             :execution_generation_mismatch
             | :execution_generation_unavailable
             | :work_admission_generation_mismatch
             | :invalid_generation
             | :marker_unavailable
             | :unavailable}
  def open_work_admission(target_generation) do
    open_work_admission(__MODULE__, target_generation)
  end

  @spec open_work_admission(GenServer.server(), String.t()) ::
          {:ok, map()}
          | {:error,
             :execution_generation_mismatch
             | :execution_generation_unavailable
             | :work_admission_generation_mismatch
             | :invalid_generation
             | :marker_unavailable
             | :unavailable}
  def open_work_admission(server, target_generation) do
    work_admission_call(server, {:open_work_admission, target_generation})
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
  def handle_call({:close_work_admission, target_generation}, _from, %State{} = state) do
    case validate_generation(target_generation) do
      :ok ->
        admission = %{status: "closed", target_generation: target_generation}
        closed_state = %{state | work_admission: admission}

        case persist_work_admission(state.work_admission_marker_path, admission) do
          :ok ->
            notify_dashboard()
            {:reply, {:ok, work_admission_payload(closed_state)}, closed_state}

          {:error, reason} ->
            Logger.error("Failed to persist closed work admission marker: #{inspect(reason)}")
            notify_dashboard()
            {:reply, {:error, :marker_unavailable}, closed_state}
        end

      {:error, :invalid_generation} ->
        {:reply, {:error, :invalid_generation}, state}
    end
  end

  def handle_call({:open_work_admission, target_generation}, _from, %State{} = state) do
    cond do
      state.execution_generation == "unknown" ->
        {:reply, {:error, :execution_generation_unavailable}, state}

      validate_generation(target_generation) != :ok ->
        {:reply, {:error, :invalid_generation}, state}

      state.execution_generation != target_generation ->
        {:reply, {:error, :execution_generation_mismatch}, state}

      state.work_admission.target_generation != target_generation ->
        {:reply, {:error, :work_admission_generation_mismatch}, state}

      true ->
        admission = %{status: "open", target_generation: target_generation}

        case persist_work_admission(state.work_admission_marker_path, admission) do
          :ok ->
            opened_state =
              state
              |> Map.put(:work_admission, admission)
              |> rearm_held_retry_timers()

            notify_dashboard()
            {:reply, {:ok, work_admission_payload(opened_state)}, opened_state}

          {:error, reason} ->
            Logger.error("Failed to persist open work admission marker: #{inspect(reason)}")
            {:reply, {:error, :marker_unavailable}, state}
        end
    end
  end

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
          # Serviceability: read the CACHED process ownership refreshed on the
          # codex-update path and 30s cadence instead of scanning the process
          # table per running issue inline on the snapshot call. Bounded
          # staleness is acceptable; a snapshot that head-of-line blocks behind
          # per-issue OS scans is the wedge this contract forbids (EMB-1260).
          process_ownership: snapshot_process_ownership(metadata),
          run_id: Map.get(metadata, :run_id),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_activity_at_ms: current_run_activity_ms(metadata),
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
          process_ownership: retry_process_ownership_snapshot(retry)
        }
      end)

    blocked =
      state.blocked_failures
      |> Enum.map(fn {_issue_id, blocked_failure} ->
        %{
          issue_id: Map.get(blocked_failure, :issue_id),
          identifier: Map.get(blocked_failure, :identifier),
          family: Map.get(blocked_failure, :family),
          provider: Map.get(blocked_failure, :provider),
          subtype: Map.get(blocked_failure, :subtype),
          error: Map.get(blocked_failure, :error),
          recovery_reason: Map.get(blocked_failure, :recovery_reason),
          worker_host: Map.get(blocked_failure, :worker_host),
          workspace_path: Map.get(blocked_failure, :workspace_path),
          process_ownership: Map.get(blocked_failure, :process_ownership),
          blocked_at: Map.get(blocked_failure, :blocked_at)
        }
      end)

    {:reply,
     %{
       work_admission: work_admission_payload(state),
       execution_generation: state.execution_generation,
       running: running,
       retrying: retrying,
       blocked: blocked,
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

  defp record_dispatch_result(acc, _issue, :attempted) do
    Map.update!(acc, :attempted, &(&1 + 1))
  end

  defp record_dispatch_result(acc, _issue, {:failed, reason_family}) do
    acc
    |> Map.update!(:attempted, &(&1 + 1))
    |> Map.update!(:failed, &[reason_family | &1])
  end

  defp record_dispatch_result(acc, _issue, {:skipped, skip_summary}) do
    Map.update!(acc, :skipped, &[skip_summary | &1])
  end

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
    |> Map.put(:failure_reason_families, [Atom.to_string(reason_family)])
  end

  defp record_dispatch_summary(%State{} = state, summary) when is_map(summary) do
    log_dispatch_cycle(summary)

    %{
      state
      | latest_dispatch_summary: summary,
        last_poll_result: Map.get(summary, :result, "unknown")
    }
  end

  defp latest_poll_result(%State{
         latest_dispatch_summary: summary,
         last_poll_result: last_poll_result
       }) do
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

  defp safe_issue_identifier(%Issue{identifier: identifier})
       when is_binary(identifier) and identifier != "", do: identifier

  defp safe_issue_identifier(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp safe_issue_identifier(_issue), do: nil

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

  defp integrate_codex_update(
         running_entry,
         update,
         activity_at_ms
       )
       when is_map(update) do
    event = Map.get(update, :event, Map.get(running_entry, :last_codex_event))

    timestamp =
      case Map.get(update, :timestamp) do
        %DateTime{} = provider_timestamp -> provider_timestamp
        _ -> Map.get(running_entry, :last_codex_timestamp)
      end

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
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        last_activity_at_ms: nondecreasing_activity_ms(Map.get(running_entry, :last_activity_at_ms), activity_at_ms)
      })
      |> refresh_handoff_settlement_activity(activity_at_ms),
      token_delta
    }
  end

  # Runtime activity from a turn that is already settling proves the turn is
  # still alive and working, so it pushes the no-activity deadline out in the
  # same update that records `last_codex_timestamp` (EMB-1307). Delegation
  # supervision emits `turn_heartbeat` on every observation cycle while the
  # Herdr orchestrator is working, so a legitimately progressing turn refreshes
  # this continuously and is never force-cleaned; when the activity stops, the
  # anchor ages and forced cleanup still happens after the finite grace.
  #
  # The anchor is only ever REFRESHED here, never created: settlement tracking
  # starts at the first eligible non-active reconciliation, and activity on a
  # turn that is not settling must not enrol it.
  defp refresh_handoff_settlement_activity(
         %{handoff_settlement_last_activity_at_ms: existing} = running_entry,
         activity_at_ms
       )
       when is_integer(activity_at_ms) do
    Map.put(
      running_entry,
      :handoff_settlement_last_activity_at_ms,
      nondecreasing_activity_ms(existing, activity_at_ms)
    )
  end

  defp refresh_handoff_settlement_activity(running_entry, _activity_at_ms), do: running_entry

  defp nondecreasing_activity_ms(existing, observed)
       when is_integer(existing) and is_integer(observed),
       do: max(existing, observed)

  defp nondecreasing_activity_ms(_existing, observed) when is_integer(observed), do: observed
  defp nondecreasing_activity_ms(existing, _observed), do: existing

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
    running_entry = Map.get(state.running, issue_id)
    state = fence_routine_process_ownership(state, issue_id)
    {running_entry, %{state | running: Map.delete(state.running, issue_id)}}
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

  # Keeps the last-known-good runtime values when WORKFLOW.md is transiently
  # invalid (an operator or test rewriting the file between validations).
  # Visibility for the invalid state is owned by the WorkflowStore reload log
  # and the skipped poll-cycle error; raising here would crash-loop the
  # orchestrator until the root supervisor stops the whole application.
  defp refresh_runtime_config(%State{} = state) do
    case Config.settings() do
      {:ok, config} ->
        %{
          state
          | poll_interval_ms: config.polling.interval_ms,
            max_concurrent_agents: config.agent.max_concurrent_agents
        }

      {:error, _reason} ->
        state
    end
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !process_ownership_blocks_retry?(issue)
  end

  defp retry_blocked_by_process_ownership?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      process_ownership_blocks_retry?(issue)
  end

  defp process_ownership_blocks_retry?(%Issue{} = issue) do
    not is_nil(ProcessOwnership.blocking_record(issue))
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

  defp extract_token_delta(running_entry, update) when is_map(update) do
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

  defp work_admission_open?(%State{work_admission: %{status: "open"}}), do: true
  defp work_admission_open?(_state), do: false

  defp active_runner_count do
    case active_runner_pids() do
      {:ok, runner_pids} -> {:ok, length(runner_pids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp work_admission_payload(%State{} = state) do
    %{
      status: state.work_admission.status,
      target_generation: state.work_admission.target_generation,
      drained: map_size(state.running) == 0 and active_runner_count() == {:ok, 0}
    }
  end

  defp active_runner_pids do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      pid when is_pid(pid) -> {:ok, Task.Supervisor.children(SymphonyElixir.TaskSupervisor)}
      _ -> {:error, :task_supervisor_unavailable}
    end
  rescue
    error -> {:error, {:inspection_failed, error}}
  catch
    :exit, reason -> {:error, {:inspection_exited, reason}}
  end

  defp execution_generation(opts) do
    value =
      Keyword.get(opts, :execution_generation) ||
        System.get_env("SYMPHONY_EXECUTION_GENERATION") ||
        "unknown"

    if validate_generation(value) == :ok, do: value, else: "unknown"
  end

  defp work_admission_marker_path(opts) do
    Keyword.get(opts, :work_admission_marker_path) ||
      Application.get_env(:symphony_elixir, :work_admission_marker_path) ||
      non_blank_env("SYMPHONY_WORK_ADMISSION_PATH") ||
      default_work_admission_marker_path()
  end

  defp default_work_admission_marker_path do
    case non_blank_env("SYMPHONY_ORCHESTRATION_ROOT") do
      nil -> nil
      root -> Path.join([root, ".runtime", "symphony", "work-admission.json"])
    end
  end

  defp non_blank_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end

  defp load_work_admission(nil, execution_generation) do
    %{status: "open", target_generation: execution_generation}
  end

  defp load_work_admission(marker_path, execution_generation) when is_binary(marker_path) do
    default_target = if execution_generation == "unknown", do: nil, else: execution_generation

    case read_work_admission_marker(marker_path) do
      {:ok, marker} ->
        apply_marker_generation(marker, execution_generation)

      {:error, :enoent} ->
        %{status: "closed", target_generation: default_target}

      {:error, :malformed} ->
        Logger.error("Work admission marker is malformed; starting closed")
        %{status: "closed", target_generation: default_target}

      {:error, reason} ->
        Logger.error("Work admission marker is unreadable; starting closed reason=#{inspect(reason)}")

        %{status: "closed", target_generation: default_target}
    end
  end

  defp load_work_admission(_marker_path, _execution_generation) do
    %{status: "closed", target_generation: nil}
  end

  defp read_work_admission_marker(marker_path) when is_binary(marker_path) do
    case File.read(marker_path) do
      {:ok, body} -> decode_work_admission(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_work_admission(body) when is_binary(body) do
    with {:ok,
          %{
            "version" => @work_admission_marker_version,
            "status" => status,
            "target_generation" => target_generation
          } = marker} <- Jason.decode(body),
         true <- map_size(marker) == 3,
         true <- status in ["open", "closed"],
         :ok <- validate_generation(target_generation) do
      {:ok, %{status: status, target_generation: target_generation}}
    else
      _reason -> {:error, :malformed}
    end
  end

  defp apply_marker_generation(
         %{status: "open"} = marker,
         "unknown"
       ) do
    Logger.error("Open work admission marker has no valid execution generation; starting closed")
    %{marker | status: "closed"}
  end

  defp apply_marker_generation(
         %{status: "open", target_generation: marker_generation} = marker,
         execution_generation
       )
       when marker_generation != execution_generation do
    Logger.error("Open work admission marker targets a different execution generation; starting closed")

    %{marker | status: "closed"}
  end

  defp apply_marker_generation(marker, _execution_generation), do: marker

  defp persist_work_admission(nil, _admission), do: {:error, :marker_path_missing}

  defp persist_work_admission(marker_path, admission)
       when is_binary(marker_path) and is_map(admission) do
    directory = Path.dirname(marker_path)

    temporary_path =
      marker_path <>
        ".tmp-" <>
        System.pid() <>
        "-" <>
        Integer.to_string(System.unique_integer([:positive, :monotonic]))

    body =
      Jason.encode!(%{
        "version" => @work_admission_marker_version,
        "status" => admission.status,
        "target_generation" => admission.target_generation
      })

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary_path, body <> "\n", [:exclusive, :sync]),
         :ok <- File.rename(temporary_path, marker_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary_path)
        {:error, reason}
    end
  end

  defp persist_work_admission(_marker_path, _admission), do: {:error, :invalid_marker_path}

  defp validate_generation(value) when is_binary(value) do
    if value != "unknown" and
         byte_size(value) in 1..@max_generation_length and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value) do
      :ok
    else
      {:error, :invalid_generation}
    end
  end

  defp validate_generation(_value), do: {:error, :invalid_generation}

  defp work_admission_call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp rearm_held_retry_timers(%State{} = state) do
    retry_attempts =
      Enum.into(state.retry_attempts, %{}, fn {issue_id, retry} ->
        if Map.get(retry, :held_by_admission, false) do
          retry_token = make_ref()

          delay_ms =
            max(
              Map.get(retry, :due_at_ms, System.monotonic_time(:millisecond)) -
                System.monotonic_time(:millisecond),
              0
            )

          timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

          {issue_id,
           retry
           |> Map.put(:retry_token, retry_token)
           |> Map.put(:timer_ref, timer_ref)
           |> Map.delete(:held_by_admission)}
        else
          {issue_id, retry}
        end
      end)

    %{state | retry_attempts: retry_attempts}
  end
end
