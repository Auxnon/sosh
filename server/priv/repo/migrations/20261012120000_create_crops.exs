defmodule Sosh.Repo.Migrations.CreateCrops do
  use Ecto.Migration

  def change do
    # One row per planted crop, at the air cell it grows in. Growth isn't
    # stored: it follows from planted_ms and the wall clock (see Sosh.Sim).
    create table(:crops, primary_key: false) do
      add :x, :integer, primary_key: true
      add :y, :integer, primary_key: true
      add :z, :integer, primary_key: true
      add :kind, :string, null: false, default: "carrot"
      add :planted_ms, :bigint, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
