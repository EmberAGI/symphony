defmodule SymphonyElixir.ImplementerDelegation.Supervision do
  @moduledoc """
  Bounded, idempotent heartbeat supervision for one delegated Implementer turn.

  Replaces the budget-length `agent wait` with bounded-cadence typed status
  reads (`get_agent`) so blocked, unknown, unreadable, and stalled agents
  surface within one observation interval instead of at the end of the turn
  budget. The pure `step/3` core owns every transition; the loop only performs
  transport reads and sleeps. Observation only: lifecycle arbitration and
  teardown verdicts stay outside this module (EMB-1217).

  Work preservation is scoped to the technically observable: before any halt
  that could precede a destructive shutdown, the supervisor records a
  best-effort checkpoint (pane tail, session/workspace identity, last status,
  progress cursor, recovery history, shutdown reason) in the typed outcome. A
  checkpoint failure is itself typed and marks destructive shutdown as blocked.
  """

  @statuses ~w(idle working blocked done unknown)

  @default_status_read_timeout_ms 5_000
  @default_max_indeterminate_reads 4
  @default_stale_working_ms 900_000
  @default_max_recovery_attempts 2
  @checkpoint_pane_lines 240

  @typedoc "Supervision loop configuration owned by `ImplementerDelegation.run_turn/4`."
  @type config :: map()
  @typedoc "Pure supervision state threaded through `step/3`."
  @type state :: map()

  @spec default_status_read_timeout_ms() :: pos_integer()
  def default_status_read_timeout_ms, do: @default_status_read_timeout_ms

  # Herdr 0.7.5's prompt-effect window: a same-revision idle/done read inside
  # this window after submission is transitional, not completion.
  @default_settle_window_ms 5_000

  @spec default_settle_window_ms() :: pos_integer()
  def default_settle_window_ms, do: @default_settle_window_ms

  @doc "Build the initial pure supervision state from bounds and the current monotonic time."
  @spec new(map(), integer()) :: state()
  def new(bounds, now_ms) when is_map(bounds) and is_integer(now_ms) do
    %{
      budget_deadline: now_ms + Map.fetch!(bounds, :hard_budget_ms),
      max_indeterminate_reads: Map.get(bounds, :max_indeterminate_reads, @default_max_indeterminate_reads),
      stale_working_ms: Map.get(bounds, :stale_working_ms, @default_stale_working_ms),
      max_recovery_attempts: Map.get(bounds, :max_recovery_attempts, @default_max_recovery_attempts),
      settle_deadline: now_ms + Map.get(bounds, :settle_window_ms, 0),
      baseline_revision: Map.get(bounds, :baseline_revision),
      indeterminate_reads: 0,
      last_status: "working",
      last_agent_session: nil,
      last_cursor: :unavailable,
      last_progress_at: now_ms,
      recovery_attempts: 0,
      recovery_history: []
    }
  end

  @doc """
  Pure, idempotent transition: the same state, observation, and clock always
  produce the same directive. Directives: `{:completed, agent}`, `:continue`,
  `:recover`, or `{:halt, halt_reason}` — the loop owns all side effects.
  """
  @spec step(state(), {:ok, map()} | {:error, term()}, integer()) ::
          {{:completed, map()} | :continue | :recover | {:halt, term()}, state()}
  def step(state, observation, now_ms) do
    state = remember_agent(state, observation)

    if now_ms >= state.budget_deadline,
      do: {{:halt, :hard_budget_exhausted}, state},
      else: classify(state, observation, now_ms)
  end

  defp remember_agent(state, {:ok, %{agent_session: session}}) when not is_nil(session),
    do: Map.put(state, :last_agent_session, session)

  defp remember_agent(state, _observation), do: state

  defp classify(state, {:error, {:herdr_agent_closed, _name} = reason}, _now_ms),
    do: {{:halt, {:closed, reason}}, state}

  defp classify(state, {:error, reason}, _now_ms),
    do: indeterminate(state, {:status_reads_failed, reason})

  defp classify(state, {:ok, %{agent_status: "blocked"}}, _now_ms),
    do: {{:halt, :blocked}, %{state | last_status: "blocked"}}

  defp classify(state, {:ok, %{agent_status: "unknown"}}, _now_ms),
    do: indeterminate(%{state | last_status: "unknown"}, :persistent_unknown)

  defp classify(state, {:ok, %{agent_status: status} = agent}, now_ms) when status in ["idle", "done"] do
    if transitional?(state, agent, now_ms),
      do: {:continue, state},
      else: {{:completed, agent}, %{state | last_status: status}}
  end

  defp classify(state, {:ok, %{agent_status: "working"} = agent}, now_ms) do
    state = observe_progress(%{state | indeterminate_reads: 0, last_status: "working"}, agent, now_ms)

    cond do
      now_ms - state.last_progress_at < state.stale_working_ms -> {:continue, state}
      state.recovery_attempts < state.max_recovery_attempts -> {:recover, state}
      true -> {{:halt, :stale_working}, state}
    end
  end

  defp classify(state, {:ok, agent}, _now_ms) do
    status = Map.get(agent, :agent_status)

    if status in @statuses,
      do: {:continue, state},
      else: {{:halt, {:protocol, {:unexpected_herdr_agent_status, status}}}, state}
  end

  defp indeterminate(state, halt_reason) do
    reads = state.indeterminate_reads + 1

    if reads >= state.max_indeterminate_reads,
      do: {{:halt, halt_reason}, %{state | indeterminate_reads: reads}},
      else: {:continue, %{state | indeterminate_reads: reads}}
  end

  defp transitional?(state, agent, now_ms) do
    revision = Map.get(agent, :revision)

    is_integer(revision) and revision == state.baseline_revision and now_ms < state.settle_deadline
  end

  defp observe_progress(state, agent, now_ms) do
    cursor = Map.get(agent, :progress_cursor, :unavailable)

    if cursor != :unavailable and cursor != state.last_cursor,
      do: %{state | last_cursor: cursor, last_progress_at: now_ms},
      else: state
  end

  defp record_recovery(state, attempt_result, now_ms) do
    %{
      state
      | recovery_attempts: state.recovery_attempts + 1,
        recovery_history: state.recovery_history ++ [%{at_ms: now_ms, result: attempt_result}]
    }
  end

  @doc """
  Supervise a working agent until a typed terminal observation.

  Returns `{:ok, agent}` on an observed `idle`/`done` status, or a typed error
  whose evidence carries the preservation checkpoint.
  """
  @spec supervise(config()) :: {:ok, map()} | {:error, term()}
  def supervise(config) do
    now = System.monotonic_time(:millisecond)

    state =
      new(
        %{
          hard_budget_ms: config.hard_budget_ms,
          max_indeterminate_reads: Map.get(config, :max_indeterminate_reads, @default_max_indeterminate_reads),
          stale_working_ms: Map.get(config, :stale_working_ms, @default_stale_working_ms),
          max_recovery_attempts: Map.get(config, :max_recovery_attempts, @default_max_recovery_attempts),
          settle_window_ms: Map.get(config, :settle_window_ms, 0),
          baseline_revision: Map.get(config, :baseline_revision)
        },
        now
      )

    loop(config, state)
  end

  defp loop(config, state) do
    observation = read_status(config)
    now = System.monotonic_time(:millisecond)

    case step(state, annotate_progress(config, observation), now) do
      {{:completed, agent}, _state} ->
        {:ok, agent}

      {:continue, state} ->
        heartbeat(config, state)
        pause(config, state)
        loop(config, state)

      {:recover, state} ->
        recover(config, state)

      {{:halt, halt_reason}, state} ->
        halt(config, state, halt_reason)
    end
  end

  defp read_status(config) do
    config.transport.get_agent(
      config.session,
      config.orchestrator,
      config.status_read_timeout_ms,
      config.context
    )
  end

  defp annotate_progress(config, {:ok, %{agent_status: "working"} = agent}) do
    cursor =
      case config.transport.read_agent(
             config.session,
             config.orchestrator,
             %{source: :recent_unwrapped, lines: 40},
             config.context
           ) do
        {:ok, %{text: text}} -> {byte_size(text), :erlang.phash2(text)}
        {:error, _reason} -> :unavailable
      end

    {:ok, Map.put(agent, :progress_cursor, cursor)}
  end

  defp annotate_progress(_config, observation), do: observation

  defp heartbeat(config, %{last_status: "working"}), do: config.on_heartbeat.(%{agent_status: "working"})
  defp heartbeat(_config, _state), do: :ok

  defp pause(config, state) do
    remaining_ms = state.budget_deadline - System.monotonic_time(:millisecond)
    Process.sleep(min(config.interval_ms, max(remaining_ms, 1)))
  end

  defp recover(config, state) do
    recovery_timeout_ms = Map.get(config, :recovery_timeout_ms, config.status_read_timeout_ms)

    result =
      config.transport.await_agent(
        config.session,
        config.orchestrator,
        ["idle", "done", "blocked"],
        recovery_timeout_ms,
        config.context
      )

    now = System.monotonic_time(:millisecond)

    case result do
      {:ok, %{agent_status: status} = agent} when status in ["idle", "done"] ->
        {:ok, agent}

      {:ok, %{agent_status: "blocked"}} ->
        halt(config, record_recovery(state, :observed_blocked, now), :blocked)

      other ->
        state = record_recovery(state, recovery_result_evidence(other), now)
        pause(config, state)
        loop(config, state)
    end
  end

  defp recovery_result_evidence({:error, reason}), do: {:failed, reason}
  defp recovery_result_evidence({:ok, agent}), do: {:non_terminal, Map.get(agent, :agent_status)}

  defp halt(config, state, :hard_budget_exhausted) do
    case checkpoint(config, state, :hard_budget_exhausted) do
      {:ok, saved} ->
        {:error, {:implementer_hard_budget_exhausted, %{checkpoint: {:ok, saved}, last_status: state.last_status}}}

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp halt(config, state, :blocked) do
    {:error,
     {:implementer_agent_blocked,
      %{
        agent_status: "blocked",
        checkpoint: checkpoint(config, state, :blocked),
        recovery_history: state.recovery_history
      }}}
  end

  defp halt(config, state, :persistent_unknown) do
    {:error,
     {:implementer_agent_unobservable,
      %{
        checkpoint: checkpoint(config, state, :persistent_unknown),
        indeterminate_reads: state.indeterminate_reads,
        recovery_history: state.recovery_history
      }}}
  end

  defp halt(config, state, {:status_reads_failed, reason}) do
    {:error,
     {:implementer_status_reads_failed,
      %{
        last_error: reason,
        checkpoint: checkpoint(config, state, :status_reads_failed),
        indeterminate_reads: state.indeterminate_reads
      }}}
  end

  defp halt(config, state, :stale_working) do
    {:error,
     {:implementer_agent_stalled,
      %{
        checkpoint: checkpoint(config, state, :stale_working),
        recovery_history: state.recovery_history
      }}}
  end

  defp halt(config, state, {:closed, {:herdr_agent_closed, agent_name}}) do
    {:error, {:herdr_agent_closed, agent_name, %{checkpoint: checkpoint(config, state, :agent_closed)}}}
  end

  defp halt(config, state, {:protocol, {:unexpected_herdr_agent_status, status}}) do
    saved = checkpoint(config, state, :status_protocol_violation)
    {:error, {:unexpected_herdr_agent_status, status, %{checkpoint: saved}}}
  end

  # Best-effort durable checkpoint of the observable turn state. Failure is
  # typed and marks destructive shutdown as blocked; callers must not destroy
  # the pane/session while `destructive_shutdown_blocked` is set.
  defp checkpoint(config, state, shutdown_reason) do
    case config.transport.read_agent(
           config.session,
           config.orchestrator,
           %{source: :visible, lines: @checkpoint_pane_lines},
           config.context
         ) do
      {:ok, %{text: text}} ->
        {:ok,
         %{
           pane_tail: text,
           herdr_session: Map.get(config.session, :name),
           runtime_root: Map.get(config.session, :runtime_root),
           workspace: Map.get(config.session, :workspace),
           agent: Map.get(config.orchestrator, :name),
           agent_resume: Map.get(state, :last_agent_session),
           pane_id: Map.get(config.orchestrator, :pane_id),
           last_status: Map.get(state, :last_status),
           progress_cursor: Map.get(state, :last_cursor),
           recovery_history: Map.get(state, :recovery_history, []),
           shutdown_reason: shutdown_reason,
           captured_at: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:error,
         {:implementer_checkpoint_failed,
          %{
            reason: reason,
            shutdown_reason: shutdown_reason,
            destructive_shutdown_blocked: true
          }}}
    end
  end
end
