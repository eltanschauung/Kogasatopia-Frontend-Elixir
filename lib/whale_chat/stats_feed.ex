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

      %{
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

  defp int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp int(_), do: 0
end
