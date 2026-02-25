defmodule WhaleChatWeb.LogsController do
  use WhaleChatWeb, :controller

  alias WhaleChat.StatsFeed
  alias WhaleChatWeb.StatsFragments

  @per_page 25

  def index(conn, params) do
    render_logs_page(conn, params, "regular")
  end

  def short(conn, params) do
    render_logs_page(conn, params, "short")
  end

  def current(conn, _params) do
    default_avatar = StatsFeed.default_avatar_url()
    current_log = StatsFeed.current_log()

    render(conn, :current,
      page_title: "Current Match Log · WhaleTracker",
      current_log_html: StatsFragments.current_log_fragment_html(current_log, default_avatar_url: default_avatar)
    )
  end

  defp render_logs_page(conn, params, scope) do
    page = parse_page(params["page"])

    logs =
      StatsFeed.logs(%{
        page: page,
        per_page: @per_page,
        scope: scope,
        include_players: true
      })

    render(conn, :index,
      page_title: if(scope == "short", do: "Match Logs (Short) · WhaleTracker", else: "Match Logs · WhaleTracker"),
      logs_html: StatsFragments.logs_fragment_html(logs),
      page: logs[:page] || page,
      total_pages: logs[:total_pages] || 1,
      total_logs: logs[:total] || 0,
      per_page: @per_page,
      scope: scope
    )
  end

  defp parse_page(v) when is_integer(v) and v > 0, do: v
  defp parse_page(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} when i > 0 -> i
      _ -> 1
    end
  end
  defp parse_page(_), do: 1
end
