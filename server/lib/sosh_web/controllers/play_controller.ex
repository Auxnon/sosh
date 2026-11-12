defmodule SoshWeb.PlayController do
  @moduledoc """
  A Petrichor64 cart shared in chat, running on its own: `/play/<key>`.

  The page is the web engine (the same files the game uses) pointed at the
  cart instead of the game (client/web/play.js swaps `/game.game.png` for
  `/media/<key>`), and fenced in so the cart can reach nothing of sosh's:

    * its Content-Security-Policy lets it fetch the engine, its synth and
      that one cart, and connect nowhere else: no `/socket`, no `/api`,
      no other site. The VM worker (`/play/worker.js`, the engine's own
      worker.js with the same fence) is held to it too.
    * play.js takes `WebSocket` away before the engine starts, so a
      cart's `conn` fails at once rather than at the policy.
    * sosh keeps no session in the browser (the game signs in each time,
      the app passes its token only to its own world view), so there's
      nothing on this origin to borrow.

  The game's page (client/web/bridge.js) shows it in a sandboxed frame
  over its chat; the Android app opens it in a web view of its own.
  """
  use SoshWeb, :controller

  alias Sosh.Media

  def show(conn, %{"key" => key}) do
    case Media.get(key) do
      %{kind: "cart"} = m ->
        host = conn.host

        conn
        |> fence(
          "connect-src #{host}:*/media/#{m.key} #{host}:*/Petrichor64_bg.wasm #{host}:*/petrichor_synth_bg.wasm"
        )
        |> put_resp_content_type("text/html")
        |> send_resp(200, page(m))

      _ ->
        send_resp(conn, 404, "no such game")
    end
  end

  def worker(conn, _params) do
    path = Application.app_dir(:sosh, "priv/static/worker.js")

    case File.read(path) do
      {:ok, js} ->
        conn
        |> fence("connect-src #{conn.host}:*/Petrichor64_bg.wasm")
        |> put_resp_content_type("text/javascript")
        |> send_resp(200, "self.WebSocket = undefined;\n" <> js)

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp fence(conn, connect) do
    csp =
      Enum.join(
        [
          "default-src 'none'",
          "script-src 'self' 'wasm-unsafe-eval'",
          "worker-src 'self'",
          connect,
          "style-src 'unsafe-inline'",
          "img-src 'self' data: blob:",
          "media-src 'self' data: blob:",
          "base-uri 'none'",
          "form-action 'none'",
          "frame-ancestors 'self'"
        ],
        "; "
      )

    conn
    |> put_resp_header("content-security-policy", csp)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-cache")
  end

  defp page(m) do
    name = Phoenix.HTML.html_escape(m.name || "a shared game") |> Phoenix.HTML.safe_to_string()

    """
    <!DOCTYPE html>
    <html lang="en" data-cart="/media/#{m.key}">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>#{name}</title>
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: #241E4E; overflow: hidden; }
          canvas { image-rendering: pixelated; }
          canvas:focus, canvas:focus-visible { outline: none; }
        </style>
        <script type="module" src="/play.js"></script>
      </head>
      <body></body>
    </html>
    """
  end
end
