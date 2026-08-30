defmodule KogasaFrontend.MapsDb do
  @moduledoc false

  import Ecto.Query
  import KogasaFrontend.Value, only: [float: 1, int: 1]

  alias KogasaFrontend.DisplayFormat
  alias KogasaFrontend.MapsDb.Cache
  alias KogasaFrontend.MapsDb.ConfigBrowser
  alias KogasaFrontend.MapsDb.MapMeta
  alias KogasaFrontend.QueryResult
  alias KogasaFrontend.LegacyPaths
  alias KogasaFrontend.Repo
  alias KogasaFrontend.TimeDisplay
  alias KogasaFrontend.Tf2Classes
  alias KogasaFrontend.WeaponsConfig

  @population_statistics_table "server_population_statistics_samples"
  @map_session_statistics_table "map_statistics_sessions"
  @vote_statistics_table "nativevotes_statistics_events"
  @custom_weapon_popularity_table "cwx_weapon_popularity"
  @plugin_statistics_table "plugin_statistics_events"
  @class_popularity_order [1, 3, 7, 4, 6, 9, 5, 2, 8]

  def config do
    %{
      maps_dir:
        Application.get_env(
          :kogasa_frontend,
          :mapsdb_dir,
          "/home/kogasa/hlserver/tf2/tf/cfg/mapsdb"
        ),
      tf_cfg_dir:
        Application.get_env(
          :kogasa_frontend,
          :mapsdb_tf_cfg_dir,
          "/home/kogasa/hlserver/tf2/tf/cfg"
        ),
      preview_dir:
        Application.get_env(
          :kogasa_frontend,
          :mapsdb_preview_dir,
          LegacyPaths.playercount_widget_dir()
        )
    }
  end

  def page_data do
    cfg = config()
    maps_dir_missing = not File.dir?(cfg.maps_dir)
    cache_entry = cached_page_payload()

    Map.merge(cache_entry.payload, %{
      maps_dir: cfg.maps_dir,
      maps_dir_missing: maps_dir_missing,
      analytics_cache_hash: cache_entry.hash,
      analytics_cached_at: cache_entry.generated_at,
      map_previews: map_previews(cfg.preview_dir),
      map_sections: if(maps_dir_missing, do: [], else: build_page_sections(cfg))
    })
  end

  def build_cache_payload do
    chart_bundle = popularity_chart_bundle()

    %{
      popular_maps: fetch_map_popularity(25),
      popularity_chart: chart_bundle.chart,
      popularity_active_hours: chart_bundle.active_hours,
      map_analytics: map_detail_analytics()
    }
  end

  def list_api_maps, do: ConfigBrowser.list_api_maps(config())

  def load_config_file(map, source) do
    ConfigBrowser.load_config_file(map, source, config())
  end

  def build_page_sections(cfg \\ config()), do: ConfigBrowser.build_page_sections(cfg)

  def fetch_map_popularity(limit \\ 50) do
    lim = max(1, min(limit, 500))

    Repo.all(
      from m in MapMeta,
        order_by: [desc: m.popularity, asc: m.map_name],
        limit: ^lim,
        select: %{
          map_name: m.map_name,
          category: m.category,
          sub_category: m.sub_category,
          popularity: m.popularity
        }
    )
  end

  def active_hours_last_days(days \\ 30) do
    days = days |> int() |> max(1) |> min(366)

    case query_rows("""
         SELECT UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL #{days} DAY)) AS start_ts,
                UNIX_TIMESTAMP(NOW()) AS end_ts
         """) do
      [%{start_ts: start_ts, end_ts: end_ts}] -> active_hours_between(start_ts, end_ts)
      _ -> 0
    end
  end

  def active_hours_between(start_ts, end_ts) do
    start_ts = int(start_ts)
    end_ts = int(end_ts)

    if start_ts <= 0 or end_ts <= start_ts do
      0
    else
      sql = """
      SELECT COUNT(*) AS active_hours
      FROM (
        SELECT FLOOR(sampled_at / 3600) AS hour_bucket
        FROM mapsdb_popularity_log
        WHERE sampled_at >= ?
          AND sampled_at < ?
          AND player_count > 2
          AND map_name NOT LIKE 'mge\\\\_%' ESCAPE '\\\\'
        GROUP BY hour_bucket
      ) active_hour_buckets
      """

      case Repo.query(sql, [start_ts, end_ts]) do
        {:ok, %{rows: [[active_hours]]}} -> int(active_hours)
        _ -> 0
      end
    end
  rescue
    _ -> 0
  end

  def map_detail_analytics do
    rows = fetch_map_detail_rows(40)

    %{
      rows: rows,
      top_sessions: fetch_session_extremes(:top, 8),
      worst_sessions: fetch_session_extremes(:worst, 8),
      weekday_hours: fetch_weekday_hour_performance(12),
      class_popularity: fetch_class_popularity(),
      popular_custom_weapons: fetch_popular_custom_weapons(),
      best_performing_chart: rows |> Enum.take(15) |> fetch_map_lifecycle_chart(10),
      vote_table_available: table_exists?(@vote_statistics_table)
    }
  end

  defp fetch_map_detail_rows(limit) do
    lim = max(1, min(limit, 100))

    sessions =
      query_rows("""
      SELECT s.map_name,
             MIN(s.gamemode) AS gamemode,
             COUNT(*) AS sessions,
             ROUND(AVG(s.avg_players), 2) AS avg_players,
             MAX(s.peak_players) AS peak_players,
             ROUND(SUM(s.player_seconds) / 3600, 1) AS player_hours,
             SUM(s.joins) AS joins,
             SUM(s.leaves) AS leaves
      FROM #{@map_session_statistics_table} s
      WHERE #{valid_map_session_sql("s")}
      GROUP BY s.map_name
      ORDER BY player_hours DESC, avg_players DESC
      LIMIT #{lim}
      """)

    first15 =
      query_rows("""
      SELECT p.map_name,
             ROUND(AVG(CASE WHEN p.map_elapsed_seconds BETWEEN 0 AND 899 THEN p.player_count END), 2) AS first15_avg,
             ROUND(
               COALESCE(AVG(CASE WHEN p.map_elapsed_seconds BETWEEN 600 AND 899 THEN p.player_count END), 0) -
               COALESCE(AVG(CASE WHEN p.map_elapsed_seconds BETWEEN 0 AND 299 THEN p.player_count END), 0),
               2
             ) AS first15_growth
      FROM #{@population_statistics_table} p
      JOIN #{@map_session_statistics_table} s
        ON s.host_port = p.host_port
       AND s.map_session_id = p.map_session_id
       AND s.map_name = p.map_name
      WHERE p.map_elapsed_seconds BETWEEN 0 AND 899
        AND #{valid_map_session_sql("s")}
        AND #{valid_population_sample_sql("p", "s")}
      GROUP BY p.map_name
      """)
      |> Map.new(fn row -> {row.map_name, row} end)

    best_slots =
      query_rows("""
      SELECT s.map_name,
             s.weekday,
             s.hour_of_day,
             COUNT(*) AS sessions,
             ROUND(AVG(s.avg_players), 2) AS avg_players
      FROM #{@map_session_statistics_table} s
      WHERE #{valid_map_session_sql("s")}
      GROUP BY s.map_name, s.weekday, s.hour_of_day
      ORDER BY s.map_name ASC, avg_players DESC, sessions DESC
      """)
      |> Enum.group_by(& &1.map_name)
      |> Map.new(fn {map_name, slots} -> {map_name, List.first(slots)} end)

    vote_pressure = fetch_vote_pressure()

    Enum.map(sessions, fn row ->
      first = Map.get(first15, row.map_name, %{})
      best = Map.get(best_slots, row.map_name)
      votes = Map.get(vote_pressure, row.map_name, %{})

      avg_players = float(row.avg_players)
      player_hours = float(row.player_hours)
      first15_avg = float(Map.get(first, :first15_avg))
      first15_growth = float(Map.get(first, :first15_growth))

      %{
        map_name: row.map_name || "",
        gamemode: row.gamemode || "",
        sessions: int(row.sessions),
        avg_players: avg_players,
        avg_players_display: DisplayFormat.decimal(avg_players, 1),
        peak_players: int(row.peak_players),
        player_hours: player_hours,
        player_hours_display: DisplayFormat.decimal(player_hours, 1),
        joins: int(row.joins),
        leaves: int(row.leaves),
        first15_avg: first15_avg,
        first15_avg_display: DisplayFormat.decimal(first15_avg, 1),
        first15_growth: first15_growth,
        first15_growth_display: DisplayFormat.signed_decimal(first15_growth, 1),
        best_slot: format_slot(best),
        best_slot_avg_display: DisplayFormat.decimal(Map.get(best || %{}, :avg_players), 1),
        nominations: int(Map.get(votes, :nominations)),
        rtvs: int(Map.get(votes, :rtvs)),
        vote_options: int(Map.get(votes, :vote_options)),
        vote_wins: int(Map.get(votes, :vote_wins))
      }
    end)
  end

  defp fetch_session_extremes(:worst, limit) do
    lim = max(1, min(limit, 25))

    query_rows("""
    SELECT s.map_name,
           s.map_session_id,
           s.started_at,
           s.duration,
           MAX(p.player_count) AS peak_players,
           ROUND(AVG(p.player_count), 2) AS avg_players,
           SUM(p.player_seconds_delta) AS player_seconds,
           SUM(p.joining_players) AS joins,
           SUM(p.leaving_players) AS leaves,
           s.end_reason
    FROM #{@map_session_statistics_table} s
    JOIN #{@population_statistics_table} p
      ON p.host_port = s.host_port
     AND p.map_session_id = s.map_session_id
     AND p.map_name = s.map_name
    WHERE #{valid_map_session_sql("s")}
      AND s.start_players >= 10
      AND #{valid_population_sample_sql("p", "s")}
      AND p.player_count > 3
      AND FLOOR(MOD(p.sampled_at, 86400) / 3600) >= 2
      AND FLOOR(MOD(p.sampled_at, 86400) / 3600) < 5
    GROUP BY s.host_port, s.map_session_id, s.map_name, s.started_at, s.duration, s.end_reason
    HAVING peak_players > 4
    ORDER BY avg_players ASC, peak_players ASC, duration DESC
    LIMIT #{lim}
    """)
    |> format_session_extreme_rows()
  end

  defp fetch_session_extremes(_kind, limit) do
    lim = max(1, min(limit, 25))

    query_rows("""
    SELECT s.map_name,
           s.map_session_id,
           s.started_at,
           s.duration,
           s.peak_players,
           s.avg_players,
           s.player_seconds,
           s.joins,
           s.leaves,
           s.end_reason
    FROM #{@map_session_statistics_table} s
    WHERE #{valid_map_session_sql("s")}
    ORDER BY s.avg_players DESC, s.peak_players DESC, s.duration DESC
    LIMIT #{lim}
    """)
    |> format_session_extreme_rows()
  end

  defp format_session_extreme_rows(rows) do
    rows
    |> Enum.map(fn row ->
      avg_players = float(row.avg_players)

      %{
        map_name: row.map_name || "",
        map_session_id: row.map_session_id || "",
        started_at: int(row.started_at),
        started_display: format_date(int(row.started_at)),
        duration_display: DisplayFormat.duration(int(row.duration)),
        peak_players: int(row.peak_players),
        avg_players: avg_players,
        avg_players_display: DisplayFormat.decimal(avg_players, 1),
        player_hours_display: DisplayFormat.decimal(float(row.player_seconds) / 3600.0, 1),
        joins: int(row.joins),
        leaves: int(row.leaves),
        end_reason: row.end_reason || ""
      }
    end)
  end

  defp fetch_weekday_hour_performance(limit) do
    lim = max(1, min(limit, 48))

    query_rows("""
    SELECT s.weekday,
           s.hour_of_day,
           COUNT(*) AS sessions,
           ROUND(AVG(s.avg_players), 2) AS avg_players,
           MAX(s.peak_players) AS peak_players,
           ROUND(SUM(s.player_seconds) / 3600, 1) AS player_hours
    FROM #{@map_session_statistics_table} s
    WHERE #{valid_map_session_sql("s")}
    GROUP BY s.weekday, s.hour_of_day
    ORDER BY avg_players DESC, sessions DESC
    LIMIT #{lim}
    """)
    |> Enum.map(fn row ->
      %{
        slot: format_slot(row),
        sessions: int(row.sessions),
        avg_players_display: DisplayFormat.decimal(row.avg_players, 1),
        peak_players: int(row.peak_players),
        player_hours_display: DisplayFormat.decimal(row.player_hours, 1)
      }
    end)
  end

  defp fetch_class_popularity do
    if table_exists?(@plugin_statistics_table) do
      counts =
        query_rows("""
        SELECT CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(message, 'class=', -1), '|', 1) AS UNSIGNED) AS class_id,
               COUNT(*) AS samples
        FROM #{@plugin_statistics_table} FORCE INDEX (idx_source_event_time)
        WHERE source_plugin = 'classlimits'
          AND event_name = 'class_snapshot'
        GROUP BY class_id
        """)
        |> Map.new(fn row -> {int(row.class_id), int(row.samples)} end)

      total =
        @class_popularity_order
        |> Enum.map(&Map.get(counts, &1, 0))
        |> Enum.sum()

      Enum.map(@class_popularity_order, fn class_id ->
        samples = Map.get(counts, class_id, 0)
        percentage = if total > 0, do: samples / total * 100.0, else: 0.0
        {:ok, {label, icon}} = Tf2Classes.leaderboard_icon_for_id(class_id)

        %{
          class_id: class_id,
          label: label,
          icon: icon,
          samples: samples,
          percentage: percentage,
          percentage_display: DisplayFormat.decimal(percentage, 1) <> "%",
          bar_width: DisplayFormat.decimal(percentage, 4) <> "%"
        }
      end)
    else
      []
    end
  end

  defp fetch_popular_custom_weapons do
    if table_exists?(@custom_weapon_popularity_table) do
      custom_names = WeaponsConfig.custom_item_names()

      query_rows("""
      SELECT weapon_uid,
             COUNT(DISTINCT steamid64) AS equipped_clients
      FROM #{@custom_weapon_popularity_table}
      WHERE equipped != 0
        AND weapon_uid <> ''
      GROUP BY weapon_uid
      HAVING equipped_clients > 1
      ORDER BY equipped_clients DESC, weapon_uid ASC
      """)
      |> Enum.map(fn row ->
        weapon_uid = to_string(row.weapon_uid || "")

        %{
          weapon_uid: weapon_uid,
          name: Map.get(custom_names, weapon_uid, weapon_uid),
          equipped_clients: int(row.equipped_clients)
        }
      end)
    else
      []
    end
  end

  defp fetch_map_lifecycle_chart(rows, bucket_count) do
    map_names =
      rows
      |> Enum.map(& &1.map_name)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(15)

    bucket_count = max(1, min(bucket_count, 20))
    common_seconds = fetch_common_lifecycle_seconds(map_names)
    labels = lifecycle_chart_labels(bucket_count, common_seconds)

    if map_names == [] or common_seconds <= 0 do
      %{"labels" => labels, "series" => []}
    else
      rows =
        query_rows("""
        SELECT p.map_name,
               LEAST(#{bucket_count - 1}, FLOOR((p.map_elapsed_seconds * #{bucket_count}) / #{common_seconds})) AS bucket,
               ROUND(AVG(CASE WHEN p.player_count > 23 THEN 24 ELSE p.player_count END), 2) AS avg_players
        FROM #{@population_statistics_table} p
        JOIN #{@map_session_statistics_table} s
          ON s.host_port = p.host_port
         AND s.map_session_id = p.map_session_id
         AND s.map_name = p.map_name
        WHERE p.map_name IN (#{sql_string_list(map_names)})
          AND p.map_elapsed_seconds >= 0
          AND p.map_elapsed_seconds <= #{common_seconds}
          AND #{valid_map_session_sql("s")}
          AND #{valid_population_sample_sql("p", "s")}
        GROUP BY p.map_name, bucket
        ORDER BY p.map_name ASC, bucket ASC
        """)

      values =
        rows
        |> Enum.group_by(& &1.map_name)
        |> Map.new(fn {map_name, points} ->
          point_map =
            Map.new(points, fn point -> {int(point.bucket), float(point.avg_players)} end)

          {map_name, point_map}
        end)

      series =
        Enum.map(map_names, fn map_name ->
          %{
            "label" => map_name,
            "data" =>
              values
              |> Map.get(map_name, %{})
              |> lifecycle_chart_data(bucket_count)
          }
        end)

      %{"labels" => labels, "series" => series}
    end
  end

  defp fetch_common_lifecycle_seconds([]), do: 0

  defp fetch_common_lifecycle_seconds(map_names) do
    query_rows("""
    SELECT MIN(map_max_elapsed) AS common_seconds
    FROM (
      SELECT p.map_name,
             MAX(LEAST(p.map_elapsed_seconds, s.duration)) AS map_max_elapsed
      FROM #{@population_statistics_table} p
      JOIN #{@map_session_statistics_table} s
        ON s.host_port = p.host_port
       AND s.map_session_id = p.map_session_id
       AND s.map_name = p.map_name
      WHERE p.map_name IN (#{sql_string_list(map_names)})
        AND p.map_elapsed_seconds >= 0
        AND #{valid_map_session_sql("s")}
        AND #{valid_population_sample_sql("p", "s")}
      GROUP BY p.map_name
    ) map_ends
    """)
    |> case do
      [%{common_seconds: seconds}] -> int(seconds)
      _ -> 0
    end
  end

  defp lifecycle_chart_data(point_map, bucket_count) do
    values = for bucket <- 0..(bucket_count - 1), do: Map.get(point_map, bucket)
    first_value = Enum.find(values, &(!is_nil(&1)))

    values
    |> Enum.map_reduce(first_value, fn
      nil, last_value -> {last_value, last_value}
      value, _last_value -> {value, value}
    end)
    |> elem(0)
  end

  defp lifecycle_chart_labels(bucket_count, common_seconds) do
    for bucket <- 0..(bucket_count - 1) do
      cond do
        bucket == 0 ->
          "Start"

        bucket == bucket_count - 1 ->
          "End"

        common_seconds > 0 ->
          minutes = round(bucket * common_seconds / max(bucket_count - 1, 1) / 60)
          "#{minutes}m"

        true ->
          "#{div(bucket * 100, bucket_count)}%"
      end
    end
  end

  defp fetch_vote_pressure do
    if table_exists?(@vote_statistics_table) do
      query_rows("""
      SELECT map_name,
             SUM(event_type = 'nomination') AS nominations,
             SUM(event_type = 'rtv') AS rtvs,
             SUM(event_type = 'vote_option') AS vote_options,
             SUM(event_type = 'vote_winner') AS vote_wins
      FROM #{@vote_statistics_table}
      WHERE created_at >= UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 30 DAY))
        AND map_name <> ''
      GROUP BY map_name
      """)
      |> Map.new(fn row -> {row.map_name, row} end)
    else
      %{}
    end
  end

  def popularity_chart_data, do: popularity_chart_bundle().chart
  def popularity_active_hours, do: popularity_chart_bundle().active_hours

  def map_previews(preview_dir \\ config().preview_dir) do
    if File.dir?(preview_dir) do
      preview_dir
      |> File.ls!()
      |> Enum.filter(fn file -> String.ends_with?(String.downcase(file), ".jpg") end)
      |> Enum.map(fn file ->
        name = Path.rootname(file)
        %{"name" => name, "url" => "/playercount_widget/" <> URI.encode(file)}
      end)
      |> Enum.sort_by(&String.downcase(&1["name"]))
    else
      []
    end
  end

  defp popularity_chart_bundle do
    now = System.system_time(:second)
    active_hours = active_hours_last_days(30)

    sql = """
    SELECT sampled_at, player_count
    FROM mapsdb_popularity_log
    WHERE sampled_at >= UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 90 DAY))
      AND map_name NOT LIKE 'mge\\\\_%' ESCAPE '\\\\'
    ORDER BY sampled_at ASC
    """

    with {:ok, %{rows: rows}} <- Repo.query(sql) do
      rows
      |> build_chart_from_rows(now)
      |> Map.put(:active_hours, active_hours)
    else
      _ -> %{chart: empty_chart(), active_hours: active_hours}
    end
  rescue
    _ -> %{chart: empty_chart(), active_hours: 0}
  end

  defp build_chart_from_rows(rows, now) when is_list(rows) do
    entries =
      rows
      |> Enum.map(fn
        [sampled_at, player_count] ->
          %{sampled_at: int(sampled_at), player_count: int(player_count)}

        %{sampled_at: sampled_at, player_count: player_count} ->
          %{sampled_at: int(sampled_at), player_count: int(player_count)}

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    latest_sample_ts =
      entries
      |> Enum.map(& &1.sampled_at)
      |> Enum.max(fn -> nil end)

    hours_per_range = 24 * 30
    seconds_per_range = hours_per_range * 3600

    anchor_ts =
      if latest_sample_ts do
        div(latest_sample_ts, 3600) * 3600 + 3600
      else
        div(now, 3600) * 3600
      end

    current_start_ts = anchor_ts - seconds_per_range
    previous_start_ts = current_start_ts - seconds_per_range
    earlier_start_ts = previous_start_ts - seconds_per_range

    windows = %{
      "current" => %{start: current_start_ts, end: anchor_ts},
      "previous" => %{start: previous_start_ts, end: current_start_ts},
      "earlier" => %{start: earlier_start_ts, end: previous_start_ts}
    }

    sums =
      Map.new(windows, fn {k, _} -> {k, :array.new(hours_per_range, default: 0.0)} end)

    counts =
      Map.new(windows, fn {k, _} -> {k, :array.new(hours_per_range, default: 0)} end)

    {sums, counts} =
      Enum.reduce(entries, {sums, counts}, fn %{sampled_at: ts, player_count: count},
                                              {s_acc, c_acc} ->
        if ts <= 0 or ts < earlier_start_ts or ts >= anchor_ts do
          {s_acc, c_acc}
        else
          case find_window(ts, windows) do
            nil ->
              {s_acc, c_acc}

            {window_key, window_start} ->
              slot = div(ts - window_start, 3600)

              if slot < 0 or slot >= hours_per_range do
                {s_acc, c_acc}
              else
                sum_arr = Map.fetch!(s_acc, window_key)
                count_arr = Map.fetch!(c_acc, window_key)

                {
                  Map.put(
                    s_acc,
                    window_key,
                    :array.set(slot, :array.get(slot, sum_arr) + count, sum_arr)
                  ),
                  Map.put(
                    c_acc,
                    window_key,
                    :array.set(slot, :array.get(slot, count_arr) + 1, count_arr)
                  )
                }
              end
          end
        end
      end)

    labels = for i <- 0..(hours_per_range - 1), do: current_start_ts + i * 3600
    restart_ts = Enum.filter(labels, fn ts -> TimeDisplay.server_hour(ts) == 6 end)

    series =
      for key <- ["current", "previous", "earlier"], into: %{} do
        sum_arr = Map.fetch!(sums, key)
        count_arr = Map.fetch!(counts, key)

        line =
          for i <- 0..(hours_per_range - 1) do
            cnt = :array.get(i, count_arr)
            if cnt > 0, do: :array.get(i, sum_arr) / cnt, else: 0.0
          end

        {key, line}
      end

    series =
      series
      |> Map.update!("current", &smooth_line(&1, 0.35))
      |> Map.update!("previous", &smooth_line(&1, 0.35))
      |> Map.update!("earlier", &smooth_line(&1, 0.35))
      |> shift_comparison_series(hours_per_range)

    compressed = compress_idle_periods(labels, series, 3, 0.01, MapSet.new(restart_ts))

    %{
      chart: %{
        "labels" => compressed.labels,
        "current" => compressed.series["current"] || [],
        "previous" => compressed.series["previous"] || [],
        "earlier" => compressed.series["earlier"] || [],
        "restart_ts" => restart_ts
      },
      active_hours: 0
    }
  end

  defp build_chart_from_rows(_rows, _now), do: %{chart: empty_chart(), active_hours: 0}

  defp empty_chart,
    do: %{"labels" => [], "current" => [], "previous" => [], "earlier" => [], "restart_ts" => []}

  defp find_window(ts, windows) do
    Enum.find_value(windows, fn {key, %{start: start_ts, end: end_ts}} ->
      if ts >= start_ts and ts < end_ts, do: {key, start_ts}, else: nil
    end)
  end

  defp shift_comparison_series(series, hours_per_range) do
    shift_hours = round(hours_per_range * 0.075)

    if shift_hours > 0 do
      series
      |> Map.update!("previous", &shift_line(&1, shift_hours))
      |> Map.update!("earlier", &shift_line(&1, -shift_hours))
    else
      series
    end
  end

  defp smooth_line(values, blend) when is_list(values) do
    count = length(values)
    blend = max(0.0, min(1.0, blend))

    cond do
      count == 0 ->
        values

      blend <= 0.0 ->
        values

      true ->
        Enum.with_index(values)
        |> Enum.map(fn {current, i} ->
          prev = if i > 0, do: Enum.at(values, i - 1), else: current
          nxt = if i < count - 1, do: Enum.at(values, i + 1), else: current
          neighbor_avg = (prev + nxt) * 0.5
          current * (1.0 - blend) + neighbor_avg * blend
        end)
    end
  end

  defp shift_line(values, 0), do: values

  defp shift_line(values, shift) when is_list(values) do
    count = length(values)

    cond do
      count == 0 ->
        values

      shift > 0 ->
        s = min(shift, count)
        List.duplicate(0.0, s) ++ Enum.take(values, count - s)

      shift < 0 ->
        s = min(abs(shift), count)
        Enum.drop(values, s) ++ List.duplicate(0.0, s)

      true ->
        values
    end
  end

  defp compress_idle_periods(
         labels,
         series,
         chunk_size,
         threshold,
         preserve_timestamps
       ) do
    current = Map.get(series, "current", [])
    count = length(labels)

    if count == 0 or chunk_size <= 1 or current == [] do
      %{labels: labels, series: series}
    else
      keys = Map.keys(series)

      {new_labels, new_series} =
        compress_idle_loop(
          labels,
          series,
          keys,
          current,
          count,
          chunk_size,
          threshold,
          preserve_timestamps,
          0,
          [],
          Map.new(keys, &{&1, []})
        )

      %{
        labels: Enum.reverse(new_labels),
        series: Map.new(new_series, fn {k, v} -> {k, Enum.reverse(v)} end)
      }
    end
  end

  defp compress_idle_loop(
         _labels,
         _series,
         _keys,
         _current,
         count,
         _chunk_size,
         _threshold,
         _preserve_timestamps,
         i,
         acc_labels,
         acc_series
       )
       when i >= count do
    {acc_labels, acc_series}
  end

  defp compress_idle_loop(
         labels,
         series,
         keys,
         current,
         count,
         chunk_size,
         threshold,
         preserve_timestamps,
         i,
         acc_labels,
         acc_series
       ) do
    value = abs(Enum.at(current, i) || 0.0)

    if value <= threshold do
      run_len = idle_run_length(current, count, i, threshold)

      if run_len < chunk_size do
        {labels2, series2} =
          Enum.reduce(0..(run_len - 1), {acc_labels, acc_series}, fn j, {lacc, sacc} ->
            idx = i + j
            add_point(labels, series, keys, idx, lacc, sacc)
          end)

        compress_idle_loop(
          labels,
          series,
          keys,
          current,
          count,
          chunk_size,
          threshold,
          preserve_timestamps,
          i + run_len,
          labels2,
          series2
        )
      else
        chunks = max(1, ceil_div(run_len, chunk_size))

        {labels2, series2} =
          Enum.reduce(0..(chunks - 1), {acc_labels, acc_series}, fn chunk, {lacc, sacc} ->
            chunk_start = i + chunk * chunk_size
            chunk_end = min(chunk_start + chunk_size, i + run_len)

            if chunk_start >= i + run_len do
              {lacc, sacc}
            else
              len = max(1, chunk_end - chunk_start)

              label_idx =
                preserved_label_index(labels, chunk_start, chunk_end, preserve_timestamps)

              lacc2 = [Enum.at(labels, label_idx || chunk_start) | lacc]

              sacc2 =
                Enum.reduce(keys, sacc, fn key, map_acc ->
                  avg =
                    Enum.reduce(chunk_start..(chunk_end - 1), 0.0, fn idx, sum ->
                      sum + (Enum.at(Map.get(series, key, []), idx) || 0.0)
                    end) / len

                  Map.update!(map_acc, key, &[avg | &1])
                end)

              {lacc2, sacc2}
            end
          end)

        compress_idle_loop(
          labels,
          series,
          keys,
          current,
          count,
          chunk_size,
          threshold,
          preserve_timestamps,
          i + run_len,
          labels2,
          series2
        )
      end
    else
      {labels2, series2} = add_point(labels, series, keys, i, acc_labels, acc_series)

      compress_idle_loop(
        labels,
        series,
        keys,
        current,
        count,
        chunk_size,
        threshold,
        preserve_timestamps,
        i + 1,
        labels2,
        series2
      )
    end
  end

  defp preserved_label_index(labels, chunk_start, chunk_end, preserve_timestamps) do
    Enum.find(chunk_start..(chunk_end - 1), fn idx ->
      MapSet.member?(preserve_timestamps, Enum.at(labels, idx))
    end)
  end

  defp add_point(labels, series, keys, idx, acc_labels, acc_series) do
    lacc = [Enum.at(labels, idx) | acc_labels]

    sacc =
      Enum.reduce(keys, acc_series, fn key, map_acc ->
        val = Enum.at(Map.get(series, key, []), idx) || 0.0
        Map.update!(map_acc, key, &[val | &1])
      end)

    {lacc, sacc}
  end

  defp idle_run_length(current, count, start_idx, threshold) do
    Enum.reduce_while(start_idx..(count - 1), 0, fn idx, acc ->
      if abs(Enum.at(current, idx) || 0.0) <= threshold, do: {:cont, acc + 1}, else: {:halt, acc}
    end)
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp valid_map_session_sql(alias_name) do
    """
    #{alias_name}.peak_players >= 8
    AND #{alias_name}.duration >= 600
    AND #{alias_name}.end_reason IN ('map_end', 'historical', 'synthetic_backfill')
    """
  end

  defp valid_population_sample_sql(sample_alias, session_alias) do
    """
    #{sample_alias}.player_count > 0
    AND #{sample_alias}.player_count <= 32
    AND #{sample_alias}.sampled_at BETWEEN #{session_alias}.started_at AND #{session_alias}.ended_at + 120
    AND #{sample_alias}.map_elapsed_seconds BETWEEN 0 AND #{session_alias}.duration + 120
    """
  end

  defp query_rows(sql) do
    case Repo.query(sql) do
      {:ok, %{columns: columns, rows: rows}} ->
        QueryResult.rows_to_maps(rows, columns, :atoms)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp cached_page_payload do
    if Cache.enabled?() do
      case Cache.get() do
        {:ok, entry} -> entry
        {:error, _reason} -> uncached_page_payload()
      end
    else
      uncached_page_payload()
    end
  end

  defp uncached_page_payload do
    %{
      payload: build_cache_payload(),
      hash: nil,
      generated_at: System.system_time(:second)
    }
  end

  defp table_exists?(table) do
    case Repo.query(
           "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '#{table}'"
         ) do
      {:ok, %{rows: [[count]]}} -> int(count) > 0
      _ -> false
    end
  rescue
    _ -> false
  end

  defp sql_string(value), do: "'" <> String.replace(to_string(value), "'", "''") <> "'"

  defp sql_string_list(values) do
    values
    |> Enum.map(&sql_string/1)
    |> Enum.join(",")
  end

  defp format_slot(nil), do: "n/a"

  defp format_slot(%{} = row) do
    weekday = row |> Map.get(:weekday) |> int()
    hour = row |> Map.get(:hour_of_day) |> int()
    "#{weekday_label(weekday)} #{pad2(hour)}:00 ET"
  end

  defp weekday_label(day) do
    Enum.at(~w(Sun Mon Tue Wed Thu Fri Sat), rem(max(day, 0), 7), "n/a")
  end

  defp pad2(value) do
    value
    |> int()
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end

  defp format_date(0), do: "n/a"

  defp format_date(unix_seconds) do
    TimeDisplay.format_server_datetime(unix_seconds)
  end
end
