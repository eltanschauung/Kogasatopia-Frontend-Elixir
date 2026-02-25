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
end
