defmodule Sosh.Social.Membership do
  @moduledoc "Someone's place in a server. See `Sosh.Servers`."
  use Ecto.Schema

  schema "memberships" do
    field :role, :string, default: "member"
    field :status, :string, default: "pending"
    belongs_to :server, Sosh.Social.Server
    belongs_to :user, Sosh.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
