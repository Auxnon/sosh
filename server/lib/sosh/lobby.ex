defmodule Sosh.Lobby do
  @moduledoc """
  Who is in the plaza right now, keyed by user id.

  The channel keeps this current so a newcomer can be sent everyone's position,
  face and pose on join instead of waiting for each player to move.
  """
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(user_id, player), do: Agent.update(__MODULE__, &Map.put(&1, user_id, player))

  @doc "Merge `changes` into a player's entry; a no-op if they've already left."
  def update(user_id, changes) do
    Agent.update(__MODULE__, fn players ->
      case players do
        %{^user_id => player} -> Map.put(players, user_id, Map.merge(player, changes))
        _ -> players
      end
    end)
  end

  def delete(user_id), do: Agent.update(__MODULE__, &Map.delete(&1, user_id))

  def list, do: Agent.get(__MODULE__, &Map.values/1)
end
