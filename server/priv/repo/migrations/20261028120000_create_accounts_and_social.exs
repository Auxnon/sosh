defmodule Sosh.Repo.Migrations.CreateAccountsAndSocial do
  use Ecto.Migration

  def change do
    # Accounts sign in by email; `handle` is the name everyone sees, and the
    # player's name in the world (`players.name`). Both are unique ignoring
    # case.
    create table(:users) do
      add :email, :string, null: false
      add :handle, :string, null: false
      add :hashed_password, :string, null: false
      add :confirmed_at, :utc_datetime
      # what they look like (`Sosh.Character`)
      add :character, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, ["lower(email)"], name: :users_email_index)
    create unique_index(:users, ["lower(handle)"], name: :users_handle_index)

    # Sessions, and the codes emailed to confirm an address or reset a
    # password. Only a SHA-256 of each token is kept.
    create table(:user_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      # "session", "confirm" or "reset"
      add :context, :string, null: false
      # the email a code went to
      add :sent_to, :string
      # wrong guesses at a code
      add :attempts, :integer, null: false, default: 0
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_tokens, [:user_id, :context])
    create unique_index(:user_tokens, [:context, :token])

    # One row per pair: `user_id` asked, `friend_id` was asked.
    create table(:friendships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :friend_id, references(:users, on_delete: :delete_all), null: false
      # "pending" or "accepted"
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:friendships, [:user_id, :friend_id])
    create index(:friendships, [:friend_id])

    # A server is a universe of the grid, with members.
    create table(:servers) do
      add :name, :string, null: false
      add :gx, :integer, null: false
      add :gy, :integer, null: false
      # nil for the servers the world was seeded with
      add :owner_id, references(:users, on_delete: :nilify_all)
      # "open", "friends" or "approval" (`Sosh.Servers`)
      add :policy, :string, null: false, default: "approval"
      add :description, :string, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:servers, [:gx, :gy])

    create table(:memberships) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # "owner", "admin", "moderator" or "member"
      add :role, :string, null: false, default: "member"
      # "member", "pending" (asked to join), "invited" or "banned"
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:server_id, :user_id])
    create index(:memberships, [:user_id])

    # A direct conversation between two people, `a_id` < `b_id`.
    create table(:conversations) do
      add :a_id, references(:users, on_delete: :delete_all), null: false
      add :b_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversations, [:a_id, :b_id])
    create index(:conversations, [:b_id])

    # A message in a server's chat or a conversation. It can carry items
    # for one person (`recipient_id`, the @mention): they're taken from
    # the author's bag when it's sent and only the recipient can open it
    # (`claimed_at`); the author can take them back until then
    # (`cancelled_at`).
    create table(:messages) do
      add :server_id, references(:servers, on_delete: :delete_all)
      add :conversation_id, references(:conversations, on_delete: :delete_all)
      add :author_id, references(:users, on_delete: :nilify_all)
      add :body, :text, null: false, default: ""
      add :item, :string
      add :count, :integer
      add :recipient_id, references(:users, on_delete: :nilify_all)
      add :claimed_at, :utc_datetime
      add :cancelled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:server_id, :id])
    create index(:messages, [:conversation_id, :id])
    create index(:messages, [:recipient_id])

    create constraint(:messages, :one_place,
             check: "(server_id IS NULL) <> (conversation_id IS NULL)"
           )
  end
end
