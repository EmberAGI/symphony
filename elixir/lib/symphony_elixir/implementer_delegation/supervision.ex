defmodule SymphonyElixir.ImplementerDelegation.Supervision do
  @moduledoc """
  Bounded heartbeat supervision for one delegated Implementer turn.

  Replaces the budget-length `agent wait` with bounded-cadence typed status
  reads (`get_agent`) so blocked, unknown, and stalled agents surface within one
  observation interval instead of at the end of the turn budget.
  """

  @default_status_read_timeout_ms 5_000

  @typedoc "Supervision loop configuration owned by `ImplementerDelegation.run_turn/4`."
  @type config :: %{
          required(:transport) => module(),
          required(:context) => term(),
          required(:session) => map(),
          required(:orchestrator) => map(),
          required(:hard_budget_ms) => non_neg_integer(),
          required(:interval_ms) => pos_integer(),
          required(:status_read_timeout_ms) => pos_integer(),
          required(:on_heartbeat) => (map() -> any())
        }

  @spec default_status_read_timeout_ms() :: pos_integer()
  def default_status_read_timeout_ms, do: @default_status_read_timeout_ms

  @doc """
  Supervise a working agent until a typed terminal observation.

  Returns `{:ok, agent}` on an observed `idle`/`done` status, or a typed error.
  """
  @spec supervise(config()) :: {:ok, map()} | {:error, term()}
  def supervise(config) do
    deadline = System.monotonic_time(:millisecond) + config.hard_budget_ms
    observe(config, deadline)
  end

  defp observe(config, deadline) do
    case config.transport.get_agent(
           config.session,
           config.orchestrator,
           config.status_read_timeout_ms,
           config.context
         ) do
      {:ok, %{agent_status: status} = agent} when status in ["idle", "done"] ->
        {:ok, agent}

      {:ok, %{agent_status: "working"} = agent} ->
        config.on_heartbeat.(agent)
        continue(config, deadline)

      {:ok, agent} ->
        {:error, {:unexpected_herdr_agent_status, Map.get(agent, :agent_status)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue(config, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, {:herdr_agent_status_timeout, Map.get(config.orchestrator, :name), ["idle", "done"]}}
    else
      Process.sleep(min(config.interval_ms, max(remaining_ms, 1)))
      observe(config, deadline)
    end
  end
end
