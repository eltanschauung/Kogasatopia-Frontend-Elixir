defmodule WhaleChatWeb.StatsFragments do
  @moduledoc false

  @favorite_class_icons %{
    1 => {"Scout", "/leaderboard/Scout.png"},
    2 => {"Sniper", "/leaderboard/Sniper.png"},
    3 => {"Soldier", "/leaderboard/Soldier.png"},
    4 => {"Demoman", "/leaderboard/Demoman.png"},
    5 => {"Medic", "/leaderboard/Medic.png"},
    6 => {"Heavy", "/leaderboard/Heavy.png"},
    7 => {"Pyro", "/leaderboard/Pyro.png"},
    8 => {"Spy", "/leaderboard/Spy.png"},
    9 => {"Engineer", "/leaderboard/Engineer.png"}
  }

  def cumulative_fragment_html(payload, opts \\ %{}) do
    q = Map.get(payload, :q, "")
    page = Map.get(payload, :page, 1)
    total_rows = Map.get(payload, :total, 0)
    total_pages = Map.get(payload, :total_pages, 1)
    rows = Map.get(payload, :rows, [])
    prev_url = page_url(q, if(page > 1, do: page - 1, else: nil))
    next_url = page_url(q, if(page < total_pages, do: page + 1, else: nil))
    default_avatar = get_opt(opts, :default_avatar_url, "/stats/assets/whaley-avatar.jpg")

    [
      ~s(<div class="wt-cumulative-fragment" data-page="#{page}" data-total-pages="#{total_pages}" data-total-rows="#{total_rows}">),
      cumulative_toolbar_html(q, page, total_rows, total_pages, prev_url, next_url),
      cumulative_table_html(rows, default_avatar, get_opt(opts, :focused_player, nil)),
      if(total_rows > 0, do: pagination_html(page, total_pages, prev_url, next_url, "table-pagination table-pagination--bottom"), else: ""),
      "</div>"
    ]
    |> IO.iodata_to_binary()
  end

  def cumulative_rows_html(rows, default_avatar \\ "/stats/assets/whaley-avatar.jpg", focused_steamid \\ nil) do
    rows
    |> Enum.map(&cumulative_row_html(&1, default_avatar, focused_steamid))
    |> IO.iodata_to_binary()
  end

  def focused_player_html(nil, _default_avatar), do: ""
  def focused_player_html(row, default_avatar), do: focused_player_html(row, default_avatar, %{})
  def focused_player_html(nil, _default_avatar, _opts), do: ""
  def focused_player_html(row, default_avatar, opts) do
    avatar = fallback(row[:avatar], default_avatar)
    name = fallback(row[:personaname], fallback(row[:steamid], "Unknown"))
    perf = get_opt(opts, :performance_averages, %{})
    comparison_enabled = get_opt(opts, :comparison_enabled, false) and number_or_zero(perf[:eligible] || perf["eligible"]) > 0
    profile_link =
      case row[:profileurl] do
        url when is_binary(url) and url != "" -> ~s(<a href="#{e(url)}" target="_blank" rel="noopener">Steam Profile</a>)
        _ -> ""
      end

    kd = row[:kd] || 0
    acc = row[:accuracy_overall] || 0
    dpm = row[:dpm] || 0
    dtpm = row[:dtpm] || 0
    damage = number_or_zero(row[:damage_dealt])
    damage_taken = number_or_zero(row[:damage_taken])
    healing = number_or_zero(row[:healing])
    airshots = number_or_zero(row[:airshots])
    kills = number_or_zero(row[:kills])
    deaths = number_or_zero(row[:deaths])
    assists = number_or_zero(row[:assists])
    total_ubers = number_or_zero(row[:total_ubers])
    dropped = number_or_zero(row[:uber_drops] || row[:medic_drops])

    damage_attr = stat_compare_attr(comparison_enabled, damage, perf[:damage] || perf["damage"], true, "Damage Dealt")
    dpm_attr = stat_compare_attr(comparison_enabled, dpm, perf[:dpm] || perf["dpm"], true, "Damage Per Minute")
    acc_attr = stat_compare_attr(comparison_enabled, acc, perf[:accuracy] || perf["accuracy"], true, "Shots hit vs fired")
    heal_attr = stat_compare_attr(comparison_enabled, healing, perf[:healing] || perf["healing"], true, "Healing Done")
    air_attr = stat_compare_attr(comparison_enabled, airshots, perf[:airshots] || perf["airshots"], true, "Airshots")
    {kd_class, kd_title} = kd_compare(comparison_enabled, kd, perf[:kd] || perf["kd"])

    """
    <section class="detail-panel stats-focused-panel" data-focused-player="#{e(row[:steamid] || "")}">
      <div class="detail-profile">
        <img src="#{e(avatar)}" alt="" onerror="this.onerror=null;this.src='#{e(default_avatar)}'">
        <div>
          <div style="font-size:1.35rem;font-weight:600;">#{e(name)}</div>
          <div class="detail-profile-links">#{profile_link}</div>
          <div style="color:var(--text-muted,#b7c0d2);">#{number(kills)} K / #{number(deaths)} D / #{number(assists)} A</div>
        </div>
      </div>
      <div class="detail-grid">
        <div><h3>Damage</h3><p#{damage_attr}>#{number(damage)}</p></div>
        <div><h3>DT</h3><p title="Damage Taken">#{number(damage_taken)}</p></div>
        <div><h3>DPM</h3><p#{dpm_attr}>#{decimal(dpm, 1)}</p></div>
        <div><h3>DT/M</h3><p>#{decimal(dtpm, 1)}</p></div>
        <div><h3>Accuracy</h3><p#{acc_attr}>#{decimal(acc, 1)}%</p></div>
        <div><h3>K/D</h3><p class="stat-kd-trigger #{kd_class}" title="#{e(kd_title)}">#{decimal(kd, 2)}</p></div>
        <div><h3>Healing</h3><p#{heal_attr}>#{number(healing)}</p></div>
        <div><h3>Headshots</h3><p title="Headshots">#{number(row[:headshots])}</p></div>
        <div><h3>Stabs</h3><p>#{number(row[:backstabs])}</p></div>
        <div><h3>Best Streak</h3><p>#{number(row[:best_killstreak])}</p></div>
        <div><h3>Dropped Ubers</h3><p title="Times Dropped">#{number(dropped)}</p></div>
        <div><h3>Ubers</h3><p title="Total Ubers Used">#{number(total_ubers)}</p></div>
        <div><h3>Airshots</h3><p#{air_attr}>#{number(airshots)}</p></div>
        <div><h3>Time</h3><p>#{e(fallback(row[:playtime_human], "0m"))}</p></div>
      </div>
    </section>
    """
  end

  def logs_fragment_html(payload) do
    rows = Map.get(payload, :rows, [])
    page = Map.get(payload, :page, 1)
    total_pages = Map.get(payload, :total_pages, 1)
    total = Map.get(payload, :total, 0)
    scope = Map.get(payload, :scope, "regular")

    body =
      if rows == [] do
        ~s(<div class="empty-state">Logs loading or unavailable...</div>)
      else
        Enum.map_join(rows, "", &single_log_summary_html/1)
      end

    """
    <div class="logs-fragment-root" data-page="#{page}" data-total-pages="#{total_pages}" data-total-logs="#{total}" data-scope="#{e(scope)}">
      #{body}
    </div>
    """
  end

  def current_log_fragment_html(data, opts \\ [])
  def current_log_fragment_html(%{ok: true, log: log}, opts), do: current_log_fragment_html(log, opts)
  def current_log_fragment_html(%{log: nil}, _opts), do: ~s(<div class="empty-state">No logs available.</div>)
  def current_log_fragment_html(nil, _opts), do: ~s(<div class="empty-state">No logs available.</div>)

  def current_log_fragment_html(log, opts) when is_map(log) do
    default_avatar = get_opt(opts, :default_avatar_url, "/stats/assets/whaley-avatar.jpg")
    players = Map.get(log, :players, [])
    player_count = if players != [], do: length(players), else: Map.get(log, :player_count, 0)
    map_name = basename(Map.get(log, :map))
    started_at = Map.get(log, :started_at, 0)
    duration = Map.get(log, :duration, 0)
    duration_text = format_playtime(duration)
    started_text = format_log_datetime(started_at)
    mode = fallback(Map.get(log, :gamemode), "Unknown")

    players_table =
      if players == [] do
        ~s(<div class="empty-state">No player data recorded for this match.</div>)
      else
        [
          ~s(<table class="stats-table log-table"><thead><tr><th>Player</th><th>K</th><th>D</th><th>K/D</th><th>Acc.</th><th>Dmg</th><th>D/M</th><th>DT/M</th><th>AS</th><th>HS</th><th>BS</th><th>Healing</th><th>Ubers</th><th>Time</th></tr></thead><tbody>),
          Enum.map(players, &current_log_player_row_html(&1, default_avatar)),
          "</tbody></table>"
        ]
        |> IO.iodata_to_binary()
      end

    """
    <div class="log-entry log-current" data-player-count="#{player_count}" data-started-at="#{started_at}">
      <div class="log-summary">
        <span class="gamemode-icon"><span class="gamemode-label">#{e(mode)}</span></span>
        <span class="log-title">#{e(map_name)} — #{e(started_text)} — #{e(duration_text)}</span>
        <span class="log-meta">#{player_count} player#{if player_count == 1, do: "", else: "s"}</span>
      </div>
      <div class="log-body">#{players_table}</div>
    </div>
    """
  end

  defp cumulative_toolbar_html(q, page, total_rows, total_pages, prev_url, next_url) do
    """
    <div class="table-toolbar">
      <form class="search-bar toolbar-search" method="get" action="/stats" data-rate-limit-ms="1500">
        <input type="text" name="q" value="#{e(q)}" placeholder="Search players by Steam name or SteamID">
        <button type="submit">Search</button>
        <p class="toolbar-search__rate-notice" aria-live="polite" hidden></p>
      </form>
      <div class="toolbar-spacer"></div>
      <div class="toolbar-pagination">
        #{if total_rows > 0, do: pagination_html(page, total_pages, prev_url, next_url, nil), else: ""}
      </div>
    </div>
    """
  end

  defp cumulative_table_html(rows, default_avatar, focused_steamid) do
    """
    <div class="table-wrapper">
      <table class="stats-table" id="stats-table-cumulative">
        <thead>
          <tr>
            <th data-key="player" data-type="text">Player</th>
            <th data-key="kills" data-type="number">Kills|Deaths|Assists</th>
            <th data-key="kd" data-type="number">K/D</th>
            <th data-key="damage" data-type="number">Dmg</th>
            <th data-key="damage_taken" data-type="number">DT</th>
            <th data-key="dpm" data-type="number">D/M</th>
            <th data-key="dtpm" data-type="number">DT/M</th>
            <th data-key="accuracy" data-type="number">Acc.</th>
            <th data-key="airshots" data-type="number">AS</th>
            <th data-key="drops" data-type="number">Dp | Dp'd</th>
            <th data-key="healing" data-type="number">Heals</th>
            <th data-key="headshots" data-type="number">Headshots</th>
            <th data-key="backstabs" data-type="number">Stabs</th>
            <th data-key="streak" data-type="number">Best Streak</th>
            <th data-key="playtime" data-type="number">Time</th>
          </tr>
        </thead>
        <tbody>
          #{if rows == [], do: ~s(<tr><td colspan="15" class="empty-state">No players found.</td></tr>), else: cumulative_rows_html(rows, default_avatar, focused_steamid)}
        </tbody>
      </table>
    </div>
    """
  end

  defp cumulative_row_html(row, default_avatar, focused_steamid) do
    steamid = row[:steamid] || ""
    personaname = fallback(row[:personaname], steamid)
    avatar = fallback(row[:avatar], default_avatar)
    profile_url = row[:profileurl]
    classes =
      []
      |> maybe_push(row[:is_online], "online-player")
      |> maybe_push(focused_steamid && steamid == focused_steamid, "player-highlight")
      |> Enum.join(" ")

    name_classes =
      []
      |> maybe_push(row[:is_admin], "admin-name")
      |> maybe_push(row[:is_online], "online-name")
      |> Enum.join(" ")

    kd = row[:kd] || 0
    acc = row[:accuracy_overall] || 0
    favorite_class = favorite_class_icon_html(row[:favorite_class])
    accuracy_class = if is_integer(row[:favorite_class]), do: row[:favorite_class], else: 0
    tr_class = if classes == "", do: "", else: ~s( class="#{e(classes)}")
    name_title =
      cond do
        row[:is_online] && row[:is_admin] -> "Connected Admin"
        row[:is_online] -> "Connected Player"
        row[:is_admin] -> "Admin"
        true -> "Player"
      end

    player_link =
      if is_binary(profile_url) and profile_url != "" do
        ~s(<a class="#{e(name_classes)}" title="#{e(name_title)}" href="#{e(profile_url)}" target="_blank" rel="noopener">#{e(personaname)}</a>)
      else
        ~s(<span class="#{e(name_classes)}" title="#{e(name_title)}">#{e(personaname)}</span>)
      end

    """
    <tr#{tr_class} data-steamid="#{e(steamid)}" data-player="#{e(String.downcase(personaname))}" data-kills="#{row[:kills] || 0}" data-deaths="#{row[:deaths] || 0}" data-assists="#{row[:assists] || 0}" data-kd="#{decimal(kd, 4)}" data-damage="#{row[:damage_dealt] || 0}" data-damage_taken="#{row[:damage_taken] || 0}" data-dpm="#{decimal(row[:dpm] || 0, 4)}" data-dtpm="#{decimal(row[:dtpm] || 0, 4)}" data-accuracy="#{decimal(acc, 4)}" data-accuracy_class="#{accuracy_class}" data-airshots="#{row[:airshots] || 0}" data-drops="#{row[:medic_drops] || 0}" data-dropped="#{row[:uber_drops] || 0}" data-healing="#{row[:healing] || 0}" data-headshots="#{row[:headshots] || 0}" data-backstabs="#{row[:backstabs] || 0}" data-streak="#{row[:best_killstreak] || 0}" data-playtime="#{row[:playtime] || 0}" data-score="#{row[:score] || 0}" data-online="#{if row[:is_online], do: 1, else: 0}">
      <td class="player-cell">
        <img class="player-avatar" src="#{e(avatar)}" alt="" onerror="this.onerror=null;this.src='#{e(default_avatar)}'">
        <div>#{player_link}</div>
      </td>
      <td>#{number(row[:kills])}|#{number(row[:deaths])}|#{number(row[:assists])}</td>
      <td>#{decimal(kd, 2)}</td>
      <td>#{number(row[:damage_dealt])}</td>
      <td>#{number(row[:damage_taken])}</td>
      <td>#{decimal(row[:dpm] || 0, 1)}</td>
      <td>#{decimal(row[:dtpm] || 0, 1)}</td>
      <td class="stat-accuracy-cell"><span class="stat-accuracy-value">#{decimal(acc, 1)}%</span>#{favorite_class}</td>
      <td>#{number(row[:airshots])}</td>
      <td>#{number(row[:medic_drops])} | #{number(row[:uber_drops])}</td>
      <td>#{number(row[:healing])}</td>
      <td>#{number(row[:headshots])}</td>
      <td>#{number(row[:backstabs])}</td>
      <td>#{number(row[:best_killstreak])}</td>
      <td>#{e(fallback(row[:playtime_human], "0m"))}</td>
    </tr>
    """
  end

  defp single_log_summary_html(log) do
    player_count = Map.get(log, :player_count, 0)
    map_name = basename(Map.get(log, :map))
    started_at = Map.get(log, :started_at, 0)
    duration = Map.get(log, :duration, 0)
    mode = fallback(Map.get(log, :gamemode), "Unknown")
    players = Map.get(log, :players, [])

    body_html =
      if is_list(players) and players != [] do
        [
          ~s(<div class="table-wrapper"><table class="stats-table log-table"><thead><tr><th>Player</th><th>K</th><th>D</th><th>K/D</th><th>Acc.</th><th>Dmg</th><th>D/M</th><th>DT/M</th><th>AS</th><th>HS</th><th>BS</th><th>Healing</th><th>Ubers</th><th>Time</th></tr></thead><tbody>),
          Enum.map(players, &current_log_player_row_html(&1, "/stats/assets/whaley-avatar.jpg")),
          "</tbody></table></div>"
        ]
        |> IO.iodata_to_binary()
      else
        ~s(<div class="empty-state">No player rows recorded for this log.</div>)
      end

    """
    <details class="log-entry" data-player-count="#{player_count}" data-started-at="#{started_at}">
      <summary class="log-summary">
        <span class="gamemode-icon"><span class="gamemode-label">#{e(mode)}</span></span>
        <span class="log-title">#{e(map_name)} — #{e(format_log_datetime(started_at))} — #{e(format_playtime(duration))}</span>
        <span class="log-meta">#{player_count} player#{if player_count == 1, do: "", else: "s"}</span>
      </summary>
      <div class="log-body">
        #{body_html}
      </div>
    </details>
    """
  end

  defp current_log_player_row_html(player, default_avatar) do
    avatar = fallback(player[:avatar], default_avatar)
    name = fallback(player[:personaname], player[:steamid] || "Unknown")
    profile_url = player[:profileurl]
    kills = player[:kills] || 0
    deaths = player[:deaths] || 0
    damage = player[:damage] || 0
    damage_taken = player[:damage_taken] || 0
    healing = player[:healing] || 0
    headshots = player[:headshots] || 0
    backstabs = player[:backstabs] || 0
    ubers = player[:total_ubers] || 0
    playtime = player[:playtime] || 0
    airshots = player[:airshots] || 0
    shots = player[:shots] || 0
    hits = player[:hits] || 0
    minutes = if playtime > 0, do: playtime / 60.0, else: 0.0
    kd = if deaths > 0, do: kills / deaths, else: kills * 1.0
    dpm = if minutes > 0, do: damage / minutes, else: damage * 1.0
    dtpm = if minutes > 0, do: damage_taken / minutes, else: damage_taken * 1.0
    acc = if shots > 0, do: hits * 100.0 / shots, else: nil
    name_cls = if player[:is_admin], do: "admin-name", else: ""

    link_html =
      if is_binary(profile_url) and profile_url != "" do
        ~s(<a href="#{e(profile_url)}" target="_blank" rel="noopener" class="#{e(name_cls)}">#{e(name)}</a>)
      else
        ~s(<span class="#{e(name_cls)}">#{e(name)}</span>)
      end

    """
    <tr>
      <td class="player-cell">
        <img class="player-avatar" src="#{e(avatar)}" alt="">
        <div class="log-player-info">#{link_html}</div>
      </td>
      <td>#{number(kills)}</td>
      <td>#{number(deaths)}</td>
      <td>#{decimal(kd, 2)}</td>
      <td>#{if(acc == nil, do: "—", else: decimal(acc, 1) <> "%")}</td>
      <td>#{number(damage)}</td>
      <td>#{decimal(dpm, 1)}</td>
      <td>#{decimal(dtpm, 1)}</td>
      <td>#{number(airshots)}</td>
      <td>#{number(headshots)}</td>
      <td>#{number(backstabs)}</td>
      <td>#{number(healing)}</td>
      <td>#{number(ubers)}</td>
      <td>#{e(format_playtime(playtime))}</td>
    </tr>
    """
  end

  defp pagination_html(page, total_pages, prev_url, next_url, classes) do
    outer_class =
      if is_binary(classes) and classes != "" do
        ~s( class="#{e(classes)}")
      else
        ""
      end

    """
    <div#{outer_class}>
      <span class="table-pagination-info">Page #{page} / #{total_pages}</span>
      <div class="table-pagination-controls">
        #{pagination_link_html("Prev", prev_url)}
        #{pagination_link_html("Next", next_url)}
      </div>
    </div>
    """
  end

  defp pagination_link_html(label, nil),
    do: ~s(<span class="table-pagination-button is-disabled" aria-disabled="true">#{label}</span>)

  defp pagination_link_html(label, url),
    do: ~s(<a class="table-pagination-button" href="#{e(url)}">#{label}</a>)

  defp page_url(_q, nil), do: nil

  defp page_url(q, page) do
    params = [{"page", Integer.to_string(page)}]
    params = if is_binary(q) and String.trim(q) != "", do: [{"q", q} | params], else: params
    "/?" <> URI.encode_query(params)
  end

  defp format_log_datetime(ts) when is_integer(ts) and ts > 0 do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> "Unknown"
    end
  end
  defp format_log_datetime(_), do: "Unknown"

  defp format_playtime(seconds) when is_integer(seconds) and seconds > 0 do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    if h > 0, do: "#{h}h #{m}m", else: "#{max(m, 1)}m"
  end
  defp format_playtime(_), do: "0m"

  defp number(nil), do: "0"
  defp number(v) when is_integer(v), do: format_integer(v)
  defp number(v) when is_float(v), do: format_integer(trunc(v))
  defp number(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> format_integer(i)
      :error -> "0"
    end
  end
  defp number(_), do: "0"

  defp decimal(v, places) when is_integer(v), do: :erlang.float_to_binary(v / 1, decimals: places)
  defp decimal(v, places) when is_float(v), do: :erlang.float_to_binary(v, decimals: places)
  defp decimal(v, places) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> decimal(f, places)
      :error ->
        case Integer.parse(v) do
          {i, _} -> decimal(i, places)
          :error -> decimal(0.0, places)
        end
    end
  end
  defp decimal(_, places), do: decimal(0.0, places)

  defp format_integer(i) do
    i
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(.{3})(?=.)/, "\\1,")
    |> String.reverse()
  end

  defp maybe_push(list, true, value), do: [value | list]
  defp maybe_push(list, _, _), do: list

  defp favorite_class_icon_html(id) do
    case @favorite_class_icons[id] do
      {label, path} ->
        ~s(<img class="stat-accuracy-icon" src="#{e(path)}" alt="#{e(label)}" title="Favorite class: #{e(label)}">)

      _ ->
        ""
    end
  end

  defp stat_compare_attr(false, _value, _average, _hib, title), do: title_attr(title)
  defp stat_compare_attr(_enabled, _value, average, _hib, title) when average in [nil, 0, 0.0], do: title_attr(title)
  defp stat_compare_attr(true, value, average, higher_is_better, title) do
    value = number_or_zero(value)
    average = number_or_zero(average)
    diff = if average > 0, do: ((value - average) / average) * 100.0, else: 0.0

    suffix =
      cond do
        abs(diff) < 0.05 -> "neutral"
        (diff >= 0 && higher_is_better) || (diff < 0 && !higher_is_better) -> "better"
        true -> "worse"
      end

    ~s( class="stat-compare stat-compare--#{suffix}" title="#{e(title <> " (" <> signed_pct(diff) <> " vs server average)")}")
  end

  defp kd_compare(false, kd, _avg), do: {"stat-kd--neutral", "K/D: " <> decimal(kd, 2)}
  defp kd_compare(_enabled, kd, avg) when avg in [nil, 0, 0.0], do: {"stat-kd--neutral", "K/D: " <> decimal(kd, 2)}
  defp kd_compare(true, kd, avg) do
    kd = number_or_zero(kd)
    avg = number_or_zero(avg)
    diff = ((kd - avg) / avg) * 100.0

    klass =
      cond do
        abs(diff) < 0.05 -> "stat-kd--neutral"
        diff >= 0 -> "stat-kd--better"
        true -> "stat-kd--worse"
      end

    {klass, "K/D: #{decimal(kd, 2)} vs server #{decimal(avg, 2)} (#{signed_pct(diff)})"}
  end

  defp title_attr(""), do: ""
  defp title_attr(v), do: ~s( title="#{e(v)}")

  defp signed_pct(v) when is_number(v) do
    sign = if v >= 0, do: "+", else: ""
    sign <> decimal(v, 1) <> "%"
  end

  defp number_or_zero(v) when is_integer(v), do: v
  defp number_or_zero(v) when is_float(v), do: v
  defp number_or_zero(%Decimal{} = v), do: Decimal.to_float(v)
  defp number_or_zero(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error ->
        case Integer.parse(v) do
          {i, _} -> i
          :error -> 0
        end
    end
  end
  defp number_or_zero(_), do: 0

  defp get_opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp get_opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp get_opt(_, _, default), do: default

  defp basename(nil), do: "Unknown"
  defp basename(v) when is_binary(v), do: if(v == "", do: "Unknown", else: Path.basename(v))
  defp basename(v), do: basename(to_string(v))

  defp fallback(v, default) when v in [nil, ""], do: default
  defp fallback(v, _default), do: v

  defp e(v) do
    v
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
