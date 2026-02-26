defmodule WhaleChat.LegacySite do
  @moduledoc false

  @docroot "/var/www/kogasatopia"
  @blog_fragment Path.join([@docroot, "home", "includes", "blog.html"])
  @homepage_preload_images [
    "/background_lumberyard.png",
    "/main_panel.png",
    "/white_panel.png",
    "/trump_update_card.png",
    "/twitter.png",
    "/55.png",
    "/keyedbnat.png",
    "/moriyashrine.png",
    "/github.png",
    "/whaletracker.png",
    "/tf2steam.png"
  ]

  def docroot, do: @docroot

  def homepage_preload_images do
    (@homepage_preload_images ++ blog_image_paths())
    |> Enum.uniq()
  end

  def homepage_immutable_images do
    homepage_preload_images()
    |> MapSet.new()
  end

  def safe_resolve(request_path) when is_binary(request_path) do
    rel = request_path |> String.trim_leading("/")
    candidate = Path.expand(rel, @docroot)
    root = Path.expand(@docroot)

    if candidate == root or String.starts_with?(candidate, root <> "/") do
      {:ok, candidate}
    else
      :error
    end
  end

  defp blog_image_paths do
    case File.read(@blog_fragment) do
      {:ok, html} ->
        Regex.scan(
          ~r/<img[^>]*\bclass="[^"]*\bblog_image\b[^"]*"[^>]*\bsrc="([^"]+\.(?:png|jpe?g|gif|webp|svg))"/i,
          html,
          capture: :all_but_first
        )
        |> List.flatten()
        |> Enum.map(&normalize_local_src/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp normalize_local_src(src) when is_binary(src) do
    cond do
      String.starts_with?(src, "http://") or String.starts_with?(src, "https://") -> nil
      String.starts_with?(src, "//") -> nil
      String.starts_with?(src, "/") -> src
      true -> "/" <> src
    end
  end
end
