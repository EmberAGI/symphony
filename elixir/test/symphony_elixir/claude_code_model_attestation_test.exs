defmodule SymphonyElixir.ClaudeCodeModelAttestationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.ModelAttestation

  test "accepts only canonical alias and dated-build equivalence" do
    assert :ok = ModelAttestation.verify("fable", "claude-fable-5")
    assert :ok = ModelAttestation.verify("opus", "claude-opus-5")
    assert :ok = ModelAttestation.verify("claude-opus-4-8", "claude-opus-4-8-20260801")
    assert :ok = ModelAttestation.verify("us.anthropic.claude-sonnet-4-6", "claude-sonnet-4-6")
  end

  test "rejects a different family even when both identities are valid" do
    assert {:error, {:claude_model_mismatched, %{requested_model: "fable", observed_model: "claude-sonnet-5"}}} =
             ModelAttestation.verify("fable", "claude-sonnet-5")
  end

  test "distinguishes missing and malformed observed identities" do
    assert {:error, {:claude_model_missing, %{observed_model: nil}}} =
             ModelAttestation.verify("claude-fable-5", nil)

    assert {:error, {:claude_model_malformed, %{observed_model: "Fable Five"}}} =
             ModelAttestation.verify("claude-fable-5", "Fable Five")
  end
end
