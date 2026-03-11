defmodule ElixirNawala.Shortlink do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias ElixirNawala.Monitor
  alias ElixirNawala.Monitor.Domain
  alias ElixirNawala.Repo
  alias ElixirNawala.Shortlink.{ShortLink, ShortLinkClick, ShortLinkRotator, ShortLinkRotatorDomain}

  @random_slug_size 7
  @max_random_attempts 8

  def create_short_link(attrs, admin_id, allowed_domains \\ [])
      when is_map(attrs) and is_integer(admin_id) and is_list(allowed_domains) do
    attrs =
      attrs
      |> normalize_create_attrs()
      |> Map.put("created_by_admin_id", admin_id)

    if destination_allowed?(attrs["destination_url"], allowed_domains) do
      %ShortLink{}
      |> ShortLink.changeset(attrs)
      |> Repo.insert()
    else
      {:error, :invalid_destination_domain}
    end
  end

  def delete_short_link(short_link_id) when is_integer(short_link_id) do
    case Repo.get(ShortLink, short_link_id) do
      nil ->
        {:error, :not_found}

      short_link ->
        Repo.transaction(fn ->
          # Delete associated data
          Repo.delete_all(from(c in ShortLinkClick, where: c.short_link_id == ^short_link_id))
          Repo.delete_all(from(r in ShortLinkRotator, where: r.short_link_id == ^short_link_id))
          # Delete the shortlink itself
          {:ok, deleted} = Repo.delete(short_link)
          deleted
        end)
        |> case do
          {:ok, deleted} -> {:ok, deleted}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def list_short_links(query \\ "") do
    normalized_query = normalize_query(query)

    links =
      ShortLink
      |> order_by([l], desc: l.inserted_at)
      |> Repo.all()

    case normalized_query do
      "" ->
        links

      _ ->
        candidates = query_candidates(normalized_query)

        links
        |> Enum.map(fn link -> {link, shortlink_match_score(link, candidates)} end)
        |> Enum.filter(fn {_link, score} -> score > 0.0 end)
        |> Enum.sort_by(fn {link, score} ->
          {-score, -(link.click_count || 0), -unix_timestamp(link.inserted_at)}
        end)
        |> Enum.map(&elem(&1, 0))
    end
  end

  def list_recent_clicks(limit \\ 50) when is_integer(limit) and limit > 0 do
    ShortLinkClick
    |> join(:inner, [c], l in assoc(c, :short_link))
    |> preload([_c, l], short_link: l)
    |> order_by([c], desc: c.clicked_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_stats do
    total_links = Repo.aggregate(ShortLink, :count, :id)
    active_links = Repo.aggregate(from(l in ShortLink, where: l.active == true), :count, :id)

    total_clicks =
      ShortLink
      |> select([l], sum(l.click_count))
      |> Repo.one()
      |> Kernel.||(0)

    top_links =
      ShortLink
      |> order_by([l], desc: l.click_count)
      |> limit(10)
      |> Repo.all()

    today_start = Date.utc_today()

    today_clicks =
      ShortLinkClick
      |> where([c], fragment("?::date >= ?", c.clicked_at, ^today_start))
      |> Repo.aggregate(:count, :id)

    %{
      total_links: total_links,
      active_links: active_links,
      total_clicks: total_clicks,
      today_clicks: today_clicks,
      top_links: top_links
    }
  end

  def update_redirect_type(id, redirect_type) when is_integer(id) and redirect_type in [301, 302] do
    case Repo.get(ShortLink, id) do
      nil ->
        {:error, :not_found}

      %ShortLink{} = short_link ->
        short_link
        |> ShortLink.redirect_type_changeset(%{redirect_type: redirect_type})
        |> Repo.update()
    end
  end

  def update_primary_destination(id, destination_domain, allowed_domains \\ [])
      when is_integer(id) and is_binary(destination_domain) and is_list(allowed_domains) do
    case Repo.get(ShortLink, id) do
      nil ->
        {:error, :not_found}

      %ShortLink{} = short_link ->
        normalized_domain = normalize_domain_value(destination_domain)
        next_destination_url = build_destination_url(short_link.destination_url, normalized_domain)

        cond do
          normalized_domain == "" ->
            {:error, :invalid_destination_domain}

          allowed_domains != [] and not destination_allowed?(next_destination_url, allowed_domains) ->
            {:error, :invalid_destination_domain}

          true ->
            short_link
            |> ShortLink.changeset(%{"destination_url" => next_destination_url})
            |> Repo.update()
        end
    end
  end

  def get_active_by_slug(slug) when is_binary(slug) do
    normalized = slug |> String.trim() |> String.downcase()

    case Repo.get_by(ShortLink, slug: normalized, active: true) |> preload_rotator() do
      nil -> {:error, :not_found}
      %ShortLink{} = short_link -> {:ok, short_link}
    end
  end

  def resolve_destination_url(%ShortLink{} = short_link) do
    primary_url = short_link.destination_url
    primary_host = normalize_domain_value(primary_url)

    cond do
      primary_host == "" ->
        primary_url

      not primary_domain_blocked_now?(primary_host) ->
        primary_url

      true ->
        case pick_rotator_domain(short_link, primary_host) do
          nil ->
            primary_url

          fallback_domain ->
            replace_destination_host(primary_url, fallback_domain.name)
        end
    end
  end

  def list_rotator_configs(query \\ "") do
    list_short_links(query)
    |> Repo.preload(rotator: [rotator_domains: :domain])
  end

  def new_rotator_form_defaults do
    %{
      "short_link_id" => "",
      "enabled" => "true",
      "fallback_domain_ids" => []
    }
  end

  def save_rotator_config(attrs) when is_map(attrs) do
    with {short_link_id, _} <- attrs |> Map.get("short_link_id", "") |> to_string() |> Integer.parse(),
         %ShortLink{} = short_link <- Repo.get(ShortLink, short_link_id) |> preload_rotator() do
      fallback_domain_ids = parse_domain_ids(Map.get(attrs, "fallback_domain_ids", []))
      primary_host = normalize_domain_value(short_link.destination_url)

      domain_ids =
        fallback_domain_ids
        |> Enum.uniq()
        |> Enum.filter(fn domain_id ->
          case Repo.get(Domain, domain_id) do
            %Domain{name: name} -> normalize_domain_value(name) != primary_host
            _ -> false
          end
        end)

      enabled =
        attrs
        |> Map.get("enabled", "false")
        |> to_string()
        |> Kernel.==("true")

      Multi.new()
      |> Multi.run(:rotator, fn repo, _changes ->
        save_or_create_rotator(repo, short_link, enabled)
      end)
      |> Multi.run(:delete_old_domains, fn repo, %{rotator: rotator} ->
        repo.delete_all(from(rd in ShortLinkRotatorDomain, where: rd.rotator_id == ^rotator.id))
        {:ok, :deleted}
      end)
      |> Multi.merge(fn %{rotator: rotator} ->
        insert_rotator_domains_multi(rotator.id, domain_ids)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} -> {:ok, :saved}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_shortlink}
    end
  end

  def record_click(%ShortLink{} = short_link, attrs \\ %{}) when is_map(attrs) do
    clicked_at = DateTime.utc_now()

    Multi.new()
    |> Multi.update_all(
      :increment_link,
      from(l in ShortLink, where: l.id == ^short_link.id),
      [inc: [click_count: 1], set: [last_clicked_at: clicked_at]]
    )
    |> Multi.insert(
      :insert_click,
      ShortLinkClick.changeset(%ShortLinkClick{}, %{
        short_link_id: short_link.id,
        ip_address: Map.get(attrs, :ip_address),
        user_agent: Map.get(attrs, :user_agent),
        referrer: Map.get(attrs, :referrer),
        clicked_at: clicked_at
      })
    )
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def short_url_for_slug(slug) when is_binary(slug) do
    base = ElixirNawalaWeb.Endpoint.url()
    "#{String.trim_trailing(base, "/")}/#{slug}"
  end

  def new_short_link_form_defaults(domain_names \\ []) do
    destination_url =
      case normalize_allowed_domains(domain_names) do
        [first | _] -> "https://#{first}"
        _ -> ""
      end

    %{
      "destination_url" => destination_url,
      "slug" => "",
      "redirect_type" => "302"
    }
  end

  def random_slug do
    1..@max_random_attempts
    |> Enum.find_value(fn _ ->
      candidate = generate_slug()

      if Repo.exists?(from(l in ShortLink, where: l.slug == ^candidate)) do
        nil
      else
        candidate
      end
    end)
    |> Kernel.||("#{generate_slug()}#{:rand.uniform(9)}")
  end

  defp generate_slug do
    :crypto.strong_rand_bytes(@random_slug_size)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, @random_slug_size)
    |> String.downcase()
  end

  defp normalize_create_attrs(attrs) do
    destination_url =
      attrs
      |> Map.get("destination_url", "")
      |> to_string()
      |> String.trim()

    incoming_slug =
      attrs
      |> Map.get("slug", "")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    slug = if incoming_slug == "", do: random_slug(), else: incoming_slug

    redirect_type =
      attrs
      |> Map.get("redirect_type", "302")
      |> to_string()
      |> Integer.parse()
      |> case do
        {value, _} when value in [301, 302] -> value
        _ -> 302
      end

    %{
      "destination_url" => destination_url,
      "slug" => slug,
      "redirect_type" => redirect_type
    }
  end

  defp normalize_query(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_query(_), do: ""

  defp query_candidates(query) when is_binary(query) do
    cleaned =
      query
      |> String.trim()
      |> String.downcase()

    without_scheme =
      cleaned
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")

    without_www = String.trim_leading(without_scheme, "www.")
    host_only = without_www |> String.split("/", parts: 2) |> hd() |> to_string()

    [cleaned, without_scheme, without_www, host_only]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp query_candidates(_), do: []

  defp shortlink_match_score(link, candidates) when is_map(link) and is_list(candidates) do
    slug =
      link
      |> Map.get(:slug, "")
      |> to_string()
      |> normalize_query()

    destination =
      link
      |> Map.get(:destination_url, "")
      |> to_string()
      |> normalize_query()

    destination_host = normalize_domain_value(destination)

    slug_score = text_match_score(slug, candidates, 9.0, 7.0, 5.0)
    destination_score = text_match_score(destination, candidates, 7.0, 5.0, 3.5)
    host_score = text_match_score(destination_host, candidates, 6.5, 4.8, 3.2)
    fuzzy_score = fuzzy_match_score(slug, destination_host, candidates)

    max(max(slug_score, destination_score), max(host_score, fuzzy_score))
  end

  defp shortlink_match_score(_, _), do: 0.0

  defp text_match_score(text, candidates, exact_score, prefix_score, contains_score)
       when is_binary(text) and is_list(candidates) do
    Enum.reduce(candidates, 0.0, fn candidate, acc ->
      score =
        cond do
          text == candidate -> exact_score
          String.starts_with?(text, candidate) -> prefix_score
          String.contains?(text, candidate) -> contains_score
          true -> 0.0
        end

      max(acc, score)
    end)
  end

  defp text_match_score(_, _, _, _, _), do: 0.0

  defp fuzzy_match_score(slug, destination_host, candidates)
       when is_binary(slug) and is_binary(destination_host) and is_list(candidates) do
    Enum.reduce(candidates, 0.0, fn candidate, acc ->
      similarity =
        max(
          String.jaro_distance(slug, candidate),
          String.jaro_distance(destination_host, candidate)
        )

      score = if similarity >= 0.86, do: similarity * 2.0, else: 0.0
      max(acc, score)
    end)
  end

  defp fuzzy_match_score(_, _, _), do: 0.0

  defp unix_timestamp(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp unix_timestamp(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
  end

  defp unix_timestamp(_), do: 0

  defp preload_rotator(nil), do: nil

  defp preload_rotator(%ShortLink{} = short_link) do
    Repo.preload(short_link, rotator: [rotator_domains: :domain])
  end

  defp domain_by_name(name) when is_binary(name) do
    normalized = normalize_domain_value(name)

    Repo.one(
      from(d in Domain,
        where: d.name == ^normalized or d.name == ^("www." <> normalized),
        limit: 1
      )
    )
  end

  defp domain_by_name(_), do: nil

  defp domain_blocked?(%Domain{} = domain) do
    status =
      domain
      |> Map.get(:last_status, "")
      |> to_string()
      |> String.downcase()

    status in ["down", "nawala", "error", "blocked"]
  end

  defp domain_blocked?(_), do: false

  defp domain_blocked_now?(%Domain{} = domain) do
    host =
      domain
      |> Map.get(:name, "")
      |> to_string()
      |> normalize_domain_value()

    domain_blocked?(domain) or remote_domain_blocked_by_host?(host)
  end

  defp domain_blocked_now?(_), do: false

  defp primary_domain_blocked_now?(primary_host) when is_binary(primary_host) do
    case domain_by_name(primary_host) do
      %Domain{} = domain ->
        domain_blocked_now?(domain)

      nil ->
        remote_domain_blocked_by_host?(primary_host)
    end
  end

  defp primary_domain_blocked_now?(_), do: false

  defp remote_domain_blocked_by_host?(host) when is_binary(host) do
    normalized_host = normalize_domain_value(host)

    case Monitor.list_remote_domains() do
      {:ok, remote_domains} when is_list(remote_domains) ->
        remote_domains
        |> Enum.find(fn rd ->
          rd.domain
          |> to_string()
          |> normalize_domain_value()
          |> Kernel.==(normalized_host)
        end)
        |> case do
          %{status: status} ->
            status_indicates_blocked?(status)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp remote_domain_blocked_by_host?(_), do: false

  defp status_indicates_blocked?(status) do
    normalized_status =
      status
      |> to_string()
      |> String.trim()
      |> String.downcase()

    normalized_status in ["blocked", "nawala", "down", "error", "failed", "false", "diblokir"]
  end

  defp pick_rotator_domain(%ShortLink{} = short_link, primary_host) do
    rotator =
      short_link
      |> preload_rotator()
      |> Map.get(:rotator)

    cond do
      is_nil(rotator) or rotator.enabled != true ->
        nil

      true ->
        rotator.rotator_domains
        |> Enum.sort_by(& &1.priority)
        |> Enum.map(& &1.domain)
        |> Enum.find(fn
          %Domain{} = domain ->
            host = normalize_domain_value(domain.name)
            host != "" and host != primary_host and domain.active == true and not domain_blocked_now?(domain)

          _ ->
            false
        end)
    end
  end

  defp replace_destination_host(url, host) when is_binary(url) and is_binary(host) do
    case URI.parse(url) do
      %URI{} = uri ->
        %{uri | host: host}
        |> URI.to_string()

      _ ->
        url
    end
  end

  defp build_destination_url(current_url, host) when is_binary(current_url) and is_binary(host) do
    host = normalize_domain_value(host)

    case URI.parse(current_url) do
      %URI{host: current_host} = uri when is_binary(current_host) and current_host != "" ->
        %{uri | host: host}
        |> URI.to_string()

      %URI{} = uri ->
        %URI{uri | scheme: uri.scheme || "https", host: host, path: uri.path || "/"}
        |> URI.to_string()

      _ ->
        "https://#{host}"
    end
  end

  defp save_or_create_rotator(repo, %ShortLink{} = short_link, enabled) do
    case short_link.rotator do
      %ShortLinkRotator{} = rotator ->
        rotator
        |> ShortLinkRotator.changeset(%{"enabled" => enabled})
        |> repo.update()

      nil ->
        %ShortLinkRotator{}
        |> ShortLinkRotator.changeset(%{"short_link_id" => short_link.id, "enabled" => enabled})
        |> repo.insert()
    end
  end

  defp insert_rotator_domains_multi(_rotator_id, []), do: Multi.new()

  defp insert_rotator_domains_multi(rotator_id, domain_ids) when is_list(domain_ids) do
    Enum.with_index(domain_ids, 1)
    |> Enum.reduce(Multi.new(), fn {domain_id, priority}, multi ->
      name = :"rotator_domain_#{priority}"

      Multi.insert(
        multi,
        name,
        ShortLinkRotatorDomain.changeset(%ShortLinkRotatorDomain{}, %{
          "rotator_id" => rotator_id,
          "domain_id" => domain_id,
          "priority" => priority
        })
      )
    end)
  end

  defp parse_domain_ids(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn value ->
      case Integer.parse(value) do
        {id, _} -> id
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_domain_ids(_), do: []

  defp destination_allowed?(destination_url, allowed_domains) when is_binary(destination_url) do
    allowed = normalize_allowed_domains(allowed_domains)

    with %URI{scheme: scheme, host: host} <- URI.parse(destination_url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "" do
      normalized_host = normalize_domain_value(host)
      normalized_host in allowed
    else
      _ -> false
    end
  end

  defp destination_allowed?(_, _), do: false

  defp normalize_allowed_domains(values) when is_list(values) do
    values
    |> Enum.map(&normalize_domain_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_allowed_domains(_), do: []

  defp normalize_domain_value(value) when is_binary(value) do
    value = String.trim(value)

    host =
      if String.contains?(value, "://") do
        URI.parse(value).host || ""
      else
        value
      end

    host
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading("www.")
    |> String.trim_trailing(".")
  end

  defp normalize_domain_value(_), do: ""
end
