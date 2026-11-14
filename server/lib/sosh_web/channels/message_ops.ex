defmodule SoshWeb.MessageOps do
  @moduledoc """
  What can be done to a message from a chat's channel (`server:<id>`,
  `dm:<id>`), as `Sosh.Chat` allows it:

    * `edit` {id, body}: replies `%{message}`
    * `delete` {id}
    * `react` {id, emoji, on}: `on` false takes it off; replies `%{id, reactions}`
    * `pin` {id}: a sign of it into your bag; replies `%{id, pins, item}`
  """
  alias Sosh.Chat

  @events ~w(edit delete react pin)
  def events, do: @events

  def handle("edit", %{"id" => id, "body" => body}, me) when is_integer(id),
    do: reply(Chat.edit(me, id, body), &%{message: &1})

  def handle("delete", %{"id" => id}, me) when is_integer(id), do: reply(Chat.delete(me, id), fn _ -> %{} end)

  def handle("react", %{"id" => id, "emoji" => e} = p, me) when is_integer(id) and is_binary(e),
    do: reply(Chat.react(me, id, e, Map.get(p, "on", true) != false), & &1)

  def handle("pin", %{"id" => id}, me) when is_integer(id), do: reply(Chat.pin(me, id), & &1)

  def handle(_, _, _), do: {:error, %{reason: "bad_request"}}

  defp reply(:ok, f), do: {:ok, f.(nil)}
  defp reply({:ok, v}, f), do: {:ok, f.(v)}
  defp reply({:error, why}, _), do: {:error, %{reason: to_string(why)}}
end
