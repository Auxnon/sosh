defmodule Sosh.Repo.Migrations.AddCraftingToPlayers do
  use Ecto.Migration

  def change do
    alter table(:players) do
      add :crafting, :map, null: false, default: %{}
      add :stations, {:array, :string}, null: false, default: []
    end
  end
end
