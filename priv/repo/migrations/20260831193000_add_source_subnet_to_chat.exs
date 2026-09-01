defmodule KogasaFrontend.Repo.Migrations.AddSourceSubnetToChat do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE whaletracker_chat ADD COLUMN IF NOT EXISTS source_subnet VARCHAR(32) NULL AFTER iphash",
      "ALTER TABLE whaletracker_chat DROP COLUMN IF EXISTS source_subnet"
    )

    execute(
      "ALTER TABLE whaletracker_chat_outbox ADD COLUMN IF NOT EXISTS source_subnet VARCHAR(32) NULL AFTER iphash",
      "ALTER TABLE whaletracker_chat_outbox DROP COLUMN IF EXISTS source_subnet"
    )
  end
end
