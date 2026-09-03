defmodule KogasaFrontend.Chat do
  @moduledoc false

  import Ecto.Query
  import KogasaFrontend.Value, only: [truthy?: 1]
  alias Ecto.Multi

  alias KogasaFrontend.Chat.{
    AvatarService,
    IpBan,
    Message,
    MessageParts,
    OutboxMessage,
    Persona,
    RateLimiter,
    SpamGuard,
    SteamProfiles
  }

  alias KogasaFrontend.PlayerIdentity
  alias KogasaFrontend.Repo

  @topic "chat:live"
  @same_message_limit 3
  @same_message_window_seconds 300
  @message_volume_limit 15
  @message_volume_window_seconds 180

  def topic, do: @topic

  def list_messages(opts \\ %{}) do
    limit = opts |> Map.get(:limit, 50) |> normalize_limit()
    before_id = normalize_id(Map.get(opts, :before))
    after_id = normalize_id(Map.get(opts, :after))
    alerts_only = truthy?(Map.get(opts, :alerts_only, false))

    base =
      from m in Message,
        select: %{
          id: m.id,
          created_at: m.created_at,
          steamid: m.steamid,
          personaname: m.personaname,
          iphash: m.iphash,
          server_ip: m.server_ip,
          message: m.message,
          alert: m.alert
        }

    base =
      if alerts_only do
        from m in base, where: m.alert == true
      else
        base
      end

    {rows, has_more_older} =
      try do
        cond do
          is_integer(after_id) and after_id > 0 ->
            rows =
              from(m in base, where: m.id > ^after_id, order_by: [asc: m.id], limit: ^limit)
              |> Repo.all()

            {rows, false}

          true ->
            q =
              if is_integer(before_id) and before_id > 0 do
                from m in base, where: m.id < ^before_id
              else
                base
              end

            rows =
              from(m in q, order_by: [desc: m.id], limit: ^(limit + 1))
              |> Repo.all()

            has_extra = length(rows) > limit
            rows = if has_extra, do: Enum.take(rows, limit), else: rows
            {Enum.reverse(rows), has_extra}
        end
      rescue
        _ -> {[], false}
      end

    steamids = Enum.map(rows, fn r -> r[:steamid] || r["steamid"] end)
    steam_profiles = SteamProfiles.fetch_many(steamids)
    name_styles = PlayerIdentity.name_styles_for_ids(steamids)
    messages = Enum.map(rows, &format_message(&1, steam_profiles, name_styles))
    ids = Enum.map(messages, & &1.id)

    %{
      ok: true,
      messages: Enum.map(messages, &message_to_json/1),
      oldest_id: List.first(ids),
      newest_id: List.last(ids),
      latest_id: if(ids == [], do: nil, else: Enum.max(ids)),
      has_more_older: has_more_older
    }
  end

  def submit_message(actor, message) when is_binary(message) do
    message = String.trim(message)

    cond do
      message == "" -> {:error, :invalid}
      String.length(message) > 180 -> {:error, :invalid}
      true -> do_submit_message(actor, message)
    end
  end

  def ensure_session_persona(persona), do: Persona.ensure_persona(persona)

  def webname_options, do: Persona.webnames()

  defp do_submit_message(actor, "/" <> _ = message) do
    if actor[:steamid] do
      create_chat_message(actor, message)
    else
      case Persona.try_update_from_command(message) do
        {:not_command, _} ->
          create_chat_message(actor, message)

        {:persona_updated, persona} ->
          {:ok, {:persona_updated, persona}}

        {:persona_not_found, options} ->
          {:ok, {:persona_not_found, options}}
      end
    end
  end

  defp do_submit_message(actor, message), do: create_chat_message(actor, message)

  def create_chat_message(actor, message) do
    rate_key = "chat:" <> to_string(actor[:rate_key] || actor[:iphash] || "anon")
    same_message_key = same_message_rate_key(actor, message)
    message_volume_key = message_volume_rate_key(actor)

    cond do
      IpBan.blocked?(actor) ->
        {:error, :ip_banned}

      SpamGuard.automatic_ban_content?(message) ->
        immediate_ban_result(actor, :prohibited_content)

      not RateLimiter.allow?(rate_key, 5) ->
        {:error, :rate_limited}

      SpamGuard.suspicious_content?(message) ->
        antispam_limit_result(actor, :suspicious_content, :spam_limited)

      not RateLimiter.allow_count?(
        same_message_key,
        @same_message_limit,
        @same_message_window_seconds
      ) ->
        antispam_limit_result(actor, :canonical_duplicate, :duplicate_rate_limited)

      not RateLimiter.allow_count?(
        message_volume_key,
        @message_volume_limit,
        @message_volume_window_seconds
      ) ->
        antispam_limit_result(actor, :sustained_volume, :spam_limited)

      true ->
        now = System.system_time(:second)

        server_ip =
          actor[:server_ip] || Application.get_env(:kogasa_frontend, :chat_server_ip, "127.0.0.1")

        server_port =
          actor[:server_port] || Application.get_env(:kogasa_frontend, :chat_server_port, 443)

        display_name =
          cond do
            actor[:steamid] && actor[:personaname] -> actor[:personaname] <> " | Web"
            actor[:personaname] -> actor[:personaname]
            true -> "Web Player"
          end

        attrs = %{
          created_at: now,
          steamid: actor[:steamid],
          personaname: display_name,
          iphash: actor[:iphash],
          source_subnet: actor[:source_subnet],
          message: message,
          server_ip: server_ip,
          server_port: server_port,
          alert: true
        }

        outbox_attrs = %{
          created_at: now,
          iphash: actor[:iphash] || "anon",
          source_subnet: actor[:source_subnet],
          display_name: display_name,
          message: message,
          server_ip: server_ip,
          server_port: server_port
        }

        multi =
          Multi.new()
          |> Multi.insert(:chat, Message.changeset(%Message{}, attrs))
          |> Multi.insert(:outbox, OutboxMessage.changeset(%OutboxMessage{}, outbox_attrs))

        try do
          case Repo.transaction(multi) do
            {:ok, %{chat: msg}} ->
              row = Map.from_struct(msg)

              payload =
                row
                |> format_message(%{}, PlayerIdentity.name_styles_for_ids([row.steamid]))
                |> message_to_json()

              Phoenix.PubSub.broadcast(KogasaFrontend.PubSub, @topic, {:new_message, payload})
              {:ok, :sent}

            {:error, _step, _changeset, _changes} ->
              {:error, :server}
          end
        rescue
          _ -> {:error, :server}
        end
    end
  end

  defp antispam_limit_result(actor, reason, public_error) do
    case IpBan.record_antispam_block(actor, reason) do
      :banned -> {:error, :ip_banned}
      :not_banned -> {:error, public_error}
    end
  end

  defp immediate_ban_result(actor, reason) do
    case IpBan.ban_immediately(actor, reason) do
      :banned -> {:error, :ip_banned}
      :not_banned -> {:error, :spam_limited}
    end
  end

  defp same_message_rate_key(actor, message) do
    normalized_message = SpamGuard.normalize_for_fingerprint(message)

    "chat-repeat:" <>
      rate_digest(client_identity(actor)) <>
      ":" <>
      rate_digest(normalized_message)
  end

  defp message_volume_rate_key(actor) do
    "chat-volume:" <> rate_digest(client_identity(actor))
  end

  defp client_identity(actor) do
    Enum.find(
      [actor[:remote_ip], actor[:rate_key], actor[:iphash]],
      "anon",
      &(is_binary(&1) and &1 != "")
    )
  end

  defp rate_digest(value) do
    :sha256
    |> :crypto.hash(to_string(value))
    |> Base.encode16(case: :lower)
  end

  defp format_message(row, steam_profiles, name_styles) do
    iphash = row[:iphash] || row["iphash"]
    personaname = row[:personaname] || row["personaname"]
    steamid = row[:steamid] || row["steamid"]
    raw_message = row[:message] || row["message"] || ""
    {clan_tag, message} = MessageParts.split(raw_message, row)

    profile =
      if is_binary(steamid) and steamid != "", do: Map.get(steam_profiles, steamid), else: nil

    avatar =
      AvatarService.resolve(%{
        iphash: iphash,
        steamid: steamid,
        personaname: personaname,
        profile: profile
      })

    %{
      id: row[:id] || row["id"],
      created_at: row[:created_at] || row["created_at"] || 0,
      steamid: steamid,
      name: resolved_name(personaname, steamid, iphash, profile),
      name_style: Map.get(name_styles, steamid),
      avatar: avatar,
      clan_tag: clan_tag,
      message: message,
      alert: truthy?(row[:alert] || row["alert"] || false)
    }
  end

  defp resolved_name(nil, steamid, iphash, profile),
    do: resolved_name("", steamid, iphash, profile)

  defp resolved_name("", steamid, iphash, profile) do
    cond do
      is_map(profile) and is_binary(profile["personaname"]) and profile["personaname"] != "" ->
        profile["personaname"]

      is_binary(steamid) and steamid != "" ->
        steamid

      is_binary(iphash) and iphash != "" ->
        "Web Player ##{String.slice(iphash, 0, 6)}"

      true ->
        "Unknown"
    end
  end

  defp resolved_name(personaname, _steamid, _iphash, _profile), do: personaname

  defp message_to_json(msg) do
    %{
      id: msg.id,
      created_at: msg.created_at,
      steamid: msg.steamid,
      name: msg.name,
      name_style: msg.name_style,
      avatar: msg.avatar,
      clan_tag: msg.clan_tag,
      message: msg.message,
      alert: msg.alert
    }
  end

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(200)

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> normalize_limit(int)
      _ -> 50
    end
  end

  defp normalize_limit(_), do: 50

  defp normalize_id(nil), do: nil
  defp normalize_id(""), do: nil

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, _} when id > 0 -> id
      _ -> nil
    end
  end

  defp normalize_id(value) when is_integer(value) and value > 0, do: value
  defp normalize_id(_), do: nil
end
