defmodule KogasaFrontend.Repo.Migrations.CreateWebchatBannedIps do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:webchat_banned_ips) do
      add :subnet, :string, size: 64, null: false
      add :banned_at, :integer, null: false
      add :expires_at, :integer, null: false
      add :reason, :string, size: 128, null: false
    end

    create unique_index(:webchat_banned_ips, [:subnet])
    create index(:webchat_banned_ips, [:expires_at])
  end
end
