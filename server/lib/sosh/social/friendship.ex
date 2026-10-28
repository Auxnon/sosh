defmodule Sosh.Social.Friendship do
  @moduledoc "A friend request, or a friendship once accepted. See `Sosh.Friends`."
  use Ecto.Schema

  schema "friendships" do
    field :status, :string, default: "pending"
    belongs_to :user, Sosh.Accounts.User
    belongs_to :friend, Sosh.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
