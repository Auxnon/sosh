defmodule Sosh.Repo.Migrations.AddMapToUniverses do
  use Ecto.Migration

  # a universe's map picture (Sosh.Maps), redrawn as it's saved
  def change do
    alter table(:universes) do
      add :map, :binary
      add :map_at, :utc_datetime
    end
  end
end
