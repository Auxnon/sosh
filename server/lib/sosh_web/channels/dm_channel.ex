defmodule SoshWeb.DmChannel do
  @moduledoc """
  `dm:<conversation id>`: a direct conversation, for its two people (open
  one by handle with `user:<id>` `dm_open`). The join replies `%{with,
  messages}`. Events and requests as `SoshWeb.ServerChannel`: `message`,
  `gift`, `deleted`; `post`, `history`.
  """
  use Phoenix.Channel

  alias Sosh.{Accounts, Chat}
  alias Sosh.Accounts.User

  def join("dm:" <> id, _params, socket) do
    with %{} = me <- socket.assigns[:account] || {:error, :signed_out},
         {id, ""} <- Integer.parse(id),
         %{} = c <- Chat.get_conversation(id) || {:error, :no_such_conversation},
         true <- Chat.in_conversation?(c, me.id) || {:error, :forbidden} do
      other = Accounts.get_user(if c.a_id == me.id, do: c.b_id, else: c.a_id)

      {:ok, %{with: User.public(other), messages: Chat.dm_history(c.id, me)},
       assign(socket, :conversation_id, c.id)}
    else
      {:error, why} -> {:error, %{reason: to_string(why)}}
      _ -> {:error, %{reason: "no_such_conversation"}}
    end
  end

  def handle_in("post", p, socket) do
    case Chat.post(socket.assigns.account, {:dm, socket.assigns.conversation_id}, p) do
      {:ok, m} -> {:reply, {:ok, %{message: m}}, socket}
      {:error, why} -> {:reply, {:error, %{reason: to_string(why)}}, socket}
    end
  end

  def handle_in("history", p, socket) do
    before = if is_integer(p["before"]), do: p["before"]
    msgs = Chat.dm_history(socket.assigns.conversation_id, socket.assigns.account, before)
    {:reply, {:ok, %{messages: msgs}}, socket}
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "bad_request"}}, socket}
end
