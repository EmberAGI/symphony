defmodule SymphonyElixir.TrackerEscalationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker.{EscalationMarker, Memory}

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_fail_mutations)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  test "repeated escalation delivery creates one note and reconciles label and state once" do
    issue_id = "issue-escalation-repeat-#{System.unique_integer([:positive])}"
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: issue_id, state: "In Progress"}])

    assert {:ok, first} = Memory.ensure_irrecoverable_escalation(issue_id, escalation_attrs())
    assert {:ok, second} = Memory.ensure_irrecoverable_escalation(issue_id, escalation_attrs())

    assert first.comment == :created
    assert first.label == :applied
    assert first.state == :applied
    assert second.comment == :already_present
    assert second.label == :already_present
    assert second.state == :already_present

    assert_receive {:memory_tracker_comment, ^issue_id, body}
    assert body =~ "symphony-irrecoverable-escalation:v1"
    assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}
    refute_receive {:memory_tracker_comment, ^issue_id, _body}, 100
    refute_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 100
    refute_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}, 100
  end

  test "a process restart reuses the failure fingerprint identity for the retry epoch" do
    issue_id = "issue-escalation-restart-#{System.unique_integer([:positive])}"
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: issue_id, state: "In Progress"}])

    assert {:ok, first} = Memory.ensure_irrecoverable_escalation(issue_id, escalation_attrs())
    assert {:ok, [durable_issue]} = Memory.fetch_issue_states_by_ids([issue_id])

    restarted_recipient =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [durable_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, restarted_recipient)

    assert {:ok, restarted} =
             Memory.ensure_irrecoverable_escalation(
               issue_id,
               Map.put(escalation_attrs(), :run_id, "run-after-process-restart")
             )

    send(restarted_recipient, :stop)

    assert first.comment == :created
    assert restarted.comment == :already_present
    assert first.key == restarted.key

    assert_receive {:memory_tracker_comment, ^issue_id, _body}
    refute_receive {:memory_tracker_comment, ^issue_id, _body}, 100
  end

  test "concurrent delivery creates at most one note and one label/state mutation" do
    issue_id = "issue-escalation-concurrent-#{System.unique_integer([:positive])}"
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: issue_id, state: "In Progress"}])

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Memory.ensure_irrecoverable_escalation(issue_id, escalation_attrs()) end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Enum.count(results, fn {:ok, result} -> result.comment == :created end) == 1
    assert Enum.count(results, fn {:ok, result} -> result.comment == :already_present end) == 7

    assert_receive {:memory_tracker_comment, ^issue_id, _body}
    assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}
    refute_receive {:memory_tracker_comment, ^issue_id, _body}, 100
    refute_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}, 100
    refute_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}, 100
  end

  test "partial mutation failure resumes only missing mutations" do
    issue_id = "issue-escalation-partial-#{System.unique_integer([:positive])}"
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: issue_id, state: "In Progress"}])

    Application.put_env(:symphony_elixir, :memory_tracker_fail_mutations, %{
      label: :label_down,
      state: :state_down
    })

    assert {:error, first_failure} =
             Memory.ensure_irrecoverable_escalation(issue_id, escalation_attrs())

    assert first_failure.progress.comment == :created
    assert first_failure.progress.label == {:error, :label_down}
    assert first_failure.progress.state == {:error, :state_down}

    Application.delete_env(:symphony_elixir, :memory_tracker_fail_mutations)

    assert {:ok, resumed} = Memory.ensure_irrecoverable_escalation(issue_id, escalation_attrs())
    assert resumed.comment == :already_present
    assert resumed.label == :applied
    assert resumed.state == :applied

    assert {:ok, [%Issue{} = updated_issue]} = Memory.fetch_issue_states_by_ids([issue_id])
    assert updated_issue.state == "Human Escalation"
    assert "Human Escalation" in updated_issue.labels
    assert Enum.any?(updated_issue.comments, &(&1.body =~ "symphony-irrecoverable-escalation:v1"))

    assert_receive {:memory_tracker_comment, ^issue_id, _body}
    assert_receive {:memory_tracker_label_add, ^issue_id, "Human Escalation"}
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Escalation"}
    refute_receive {:memory_tracker_comment, ^issue_id, _body}, 100
  end

  test "escalation markers redact credential fields before tracker persistence" do
    attrs =
      escalation_attrs()
      |> Map.put(
        :operator_note,
        ~s(## Operator Note\n\n{"api_key":"raw-api-key","refresh_token":"raw-refresh"} bearer raw-bearer)
      )

    assert {:ok, marker} = EscalationMarker.new(attrs)
    rendered = EscalationMarker.render(marker)

    assert rendered =~ "[REDACTED]"
    refute rendered =~ "raw-api-key"
    refute rendered =~ "raw-refresh"
    refute rendered =~ "raw-bearer"
  end

  defp escalation_attrs do
    %{
      failure_fingerprint: "fingerprint-1",
      retry_epoch: "epoch-1",
      run_id: "run-1",
      operator_note: "## Operator Note\n\nredacted failure"
    }
  end
end
