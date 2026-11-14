defmodule SoshWeb.Api.ClientController do
  @moduledoc """
  `GET /api/client`: is this app new enough? `%{ok: true}`, or (through
  `SoshWeb.Api.ClientPlug`) `426 %{error: "update_required", min,
  download}`. Asked before signing in.
  """
  use SoshWeb, :controller

  def show(conn, _), do: json(conn, %{ok: true, download: Sosh.Clients.download()})
end
