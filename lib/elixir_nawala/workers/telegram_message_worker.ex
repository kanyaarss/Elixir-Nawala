defmodule ElixirNawala.Workers.TelegramMessageWorker do
  use Oban.Worker, queue: :notifications, max_attempts: 5
  alias ElixirNawala.Monitor
  alias ElixirNawala.Telegram.Notifier

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"target" => target, "message" => message} = args
      })
      when target in ["group", "private"] do
    target =
      case target do
        "group" -> :group
        "private" -> :private
      end

    case Notifier.send_test_message(target, message) do
      :ok ->
        maybe_mark_notification(args["notification_id"], "sent")
        :ok

      {:error, reason} ->
        maybe_mark_notification(args["notification_id"], "failed")
        {:error, reason}
    end
  end

  defp maybe_mark_notification(nil, _status), do: :ok
  defp maybe_mark_notification(id, status), do: Monitor.update_notification_status(id, status)
end
