defmodule Sosh.Social.Conversation do
  @moduledoc "Direct messages between two people, `a_id` < `b_id`. See `Sosh.Chat`."
  use Ecto.Schema

  schema "conversations" do
    belongs_to :a, Sosh.Accounts.User
    belongs_to :b, Sosh.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
