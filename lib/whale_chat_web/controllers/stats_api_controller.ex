defmodule WhaleChatWeb.StatsApiController do
  use WhaleChatWeb, :controller

  alias WhaleChat.StatsFeed
  alias WhaleChatWeb.StatsFragments

  def fetch_page(conn, params) do
    performance_averages = StatsFeed.performance_averages()
    logged_in = is_binary(get_session(conn, "steamid")) and get_session(conn, "steamid") != ""

    payload =
      StatsFeed.cumulative(%{
        q: Map.get(params, "q", ""),
        page: Map.get(params, "page", "1"),
        per_page: Map.get(params, "perPage", Map.get(params, "per_page", "50")),
        player: Map.get(params, "player")
      })

    prev_page_url =
      case payload[:page] do
        p when is_integer(p) and p > 1 -> page_url(p - 1, payload[:q])
        _ -> nil
      end

    next_page_url =
      case {payload[:page], payload[:total_pages]} do
        {p, tp} when is_integer(p) and is_integer(tp) and p < tp -> page_url(p + 1, payload[:q])
        _ -> nil
      end

    payload =
      payload
      |> Map.put(:html, StatsFragments.cumulative_fragment_html(payload, default_avatar_url: StatsFeed.default_avatar_url(), focused_player: Map.get(params, "player")))
      |> Map.put(:focused_html, StatsFragments.focused_player_html(payload[:focused_player], StatsFeed.default_avatar_url(),
        performance_averages: performance_averages,
        comparison_enabled: logged_in
      ))
      |> Map.put(:success, Map.get(payload, :ok, false))
      |> Map.put(:totalRows, Map.get(payload, :total, 0))
      |> Map.put(:totalPages, Map.get(payload, :total_pages, 1))
      |> Map.put(:prevPageUrl, prev_page_url)
      |> Map.put(:nextPageUrl, next_page_url)

    no_cache_json(conn, payload)
  end

  def cumulative_fragment(conn, params), do: fetch_page(conn, params)

  def logs_fragment(conn, params) do
    payload =
      StatsFeed.logs(%{
        page: Map.get(params, "page", "1"),
        per_page: Map.get(params, "perPage", Map.get(params, "per_page", "25")),
        scope: Map.get(params, "scope", "regular"),
        include_players: Map.get(params, "include_players", "0")
      })

    html = StatsFragments.logs_fragment_html(payload)

    conn
    |> put_resp_content_type("text/html", "utf-8")
    |> put_resp_header("cache-control", "public, max-age=10")
    |> put_resp_header("x-logs-page", to_string(payload[:page] || 1))
    |> put_resp_header("x-logs-total-pages", to_string(payload[:total_pages] || 1))
    |> send_resp(200, html)
  end

  def current_log_fragment(conn, _params) do
    html =
      StatsFeed.current_log()
      |> StatsFragments.current_log_fragment_html(default_avatar_url: StatsFeed.default_avatar_url())

    conn
    |> put_resp_content_type("text/html", "utf-8")
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, max-age=0")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(200, html)
  end

  defp no_cache_json(conn, payload) do
    conn
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, max-age=0")
    |> put_resp_header("pragma", "no-cache")
    |> json(payload)
  end

  defp page_url(page, q) do
    params = [{"page", Integer.to_string(page)}]
    params = if is_binary(q) and String.trim(q) != "", do: [{"q", q} | params], else: params
    "/?" <> URI.encode_query(params)
  end
end
