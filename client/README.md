# sosh client

The sosh frontend is a [Petrichor64](../../petrichor64) game. The same scripts run as
a desktop app and in the browser, and all UI (connect screen, chat, name tags,
speech bubbles, buttons) is drawn in-engine on the `gui` layer, so the two builds
behave identically.

```
client/
  scripts/   Lua (silt): main (app, network), tools (keys, pointer), hud, phx,
             avatar, world, blocks, farm, carry, furniture, ships (and
             helpers), bag, ui, util
  assets/    generated models (.glb) and tile textures
  tools/     gen_assets.py — regenerates assets/, the player and faces from the
             old web client's front/public/models/player.glb and faces.png
  icon.png   cart icon (required by `pack`)
  justfile   build/run recipes
```

## Running

Needs a Petrichor64 engine with the **`ws`** feature, which provides
`conn("ws://…")`. The web build always has it. For desktop, build it with
`just engine`. The `chor`/`petrichor64` binary in `~/.cargo/bin` predates it.

```sh
just engine        # desktop engine with websockets (once)
just db            # Postgres for the world, on :5442
just serve         # Phoenix on :4000, in another terminal (container if no local mix)
just desktop       # run the client window; join with server ws://localhost:4000
```

The recipes run from the repo root or `client/`. Containers use podman if it's
installed, otherwise docker (`CTR=docker` to choose). On macOS (Docker
Desktop) the server container publishes :4000 and reaches Postgres at
`host.docker.internal` instead of sharing the host network.

Web (served by Phoenix from `server/priv/static/`):

```sh
just web           # build the wasm engine + pack the game into priv/static
just serve         # open http://localhost:4000
```

After a script or asset change, rerun `just pack` (web) or reload the desktop
client (Super+R). The client needs the engine's `feat/skinning` branch. The
recipes use the `~/projects/petrichor64-ws` worktree of it if that exists,
else `~/projects/petrichor64`; set `P64=/path/to/petrichor64` to override.

## The world

The world is a grid of **universes**. Each is 96×96 blocks of floating
islands, over the sea or over wild land far below. Universe (0, 0) is the
plaza; (1, 0) lies east of it. A universe with nobody in it sleeps: crops
stop ticking (and catch up the moment someone arrives), empty ships fly
home, and a universe whose ship has flown away builds another.

**Airships** are blocks that fly together: a hull, a deck with rails, a
helm at the stern and a balloon on four masts. One docks by each
universe's home island, its side to the shore; step aboard amidships,
where the rail is open. Anyone at the helm steers it. It only turns about
the vertical, and it can't fly through islands or other ships. Everyone on
deck moves with it. A ship is built like anything else: put blocks on it
(deck, hull, balloon, rail and helm blocks come from digging one, and new
players start with some deck), set chests and furniture down on it, lay
out blueprints on it. Whatever's aboard flies with it. Fly one off the edge
of the universe and it crosses into the neighbour on that side, everyone
and everything aboard, if the grid has one; if not, the ship stops there.

Your **bag** goes by your name and follows you between universes. Digging
fills it and building spends from it. New players start with wood, stone,
path, deck and two pots.

**Furniture** (chest, drawer, dresser, table, stool, wardrobe) is built
from blueprints. Lay one out with the craft tool and scaffolding fills its
footprint. Then click the scaffolding to put in the ingredients until the
recipe is met. Chests, drawers, dressers and wardrobes hold things. Most
furniture stays whole: carry it (one thing at a time) to move it. Drawers
and stools pack into the bag when empty. Dressers and wardrobes are heavy
and take two to lift: another player, or a helper (Porter and Hob on the
plaza; one on every home island). Digging furniture breaks it: half of
what it was made of comes back, and everything it held. Whatever doesn't
fit in your bag is left in a sack.

## Controls

- **1–6**: tool. **Walk** clicks a block to walk onto it, furniture to
  open it, and a ship's helm to take it. **Dig** digs into your bag, breaks
  furniture, and takes scaffolding down (everything put in comes back).
  **Build** places what's picked from the bag on the outlined face.
  **Plant** plants carrots on grass or dirt, or picks them once ripe.
  **Carry** lifts a pot, a cow or furniture over your head and puts it
  down on a face. **Craft** lays out a blueprint, then puts in its
  ingredients. The toolbar at the bottom does the same.
- **Z / X**: what the tool uses: the item to build, or the blueprint.
  **R** turns furniture and blueprints. A green outline shows where they'll
  go.
- **I**: the bag. With furniture open, click a bag slot to put that stack
  in and a furniture slot to take it out. Otherwise clicking a slot picks
  it to build with. **Esc** closes it.
- **H**: holding one end of something heavy, ask the nearest helper for
  the other. Clicking a helper with the carry tool does the same.
- **B**: take the helm you're standing at, or let go of it. At the helm,
  **W / S** drive the ship ahead and astern, **A / D** turn it, and
  **Space / C** climb and sink.
- **WASD / arrows**: walk. One block is a step up, two is a wall.
- **7–0**: emote (wave, dance, jump, cheer). The buttons on the right do the
  same.
- **Enter**: chat (Enter sends, Esc cancels)
- **F**: your look (the character creator). **G**: put down what you
  carry (one cell ahead), let go of the helm, or sit and stand.
- **Q/E, right-drag, or drag the world**: orbit the camera. **Scroll**: zoom.
  Clicks on the world act when let go, so a drag never digs or walks.
- **A controller** (`client/web/gamepad.js` in the browser, natively in the
  app): left stick or d-pad walk, right stick and the bumpers turn the
  camera, A takes the helm or lets go, B closes the bag, X is pose (G),
  Y the bag, the triggers climb and sink at a helm, and back asks a helper.

Everything reaches about 7 blocks. The server enforces this and refuses
anything farther.

## Protocol

`phx.lua` speaks Phoenix Channels (V2 JSON serializer) over the engine's
websocket, with reply callbacks for request/response pushes.

The socket starts signed out (account.lua). It can only join
**`auth:lobby`**: `login`, `register` (the server emails a 6-digit code),
`confirm`, `resend`, `forgot` and `reset`, each answering a session `token`
once you're signed in, plus `whoami` (the Android app's world view is already
signed in by its user agent). The client connects again with
`&token=<token>` and joins:

- **`user:<id>`**: your own channel. The join reply has everything: you, your
  bag, the servers and your place in each, friends, conversations, the
  character catalog. Requests: `enter` (go to a server's universe),
  `join_server`, `leave_server`, `friend_add`/`friend_accept`/`friend_remove`,
  `character`, `dm_post`, `claim`/`cancel` (open or take back a gift),
  `members`, `member` (moderation), `invite`, `server_update`. Events tell you
  when servers, friends, your bag or your character change, and about DMs
  and gifts. See `SoshWeb.UserChannel`.
- **`server:<id>`**: a server's chat, for its members. `post` (`body`, and
  optionally `gift: {item, count, to}`) and `history`; `message`, `gift`,
  `deleted` and `members` come in. Gifts go out wrapped: who they're for,
  not what's in them. **`dm:<id>`** is the same for a conversation.

Inside a server, the client also joins two channels for its universe:

- **`room:gx,gy`**: presence, movement, faces, poses, emotes and chat. The
  join reply says where you stand (`at`, and if that's on a ship, `on` its
  id and `local` where on it). Joining a universe you're not in
  is refused with `reason: "elsewhere"` and the `universe` you are in, and
  the client goes there. See `SoshWeb.RoomChannel`.
- **`actions:gx,gy`**: everything else. See `SoshWeb.ActionChannel` and
  `Sosh.Sim`. The join reply is the universe: crops, cows, furniture,
  blueprints (`sites`), ships, helpers, who holds what, which sides lead
  to another universe (`open`), and what lies below (`kind`). It also
  carries your `bag` and the `catalog` of items and furniture.
  - `get_chunks` returns 16×16×16 chunks, run-length encoded.
  - Cells are in the world, or, with `on` a ship's id, in that ship's own
    frame. Every action aimed at a cell takes `on`.
  - `dig_action`, `place_action` (`item`, `rot`), `plant_action` and
    `harvest_action` edit the world, and ships.
  - `build_action` (`kind`, `rot`) lays out a blueprint, and
    `deposit_action` puts ingredients in.
  - `pick_up_action` (`position`, `cow` or `furniture`) and
    `put_down_action` (`rot`) carry things; `call_helper_action` asks a
    helper for a hand.
  - `stash_action` and `take_action` move stacks in and out of furniture.
  - `helm_action` takes the helm we stand at or lets go; `steer` (`helm`
    [thrust, turn, lift], each -1..1) flies the ship.

  Every reply that changes your bag carries the new one. Broadcasts cover
  everything as it changes: `block_changed`, `crop`, `cows`, `moo`,
  `carry`, `furniture`/`furniture_gone`, `site`/`site_gone`, `helpers`,
  `ship` (a whole ship: pose, pilot, blocks), `ship_block`, `ships` (poses
  and velocities, ten times a second), and `travel` when a ship crosses
  into the next universe with its riders.

Movement is sent as motion, not a stream of positions. `move` carries where
the player stands (`at`), their velocity in tiles a second (`v`) and, when
walking to a clicked point, the destination (`to`). It goes out only when
that motion changes (start, stop, a turn of about 14°, a new destination,
a wall), plus once a second while moving to correct drift. Other clients
carry each avatar along its last motion and ease out any error. The server
predicts the same way (`Sosh.Lobby.position/2`) to push cows and check
reach. Walking is about 6 messages a second at worst, and nothing while
standing still. On a ship, `move` also carries `on` (its id) and `local`,
where on it you stand, with `v` and `to` in the ship's frame: the ship
carries everyone on it, so a rider standing still on a flying ship sends
nothing either, and every client places them by the same pose as the ship.

The world lives in Postgres. Each universe's islands are generated from
its seed (`universes` table), and only chunks someone has changed are
stored (`chunks`, one 4 KB row per chunk). The rest of a universe's state
(crops, furniture, blueprints, ships) is a JSON blob in `universes.state`.
It saves when the universe goes to sleep, every 30s while awake and on
shutdown; `Sosh.Sim.save({0, 0})` saves on demand, for example from
`iex -S mix phx.server`. Players' bags and whereabouts are in `players`. Movement runs on the engine's `now()` clock, so it's
the same speed at any frame rate (an engine without `now()` falls back to
counting frames). Heartbeats, reconnect backoff and other timers count
frames.

## Engine constraints worth knowing

- **Web worker sync:** on the web, Lua runs in a worker and only an entity's
  transform (position/rotation/scale) syncs after the frame it was created. So
  a face change swaps the face entity rather than retexturing it.
- **Rigged models:** the engine skins a glTF model and plays its clips
  (`ent:anim`) and bone overrides (`ent:bone`), but wants it Z-up and ignores
  vertex colours. `gen_assets.py` converts `player.glb`: it turns the rig to
  Z-up facing +X and bakes the colours into a palette texture.
- **No exponent literals:** silt can't parse `1e9`, so write the number out.
- **No `mod()` on the web:** it can't reach the renderer from the worker, so
  meshes ship as `.glb` files in `assets/`, generated by `tools/gen_assets.py`.
- **silt miscompile:** a table constructor containing a local, assigned to a
  field or index inside a loop, miscompiles. The scripts always build it into
  a `local` first (petrichor64 `SILT-BUGS.md` #5).
- **`now()`:** the engine's clock (seconds since start) is new on
  petrichor64-ws `feat/skinning`; silt's own `clock()` panics on the web.
- **No model tiles on the web:** the tile world lives in the Lua worker,
  which only learns texture names, so `tile("pot", …)` draws a cube with
  the pot's texture there. Model blocks are entities in their cell
  (`Blocks.is_model`).
- **Smooth ground:** grass and dirt are a `tileset` with the smooth look
  (`world_ground`), so the engine meshes them with marching cubes. It's only
  the look: the edge of a step slopes over half a block either side, while
  walking, rays and the server still use whole blocks. `tileset()` is on
  petrichor64's `feat/tilesets`; without it the ground stays cubes.
- **Load order:** script load order isn't guaranteed, so top level only
  defines things and everything runs from `main()`.
- **JSON nulls vanish:** the decoder drops nulls from arrays and closes the
  gap, so a Phoenix broadcast `[null, null, topic, event, payload]` arrives
  three long. `phx.lua` reads frames from the end, and the server sends
  empty bag and furniture slots as `[]`, not null.
- **Entity tile grids:** a ship is one entity whose tiles (`ent:tile`)
  move and turn with it. On the web an entity's tiles only reach the
  renderer in the frame it's made, so a ship whose blocks change is made
  again. `hit.grid` (and every `hit.*`) waits on a reply the worker never
  gets, like `dtile`, so ships' collisions are worked out by the server and
  players' footing on them by `Avatar.footing`.
- **No anonymous functions:** `local f = function() … end` inside a
  function panics silt's compiler (`SILT-BUGS.md` #10); only named
  functions.
- **No `dtile()` on the web:** there it waits on a reply the worker never
  gets and hangs the VM (and with no arguments it drops only one chunk
  anyway). `Blocks.clear` clears tiles one by one.
