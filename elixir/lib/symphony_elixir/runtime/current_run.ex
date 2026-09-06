defmodule SymphonyElixir.Runtime.CurrentRun do
  @moduledoc """
  Exact acquired-run identity and its bounded in-memory activity signal.

  The capability is created by Orchestrator at acquisition and shared only
  with that run's AgentRunner. Provider observations advance a monotonic
  watermark before mailbox enqueue. Plain streaming notifications are
  coalesced to at most one outstanding mailbox signal; identity, accounting,
  session, PID, rate-limit, and terminal-bearing updates are never coalesced.

  ProcessOwnership remains the durable authority. This module contains no
  ownership or persistence policy.
  """

  alias SymphonyElixir.Linear.Issue

  @active_slot 1
  @watermark_slot 2
  @notification_pending_slot 3

  @enforce_keys [:identity, :signal]
  defstruct [:identity, :signal]

  @type identity :: %{
          required(:issue_id) => String.t(),
          required(:workspace_path) => String.t(),
          required(:role) => String.t(),
          required(:holder) => String.t(),
          required(:run_id) => String.t()
        }

  @opaque t :: %__MODULE__{identity: identity(), signal: :atomics.atomics_ref()}

  @spec new(Issue.t(), map()) :: t()
  def new(%Issue{id: issue_id}, ownership) when is_map(ownership) do
    identity = %{
      issue_id: issue_id,
      workspace_path: value(ownership, :workspace_path),
      role: value(ownership, :role),
      holder: value(ownership, :holder),
      run_id: value(ownership, :run_id)
    }

    unless Enum.all?(identity, fn {_key, item} -> is_binary(item) and item != "" end) do
      raise ArgumentError, "current run requires exact issue/workspace/role/holder/run identity"
    end

    signal = :atomics.new(3, signed: true)
    :atomics.put(signal, @active_slot, 1)
    :atomics.put(signal, @watermark_slot, System.monotonic_time(:millisecond))
    %__MODULE__{identity: identity, signal: signal}
  end

  @spec identity(t()) :: identity()
  def identity(%__MODULE__{identity: identity}), do: identity

  @spec envelope(term()) :: identity()
  def envelope(%__MODULE__{} = current_run), do: identity(current_run)

  @spec observe(t()) :: {:ok, integer()} | :retired
  def observe(%__MODULE__{signal: signal}) do
    if active?(signal) do
      observed_at_ms = System.monotonic_time(:millisecond)
      advance(signal, observed_at_ms)

      if active?(signal), do: {:ok, observed_at_ms}, else: :retired
    else
      :retired
    end
  end

  @spec accept_ingress(t(), map()) :: {:ok, integer()} | :invalid
  def accept_ingress(%__MODULE__{} = current_run, envelope) when is_map(envelope) do
    ingress_at_ms = Map.get(envelope, :ingress_at_ms)
    now_ms = System.monotonic_time(:millisecond)
    observed_watermark = :atomics.get(current_run.signal, @watermark_slot)

    if matches?(current_run, envelope) and is_integer(ingress_at_ms) and ingress_at_ms <= now_ms and
         ingress_at_ms <= observed_watermark and active?(current_run.signal) do
      {:ok, ingress_at_ms}
    else
      :invalid
    end
  end

  def accept_ingress(_current_run, _envelope), do: :invalid

  @spec activity_ms(term()) :: integer() | nil
  def activity_ms(%__MODULE__{signal: signal}) do
    if active?(signal), do: :atomics.get(signal, @watermark_slot), else: nil
  end

  def activity_ms(_current_run), do: nil

  @spec matches?(term(), map()) :: boolean()
  def matches?(%__MODULE__{identity: identity}, envelope) when is_map(envelope) do
    Enum.all?(identity, fn {key, expected} -> Map.get(envelope, key) == expected end)
  end

  def matches?(_current_run, _envelope), do: false

  @spec forward_update(pid(), t(), map()) :: :ok
  def forward_update(recipient, %__MODULE__{} = current_run, update)
      when is_pid(recipient) and is_map(update) do
    case observe(current_run) do
      {:ok, ingress_at_ms} ->
        if critical_update?(update) or claim_plain_notification(current_run.signal) do
          envelope = Map.put(current_run.identity, :ingress_at_ms, ingress_at_ms)
          send(recipient, {:codex_worker_update, current_run.identity.issue_id, envelope, update})
        end

      :retired ->
        :ok
    end

    :ok
  end

  def forward_update(_recipient, _current_run, _update), do: :ok

  @spec acknowledge_update(t()) :: :ok
  def acknowledge_update(%__MODULE__{signal: signal}) do
    :atomics.put(signal, @notification_pending_slot, 0)
    :ok
  end

  @spec retire(term()) :: :ok
  def retire(%__MODULE__{signal: signal}) do
    :atomics.put(signal, @active_slot, 0)
    :atomics.put(signal, @notification_pending_slot, 0)
    :ok
  end

  def retire(_current_run), do: :ok

  defp active?(signal), do: :atomics.get(signal, @active_slot) == 1

  defp advance(signal, observed_at_ms) do
    previous = :atomics.get(signal, @watermark_slot)

    cond do
      observed_at_ms <= previous ->
        :ok

      :atomics.compare_exchange(signal, @watermark_slot, previous, observed_at_ms) == :ok ->
        :ok

      true ->
        advance(signal, observed_at_ms)
    end
  end

  defp claim_plain_notification(signal) do
    :atomics.compare_exchange(signal, @notification_pending_slot, 0, 1) == :ok
  end

  defp critical_update?(update) do
    Map.get(update, :event) != :notification or
      Enum.any?(
        [:usage, :rate_limits, :session_id, :codex_app_server_pid],
        &Map.has_key?(update, &1)
      ) or contains_accounting_data?(Map.get(update, :payload))
  end

  defp contains_accounting_data?(payload) when is_map(payload) do
    Enum.any?(payload, fn {key, value} ->
      key in ["usage", :usage, "rate_limits", :rate_limits, "tokenUsage", :tokenUsage] or
        contains_accounting_data?(value)
    end)
  end

  defp contains_accounting_data?(payload) when is_list(payload),
    do: Enum.any?(payload, &contains_accounting_data?/1)

  defp contains_accounting_data?(_payload), do: false

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
