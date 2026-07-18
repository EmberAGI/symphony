defmodule SymphonyElixir.Tracker.ClaimLeaseReconciliation do
  @moduledoc """
  Typed outcome of reconciling a transport-ambiguous claim-lease write.

  A claim-lease create or update whose transport failed before a response
  arrived may still have committed. The tracker adapter reconciles that
  ambiguity with one authoritative issue refetch and reports the result here
  so the orchestrator can dispatch exactly once on confirmed ownership or
  fail closed with an observable next recovery action.
  """

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.Tracker.ClaimLease

  defstruct [:mutation, :transport_reason, :refetch, :outcome, :next_action, :lease]

  @type mutation :: :create | :update
  @type outcome ::
          :confirmed_ownership
          | :issue_identity_mismatch
          | :lease_not_active
          | :no_lease_found
          | :competing_holder
          | :same_holder_different_run
          | :malformed_lease
          | :refetch_failed
  @type next_action ::
          :dispatch_once
          | :retry_next_poll
          | :defer_to_current_holder
          | :recover_stale_current_holder_lease
          | :requires_lease_recovery

  @type t :: %__MODULE__{
          mutation: mutation(),
          transport_reason: String.t(),
          refetch: :verified | :failed,
          outcome: outcome(),
          next_action: next_action(),
          lease: ClaimLease.t() | nil
        }

  @fail_closed_next_actions %{
    issue_identity_mismatch: :requires_lease_recovery,
    lease_not_active: :recover_stale_current_holder_lease,
    no_lease_found: :retry_next_poll,
    competing_holder: :defer_to_current_holder,
    same_holder_different_run: :recover_stale_current_holder_lease,
    malformed_lease: :requires_lease_recovery,
    refetch_failed: :retry_next_poll
  }

  @spec confirmed(mutation(), term(), ClaimLease.t()) :: t()
  def confirmed(mutation, transport_reason, %ClaimLease{} = lease) when mutation in [:create, :update] do
    %__MODULE__{
      mutation: mutation,
      transport_reason: summarize_transport_reason(transport_reason),
      refetch: :verified,
      outcome: :confirmed_ownership,
      next_action: :dispatch_once,
      lease: lease
    }
  end

  @spec fail_closed(mutation(), term(), outcome(), ClaimLease.t() | nil) :: t()
  def fail_closed(mutation, transport_reason, outcome, lease \\ nil)
      when mutation in [:create, :update] and is_map_key(@fail_closed_next_actions, outcome) do
    %__MODULE__{
      mutation: mutation,
      transport_reason: summarize_transport_reason(transport_reason),
      refetch: if(outcome == :refetch_failed, do: :failed, else: :verified),
      outcome: outcome,
      next_action: Map.fetch!(@fail_closed_next_actions, outcome),
      lease: lease
    }
  end

  @spec reason_family(t()) :: String.t()
  def reason_family(%__MODULE__{outcome: outcome}) do
    "claim_lease_ambiguous_" <> Atom.to_string(outcome)
  end

  @spec diagnostic(t()) :: map()
  def diagnostic(%__MODULE__{} = reconciliation) do
    %{
      trigger: "ambiguous_" <> Atom.to_string(reconciliation.mutation) <> "_transport_error",
      mutation: Atom.to_string(reconciliation.mutation),
      transport_reason: reconciliation.transport_reason,
      refetch: Atom.to_string(reconciliation.refetch),
      outcome: Atom.to_string(reconciliation.outcome),
      next_action: Atom.to_string(reconciliation.next_action)
    }
  end

  defp summarize_transport_reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> sanitize_and_bound()

  defp summarize_transport_reason(%{reason: reason}) when is_atom(reason),
    do: reason |> Atom.to_string() |> sanitize_and_bound()

  defp summarize_transport_reason(reason) when is_binary(reason), do: sanitize_and_bound(reason)

  defp summarize_transport_reason(reason), do: reason |> inspect() |> sanitize_and_bound()

  defp sanitize_and_bound(reason) do
    reason
    |> AgentRuntime.sanitize_runtime_text()
    |> String.slice(0, 120)
  end
end
