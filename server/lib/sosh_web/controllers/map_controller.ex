defmodule SoshWeb.MapController do
  @moduledoc """
  `GET /map/<gx>,<gy>`: universe `{gx, gy}`'s map (`Sosh.Maps`), a PNG,
  public like the server list it's the banner of. Cached for a few
  minutes, with an ETag of when it was drawn.
  """
  use SoshWeb, :controller

  alias Sosh.Maps

  def show(conn, %{"at" => at}) do
    with [x, y] <- String.split(at, ","),
         {gx, ""} <- Integer.parse(x),
         {gy, ""} <- Integer.parse(y),
         {png, drawn} <- Maps.get({gx, gy}) do
      tag = ~s("#{DateTime.to_unix(drawn)}")

      conn =
        conn
        |> put_resp_header("etag", tag)
        |> put_resp_header("cache-control", "public, max-age=300")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("cross-origin-resource-policy", "cross-origin")
        |> put_resp_header("access-control-allow-origin", "*")

      if tag in get_req_header(conn, "if-none-match"),
        do: send_resp(conn, 304, ""),
        else: conn |> put_resp_content_type("image/png", nil) |> send_resp(200, png)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
