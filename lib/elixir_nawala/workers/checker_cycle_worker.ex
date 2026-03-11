defmodule ElixirNawala.Workers.CheckerCycleWorker do
  use Oban.Worker, queue: :checker, max_attempts: 1

  alias ElixirNawala.Monitor
  alias ElixirNawala.Workers.CheckDomainWorker

  @impl Oban.Worker
  def perform(_job) do
    domains = Monitor.list_active_domains()
    tokens = Monitor.list_active_sflink_tokens()

    if tokens == [] do
      error_message =
        "Checker cycle dibatalkan karena tidak ada SFLINK API token aktif. Periksa konfigurasi profile/token pada menu Admin."

      Monitor.enqueue_program_error_notification(error_message)

      Monitor.broadcast_checker_cycle(%{
        active_domains: length(domains),
        enqueued_at: DateTime.utc_now(),
        error: "Tidak ada SFLINK API token aktif."
      })
    else
      token_count = length(tokens)

      domains
      |> Enum.with_index()
      |> Enum.each(fn {domain, index} ->
        token = Enum.at(tokens, rem(index, token_count))

        domain.id
        |> CheckDomainWorker.new_job(token)
        |> Oban.insert()
      end)

      Monitor.broadcast_checker_cycle(%{
        active_domains: length(domains),
        active_tokens: token_count,
        enqueued_at: DateTime.utc_now()
      })

      Monitor.enqueue_telegram_summary_notification()
    end

    :ok
  end

  def enqueue do
    %{}
    |> new(unique: [period: 55, fields: [:worker], states: [:available, :scheduled, :executing, :retryable]])
    |> Oban.insert()
  end
end
