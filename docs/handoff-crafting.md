# Handoff: the crafting book

For the agent building the crafting system. Written 2026-11-17 against `main`
@ `4114258`; line numbers are as of that commit. Nothing here is built yet.

## Context

The user wants a crafting system built around a **blueprints book**: a 3D book
that opens, with items drawn onto its 3D pages. It should work in two places:
- in the game, opened from an icon that looks like it belongs in the engine;
- in the apps as a view of its own, outside any world.

Search uses the app's native field: egui on desktop, a Compose field on
Android. The field talks to the engine through a new Petrichor64 **hook** API,
`hook(key, value)`, that says which item to show.

Choosing an item walks you through it step by step, like IKEA instructions.
For example, a bed is 1 plank, 4 posts and 3 cloth sheets:
- the plank is made by veneering;
- posts are sawn from planks;
- cloth sheets are woven on a loom from yarn;
- yarn is spun from wool on a spinning wheel.

The book shows the precursor steps first and skips any ingredient you already
have. Each step needs you to be near its station, such as a loom. Leaving a
recipe partway saves it in history, and the book shows it again next time it
opens.

Each station has its own interaction, with tools along the top of its menu. In
the woodworker, for example, you pick the saw and draw a line across a plank to
get 2 posts. Stations also work without a recipe: drag an item in from the bag
and do the right action. The result flies back into the bag in an in-engine
animation. A station opened by hand stays open; one opened by a recipe closes
itself and moves on to the next step.

## Decisions (answered by the user, 2026-11-17)

1. **Wool comes from sheep.** A new sheep animal wanders like cows. Shearing
   one gives wool, and it grows back after a while.
2. **Veneering makes planks.** Wood block → plank at a veneer station; saw a
   plank → 2 posts; wool → yarn on the spinning wheel; yarn → cloth sheet on
   the loom. There is no separate wood-sheet item.
3. **Recipes replace scaffold blueprints.** The craft tool, scaffolding,
   `Sim::start_site` and `deposit` are retired. What the last step does
   depends on the thing made:
   - Small things (the kinds that pack into a bag today, like drawers and
     doors) go into the bag.
   - Heavy things, which is most furniture, don't fit in a bag. On the last
     step the player chooses: assemble it in the world where they aim, or get
     it in their arms as something carried that has to be put down
     (`Held::Furniture`, `Sim::put_down`).
4. **The standalone book also does hand steps.** Outside a world it can
   browse, search, start a recipe (saved in history), show what's missing, and
   do any step that needs no station. Steps that need a station still wait
   for one in a world.

Added by the user after those answers (2026-11-17):

5. **Too heavy means overencumbered.** Someone holding furniture that needs
   more carriers than it has (the dresser, `carriers: 2` in `furniture.rs`)
   can't move. They can put it down, wait for a second carrier, or break it.
6. **Carried furniture can be broken.** So nobody is stuck when there's
   nowhere to put it down. Breaking gives back most of the raw parts, not all.
7. **The standalone book knows the player's state:** their bag, their recipe
   history and which stations they can use.
8. **Station access is state on the player, kept by the server.** The sim
   works out which station kinds each player is in range of and records it on
   the player. Crafting checks that record; the client never claims to be
   near a station.
9. **Pocket rooms have double station range,** as a convenience.
10. **Unfinished blueprints can be broken for their raw materials.** This
    settles what the saved scaffolds turn into when the system is retired.

11. **Stations are still about being near them.** Walk too far from one and
    its step can't be done; access is cleared on leaving the world, so the
    standalone book does only hand steps and shows station steps as waiting.
12. **The server validates every result.** The client can't cheat a step: the
    server checks the ingredients, the station and the gesture, and decides
    what comes out.
13. **Breaking gives back three quarters** of each raw material, rounded
    down, at least one.
14. **A good line wastes less.** The client sends the stroke it drew; the
    server scores it and a better stroke yields more. A gesture never fails
    outright. Suggested rule: a step's listed output is the best case, a poor
    stroke gives as little as half of it, and never less than one.

Not yet decided:
- Which recipe steps are hand steps. None of the example steps are; a hand
  step would be a recipe step with no station kind.

Smaller points to settle while building:
- What the spinning wheel, loom and veneer gestures are. Suggested: circle the
  wheel, alternate swipes across the loom, one long stroke along the block.
- How many history entries to keep.
- Whether other players see you crafting.

## What's there to build on (from exploring both repos)

**Petrichor64 (`~/projects/petrichor64`, main at db2792e):**
- Host channel: Lua has `host.send(s)` and `host.recv()`
  (`src/command.rs:3545-3588`). Embedders use `Instance::post` and
  `Instance::messages` (`src/instance.rs:424,429`). The web build has
  `Engine.post` and a `"message"` event on the `<petrichor-64>` element
  (`src/lib.rs:1848-1884`, `web/petrichor64-element.js`). Messages are
  strings only, capped at 1024 per direction.
- No hook callback: the cart has to poll `host.recv()` in `loop()`. The
  pattern to copy is `Drop`, a `LuaTalk` variant that calls a Lua global with
  a string (`src/lua_define.rs:65,628,945`; `Instance::input(Input::Drop)`).
- Dynamic textures: `nimg(w,h)` / `gimg(name)`, then `line`, `rect`, `img`
  and text on the image, then `tex(name, img)` to upload it under a name
  (`src/command.rs:2670-2724`, `guide/image.md`). That's enough to draw items
  onto page textures and redraw them on change. There is no rendering of the
  3D scene into a texture.
- Entities: `ent.tex` and `ent.asset` can change at runtime, and the web build
  forwards those changes (`EntLook`, `src/worker.rs:79-110`). The comment in
  sosh's `avatar.lua:6-9` saying "only transforms sync on the web" is
  therefore stale; it hasn't been tested.
- Skinned glb models: `ent:anim(clip, force, speed, fade, once)`, `ent:bone`,
  `ent:ik` and `lot`. That's enough for a book model whose cover and page
  bones open and turn.
- Several engines: each native `Instance` has its own VM
  (`examples/two_carts.rs`). On the web, each `<petrichor-64>` element gets its
  own worker.

**Desktop app (`desktop/src/stage.rs`):**
- `Stages` has a `world` slot (our game) and a `play` slot (a shared cart),
  each an `Instance` drawn as an egui texture.
- Messages into the game: `session ...`, `enter <id>`, `backdrop` (read by
  `client/scripts/hosted.lua`). What the game sends back is only logged
  (`stage.rs:340`).
- Screens are `Screen{Chat,Explore,Friends,Bag,Members}`, built with
  `ui::page` (`ui/mod.rs:159`). There's no search field anywhere yet; the bag
  page is `pages.rs:165`.

**Android app:**
- `WorldPane.kt` is a WebView of the web game. It signs in through the user
  agent (`sosh-token/`, `sosh-enter/`).
- Kotlin can only reach the page with `evaluateJavascript` (the ready poll,
  and `Gamepad` key events). There's no JS interface.
- `PocketsPanel` is a Compose overlay drawn over the world, the pattern for a
  search bar over the book.
- Item icons: `Kit.kt:160-184`.

**Web page ↔ game:**
- `client/web/bridge-worker.js` already delivers `{to:"game"}` messages to a
  `/sosh-bridge` socket in the VM worker.
- But nothing on the page sends them (`bridge.js`), and no Lua reads them
  (`web.lua`).

**Server:**
- Items and bags: `items.rs`. `ITEMS` (`:33-92`) has no plank, post, wool,
  yarn or cloth. `take` is all-or-nothing, and `add` returns what didn't fit.
- Bags change in one step through `Sosh.Players.change_bag/2`
  (`players.ex:46`, `with_bag` in `sim.ex:595`).
- Actions: `action_channel.ex`, with `within_reach` (`:306`) and errors
  returned as `{reason}`.
- No lookup finds furniture by kind near a point. The closest pattern is
  `reachable_box` (`sim.rs:1123`, `dist(at, furniture_middle(f)) > REACH`).
- `catalog()` (`lib.rs:784`) sends the game the furniture kinds and items.
- Nothing stores per-player history or preferences. `players` has name, place,
  `bag` and wallet; `users` has `character`.

## Plan

### 1. Petrichor64: the hook API (branch `feat/hook`, the user merges it)
- **Lua:** a global `hook(key, value)` that the engine calls once for each
  event, before `loop()`. Add `host.hook(key, value)` for events going out to
  the host. Keep `host.send` and `host.recv` as they are.
- **Rust:** `Instance::hook(key, value)` and `Instance::hooks()`. A new
  `LuaTalk::Hook` variant modelled on `Drop`, and `HostToVm::Hook` and
  `VmToHost::Hook` for the web worker.
- **Web:** `Engine.hook(key, value)` and `el.hook(...)`, plus a `"hook"`
  event on the element.
- **Policy:** gated by `host_messages`, so it's off in the sandbox. Tests go
  in `tests/host.rs`.
- **Sosh side:** pin sosh to the merge commit (Containerfile, `release.yml`,
  `desktop/Cargo.toml` / `Cargo.lock`), as was done for rig-attach.

### 2. Server: recipes, stations, crafting
- **Items:** a new `recipes.rs` with the new items: plank, post, wool, yarn,
  cloth sheet. Each recipe step has inputs, outputs, the station kind it needs
  (none for a hand step), and the tool or gesture name.
  - Example steps: `wood 1 → plank 1` (veneer), `plank 1 → post 2` (bench,
    saw), `wool 2 → yarn 1` (spinning wheel), `yarn 2 → sheet 1` (loom),
    `plank 1 + post 4 + sheet 3 → bed` (bench, assemble).
- **Stations:** new furniture kinds (bench, veneer, spinning wheel, loom).
  Each has its own recipe, so it can be made from simple parts.
- **Station access:** each tick the sim works out, for every player, the
  station kinds within `REACH` of them (twice `REACH` inside a pocket room,
  `Ship::pocket`), in the same frame as the player. When the set changes,
  `Sosh.Sim` records it on the player (`Sosh.Players`, a `stations` list of
  kind names; a list reads better than a bitmask and costs nothing at this
  size) and pushes it on `user:<id>`. It is emptied when they leave the
  universe.
- **The crafting action:** `craft(step, stroke)` checks the step's station
  kind against the player's recorded access, scores the stroke (a list of
  points in the station's drawing area, 0..1 each way) against the step's
  gesture, then takes the inputs and adds the scored outputs in one
  `change_bag`. No station id is sent. Errors: `missing_ingredients`,
  `no_station_near`, `bag_full`.
- **The last step of a furniture recipe:**
  - A kind that packs into a bag (`itemizable`) is added to the bag like any
    other output.
  - Any other kind is never a bag item. The action says which the player
    chose: `place` with a spot and turn (the furniture appears there, with the
    checks placing has today), or `carry` (it appears in their arms as
    `Held::Furniture`, refused if they're already holding something).
  - **Overencumbered:** held furniture with fewer carriers than its kind
    needs pins its holder. The sim refuses their moves (the same way a
    carried player's are) and says so in their state, so the game can show
    it. A second carrier taking hold frees them both.
  - **Breaking:** a `break` action on furniture you hold, or on empty
    furniture in reach, removes it and gives back most of its raw parts: the
    recipe expanded down to raw materials. They go to the bag, and what
    doesn't fit drops as a sack at the player's feet (`Sim::drop_stack`).
  - The inputs are taken only if the furniture could be made.
- **Hand steps:** a step with no station can also be done over `user:<id>`,
  outside a world, through the same `change_bag`.
- **Player state for the book:** `user:<id>` gives the bag, `crafting`
  history and `stations`, and pushes each when it changes, so the standalone
  book shows the same as the one in the world.
- **Retired:** starting scaffold blueprints (`Kind::recipe`,
  `Sim::start_site`, `deposit` and their channel events). Unfinished ones
  already in a universe still load and stay where they are. Breaking one
  removes it and gives back every block deposited in it; that is all that
  can be done with them.
- **Channel event:** `craft_action` on `actions:gx,gy`, replying with `{bag}`.
- **Catalog:** recipes are added to it, so the game and both apps can show
  them. The book itself never decides whether a step worked; the server does.
- **History:** a migration adding `players.crafting` (a map of the recipes in
  progress and the step each is on). Read and written over `user:<id>`
  (`crafting` get and set), so the standalone book has it outside a world too.
- **Wool source:** a `Sheep` alongside `Cow` (spawning, wandering), a `shear`
  action that gives wool, and regrowth on the world tick.
- **Tests:** in `sim/tests.rs` and Elixir channel tests.

### 3. Game client (`client/scripts/`)
- **`book.lua`:**
  - A skinned book model, `assets/book.glb` (cover and page bones), and an
    open/turn animation.
  - The two pages are textures drawn with `nimg`, using item icons, names,
    counts and step numbers, and uploaded with `tex("book_l", ...)` /
    `tex("book_r", ...)` whenever they change.
  - It handles `hook("search", text)`, `hook("show", item)`,
    `hook("open")` / `hook("close")`, and sends `host.hook("step", ...)` and
    friends back out.
- **`recipes.lua`:**
  - Expands an item into its steps, depth first so precursors come first, and
    skips anything already in the bag (`Bag.count`).
  - Remembers the open recipe and its step in `players.crafting`.
- **`stations.lua`:** one interaction per station.
  - The bench has a tool row (saw, assemble). The saw is a stroke across the
    drawn plank, checked by length and angle across it.
  - The veneer, wheel and loom each have their own gesture.
  - A station opened from a recipe closes itself when the step is done; one
    opened by hand stays open.
  - Items are dragged in from the bag panel (`bag.lua` already has dragging).
  - The result flies to the bag as a 3D item arcing toward the bag button.
- **Proximity:** opening a station by hand needs it within reach
  (`Furn.pieces`, `in_reach`; twice that in a pocket room), but whether a step
  can be done is the server's `stations`.
- **In-engine icon:** a small book button on the HUD (`hud.lua`), drawn in the
  same style, that opens the book over the world.
- **Book mode:** a `book` screen with no world, entered by `hook("mode",
  "book")` from an app. It signs in like `session` does, but never joins a
  universe. It still gets the bag, catalog and crafting data, and can do hand
  steps.
- **Finishing heavy furniture:** the last step asks "build it here" or "carry
  it". Building uses the aim and turn the furniture placing already has.
- **Overencumbered:** the player can't walk and is shown straining, with the
  choices put down and break.
- **Breaking:** a break choice on held furniture, on empty furniture in reach
  and on unfinished blueprints; the parts fly to the bag like a station's
  result.
- **Stations in the book:** steps are marked ready or waiting from the
  player's `stations`, not from the client's own distance check.
- **Removed:** the craft tool and laying out scaffolding (`tools.lua`).

### 4. Desktop app
- **A `Screen::Book` page:**
  - an egui search field that sends `inst.hook("search", text)`;
  - a results list from the catalog's recipes, where choosing one sends
    `hook("show", item)`;
  - the book drawn in a third `Stages` slot, the same game cart in book mode.
- **Reading back:** `hooks()` from the instance, for example to know which
  step is showing.
- **In a world:** the same search bar sits over the world pane when the book
  is open there.

### 5. Android app
- **A `Screen.Book`:**
  - a Compose search field over a second WebView loading the game in book
    mode (`sosh-book` in the user agent);
  - in a world, the field sits over `WorldPane` the way `PocketsPanel` does.
- **Kotlin → game:** `evaluateJavascript("soshHook(key, value)")`.
  `bridge.js` defines `soshHook` and calls the engine's `hook`, or else posts
  `{to:"game"}` on the bridge.
- **Game → Kotlin:** an `addJavascriptInterface` for the hooks the game sends
  out.

### 6. Order of work
1. The engine hook API, on a branch with its tests.
2. Server recipes, stations and the crafting action, with tests.
3. The book and stations in the game, using hooks typed in a debug chat
   command at first.
4. The desktop book page and search.
5. The Android book screen and search.
6. Wool (sheep), and the station and book models.

## Constraints to keep (this machine and this user)
- **Commits:** `type: [aid] details`, no Claude trailers, split by feature,
  push freely. Never create a `v*` tag, and never commit `server/Cargo.lock`.
- **One heavy build or test at a time on the machine.** Check `free -m` and
  `ps` first. Use `cargo -j 2` and Gradle `--max-workers=2`. Temp files go in
  `$TMPDIR`.
- **Silt Lua rules:** hoist nested calls and table constructors into locals,
  write no anonymous functions in new code, and avoid `^`.
- **Petrichor64 work goes on a branch** for the user to merge. Then sosh is
  pinned to the merge commit.
- **No looking at the desktop screen:** use only the desktop app's offscreen
  `--snapshot` mode, which needs the local server running.

## Verification (for the implementation, later)
- Petrichor64: `cargo test -j 2 --lib` and `tests/host.rs`, with new hook
  tests (an event arrives before `loop`; sandboxed instances ignore it).
- Server: `cargo test -j 2` in `server/native/universe`, plus `mix test` in the
  dev image for recipes, stations, reach and errors.
- Client: `luac -p client/scripts/*.lua`. Then `just web` and `just serve`,
  and play it: open the book, search "bed", follow the steps at each station,
  leave partway and reopen to check the history.
- Desktop: `cargo build -j 2`, plus a `--snapshot` of the book page with a
  search typed (`--type bed`).
- Android: `compileDebugKotlin`, then check by hand on a device.
