defmodule Sosh.Chunk do
  @moduledoc "A saved 16x16x16 chunk of a universe's blocks. See `Sosh.World`."
  use Ecto.Schema

  @primary_key false
  schema "chunks" do
    field :gx, :integer, primary_key: true
    field :gy, :integer, primary_key: true
    field :x, :integer, primary_key: true
    field :y, :integer, primary_key: true
    field :z, :integer, primary_key: true
    field :blocks, :binary

    timestamps(type: :utc_datetime)
  end
end
