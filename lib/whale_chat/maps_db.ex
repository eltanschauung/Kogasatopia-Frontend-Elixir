defmodule WhaleChat.MapsDb do
  @moduledoc false

  import Ecto.Query

  alias WhaleChat.MapsDb.MapMeta
  alias WhaleChat.Chat.SteamProfiles
  alias WhaleChat.Repo

  @gamemode_names ~w(arena koth payload payloadrace ctf 5cp adcp tc medieval pd tr dm ultiduo rd pass mvm kotf dom default)
  @page_gamemode_names ~w(arena koth payload payloadrace ctf 5cp adcp tc medieval pd tr dm ultiduo rd pass mvm kotf dom symmetrical asymmetrical default)
  @api_category_order ~w(koth cp pl plr ctf pd sd arena zi vsh mge tc tr dm ultiduo rd pass mvm kotf dom)
  @page_category_order ~w(gamemode koth cp pl plr ctf pd sd arena zi vsh mge tc tr dm ultiduo rd pass mvm kotf dom)
  @category_label_map %{
    "koth" => "KOTH maps",
    "cp" => "Control Point maps",
    "pl" => "Payload maps",
    "plr" => "Payload Race maps",
    "ctf" => "Capture the Flag maps",
    "pd" => "Player Destruction maps",
    "sd" => "SD maps",
    "arena" => "Arena maps",
    "zi" => "Zombie Infection maps",
    "vsh" => "Vs. Saxton Hale maps",
    "mge" => "MGE maps",
    "tc" => "Terrain Control maps",
    "tr" => "Training maps",
    "dm" => "Deathmatch maps",
    "ultiduo" => "Ultiduo maps",
    "rd" => "Robot Destruction maps",
    "pass" => "Pass Time maps",
    "mvm" => "Mann vs. Machine maps",
    "kotf" => "King of the Flag maps",
    "dom" => "Domination maps",
    "gamemode" => "Gamemode configs"
  }
  @sub_category_order ["harvest"]
  @sub_category_label_map %{"harvest" => "Harvest-type maps"}

  def config do
    %{
      maps_dir: Application.get_env(:whale_chat, :mapsdb_dir, "/home/kogasa/hlserver/tf2/tf/cfg/mapsdb"),
      tf_cfg_dir: Application.get_env(:whale_chat, :mapsdb_tf_cfg_dir, "/home/kogasa/hlserver/tf2/tf/cfg"),
      preview_dir: Application.get_env(:whale_chat, :mapsdb_preview_dir, "/var/www/kogasatopia/playercount_widget"),
      admin_cache_file: Application.get_env(:whale_chat, :mapsdb_admin_cache_file, "/var/www/kogasatopia/stats/cache/admins_cache.json")
    }
  end

  def page_data(steamid \\ nil) do
    cfg = config()
    maps_dir_missing = not File.dir?(cfg.maps_dir)
    is_logged_in = is_binary(steamid) and steamid != ""
    is_admin = is_logged_in and admin?(steamid)
    can_edit_maps = is_logged_in and is_admin
    chart_bundle = popularity_chart_bundle()
    viewer_profile =
      case steamid do
        sid when is_binary(sid) and sid != "" ->
          SteamProfiles.fetch_many([sid])
          |> Map.get(sid)
          |> case do
            %{} = profile -> %{personaname: profile["personaname"], avatar: profile["avatarfull"]}
            _ -> nil
          end
        _ ->
          nil
      end

    %{
      maps_dir: cfg.maps_dir,
      maps_dir_missing: maps_dir_missing,
      is_logged_in: is_logged_in,
      current_steamid: steamid,
      viewer_profile: viewer_profile,
      is_admin: is_admin,
      can_edit_maps: can_edit_maps,
      popular_maps: fetch_map_popularity(25),
      popularity_chart: chart_bundle.chart,
      popularity_active_hours: chart_bundle.active_hours,
      map_previews: map_previews(cfg.preview_dir),
      map_sections: if(maps_dir_missing, do: [], else: build_page_sections(cfg)),
      login_url: "/mapsdb/login.php?return=" <> URI.encode("/mapsdb"),
      logout_url: "/mapsdb/login.php?action=logout&return=" <> URI.encode("/mapsdb")
    }
  end

  def admin?(nil), do: false
  def admin?(""), do: false

  def admin?(steamid) when is_binary(steamid) do
    case File.read(config().admin_cache_file) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"admins" => admins}} when is_map(admins) -> truthy?(Map.get(admins, steamid))
          _ -> false
        end

      _ -> false
    end
  end

  def list_api_maps do
    cfg = config()
    files = Path.wildcard(Path.join(cfg.maps_dir, "*.cfg"))

    rows =
      files
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn file ->
        stat = File.stat!(file)
        name = Path.rootname(Path.basename(file))

        %{
          "name" => name,
          "modified" => mtime_unix(stat),
          "size" => stat.size
        }
      end)
      |> Enum.sort_by(&String.downcase(&1["name"]))

    names = Enum.map(rows, & &1["name"])
    categories = fetch_categories(names)
    gamemode_order = Enum.with_index(Enum.map(@gamemode_names, &String.downcase/1)) |> Map.new()
    gamemode_set = Map.keys(gamemode_order) |> MapSet.new()

    enriched =
      Enum.map(rows, fn row ->
        name = row["name"]
        lower = String.downcase(name)
        type = if MapSet.member?(gamemode_set, lower), do: "gamemode", else: "map"

        row
        |> Map.put("category", Map.get(categories, name, ""))
        |> Map.put("type", type)
        |> Map.put("order", if(type == "gamemode", do: Map.get(gamemode_order, lower), else: nil))
      end)

    {gamemodes, maps} = Enum.split_with(enriched, &(&1["type"] == "gamemode"))

    gamemodes_sorted =
      Enum.sort_by(gamemodes, fn row ->
        {row["order"] || 99_999, String.downcase(row["name"])}
      end)

    grouped = Enum.group_by(maps, fn row ->
      cat = row["category"]
      if cat == "", do: "_other", else: String.downcase(cat)
    end)

    ordered_maps =
      @api_category_order
      |> Enum.reduce({[], grouped}, fn cat_key, {acc, buckets} ->
        case Map.pop(buckets, cat_key) do
          {nil, rest} -> {acc, rest}
          {bucket, rest} -> {acc ++ Enum.sort_by(bucket, &String.downcase(&1["name"])), rest}
        end
      end)
      |> then(fn {acc, buckets} ->
        tail =
          buckets
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.flat_map(fn {_k, bucket} -> Enum.sort_by(bucket, &String.downcase(&1["name"])) end)

        acc ++ tail
      end)

    ordered = gamemodes_sorted ++ ordered_maps

    Enum.map(ordered, &Map.delete(&1, "order"))
  end

  def load_config_file(map, source) do
    with {:ok, src} <- sanitize_source(source),
         {:ok, path, map_name} <- sanitize_map(map, src),
         {:ok, content} <- File.read(path),
         {:ok, stat} <- File.stat(path) do
      {:ok, %{map: map_name, content: content, modified: mtime_unix(stat)}}
    else
      {:error, _} = err -> err
      {:file_error, reason} -> {:error, {:io, reason}}
    end
  end

  def save_config_file(map, source, content) when is_binary(content) do
    with {:ok, src} <- sanitize_source(source),
         {:ok, path, map_name} <- sanitize_map(map, src),
         :ok <- write_file(path, content),
         {:ok, stat} <- File.stat(path) do
      {:ok,
       %{map: map_name, modified: mtime_unix(stat), bytes: stat.size || byte_size(content)}}
    else
      {:error, _} = err -> err
      {:file_error, reason} -> {:error, {:io, reason}}
    end
  end

  def mass_edit(search, replace) when is_binary(search) and is_binary(replace) do
    if String.trim(search) == "" do
      {:error, :search_required}
    else
      cfg = config()

      {modified, total} =
        Path.wildcard(Path.join(cfg.maps_dir, "*.cfg"))
        |> Enum.reduce({[], 0}, fn file, {mods, total_replacements} ->
          if File.regular?(file) do
            case File.read(file) do
              {:ok, contents} ->
                {updated, count} = replace_count(contents, search, replace)

                if count > 0 do
                  case write_file(file, updated) do
                    :ok ->
                      file_name = Path.basename(file)
                      {[ %{file: file_name, replacements: count} | mods], total_replacements + count}

                    _ ->
                      {mods, total_replacements}
                  end
                else
                  {mods, total_replacements}
                end

              _ ->
                {mods, total_replacements}
            end
          else
            {mods, total_replacements}
          end
        end)

      {:ok, %{modified: Enum.reverse(modified), filesEdited: length(modified), totalReplacements: total}}
    end
  end

  def build_page_sections(cfg \\ config()) do
    maps_dir = cfg.maps_dir
    tf_cfg_dir = cfg.tf_cfg_dir

    map_names =
      Path.wildcard(Path.join(maps_dir, "*.cfg"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.rootname(Path.basename(&1)))
      |> Enum.sort_by(&String.downcase/1)

    map_meta = fetch_meta(map_names)

    sections = []
    |> maybe_add_server_configs(tf_cfg_dir)
    |> maybe_add_mapcycles(tf_cfg_dir)
    |> add_playercount_settings()
    |> maybe_add_category_configs(map_meta)

    map_sections = build_map_sections(map_names, map_meta)
    sections ++ map_sections
  end

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

    sql = """
    SELECT sampled_at, player_count
    FROM mapsdb_popularity_log
    WHERE sampled_at >= UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 90 DAY))
      AND map_name NOT LIKE 'mge\\\\_%' ESCAPE '\\\\'
    ORDER BY sampled_at ASC
    """

    with {:ok, %{rows: rows}} <- Repo.query(sql) do
      build_chart_from_rows(rows, now)
    else
      _ -> %{chart: empty_chart(), active_hours: 0}
    end
  rescue
    _ -> %{chart: empty_chart(), active_hours: 0}
  end

  defp build_chart_from_rows(rows, now) when is_list(rows) do
    entries =
      rows
      |> Enum.map(fn
        [sampled_at, player_count] ->
          %{sampled_at: to_int(sampled_at), player_count: to_int(player_count)}

        %{sampled_at: sampled_at, player_count: player_count} ->
          %{sampled_at: to_int(sampled_at), player_count: to_int(player_count)}

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
      Enum.reduce(entries, {sums, counts}, fn %{sampled_at: ts, player_count: count}, {s_acc, c_acc} ->
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
                  Map.put(s_acc, window_key, :array.set(slot, :array.get(slot, sum_arr) + count, sum_arr)),
                  Map.put(c_acc, window_key, :array.set(slot, :array.get(slot, count_arr) + 1, count_arr))
                }
              end
          end
        end
      end)

    labels = for i <- 0..(hours_per_range - 1), do: current_start_ts + i * 3600
    restart_ts = Enum.filter(labels, fn ts -> hour_of_day_utc(ts) == 6 end)

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

    current_limited = limit_active_hours(series["current"], 150, 4.0)
    active_hours = Enum.count(current_limited, &(&1 > 4.0))

    series =
      series
      |> Map.put("current", current_limited)
      |> Map.update!("current", &smooth_line(&1, 0.35))
      |> Map.update!("previous", &smooth_line(&1, 0.35))
      |> Map.update!("earlier", &smooth_line(&1, 0.35))
      |> shift_comparison_series(hours_per_range)

    compressed = compress_idle_periods(labels, series, 3, 0.01)

    %{
      chart: %{
        "labels" => compressed.labels,
        "current" => compressed.series["current"] || [],
        "previous" => compressed.series["previous"] || [],
        "earlier" => compressed.series["earlier"] || [],
        "restart_ts" => restart_ts
      },
      active_hours: active_hours
    }
  end

  defp build_chart_from_rows(_rows, _now), do: %{chart: empty_chart(), active_hours: 0}

  defp empty_chart, do: %{"labels" => [], "current" => [], "previous" => [], "earlier" => [], "restart_ts" => []}

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
      count == 0 -> values
      blend <= 0.0 -> values
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
      count == 0 -> values
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

  defp limit_active_hours(values, target_hours, threshold) when is_list(values) do
    above =
      values
      |> Enum.with_index()
      |> Enum.filter(fn {v, _i} -> v > threshold end)

    if length(above) <= target_hours do
      values
    else
      keep =
        above
        |> Enum.sort(fn {va, ia}, {vb, ib} ->
          if va == vb, do: ia <= ib, else: va >= vb
        end)
        |> Enum.take(target_hours)
        |> Enum.map(fn {_v, i} -> i end)
        |> MapSet.new()

      Enum.with_index(values)
      |> Enum.map(fn {v, i} -> if MapSet.member?(keep, i), do: v, else: min(v, threshold) end)
    end
  end

  defp compress_idle_periods(labels, series, chunk_size, threshold) do
    current = Map.get(series, "current", [])
    count = length(labels)

    if count == 0 or chunk_size <= 1 or current == [] do
      %{labels: labels, series: series}
    else
      keys = Map.keys(series)

      {new_labels, new_series} =
        compress_idle_loop(labels, series, keys, current, count, chunk_size, threshold, 0, [], Map.new(keys, &{&1, []}))

      %{labels: Enum.reverse(new_labels), series: Map.new(new_series, fn {k, v} -> {k, Enum.reverse(v)} end)}
    end
  end

  defp compress_idle_loop(_labels, _series, _keys, _current, count, _chunk_size, _threshold, i, acc_labels, acc_series) when i >= count do
    {acc_labels, acc_series}
  end

  defp compress_idle_loop(labels, series, keys, current, count, chunk_size, threshold, i, acc_labels, acc_series) do
    value = abs(Enum.at(current, i) || 0.0)

    if value <= threshold do
      run_len = idle_run_length(current, count, i, threshold)

      if run_len < chunk_size do
        {labels2, series2} =
          Enum.reduce(0..(run_len - 1), {acc_labels, acc_series}, fn j, {lacc, sacc} ->
            idx = i + j
            add_point(labels, series, keys, idx, lacc, sacc)
          end)

        compress_idle_loop(labels, series, keys, current, count, chunk_size, threshold, i + run_len, labels2, series2)
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
              lacc2 = [Enum.at(labels, chunk_start) | lacc]

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

        compress_idle_loop(labels, series, keys, current, count, chunk_size, threshold, i + run_len, labels2, series2)
      end
    else
      {labels2, series2} = add_point(labels, series, keys, i, acc_labels, acc_series)
      compress_idle_loop(labels, series, keys, current, count, chunk_size, threshold, i + 1, labels2, series2)
    end
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

  defp hour_of_day_utc(ts) do
    ts
    |> DateTime.from_unix!()
    |> Map.get(:hour)
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp fetch_categories([]), do: %{}

  defp fetch_categories(names) do
    Repo.all(from m in MapMeta, where: m.map_name in ^names, select: {m.map_name, m.category})
    |> Map.new()
  end

  defp fetch_meta([]), do: %{}

  defp fetch_meta(names) do
    Repo.all(
      from m in MapMeta,
        where: m.map_name in ^names,
        select: {m.map_name, %{category: m.category, sub_category: m.sub_category}}
    )
    |> Enum.map(fn {name, meta} ->
      {name, %{category: meta.category || "", sub_category: meta.sub_category || ""}}
    end)
    |> Map.new()
  end

  defp build_map_sections(map_names, map_meta) do
    gamemode_set = @page_gamemode_names |> Enum.map(&String.downcase/1) |> MapSet.new()

    {sub_buckets, cat_buckets} =
      Enum.reduce(map_names, {%{}, %{}}, fn map_name, {sub_acc, cat_acc} ->
        lower = String.downcase(map_name)
        meta = Map.get(map_meta, map_name, %{category: "", sub_category: ""})
        category = meta.category || ""
        sub_category = meta.sub_category || ""

        entry = %{
          name: map_name,
          display: map_name,
          type: if(MapSet.member?(gamemode_set, lower), do: "gamemode", else: "map"),
          category: category,
          sub_category: sub_category,
          source: "mapsdb"
        }

        sub_key = String.downcase(sub_category)

        cond do
          sub_key != "" and Map.has_key?(@sub_category_label_map, sub_key) ->
            {Map.update(sub_acc, sub_key, [entry], &[entry | &1]), cat_acc}

          true ->
            bucket_key =
              cond do
                entry.type == "gamemode" and category == "" -> "gamemode"
                category == "" -> "_other"
                true -> String.downcase(category)
              end

            {sub_acc, Map.update(cat_acc, bucket_key, [entry], &[entry | &1])}
        end
      end)

    sub_sections =
      Enum.reduce(@sub_category_order, {[], sub_buckets}, fn sub_key, {acc, buckets} ->
        case Map.pop(buckets, sub_key) do
          {nil, rest} -> {acc, rest}
          {entries, rest} ->
            sorted = Enum.sort_by(entries, &String.downcase(&1.name))
            section = %{label: @sub_category_label_map[sub_key], slug: "subcat-" <> sub_key, entries: sorted, open: false}
            {acc ++ [section], rest}
        end
      end)
      |> then(fn {acc, _rest} -> acc end)

    ordered_cat_sections =
      Enum.reduce(@page_category_order, {[], cat_buckets}, fn cat_key, {acc, buckets} ->
        case Map.pop(buckets, cat_key) do
          {nil, rest} -> {acc, rest}
          {entries, rest} ->
            sorted = Enum.sort_by(entries, &String.downcase(&1.name))
            section = %{label: format_category_label(cat_key), slug: cat_key, entries: sorted, open: false}
            {acc ++ [section], rest}
        end
      end)
      |> then(fn {acc, rest} ->
        extra =
          rest
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {bucket_key, entries} ->
            %{label: format_category_label(bucket_key), slug: bucket_key, entries: Enum.sort_by(entries, &String.downcase(&1.name)), open: false}
          end)

        acc ++ extra
      end)

    sub_sections ++ ordered_cat_sections
  end

  defp maybe_add_server_configs(sections, tf_cfg_dir) do
    entries =
      list_tfcfg_files(tf_cfg_dir, fn _base, lower -> String.contains?(lower, "server") && not String.contains?(lower, "mapcycle") end, "server", "server", "tfcfg")

    if entries == [] do
      sections
    else
      sections ++ [%{label: "Server configs", slug: "server-configs", entries: entries, open: false}]
    end
  end

  defp maybe_add_mapcycles(sections, tf_cfg_dir) do
    entries = list_tfcfg_files(tf_cfg_dir, fn _base, lower -> String.contains?(lower, "mapcycle") end, "mapcycle", "mapcycle", "tfcfg")

    if entries == [] do
      sections
    else
      sections ++ [%{label: "Mapcycles", slug: "mapcycles", entries: entries, open: false}]
    end
  end

  defp add_playercount_settings(sections) do
    sections ++
      [
        %{
          label: "Playercount settings",
          slug: "playercount-settings",
          open: false,
          entries: [
            %{name: "d_highpop", display: "High Population", type: "playercount", category: "playercount", source: "mapsdb"},
            %{name: "d_lowpop", display: "Low Population", type: "playercount", category: "playercount", source: "mapsdb"}
          ]
        }
      ]
  end

  defp maybe_add_category_configs(sections, map_meta) do
    category_targets = [
      {"harvest", :sub_category, "category_harvest", "Harvest-type maps", "subcategory"},
      {"5cp", :category, "category_5cp", "5CP maps", "category"},
      {"3cp", :category, "category_3cp", "3CP maps", "category"},
      {"attack/defend", :category, "category_attack_defend", "Attack/Defend maps", "category"}
    ]

    entries =
      Enum.flat_map(category_targets, fn {slug, column, name, display, type} ->
        exists? =
          Enum.any?(map_meta, fn {_map_name, meta} ->
            val = meta |> Map.get(column, "") |> to_string() |> String.trim() |> String.downcase()
            val == slug
          end)

        if exists? do
          [%{name: name, display: display, type: type, category: type, source: "mapsdb"}]
        else
          []
        end
      end)

    if entries == [] do
      sections
    else
      sections ++ [%{label: "Category configs", slug: "category-configs", entries: entries, open: false}]
    end
  end

  defp list_tfcfg_files(tf_cfg_dir, predicate, type, category, source) do
    if File.dir?(tf_cfg_dir) do
      tf_cfg_dir
      |> File.ls!()
      |> Enum.filter(fn file ->
        lower = String.downcase(file)
        String.ends_with?(lower, ".cfg") and predicate.(Path.rootname(file), lower)
      end)
      |> Enum.map(fn file ->
        %{name: Path.rootname(file), display: Path.rootname(file), type: type, category: category, source: source}
      end)
      |> Enum.sort_by(&String.downcase(&1.name))
    else
      []
    end
  end

  defp format_category_label(slug) do
    key = String.downcase(to_string(slug || ""))

    cond do
      Map.has_key?(@category_label_map, key) -> @category_label_map[key]
      key in ["", "_other"] -> "Other maps"
      true -> String.upcase(key) <> " maps"
    end
  end

  defp sanitize_source(nil), do: {:ok, "mapsdb"}
  defp sanitize_source("tfcfg"), do: {:ok, "tfcfg"}
  defp sanitize_source(_), do: {:ok, "mapsdb"}

  defp sanitize_map(nil, _source), do: {:error, :missing_map}
  defp sanitize_map("", _source), do: {:error, :missing_map}

  defp sanitize_map(map, source) when is_binary(map) do
    if Regex.match?(~r/^[A-Za-z0-9_]+$/, map) do
      cfg = config()
      base = if source == "tfcfg", do: cfg.tf_cfg_dir, else: cfg.maps_dir
      path = Path.join(base, map <> ".cfg")
      if File.regular?(path), do: {:ok, path, map}, else: {:error, :not_found}
    else
      {:error, :invalid_map}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok ->
        _ = File.chmod(path, 0o777)
        :ok

      {:error, reason} ->
        {:file_error, reason}
    end
  end

  defp replace_count(contents, search, replace) do
    parts = String.split(contents, search)

    case parts do
      [_single] -> {contents, 0}
      _ -> {Enum.join(parts, replace), length(parts) - 1}
    end
  end

  defp mtime_unix(%File.Stat{mtime: {{y, mo, d}, {h, mi, s}}}) do
    {:ok, ndt} = NaiveDateTime.new(y, mo, d, h, mi, s)
    DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
  end

  defp mtime_unix(%File.Stat{}), do: System.system_time(:second)

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_float(v), do: trunc(v)

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defp truthy?(v) when v in [true, 1, "1", "true", "yes", "on"], do: true
  defp truthy?(_), do: false
end
