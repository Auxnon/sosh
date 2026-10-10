defmodule Sosh.Repo.Migrations.CreateChunks do
  use Ecto.Migration

  def change do
    # One row per 16x16x16 chunk of the world, keyed by chunk coordinates.
    # `blocks` is 4096 bytes, one block id each (see Sosh.World).
    create table(:chunks, primary_key: false) do
      add :x, :integer, primary_key: true
      add :y, :integer, primary_key: true
      add :z, :integer, primary_key: true
      add :blocks, :binary, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
