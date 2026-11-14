defmodule Sosh.Repo.Migrations.ChatEditsReactionsSigns do
  use Ecto.Migration

  # Messages can be edited and reacted to, and a server message can be
  # pinned: a sign in the pinner's bag (`sign:<pin id>`), placed in the world
  # showing the message. See Sosh.Chat.
  def change do
    alter table(:messages) do
      add :edited_at, :utc_datetime
    end

    create table(:reactions) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :emoji, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:reactions, [:message_id, :user_id, :emoji])

    # a pin outlives its message: the sign then says it was removed
    create table(:pins) do
      add :message_id, references(:messages, on_delete: :nilify_all)
      add :user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:pins, [:message_id])
  end
end
