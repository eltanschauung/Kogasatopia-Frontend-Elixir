defmodule WhaleChatWeb.StatsLoginController do
  use WhaleChatWeb, :controller

  @steam_openid_url "https://steamcommunity.com/openid/login"
  @openid_ns "http://specs.openid.net/auth/2.0"
  @openid_identifier_select "http://specs.openid.net/auth/2.0/identifier_select"

  def show(conn, params) do
    action = params["action"] || "login"
    return_to = sanitize_return(params["return"] || "/stats")

    case action do
      "logout" ->
        conn
        |> configure_session(drop: true)
        |> redirect(to: return_to)

      _ ->
        login_or_callback(conn, params, return_to)
    end
  end

  defp login_or_callback(conn, %{"steamid" => steamid}, return_to) when is_binary(steamid) do
    steamid = String.trim(steamid)

    if Regex.match?(~r/^\d{17}$/, steamid) do
      conn
      |> put_session("steamid", steamid)
      |> redirect(to: return_to)
    else
      render_error_page(conn, return_to, "Invalid SteamID64. Expected 17 digits.")
    end
  end

  defp login_or_callback(conn, %{"openid.mode" => "cancel"}, return_to) do
    redirect(conn, to: append_query_flag(return_to, "login", "cancelled"))
  end

  defp login_or_callback(conn, %{"openid.mode" => _} = params, return_to) do
    case validate_openid_response(conn, params, return_to) do
      {:ok, steamid} ->
        conn
        |> put_session("steamid", steamid)
        |> redirect(to: return_to)

      {:error, reason} ->
        render_error_page(conn, return_to, reason)
    end
  end

  defp login_or_callback(conn, _params, return_to) do
    redirect(conn, external: build_steam_login_url(conn, return_to))
  end

  defp build_steam_login_url(conn, return_to) do
    return_url = absolute_login_return_url(conn, return_to)
    realm = request_realm(conn)

    query = URI.encode_query(%{
      "openid.ns" => @openid_ns,
      "openid.mode" => "checkid_setup",
      "openid.identity" => @openid_identifier_select,
      "openid.claimed_id" => @openid_identifier_select,
      "openid.return_to" => return_url,
      "openid.realm" => realm
    })

    @steam_openid_url <> "?" <> query
  end

  defp validate_openid_response(conn, params, return_to) do
    openid_fields =
      params
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "openid.") end)
      |> Map.new()
      |> Map.put("openid.mode", "check_authentication")
      |> Map.put("openid.return_to", absolute_login_return_url(conn, return_to))

    with {:ok, response} <- Req.post(@steam_openid_url, form: openid_fields),
         true <- response.status in 200..299,
         body when is_binary(body) <- response.body,
         true <- String.contains?(body, "is_valid:true"),
         {:ok, steamid} <- steamid_from_claimed_id(params["openid.claimed_id"]) do
      {:ok, steamid}
    else
      false -> {:error, "Steam OpenID validation failed."}
      {:error, %Req.TransportError{reason: reason}} -> {:error, "Steam OpenID network error: #{inspect(reason)}"}
      {:error, reason} -> {:error, "Steam OpenID error: #{inspect(reason)}"}
      _ -> {:error, "Steam OpenID validation failed."}
    end
  end

  defp steamid_from_claimed_id(claimed_id) when is_binary(claimed_id) do
    case Regex.run(~r|^https://steamcommunity\.com/openid/id/(\d+)$|, claimed_id) do
      [_full, steamid] -> {:ok, steamid}
      _ -> {:error, :invalid_claimed_id}
    end
  end

  defp steamid_from_claimed_id(_), do: {:error, :missing_claimed_id}

  defp absolute_login_return_url(conn, return_to) do
    request_realm(conn) <> "/stats/login.php?return=" <> URI.encode(return_to)
  end

  defp request_realm(conn) do
    scheme =
      case get_req_header(conn, "x-forwarded-proto") do
        [proto | _] when proto in ["http", "https"] -> proto
        _ -> Atom.to_string(conn.scheme || :http)
      end

    host =
      case get_req_header(conn, "x-forwarded-host") do
        [value | _] -> value
        _ -> List.first(get_req_header(conn, "host")) || "localhost"
      end

    scheme <> "://" <> host
  end

  defp append_query_flag(path, key, value) do
    uri = URI.parse(path)
    existing = if uri.query, do: URI.decode_query(uri.query), else: %{}
    %{uri | query: URI.encode_query(Map.put(existing, key, value))} |> URI.to_string()
  end

  defp render_error_page(conn, return_to, error_msg) do
    esc = fn value -> value |> to_string() |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary() end
    steamid = get_session(conn, "steamid")

    html = """
    <!doctype html>
    <html lang="en"><head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Stats Login</title>
      <style>
        body { font-family: sans-serif; background:#0f1118; color:#eee; margin:0; padding:2rem; }
        .card { max-width:760px; margin:0 auto; background:#171b26; border:1px solid #303749; border-radius:12px; padding:1rem 1.25rem; }
        a { display:inline-block; margin-top:.6rem; padding:.5rem .9rem; border-radius:8px; border:1px solid #51607d; background:#36455f; color:#fff; text-decoration:none; }
        .muted { color:#aab2c5; } .err { color:#ff9b9b; } code { background:#0b0f18; padding:.1rem .3rem; border-radius:4px; }
      </style>
    </head><body><div class="card">
      <h1>Steam Login Error</h1>
      <p class="err">#{esc.(error_msg)}</p>
      <p class="muted">Current session steamid: <code>#{esc.(steamid || "none")}</code></p>
      <p><a href="/stats/login.php?return=#{URI.encode(return_to)}">Try Steam login again</a></p>
      <p><a href="#{esc.(return_to)}">Return to stats</a></p>
    </div></body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp sanitize_return(path) do
    if is_binary(path) and String.starts_with?(path, "/") and not String.starts_with?(path, "//"), do: path, else: "/stats"
  end
end
