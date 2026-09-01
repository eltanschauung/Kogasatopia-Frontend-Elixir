defmodule KogasaFrontend.Chat.OutboxMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "whaletracker_chat_outbox" do
    field :created_at, :integer
    field :iphash, :string
    field :source_subnet, :string
    field :display_name, :string
    field :message, :string
    field :server_ip, :string
    field :server_port, :integer
    field :delivered_to, :string
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :created_at,
      :iphash,
      :source_subnet,
      :display_name,
      :message,
      :server_ip,
      :server_port,
      :delivered_to
    ])
    |> validate_required([:created_at, :iphash, :message])
    |> validate_length(:message, max: 180)
  end
end
