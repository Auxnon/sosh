defmodule Sosh.Social.Message do
  @moduledoc "A chat message, maybe carrying items for someone. See `Sosh.Chat`."
  use Ecto.Schema

  schema "messages" do
    field :body, :string, default: ""
    field :item, :string
    field :count, :integer
    field :claimed_at, :utc_datetime
    field :cancelled_at, :utc_datetime
    belongs_to :server, Sosh.Social.Server
    belongs_to :conversation, Sosh.Social.Conversation
    belongs_to :author, Sosh.Accounts.User
    belongs_to :recipient, Sosh.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
