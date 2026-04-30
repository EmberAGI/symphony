defmodule SymphonyElixir.TelegramNotifierTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Notifications.Telegram

  test "missing telegram config is a no-op" do
    parent = self()

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    assert :ok =
             Telegram.notify_human_review(issue,
               request_fun: fn request ->
                 send(parent, {:telegram_request, request})
                 {:ok, %Req.Response{status: 200}}
               end
             )

    refute_receive {:telegram_request, _request}
  end

  test "telegram event filters can disable human review sends" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id",
      telegram_events: ["other_event"]
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    assert :ok =
             Telegram.notify_human_review(issue,
               request_fun: fn request ->
                 send(parent, {:telegram_request, request})
                 {:ok, %Req.Response{status: 200}}
               end
             )

    refute_receive {:telegram_request, _request}
  end

  test "incomplete telegram config is a no-op" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(), telegram_bot_token: "bot-token")

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    assert :ok =
             Telegram.notify_human_review(issue,
               request_fun: fn request ->
                 send(parent, {:telegram_request, request})
                 {:ok, %Req.Response{status: 200}}
               end
             )

    refute_receive {:telegram_request, _request}
  end

  test "non-issue notification input is a no-op" do
    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    assert :ok =
             Telegram.notify_human_review(:not_an_issue,
               request_fun: fn _request -> flunk("request function should not be called") end
             )
  end

  test "successful telegram send includes issue context" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_endpoint: "https://telegram.example.test",
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id",
      telegram_message_thread_id: "42"
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    assert :ok =
             Telegram.notify_human_review(issue,
               request_fun: fn request ->
                 send(parent, {:telegram_request, request})
                 {:ok, %Req.Response{status: 200}}
               end
             )

    assert_receive {:telegram_request, request}
    assert request[:url] == "https://telegram.example.test/botbot-token/sendMessage"
    assert request[:json].chat_id == "chat-id"
    assert request[:json].message_thread_id == 42
    assert request[:json].disable_web_page_preview == true

    assert request[:json].text =~ "Issue: EMB-99"
    assert request[:json].text =~ "Title: Add telegram notification hooks for human review"
    assert request[:json].text =~ "State: Human Review"
    assert request[:json].text =~ "URL: https://linear.app/example/EMB-99"
  end

  test "agent failure notification is disabled unless the event is configured" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "In Progress",
      url: "https://linear.app/example/EMB-99"
    }

    assert :ok =
             Telegram.notify_agent_failed(issue, :timeout,
               request_fun: fn request ->
                 send(parent, {:telegram_request, request})
                 {:ok, %Req.Response{status: 200}}
               end
             )

    refute_receive {:telegram_request, _request}
  end

  test "agent failure notification includes issue context and reason" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_endpoint: "https://telegram.example.test",
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id",
      telegram_message_thread_id: "42",
      telegram_events: ["human_review", "agent_failed"]
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "In Progress",
      url: "https://linear.app/example/EMB-99"
    }

    assert :ok =
             Telegram.notify_agent_failed(issue, :timeout,
               request_fun: fn request ->
                 send(parent, {:telegram_request, request})
                 {:ok, %Req.Response{status: 200}}
               end
             )

    assert_receive {:telegram_request, request}
    assert request[:json].chat_id == "chat-id"
    assert request[:json].message_thread_id == 42
    assert request[:json].text =~ "Symphony agent failed"
    assert request[:json].text =~ "Issue: EMB-99"
    assert request[:json].text =~ "Title: Add telegram notification hooks for human review"
    assert request[:json].text =~ "State: In Progress"
    assert request[:json].text =~ "URL: https://linear.app/example/EMB-99"
    assert request[:json].text =~ "Reason: :timeout"
  end

  test "invalid telegram message thread id is omitted" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id",
      telegram_message_thread_id: "not-a-thread"
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    assert :ok =
             Telegram.notify_human_review(issue,
               request_fun: fn request ->
                 send(parent, {:telegram_request, request})
                 {:ok, %Req.Response{status: 200}}
               end
             )

    assert_receive {:telegram_request, request}
    refute Map.has_key?(request[:json], :message_thread_id)
  end

  test "general telegram topic id is omitted" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id",
      telegram_message_thread_id: "1"
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    assert :ok =
             Telegram.notify_human_review(issue,
               request_fun: fn request ->
                 send(parent, {:telegram_request, request})
                 {:ok, %Req.Response{status: 200}}
               end
             )

    assert_receive {:telegram_request, request}
    refute Map.has_key?(request[:json], :message_thread_id)
  end

  test "raised agent failure reasons are redacted to the exception module" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id",
      telegram_events: ["agent_failed"]
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "In Progress",
      url: "https://linear.app/example/EMB-99"
    }

    assert :ok =
             Telegram.notify_agent_failed(issue, {%RuntimeError{message: "hidden details"}, []},
               request_fun: fn request ->
                 send(parent, {:telegram_request, request})
                 {:ok, %Req.Response{status: 200}}
               end
             )

    assert_receive {:telegram_request, request}
    assert request[:json].text =~ "Reason: RuntimeError"
    refute request[:json].text =~ "hidden details"
  end

  test "telegram request failures are logged and do not raise" do
    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    log =
      capture_log(fn ->
        assert :ok =
                 Telegram.notify_human_review(issue,
                   request_fun: fn _request -> {:error, :timeout} end
                 )
      end)

    assert log =~ "Telegram notification request failed"
  end

  test "telegram request failure reasons are redacted by shape" do
    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    binary_log =
      capture_log(fn ->
        assert :ok =
                 Telegram.notify_human_review(issue,
                   request_fun: fn _request -> {:error, "temporary failure"} end
                 )
      end)

    struct_log =
      capture_log(fn ->
        assert :ok =
                 Telegram.notify_human_review(issue,
                   request_fun: fn _request -> {:error, %RuntimeError{message: "hidden details"}} end
                 )
      end)

    fallback_log =
      capture_log(fn ->
        assert :ok =
                 Telegram.notify_human_review(issue,
                   request_fun: fn _request -> {:error, %{reason: "hidden details"}} end
                 )
      end)

    assert binary_log =~ "temporary failure"
    assert struct_log =~ "RuntimeError"
    assert fallback_log =~ "request failed"
  end

  test "telegram response errors are logged and do not raise" do
    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    log =
      capture_log(fn ->
        assert :ok =
                 Telegram.notify_human_review(issue,
                   request_fun: fn _request -> {:ok, %Req.Response{status: 500}} end
                 )
      end)

    assert log =~ "Telegram notification failed with status=500"
  end

  test "unexpected telegram request result is logged and does not raise" do
    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    log =
      capture_log(fn ->
        assert :ok =
                 Telegram.notify_human_review(issue,
                   request_fun: fn _request -> :unexpected end
                 )
      end)

    assert log =~ "Telegram notification request returned unexpected result"
  end

  test "raised telegram request is logged and does not raise" do
    write_workflow_file!(Workflow.workflow_file_path(),
      telegram_bot_token: "bot-token",
      telegram_chat_id: "chat-id"
    )

    issue = %Issue{
      identifier: "EMB-99",
      title: "Add telegram notification hooks for human review",
      state: "Human Review",
      url: "https://linear.app/example/EMB-99"
    }

    log =
      capture_log(fn ->
        assert :ok =
                 Telegram.notify_human_review(issue,
                   request_fun: fn _request -> raise RuntimeError, "hidden details" end
                 )
      end)

    assert log =~ "Telegram notification request raised"
    assert log =~ "RuntimeError"
  end
end
