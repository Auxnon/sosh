defmodule Sosh.Signs do
  @moduledoc """
  What placed signs say. A sign is furniture whose `sign` is a pin's id
  (`Sosh.Social.Pin`); clients get it dressed (`dress/1`) as
  `%{id, author, body, at, server}` (`author` a handle, `server` the
  server's name), or `%{id, removed: true}` once the message is gone.

  Furniture is broadcast often (lifted pieces move every tick), so what a
  pin says is kept in an ETS table, forgotten whenever any message is edited
  or deleted (`forget/0`).
  """
  use GenServer

  import Ecto.Query
  alias Sosh.Repo
  alias Sosh.Social.{Message, Pin}

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Furniture as the universe gives it, with a sign's text in place of its pin id."
  def dress(%{sign: id} = f) when is_integer(id), do: %{f | sign: text(id)}
  def dress(f), do: f

  @doc "What pin `id` says."
  def text(id) do
    case :ets.lookup(@table, id) do
      [{^id, t}] ->
        t

      [] ->
        t = load(id)
        :ets.insert(@table, {id, t})
        t
    end
  end

  def forget, do: :ets.delete_all_objects(@table)

  defp load(id) do
    q =
      from p in Pin,
        left_join: m in Message,
        on: m.id == p.message_id,
        left_join: a in assoc(m, :author),
        left_join: s in assoc(m, :server),
        where: p.id == ^id,
        select: {m.id, a.handle, m.body, m.inserted_at, s.name}

    case Repo.one(q) do
      {mid, author, body, at, server} when mid != nil ->
        %{id: id, author: author, body: body, at: at, server: server}

      _ ->
        %{id: id, removed: true}
    end
  end
end
