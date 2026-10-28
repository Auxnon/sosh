defmodule SoshWeb.UserChannel do
  @moduledoc """
  `user:<id>`: one signed-in account's own channel. The join replies with
  everything (`Sosh.Me.everything/1`).

  Server -> client (no payload unless given; refetch what changed):
    * `friends`, `servers` - lists changed
    * `dm` `%{conversation_id, from}` - a direct message
    * `gift` `%{message_id, from}` - items were sent to you
    * `bag` `%{bag}`, `character` `%{character}`
    * `removed` `%{server_id, universe}` - kicked or banned from a server

  Client -> server, replying `{:ok, ...}` or `{:error, %{reason}}`:
  `everything`, `character` {character}, `friend_add` / `friend_accept` /
  `friend_remove` {handle}, `join_server` / `leave_server` {id},
  `members` {id}, `member` {id, handle, action, role?} (approve, reject,
  kick, ban, unban, role), `invite` {id, handle}, `server_update` {id, name?,
  description?, policy?}, `dm_open` {handle} -> {conversation_id,
  messages}, `claim` / `cancel` / `delete` {id} (a message), `logout`.
  """
  use Phoenix.Channel

  alias Sosh.{Accounts, Chat, Friends, Me, Servers}
  alias SoshWeb.AuthChannel

  def join("user:" <> id, _params, socket) do
    case socket.assigns[:account] do
      %{id: mine} = u when is_binary(id) ->
        if to_string(mine) == id,
          do: {:ok, Me.everything(u), socket},
          else: {:error, %{reason: "forbidden"}}

      _ ->
        {:error, %{reason: "signed_out"}}
    end
  end

  def handle_in(event, payload, socket) do
    me = Accounts.get_user(socket.assigns.account.id)
    socket = assign(socket, :account, me)
    {:reply, answer(event, payload, me, socket), socket}
  end

  defp answer("everything", _, me, _), do: {:ok, Me.everything(me)}

  defp answer("character", %{"character" => c}, me, _),
    do: wrap(Me.set_character(me, c), &%{user: Me.user(&1)})

  defp answer("friend_add", %{"handle" => h}, me, _), do: wrap(Friends.request(me, h), &%{status: &1})
  defp answer("friend_accept", %{"handle" => h}, me, _), do: wrap(Friends.accept(me, h))
  defp answer("friend_remove", %{"handle" => h}, me, _), do: wrap(Friends.remove(me, h))
  defp answer("friends", _, me, _), do: {:ok, Friends.list(me)}

  defp answer("servers", _, me, _), do: {:ok, %{servers: Servers.list(me)}}
  defp answer("join_server", %{"id" => id}, me, _), do: wrap(Servers.join(me, id), &%{status: &1})
  defp answer("leave_server", %{"id" => id}, me, _), do: wrap(Servers.leave(me, id))

  defp answer("members", %{"id" => id}, me, _) do
    case Servers.get(id) do
      nil -> {:error, %{reason: "no_such_server"}}
      s -> {:ok, %{members: Servers.members(s, me.id)}}
    end
  end

  defp answer("member", %{"id" => id, "handle" => h, "action" => a} = p, me, _) do
    wrap(
      case a do
        "approve" -> Servers.approve(me, id, h)
        "reject" -> Servers.reject(me, id, h)
        "kick" -> Servers.kick(me, id, h)
        "ban" -> Servers.ban(me, id, h)
        "unban" -> Servers.unban(me, id, h)
        "role" -> Servers.set_role(me, id, h, p["role"])
        _ -> {:error, :no_such_action}
      end
    )
  end

  defp answer("invite", %{"id" => id, "handle" => h}, me, _), do: wrap(Servers.invite(me, id, h))

  defp answer("server_update", %{"id" => id} = p, me, _),
    do: wrap(Servers.update(me, id, Map.take(p, ["name", "description", "policy"])), &%{server: Servers.public(&1)})

  defp answer("dm_open", %{"handle" => h}, me, _) do
    case SoshWeb.Api.ChatController.conversation(me, h) do
      {:ok, c} -> {:ok, %{conversation_id: c.id, messages: Chat.dm_history(c.id, me)}}
      {:error, why} -> {:error, %{reason: to_string(why)}}
    end
  end

  defp answer("conversations", _, me, _), do: {:ok, %{conversations: Chat.conversations(me)}}
  defp answer("claim", %{"id" => id}, me, _), do: wrap(Chat.claim(me, id), &%{message: &1})
  defp answer("cancel", %{"id" => id}, me, _), do: wrap(Chat.cancel(me, id), &%{message: &1})
  defp answer("delete", %{"id" => id}, me, _), do: wrap(Chat.delete(me, id))

  defp answer("logout", _, _, socket) do
    Accounts.logout(socket.assigns.token)
    {:ok, %{}}
  end

  defp answer(_, _, _, _), do: {:error, %{reason: "bad_request"}}

  defp wrap(result, fun \\ fn _ -> %{} end)
  defp wrap(:ok, fun), do: {:ok, fun.(nil)}
  defp wrap({:ok, x}, fun), do: {:ok, fun.(x)}
  defp wrap({:error, why}, _), do: {:error, AuthChannel.error(why)}
end
