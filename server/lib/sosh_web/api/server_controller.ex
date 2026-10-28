defmodule SoshWeb.Api.ServerController do
  @moduledoc "Servers and their members: see `Sosh.Servers`."
  use SoshWeb, :controller

  import SoshWeb.Api.Json
  alias Sosh.Servers

  def index(conn, _), do: ok(conn, %{servers: Servers.list(conn.assigns.user)})

  def members(conn, %{"id" => id}) do
    case Servers.get(id) do
      nil -> error(conn, :no_such_server)
      s -> ok(conn, %{members: Servers.members(s, conn.assigns.user.id)})
    end
  end

  def join(conn, %{"id" => id}),
    do: reply(conn, Servers.join(conn.assigns.user, id), &%{status: &1})

  def leave(conn, %{"id" => id}), do: reply(conn, Servers.leave(conn.assigns.user, id))

  def update(conn, %{"id" => id} = params) do
    attrs = Map.take(params, ["name", "description", "policy"])
    reply(conn, Servers.update(conn.assigns.user, id, attrs), &%{server: Servers.public(&1)})
  end

  def invite(conn, %{"id" => id, "handle" => h}),
    do: reply(conn, Servers.invite(conn.assigns.user, id, h))

  @actions ~w(approve reject kick ban unban)

  def member(conn, %{"id" => id, "handle" => h, "action" => a}) when a in @actions do
    me = conn.assigns.user

    result =
      case a do
        "approve" -> Servers.approve(me, id, h)
        "reject" -> Servers.reject(me, id, h)
        "kick" -> Servers.kick(me, id, h)
        "ban" -> Servers.ban(me, id, h)
        "unban" -> Servers.unban(me, id, h)
      end

    reply(conn, result)
  end

  def member(conn, %{"id" => id, "handle" => h, "action" => "role", "role" => role}),
    do: reply(conn, Servers.set_role(conn.assigns.user, id, h, role))

  def member(conn, _), do: error(conn, :no_such_action)
end
