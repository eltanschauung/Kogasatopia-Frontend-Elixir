defmodule WhaleChatWeb.StatsHTML do
  use WhaleChatWeb, :html

  embed_templates "stats_html/*"

  def number_format(v) do
    v
    |> to_number()
    |> trunc()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(.{3})(?=.)/, "\\1,")
    |> String.reverse()
  end

  def format_decimal(v, digits \\ 1) do
    v
    |> to_float()
    |> :erlang.float_to_binary(decimals: max(0, digits))
  end

  def summary_week_trend_class(summary) do
    {_, trend} = normalized_week_change(summary)

    if trend in ["up", "down", "flat"], do: "stat-card-trend stat-card-trend--#{trend}", else: "stat-card-trend stat-card-trend--flat"
  end

  def summary_week_change_label(summary) do
    case elem(normalized_week_change(summary), 0) do
      nil -> "—"
      value when is_number(value) ->
        sign = if value >= 0, do: "+", else: ""
        sign <> :erlang.float_to_binary(value / 1, decimals: 1) <> "%"
      _ -> "—"
    end
  end

  def summary_week_tooltip(summary) do
    label = summary_week_change_label(summary)
    "Change vs prior 7 days: " <> if(label == "—", do: "not enough data", else: label)
  end

  def avatar_or_default(nil, default), do: default
  def avatar_or_default(map, default) when is_map(map), do: map[:avatar] || map["avatar"] || default
  def avatar_or_default(_, default), do: default

  def display_name(nil), do: "Unknown"
  def display_name(map) when is_map(map), do: map[:personaname] || map["personaname"] || map[:steamid] || map["steamid"] || "Unknown"
  def display_name(v), do: to_string(v)

  def map_get(summary, key, default \\ nil), do: get_key(summary, key, default)

  defp to_number(v) when is_integer(v), do: v
  defp to_number(v) when is_float(v), do: v

  defp to_number(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> 0
        end
    end
  end

  defp to_number(_), do: 0

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v / 1

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error ->
        case Integer.parse(v) do
          {i, _} -> i / 1
          :error -> 0.0
        end
    end
  end

  defp to_float(_), do: 0.0

  defp get_key(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
  defp get_key(_, _key, default), do: default

  # Match PHP wt_build_summary_context() behavior: clamp negative weekly change to 0.0 and mark as "up".
  defp normalized_week_change(summary) do
    raw = get_key(summary, :players_week_change_percent, nil)
    trend = get_key(summary, :players_week_trend, "flat") |> to_string()
    trend = if trend in ["up", "down", "flat"], do: trend, else: "flat"

    cond do
      is_number(raw) and raw < 0.0 -> {0.0, "up"}
      is_number(raw) -> {raw / 1, trend}
      true -> {nil, trend}
    end
  end
end
