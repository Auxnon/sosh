# sosh for the desktop

The social client for Linux, macOS and Windows: servers, chat, direct
messages, friends, pockets, pictures, shared games and the world. It's built the way
`~/projects/aqua`'s desktop app is: winit and egui on wgpu. It looks like the
Android app: the same colours, the Android app's own fonts (read from
`android/app/src/main/res/font/`), plastic buttons and paper bubbles.

```sh
just app                       # from the repo root (cargo run --release)
cd desktop && cargo run        # or a debug build
```

It starts on https://sosh.makeavoy.com. The server button under the sign-in
card changes it, e.g. to `http://localhost:4000` for `just serve`.

It builds Petrichor64 from GitHub at a pinned revision (`Cargo.toml`), for
the engine's library mode (`petrichor64::Instance`). To try a local engine
checkout, point the dependency at it with `path = "../../petrichor64"`.

## The world and shared games

Both are Petrichor64 run as a library (`src/stage.rs`): each is an engine
`Instance` on the app's own GPU device, drawing into a texture of its own
that egui shows like a picture. Input that lands on one (and keys, once it's
been clicked) goes to it.

- **The world** runs the sosh game: the same `/game.game.png` the web plays,
  fetched from the server, or a folder with `SOSH_GAME=../client` while
  working on it. It runs trusted (`Policy::open`). Over the engine's host
  channel the app tells it the session and which server to be in
  (`client/scripts/hosted.lua`), so it signs in as you and, like the Android
  app's world, leaves chat and the way home to the app. It keeps running
  while hidden (Chat only, or a DM open), so it stays connected.
- **A shared game** (Play on a cart in chat) opens in a window over the
  chat and runs fenced off (`Policy::sandbox()`): no network, files,
  clipboard, console, other carts, microphone or host channel. Esc or the
  cross closes it.

## Layout

- **Wider than 840 px:** the rail of servers and its page stay docked on the
  left.
- **Narrower:** the menu button slides them in over the chat.
- **The world pane:** sits beside the chat on a wide view and above it on a
  tall one, as on Android.

## Where things are

| File | What |
|---|---|
| `src/main.rs` | the window, the GPU, egui; `--snapshot` (below) |
| `src/state.rs` | what the app knows and does (`AppState.kt`): calls run on threads, and come back as jobs applied once a frame |
| `src/net.rs` | the JSON API (`Api.kt`) and a Phoenix channels client (`Phoenix.kt`); the socket has a thread of its own |
| `src/models.rs` | what the server sends (`Models.kt`) |
| `src/stage.rs` | the world and a shared game: Petrichor64 instances, their textures and input |
| `src/media.rs` | pictures: fetched, decoded (png and apng, jpeg, gif, webp; moving ones keep their frames), kept as textures |
| `src/store.rs` | the server and session token, in `~/.config/sosh/session.json` (mode 600); `SOSH_CONFIG` points elsewhere |
| `src/theme.rs` | colours, fonts, plastic and paper, drawn icons |
| `src/ui/` | sign in (`auth`), the rail and its page (`drawer`), the open place (`chat`), the pages over it (`pages`) |

Pictures are shared with the picture button, or by dropping a file on the
window.

## Checking layouts without a window

```sh
SOSH_CONFIG=some/dir cargo run -- --snapshot out.png --size 1400x860 --secs 6 \
  --click 870,817 --type "hello"
```

This draws the app offscreen (no display needed) for `--secs` seconds, then
writes the picture; the world and games run in it too (with `SOSH_GAME` for
the local game). `SOSH_CONFIG` holds a `session.json` with `server` and
`token`. The `--click`s (logical pixels) land a second apart near the end.
`--type` types into whatever has focus and presses Enter.

## Not here yet

- the character creator
- server settings
- the retro screen looks
- notifications
