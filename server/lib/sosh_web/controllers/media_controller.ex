defmodule SoshWeb.MediaController do
  @moduledoc """
  Pictures and carts shared in chat (`Sosh.Media`).

  `POST /api/media` (signed in): the file itself as the request body
  (any content type; what it is comes from the bytes), the file's name in
  `?name=` if you like. Answers `%{media}`, whose `key` goes in a message's
  `media` when posting.

  `POST /api/media/shared?ticket=<t>` (no session: a ticket from
  `Sosh.Media.ticket/2`): the same, then posted as a message to the
  ticket's chat. Answers `%{message}`. For the web page around the game.

  `GET /media/<key>`: the file, cached forever (a key never changes what it
  points at). Served as the type its bytes say it is, never sniffed into
  anything else, and as a sandboxed document should a browser open it as
  one, so nothing in it can run as this site.
  """
  use SoshWeb, :controller

  import SoshWeb.Api.Json
  alias Sosh.Media

  def create(conn, params) do
    case read_all(conn, Media.max_size()) do
      {:ok, bytes, conn} ->
        reply(conn, Media.store(conn.assigns.user, bytes, params["name"]), &%{media: Media.view(&1)})

      {:error, why, conn} ->
        error(conn, why)
    end
  end

  def shared(conn, params) do
    with {:ok, user, place} <- Media.redeem(params["ticket"]),
         {:ok, bytes, conn} <- read_all(conn, Media.max_size()),
         {:ok, m} <- Media.store(user, bytes, params["name"]),
         {:ok, msg} <- Sosh.Chat.post(user, place, %{"body" => "", "media" => m.key}) do
      ok(conn, %{message: msg})
    else
      {:error, why, conn} -> error(conn, why)
      {:error, why} -> error(conn, why)
    end
  end

  defp read_all(conn, max, acc \\ []) do
    case Plug.Conn.read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} -> done([acc, chunk], max, conn)
      {:more, chunk, conn} -> more([acc, chunk], max, conn)
      {:error, _} -> {:error, :bad_media, conn}
    end
  end

  defp done(acc, max, conn) do
    if IO.iodata_length(acc) > max,
      do: {:error, :too_big, conn},
      else: {:ok, IO.iodata_to_binary(acc), conn}
  end

  defp more(acc, max, conn) do
    if IO.iodata_length(acc) > max, do: {:error, :too_big, conn}, else: read_all(conn, max, acc)
  end

  def show(conn, %{"key" => key}) do
    case Media.fetch(key) do
      {mime, data} ->
        conn
        |> put_resp_content_type(mime, nil)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> put_resp_header("cross-origin-resource-policy", "cross-origin")
        |> put_resp_header("access-control-allow-origin", "*")
        |> send_resp(200, data)

      nil ->
        send_resp(conn, 404, "")
    end
  end
end
