defmodule SoshWeb.AuthChannel do
  @moduledoc """
  `auth:lobby`: signing in from a client that has no token yet (the game
  on desktop and web). Anyone can join. Every request replies like the API
  (`SoshWeb.Api.AuthController`): `{:ok, %{token, user}}` once signed in,
  `{:ok, %{status: "confirm"}}` when a code was emailed, or `{:error,
  %{reason, errors}}`. With the token, reconnect the socket with
  `token=<token>`.

  Client -> server: `register` {email, handle, password}, `confirm`
  {email, code}, `resend` {email}, `login` {email, password}, `forgot`
  {email}, `reset` {email, code, password}, `whoami` (who this socket is
  signed in as, if anyone).
  """
  use Phoenix.Channel

  alias Sosh.{Accounts, Me}

  def join("auth:lobby", _params, socket), do: {:ok, socket}
  def join(_, _, _), do: {:error, %{reason: "no_such_topic"}}

  def handle_in("whoami", _, socket) do
    case socket.assigns[:account] do
      nil -> {:reply, {:ok, %{user: nil}}, socket}
      u ->
        reply = Me.session(u, socket.assigns.token) |> Map.put(:enter, socket.assigns[:enter]) |> Map.put(:app, socket.assigns[:app] == true)
        {:reply, {:ok, reply}, socket}
    end
  end

  def handle_in("register", p, socket) do
    attrs = Map.take(p, ["email", "handle", "password"])

    case Accounts.register(attrs, socket.assigns.caller) do
      {:ok, %{confirmed_at: nil}} -> {:reply, {:ok, %{status: "confirm"}}, socket}
      {:ok, user} -> signed_in(socket, user, Accounts.new_session(user))
      {:error, why} -> {:reply, {:error, error(why)}, socket}
    end
  end

  def handle_in("confirm", %{"email" => e, "code" => c}, socket),
    do: session(socket, Accounts.confirm(e, c))

  def handle_in("resend", %{"email" => e}, socket) do
    Accounts.resend_confirmation(e)
    {:reply, {:ok, %{}}, socket}
  end

  def handle_in("login", %{"email" => e, "password" => pw}, socket),
    do: session(socket, Accounts.login(e, pw, socket.assigns.caller))

  def handle_in("forgot", %{"email" => e}, socket) do
    Accounts.forgot_password(e)
    {:reply, {:ok, %{}}, socket}
  end

  def handle_in("reset", %{"email" => e, "code" => c, "password" => pw}, socket),
    do: session(socket, Accounts.reset_password(e, c, pw))

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  # (mail adapters in tests message the sending process)
  def handle_info(_, socket), do: {:noreply, socket}

  defp session(socket, {:ok, user, token}), do: signed_in(socket, user, token)
  defp session(socket, {:error, why}), do: {:reply, {:error, error(why)}, socket}

  defp signed_in(socket, user, token) do
    Me.signed_in(user)
    {:reply, {:ok, Me.session(user, token)}, socket}
  end

  @doc false
  def error(%Ecto.Changeset{} = cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    # one line a game can show: "handle has already been taken"
    first =
      case Enum.at(errors, 0) do
        {field, [msg | _]} -> "#{field} #{msg}"
        _ -> "invalid"
      end

    %{reason: "invalid", errors: errors, message: first}
  end

  def error(why), do: %{reason: to_string(why)}
end
