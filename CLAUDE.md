# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

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
- `lib/chat_test/`: Core domain logic
  - `universe.ex`: Elixir interface to Rust NIF functions
  - `application.ex`: OTP application supervisor tree
- `lib/chat_test_web/`: Web layer
  - `channels/room_channel.ex`: WebSocket channel for real-time communication
  - `router.ex`: Phoenix routes (catch-all serves frontend)
  - `endpoint.ex`: Phoenix endpoint configuration
- `native/universe/`: Rust NIF implementation
  - `src/lib.rs`: NIF function exports and Universe state management
  - `src/entity.rs`: Entity data structures

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
- Channel: `"room:lobby"`
- Incoming events: `"joined"`, `"new_msg"`, `"move"`
- Outgoing events: `"get_update"`, `"new_msg"`, `"move"`
- Join payload includes `greet` and `vec` (position vector)
- Each user gets a UUID assigned on join (`socket.assigns.user_id`)

### Rust NIF Interface
- `bigbang()`: Creates new Universe wrapped in ResourceArc with RwLock
- `new_ent(universe)`: Creates entity, returns UUID as binary
- `move_ent(universe, id, pos)`: Updates entity position
- `get_state(universe)`: Returns all entity states as Elixir terms
- All functions use RwLock for thread-safe concurrent access

### Svelte 5 Patterns
- Uses modern runes API ($state, $derived, etc.)
- `bind:this` for canvas element reference
- Mount/destroy lifecycle for Three.js setup/cleanup
- Reactive stores replaced with exported globals in World.ts

## Testing Notes
- Mix tests are in `server/test/`
- No frontend tests currently configured
- Rust can be tested with `cargo test` in `server/native/universe/`

## Known Patterns
- Frontend served as catch-all route from Phoenix (`get "/*path"`)
- Static assets from Vite build copied to `server/priv/static/`
- Phoenix LiveDashboard available at `/dev/dashboard` in dev mode
- Archive folders contain old Svelte and React frontends (not active)
