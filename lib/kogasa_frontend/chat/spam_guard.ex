defmodule KogasaFrontend.Chat.SpamGuard do
  @moduledoc false

  @non_text_codepoints ~r/[\p{Cc}\p{Cf}\p{Co}\p{Cn}]/u
  @low_diversity_min_length 12
  @dominant_grapheme_ratio 0.8
  @suspicious_codepoint_ratio 0.5
  @automatic_ban_terms ["porn", "child"]

  def normalize_for_fingerprint(message) when is_binary(message) do
    message
    |> normalize()
    |> String.replace(@non_text_codepoints, "")
    |> String.graphemes()
    |> collapse_repeated_graphemes()
    |> Enum.join()
  end

  def suspicious_content?(message) when is_binary(message) do
    graphemes =
      message
      |> normalize()
      |> String.graphemes()

    low_diversity?(graphemes) || suspicious_codepoints?(graphemes)
  end

  def automatic_ban_content?(message) when is_binary(message) do
    normalized = normalize(message)
    Enum.all?(@automatic_ban_terms, &String.contains?(normalized, &1))
  end

  defp normalize(message) do
    message
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp collapse_repeated_graphemes(graphemes) do
    {collapsed, _last, _count} =
      Enum.reduce(graphemes, {[], nil, 0}, fn grapheme, {result, last, count} ->
        cond do
          grapheme != last ->
            {[grapheme | result], grapheme, 1}

          count < 2 ->
            {[grapheme | result], last, count + 1}

          true ->
            {result, last, count + 1}
        end
      end)

    Enum.reverse(collapsed)
  end

  defp low_diversity?(graphemes) do
    length = length(graphemes)

    if length < @low_diversity_min_length do
      false
    else
      frequencies = Enum.frequencies(graphemes)
      dominant_count = frequencies |> Map.values() |> Enum.max()

      map_size(frequencies) <= 2 ||
        dominant_count / length >= @dominant_grapheme_ratio
    end
  end

  defp suspicious_codepoints?(graphemes) do
    length = length(graphemes)

    if length < @low_diversity_min_length do
      false
    else
      suspicious_count =
        Enum.count(graphemes, &Regex.match?(@non_text_codepoints, &1))

      suspicious_count / length >= @suspicious_codepoint_ratio
    end
  end
end
