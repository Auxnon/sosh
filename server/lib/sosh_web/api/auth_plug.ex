defmodule SoshWeb.Api.AuthPlug do
  @moduledoc """
  Signs API requests in from `Authorization: Bearer <session token>`
  (`Sosh.Accounts.session_user/1`). With `required: true` (the default) a
  request without a good token gets a 401.
  """
  import Plug.Conn

  def init(opts), do: Keyword.get(opts, :required, true)

  def call(conn, required) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> t | _] -> String.trim(t)
        _ -> nil
      end

    case token && Sosh.Accounts.session_user(token) do
      %Sosh.Accounts.User{} = user ->
        conn |> assign(:user, user) |> assign(:token, token)

      _ when required ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"signed_out"}))
        |> halt()

      _ ->
        assign(conn, :user, nil)
    end
  end

  @doc "Who's asking, for rate limits: their address."
  def caller(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
