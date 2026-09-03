defmodule KogasaFrontend.Chat.IpBan do
  @moduledoc false

  import Ecto.Query
  require Logger

  alias KogasaFrontend.Chat.{BannedIp, RateLimiter}
  alias KogasaFrontend.Repo

  @antispam_strikes_before_ban 3
  @antispam_strike_window_seconds 300
  @ban_seconds 7 * 24 * 60 * 60
  @reason_prefix "webchat antispam"

  def blocked?(actor) do
    case subnet_for_actor(actor) do
      nil ->
        false

      subnet ->
        now = System.system_time(:second)
        Repo.exists?(from ban in BannedIp, where: ban.subnet == ^subnet and ban.expires_at > ^now)
    end
  rescue
    error ->
      Logger.error("Failed to check webchat IP ban: #{Exception.message(error)}")
      false
  end

  def record_antispam_block(actor, reason) do
    case subnet_for_actor(actor) do
      nil ->
        :not_banned

      subnet ->
        strike_key = "chat-ban-strikes:" <> subnet

        if RateLimiter.allow_count?(
             strike_key,
             @antispam_strikes_before_ban - 1,
             @antispam_strike_window_seconds
           ) do
          :not_banned
        else
          ban(subnet, reason)
        end
    end
  end

  def ban_immediately(actor, reason) do
    case subnet_for_actor(actor) do
      nil -> :not_banned
      subnet -> ban(subnet, reason)
    end
  end

  def subnet_for_actor(actor), do: subnet_for_ip(actor[:remote_ip])

  def subnet_for_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, address} -> subnet_for_ip(address)
      {:error, _reason} -> nil
    end
  end

  def subnet_for_ip({first, second, _, _})
      when first in 0..255 and second in 0..255 do
    "#{first}.#{second}.0.0/16"
  end

  def subnet_for_ip({0, 0, 0, 0, 0, 65_535, high, _low}) do
    first = Bitwise.bsr(high, 8)
    second = Bitwise.band(high, 255)
    "#{first}.#{second}.0.0/16"
  end

  def subnet_for_ip({a, b, c, d, _, _, _, _}) do
    "#{:inet.ntoa({a, b, c, d, 0, 0, 0, 0})}/64"
  end

  def subnet_for_ip(_ip), do: nil

  defp ban(subnet, reason) do
    now = System.system_time(:second)

    attrs = %{
      subnet: subnet,
      banned_at: now,
      expires_at: now + @ban_seconds,
      reason: "#{@reason_prefix}: #{reason}"
    }

    %BannedIp{}
    |> BannedIp.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, [:banned_at, :expires_at, :reason]})
    |> case do
      {:ok, _ban} ->
        :banned

      {:error, changeset} ->
        Logger.error("Failed to ban webchat subnet #{subnet}: #{inspect(changeset.errors)}")
        :not_banned
    end
  rescue
    error ->
      Logger.error("Failed to ban webchat subnet #{subnet}: #{Exception.message(error)}")
      :not_banned
  end
end
