defmodule WhaleChat.InfoPage do
  @moduledoc false

  alias WhaleChat.LegacySite

  @changes_path Path.join([LegacySite.docroot(), "info", "data", "changes.json"])
  @active_class "scout"

  @classes [
    %{id: 1, key: "scout", label: "Scout", icon: "scout.png"},
    %{id: 2, key: "sniper", label: "Sniper", icon: "sniper.png"},
    %{id: 3, key: "soldier", label: "Soldier", icon: "soldier.png"},
    %{id: 4, key: "demoman", label: "Demoman", icon: "demoman.png"},
    %{id: 5, key: "medic", label: "Medic", icon: "medic.png"},
    %{id: 6, key: "heavy", label: "Heavy", icon: "heavy.png"},
    %{id: 7, key: "pyro", label: "Pyro", icon: "pyro.png"},
    %{id: 8, key: "spy", label: "Spy", icon: "spy.png"},
    %{id: 9, key: "engineer", label: "Engineer", icon: "engineer.png"}
  ]

  @class_icons Map.new(@classes, fn %{key: key, icon: icon} -> {key, icon} end)

  # Manual icon mapping copied from the original JS implementation for parity.
  @item_icons %{
    "Back Scatter" => "100px-item_icon_back_scatter.png",
    "Baby Face's" => "100px-item_icon_baby_face's_blaster.png",
    "The Shortstop" => "100px-item_icon_shortstop.png",
    "Flying Guillotine" => "100px-item_icon_flying_guillotine.png",
    "Crit-a-Cola" => "100px-item_icon_crit-a-cola.png",
    "The Sandman" => "100px-item_icon_sandman.png",
    "Candy Cane" => "100px-item_icon_candy_cane.png",
    "Fan-o-War" => "100px-Item_icon_Fan_O'War.png",
    "Air Strike" => "100px-item_icon_air_strike.png",
    "Liberty Launcher" => "100px-item_icon_liberty_launcher.png",
    "Righteous Bison" => "100px-item_icon_righteous_bison.png",
    "Base Jumper" => "100px-item_icon_b.a.s.e._jumper.png",
    "Equalizer" => "100px-item_icon_equalizer.png",
    "Dragon's Fury" => "100px-item_icon_dragon's_fury.png",
    "Degreaser" => "100px-item_icon_degreaser.png",
    "Detonator" => "100px-item_icon_detonator.png",
    "Axtinguisher" => "axtinguisher.png",
    "Volcano Fragment" => "100px-item_icon_sharpened_volcano_fragment.png",
    "Booties" => "booties.png",
    "Sticky Jumper" => "sticky_jumper.png",
    "Scottish Resistance" => "scottish_resistance.png",
    "Shields" => "shields.png",
    "Caber" => "100px-item_icon_ullapool_caber.png",
    "Scottish Handshake" => "scottish_handshake.png",
    "Huo-Long Heater" => "100px-item_icon_huo-long_heater.png",
    "Natascha" => "100px-item_icon_natascha.png",
    "Shotguns" => "100px-item_icon_panic_attack.png",
    "Gloves of Running" => "100px-item_gloves_of_running.png",
    "Eviction Notice" => "100px-Item_icon_Eviction_Notice.png",
    "Warrior's Spirit" => "100px-item_icon_warrior's_spirit.png",
    "Pomson" => "100px-item_icon_pomson_6000.png",
    "The Wrangler" => "100px-item_icon_wrangler.png",
    "The Short Circuit" => "100px-item_icon_short_circuit.png",
    "Southern Hospitality" => "100px-item_icon_southern_hospitality.png",
    "Sentry Guns" => "sentry.png",
    "Amplifier" => "amplifier.png",
    "Syringe Guns" => "100px-item_icon_syringe_gun.png",
    "The Vita-Saw" => "100px-item_icon_vita-saw.png",
    "The Vaccinator" => "100px-item_icon_vaccinator.png",
    "The Huntsman" => "100px-item_icon_huntsman.png",
    "The Classic" => "100px-item_icon_classic.png",
    "The Cozy Camper" => "100px-Item_cozy_camper.png",
    "The Cleaner's Carbine" => "100px-item_icon_cleaner's_carbine.png",
    "The Tribalman's Shiv" => "100px-Item_icon_Tribalman's_Shiv.png",
    "The Ambassador" => "100px-item_icon_ambassador.png",
    "The Enforcer" => "100px-item_icon_enforcer.png",
    "The Big Earner" => "big_earner.png",
    "Your Eternal Reward" => "100px-item_icon_your_eternal_reward.png"
  }

  @upside_cues [
    "more accurate",
    "+15 hp",
    "allies",
    "more health",
    "ber on hit",
    "+5",
    "+20% dam",
    "no active",
    "lights up",
    "penetrat",
    "+20 health",
    "bonus",
    "+50% reload",
    "15 metal",
    "+15% reload",
    "+10%",
    "charge",
    "healing",
    "boost kept",
    "no damage penalty",
    "+100%",
    "no health drain",
    "no active damage penalty",
    "penalty reduced",
    "less bullet spread",
    "102",
    "0% cloak",
    "airblast jump",
    "mini-crits burning",
    "crits burning",
    "no mark",
    "damage vulnerability reduced",
    "wall climbing",
    "no aim flinch",
    "on kill",
    "instead of",
    "deploy",
    "ranged sources",
    "hitbox",
    "ignores",
    "ignites",
    "stuns",
    "even without",
    "max stickies",
    "arm time",
    "provide",
    "deals 1",
    "market",
    "holster",
    "retain"
  ]

  @downside_cues [
    "violent",
    "does not slow",
    "-20% base",
    "-95%",
    "all resistances",
    "+20% damage taken",
    "-20",
    "75% less",
    "marks for",
    "non-burning",
    "66%",
    "No ammo",
    "range",
    "no disguise"
  ]

  def assigns do
    items_by_class = load_items_by_class()
    preload_images = preload_images(items_by_class)

    %{
      classes: @classes,
      active_class: @active_class,
      initial_items: Map.get(items_by_class, @active_class, []),
      payload_json: Jason.encode!(%{active_class: @active_class, items_by_class: items_by_class}),
      preload_images: preload_images
    }
  end

  defp load_items_by_class do
    raw = read_changes_json()

    Enum.reduce(@classes, %{}, fn %{key: class_key}, acc ->
      items =
        raw
        |> Map.get(class_key, [])
        |> List.wrap()
        |> Enum.map(&normalize_item(&1, class_key))

      Map.put(acc, class_key, items)
    end)
  end

  defp read_changes_json do
    with {:ok, body} <- File.read(@changes_path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      decoded
    else
      _ -> %{}
    end
  end

  defp normalize_item(item, class_key) do
    name =
      case item do
        %{"name" => value} when is_binary(value) -> value
        _ -> ""
      end

    effects =
      case item do
        %{"effects" => list} when is_list(list) ->
          Enum.map(list, fn effect -> effect |> to_string() |> String.trim() end)

        _ ->
          []
      end

    %{
      name: name,
      icon: "/info/icons/" <> icon_filename(name, class_key),
      title: title_text(name, effects),
      search: String.downcase(name <> " " <> Enum.join(effects, " ")),
      effects: Enum.map(effects, &classify_segment/1)
    }
  end

  defp title_text(name, effects) do
    case effects do
      [] -> name
      _ -> name <> ": " <> Enum.join(effects, "; ")
    end
  end

  defp classify_segment(text) do
    trimmed = String.trim(text)
    low = String.downcase(trimmed)

    is_down =
      Enum.any?(@downside_cues, &String.contains?(low, &1)) and not String.contains?(low, "+")

    is_up = not is_down and Enum.any?(@upside_cues, &String.contains?(low, &1))

    %{
      text: trimmed,
      cls:
        cond do
          is_down -> "downside"
          is_up -> "upside"
          true -> "neutral"
        end
    }
  end

  defp icon_filename(name, class_key) do
    no_the = String.replace_prefix(name, "The ", "")

    cond do
      icon = @item_icons[name] -> icon
      icon = @item_icons[no_the] -> icon
      true -> Map.get(@class_icons, class_key, "scout.png")
    end
  end

  defp preload_images(items_by_class) do
    class_images =
      Enum.map(@classes, fn %{icon: icon} -> "/info/icons/" <> icon end)

    item_images =
      items_by_class
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.icon)

    (class_images ++ item_images)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
