defmodule Sosh.Crop do
  @moduledoc "A planted crop, at the air cell above its soil. See `Sosh.Sim`."
  use Ecto.Schema

  @primary_key false
  schema "crops" do
    field :x, :integer, primary_key: true
    field :y, :integer, primary_key: true
    field :z, :integer, primary_key: true
    field :kind, :string, default: "carrot"
    # wall-clock milliseconds; the stage follows from it
    field :planted_ms, :integer

    timestamps(type: :utc_datetime)
  end
end
