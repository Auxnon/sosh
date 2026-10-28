defmodule SoshWeb.ServerChannel do
  @moduledoc """
  `server:<id>`: a server's chat, for its members (`:chat`). The join
  replies `%{server, messages}`, the latest messages.

  Server -> client: `message` (a new message, gifts sealed), `gift` (a
  gift opened or taken back), `deleted` `%{id}`, `members` (refetch them),
  and `removed` before the channel closes when you're no longer a member.

  Client -> server: `post` {body, gift?: {item, count, to}} replying
  `%{message}` as you see it; `history` {before} replying `%{messages}`.
  """
  use Phoenix.Channel

  alias Sosh.{Chat, Servers}

  intercept ["members"]

  def join("server:" <> id, _params, socket) do
    with %{} = me <- socket.assigns[:account] || {:error, :signed_out},
         {id, ""} <- Integer.parse(id),
         %{} = s <- Servers.get(id) || {:error, :no_such_server},
         true <- Servers.can?(s, me.id, :chat) || {:error, :forbidden} do
      {:ok, %{server: Servers.public(s), messages: Chat.history({:server, s.id}, me)},
       assign(socket, :server_id, s.id)}
    else
      {:error, why} -> {:error, %{reason: to_string(why)}}
      _ -> {:error, %{reason: "no_such_server"}}
    end
  end

  def handle_in("post", p, socket) do
    case Chat.post(socket.assigns.account, {:server, socket.assigns.server_id}, p) do
      {:ok, m} -> {:reply, {:ok, %{message: m}}, socket}
      {:error, why} -> {:reply, {:error, %{reason: to_string(why)}}, socket}
    end
  end

  def handle_in("history", p, socket) do
    before = if is_integer(p["before"]), do: p["before"]
    msgs = Chat.history({:server, socket.assigns.server_id}, socket.assigns.account, before)
    {:reply, {:ok, %{messages: msgs}}, socket}
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  # Membership changed: still allowed in?
  def handle_out("members", payload, socket) do
    s = Servers.get(socket.assigns.server_id)

    if s && Servers.can?(s, socket.assigns.account.id, :chat) do
      push(socket, "members", payload)
      {:noreply, socket}
    else
      push(socket, "removed", %{server_id: socket.assigns.server_id})
      {:stop, :normal, socket}
    end
  end
end
