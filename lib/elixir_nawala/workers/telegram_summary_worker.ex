defmodule ElixirNawala.Workers.TelegramSummaryWorker do
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias ElixirNawala.Telegram.Notifier

  @impl Oban.Worker
  def perform(_job) do
    case Notifier.send_periodic_summary() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue do
    %{}
    |> new(unique: [period: 240, fields: [:worker], states: [:available, :scheduled, :executing, :retryable]])
    |> Oban.insert()
  end
end
