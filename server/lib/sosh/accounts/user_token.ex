defmodule Sosh.Accounts.UserToken do
  @moduledoc """
  A session token, or a code emailed to confirm an address or reset a
  password. Only a SHA-256 of it is stored, so a leaked table signs no one
  in. See `Sosh.Accounts`.
  """
  use Ecto.Schema

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :attempts, :integer, default: 0
    field :last_used_at, :utc_datetime
    belongs_to :user, Sosh.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def digest(token), do: :crypto.hash(:sha256, token)
end
