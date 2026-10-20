defmodule Sosh.Repo.Migrations.CreateUniverses do
  use Ecto.Migration

  def change do
    # The grid of universes. A universe's islands are generated from its
    # seed; `state` is what the Rust universe keeps besides its chunks
    # (crops, furniture, blueprints, airships, the world tick), as JSON.
    create table(:universes, primary_key: false) do
      add :gx, :integer, primary_key: true
      add :gy, :integer, primary_key: true
      # "sea" or "land": what lies far below its islands
      add :kind, :string, null: false, default: "sea"
      add :seed, :bigint, null: false
      add :state, :binary

      timestamps(type: :utc_datetime)
    end

    # Chunks belong to a universe now; the old ones are universe (0, 0)'s.
    alter table(:chunks) do
      add :gx, :integer, null: false, default: 0
      add :gy, :integer, null: false, default: 0
    end

    execute(
      "ALTER TABLE chunks DROP CONSTRAINT chunks_pkey",
      "ALTER TABLE chunks ADD PRIMARY KEY (x, y, z)"
    )

    execute(
      "ALTER TABLE chunks ADD PRIMARY KEY (gx, gy, x, y, z)",
      "ALTER TABLE chunks DROP CONSTRAINT chunks_pkey"
    )

    # Players by name: their bag, and where they were last.
    create table(:players, primary_key: false) do
      add :name, :string, primary_key: true
      add :gx, :integer, null: false, default: 0
      add :gy, :integer, null: false, default: 0
      add :at, {:array, :float}
      add :bag, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end
  end
end
