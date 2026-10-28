defmodule Sosh.Sim do
  @moduledoc """
  Runs one universe of the grid (`Sosh.Universes`) in a `Sosh.Universe`
  (Rust): its blocks, crops, cows, furniture and blueprints, airships,
  helpers and what everyone holds. One process per universe, registered
  under `{gx, gy}`; every call names the universe.

  **Awake and asleep.** While anyone is in the universe it ticks every
  `tick_ms` with the players' positions as `Sosh.Lobby` predicts them, and
  broadcasts what changed on `actions:gx,gy`. Once it has been empty for
  `sleep_after_ms` it saves and sleeps: only ambient systems run, every
  `idle_ms` (empty ships fly home, helpers and cows go home). Growth doesn't
  run at all while asleep; the first tick after waking catches up on every
  world tick slept through.

  **Frames.** Cells are in the world or on an airship: `on` is 0 for the
  world, else the ship's id, and the cell is in that ship's own frame (it
  turns and flies with it). Players on a ship report where on it they
  stand (`Sosh.Lobby.frame/2`).

  Broadcasts:

    * `cows`, `helpers` `%{rows: [[id, x, y, z, heading]]}` - what moved
    * `ships` `%{rows: [[id, x, y, z, heading, vx, vy, vz, spin]]}` - ships
      that moved, and how fast they're going (spin: radians a second)
    * `ship` - a ship arrived or changed pilots: `%{id, x, y, z, heading, v,
      pilot, blocks: [[x, y, z, block]]}`, blocks in its frame
    * `ship_block` `%{ship, position, block}` - a block of a ship's changed
    * `moo` `%{ids: [id]}` - cows that were just shoved or lifted
    * `crop` `%{position, stage}` - a crop grew (3 is ripe; nil: gone)
    * `block_changed` `%{position, block, block_type}`
    * `carry` `%{user_id, block, cow, furniture}` - what someone holds now
    * `furniture` - a piece changed: `%{id, kind, on, origin, rot, lifted,
      carriers, helpers, slots}`; `furniture_gone` `%{id}`
    * `site` - a blueprint changed: `%{id, kind, on, origin, rot, have,
      need}`; `site_gone` `%{id}`
    * `travel` `%{ship, users, to: [gx, gy]}` - a ship flew into the
      neighbouring universe with them aboard: it's gone from here (with
      everything on it), and they're in that one now

  Bags belong to `Sosh.Players`; calls that change one take the player's
  name, save the new bag and reply with it as JSON wants it.

  What the universe keeps (`Sosh.Universe.save/2`, plus its changed chunks
  through `Sosh.World`) is saved on going to sleep, every `save_ms` while
  awake and on shutdown. Cows aren't kept: they respawn on every start.
  """
  use GenServer
  require Logger

  import Ecto.Query, only: [from: 2]

  alias Sosh.{Crop, Lobby, Players, Repo, Universe, UniverseRecord, Universes, World}

  @ripe 3

  def ripe, do: @ripe

  def child_spec(u), do: %{id: {__MODULE__, u}, start: {__MODULE__, :start_link, [u]}}

  def start_link(u), do: GenServer.start_link(__MODULE__, u, name: via(u))

  defp via(u), do: {:via, Registry, {Sosh.Sims, u}}

  defp call(u, msg), do: GenServer.call(via(u), msg)

  @doc "Start universe `u`'s process if it isn't running. `{:ok, pid}`."
  def ensure(u) do
    case Registry.lookup(Sosh.Sims, u) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        if Universes.exists?(u) do
          case DynamicSupervisor.start_child(Sosh.SimSup, {__MODULE__, u}) do
            {:error, {:already_started, pid}} -> {:ok, pid}
            other -> other
          end
        else
          {:error, :no_such_universe}
        end
    end
  end

  def running?(u), do: Registry.lookup(Sosh.Sims, u) != []

  @doc "Stop every universe. For tests."
  def stop_all do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Sosh.SimSup),
        do: DynamicSupervisor.terminate_child(Sosh.SimSup, pid)

    # the registry forgets them a moment after they exit
    unregistered(100)
  end

  defp unregistered(0), do: :ok

  defp unregistered(n) do
    if Registry.count(Sosh.Sims) > 0 do
      Process.sleep(5)
      unregistered(n - 1)
    else
      :ok
    end
  end

  @doc "The grid changed around `u`: recheck which sides are open."
  def reopen(u), do: if(running?(u), do: GenServer.cast(via(u), :reopen), else: :ok)

  @doc """
  Everything a newcomer needs: cows, crops, who holds what, furniture,
  blueprints, ships, helpers, which sides are open, and what lies below.
  """
  def snapshot(u), do: call(u, :snapshot)

  @doc """
  Where `user` stands on arriving: aboard the ship they flew in on, at `at`
  if that's ground, or home. `{{x, y, z}, nil | {ship, {x, y, z}}}`: world
  feet, and the ship and where on it if they're aboard.
  """
  def spawn(u, user, at), do: call(u, {:spawn, user, at})

  @doc "`user`'s feet in the world, where `Sosh.Lobby` predicts them. `{:ok, {x, y, z}}`."
  def feet(u, user), do: call(u, {:feet, user})

  @doc "Is cell `pos` of frame `on` within `reach` of `user`? `:ok` or `{:error, reason}`."
  def reach(u, user, on, pos, reach), do: call(u, {:reach, user, on, pos, reach})

  @doc "Chunks run-length encoded, as `%{key, rle}`; keys outside the universe are skipped."
  def chunks(u, keys), do: call(u, {:chunks, keys})

  def block(u, pos), do: block(u, 0, pos)
  def block(u, on, pos), do: call(u, {:block, on, pos})

  def crop(u, pos), do: call(u, {:crop, pos})

  @doc "Plant a carrot in the air cell `pos`, over grass (tilled) or dirt."
  def plant(u, pos), do: call(u, {:plant, pos})

  @doc "Pick the ripe crop at `pos` into `name`'s bag. `{:ok, bag}`."
  def harvest(u, name, pos), do: call(u, {:bag, name, :harvest, [pos]})

  @doc "Dig the block at `pos` of frame `on` into the bag, breaking furniture or taking scaffolding down."
  def dig(u, user, name, on, pos), do: call(u, {:bag, name, :dig, [user, on, pos]})

  @doc "Place one `item` from the bag at `pos` of frame `on`, turned `rot`."
  def place(u, name, on, pos, item, rot), do: call(u, {:bag, name, :place, [on, pos, item, rot]})

  @doc "Lay out blueprint `kind` at `pos` of frame `on`, turned `rot`. `{:ok, site_id}`."
  def build(u, kind, on, pos, rot), do: call(u, {:build, kind, on, pos, rot})

  @doc "Put ingredients from the bag into the blueprint at `pos` of frame `on`. `{:ok, built_id | nil, bag}`."
  def deposit(u, name, on, pos), do: call(u, {:deposit, name, on, pos})

  def stash(u, name, at, id, slot), do: call(u, {:bag, name, :stash, [at, id], [slot]})

  def take(u, name, at, id, slot), do: call(u, {:bag, name, :take, [at, id, slot]})

  @doc """
  `user` standing at `at` picks up `{:cell, on, pos}` (a carryable block, or
  the furniture there), `{:furniture, id}` or `{:cow, id}`. `{:ok, how, bag}`,
  `how` being `:block`, `:cow`, `:lifted`, `:gripped` (waiting for a second
  carrier) or `:pocketed` (packed into the bag).
  """
  def pick_up(u, user, name, what, at), do: call(u, {:pick_up, user, name, what, at})

  @doc "`user` puts down what they hold at `pos` of frame `on`, turned `rot`."
  def put_down(u, user, on, pos, rot \\ 0), do: call(u, {:put_down, user, on, pos, rot})

  @doc "`user` left: set down what they held, leave any helm."
  def release(u, user), do: call(u, {:release, user})

  @doc """
  `user` takes the helm they stand at, or lets go of the one they hold.
  `{:ok, ship_id}` taking it, `{:ok, nil}` letting go.
  """
  def helm(u, user), do: call(u, {:helm, user})

  @doc "The pilot asks for `{thrust, turn, lift}`, each -1..1."
  def steer(u, user, helm), do: call(u, {:steer, user, helm})

  def call_helper(u, user, id), do: call(u, {:call_helper, user, id})

  @doc "Advance to `now_ms` and broadcast, as a timer tick does. For tests."
  def tick(u, now_ms), do: call(u, {:tick, now_ms})

  @doc "Run the ambient systems as an idle tick does. For tests."
  def ambient(u, now_ms), do: call(u, {:ambient, now_ms})

  @doc "Save now."
  def save(u), do: call(u, :save)

  @doc "Start over from the database: terrain, state, fresh cows. For tests."
  def reset(u, opts \\ []), do: call(u, {:reset, opts})

  # -- server

  @impl true
  def init(u) do
    # so terminate/2 runs (and saves) on a normal shutdown
    Process.flag(:trap_exit, true)
    config = Application.get_env(:sosh, __MODULE__, [])

    state = %{
      u: u,
      uni: nil,
      kind: "sea",
      tick_ms: config[:tick_ms],
      stage_ms: config[:stage_ms] || 60_000,
      cows: config[:cows] || 0,
      idle_ms: config[:idle_ms] || 2_000,
      sleep_after_ms: config[:sleep_after_ms] || 10_000,
      save_ms: config[:save_ms],
      empty_since: nil,
      last_ambient: 0,
      last_save: now_ms()
    }

    state = build(state)
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(msg, _from, state) do
    # anything that changes the universe wakes it first, catching up on
    # the world ticks it slept through
    if wakes?(msg), do: Universe.wake(state.uni, now_ms())
    {reply, state} = act(msg, state)
    {:reply, reply, state}
  end

  @lookups [:spawn, :chunks, :block, :crop, :ambient, :reset, :feet, :reach]
  defp wakes?(msg) when is_tuple(msg), do: elem(msg, 0) not in @lookups
  defp wakes?(_), do: false

  defp act(:snapshot, state) do
    {gx, gy} = state.u
    snap = Universe.snapshot(state.uni)

    snap =
      Map.merge(snap, %{
        cows: Enum.map(snap.cows, &row/1),
        universe: [gx, gy],
        kind: state.kind
      })

    {snap, state}
  end

  defp act({:spawn, user, at}, state),
    do: {Universe.spawn(state.uni, user, floats(at)), state}

  defp act({:chunks, keys}, state) do
    chunks =
      for {_, _, _} = key <- keys, rle = Universe.rle(state.uni, key), rle != nil do
        %{key: Tuple.to_list(key), rle: rle}
      end

    {chunks, state}
  end

  defp act({:block, on, pos}, state),
    do: {Universe.block(state.uni, on, pos), state}

  defp act({:feet, user}, state), do: {feet_of(state, user), state}

  defp act({:reach, user, on, {x, y, z}, reach}, state) do
    result =
      with {:ok, {px, py, pz}} <- feet_of(state, user),
           {cx, cy, cz} <- Universe.world_of(state.uni, on, {x * 1.0, y * 1.0, z + 0.5}) do
        {dx, dy, dz} = {cx - px, cy - py, cz - pz}
        if dx * dx + dy * dy + dz * dz <= reach * reach, do: :ok, else: {:error, "out_of_reach"}
      else
        nil -> {:error, "no_such_ship"}
        error -> error
      end

    {result, state}
  end

  defp act({:crop, pos}, state),
    do: {Universe.crop_at(state.uni, pos), state}

  defp act({:plant, pos}, state),
    do: reply(state, Universe.plant(state.uni, pos))

  # Anything that changes a bag: `fun(universe, ...before, bag, ...after)`.
  defp act({:bag, name, fun, before}, state),
    do: act({:bag, name, fun, before, []}, state)

  defp act({:bag, name, fun, before, rest}, state) do
    args = [state.uni | before] ++ [Players.bag(name) | rest]
    reply(state, with_bag(name, apply(Universe, fun, args)))
  end

  defp act({:build, kind, on, pos, rot}, state),
    do: reply(state, Universe.start_site(state.uni, kind, on, pos, rot))

  defp act({:deposit, name, on, pos}, state) do
    result =
      case Universe.site_at(state.uni, on, pos) do
        nil -> {:error, "no_blueprint_there"}
        site -> with_bag(name, Universe.deposit(state.uni, site, Players.bag(name)))
      end

    reply(state, result)
  end

  defp act({:pick_up, user, name, what, at}, state) do
    uni = state.uni
    at = floats(at)

    result =
      case what do
        {:cow, id} ->
          with :ok <- Universe.pick_cow(uni, user, at, id), do: {:ok, :cow, nil}

        {:furniture, id} ->
          with_bag(name, Universe.grab(uni, user, at, id, Players.bag(name)))

        {:cell, on, pos} ->
          case Universe.furniture_at(uni, on, pos) do
            nil ->
              with {:ok, _} <- Universe.pick_block(uni, user, at, on, pos),
                   do: {:ok, :block, nil}

            id ->
              with_bag(name, Universe.grab(uni, user, at, id, Players.bag(name)))
          end
      end

    reply(state, result)
  end

  defp act({:put_down, user, on, pos, rot}, state),
    do: reply(state, Universe.put_down(state.uni, user, on, pos, rot))

  defp act({:release, user}, state) do
    Universe.release(state.uni, user)
    reply(state, :ok)
  end

  defp act({:helm, user}, state) do
    result =
      if Universe.leave_helm(state.uni, user) do
        {:ok, nil}
      else
        with {:ok, at} <- feet_of(state, user), do: Universe.take_helm(state.uni, user, at)
      end

    reply(state, result)
  end

  defp act({:steer, user, helm}, state),
    do: reply(state, Universe.steer(state.uni, user, floats(helm)))

  defp act({:call_helper, user, id}, state),
    do: reply(state, Universe.call_helper(state.uni, user, id))

  defp act({:tick, now}, state) do
    step(state, now)
    {:ok, state}
  end

  defp act({:ambient, now}, state) do
    Universe.ambient(state.uni, now)
    flush(state)
    {:ok, state}
  end

  defp act(:save, state), do: {:ok, persist(state)}

  defp act({:reset, opts}, state) do
    state = build(%{state | cows: Keyword.get(opts, :cows, state.cows)})
    {:ok, state}
  end

  @impl true
  def handle_cast(:reopen, state) do
    Universe.set_open(state.uni, Universes.open(state.u))
    {:noreply, state}
  end

  def handle_cast({:arrive, cargo, from}, state) do
    Universe.wake(state.uni, now_ms())
    {:ok, _} = Universe.arrive(state.uni, cargo, to_string(from))
    flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(state)
    {:noreply, live(state, now_ms())}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.save_ms && state.uni, do: persist(state)
    :ok
  end

  # -- internals

  defp build(%{u: {gx, gy} = u} = state) do
    rec = Universes.get(u) || raise "no universe #{inspect(u)}"
    uni = Universe.bigbang(gx, gy, rec.seed, state.stage_ms)
    Enum.each(World.load(u), fn {key, bin} -> Universe.load_chunk(uni, key, bin) end)

    cond do
      rec.state ->
        case Universe.restore(uni, rec.state) do
          :ok -> :ok
          {:error, why} -> Logger.error("universe #{inspect(u)}: bad saved state: #{why}")
        end

      u == {0, 0} ->
        # the plaza's crops from before universes, grown by the time since
        now = now_ms()

        for %Crop{x: x, y: y, z: z, planted_ms: t} <- Repo.all(Crop),
            do: Universe.plant_aged(uni, {x, y, z}, now - t)

      true ->
        :ok
    end

    # a new universe's clock starts now; a saved one sleeps until visited
    if rec.state == nil, do: Universe.wake(uni, now_ms())
    Universe.spawn_cows(uni, state.cows)
    Universe.set_open(uni, Universes.open(u))
    Universe.drain(uni)
    %{state | uni: uni, kind: rec.kind, empty_since: nil}
  end

  # A timer tick: tick while anyone's here, or for a while after the last
  # one leaves; then save and sleep, running only the ambient systems.
  defp live(state, now) do
    here = players(state)

    state =
      cond do
        here != [] ->
          step(state, now, here)
          %{state | empty_since: nil}

        Universe.asleep(state.uni) ->
          if now - state.last_ambient >= state.idle_ms do
            Universe.ambient(state.uni, now)
            flush(state)
            %{state | last_ambient: now}
          else
            state
          end

        state.empty_since == nil ->
          step(state, now, here)
          %{state | empty_since: now}

        now - state.empty_since >= state.sleep_after_ms ->
          Universe.sleep(state.uni, now)
          persist(state)

        true ->
          step(state, now, here)
          state
      end

    awake = not Universe.asleep(state.uni)

    if (awake and state.save_ms) && now - state.last_save >= state.save_ms,
      do: persist(state),
      else: state
  end

  # Everyone here, `{id, on, {x, y, z}}`: feet in the world or on a ship.
  defp players(state) do
    t = Lobby.now()

    for p <- Lobby.list(state.u),
        {on, [x, y, z]} = Lobby.frame(p, t),
        do: {p.user_id, on, {x * 1.0, y * 1.0, z * 1.0}}
  end

  # A player's feet in the world, where Sosh.Lobby predicts them.
  defp feet_of(state, user) do
    here = state.u

    with %{universe: ^here} = p <- Lobby.get(user),
         {on, [x, y, z]} = Lobby.frame(p, Lobby.now()),
         {_, _, _} = at <- Universe.world_of(state.uni, on, {x * 1.0, y * 1.0, z * 1.0}) do
      {:ok, at}
    else
      _ -> {:error, "not_in_world"}
    end
  end

  defp step(state, now), do: step(state, now, players(state))

  defp step(state, now, players) do
    {cows, moos, ships, helpers} = Universe.tick(state.uni, now, players)
    if cows != [], do: broadcast(state, "cows", %{rows: Enum.map(cows, &row/1)})
    if moos != [], do: broadcast(state, "moo", %{ids: moos})
    if ships != [], do: broadcast(state, "ships", %{rows: Enum.map(ships, &ship_row/1)})
    if helpers != [], do: broadcast(state, "helpers", %{rows: Enum.map(helpers, &row/1)})
    flush(state)
  end

  defp persist(state) do
    chunks = Universe.take_dirty(state.uni)
    World.store(state.u, chunks)
    {gx, gy} = state.u
    json = Universe.save(state.uni, now_ms())

    Repo.update_all(
      from(r in UniverseRecord, where: r.gx == ^gx and r.gy == ^gy),
      set: [state: json, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    %{state | last_save: now_ms()}
  end

  defp schedule(%{tick_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :tick, ms)

  defp schedule(_), do: :ok

  # Reply, after broadcasting whatever the call changed.
  defp reply(state, result) do
    flush(state)
    {result, state}
  end

  # Keep a changed bag and reply with it as JSON wants it.
  defp with_bag(name, {:ok, bag}) when is_list(bag), do: {:ok, keep(name, bag)}
  defp with_bag(name, {:ok, x, bag}) when is_list(bag), do: {:ok, x, keep(name, bag)}
  defp with_bag(_name, other), do: other

  defp keep(name, bag) do
    Players.put_bag(name, bag)
    Players.bag_json(bag)
  end

  defp flush(state) do
    for {event, payload} <- Universe.drain(state.uni), do: emit(state, event, payload)
    :ok
  end

  defp emit(state, :block_changed, p),
    do: broadcast(state, "block_changed", Map.put(p, :block_type, World.block_name(p.block)))

  # A ship flew off our edge: it's the neighbour's now, with all aboard.
  defp emit(state, :departed, %{id: id, cargo: cargo, side: side, riders: riders}) do
    side = Universes.side(side)
    to = Universes.beside(state.u, side)

    case ensure(to) do
      {:ok, _} ->
        GenServer.cast(via(to), {:arrive, cargo, Universes.opposite(side)})

        # Only members of the server there go along; anyone else is set
        # down on this universe's home island instead.
        {going, staying} =
          Enum.split_with(riders, fn user ->
            case Lobby.get(user) do
              %{account_id: a} when a != nil -> Sosh.Servers.may_enter?(to, a)
              _ -> true
            end
          end)

        for user <- going, p = Lobby.get(user), p != nil do
          Players.move(p.name, to)
        end

        {gx, gy} = to
        broadcast(state, "travel", %{ship: id, users: going, to: [gx, gy]})

        for user <- staying do
          {{x, y, z}, _} = Universe.spawn(state.uni, user, nil)
          broadcast(state, "stranded", %{user_id: user, at: [x, y, z], reason: "not_a_member"})
        end

      error ->
        Logger.error("ship lost flying to #{inspect(to)}: #{inspect(error)}")
    end
  end

  defp emit(state, event, payload), do: broadcast(state, to_string(event), payload)

  defp broadcast(state, event, payload),
    do: SoshWeb.Endpoint.broadcast("actions:" <> Universes.key(state.u), event, payload)

  defp row({id, x, y, z, h}),
    do: [id, Float.round(x, 3), Float.round(y, 3), Float.round(z, 3), Float.round(h, 3)]

  defp ship_row([id | rest]), do: [trunc(id) | Enum.map(rest, &Float.round(&1, 3))]

  defp floats(nil), do: nil
  defp floats({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}
  defp floats([x, y, z]), do: {x * 1.0, y * 1.0, z * 1.0}

  defp now_ms, do: System.os_time(:millisecond)
end
