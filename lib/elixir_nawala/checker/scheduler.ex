defmodule ElixirNawala.Checker.Scheduler do
  use GenServer

  alias ElixirNawala.Monitor
  alias ElixirNawala.Workers.CheckerCycleWorker

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_next(1_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    CheckerCycleWorker.enqueue()
    schedule_next(Monitor.checker_interval_seconds() * 1_000)
    {:noreply, state}
  end

  defp schedule_next(milliseconds) do
    Process.send_after(self(), :tick, milliseconds)
  end
end
