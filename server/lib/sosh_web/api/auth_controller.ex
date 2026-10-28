defmodule SoshWeb.Api.AuthController do
  @moduledoc """
  Sign up, confirm, sign in, reset: see `Sosh.Accounts`. Each that signs
  someone in answers `%{token, user}`; send the token as `Authorization:
  Bearer <token>` (API) or the socket's `token` param.
  """
  use SoshWeb, :controller

  import SoshWeb.Api.Json
  alias Sosh.{Accounts, Me}
  alias SoshWeb.Api.AuthPlug

  def register(conn, params) do
    attrs = Map.take(params, ["email", "handle", "password"])

    case Accounts.register(attrs, AuthPlug.caller(conn)) do
      {:ok, %{confirmed_at: nil}} ->
        conn |> put_status(201) |> ok(%{status: "confirm"})

      {:ok, user} ->
        Me.signed_in(user)
        conn |> put_status(201) |> ok(Me.session(user, Accounts.new_session(user)))

      {:error, why} ->
        error(conn, why)
    end
  end

  def confirm(conn, %{"email" => email, "code" => code}) do
    case Accounts.confirm(email, code) do
      {:ok, user, token} -> signed_in(conn, user, token)
      {:error, why} -> error(conn, why)
    end
  end

  def resend(conn, %{"email" => email}) do
    Accounts.resend_confirmation(email)
    ok(conn)
  end

  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.login(email, password, AuthPlug.caller(conn)) do
      {:ok, user, token} -> signed_in(conn, user, token)
      {:error, why} -> error(conn, why)
    end
  end

  def forgot(conn, %{"email" => email}) do
    Accounts.forgot_password(email)
    ok(conn)
  end

  def reset(conn, %{"email" => email, "code" => code, "password" => password}) do
    case Accounts.reset_password(email, code, password) do
      {:ok, user, token} -> signed_in(conn, user, token)
      {:error, why} -> error(conn, why)
    end
  end

  def password(conn, %{"current" => current, "password" => new}) do
    reply(conn, Accounts.change_password(conn.assigns.user, current, new, conn.assigns.token))
  end

  def logout(conn, _) do
    Accounts.logout(conn.assigns[:token])
    ok(conn)
  end

  defp signed_in(conn, user, token) do
    Me.signed_in(user)
    ok(conn, Me.session(user, token))
  end
end
