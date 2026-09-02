defmodule KogasaFrontendWeb.ChatApiController do
  use KogasaFrontendWeb, :controller

  alias KogasaFrontend.Chat

  def index(conn, params) do
    payload =
      Chat.list_messages(%{
        limit: Map.get(params, "limit", "100"),
        before: Map.get(params, "before"),
        after: Map.get(params, "after"),
        alerts_only: Map.get(params, "alerts_only")
      })

    json(conn, payload)
  end

  def create(conn, _params) do
    identity = conn.assigns[:chat_identity] || %{}
    message = extract_message_param(conn)

    if is_binary(message) do
      case Chat.submit_message(identity, message) do
        {:ok, :sent} ->
          json(conn, %{ok: true})

        {:ok, {:persona_updated, persona}} ->
          conn
          |> put_session("wt_chat_persona", persona)
          |> json(%{ok: true, persona: persona, message: "persona-updated"})

        {:ok, {:persona_not_found, options}} ->
          json(conn, %{ok: true, message: "persona-not-found", options: options})

        {:error, :rate_limited} ->
          conn |> put_status(:too_many_requests) |> json(%{ok: false, error: "rate"})

        {:error, :duplicate_rate_limited} ->
          conn
          |> put_status(:too_many_requests)
          |> json(%{ok: false, error: "duplicate_rate"})

        {:error, :spam_limited} ->
          conn
          |> put_status(:too_many_requests)
          |> json(%{ok: false, error: "spam"})

        {:error, :ip_banned} ->
          conn
          |> put_status(:forbidden)
          |> json(%{ok: false, error: "ip_banned"})

        {:error, :invalid} ->
          conn |> put_status(:bad_request) |> json(%{ok: false, error: "invalid"})

        {:error, _} ->
          conn |> put_status(:internal_server_error) |> json(%{ok: false, error: "server"})
      end
    else
      conn |> put_status(:bad_request) |> json(%{ok: false, error: "invalid"})
    end
  end

  defp extract_message_param(conn) do
    case conn.body_params do
      %{"message" => message} when is_binary(message) ->
        message

      _ ->
        case read_body(conn) do
          {:ok, body, _conn} ->
            case Jason.decode(body) do
              {:ok, %{"message" => message}} when is_binary(message) -> message
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end
end
