defmodule Sosh.Repo do
  use Ecto.Repo,
    otp_app: :sosh,
    adapter: Ecto.Adapters.Postgres
end
