defmodule SymphonyElixir.RunLogTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias SymphonyElixir.RunLog

  setup do
    previous_run_log_root = Application.get_env(:symphony_elixir, :run_log_root)

    on_exit(fn ->
      case previous_run_log_root do
        nil -> Application.delete_env(:symphony_elixir, :run_log_root)
        root -> Application.put_env(:symphony_elixir, :run_log_root, root)
      end
    end)

    :ok
  end

  test "irrecoverable runtime failure run log noops without a usable root and run id" do
    Application.delete_env(:symphony_elixir, :run_log_root)

    assert :ok =
             RunLog.record_irrecoverable_runtime_failure(
               "issue-no-root",
               %{identifier: "MT-NO-ROOT", run_id: "run-no-root"},
               nil,
               %{family: :permission_denied, retry_reason: "permission_denied"}
             )

    Application.put_env(:symphony_elixir, :run_log_root, "")

    assert :ok =
             RunLog.record_irrecoverable_runtime_failure(
               "issue-empty-root",
               %{identifier: "MT-EMPTY-ROOT", run_id: "run-empty-root"},
               nil,
               %{family: :permission_denied, retry_reason: "permission_denied"}
             )

    run_log_root = Path.join(System.tmp_dir!(), "symphony-run-log-noop-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :run_log_root, run_log_root)

    assert :ok =
             RunLog.record_irrecoverable_runtime_failure(
               "issue-no-run",
               %{identifier: "MT-NO-RUN"},
               nil,
               %{family: :permission_denied, retry_reason: "permission_denied"}
             )

    refute File.exists?(run_log_root)
  end

  test "irrecoverable runtime failure run log writes redacted string family payloads" do
    run_log_root = Path.join(System.tmp_dir!(), "symphony-run-log-write-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :run_log_root, run_log_root)

    process_ownership = %{
      issue_identifier: "MT-RUN-LOG-IRRECOVERABLE",
      run_id: "run-irrecoverable",
      state: "blocked"
    }

    assert :ok =
             RunLog.record_irrecoverable_runtime_failure(
               "issue-irrecoverable",
               %{run_id: "ignored", retry_attempt: 4},
               process_ownership,
               %{
                 family: "permission_denied",
                 provider: nil,
                 retry_reason: "permission_denied bearer raw-token",
                 recovery_reason: "permission-denied-repair-required"
               }
             )

    run_log_path = Path.join([run_log_root, "MT-RUN-LOG-IRRECOVERABLE", "run-irrecoverable.jsonl"])
    assert File.exists?(run_log_path)

    [event] =
      run_log_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert event["event"] == "irrecoverable_runtime_failure_escalated"
    assert event["issue_identifier"] == "MT-RUN-LOG-IRRECOVERABLE"
    assert event["failure"]["family"] == "permission_denied"
    assert event["failure"]["provider"] == nil
    assert event["failure"]["reason"] == "permission_denied Bearer [REDACTED]"
    assert event["failure"]["claim_lease_state"] == "blocked"

    File.rm_rf(run_log_root)
  end

  test "irrecoverable runtime failure run log write errors are visible but non-fatal" do
    run_log_root = Path.join(System.tmp_dir!(), "symphony-run-log-file-#{System.unique_integer([:positive])}")
    File.write!(run_log_root, "not a directory")
    Application.put_env(:symphony_elixir, :run_log_root, run_log_root)

    log =
      capture_log(fn ->
        assert :ok =
                 RunLog.record_irrecoverable_runtime_failure(
                   "issue-write-error",
                   %{identifier: "MT-WRITE-ERROR", run_id: "run-write-error"},
                   nil,
                   %{family: :permission_denied, retry_reason: "permission_denied"}
                 )
      end)

    assert log =~ "Failed to write irrecoverable run log artifact"

    File.rm_rf(run_log_root)
  end

  test "agent retry run log write errors are visible but non-fatal" do
    run_log_root = Path.join(System.tmp_dir!(), "symphony-run-log-retry-file-#{System.unique_integer([:positive])}")
    File.write!(run_log_root, "not a directory")
    Application.put_env(:symphony_elixir, :run_log_root, run_log_root)

    log =
      capture_log(fn ->
        assert :ok =
                 RunLog.record_agent_retry_scheduled(
                   "issue-retry-write-error",
                   %{identifier: "MT-RETRY-WRITE-ERROR", run_id: "run-retry-write-error"},
                   nil,
                   %{attempt: 1},
                   %{attempt: 1}
                 )
      end)

    assert log =~ "Failed to write run log artifact"

    File.rm_rf(run_log_root)
  end

  test "run log falls back to issue id segments and preserves JSON-safe non-binary summaries" do
    run_log_root = Path.join(System.tmp_dir!(), "symphony-run-log-fallback-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :run_log_root, run_log_root)

    assert :ok =
             RunLog.record_agent_retry_scheduled(
               "._-",
               %{run_id: "retry-fallback", error: 404},
               nil,
               %{attempt: 2},
               %{attempt: 2}
             )

    retry_path = Path.join([run_log_root, "unknown", "retry-fallback.jsonl"])
    assert File.exists?(retry_path)

    [retry_event] =
      retry_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert retry_event["issue_identifier"] == "._-"
    assert retry_event["reason"] == 404

    assert :ok =
             RunLog.record_irrecoverable_runtime_failure(
               "MT-FALLBACK",
               %{run_id: "irrecoverable-fallback"},
               nil,
               %{family: 123, provider: 456, retry_reason: 500}
             )

    irrecoverable_path = Path.join([run_log_root, "MT-FALLBACK", "irrecoverable-fallback.jsonl"])
    assert File.exists?(irrecoverable_path)

    [irrecoverable_event] =
      irrecoverable_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert irrecoverable_event["failure"]["family"] == nil
    assert irrecoverable_event["failure"]["provider"] == nil
    assert irrecoverable_event["failure"]["reason"] == 500

    File.rm_rf(run_log_root)
  end
end
