# sosh for Android

The Android app: the social side as native screens (Kotlin, Jetpack
Compose), the world as the same web game the browser gets. It talks to the
same Phoenix server as the desktop and web game: the account API (`/api`)
and the Phoenix channels on `/socket`.

## Building

```sh
just android           # app/build/outputs/apk/debug/app-debug.apk
just android-install   # onto the connected phone or emulator (adb)
just android-test      # network code and models against `just serve`
```

Gradle downloads a JDK 21 for itself (`gradle/gradle-daemon-jvm.properties`),
so only a JRE is needed to start it. The Android SDK is read from
`local.properties` (`sdk.dir`), else `$ANDROID_HOME`, else `~/Android/Sdk`.

The app starts pointed at `http://10.0.2.2:4000`, which is the computer
running the emulator. On a phone, tap the server address under the sign-in
form and give it the computer's LAN address (`http://192.168.x.y:4000`);
`just serve` listens on every interface. Debug builds allow plain http;
release builds only allow https.

## What's where

| | |
|---|---|
| `AppState.kt` | everything the app knows and does: session, servers, friends, conversations, bag, the open chat |
| `net/Api.kt` | the account API: JSON over OkHttp, `Authorization: Bearer <token>` |
| `net/Phoenix.kt` | a Phoenix Channels client (v2 JSON frames) over OkHttp's websocket: heartbeats, reconnects, rejoins |
| `data/Models.kt` | the server's JSON as data classes |
| `data/SessionStore.kt` | the token, sealed with an Android Keystore AES-GCM key |
| `ui/AuthScreen.kt` | sign in, sign up, confirm the emailed code, forgot/reset password, server address |
| `ui/Theme.kt`, `ui/Kit.kt` | the look: console plastic around cozy paper (indigo, cream, leaf green, orange; M PLUS Rounded 1c and Michroma, subset to Latin in `res/font`), and its pieces: plastic buttons, paper cards, name tags, item icons |
| `ui/MainScreen.kt` | the server rail (memory-card slots) and drawer, the chat as speech bubbles with @mentions and presents, the message tray and Chat / Both / World, wrapping a present |
| `ui/Pockets.kt` | the pockets over the world, dragging to sort them or onto the chat (`PocketDrag`) |
| `ui/Screens.kt` | server list (join or ask), friends, the pockets page, members and moderation, server settings |
| `ui/CreatorScreen.kt` | the character creator: a front view drawn on a canvas, face sprites dragged into place |
| `ui/WorldPane.kt` | the world: the web game in a web view, and `Gamepad`, which hands a controller's buttons and sticks to it |

Item icons (`res/drawable-nodpi/item_*.png`) are the game's own block
textures plus a few drawn to match: `python3 android/tools/item_icons.py`.
The fonts are under the SIL Open Font License (`FONTS.md`).

## How it fits the server

- **Signing in** is by email and password. A new account confirms its
  address with a 6-digit code from the email. Codes and tokens are only
  stored hashed on the server, and passwords are Argon2id in the Rust NIF
  (`server/native/universe/src/secret.rs`).
- **Servers** are the grid's universes. The rail shows the servers you're
  in; `+` lists all of them, so you can join an open one or ask to join the
  rest (`Sosh.Servers`: open, friends of the owner, or approval). Members
  shows roles and lets you moderate as far as your role allows.
- **Chat** is `server:<id>` or `dm:<id>` on the socket, with history over
  the API. Saying something in the world puts it in the server's chat too.
- **Pockets** are your bag. In a server, the backpack in the corner of
  the world opens them over it (tap it, or drag it up); the rail's
  backpack opens them as a page. Drag a pocket onto another to swap them
  (`bag_swap` on `user:<id>`, which tells the game too), or out onto the
  chat to wrap it as a present.
- **Presents**: dropping a pocket on the chat, the present button, or the
  pockets page sends items to an @someone. They leave your bag straight
  away. Everyone in the chat sees it wrapped, and only that person can
  open it into their bag. You can take it back until they do.
- **The world** is part of a server's chat: the bar under the composer
  slides it in and out (**Chat**, **Both**, **World**). In Both it shares
  the screen with the chat, stacked upright or side by side on its side;
  in World it fills it, with the latest lines over it (tap them for Both).
  Once opened it stays loaded, paused while slid away, until you leave the
  server. It's `WorldPane`: a web view of the server's own page (the web
  game). Its user agent carries `sosh-token/<token> sosh-enter/<id>`; the
  socket signs in by it, and the game skips its own sign-in, opens that
  server and, told it's in the app, leaves chat, looks and the way home
  to the app. Tap the world to walk there (or act with the tool), drag it
  to turn the camera. A controller works too: the activity hands its
  events to `Gamepad`, which presses the game's keys (the mapping is in
  `client/README.md`).
