defmodule Sosh.Chunk do
  @moduledoc "A saved 16x16x16 chunk of world blocks. See `Sosh.World`."
  use Ecto.Schema

  @primary_key false
  schema "chunks" do
    field :x, :integer, primary_key: true
    field :y, :integer, primary_key: true
    field :z, :integer, primary_key: true
    field :blocks, :binary

    timestamps(type: :utc_datetime)
  end
end
