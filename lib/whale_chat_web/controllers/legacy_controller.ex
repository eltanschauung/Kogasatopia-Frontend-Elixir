defmodule WhaleChatWeb.LegacyController do
  use WhaleChatWeb, :controller

  alias WhaleChat.Homepage
  alias WhaleChat.LegacySite
  alias WhaleChat.UpstreamProxy

  def home(conn, _params) do
    html = Homepage.render_html(mobile?: mobile_request?(conn))

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  def passthrough(conn, %{"path" => path_parts}) do
    req_path = "/" <> Enum.join(path_parts, "/")

    cond do
      leaderboard_root?(req_path) ->
        proxy_upstream_php(conn, "/leaderboard/index.php")

      proxy_leaderboard_php?(req_path) ->
        proxy_upstream_php(conn, req_path)

      proxy_playercount_widget_php?(req_path) ->
        proxy_upstream_php(conn, req_path)

      php_index_dir?(req_path) or String.ends_with?(req_path, ".php") ->
        redirect(conn, external: "https://kogasa.tf" <> req_path)

      true ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp php_index_dir?(request_path) do
    with {:ok, resolved} <- LegacySite.safe_resolve(request_path),
         true <- File.dir?(resolved) do
      File.regular?(Path.join(resolved, "index.php"))
    else
      _ -> false
    end
  end

  defp proxy_playercount_widget_php?(request_path) do
    String.starts_with?(request_path, "/playercount_widget/") and String.ends_with?(request_path, ".php")
  end

  defp proxy_leaderboard_php?(request_path) do
    String.starts_with?(request_path, "/leaderboard/") and String.ends_with?(request_path, ".php")
  end

  defp leaderboard_root?(request_path), do: request_path in ["/leaderboard", "/leaderboard/"]

  defp proxy_upstream_php(conn, request_path) do
    url =
      case conn.query_string do
        "" -> "https://kogasa.tf" <> request_path
        qs -> "https://kogasa.tf" <> request_path <> "?" <> qs
      end

    case UpstreamProxy.fetch_html(url) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, body)

      :error ->
        redirect(conn, external: "https://kogasa.tf" <> request_path)
    end
  end

  defp mobile_request?(conn) do
    ua = List.first(get_req_header(conn, "user-agent")) || ""
    String.contains?(ua, "Mobile") or String.contains?(ua, "Android")
  end
end
