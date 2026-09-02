defmodule KogasaFrontend.Chat.BannedIp do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  schema "webchat_banned_ips" do
    field :subnet, :string
    field :banned_at, :integer
    field :expires_at, :integer
    field :reason, :string
  end

  def changeset(ban, attrs) do
    ban
    |> cast(attrs, [:subnet, :banned_at, :expires_at, :reason])
    |> validate_required([:subnet, :banned_at, :expires_at, :reason])
    |> unique_constraint(:subnet)
  end
end
