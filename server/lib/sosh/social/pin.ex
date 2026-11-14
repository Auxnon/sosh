defmodule Sosh.Social.Pin do
  @moduledoc """
  A server message someone pinned: the `sign:<id>` item in their bag, and
  the sign it becomes when placed. See `Sosh.Chat.pin/2` and `Sosh.Signs`.
  """
  use Ecto.Schema

  schema "pins" do
    belongs_to :message, Sosh.Social.Message
    belongs_to :user, Sosh.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
