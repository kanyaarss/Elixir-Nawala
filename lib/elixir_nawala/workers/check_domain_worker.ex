defmodule ElixirNawala.Workers.CheckDomainWorker do
  use Oban.Worker, queue: :checker, max_attempts: 5

  alias ElixirNawala.Monitor
  alias ElixirNawala.Sflink.Client

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id} = args}) do
    token = Map.get(args, "api_token")

    case Monitor.get_domain(domain_id) do
      nil ->
        :discard

      domain ->
        previous_status = domain.last_status

        with {:ok, result} <- Client.fetch_domain_status(domain.name, token),
             {:ok, %{domain: updated_domain, changed?: changed?}} <-
               Monitor.record_domain_check(
                 domain,
                 result.status,
                 result.raw_payload,
                 result.latency_ms,
                 result.request_id
               ) do
          Monitor.broadcast_domain_updated(updated_domain)

          if changed? do
            Monitor.enqueue_domain_status_notifications(
              updated_domain,
              previous_status,
              updated_domain.last_status
            )
          end

          :ok
        else
          _ -> {:error, :check_failed}
        end
    end
  end

  def new_job(domain_id, token \\ nil) when is_integer(domain_id) do
    args =
      %{"domain_id" => domain_id}
      |> maybe_put_token(token)

    |> Oban.Job.new(
      worker: __MODULE__,
      queue: :checker,
      unique: [
        period: 60,
        fields: [:worker, :args],
        keys: ["domain_id"],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
  end

  defp maybe_put_token(args, token) when is_binary(token) and token != "" do
    Map.put(args, "api_token", token)
  end

  defp maybe_put_token(args, _token), do: args
end
