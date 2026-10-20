defmodule Sosh.UniverseRecord do
  @moduledoc """
  A universe of the grid: where it is, what lies below its islands, the
  seed they grow from and its saved state. See `Sosh.Universes`.
  """
  use Ecto.Schema

  @primary_key false
  schema "universes" do
    field :gx, :integer, primary_key: true
    field :gy, :integer, primary_key: true
    field :kind, :string, default: "sea"
    field :seed, :integer
    # Sosh.Universe.save/2's JSON: crops, furniture, ships, the world tick
    field :state, :binary

    timestamps(type: :utc_datetime)
  end
end
