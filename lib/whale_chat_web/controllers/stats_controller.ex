defmodule WhaleChatWeb.StatsController do
  use WhaleChatWeb, :controller

  alias WhaleChat.Chat.SteamProfiles
  alias WhaleChat.StatsFeed
  alias WhaleChatWeb.StatsFragments

  def index(conn, params) do
    session_steamid = get_session(conn, "steamid")
    focused_player = Map.get(params, "player") || session_steamid
    search = Map.get(params, "q", "")

    payload = StatsFeed.page_payload(%{"q" => search, "page" => Map.get(params, "page"), "player" => focused_player})
    cumulative = payload.cumulative
    default_avatar = payload.default_avatar_url
    viewer_profile = viewer_profile(session_steamid, cumulative[:focused_player], default_avatar)

    render(conn, :index,
      summary: payload.summary,
      cumulative: cumulative,
      current_log: payload.current_log,
      default_avatar_url: default_avatar,
      cumulative_html: StatsFragments.cumulative_fragment_html(cumulative, default_avatar_url: default_avatar, focused_player: focused_player),
      focused_html: StatsFragments.focused_player_html(cumulative[:focused_player], default_avatar),
      current_log_html: StatsFragments.current_log_fragment_html(payload.current_log, default_avatar_url: default_avatar),
      search: search,
      focused_player: focused_player,
      steamid: session_steamid,
      logged_in: is_binary(session_steamid) and session_steamid != "",
      viewer_profile: viewer_profile
    )
  end

  defp viewer_profile(nil, _focused, _default_avatar), do: nil
  defp viewer_profile("", _focused, _default_avatar), do: nil

  defp viewer_profile(session_steamid, focused_player, default_avatar) do
    cond do
      is_map(focused_player) && focused_player[:steamid] == session_steamid ->
        focused_player

      true ->
        case StatsFeed.fetch_player(session_steamid) do
          nil ->
            profile = SteamProfiles.fetch_many([session_steamid])[session_steamid] || %{}

            %{
              steamid: session_steamid,
              personaname: profile["personaname"] || session_steamid,
              avatar: profile["avatarfull"] || default_avatar,
              profileurl: "https://steamcommunity.com/profiles/" <> session_steamid
            }

          row ->
            row
        end
    end
  end
end
