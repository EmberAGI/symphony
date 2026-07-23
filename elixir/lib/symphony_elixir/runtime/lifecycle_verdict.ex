defmodule SymphonyElixir.Runtime.LifecycleVerdict do
  @moduledoc """
  Typed authority for role-turn lifecycle mutations.

  Herdr session liveness is authoritative only for whether the owned session
  tree is alive. This verdict combines that fact with claim-lease and provider
  turn state before a caller may retry, release a claim, or mutate workflow
  state.
  """

  @type session_liveness :: :live | :absent | :unknown | :unreachable
  @type lease_liveness :: :live | :expired | :missing
  @type provider_turn :: :working | :completed | :failed
  @type disposition ::
          :running | :cleanup_required | :settled | :retryable | :quarantined
  @type permission :: :allow | :refuse
  @type cleanup_action :: :not_required | :required | :quarantine

  @enforce_keys [
    :session,
    :lease,
    :provider_turn,
    :disposition,
    :workflow_mutation,
    :claim_release,
    :retry,
    :cleanup,
    :escalation
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          session: session_liveness(),
          lease: lease_liveness(),
          provider_turn: provider_turn(),
          disposition: disposition(),
          workflow_mutation: permission(),
          claim_release: permission(),
          retry: permission(),
          cleanup: cleanup_action(),
          escalation: permission()
        }

  @doc "Evaluate the lifecycle facts that gate every durable role-turn mutation."
  @spec evaluate(
          session: session_liveness(),
          lease: lease_liveness(),
          provider_turn: provider_turn()
        ) :: t()
  def evaluate(session: :live, lease: lease, provider_turn: provider_turn)
      when lease in [:live, :expired, :missing] and
             provider_turn in [:working, :completed, :failed] do
    %__MODULE__{
      session: :live,
      lease: lease,
      provider_turn: provider_turn,
      disposition: live_session_disposition(provider_turn),
      workflow_mutation: :refuse,
      claim_release: :refuse,
      retry: :refuse,
      cleanup: live_session_cleanup(provider_turn),
      escalation: live_session_escalation(provider_turn)
    }
  end

  def evaluate(session: :absent, lease: lease, provider_turn: :completed)
      when lease in [:live, :expired, :missing] do
    %__MODULE__{
      session: :absent,
      lease: lease,
      provider_turn: :completed,
      disposition: :settled,
      workflow_mutation: :allow,
      claim_release: :allow,
      retry: :refuse,
      cleanup: :not_required,
      escalation: :refuse
    }
  end

  def evaluate(session: :absent, lease: lease, provider_turn: :failed)
      when lease in [:live, :expired, :missing] do
    %__MODULE__{
      session: :absent,
      lease: lease,
      provider_turn: :failed,
      disposition: :retryable,
      workflow_mutation: :allow,
      claim_release: :allow,
      retry: :allow,
      cleanup: :not_required,
      escalation: :allow
    }
  end

  def evaluate(session: :absent, lease: lease, provider_turn: :working)
      when lease in [:live, :expired, :missing] do
    quarantined(:absent, lease, :working)
  end

  def evaluate(session: session, lease: lease, provider_turn: provider_turn)
      when session in [:unknown, :unreachable] and
             lease in [:live, :expired, :missing] and
             provider_turn in [:working, :completed, :failed] do
    quarantined(session, lease, provider_turn)
  end

  defp quarantined(session, lease, provider_turn) do
    %__MODULE__{
      session: session,
      lease: lease,
      provider_turn: provider_turn,
      disposition: :quarantined,
      workflow_mutation: :refuse,
      claim_release: :refuse,
      retry: :refuse,
      cleanup: :quarantine,
      escalation: :allow
    }
  end

  defp live_session_disposition(:working), do: :running
  defp live_session_disposition(provider_turn) when provider_turn in [:completed, :failed], do: :cleanup_required

  defp live_session_cleanup(:working), do: :not_required
  defp live_session_cleanup(provider_turn) when provider_turn in [:completed, :failed], do: :required

  defp live_session_escalation(:working), do: :refuse
  defp live_session_escalation(provider_turn) when provider_turn in [:completed, :failed], do: :allow
end
