defmodule KogasaFrontend.InfoPage do
  @moduledoc false

  alias KogasaFrontend.Tf2Classes
  alias KogasaFrontend.WeaponsConfig

  @active_class "scout"
  @classes Tf2Classes.info_classes()
  @class_icons Map.new(@classes, fn %{key: key, icon: icon} -> {key, icon} end)

  def assigns do
    items_by_class = load_items_by_class()
    preload_images = preload_images(items_by_class)
    config_update = config_update_metadata()

    %{
      classes: @classes,
      active_class: @active_class,
      initial_items: Map.get(items_by_class, @active_class, []),
      payload_json: Jason.encode!(%{active_class: @active_class, items_by_class: items_by_class}),
      asset_version: asset_version(),
      preload_images: preload_images,
      config_update: config_update
    }
  end

  defp load_items_by_class do
    WeaponsConfig.items_by_class(@classes)
    |> Enum.into(%{}, fn {class_key, items} ->
      {class_key, Enum.map(items, &normalize_item(&1, class_key))}
    end)
  end

  defp normalize_item(item, class_key) do
    effects =
      [
        effect_segment(item.positive, "positive"),
        effect_segment(item.neutral, "neutral"),
        effect_segment(item.negative, "negative")
      ]
      |> Enum.reject(&is_nil/1)

    title_segments = Enum.map(effects, & &1.text)

    %{
      name: item.name,
      icon: icon_path(item.image, class_key),
      is_custom: item.type == "custom",
      is_reskin: item.reskin_only,
      title: title_text(item.name, title_segments),
      search: search_text(item.name, title_segments, item.type, item.reskin_only),
      effects: effects
    }
  end

  defp search_text(name, title_segments, type, reskin_only) do
    type_terms = if type == "custom", do: "custom cwx", else: type
    reskin_term = if reskin_only, do: " reskin", else: ""

    String.downcase(
      name <> " " <> Enum.join(title_segments, " ") <> " " <> type_terms <> reskin_term
    )
  end

  defp effect_segment(value, class_name) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> %{text: trimmed, cls: class_name}
    end
  end

  defp title_text(name, effects) do
    case effects do
      [] -> name
      _ -> name <> ": " <> Enum.join(effects, "; ")
    end
  end

  defp icon_path(image, class_key) when is_binary(image) do
    case String.trim(image) do
      "" -> fallback_icon(class_key)
      filename -> "/info/icons/" <> filename
    end
  end

  defp icon_path(_, class_key), do: fallback_icon(class_key)

  defp fallback_icon(class_key),
    do: "/info/icons/" <> Map.get(@class_icons, class_key, "scout.png")

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

  defp asset_version do
    ["priv/static/info/css/changes.css", "priv/static/info/js/info_page.js"]
    |> Enum.flat_map(fn path ->
      case File.stat(Path.expand(path), time: :posix) do
        {:ok, %{mtime: mtime}} -> [mtime]
        _ -> []
      end
    end)
    |> Enum.max(fn -> System.system_time(:second) end)
    |> Integer.to_string()
  end

  defp config_update_metadata do
    [
      {"weapons.cfg", WeaponsConfig.config_path()}
    ]
    |> Enum.flat_map(fn {filename, path} ->
      case File.stat(path, time: :local) do
        {:ok, %{mtime: mtime}} -> [%{filename: filename, mtime: mtime}]
        _ -> []
      end
    end)
    |> Enum.max_by(& &1.mtime, fn -> nil end)
    |> case do
      nil ->
        nil

      %{filename: filename, mtime: mtime} ->
        formatted = format_mtime(mtime)

        %{
          label: "updated " <> formatted,
          title: filename <> " was updated " <> formatted
        }
    end
  end

  defp format_mtime({{year, month, day}, {hour, minute, second}}) do
    "#{pad2(day)} #{month_name(month)} #{year} #{pad2(second)}:#{pad2(minute)}:#{pad2(hour)}"
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp month_name(1), do: "January"
  defp month_name(2), do: "February"
  defp month_name(3), do: "March"
  defp month_name(4), do: "April"
  defp month_name(5), do: "May"
  defp month_name(6), do: "June"
  defp month_name(7), do: "July"
  defp month_name(8), do: "August"
  defp month_name(9), do: "September"
  defp month_name(10), do: "October"
  defp month_name(11), do: "November"
  defp month_name(12), do: "December"
end
