defmodule WhaleChat.StatsFeed do
  @moduledoc false

  require Logger
  alias Ecto.Adapters.SQL
  alias WhaleChat.Chat.SteamProfiles
  alias WhaleChat.Repo

  @default_avatar "/stats/assets/whaley-avatar.jpg"
  @stats_table "whaletracker"
  @logs_table "whaletracker_logs"
  @log_players_table "whaletracker_log_players"
  @stats_min_playtime_sort 4 * 3600

  def page_payload(opts \\ %{}) do
    search = str(Map.get(opts, :q, Map.get(opts, "q", "")))
    page = positive_int(Map.get(opts, :page, Map.get(opts, "page", 1)), 1)
    per_page = positive_int(Map.get(opts, :per_page, Map.get(opts, "per_page", 50)), 50)
    player = Map.get(opts, :player, Map.get(opts, "player"))

    %{
      summary: summary(),
      performance_averages: performance_averages(),
      cumulative: cumulative(%{q: search, page: page, per_page: per_page, player: player}),
      current_log: current_log(),
      default_avatar_url: default_avatar_url()
    }
  end

  def summary do
    sql = """
    SELECT COUNT(*) AS total_players,
           COALESCE(SUM(kills), 0) AS total_kills,
           COALESCE(SUM(assists), 0) AS total_assists,
           COALESCE(SUM(playtime), 0) AS total_playtime,
           COALESCE(SUM(healing), 0) AS total_healing,
           COALESCE(SUM(headshots), 0) AS total_headshots,
           COALESCE(SUM(backstabs), 0) AS total_backstabs,
           COALESCE(SUM(damage_dealt), 0) AS total_damage,
           COALESCE(SUM(damage_taken), 0) AS total_damage_taken,
           COALESCE(SUM(medic_drops), 0) AS total_drops,
           COALESCE(SUM(total_ubers), 0) AS total_ubers_used
    FROM #{@stats_table}
    """

    with {:ok, %{rows: [row], columns: cols}} <- SQL.query(Repo, sql, []) do
      data = row_map(row, cols)
      playtime_seconds = int(data["total_playtime"])
      total_damage = int(data["total_damage"])
      total_minutes = if playtime_seconds > 0, do: playtime_seconds / 60.0, else: 0.0
      base = %{
        total_players: int(data["total_players"]),
        total_kills: int(data["total_kills"]),
        total_assists: int(data["total_assists"]),
        total_playtime_hours: Float.round(playtime_seconds / 3600.0, 1),
        total_healing: int(data["total_healing"]),
        total_headshots: int(data["total_headshots"]),
        total_backstabs: int(data["total_backstabs"]),
        total_damage: total_damage,
        total_damage_taken: int(data["total_damage_taken"]),
        total_drops: int(data["total_drops"]),
        total_ubers_used: int(data["total_ubers_used"]),
        average_dpm: if(total_minutes > 0, do: Float.round(total_damage / total_minutes, 1), else: 0.0)
      }

      base
      |> Map.merge(summary_top_killstreak())
      |> Map.merge(summary_insights())
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  def cumulative(opts \\ %{}) do
    q = str(Map.get(opts, :q, Map.get(opts, "q", ""))) |> String.trim()
    page = positive_int(Map.get(opts, :page, Map.get(opts, "page", 1)), 1)
    per_page = positive_int(Map.get(opts, :per_page, Map.get(opts, "per_page", 50)), 50) |> min(100)
    offset = (page - 1) * per_page

    try do
      {rows, total} =
        if q == "" do
          {fetch_cumulative_rows(per_page, offset), count_table(@stats_table)}
        else
          fetch_cumulative_search(q, per_page, offset)
        end

      rows = enrich_cumulative_rows(rows)
      total_pages = max(1, ceil_div(total, per_page))

      focused_player =
        case Map.get(opts, :player, Map.get(opts, "player")) do
          nil -> nil
          "" -> nil
          steamid -> fetch_player(steamid)
        end

      %{
        ok: true,
        q: q,
        page: page,
        per_page: per_page,
        total: total,
        total_pages: total_pages,
        rows: rows,
        focused_player: focused_player
      }
    rescue
      e ->
        Logger.error("StatsFeed.cumulative failed: " <> Exception.format(:error, e, __STACKTRACE__))
        %{ok: false, rows: [], total: 0, page: 1, total_pages: 1, per_page: 50, q: q, focused_player: nil}
    end
  end

  def logs(opts \\ %{}) do
    page = positive_int(Map.get(opts, :page, Map.get(opts, "page", 1)), 1)
    per_page = positive_int(Map.get(opts, :per_page, Map.get(opts, "per_page", 25)), 25) |> min(100)
    scope = logs_scope(Map.get(opts, :scope, Map.get(opts, "scope", "regular")))
    include_players = truthy?(Map.get(opts, :include_players, Map.get(opts, "include_players", false)))
    offset = (page - 1) * per_page

    {where_sql, params} = logs_scope_sql(scope)

    total_sql = "SELECT COUNT(*) AS c FROM #{@logs_table} WHERE player_count > 0#{where_sql}"
    total = scalar_query(total_sql, params)

    sql = """
    SELECT log_id, map, gamemode, started_at, ended_at, duration, player_count, created_at, updated_at
    FROM #{@logs_table}
    WHERE player_count > 0#{where_sql}
    ORDER BY started_at DESC
    LIMIT ? OFFSET ?
    """

    rows =
      case SQL.query(Repo, sql, params ++ [per_page, offset]) do
        {:ok, %{rows: rs, columns: cols}} ->
          Enum.map(rs, fn row ->
            m = row_map(row, cols)

            %{
              log_id: str(m["log_id"]),
              map: str(m["map"]),
              gamemode: str(m["gamemode"]),
              started_at: int(m["started_at"]),
              ended_at: int(m["ended_at"]),
              duration: int(m["duration"]),
              player_count: int(m["player_count"]),
              created_at: int(m["created_at"]),
              updated_at: int(m["updated_at"])
            }
          end)

        _ ->
          []
      end

    rows =
      if include_players do
        attach_log_players(rows)
      else
        rows
      end

    %{
      ok: true,
      page: page,
      per_page: per_page,
      total: total,
      total_pages: max(1, ceil_div(total, per_page)),
      scope: scope,
      rows: rows
    }
  rescue
    _ -> %{ok: false, rows: [], total: 0, page: 1, total_pages: 1, per_page: 25, scope: "regular"}
  end

  def current_log do
    case logs(%{page: 1, per_page: 1, scope: "all", include_players: true}) do
      %{ok: true, rows: [log | _]} -> %{ok: true, log: log}
      _ -> %{ok: false, log: nil}
    end
  end

  def tab_hash do
    sql = "SELECT COALESCE(MAX(last_seen), 0) AS recent, COUNT(*) AS total FROM #{@stats_table}"

    case SQL.query(Repo, sql, []) do
      {:ok, %{rows: [row], columns: cols}} ->
        m = row_map(row, cols)
        raw = "#{int(m["recent"])}:#{int(m["total"])}"
        :crypto.hash(:sha, raw) |> Base.encode16(case: :lower) |> binary_part(0, 7)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def performance_averages do
    sql = """
    SELECT COUNT(*) AS eligible,
           AVG(CASE WHEN deaths > 0 THEN kills / NULLIF(deaths, 0) ELSE kills END) AS avg_kd,
           AVG(damage_dealt) AS avg_damage,
           AVG(airshots) AS avg_airshots,
           AVG(healing) AS avg_healing,
           AVG(CASE WHEN playtime > 0 THEN damage_dealt / (playtime / 60.0) END) AS avg_dpm,
           AVG(CASE WHEN shots > 0 THEN hits / shots END) AS avg_accuracy
    FROM #{@stats_table}
    WHERE playtime >= 18000
    """

    case SQL.query(Repo, sql, []) do
      {:ok, %{rows: [row], columns: cols}} ->
        m = row_map(row, cols)

        %{
          eligible: int(m["eligible"]),
          kd: floaty(m["avg_kd"]),
          damage: floaty(m["avg_damage"]),
          airshots: floaty(m["avg_airshots"]),
          healing: floaty(m["avg_healing"]),
          dpm: floaty(m["avg_dpm"]),
          accuracy: floaty(m["avg_accuracy"]) * 100.0
        }

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  def fetch_player(nil), do: nil
  def fetch_player(""), do: nil

  def fetch_player(steamid) do
    steamid = str(steamid) |> String.trim()
    if steamid == "" do
      nil
    else
      favorite_class_expr = favorite_class_select_expr()

      sql = """
      SELECT steamid,
             COALESCE(cached_personaname, personaname, steamid) AS personaname,
             kills, deaths, assists, healing, headshots, backstabs,
             COALESCE(best_killstreak, 0) AS best_killstreak,
             COALESCE(playtime, 0) AS playtime,
             COALESCE(damage_dealt, 0) AS damage_dealt,
             COALESCE(damage_taken, 0) AS damage_taken,
             COALESCE(shots, 0) AS shots,
             COALESCE(hits, 0) AS hits,
             COALESCE(total_ubers, 0) AS total_ubers,
             COALESCE(medic_drops, 0) AS medic_drops,
             COALESCE(uber_drops, COALESCE(medic_drops, 0)) AS uber_drops,
             COALESCE(airshots, 0) AS airshots,
             #{favorite_class_expr} AS favorite_class,
             COALESCE(last_seen, 0) AS last_seen
      FROM #{@stats_table}
      WHERE steamid = ?
      LIMIT 1
      """

      case SQL.query(Repo, sql, [steamid]) do
        {:ok, %{rows: [row], columns: cols}} ->
          row
          |> row_map(cols)
          |> then(&enrich_cumulative_rows([&1]))
          |> List.first()

        _ ->
          nil
      end
    end
  rescue
    _ -> nil
  end

  def default_avatar_url, do: Application.get_env(:whale_chat, :default_avatar_url, @default_avatar)

  defp fetch_cumulative_rows(limit, offset) do
    favorite_class_expr = favorite_class_select_expr()

    sql = """
    SELECT steamid,
           COALESCE(cached_personaname, personaname, steamid) AS personaname,
           kills, deaths, assists, healing, headshots, backstabs,
           COALESCE(best_killstreak, 0) AS best_killstreak,
           COALESCE(playtime, 0) AS playtime,
           COALESCE(damage_dealt, 0) AS damage_dealt,
           COALESCE(damage_taken, 0) AS damage_taken,
           COALESCE(shots, 0) AS shots,
           COALESCE(hits, 0) AS hits,
           COALESCE(total_ubers, 0) AS total_ubers,
           COALESCE(medic_drops, 0) AS medic_drops,
           COALESCE(uber_drops, COALESCE(medic_drops, 0)) AS uber_drops,
           COALESCE(airshots, 0) AS airshots,
           #{favorite_class_expr} AS favorite_class,
           COALESCE(last_seen, 0) AS last_seen
    FROM #{@stats_table}
    ORDER BY #{stats_order_clause()}
    LIMIT ? OFFSET ?
    """

    case SQL.query(Repo, sql, [limit, offset]) do
      {:ok, %{rows: rows, columns: cols}} -> Enum.map(rows, &row_map(&1, cols))
      _ -> []
    end
  end

  defp fetch_cumulative_search(q, limit, offset) do
    favorite_class_expr = favorite_class_select_expr()
    like = "%" <> String.downcase(q) <> "%"
    steam_like = "%" <> q <> "%"

    count_sql = """
    SELECT COUNT(*)
    FROM #{@stats_table}
    WHERE LOWER(COALESCE(cached_personaname, personaname, steamid)) LIKE ?
       OR steamid LIKE ?
       OR steamid = ?
    """

    total = scalar_query(count_sql, [like, steam_like, q])

    sql = """
    SELECT steamid,
           COALESCE(cached_personaname, personaname, steamid) AS personaname,
           kills, deaths, assists, healing, headshots, backstabs,
           COALESCE(best_killstreak, 0) AS best_killstreak,
           COALESCE(playtime, 0) AS playtime,
           COALESCE(damage_dealt, 0) AS damage_dealt,
           COALESCE(damage_taken, 0) AS damage_taken,
           COALESCE(shots, 0) AS shots,
           COALESCE(hits, 0) AS hits,
           COALESCE(total_ubers, 0) AS total_ubers,
           COALESCE(medic_drops, 0) AS medic_drops,
           COALESCE(uber_drops, COALESCE(medic_drops, 0)) AS uber_drops,
           COALESCE(airshots, 0) AS airshots,
           #{favorite_class_expr} AS favorite_class,
           COALESCE(last_seen, 0) AS last_seen
    FROM #{@stats_table}
    WHERE LOWER(COALESCE(cached_personaname, personaname, steamid)) LIKE ?
       OR steamid LIKE ?
       OR steamid = ?
    ORDER BY #{stats_order_clause()}
    LIMIT ? OFFSET ?
    """

    rows =
      case SQL.query(Repo, sql, [like, steam_like, q, limit, offset]) do
        {:ok, %{rows: rs, columns: cols}} -> Enum.map(rs, &row_map(&1, cols))
        _ -> []
      end

    {rows, total}
  end

  defp enrich_cumulative_rows(rows) do
    steam_ids =
      rows
      |> Enum.map(&str(&1["steamid"]))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    profiles = SteamProfiles.fetch_many(steam_ids)
    admin_flags = admin_flags_for_ids(steam_ids)
    default_avatar = default_avatar_url()

    Enum.map(rows, fn row ->
      steamid = str(row["steamid"])
      profile = Map.get(profiles, steamid, %{})
      kills = int(row["kills"])
      deaths = int(row["deaths"])
      assists = int(row["assists"])
      playtime = int(row["playtime"])
      damage = int(row["damage_dealt"])
      damage_taken = int(row["damage_taken"])
      shots = int(row["shots"])
      hits = int(row["hits"])
      minutes = if playtime > 0, do: playtime / 60.0, else: 0.0

      personaname =
        case str(profile["personaname"]) do
          "" -> row["personaname"] |> str()
          name -> name
        end

      avatar =
        case str(profile["avatarfull"]) do
          "" -> default_avatar
          url -> url
        end

      accuracy = if shots > 0, do: Float.round(hits * 100.0 / shots, 1), else: 0.0
      dpm = if minutes > 0, do: Float.round(damage / minutes, 1), else: 0.0
      dtpm = if minutes > 0, do: Float.round(damage_taken / minutes, 1), else: 0.0
      kd = if deaths > 0, do: Float.round(kills / deaths, 2), else: kills * 1.0

      %{
        steamid: steamid,
        personaname: if(personaname == "", do: steamid, else: personaname),
        avatar: avatar,
        profileurl: if(steamid != "", do: "https://steamcommunity.com/profiles/" <> steamid, else: nil),
        kills: kills,
        deaths: deaths,
        assists: assists,
        healing: int(row["healing"]),
        headshots: int(row["headshots"]),
        backstabs: int(row["backstabs"]),
        best_killstreak: int(row["best_killstreak"]),
        total_ubers: int(row["total_ubers"]),
        medic_drops: int(row["medic_drops"]),
        uber_drops: int(row["uber_drops"]),
        airshots: int(row["airshots"]),
        favorite_class: int(row["favorite_class"]),
        playtime: playtime,
        playtime_human: format_playtime(playtime),
        damage_dealt: damage,
        damage_taken: damage_taken,
        accuracy_overall: accuracy,
        dpm: dpm,
        dtpm: dtpm,
        kd: kd,
        score: kills + assists,
        is_admin: Map.get(admin_flags, steamid, false),
        is_online: false,
        last_seen: int(row["last_seen"])
      }
    end)
  end

  defp count_table(table), do: scalar_query("SELECT COUNT(*) FROM #{table}", [])

  defp summary_top_killstreak do
    favorite_class_expr = favorite_class_select_expr()

    sql = """
    SELECT steamid,
           COALESCE(cached_personaname, personaname, steamid) AS personaname,
           kills, deaths, assists, healing, headshots, backstabs,
           COALESCE(best_killstreak, 0) AS best_killstreak,
           COALESCE(playtime, 0) AS playtime,
           COALESCE(damage_dealt, 0) AS damage_dealt,
           COALESCE(damage_taken, 0) AS damage_taken,
           COALESCE(shots, 0) AS shots,
           COALESCE(hits, 0) AS hits,
           COALESCE(total_ubers, 0) AS total_ubers,
           COALESCE(medic_drops, 0) AS medic_drops,
           COALESCE(uber_drops, COALESCE(medic_drops, 0)) AS uber_drops,
           COALESCE(airshots, 0) AS airshots,
           #{favorite_class_expr} AS favorite_class,
           COALESCE(last_seen, 0) AS last_seen
    FROM #{@stats_table}
    ORDER BY COALESCE(best_killstreak, 0) DESC, kills DESC
    LIMIT 1
    """

    case SQL.query(Repo, sql, []) do
      {:ok, %{rows: [row], columns: cols}} ->
        enriched =
          row
          |> row_map(cols)
          |> then(&enrich_cumulative_rows([&1]))
          |> List.first()

        top_killstreak = if is_map(enriched), do: int(enriched[:best_killstreak]), else: 0

        %{
          top_killstreak: top_killstreak,
          top_killstreak_owner: if(top_killstreak > 0, do: enriched, else: nil)
        }

      _ ->
        %{top_killstreak: 0, top_killstreak_owner: nil}
    end
  rescue
    _ -> %{top_killstreak: 0, top_killstreak_owner: nil}
  end

  defp summary_insights do
    windows = summary_time_windows()

    monthly_playtime_seconds =
      scalar_query(
        "SELECT COALESCE(SUM(duration), 0) FROM #{@logs_table} WHERE started_at >= ? AND started_at < ?",
        [windows.month_start, windows.next_month_start]
      )

    players_current_month =
      scalar_query(
        """
        SELECT COUNT(DISTINCT lp.steamid)
        FROM #{@log_players_table} lp
        INNER JOIN #{@logs_table} l ON l.log_id = lp.log_id
        WHERE l.started_at >= ? AND l.started_at < ?
        """,
        [windows.month_start, windows.next_month_start]
      )

    weekly_player_sql = """
    SELECT COUNT(DISTINCT lp.steamid)
    FROM #{@log_players_table} lp
    INNER JOIN #{@logs_table} l ON l.log_id = lp.log_id
    WHERE l.started_at >= ? AND l.started_at < ?
    """

    players_current_week = scalar_query(weekly_player_sql, [windows.current_week_start, windows.now_ts])
    players_previous_week = scalar_query(weekly_player_sql, [windows.previous_week_start, windows.current_week_start])

    {players_week_change_percent, players_week_trend} =
      cond do
        players_previous_week > 0 ->
          pct = ((players_current_week - players_previous_week) / players_previous_week) * 100.0

          trend =
            cond do
              pct > 0.5 -> "up"
              pct < -0.5 -> "down"
              true -> "flat"
            end

          {pct, trend}

        players_current_week > 0 ->
          {nil, "up"}

        true ->
          {nil, "flat"}
      end

    {best_killstreak_week, best_killstreak_week_leaders} = weekly_killstreak_podium(windows.current_week_start)
    {weekly_top_dpm, weekly_top_dpm_owner} = weekly_top_dpm(windows.current_week_start)

    %{
      playtime_month_hours: Float.round(monthly_playtime_seconds / 3600.0, 1),
      playtime_month_label: windows.month_label,
      players_current_week: players_current_week,
      players_current_month: players_current_month,
      players_previous_week: players_previous_week,
      players_week_change_percent: players_week_change_percent,
      players_week_trend: players_week_trend,
      best_killstreak_week: best_killstreak_week,
      best_killstreak_week_leaders: best_killstreak_week_leaders,
      weekly_top_dpm: weekly_top_dpm,
      weekly_top_dpm_owner: weekly_top_dpm_owner,
      gamemode_top: gamemode_top()
    }
  rescue
    e ->
      Logger.error("StatsFeed.summary_insights failed: " <> Exception.format(:error, e, __STACKTRACE__))

      %{
        playtime_month_hours: 0.0,
        playtime_month_label: "Month",
        players_current_week: 0,
        players_current_month: 0,
        players_previous_week: 0,
        players_week_change_percent: nil,
        players_week_trend: "flat",
        best_killstreak_week: 0,
        best_killstreak_week_leaders: [],
        weekly_top_dpm: 0.0,
        weekly_top_dpm_owner: nil,
        gamemode_top: []
      }
  end

  defp weekly_killstreak_podium(week_start_ts) do
    sql = """
    SELECT lp.log_id,
           lp.steamid,
           lp.personaname,
           COALESCE(lp.best_streak, 0) AS best_streak,
           COALESCE(lp.kills, 0) AS kills,
           l.started_at
    FROM #{@log_players_table} lp
    INNER JOIN #{@logs_table} l ON l.log_id = lp.log_id
    WHERE l.started_at >= ?
      AND lp.log_id = (
        SELECT lp2.log_id
        FROM #{@log_players_table} lp2
        INNER JOIN #{@logs_table} l2 ON l2.log_id = lp2.log_id
        WHERE lp2.steamid = lp.steamid
          AND l2.started_at >= ?
        ORDER BY COALESCE(lp2.best_streak, 0) DESC, COALESCE(lp2.kills, 0) DESC, l2.started_at DESC
        LIMIT 1
      )
    ORDER BY COALESCE(lp.best_streak, 0) DESC, COALESCE(lp.kills, 0) DESC, l.started_at DESC
    LIMIT 3
    """

    rows =
      case SQL.query(Repo, sql, [week_start_ts, week_start_ts]) do
        {:ok, %{rows: rs, columns: cols}} -> Enum.map(rs, &row_map(&1, cols))
        _ -> []
      end

    rows = Enum.filter(rows, fn row -> int(row["best_streak"]) > 0 end)

    if rows == [] do
      {0, []}
    else
      steamids =
        rows
        |> Enum.map(&str(&1["steamid"]))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      profiles = SteamProfiles.fetch_many(steamids)
      default_avatar = default_avatar_url()

      leaders =
        Enum.map(rows, fn row ->
          steamid = str(row["steamid"])
          profile = profiles[steamid] || %{}

          %{
            steamid: steamid,
            personaname: str(profile["personaname"]) |> fallback_blank(str(row["personaname"]) |> fallback_blank(steamid)),
            avatar: str(profile["avatarfull"]) |> fallback_blank(default_avatar),
            profileurl: "https://steamcommunity.com/profiles/" <> steamid,
            best_streak: int(row["best_streak"]),
            kills: int(row["kills"])
          }
        end)

      {int(hd(leaders).best_streak), leaders}
    end
  rescue
    _ -> {0, []}
  end

  defp weekly_top_dpm(week_start_ts) do
    sql = """
    SELECT lp.steamid, lp.personaname, COALESCE(lp.damage, 0) AS damage, COALESCE(lp.playtime, 0) AS playtime
    FROM #{@log_players_table} lp
    INNER JOIN #{@logs_table} l ON l.log_id = lp.log_id
    WHERE l.started_at >= ? AND COALESCE(lp.playtime, 0) > 0
    ORDER BY (COALESCE(lp.damage, 0) * 60.0 / NULLIF(lp.playtime, 0)) DESC,
             COALESCE(lp.damage, 0) DESC,
             l.started_at DESC
    LIMIT 1
    """

    case SQL.query(Repo, sql, [week_start_ts]) do
      {:ok, %{rows: [row], columns: cols}} ->
        m = row_map(row, cols)
        playtime = int(m["playtime"])
        damage = int(m["damage"])

        if playtime > 0 do
          steamid = str(m["steamid"])
          dpm = Float.round((damage * 60.0) / playtime, 1)
          profile = SteamProfiles.fetch_many([steamid])[steamid] || %{}
          default_avatar = default_avatar_url()

          owner = %{
            steamid: steamid,
            personaname: str(profile["personaname"]) |> fallback_blank(str(m["personaname"]) |> fallback_blank(steamid)),
            avatar: str(profile["avatarfull"]) |> fallback_blank(default_avatar),
            profileurl: "https://steamcommunity.com/profiles/" <> steamid
          }

          {dpm, owner}
        else
          {0.0, nil}
        end

      _ ->
        {0.0, nil}
    end
  rescue
    _ -> {0.0, nil}
  end

  defp gamemode_top do
    sql = """
    SELECT gamemode, COUNT(*) AS mode_count
    FROM #{@logs_table}
    WHERE gamemode IS NOT NULL AND gamemode <> ''
    GROUP BY gamemode
    """

    rows =
      case SQL.query(Repo, sql, []) do
        {:ok, %{rows: rs, columns: cols}} -> Enum.map(rs, &row_map(&1, cols))
        _ -> []
      end

    total = Enum.reduce(rows, 0, fn row, acc -> acc + int(row["mode_count"]) end)

    rows
    |> Enum.sort_by(fn row -> {-int(row["mode_count"]), str(row["gamemode"])} end)
    |> Enum.take(3)
    |> Enum.map(fn row ->
      count = int(row["mode_count"])

      %{
        label: format_gamemode_label(str(row["gamemode"])),
        count: count,
        percentage: if(total > 0, do: Float.round(count * 100.0 / total, 1), else: 0.0)
      }
    end)
  rescue
    _ -> []
  end

  defp summary_time_windows do
    sql = """
    SELECT
      UNIX_TIMESTAMP(NOW()) AS now_ts,
      UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 7 DAY)) AS current_week_start,
      UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 14 DAY)) AS previous_week_start,
      UNIX_TIMESTAMP(DATE_FORMAT(NOW(), '%Y-%m-01 00:00:00')) AS month_start,
      UNIX_TIMESTAMP(DATE_FORMAT(DATE_ADD(NOW(), INTERVAL 1 MONTH), '%Y-%m-01 00:00:00')) AS next_month_start,
      DATE_FORMAT(NOW(), '%M') AS month_label
    """

    case SQL.query(Repo, sql, []) do
      {:ok, %{rows: [row], columns: cols}} ->
        m = row_map(row, cols)

        %{
          now_ts: int(m["now_ts"]),
          current_week_start: int(m["current_week_start"]),
          previous_week_start: int(m["previous_week_start"]),
          month_start: int(m["month_start"]),
          next_month_start: int(m["next_month_start"]),
          month_label: fallback_blank(str(m["month_label"]), "Month")
        }

      _ ->
        now = System.system_time(:second)
        %{now_ts: now, current_week_start: now - 7 * 86_400, previous_week_start: now - 14 * 86_400, month_start: 0, next_month_start: now, month_label: "Month"}
    end
  rescue
    _ ->
      now = System.system_time(:second)
      %{now_ts: now, current_week_start: now - 7 * 86_400, previous_week_start: now - 14 * 86_400, month_start: 0, next_month_start: now, month_label: "Month"}
  end

  defp format_gamemode_label(gamemode) do
    case gamemode |> str() |> String.trim() |> String.downcase() do
      "" -> "Unknown"
      "koth" -> "Koth"
      "king of the hill" -> "Koth"
      "payload" -> "Payload"
      "payload race" -> "Payload Race"
      "payload - race" -> "Payload Race"
      "cp" -> "CP"
      "control point" -> "Control Point"
      "attack/defend cp" -> "Attack/Defend"
      "attack/defend" -> "Attack/Defend"
      "arena" -> "Arena"
      "mge" -> "MGE"
      "ctf" -> "CTF"
      "mann vs machine" -> "MvM"
      "rd" -> "Robot Destruction"
      "passtime" -> "Pass Time"
      other when byte_size(other) <= 3 -> String.upcase(other)
      other -> other |> String.split() |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp fallback_blank("", default), do: default
  defp fallback_blank(nil, default), do: default
  defp fallback_blank(v, _default), do: v

  defp favorite_class_select_expr do
    if favorite_class_supported?(), do: "COALESCE(favorite_class, 0)", else: "0"
  end

  defp favorite_class_supported? do
    key = {__MODULE__, :favorite_class_supported}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        supported =
          case SQL.query(Repo, "SHOW COLUMNS FROM #{@stats_table} LIKE 'favorite_class'", []) do
            {:ok, %{rows: rows}} when is_list(rows) -> rows != []
            _ -> false
          end

        :persistent_term.put(key, supported)
        supported

      true -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp scalar_query(sql, params) do
    case SQL.query(Repo, sql, params) do
      {:ok, %{rows: [[v | _] | _]}} -> int(v)
      {:ok, %{rows: rows}} when rows == [] -> 0
      _ -> 0
    end
  end

  defp stats_order_clause do
    ratio_expr = "COALESCE((kills + (0.5 * assists)) / NULLIF(deaths, 0), (kills + (0.5 * assists)))"

    "CASE WHEN playtime >= #{@stats_min_playtime_sort} THEN #{ratio_expr} ELSE -1 END DESC, (kills + assists) DESC, kills DESC"
  end

  defp logs_scope(value) do
    case value |> str() |> String.downcase() |> String.trim() do
      "short" -> "short"
      "all" -> "all"
      _ -> "regular"
    end
  end

  defp logs_scope_sql("short"), do: {" AND player_count >= ? AND player_count <= ?", [2, 12]}
  defp logs_scope_sql("all"), do: {"", []}
  defp logs_scope_sql(_), do: {"", []}

  defp attach_log_players([]), do: []

  defp attach_log_players(logs) do
    log_ids = logs |> Enum.map(& &1.log_id) |> Enum.filter(&(&1 && &1 != ""))

    players_by_log =
      case fetch_log_players(log_ids) do
        {:ok, players} -> players
        _ -> %{}
      end

    Enum.map(logs, fn log -> Map.put(log, :players, Map.get(players_by_log, log.log_id, [])) end)
  end

  defp fetch_log_players([]), do: {:ok, %{}}

  defp fetch_log_players(log_ids) do
    placeholders = Enum.map_join(log_ids, ",", fn _ -> "?" end)

    sql = """
    SELECT log_id, steamid, personaname, kills, deaths, assists, damage, damage_taken, healing,
           headshots, backstabs, total_ubers, playtime, shots, hits,
           COALESCE(airshots, 0) AS airshots, COALESCE(is_admin, 0) AS is_admin
    FROM #{@log_players_table}
    WHERE log_id IN (#{placeholders})
    ORDER BY log_id ASC, kills DESC, assists DESC
    """

    case SQL.query(Repo, sql, log_ids) do
      {:ok, %{rows: rows, columns: cols}} ->
        mapped = Enum.map(rows, &row_map(&1, cols))
        enriched = enrich_log_players(mapped)
        grouped = Enum.group_by(enriched, &str(&1.log_id))
        {:ok, grouped}

      {:error, _} ->
        fallback_sql = """
        SELECT log_id, steamid, personaname, kills, deaths, assists, damage, damage_taken, healing,
               headshots, backstabs, total_ubers, playtime, shots, hits
        FROM #{@log_players_table}
        WHERE log_id IN (#{placeholders})
        ORDER BY log_id ASC, kills DESC, assists DESC
        """

        case SQL.query(Repo, fallback_sql, log_ids) do
          {:ok, %{rows: rows, columns: cols}} ->
            mapped = Enum.map(rows, &row_map(&1, cols)) |> Enum.map(&Map.put_new(&1, "airshots", 0))
            enriched = enrich_log_players(mapped)
            {:ok, Enum.group_by(enriched, &str(&1.log_id))}

          err ->
            err
        end
    end
  rescue
    _ -> {:error, :failed}
  end

  defp enrich_log_players(rows) do
    steam_ids =
      rows
      |> Enum.map(&str(&1["steamid"]))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    profiles = SteamProfiles.fetch_many(steam_ids)
    admin_flags = admin_flags_for_ids(steam_ids)
    default_avatar = default_avatar_url()

    Enum.map(rows, fn row ->
      steamid = str(row["steamid"])
      profile = Map.get(profiles, steamid, %{})
      personaname =
        case str(profile["personaname"]) do
          "" -> str(row["personaname"])
          name -> name
        end

      avatar =
        case str(profile["avatarfull"]) do
          "" -> default_avatar
          url -> url
        end

      %{
        log_id: str(row["log_id"]),
        steamid: steamid,
        personaname: if(personaname == "", do: steamid, else: personaname),
        avatar: avatar,
        profileurl: if(steamid != "", do: "https://steamcommunity.com/profiles/" <> steamid, else: nil),
        is_admin: Map.get(admin_flags, steamid, false) || truthy?(row["is_admin"]),
        kills: int(row["kills"]),
        deaths: int(row["deaths"]),
        assists: int(row["assists"]),
        damage: int(row["damage"]),
        damage_taken: int(row["damage_taken"]),
        healing: int(row["healing"]),
        headshots: int(row["headshots"]),
        backstabs: int(row["backstabs"]),
        total_ubers: int(row["total_ubers"]),
        playtime: int(row["playtime"]),
        shots: int(row["shots"]),
        hits: int(row["hits"]),
        airshots: int(row["airshots"])
      }
    end)
  end

  defp admin_flags_for_ids([]), do: %{}

  defp admin_flags_for_ids(ids) do
    cache_file =
      Application.get_env(
        :whale_chat,
        :mapsdb_admin_cache_file,
        "/var/www/kogasatopia/stats/cache/admins_cache.json"
      )

    with {:ok, json} <- File.read(cache_file),
         {:ok, %{"admins" => admins}} <- Jason.decode(json) do
      Enum.reduce(ids, %{}, fn id, acc -> Map.put(acc, id, truthy?(Map.get(admins, id))) end)
    else
      _ -> %{}
    end
  end

  defp format_playtime(seconds) when seconds <= 0, do: "0m"

  defp format_playtime(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      hours > 0 and minutes > 0 -> "#{hours}h #{minutes}m"
      hours > 0 -> "#{hours}h"
      true -> "#{minutes}m"
    end
  end

  defp truthy?(v) when v in [true, 1, "1", "true", "yes", "on"], do: true
  defp truthy?(_), do: false

  defp row_map(row, cols), do: Enum.zip(cols, row) |> Map.new()

  defp ceil_div(total, per_page) when per_page > 0, do: div(total + per_page - 1, per_page)

  defp positive_int(value, default) do
    case value do
      v when is_integer(v) and v > 0 -> v
      v when is_binary(v) ->
        case Integer.parse(v) do
          {i, _} when i > 0 -> i
          _ -> default
        end

      _ ->
        default
    end
  end

  defp str(nil), do: ""
  defp str(v) when is_binary(v), do: v
  defp str(v), do: to_string(v)

  defp int(nil), do: 0
  defp int(v) when is_integer(v), do: v
  defp int(v) when is_float(v), do: trunc(v)
  defp int(%Decimal{} = v), do: v |> Decimal.round(0) |> Decimal.to_integer()

  defp int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> 0
    end
  end
  defp int(_), do: 0

  defp floaty(nil), do: 0.0
  defp floaty(v) when is_float(v), do: v
  defp floaty(v) when is_integer(v), do: v / 1
  defp floaty(%Decimal{} = v), do: Decimal.to_float(v)
  defp floaty(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error ->
        case Integer.parse(v) do
          {i, _} -> i / 1
          :error -> 0.0
        end
    end
  end
  defp floaty(_), do: 0.0

end
