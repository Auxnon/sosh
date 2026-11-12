defmodule Sosh.Social.Medium do
  @moduledoc "A picture or a Petrichor64 cart shared in chat. See `Sosh.Media`."
  use Ecto.Schema

  schema "media" do
    field :key, :string
    field :kind, :string
    field :mime, :string
    field :animated, :boolean, default: false
    field :width, :integer
    field :height, :integer
    field :size, :integer
    field :name, :string
    field :data, :binary, load_in_query: false
    belongs_to :owner, Sosh.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
