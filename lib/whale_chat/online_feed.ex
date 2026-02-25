defmodule WhaleChat.OnlineFeed do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias WhaleChat.Chat.SteamProfiles
  alias WhaleChat.Repo

  @weapon_category_metadata %{
    "shotguns" => %{label: "Shotgun"},
    "scatterguns" => %{label: "Scattergun"},
    "pistols" => %{label: "Pistol"},
    "rocketlaunchers" => %{label: "Rocket Launcher"},
    "grenadelaunchers" => %{label: "Grenade Launcher"},
    "stickylaunchers" => %{label: "Sticky Launcher"},
    "snipers" => %{label: "Sniper Rifle"},
    "revolvers" => %{label: "Revolver"}
  }
  @max_weapon_slots 3

  def payload do
    now = System.system_time(:second)

    with {:ok, players} <- fetch_online_players(),
         {:ok, servers} <- fetch_servers(now) do
      enriched_players = enrich_players(players)
      build_response(enriched_players, servers, now)
    else
      _ -> %{"success" => false, "error" => "internal_error"}
    end
  rescue
    _ -> %{"success" => false, "error" => "internal_error"}
  end

  def page_config do
    %{
      default_avatar_url: Application.get_env(:whale_chat, :default_avatar_url, "/stats/assets/whaley-avatar.jpg"),
      class_icon_base: System.get_env("WT_CLASS_ICON_BASE") || "/leaderboard/"
    }
  end

  defp fetch_online_players do
    weapon_select_clause = weapon_select_clause()
    category_select_clause = weapon_category_select_clause()

    sql_extended =
      "SELECT steamid, personaname, class, team, alive, is_spectator, kills, deaths, assists, damage, damage_taken, healing, headshots, backstabs, shots, hits" <>
        category_select_clause <>
        weapon_select_clause <>
        ", playtime, total_ubers, classes_mask, time_connected, visible_max, last_update FROM whaletracker_online ORDER BY last_update DESC"

    sql_legacy =
      "SELECT steamid, personaname, class, team, alive, is_spectator, kills, deaths, assists, damage, damage_taken, healing, headshots, backstabs, shots, hits" <>
        category_select_clause <>
        weapon_select_clause <>
        ", playtime, total_ubers, time_connected, visible_max, last_update FROM whaletracker_online ORDER BY last_update DESC"

    case SQL.query(Repo, sql_extended, []) do
      {:ok, %{rows: rows, columns: columns}} -> {:ok, map_rows(rows, columns)}
      {:error, _} ->
        case SQL.query(Repo, sql_legacy, []) do
          {:ok, %{rows: rows, columns: columns}} -> {:ok, map_rows(rows, columns)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp fetch_servers(now) do
    cutoff = now - 180

    sql_with_game =
      "SELECT ip, port, playercount, visible_max, game, game_url, map, city, country, flags, last_update " <>
        "FROM whaletracker_servers WHERE last_update >= ? ORDER BY port ASC"

    sql_legacy =
      "SELECT ip, port, playercount, visible_max, map, city, country, flags, last_update " <>
        "FROM whaletracker_servers WHERE last_update >= ? ORDER BY port ASC"

    case SQL.query(Repo, sql_with_game, [cutoff]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, build_server_rows(rows, columns)}

      {:error, _} ->
        case SQL.query(Repo, sql_legacy, [cutoff]) do
          {:ok, %{rows: rows, columns: columns}} -> {:ok, build_server_rows(rows, columns)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp build_server_rows(rows, columns) do
    rows
    |> map_rows(columns)
    |> Enum.map(fn server ->
      host_ip = str(server["ip"])
      host_port = int(server["port"])
      map_name = str(server["map"])

      game_name =
        case str(server["game"]) do
          "" -> "TF2"
          game -> game
        end

      game_url =
        case str(server["game_url"]) do
          "" -> "440"
          app_id -> app_id
        end

      %{
        "host_ip" => host_ip,
        "host_port" => host_port,
        "map_name" => map_name,
        "game" => game_name,
        "game_url" => game_url,
        "player_count" => int(server["playercount"]),
        "visible_max" => int(server["visible_max"]),
        "map_image" => resolve_map_image(map_name),
        "city" => str(server["city"]),
        "country_code" => server |> Map.get("country") |> str() |> String.downcase(),
        "extra_flags" => parse_flags(server["flags"]),
        "last_update" => int(server["last_update"])
      }
    end)
  end

  defp enrich_players(players) do
    steam_ids =
      players
      |> Enum.map(&str(&1["steamid"]))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    profiles = SteamProfiles.fetch_many(steam_ids)
    admin_flags = admin_flags_for_ids(steam_ids)
    default_avatar = Application.get_env(:whale_chat, :default_avatar_url, "/stats/assets/whaley-avatar.jpg")

    Enum.map(players, fn row ->
      row = normalize_online_player(row)
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

      row =
        row
        |> Map.put("personaname", if(personaname == "", do: steamid, else: personaname))
        |> Map.put("avatar", avatar)
        |> Map.put("profileurl", if(steamid != "", do: "https://steamcommunity.com/profiles/" <> steamid, else: nil))
        |> Map.put("is_admin", if(Map.get(admin_flags, steamid, false), do: 1, else: int(row["is_admin"])))

      {weapon_summary, active_acc} = weapon_summary_for_row(row)

      row
      |> Map.put("weapon_accuracy_summary", weapon_accuracy_summary_for_row(row))
      |> Map.put("weapon_category_summary", weapon_summary)
      |> Map.put("active_weapon_accuracy", active_acc)
      |> drop_weapon_slot_fields()
    end)
  end

  defp build_response(players, servers, now) do
    visible_max_from_players = players |> List.first() |> then(fn p -> if p, do: int(p["visible_max"]), else: 0 end)
    visible_max = if visible_max_from_players > 0, do: visible_max_from_players, else: 32
    player_count_guess = length(players)
    map_name_guess = players |> List.first() |> then(fn p -> if p, do: str(p["map_name"]), else: "" end)

    {servers, player_count, visible_max, map_name, map_image} =
      if servers != [] do
        aggregate_players = Enum.reduce(servers, 0, fn s, acc -> acc + int(s["player_count"]) end)
        aggregate_visible = Enum.reduce(servers, 0, fn s, acc -> acc + int(s["visible_max"]) end)
        first_server = hd(servers)
        {
          servers,
          if(aggregate_players > 0, do: aggregate_players, else: player_count_guess),
          if(aggregate_visible > 0, do: aggregate_visible, else: visible_max),
          if(map_name_guess != "", do: map_name_guess, else: str(first_server["map_name"])),
          str(first_server["map_image"])
        }
      else
        fallback_server = %{
          "host_ip" => "",
          "host_port" => 0,
          "map_name" => map_name_guess,
          "player_count" => player_count_guess,
          "visible_max" => visible_max,
          "map_image" => resolve_map_image(map_name_guess),
          "last_update" => now,
          "city" => "",
          "country_code" => "",
          "extra_flags" => []
        }

        {[fallback_server], player_count_guess, visible_max, map_name_guess, str(fallback_server["map_image"])}
      end

    %{
      "success" => true,
      "updated" => now,
      "visible_max_players" => visible_max,
      "player_count" => player_count,
      "map_name" => map_name,
      "map_image" => map_image,
      "servers" => servers,
      "players" => players
    }
  end

  defp normalize_online_player(row) do
    row
    |> Map.update("shots", 0, &int/1)
    |> Map.update("hits", 0, &int/1)
    |> Map.update("classes_mask", 0, &int/1)
    |> Enum.into(%{}, fn {k, v} -> {k, normalize_scalar(v)} end)
  end

  defp normalize_scalar(v) when is_integer(v) or is_float(v) or is_boolean(v) or is_nil(v), do: v
  defp normalize_scalar(v), do: v

  defp weapon_select_clause do
    for slot <- 1..@max_weapon_slots do
      ", weapon#{slot}_name, weapon#{slot}_accuracy, weapon#{slot}_shots, weapon#{slot}_hits"
    end
    |> Enum.join("")
  end

  defp weapon_category_select_clause do
    @weapon_category_metadata
    |> Map.keys()
    |> Enum.flat_map(fn slug -> [", shots_#{slug}", ", hits_#{slug}"] end)
    |> Enum.join("")
  end

  defp weapon_accuracy_summary_for_row(row) do
    Enum.reduce(1..@max_weapon_slots, [], fn slot, acc ->
      name = row["weapon#{slot}_name"] |> str() |> String.trim()
      accuracy = row["weapon#{slot}_accuracy"]
      shots = int(row["weapon#{slot}_shots"])
      hits = int(row["weapon#{slot}_hits"])

      if name == "" or is_nil(accuracy) or shots <= 0 do
        acc
      else
        acc ++ [%{"name" => name, "accuracy" => float(accuracy), "shots" => shots, "hits" => hits}]
      end
    end)
  end

  defp weapon_summary_for_row(row) do
    summary =
      @weapon_category_metadata
      |> Enum.reduce([], fn {slug, meta}, acc ->
        shots = int(row["shots_#{slug}"])
        hits = int(row["hits_#{slug}"])

        if shots <= 0 do
          acc
        else
          acc ++ [%{
            "slug" => slug,
            "label" => meta.label,
            "shots" => shots,
            "hits" => hits,
            "accuracy" => (hits / max(shots, 1)) * 100.0
          }]
        end
      end)
      |> Enum.sort_by(fn item -> {-int(item["shots"]), -(float(item["accuracy"]))} end)
      |> fallback_overall_weapon_summary(row)

    {summary, List.first(summary)}
  end

  defp fallback_overall_weapon_summary([], row) do
    {total_shots, total_hits} = total_weapon_accuracy_counts(row)

    if total_shots > 0 do
      [
        %{
          "slug" => "overall",
          "label" => "Overall",
          "shots" => total_shots,
          "hits" => total_hits,
          "accuracy" => (total_hits / max(total_shots, 1)) * 100.0
        }
      ]
    else
      []
    end
  end

  defp fallback_overall_weapon_summary(summary, _row), do: summary

  defp total_weapon_accuracy_counts(row) do
    pairs = [
      {"shots_shotguns", "hits_shotguns"},
      {"shots_scatterguns", "hits_scatterguns"},
      {"shots_pistols", "hits_pistols"},
      {"shots_rocketlaunchers", "hits_rocketlaunchers"},
      {"shots_grenadelaunchers", "hits_grenadelaunchers"},
      {"shots_stickylaunchers", "hits_stickylaunchers"},
      {"shots_snipers", "hits_snipers"},
      {"shots_revolvers", "hits_revolvers"}
    ]

    {total_shots, total_hits} =
      Enum.reduce(pairs, {0, 0}, fn {shots_key, hits_key}, {s_acc, h_acc} ->
        {s_acc + int(row[shots_key]), h_acc + int(row[hits_key])}
      end)

    if total_shots == 0 and Map.has_key?(row, "shots") and Map.has_key?(row, "hits") do
      {int(row["shots"]), int(row["hits"])}
    else
      {total_shots, total_hits}
    end
  end

  defp drop_weapon_slot_fields(row) do
    row =
      Enum.reduce(1..@max_weapon_slots, row, fn slot, acc ->
        acc
        |> Map.delete("weapon#{slot}_name")
        |> Map.delete("weapon#{slot}_accuracy")
        |> Map.delete("weapon#{slot}_shots")
        |> Map.delete("weapon#{slot}_hits")
      end)

    row
  end

  defp resolve_map_image(map_name) do
    safe =
      map_name
      |> str()
      |> String.trim()
      |> case do
        "" -> ""
        v -> Regex.replace(~r/[^a-zA-Z0-9_\-]/, v, "")
      end

    cond do
      safe == "" -> nil
      File.exists?("/var/www/kogasatopia/playercount_widget/#{safe}.jpg") -> "/playercount_widget/#{URI.encode(safe)}.jpg"
      true -> "https://image.gametracker.com/images/maps/160x120/tf2/#{URI.encode(safe)}.jpg"
    end
  end

  defp parse_flags(nil), do: []

  defp parse_flags(value) do
    value
    |> str()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp admin_flags_for_ids([]), do: %{}

  defp admin_flags_for_ids(ids) do
    cache_file = Application.get_env(:whale_chat, :mapsdb_admin_cache_file, "/var/www/kogasatopia/stats/cache/admins_cache.json")

    with {:ok, json} <- File.read(cache_file),
         {:ok, %{"admins" => admins}} <- Jason.decode(json) do
      ids
      |> Enum.reduce(%{}, fn id, acc -> Map.put(acc, id, truthy?(Map.get(admins, id))) end)
    else
      _ -> %{}
    end
  end

  defp truthy?(v) when v in [true, 1, "1", "true", "yes", "on"], do: true
  defp truthy?(_), do: false

  defp map_rows(rows, columns) do
    Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)
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

  defp float(nil), do: 0.0
  defp float(v) when is_float(v), do: v
  defp float(v) when is_integer(v), do: v / 1
  defp float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp float(_), do: 0.0
end
