defmodule ElixirNawala.Telegram.Scheduler do
  use GenServer

  alias ElixirNawala.Monitor
  alias ElixirNawala.Workers.TelegramSummaryWorker

  @interval_ms 300_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_next(10_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    settings = Monitor.list_settings()

    if telegram_summary_enabled?(settings) do
      TelegramSummaryWorker.enqueue()
    end

    schedule_next(@interval_ms)
    {:noreply, state}
  end

  defp telegram_summary_enabled?(settings) do
    settings["telegram_notifications_enabled"] == "true" and
      ((settings["telegram_group_notifications_enabled"] == "true" and settings["telegram_group_chat_id"] not in [nil, ""]) or
         (settings["telegram_private_notifications_enabled"] == "true" and
            settings["telegram_private_chat_id"] not in [nil, ""]))
  end

  defp schedule_next(milliseconds) do
    Process.send_after(self(), :tick, milliseconds)
  end
end
