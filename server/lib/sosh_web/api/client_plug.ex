defmodule SoshWeb.Api.ClientPlug do
  @moduledoc "Turns away apps too old for this server (`Sosh.Clients`): `426 update_required`."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Sosh.Clients.check(client(conn)) do
      :ok ->
        conn

      {:update, info} ->
        conn
        |> put_status(426)
        |> Phoenix.Controller.json(Map.put(info, :error, "update_required"))
        |> halt()
    end
  end

  def client(conn), do: conn |> get_req_header("x-sosh-client") |> List.first()
end
