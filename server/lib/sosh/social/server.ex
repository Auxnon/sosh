defmodule Sosh.Social.Server do
  @moduledoc "A server: a universe of the grid, with members. See `Sosh.Servers`."
  use Ecto.Schema
  import Ecto.Changeset

  @policies ~w(open friends approval)

  schema "servers" do
    field :name, :string
    field :gx, :integer
    field :gy, :integer
    field :policy, :string, default: "approval"
    field :description, :string, default: ""
    belongs_to :owner, Sosh.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def policies, do: @policies

  def changeset(server, attrs) do
    server
    |> cast(attrs, [:name, :policy, :description])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :policy])
    |> validate_length(:name, min: 2, max: 32)
    |> validate_length(:description, max: 200)
    |> validate_inclusion(:policy, @policies)
  end
end
