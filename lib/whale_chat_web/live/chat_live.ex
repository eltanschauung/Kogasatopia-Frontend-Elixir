defmodule WhaleChatWeb.ChatLive do
  use WhaleChatWeb, :live_view

  alias WhaleChat.Chat
  @poll_ms 4_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(WhaleChat.PubSub, Chat.topic())
      Process.send_after(self(), :poll_new_messages, @poll_ms)
    end

    persona = session["wt_chat_persona"] || Chat.ensure_session_persona(nil)

    identity =
      %{
        steamid: nil,
        personaname: persona["display"],
        persona: persona,
        iphash: short_hash(session),
        rate_key: session["wt_chat_client_token"] || "anon",
        server_ip: Application.get_env(:whale_chat, :chat_server_ip, "127.0.0.1"),
        server_port: Application.get_env(:whale_chat, :chat_server_port, 443)
      }
      |> ensure_persona(session, persona)

    payload = Chat.list_messages(%{limit: 50})

    {:ok,
     socket
     |> assign(:page_title, "Live Chat · WhaleChat")
     |> assign(:messages, payload.messages || [])
     |> assign(:latest_id, payload.latest_id || payload.newest_id)
     |> assign(:oldest_id, payload.oldest_id)
     |> assign(:has_more_older, payload.has_more_older)
     |> assign(:status, nil)
     |> assign(:message_input, "")
     |> assign(:identity, identity)}
  end

  @impl true
  def handle_event("send", %{"message" => message}, socket) do
    case Chat.submit_message(socket.assigns.identity, message) do
      {:ok, :sent} ->
        {:noreply, assign(socket, message_input: "", status: nil)}

      {:ok, {:persona_updated, persona}} ->
        identity = %{socket.assigns.identity | personaname: persona["display"], persona: persona}

        {:noreply,
         socket
         |> assign(:identity, identity)
         |> assign(:message_input, "")
         |> assign(:status, "Persona updated")}

      {:ok, {:persona_not_found, options}} ->
        names =
          options
          |> Enum.map(&Map.get(&1, "name"))
          |> Enum.filter(&is_binary/1)
          |> Enum.join(", ")

        status =
          if names == "", do: "Persona not found", else: "Persona not found — available: #{names}"

        {:noreply, assign(socket, :status, status)}

      {:error, :rate_limited} ->
        {:noreply, assign(socket, :status, "Rate limited (wait 5s)")}

      {:error, :invalid} ->
        {:noreply, assign(socket, :status, "Invalid message")}

      {:error, _} ->
        {:noreply, assign(socket, :status, "Failed to send message")}
    end
  end

  @impl true
  def handle_event("change", %{"message" => message}, socket) do
    {:noreply, assign(socket, :message_input, message)}
  end

  @impl true
  def handle_event("load_older", _params, socket) do
    if socket.assigns.has_more_older && socket.assigns.oldest_id do
      payload = Chat.list_messages(%{before: socket.assigns.oldest_id, limit: 50})
      older = payload.messages || []
      merged = older ++ socket.assigns.messages
      prepended = older != []

      {:reply,
       %{prepended: prepended, has_more_older: payload.has_more_older, oldest_id: payload.oldest_id},
       socket
       |> assign(:messages, dedupe_by_id(merged))
       |> assign(:oldest_id, payload.oldest_id || socket.assigns.oldest_id)
       |> assign(:has_more_older, payload.has_more_older)}
    else
      {:reply, %{prepended: false, has_more_older: false, oldest_id: socket.assigns.oldest_id}, socket}
    end
  end

  @impl true
  def handle_info({:new_message, msg}, socket) do
    latest_id = max_id(socket.assigns.latest_id, msg)

    {:noreply,
     socket
     |> assign(:latest_id, latest_id)
     |> update(:messages, fn messages -> dedupe_by_id(messages ++ [msg]) end)}
  end

  @impl true
  def handle_info(:poll_new_messages, socket) do
    payload =
      case socket.assigns[:latest_id] do
        id when is_integer(id) and id > 0 -> Chat.list_messages(%{after: id, limit: 100})
        _ -> Chat.list_messages(%{limit: 1})
      end

    socket =
      socket
      |> assign(:latest_id, payload[:latest_id] || socket.assigns[:latest_id])
      |> update(:messages, fn messages -> dedupe_by_id(messages ++ (payload[:messages] || [])) end)

    Process.send_after(self(), :poll_new_messages, @poll_ms)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide={true}>
      <div id="chat-container">
        <div class="chat-nav-row chat-nav-row-top">
          <a href="/" class="chat-home-btn">Blog</a>
          <a href="/stats" class="chat-home-btn">Stats</a>
          <a href="/online" class="chat-nav-pill">
            Online Now
            <span id="chat-nav-online-count-top" class="chat-nav-pill-count">-- / --</span>
          </a>
          <a href="/logs" class="chat-nav-pill">Match Logs</a>
          <span class="chat-nav-pill" aria-current="page">Chat</span>
          <a href="/mapsdb" class="chat-nav-pill">MapsDB</a>
        </div>

        <div class="chat-topbar">
          <div>
            <h1 class="chat-title">WhaleChat</h1>
            <p id="nav-chat-label" class="chat-subtitle">Last msg. --</p>
          </div>
          <div class="chat-topbar-right">
            <span id="nav-online-count" class="chat-online-count" data-mirror-target="chat-nav-online-count-top">
              -- / --
            </span>
          </div>
        </div>

        <div id="chat-panel" class="players-list">
          <div id="chat-messages" phx-hook="ChatViewport">
            <%= if @messages == [] do %>
              <p class="chat-empty">No messages yet.</p>
            <% else %>
              <%= for msg <- @messages do %>
                <div
                  id={"msg-#{msg.id}"}
                  data-chat-row
                  data-chat-id={msg.id}
                  data-chat-alert={if(msg.alert, do: "1", else: "0")}
                  class="chat-row"
                >
                  <img src={msg.avatar} alt="" class="chat-avatar" />
                  <div class="chat-content">
                    <div class="chat-header">
                      <.colored text={msg.name} class="chat-name" />
                      <span class="chat-timestamp">{format_time(msg.created_at)}</span>
                    </div>
                    <div class="chat-text">
                      <.colored text={msg.message} />
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>

          <div class="chat-nav-stack" aria-label="Chat navigation controls">
            <button id="chat-btn-lock" type="button" aria-pressed="true" title="Lock chat to bottom" class="navarrow navarrow-lock">
              <img src="/stats/assets/keine_lock.png" alt="Lock chat to bottom" />
            </button>
            <button id="chat-btn-top" type="button" title="Scroll to top" class="navarrow navarrow-top">
              <img src="/stats/assets/reisen_up.png" alt="Scroll to top" />
            </button>
            <button id="chat-btn-bottom" type="button" title="Scroll to bottom" class="navarrow navarrow-bottom">
              <img src="/stats/assets/tewi_down.png" alt="Scroll to bottom" />
            </button>
          </div>
        </div>

        <form id="chat-form" phx-submit="send" phx-change="change" class="chat-form" autocomplete="off">
          <textarea
            id="chat-input"
            name="message"
            phx-hook="ChatComposer"
            rows="2"
            maxlength="180"
            data-dynamic-placeholder="Type to {count} players | All messages are deleted after 24hrs"
            placeholder="Type to 0 players | All messages are deleted after 24hrs"
          ><%= @message_input %></textarea>
          <button id="chat-send" type="submit">Send</button>
        </form>

        <div id="chat-status" class={["chat-status", @status && "chat-status-error"]}>{@status}</div>
      </div>
    </Layouts.app>
    """
  end

  defp format_time(nil), do: ""

  defp format_time(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M")
      _ -> ""
    end
  end

  defp format_time(_), do: ""

  defp dedupe_by_id(messages) do
    messages
    |> Enum.reduce({MapSet.new(), []}, fn msg, {seen, acc} ->
      id = Map.get(msg, :id) || Map.get(msg, "id")

      if is_nil(id) or MapSet.member?(seen, id) do
        {seen, acc}
      else
        {MapSet.put(seen, id), [msg | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp max_id(current, msg) do
    msg_id = Map.get(msg, :id) || Map.get(msg, "id")

    cond do
      is_integer(current) and is_integer(msg_id) -> max(current, msg_id)
      is_integer(msg_id) -> msg_id
      true -> current
    end
  end

  defp short_hash(session) do
    token = session["wt_chat_client_token"] || "anon"
    secret = Application.get_env(:whale_chat, :chat_ip_secret, "changeme")

    :sha256
    |> :crypto.hash("#{secret}|#{token}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  defp ensure_persona(identity, session, fallback_persona) do
    case get_in(session, ["wt_chat_persona", "display"]) do
      nil ->
        persona = fallback_persona || Chat.ensure_session_persona(nil)
        %{identity | personaname: persona["display"], persona: persona}

      _ ->
        identity
    end
  end
end
