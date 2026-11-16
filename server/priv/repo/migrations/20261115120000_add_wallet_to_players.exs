defmodule Sosh.Repo.Migrations.AddWalletToPlayers do
  use Ecto.Migration

  def change do
    alter table(:players) do
      add :wallet, :bigint, null: false, default: 0
    end
  end
end
