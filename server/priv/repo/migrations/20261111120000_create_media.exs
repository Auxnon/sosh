defmodule Sosh.Repo.Migrations.CreateMedia do
  use Ecto.Migration

  # Pictures (png, jpeg, gif, webp) and Petrichor64 carts shared in chat,
  # kept in Postgres with everything else. See Sosh.Media.
  def change do
    create table(:media) do
      add :key, :string, null: false
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :mime, :string, null: false
      add :animated, :boolean, null: false, default: false
      add :width, :integer, null: false
      add :height, :integer, null: false
      add :size, :integer, null: false
      add :name, :string
      add :data, :binary, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:media, [:key])
    create index(:media, [:owner_id])

    alter table(:messages) do
      add :media_id, references(:media, on_delete: :nilify_all)
    end
  end
end
