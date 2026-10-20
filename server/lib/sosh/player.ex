defmodule Sosh.Player do
  @moduledoc "A player, by name: their bag and where they were. See `Sosh.Players`."
  use Ecto.Schema

  @primary_key {:name, :string, autogenerate: false}
  schema "players" do
    field :gx, :integer, default: 0
    field :gy, :integer, default: 0
    # feet, in their universe; nil puts them on its home island
    field :at, {:array, :float}
    # %{"slots" => [[item, count] | []]}
    field :bag, :map, default: %{}

    timestamps(type: :utc_datetime)
  end
end
