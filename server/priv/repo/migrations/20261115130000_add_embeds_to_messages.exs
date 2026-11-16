defmodule Sosh.Repo.Migrations.AddEmbedsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :embeds, {:array, :map}, null: false, default: []
    end
  end
end
