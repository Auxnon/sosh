defmodule SoshWeb.Api.ChatController do
  @moduledoc """
  Chat history and posting: a server's chat, and conversations by the
  other person's handle. Live messages come over the socket
  (`server:<id>`, `dm:<id>`). See `Sosh.Chat`.
  """
  use SoshWeb, :controller

  import SoshWeb.Api.Json
  alias Sosh.{Accounts, Chat, Servers}

  def server_index(conn, %{"id" => id} = params) do
    me = conn.assigns.user

    case Servers.get(id) do
      nil ->
        error(conn, :no_such_server)

      s ->
        if Servers.can?(s, me.id, :chat),
          do: ok(conn, %{messages: Chat.history({:server, s.id}, me, before(params))}),
          else: error(conn, :forbidden)
    end
  end

  def server_create(conn, %{"id" => id} = params) do
    {id, _} = Integer.parse(to_string(id))
    reply(conn, Chat.post(conn.assigns.user, {:server, id}, params), &%{message: &1})
  end

  def dms(conn, _), do: ok(conn, %{conversations: Chat.conversations(conn.assigns.user)})

  def dm_index(conn, %{"handle" => h} = params) do
    with {:ok, c} <- conversation(conn.assigns.user, h) do
      ok(conn, %{conversation_id: c.id, messages: Chat.dm_history(c.id, conn.assigns.user, before(params))})
    else
      {:error, why} -> error(conn, why)
    end
  end

  def dm_create(conn, %{"handle" => h} = params) do
    with {:ok, c} <- conversation(conn.assigns.user, h) do
      reply(conn, Chat.post(conn.assigns.user, {:dm, c.id}, params), &%{message: &1})
    else
      {:error, why} -> error(conn, why)
    end
  end

  def claim(conn, %{"id" => id}),
    do: reply(conn, Chat.claim(conn.assigns.user, to_int(id)), &%{message: &1})

  def cancel(conn, %{"id" => id}),
    do: reply(conn, Chat.cancel(conn.assigns.user, to_int(id)), &%{message: &1})

  def delete(conn, %{"id" => id}), do: reply(conn, Chat.delete(conn.assigns.user, to_int(id)))

  @doc false
  def conversation(me, handle) do
    case Accounts.get_by_handle(handle) do
      nil -> {:error, :no_such_user}
      them -> if Chat.may_dm?(me, them), do: {:ok, Chat.conversation(me, them)}, else: {:error, :forbidden}
    end
  end

  defp before(%{"before" => b}), do: to_int(b)
  defp before(_), do: nil

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> 0
    end
  end
end
