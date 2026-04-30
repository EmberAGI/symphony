defmodule SymphonyElixir.Notifications.Telegram do
  @moduledoc """
  Best-effort Telegram notifications for workflow events that need human attention.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @human_review_event "human_review"
  @agent_failed_event "agent_failed"

  @spec notify_human_review(term(), keyword()) :: :ok
  def notify_human_review(issue, opts \\ []) do
    with %Issue{} = issue <- issue,
         {:ok, settings} <- enabled_settings(@human_review_event) do
      send_message(settings, human_review_message(issue), opts)
    else
      _ -> :ok
    end
  end

  @spec notify_agent_failed(term(), term(), keyword()) :: :ok
  def notify_agent_failed(issue, reason, opts \\ []) do
    with %Issue{} = issue <- issue,
         {:ok, settings} <- enabled_settings(@agent_failed_event) do
      send_message(settings, agent_failed_message(issue, reason), opts)
    else
      _ -> :ok
    end
  end

  defp telegram_settings do
    Config.settings!().notifications.telegram
  end

  defp enabled_settings(event) do
    with %{bot_token: bot_token, chat_id: chat_id, events: events} = settings <- telegram_settings(),
         true <- configured?(bot_token),
         true <- configured?(chat_id),
         true <- event in events do
      {:ok, settings}
    else
      _ -> :disabled
    end
  end

  defp configured?(value) when is_binary(value), do: String.trim(value) != ""
  defp configured?(_value), do: false

  defp send_message(settings, text, opts) do
    request_fun =
      Keyword.get(opts, :request_fun) ||
        Application.get_env(:symphony_elixir, :telegram_request_fun, &Req.post/1)

    request = [
      url: telegram_send_message_url(settings.endpoint, settings.bot_token),
      json:
        %{
          chat_id: settings.chat_id,
          text: text,
          disable_web_page_preview: true
        }
        |> maybe_put_message_thread_id(settings.message_thread_id)
    ]

    case request_fun.(request) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("Telegram notification failed with status=#{status}")
        :ok

      {:error, reason} ->
        Logger.warning("Telegram notification request failed: #{failure_reason(reason)}")
        :ok

      other ->
        Logger.warning("Telegram notification request returned unexpected result: #{inspect(other)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Telegram notification request raised: #{inspect(error.__struct__)}")
      :ok
  end

  defp telegram_send_message_url(endpoint, bot_token) do
    endpoint = endpoint || "https://api.telegram.org"
    "#{String.trim_trailing(endpoint, "/")}/bot#{bot_token}/sendMessage"
  end

  defp maybe_put_message_thread_id(json, nil), do: json

  defp maybe_put_message_thread_id(json, message_thread_id) when is_binary(message_thread_id) do
    case Integer.parse(String.trim(message_thread_id)) do
      {thread_id, ""} when thread_id > 1 -> Map.put(json, :message_thread_id, thread_id)
      _ -> json
    end
  end

  defp human_review_message(%Issue{} = issue) do
    [
      "Symphony needs human review",
      "Issue: #{issue.identifier}",
      "Title: #{issue.title}",
      "State: #{issue.state}",
      "URL: #{issue.url}"
    ]
    |> Enum.join("\n")
  end

  defp agent_failed_message(%Issue{} = issue, reason) do
    [
      "Symphony agent failed",
      "Issue: #{issue.identifier}",
      "Title: #{issue.title}",
      "State: #{issue.state}",
      "URL: #{issue.url}",
      "Reason: #{failure_reason(reason)}"
    ]
    |> Enum.join("\n")
  end

  defp failure_reason({%{__struct__: module}, _stacktrace}), do: inspect(module)
  defp failure_reason(%{__struct__: module}), do: inspect(module)
  defp failure_reason(reason) when is_atom(reason), do: inspect(reason)
  defp failure_reason(reason) when is_binary(reason), do: reason
  defp failure_reason(_reason), do: "request failed"
end
