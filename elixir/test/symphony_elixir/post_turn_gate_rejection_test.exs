defmodule SymphonyElixir.PostTurnGateRejectionTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  RED: a post-turn gate that rejected the run authorizes an equivalent retry.

  `finish_with_after_run_hook/5` wraps an `after_run` failure as
  `{:post_turn_routing_failed, hook_reason}`, which matches no irrecoverable
  family and carries no transient marker, so `classify_failure/2` falls through
  to `:retryable_runtime_failure`. The orchestrator then schedules a redispatch
  from the same durable checkpoint with the same failure fingerprint. Canary
  EMB-1285 did exactly that, and EMB-1256 hit the identical rejection earlier
  the same day.

  Retrying a verdict is repetition, not recovery. The distinction the runtime
  can actually draw is not "deterministic vs transient" read out of the hook's
  message — it is whether a verdict was obtained at all:

    * the hook ran to completion and exited non-zero — it inspected the run and
      rejected it, and the same input will be rejected again;
    * the hook timed out, or the runtime could not reach the host to run it —
      no verdict exists, and retrying may well produce one.

  A gate that fails for its own transient reasons is indistinguishable from one
  that rejected the content, because both are a non-zero exit. That case is
  covered by a reserved exit status the gate opts into, never by guessing from
  its output.
  """

  alias SymphonyElixir.AgentRuntime

  @context %{
    issue_id: "issue-emb-1285",
    workspace_path: "/tmp/symphony/EMB-1285",
    role: "implementer",
    provider: :codex
  }

  # The exact gate output observed on production wrapper b054bd64.
  @gate_output """
  ERROR: current execution status contains non-field content outside multiline Work done on line 1
  ERROR: illegal state transition for implementer: todo -> todo
  """

  describe "a gate that returned a verdict is not retried" do
    test "the production rejection classifies irrecoverable, not retryable" do
      reason = {:post_turn_routing_failed, {:workspace_hook_failed, "after_run", 1, @gate_output}}

      assert {:irrecoverable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.family == :post_turn_gate_rejected
      assert failure.retryable? == false
      assert failure.recovery_reason == "post-turn-gate-rejected-repair-required"
    end

    test "any non-zero gate exit is a verdict, whatever it printed" do
      for status <- [1, 2, 3, 64, 65] do
        reason = {:post_turn_routing_failed, {:workspace_hook_failed, "after_run", status, "ERROR: rejected"}}

        assert {:irrecoverable, failure} = AgentRuntime.classify_failure(reason, @context)
        assert failure.family == :post_turn_gate_rejected
      end
    end

    test "a rejection never authorizes an equivalent redispatch, even on first observation" do
      reason = {:post_turn_routing_failed, {:workspace_hook_failed, "after_run", 1, @gate_output}}

      assert {observation, {:irrecoverable, failure}} =
               AgentRuntime.record_failure_observation(nil, reason, @context)

      assert failure.retryable? == false
      assert observation.count == 1
    end

    test "the rejected content is summarized without leaking the whole gate transcript" do
      secret = "ERROR: rejected\ntoken=gate-secret"
      reason = {:post_turn_routing_failed, {:workspace_hook_failed, "after_run", 1, secret}}

      assert {:irrecoverable, failure} = AgentRuntime.classify_failure(reason, @context)
      refute failure.summary =~ "gate-secret"
      refute failure.summary =~ "token="
    end
  end

  describe "a gate that returned no verdict is still retryable" do
    test "a hook timeout retries" do
      reason = {:post_turn_routing_failed, {:workspace_hook_timeout, "after_run", 120_000}}

      assert {:retryable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.retryable? == true
    end

    test "a transport failure reaching the hook host retries" do
      reason = {:post_turn_routing_failed, {:remote_command_failed, "worker-1", :network_error}}

      assert {:retryable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.retryable? == true
    end

    test "a gate that declares its own failure transient with the reserved exit status retries" do
      reason =
        {:post_turn_routing_failed, {:workspace_hook_failed, "after_run", 75, "ERROR: tracker unreachable, cannot evaluate"}}

      assert {:retryable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.retryable? == true
    end
  end

  describe "more specific hook families still win" do
    test "a gate whose own tooling is missing stays a missing-tool failure" do
      reason =
        {:post_turn_routing_failed, {:workspace_hook_failed, "after_run", 127, "symphony-post-turn-handoff-gate: command not found"}}

      assert {:irrecoverable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.family == :missing_required_tool_or_cli
    end

    test "a gate the runtime may not execute stays a permission failure" do
      reason =
        {:post_turn_routing_failed, {:workspace_hook_failed, "after_run", 126, "scripts/symphony-post-turn-handoff-gate: Permission denied"}}

      assert {:irrecoverable, failure} = AgentRuntime.classify_failure(reason, @context)
      assert failure.family == :permission_denied
    end
  end

  test "the family is a first-class irrecoverable family, not only a wrapped hook shape" do
    reason = {:post_turn_gate_rejected, %{subtype: "post_turn_gate_rejected", method: "after_run", message: "ERROR: rejected"}}

    assert {:irrecoverable, failure} = AgentRuntime.classify_failure(reason, @context)
    assert failure.family == :post_turn_gate_rejected
    assert failure.retryable? == false
  end

  test "a before_run hook failure is untouched by the post-turn classification" do
    reason = {:workspace_hook_failed, "before_run", 1, "ERROR: workspace not ready"}

    assert {:retryable, _failure} = AgentRuntime.classify_failure(reason, @context)
  end
end
