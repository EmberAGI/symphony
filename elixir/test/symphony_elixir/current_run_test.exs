defmodule SymphonyElixir.CurrentRunTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Runtime.CurrentRun

  test "an exact-identity envelope cannot claim ingress newer than producer observation" do
    current_run = current_run()
    observed_watermark = CurrentRun.activity_ms(current_run)
    Process.sleep(2)

    forged_envelope =
      current_run
      |> CurrentRun.envelope()
      |> Map.put(:ingress_at_ms, System.monotonic_time(:millisecond))

    assert CurrentRun.accept_ingress(current_run, forged_envelope) == :invalid
    assert CurrentRun.activity_ms(current_run) == observed_watermark
  end

  defp current_run do
    issue = %Issue{id: "issue-current-run-ingress", identifier: "TUR-878-INGRESS"}

    CurrentRun.new(issue, %{
      workspace_path: "/tmp/tur-878-ingress",
      role: "implementer",
      holder: "test-holder",
      run_id: "test-run-ingress"
    })
  end
end
