defmodule Sosh.Social.Reaction do
  @moduledoc "Someone's emoji on a message. See `Sosh.Chat.react/4`."
  use Ecto.Schema

  schema "reactions" do
    field :emoji, :string
    belongs_to :message, Sosh.Social.Message
    belongs_to :user, Sosh.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
