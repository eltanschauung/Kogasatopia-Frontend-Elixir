defmodule KogasaFrontend.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id
  @timestamps_opts [type: :utc_datetime]

  schema "whaletracker_chat" do
    field :created_at, :integer
    field :steamid, :string
    field :personaname, :string
    field :iphash, :string
    field :source_subnet, :string
    field :message, :string
    field :server_ip, :string
    field :server_port, :integer
    field :alert, :boolean, default: true
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :created_at,
      :steamid,
      :personaname,
      :iphash,
      :source_subnet,
      :message,
      :server_ip,
      :server_port,
      :alert
    ])
    |> validate_required([:created_at, :iphash, :message])
    |> validate_length(:message, max: 180)
  end
end
