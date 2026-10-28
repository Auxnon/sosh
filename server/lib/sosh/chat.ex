defmodule Sosh.Chat do
  @moduledoc """
  Chat: each server has one chat, and any two people who are friends or
  share a server can talk directly (a conversation). Messages are kept in
  Postgres and go out live on `server:<id>` and `dm:<conversation id>`
  (`message`, and `gift` when a gift is opened or taken back).

  A message can carry items for one person, the `@` it mentions
  (`post/3` with a `gift`): they leave the author's bag when it's sent
  (`Sosh.Universe.bag_take/3`, all or nothing), everyone in the chat sees a
  wrapped gift for that person, and only they can open it (`claim/2`), which
  puts the items in their bag (`bag_give/3`, all or nothing: no room, no
  opening). Until then the author can take it back (`cancel/2`).

  A server message from someone standing in that universe also shows as a
  speech bubble over them (`room:gx,gy` `new_msg`).

  Messages as clients see them (`view/2`): `%{id, server_id,
  conversation_id, author, body, at, gift}`, `author` public, `gift` nil or
  `%{to, state, item, count}` with state `"sealed"`, `"opened"` or
  `"returned"`; `item` and `count` are only there for the author, and for
  the recipient once it's opened.
  """
  import Ecto.Query

  alias Sosh.{Accounts, Friends, Lobby, Players, RateLimit, Repo, Servers, Universe}
  alias Sosh.Accounts.User
  alias Sosh.Social.{Conversation, Membership, Message, Server}

  @max_body 2000
  @page 50
  @max_count 999

  # -- where

  @doc "The conversation between two people, made on first use."
  def conversation(%User{id: a}, %User{id: b}) when a != b do
    {a, b} = if a < b, do: {a, b}, else: {b, a}

    Repo.insert!(%Conversation{a_id: a, b_id: b},
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:a_id, :b_id],
      returning: true
    )
  end

  def get_conversation(id), do: Repo.get(Conversation, id)

  def in_conversation?(%Conversation{a_id: a, b_id: b}, user_id), do: user_id in [a, b]

  @doc "May these two talk directly? Friends, or members of a server in common."
  def may_dm?(%User{id: a}, %User{id: b}) when a == b, do: false

  def may_dm?(%User{id: a}, %User{id: b}) do
    Friends.friends?(a, b) or
      Repo.exists?(
        from m1 in Membership,
          join: m2 in Membership,
          on: m1.server_id == m2.server_id,
          where:
            m1.user_id == ^a and m2.user_id == ^b and m1.status == "member" and
              m2.status == "member"
      )
  end

  @doc "Someone's conversations, latest first: `[%{id, with, last}]`."
  def conversations(%User{id: me} = user) do
    Repo.all(
      from c in Conversation,
        where: c.a_id == ^me or c.b_id == ^me,
        order_by: [desc: c.updated_at],
        preload: [:a, :b]
    )
    |> Enum.map(fn c ->
      other = if c.a_id == me, do: c.b, else: c.a

      last =
        Repo.one(
          from m in Message,
            where: m.conversation_id == ^c.id,
            order_by: [desc: m.id],
            limit: 1,
            preload: [:author, :recipient]
        )

      %{id: c.id, with: User.public(other), last: last && view(last, user)}
    end)
  end

  # -- reading

  @doc "The latest messages before message id `before` (nil: the newest), oldest first."
  def history({:server, server_id}, viewer, before \\ nil),
    do: page(from(m in Message, where: m.server_id == ^server_id), viewer, before)

  def dm_history(conversation_id, viewer, before \\ nil),
    do: page(from(m in Message, where: m.conversation_id == ^conversation_id), viewer, before)

  defp page(q, viewer, before) do
    q = if is_integer(before), do: from(m in q, where: m.id < ^before), else: q

    from(m in q, order_by: [desc: m.id], limit: @page, preload: [:author, :recipient])
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&view(&1, viewer))
  end

  @doc "A message as `viewer` sees it."
  def view(%Message{} = m, viewer) do
    viewer_id = viewer && viewer.id

    %{
      id: m.id,
      server_id: m.server_id,
      conversation_id: m.conversation_id,
      author: m.author && User.public(m.author),
      body: m.body,
      at: m.inserted_at,
      gift: gift_view(m, viewer_id)
    }
  end

  defp gift_view(%Message{item: nil}, _), do: nil

  defp gift_view(%Message{} = m, viewer_id) do
    state =
      cond do
        m.claimed_at -> "opened"
        m.cancelled_at -> "returned"
        true -> "sealed"
      end

    sees = viewer_id == m.author_id or (viewer_id == m.recipient_id and state == "opened")

    %{to: m.recipient && User.public(m.recipient), state: state}
    |> then(fn g -> if sees, do: Map.merge(g, %{item: m.item, count: m.count}), else: g end)
  end

  # -- writing

  @doc """
  Post to a server's chat (`{:server, id}`) or a conversation (`{:dm, id}`).
  `attrs`: `body`, and optionally `gift: %{item, count, to}` (`to` a handle).
  `{:ok, view}` as the author sees it, or `{:error, reason}`.
  """
  def post(%User{} = me, where, attrs) do
    body = attrs |> fetch("body") |> to_string() |> String.trim() |> String.slice(0, @max_body)
    gift = fetch(attrs, "gift")

    with :ok <- RateLimit.hit({:chat, me.id}, 20, 10_000),
         {:ok, place} <- may_post(me, where),
         {:ok, gift} <- check_gift(me, place, gift),
         :ok <- if(body == "" and gift == nil, do: {:error, :empty}, else: :ok) do
      result =
        case gift do
          nil ->
            {:ok, insert(me, place, body, nil)}

          {to, item, count} ->
            # the items leave the bag first: if they can't, nothing is sent
            case Players.update_bag(me.handle, &Universe.bag_take(&1, item, count)) do
              {:ok, bag} ->
                bag_changed(me, bag)
                {:ok, insert(me, place, body, {to, item, count})}

              {:error, why} ->
                {:error, String.to_atom(why)}
            end
        end

      with {:ok, m} <- result do
        announce(place, "message", view(%{m | author: me}, nil))
        if match?({:server, _}, place) and body != "", do: bubble(place, me, body)
        {:ok, view(%{m | author: me}, me)}
      end
    end
  end

  defp fetch(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp may_post(me, {:server, id}) do
    case Servers.get(id) do
      nil ->
        {:error, :no_such_server}

      s ->
        if Servers.can?(s, me.id, :chat), do: {:ok, {:server, s}}, else: {:error, :forbidden}
    end
  end

  defp may_post(me, {:dm, id}) do
    with %Conversation{} = c <- get_conversation(id) || {:error, :no_such_conversation},
         true <- in_conversation?(c, me.id) || {:error, :forbidden} do
      other = Accounts.get_user(if c.a_id == me.id, do: c.b_id, else: c.a_id)
      if may_dm?(me, other), do: {:ok, {:dm, c}}, else: {:error, :forbidden}
    end
  end

  defp may_post(_, _), do: {:error, :bad_place}

  defp check_gift(_, _, nil), do: {:ok, nil}

  defp check_gift(me, place, g) when is_map(g) do
    item = fetch(g, "item")
    count = fetch(g, "count") || 1
    to = fetch(g, "to")

    with true <- (is_binary(item) and is_integer(count) and count in 1..@max_count) || {:error, :bad_gift},
         %User{} = them <- Accounts.get_by_handle(to) || {:error, :no_such_user},
         true <- them.id != me.id || {:error, :yourself},
         :ok <- may_receive(place, me, them) do
      {:ok, {them, item, count}}
    end
  end

  defp check_gift(_, _, _), do: {:error, :bad_gift}

  defp may_receive({:server, s}, me, them) do
    cond do
      not Servers.can?(s, me.id, :send_items) -> {:error, :forbidden}
      Servers.role(s, them.id) == nil -> {:error, :not_a_member}
      true -> :ok
    end
  end

  defp may_receive({:dm, c}, _me, them),
    do: if(in_conversation?(c, them.id), do: :ok, else: {:error, :not_in_conversation})

  defp insert(me, place, body, gift) do
    {server_id, conversation_id} =
      case place do
        {:server, s} -> {s.id, nil}
        {:dm, c} -> {nil, c.id}
      end

    {recipient, item, count} = gift || {nil, nil, nil}

    m =
      Repo.insert!(%Message{
        server_id: server_id,
        conversation_id: conversation_id,
        author_id: me.id,
        body: body,
        item: item,
        count: count,
        recipient_id: recipient && recipient.id
      })

    if conversation_id do
      from(c in Conversation, where: c.id == ^conversation_id)
      |> Repo.update_all(set: [updated_at: DateTime.utc_now(:second)])

      c = elem(place, 1)
      for id <- [c.a_id, c.b_id], id != me.id do
        SoshWeb.Endpoint.broadcast("user:#{id}", "dm", %{
          conversation_id: c.id,
          from: User.public(me),
          message: view(%{m | author: me, recipient: recipient}, nil)
        })
      end
    end

    if recipient do
      SoshWeb.Endpoint.broadcast("user:#{recipient.id}", "gift", %{message_id: m.id, from: User.public(me)})
    end

    %{m | recipient: recipient}
  end

  @doc """
  Open a gift sent to you: its items go in your bag. `{:ok, view}` or
  `{:error, :not_yours | :already | :no_room}`.
  """
  def claim(%User{} = me, message_id), do: settle(me, message_id, :claim)

  @doc "Take back a gift you sent that hasn't been opened."
  def cancel(%User{} = me, message_id), do: settle(me, message_id, :cancel)

  # Mark it opened (or returned) only if it's still sealed and theirs to
  # settle, in one conditional update so two can't both win; then the
  # items go in their bag, and if they don't fit it's sealed again.
  defp settle(me, message_id, how) do
    {owner_field, field} =
      if how == :claim, do: {:recipient_id, :claimed_at}, else: {:author_id, :cancelled_at}

    sealed =
      from m in Message,
        where:
          m.id == ^message_id and field(m, ^owner_field) == ^me.id and not is_nil(m.item) and
            is_nil(m.claimed_at) and is_nil(m.cancelled_at)

    case Repo.update_all(sealed, set: [{field, DateTime.utc_now(:second)}]) do
      {1, _} ->
        m = Repo.get!(Message, message_id)

        case Players.update_bag(me.handle, &Universe.bag_give(&1, m.item, m.count)) do
          {:ok, bag} ->
            bag_changed(me, bag)
            m = Repo.preload(m, [:author, :recipient])
            announce(place_of(m), "gift", view(m, nil))
            {:ok, view(m, me)}

          {:error, why} ->
            Repo.update_all(from(x in Message, where: x.id == ^m.id), set: [{field, nil}])
            {:error, String.to_atom(why)}
        end

      {0, _} ->
        case Repo.get(Message, message_id) do
          %Message{item: item} = m when item != nil ->
            cond do
              Map.fetch!(m, owner_field) != me.id -> {:error, :not_yours}
              true -> {:error, :already}
            end

          _ ->
            {:error, :no_such_gift}
        end
    end
  end

  @doc "Remove a message: its author, or a server's moderators. A sealed gift goes back first."
  def delete(%User{} = me, message_id) do
    with %Message{} = m <- Repo.get(Message, message_id) || {:error, :no_such_message},
         true <- may_delete?(me, m) || {:error, :forbidden} do
      if m.item && is_nil(m.claimed_at) && is_nil(m.cancelled_at) do
        author = Accounts.get_user(m.author_id)
        if author, do: Players.update_bag(author.handle, &Universe.bag_give(&1, m.item, m.count))
      end

      Repo.delete!(m)
      announce(place_of(m), "deleted", %{id: m.id})
      :ok
    end
  end

  defp may_delete?(me, m) do
    m.author_id == me.id or
      case m.server_id && Servers.get(m.server_id) do
        nil -> false
        s -> Servers.can?(s, me.id, :manage_messages)
      end
  end

  defp place_of(%Message{server_id: nil, conversation_id: c}), do: {:dm, %Conversation{id: c}}
  defp place_of(%Message{server_id: s}), do: {:server, %Server{id: s}}

  defp announce({:server, s}, event, payload),
    do: SoshWeb.Endpoint.broadcast("server:#{s.id}", event, payload)

  defp announce({:dm, c}, event, payload),
    do: SoshWeb.Endpoint.broadcast("dm:#{c.id}", event, payload)

  defp bag_changed(me, bag),
    do: SoshWeb.Endpoint.broadcast("user:#{me.id}", "bag", %{bag: Players.bag_json(bag)})

  # Over the author's head too, if they're standing in that universe.
  defp bubble({:server, %Server{gx: gx, gy: gy}}, me, body) do
    u = {gx, gy}

    for %{name: name, user_id: id} <- Lobby.list(u), name == me.handle do
      SoshWeb.Endpoint.broadcast("room:#{gx},#{gy}", "new_msg", %{
        body: body,
        user_id: id,
        name: name
      })
    end

    :ok
  end
end
