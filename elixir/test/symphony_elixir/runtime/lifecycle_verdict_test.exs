defmodule SymphonyElixir.Runtime.LifecycleVerdictTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Runtime.LifecycleVerdict

  test "a live session prevents false-death retry and workflow mutation for every lease and turn state" do
    for lease <- [:live, :expired, :missing], provider_turn <- [:working, :completed, :failed] do
      verdict =
        LifecycleVerdict.evaluate(
          session: :live,
          lease: lease,
          provider_turn: provider_turn
        )

      assert %LifecycleVerdict{
               session: :live,
               lease: ^lease,
               provider_turn: ^provider_turn,
               workflow_mutation: :refuse,
               claim_release: :refuse,
               retry: :refuse
             } = verdict

      if provider_turn == :working do
        assert verdict.disposition == :running
        assert verdict.cleanup == :not_required
        assert verdict.escalation == :refuse
      else
        assert verdict.disposition == :cleanup_required
        assert verdict.cleanup == :required
        assert verdict.escalation == :allow
      end
    end
  end

  test "a completed turn may settle only after the session is absent for every lease state" do
    for lease <- [:live, :expired, :missing] do
      assert %LifecycleVerdict{
               session: :absent,
               lease: ^lease,
               provider_turn: :completed,
               disposition: :settled,
               workflow_mutation: :allow,
               claim_release: :allow,
               retry: :refuse,
               cleanup: :not_required,
               escalation: :refuse
             } =
               LifecycleVerdict.evaluate(
                 session: :absent,
                 lease: lease,
                 provider_turn: :completed
               )
    end
  end

  test "unknown or unreachable session liveness quarantines ownership" do
    for session <- [:unknown, :unreachable],
        lease <- [:live, :expired, :missing],
        provider_turn <- [:working, :completed, :failed] do
      assert %LifecycleVerdict{
               disposition: :quarantined,
               workflow_mutation: :refuse,
               claim_release: :refuse,
               retry: :refuse,
               cleanup: :quarantine,
               escalation: :allow
             } =
               LifecycleVerdict.evaluate(
                 session: session,
                 lease: lease,
                 provider_turn: provider_turn
               )
    end
  end

  test "an absent session makes failed turns retryable and working turns contradictory" do
    for lease <- [:live, :expired, :missing] do
      assert %LifecycleVerdict{
               disposition: :retryable,
               workflow_mutation: :allow,
               claim_release: :allow,
               retry: :allow,
               cleanup: :not_required
             } =
               LifecycleVerdict.evaluate(
                 session: :absent,
                 lease: lease,
                 provider_turn: :failed
               )

      assert %LifecycleVerdict{
               disposition: :quarantined,
               workflow_mutation: :refuse,
               claim_release: :refuse,
               retry: :refuse,
               cleanup: :quarantine
             } =
               LifecycleVerdict.evaluate(
                 session: :absent,
                 lease: lease,
                 provider_turn: :working
               )
    end
  end
end
