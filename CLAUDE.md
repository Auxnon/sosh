# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

The live client is the Petrichor64 game in `client/` (desktop and web), plus the Android app in `android/`; `front/` is the older Svelte client.

Sosh is a social application with a 3D interactive world. It combines Phoenix/Elixir backend with Phoenix Channels for real-time communication, Rust NIFs for performance-critical game logic, and a Svelte 5 + Three.js frontend for 3D rendering.

## Architecture

### Backend (server/)
- **Phoenix Framework (Elixir)**: Web server and real-time communication
- **Phoenix Channels**: WebSocket-based real-time messaging via `ChatTestWeb.RoomChannel`
- **Rust NIFs**: Performance-critical universe/entity simulation in `server/native/universe/`
  - Compiled via Rustler to native code callable from Elixir
  - `ChatTest.Universe` module provides the Elixir interface
  - Entity system with UUID-based identification and Vec3 positioning

### Frontend (front/)
- **Svelte 5**: Component framework using modern runes API
- **Three.js**: 3D rendering engine
- **Vite (Rolldown)**: Build tool (using rolldown-vite variant)
- **Tailwind CSS 4**: Styling via @tailwindcss/vite plugin

### Key Integration Points
1. **3D World State**: Shared between `ThreeCanvas.svelte` and `ChatPane.svelte` via `World.ts` exports (`player`, `cameraRef`)
2. **Phoenix Channels**: Real-time communication for player movement, chat messages, and entity updates
3. **Rust NIFs**: Called from Elixir to handle universe state (entity creation, movement, state queries)
4. **3D Chat Bubbles**: Messages are projected from 3D world space to screen coordinates in real-time

## Development Commands

### Backend (from server/)
```bash
# Install dependencies
mix deps.get

# Compile Rust NIFs (happens automatically with deps.compile)
mix deps.compile rustler

# Start development server
mix phx.server

# Run in interactive mode
iex -S mix phx.server

# Run tests
mix test

# Setup entire project (deps + assets)
mix setup
```

### Frontend (from front/)
```bash
# Install dependencies
npm install

# Start development server (proxies to Phoenix backend)
npm run dev

# Build for production
npm run build

# Type checking
npm run check

# Preview production build
npm run preview
```

### Full Stack Development
1. Start backend: `cd server && mix phx.server` (runs on port 4000)
2. Start frontend: `cd front && npm run dev` (Vite dev server)
3. Frontend connects to backend via WebSocket at `ws://localhost:4000/socket`

## Code Organization

### Backend Structure
- `lib/sosh/`: Core domain logic
  - `universes.ex`: the grid of universes (`universes` table); `sim.ex`: one process per universe running its Rust universe
  - `universe.ex`: Elixir interface to the Rust NIF functions; `world.ex`: block ids and saved chunks in Postgres
  - `players.ex`: players by name: their bag and which universe they're in (`players` table)
  - `lobby.ex`: who is where right now; `application.ex`: OTP application supervisor tree
- `lib/sosh_web/`: Web layer
  - `channels/room_channel.ex`: a universe's people (presence, movement, chat); `channels/action_channel.ex`: everything done in it
  - `router.ex`: Phoenix routes (catch-all serves frontend)
  - `endpoint.ex`: Phoenix endpoint configuration
- `native/universe/`: Rust NIF implementation
  - `src/lib.rs`: NIF function exports
  - `src/sim.rs`: one universe: crops, cows, carrying, furniture, blueprints, airships, helpers, sleeping (tests in `src/sim/tests.rs`)
  - `src/terrain.rs` (blocks and floating islands), `src/items.rs` (bags and stacks), `src/furniture.rs` (kinds, footprints, blueprints), `src/ships.rs` (airships)

### Frontend Structure
- `src/App.svelte`: Root component, composes ThreeCanvas and ChatPane
- `src/lib/World.ts`: Shared global state (player Group, camera reference)
- `src/lib/ThreeCanvas.svelte`: 3D scene, player rendering, click-to-move, OrbitControls
- `src/lib/ChatPane.svelte`: Floating chat bubbles with 3D→2D projection
- `src/lib/ChatInput.svelte`: Chat input UI component

## Important Implementation Details

### 3D World Coordinate System
- Player is a Three.js Group containing cone body + sphere head + eyes
- Click-to-move: Raycasts against ground plane, queues movement waypoints
- Movement: Linear interpolation at fixed speed, automatic rotation toward target
- Y-up coordinate system (Three.js default)

### Phoenix Channel Protocol
- The socket signs in with a session token (`token` param, or `sosh-token/<t>` in the user agent for the Android app's web view); signed out it can only join `auth:lobby`
- Channels: `auth:lobby`, `user:<id>` (your own), `server:<id>` and `dm:<id>` (chat), and `"room:gx,gy"` / `"actions:gx,gy"` for universe `{gx, gy}`; the player's name in the world is their account's handle. See `client/README.md` for the events
- Each connection gets a UUID (`socket.assigns.user_id`): who it is in a universe (the same account can connect twice)

### Accounts and the social side
- `Sosh.Accounts`: email + handle + password. 6-digit emailed codes confirm the address and reset passwords (dev: logged, and in `/dev/mailbox`). Session tokens are random, only SHA-256 digests are stored, and sessions last 60 days. Passwords are Argon2id in the Rust NIF (`native/universe/src/secret.rs`, on the dirty CPU schedulers). `Sosh.RateLimit` limits sign-in and code guesses
- `Sosh.Servers`: servers are universes. Ten are seeded (`seed/0`, a 5x2 block of the grid), all open and owned by no one; `give/2` hands one to someone. Policies: open, friends (the owner's friends skip approval), approval. Roles member < moderator < admin < owner, each with cumulative permissions (`perms/1`). Entering a universe, and arriving by airship, needs membership
- `Sosh.Friends`, `Sosh.Chat` (server chats and DMs). A message can carry items for its @: they're taken from the author's bag (`bag_take` NIF, all or nothing), only the recipient can open it (`bag_give`), and it settles once with a conditional update
- `Sosh.Character`: what someone looks like (`users.character`), cleaned on every save; the parts are made by `client/tools/gen_character.py`
- The JSON API is `/api` (`lib/sosh_web/api/`, Bearer token); the Android app (`android/`, see its README) uses it plus the channels

### Universes and the Rust NIF
- The world is a grid of universes, `{gx, gy}`, each 96x96 blocks of floating islands over the sea or wild land. Channels are per universe: `room:gx,gy` and `actions:gx,gy`. A player is in one at a time (`Sosh.Players`, by name); joining another is refused with `reason: "elsewhere"`.
- Each universe is a Rust `Sim` (`native/universe/src/sim.rs`) owned by a `Sosh.Sim` GenServer (registered in `Sosh.Sims`, started under `Sosh.SimSup`). The universe owns its blocks; `Sosh.World` only loads and saves the changed chunks.
- Awake, a universe ticks every 100ms with positions from `Sosh.Lobby` and broadcasts on `actions:gx,gy`. Empty for 10s, it saves and sleeps: only ambient systems run (ships home, a ship rebuilt if none, helpers and cows home); growth catches up on the world ticks it missed when it wakes.
- Its state (crops, furniture, blueprints, ships, world tick) is saved as JSON in `universes.state`; cows respawn on start.
- Airships are block grids with a pose (`ships.rs`): cells are in the world or in a ship's frame (`on`, the ship id; 0 is the world), so blocks, furniture and blueprints can go aboard. Whoever stands at the helm steers (`helm_action`, `steer`); ships collide with islands and each other; players on deck report `on` and `local` in their moves (`Sosh.Lobby.frame/2`).
- Airships fly off a universe's edge into the neighbour on that side (if the grid has one), taking everyone and everything aboard: the sim emits `departed` with the cargo, `Sosh.Sim` hands it to the neighbour and broadcasts `travel`.
- Saved state that no longer parses (an older ship, say) is dropped entry by entry, not wholesale (`readable` in `sim.rs`): keep it that way when changing what's saved.
- Rust tests: `cargo test` in `server/native/universe/`. Editing Rust while `mix phx.server` runs reloads the NIF and can take the app down; restart it

### Svelte 5 Patterns
- Uses modern runes API ($state, $derived, etc.)
- `bind:this` for canvas element reference
- Mount/destroy lifecycle for Three.js setup/cleanup
- Reactive stores replaced with exported globals in World.ts

## Testing Notes
- Mix tests are in `server/test/`; run them in the dev image like `just serve` does (mount the source with `:z`, not `:Z`, or the running server loses its folder)
- The Android app's tests (`just android-test`) run its network code against a running `just serve`
- No frontend tests currently configured
- Rust can be tested with `cargo test` in `server/native/universe/`

## Known Patterns
- Frontend served as catch-all route from Phoenix (`get "/*path"`)
- Static assets from Vite build copied to `server/priv/static/`
- Phoenix LiveDashboard available at `/dev/dashboard` in dev mode
- Archive folders contain old Svelte and React frontends (not active)
