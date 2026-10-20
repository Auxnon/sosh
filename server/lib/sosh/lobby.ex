defmodule Sosh.Lobby do
  @moduledoc """
  Who is where right now, keyed by user id: each entry names the universe
  (`{gx, gy}`) the player is in.

  The channel keeps this current so a newcomer can be sent everyone's position,
  face and pose on join instead of waiting for each player to move.

  A player's motion is where they last reported standing (`at`), their
  velocity (`v`, tiles a second), an optional destination (`to`) and when the
  report arrived (`t`, monotonic ms). `position/2` predicts where they are
  now from that.

  Someone standing on an airship is `on` it (its id; 0 is nobody's ship)
  and reports where on it (`local`, the ship's frame), their `v` and `to`
  in that frame too; `at` is only where in the world they were when they
  said so. `frame/2` predicts where they are in whichever frame they're in.
  """
  use Agent

  # Clients restate their motion at least once a second while moving;
  # beyond this, stop predicting rather than walk them through walls.
  @horizon_ms 1_500

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

  @doc "Everyone in universe `u`."
  def list(u), do: Agent.get(__MODULE__, fn ps -> for {_, %{universe: ^u} = p} <- ps, do: p end)

  def get(user_id), do: Agent.get(__MODULE__, &Map.get(&1, user_id))

  def now, do: System.monotonic_time(:millisecond)

  @doc """
  Where `player` should be at `now`: `at` carried along `v`, stopping at `to`
  if there is one, and for at most #{@horizon_ms}ms.
  """
  def position(%{at: at} = player, now) do
    if aboard(player) != 0, do: at, else: predict(player, at, now)
  end

  @doc """
  `{on, [x, y, z]}`: the ship `player` stands on (0 for none) and where on it
  they should be at `now`, or where in the world.
  """
  def frame(player, now) do
    case aboard(player) do
      0 -> {0, position(player, now)}
      ship -> {ship, predict(player, player.local, now)}
    end
  end

  defp aboard(player) do
    case Map.get(player, :on) do
      on when is_integer(on) and on > 0 -> if Map.get(player, :local), do: on, else: 0
      _ -> 0
    end
  end

  defp predict(player, at, now) do
    case Map.get(player, :v) do
      [vx, vy] when vx != 0 or vy != 0 -> predict(player, at, vx, vy, now)
      _ -> at
    end
  end

  defp predict(player, [x, y, z], vx, vy, now) do
    dt = (now - Map.get(player, :t, now)) |> max(0) |> min(@horizon_ms) |> Kernel./(1000)
    {nx, ny} = {x + vx * dt, y + vy * dt}

    case Map.get(player, :to) do
      [tx, ty] ->
        travelled = :math.sqrt(vx * vx + vy * vy) * dt
        left = :math.sqrt((tx - x) * (tx - x) + (ty - y) * (ty - y))
        if travelled >= left, do: [tx, ty, z], else: [nx, ny, z]

      _ ->
        [nx, ny, z]
    end
  end
end
