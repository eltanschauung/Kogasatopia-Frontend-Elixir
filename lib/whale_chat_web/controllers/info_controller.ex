defmodule WhaleChatWeb.InfoController do
  use WhaleChatWeb, :controller

  alias WhaleChat.InfoPage

  def entry(conn, _params) do
    case conn.request_path do
      "/info" ->
        conn
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> redirect(to: "/info/")

      _ ->
        assigns = InfoPage.assigns()

        conn
        |> put_root_layout(false)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> render(:index, assigns)
    end
  end
end
