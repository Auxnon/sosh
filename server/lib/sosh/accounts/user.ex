defmodule Sosh.Accounts.User do
  @moduledoc "An account. See `Sosh.Accounts`."
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :handle, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :character, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @handle ~r/^[A-Za-z0-9_]{3,16}$/
  @email ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :handle, :password])
    |> validate_required([:email, :handle, :password])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:handle, &String.trim/1)
    |> validate_format(:email, @email, message: "isn't an email address")
    |> validate_length(:email, max: 160)
    |> validate_format(:handle, @handle,
      message: "is 3-16 letters, digits or underscores"
    )
    |> validate_password()
    |> unique_constraint(:email, name: :users_email_index)
    |> unique_constraint(:handle, name: :users_handle_index)
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password()
  end

  defp validate_password(cs) do
    cs
    |> validate_length(:password, min: 10, max: 128)
    |> validate_change(:password, fn :password, pw ->
      if String.downcase(pw) in ["password12", "1234567890", "qwertyuiop", "letmein123"],
        do: [password: "is too common"],
        else: []
    end)
  end

  def character_changeset(user, character) do
    change(user, character: character)
  end

  @doc "What anyone can see of someone."
  def public(%__MODULE__{} = u), do: %{id: u.id, handle: u.handle, character: u.character}
end
