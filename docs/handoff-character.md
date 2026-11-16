# Handoff: characters, head attachments, animation

For the agent taking over the character look and posing in the Petrichor64
game (`client/`). Written 2026-11-15 against `main` @ `706c57e`. Line numbers
are as of that commit.

## Update, 2026-11-16: the engine's rig attachments are in use

Petrichor64 `feat/rig-attach` merged to its main (db2792e, pinned in the Containerfile,
`release.yml` and `desktop/Cargo.toml`) added `lot(parent, child, "bone")`,
`lot(parent, child, true)` (wear the parent's pose), `ent.zyx`, crossfades
and `ent:ik`. `Character` now uses them, so §2 and several defects below are
out of date:
- Only the body is posed each frame. Clothes wear its pose, the head rides
  the `head` bone, hair, hat and face sprites ride the head (placed once, in
  the head's terms), and the held item rides `hand.r`.
- Clip changes fade over `CLIP_FADE` (0.2 s).
- The body's heading is applied last (`zyx`), so `Avatar.lie` lies at any
  angle: `rz = a + π, ry = -π/2`.
- Fixed by this: defects 1, 2, 3 (the face now shows lying down), 4, 5 and 8.
  Still open: 6, 7, 9 to 13.
- Not yet looked at in the running game.

## 1. The pipeline end to end

**Spec (what a character is).** A JSON map, owned by the server:
`server/lib/sosh/character.ex`.
- Fields: `height` 0.85..1.2, `skin`, `head` (round, square, long, bean),
  `hair` (none, short, tuft, bob, spikes, long), clothes slots `top`,
  `bottom`, `shoes` and `hat`, each with its `_color` (`character.ex:24-31`).
  `face` is up to 12 sprites `{part, shape, x, y, scale, rot, color}`
  (`:11-14`, `:118-147`). `hand` is an item name.
- `clean/1` (`:91`) is the only gate. Anything unknown falls back to
  `default/0` (`:60`), and clients only ever receive cleaned specs.
- `catalog/0` (`:49`) lists the options for creators.
- Adding a head, hair or hat means editing `@heads`, `@hair` and `@clothes`
  here, **and** the client lists (see "duplicated lists" below).

**Storage and broadcast.**
- Stored in `users.character` (a map column, `accounts/user.ex:12`).
- Saved via `Sosh.Me.set_character/2` (`me.ex:75`). It cleans the spec and
  empties the hand unless the item is in the bag. It then broadcasts
  `character` on `user:<id>` and on `room:gx,gy` to everyone in the same
  universe (`me.ex:92-96`).
- API: `PUT /api/me/character` (`sosh_web/api/me_controller.ex:10`).
- On join, the room channel's presence carries `character`
  (`room_channel.ex:72`, `:282`).

**Editors.**
- **In-game creator:** `client/scripts/creator.lua` (C on the home screen, or
  `/look`). It rebuilds a preview `Character` at `PREVIEW_Z = 80` on every
  change and saves through `Account.ask("character", …)` (`creator.lua:73`).
  Its option lists are hard-coded at `creator.lua:21-29`.
- **Android:** `android/app/src/main/java/app/sosh/ui/CreatorScreen.kt`.
  It's a **2D Compose Canvas re-drawing** of the character, not the 3D
  models: `drawCharacter` at `:242`, face sprites at `:363`. It saves with
  `PUT /me/character` (`AppState.kt:613`). Its shapes are hand-matched to
  `gen_character.py` and drift from it whenever the models change.
- **Desktop app:** no character editor (grep finds nothing).

**Client receive.**
- `main.lua:537-538` builds an `Avatar.new(…, look)` per player.
- `main.lua:385-388` handles `character`, which calls
  `Avatar:set_character`, then `Character:restyle`, which kills every entity
  and rebuilds them (`character.lua:213`).

**Assets.**
- `client/tools/gen_character.py` (run from `gen_assets.py`) writes these to
  `client/assets/`:
  - `body.glb` and `cl_<name>.glb`: skinned.
  - `head_<name>`, `hair_<name>` and `hat_<name>.glb`: rigid.
  - `fp_<part><n>.glb`: face sprites, each a quad facing +X.
- It also writes `client/scripts/character_rig.lua` (generated, don't edit):
  - `RIG.faces`: per head, the face front x, centre z, half width, half
    height and crown offset.
  - `RIG.parts`: shape counts per face part.
  - `RIG.stretch`: rest translations of the bones that height scales.
  - `RIG.leg_drop`, `RIG.head_z`.
- Source rig: `front/public/models/player.glb`, converted by
  `gen_assets.py:585 player_model`. The conversion turns it Z-up facing +X,
  scales it and bakes vertex colours into a palette texture. It keeps the
  clips `idle`, `sit` and `carry`.
- **Clothes** are cut from the body's own triangles by dominant bone and
  pushed out along their normals (`gen_character.py:202 piece`, table at
  `:38-47`). They keep joints and weights, so they share the body's skin and
  clips.

**Duplicated lists to keep in sync by hand:**
- `character.ex:24-40`
- `creator.lua:21-29`
- `Character.default()` (`character.lua:107`, which mirrors `character.ex:60`)
- `CreatorScreen.kt`
- `gen_character.py` (`heads()`, `hair()`, `hats()`, `face_parts()`, `CLOTHES`)

`RIG.parts` is generated, but the server's `@parts` (`character.ex:33`) is
not.

## 2. How a character is assembled and posed each frame

`Character:build` (`character.lua:132`) makes one entity per piece. They are
**not parented**: no `lot()` is used anywhere in sosh. Every piece is placed
by hand in `Character:pose` (`character.lua:222`), called from
`Avatar:pose` (`avatar.lua:741`) every frame. The pieces fall into four
groups.

**Skinned: body and clothes** (`character.lua:237-262`).
- Every skinned entity gets the same position, `rz = facing` and `rx`/`ry`
  (from `flat` when lying).
- They also get the same `e:anim(clip, true)` on clip change, and the same
  bone overrides.
- Height: each `RIG.stretch` bone gets a translation override of
  `rest_translation * (k-1)`. The whole body is lifted by
  `(k-1)*RIG.leg_drop` (`:137-138`, `:249-256`) so the feet stay on the
  ground.
- Rotation overrides (`turns`) go to every skinned entity, so the clothes
  follow weight for weight.

**Rigid: head, hair, hat** (`character.lua:264-287`).
- Position: `self.body:bone("head")` returns the head bone's **world
  position** (it includes the entity's own rotation, `petrichor64
  src/lua_ent.rs:231-277`, via `entity_matrix`). The head is placed there.
- Hair and hat are placed at `hz + f[5]`, the crown difference from the
  round head, which the hair and hats are modelled for
  (`gen_character.py:288 CROWN`, `:276-325`).
- Rotation: `rz = facing` and `rx`/`ry` = the lie tip. That's the **entity's
  facing only. The head bone's animated rotation is never applied**, because
  `ent:bone(name)` returns only the *override* rotation, not the bone's
  world orientation (`lua_ent.rs:269-276`). Any clip head nod or tilt is
  lost on the head, hair and hat.

**Face sprites** (`character.lua:289-307`).
- Each sprite is its own entity. Position: the head front `f[1]`, plus
  `FACE_LAYER * i` so the sprites layer in order. Width is `p.x * f[3]` and
  height is `f[2] + p.y * f[4]`, rotated by `facing` about world Z by hand
  (`c`/`s` at `:290-300`).
- `e.rz = facing`, and `e.rx = p.rot`, meant as an in-plane roll.
- While lying, every sprite is sent to `z = -1000`, so lying characters have
  no face (`:302-304`).

**Held item** (`character.lua:309-317`): placed at the `hand.r` bone's world
position, z - 0.05, with `rz = facing` only.

**Why everything is rebuilt rather than re-tinted.** On the web build, Lua
runs in a worker. After the frame an entity is made, only its transform
(position, rotation, scale) syncs to the renderer. `tint`, `tex` and `asset`
changes later are silently dropped (`client/README.md:313-315`;
`character.lua:16-18`). So any look change must kill and remake the
entities. Set everything at `make()` time, in the same frame.

## 3. Animation: what's skeletal and what's posed by hand

- **Clips** (skeletal, from `player.glb`): `idle`, `sit`, `carry`. Sosh only
  plays `idle` and `sit` (`avatar.lua:746-764`); `carry` is unused, and
  arms are posed by hand instead. There is **no** `lie` clip.
- **Anim indices:** `ANIMS = { "idle", "sit", "lie" }`, with `ANIM_SIT = 1`
  and `ANIM_LIE = 2` (`avatar.lua:65-67`).
  - They are sent as `animation` on the room channel, which accepts 0..63
    (`room_channel.ex:45`, `:290`).
  - Older clients with a 2-entry `ANIMS` see lie (2) as `2 % 2 = 0`, idle.
  - Set via `set_my_anim`, then `change_anim`
    (`tools.lua:895`, `:975`).
- **Hand-posed bone overrides on top of the clip** (`avatar.lua:765-825`):
  - The pieces: arm swing at `shoulder.l/r` (local y), arm lift at
    `arm.l/r` (local z), leg swing at `waist.l/r` (local y), plus a body bob
    and a twist added to facing.
  - What drives them: the walk cycle (`sin(t*0.24)` scaled by `self.walk`),
    the skid brace (`:776-785`), holding (both arms at `AV_HOLD_ARMS = 2.85`,
    `:786-789`) and emotes (wave, dance, jump, cheer, `:791-815`).
  - Axis conventions are in the comment at `avatar.lua:733-740`. Every
    limb's local z points forward. Lifting at the collarbone pivots from the
    neck, which is why lift is done at the upper arm.
- **Walk steps (stepping up a block)** happen only when `anim == 0`
  (`avatar.lua:496`). Any move key stands you up from sit or lie
  (`tools.lua:117`, `:448`, `:715`).
- **Lying** (`ANIM_LIE`).
  - `lie_down(f)` (`tools.lua:684`) teleports you onto the bed cell + 1 and
    sets `ANIM_LIE`.
  - `Avatar:bed_pose()` (`avatar.lua:874`) finds the bed below with
    `Furn.under` (`furniture.lua:169`). It takes the bed's heading,
    `h + Furn.rz(rot) + π/2` (pillow at the far cell, +y), and puts the feet
    0.45 back from the origin at `z + BED_TOP + 0.2` (`BED_TOP = 0.55`,
    `furniture.lua:36`).
  - With no bed, you lie flat on the ground the way you face.
  - The clip is `idle` with no walk swing.
- **Carried** (`avatar.lua:421-441`, `:751-756`).
  - A carried avatar skips its own movement and is put at the carrier's
    `hold` point, z - 0.2. `hold` is computed at the end of every
    `Avatar:pose`, `CARRY_Z = 1.5` over the feet (`avatar.lua:842`).
  - It's laid with `Avatar.lie(carrier.heading + π/2)`, across the
    carrier's shoulders.
  - Name tag height uses `HELD_PLAYER_H = 0.6` (`carry.lua:21`).
  - The carrier's arms use the generic holding pose.
- **Ordering issue:** a carried avatar reads its carrier's `hold` from
  whenever the carrier last posed. If the carried avatar updates before the
  carrier in the same frame, it lags one frame behind.

### `Avatar.lie` and the Euler-order problem

The engine builds every entity's rotation as
`Quat::from_euler(EulerRot::XYZ, rx, ry, rz)` (`petrichor64
src/lua_ent.rs:131`, and the same in `ent_manager.rs:60`, `:974`). In glam
that is `Rx * Ry * Rz`: a vector is turned by `rz` first, then `ry`, then
`rx`, all about **world** axes. `rz` (facing) is applied *first*, so
tipping the model with `rx`/`ry` afterwards rotates about the world X/Y
axes, not about the body's own axes.

To lie on its back with the head toward `a`, the body would need "turn by
heading, then tip about its own side axis". That isn't expressible as
`(rx, ry, rz)` for arbitrary headings without converting a quaternion back
to XYZ Euler angles.

`Avatar.lie` (`avatar.lua:850`) therefore snaps `a` to a quarter turn and
uses four hand-worked `(rx, ry, rz)` triples. That's fine for beds, which
are always axis-aligned. A carried player, though, **snaps in 90° steps as
the carrier turns**.

**Bone overrides use a different order:** `BoneOverride::quat` is
`from_euler(EulerRot::ZYX, rz, ry, rx)` in bone-local space
(`skeleton.rs:112-114`). It rotates x first, then y, then z, and the result
is multiplied into the animated rotation. Don't assume the two conventions
match.

## 4. Known defects

1. **Hair and hat aren't tilted with the head when lying or carried.** The
   crown offset `f[5]` is added to world z (`character.lua:281-283`), so the
   hair floats "up" instead of sitting at the crown. It's only visible for
   heads whose `f[5] ≠ 0` (square, long, bean); round is 0. The fix is to
   rotate `(0, 0, f[5])` by the same XYZ Euler as the body, or parent hair
   and hat to the head with `lot()` (see §6).
2. **Face sprite `rot` rolls about the wrong axis.** `e.rx = p.rot` with
   `e.rz = facing` (`character.lua:305-306`). Under XYZ order, `rx` turns
   about world X after the facing turn. It's an in-plane roll only when
   facing is 0 or π. At other headings it tips the sprite out of the face's
   plane. The fix is to compose (roll about local X) then (facing about Z)
   as a quaternion and convert it to XYZ Euler, or parent the sprites to the
   head.
3. **Lying and carried characters have no face**: the sprites are hidden
   (`:302-304`), because their placement math (`:295-301`) only handles
   upright heads.
4. **The head ignores the head bone's rotation** (§2). Any head motion in
   the clips (sit, idle) is lost on the head, hair, hat and face. The engine
   can't return a bone's world rotation.
5. **Lying only along world axes** (§3). Carried players snap in 90° steps.
6. **Hair is modelled only for the round head** (`gen_character.py:292-312`).
   On the other heads it's only moved up or down by the crown difference.
   On square, long and bean (different widths and depths) the scalp clips
   into or floats off the head.
7. **Hair and hat are both drawn** with nothing hiding the hair under a hat,
   so they clip through each other (cap or beanie over long or spikes).
8. **The held item and hand ignore the hand bone's rotation** (`rz = facing`
   only, `character.lua:309-316`).
9. **The name tag** (`Avatar:top`, `avatar.lua:897`) uses the standing
   height even when lying.
10. **The `carry` clip is unused.** Arms are posed by hand at
    `AV_HOLD_ARMS`.
11. **The Android creator preview is a 2D approximation** and has drifted
    from the 3D models (§1).
12. **Emotes while lying** are still applied to the tipped body.
    `play_emote` only stands you up from sitting (`avatar.lua:158`).
13. **Lying pose values are tuned by eye and unverified in the live game.**
    That covers the four triples in `Avatar.lie`, the 0.9 offset at
    `avatar.lua:829` and the 0.45 and +0.2 at `:888-890`. Nobody has looked
    at them in the engine yet. The commit was `5fa202c`, untested beyond
    `luac -p`.

## 5. Engine and compiler constraints, and the workarounds in place

The engine is Petrichor64 (Rust), built from `~/projects/petrichor64-ws` if
it exists, else `~/projects/petrichor64` (`client/justfile:8-12`). Only
`~/projects/petrichor64` (branch `main`) exists on this machine right now.
Lua is compiled by **silt**, a custom Lua VM (`../silt-stable`). The full
list is in `client/README.md:311-380` and `~/projects/petrichor64/SILT-BUGS.md`.

The ones that matter here:

**Engine**
- **Web worker sync:** only the transform syncs after the creation frame,
  so looks are rebuilt, never retextured (§2).
- **Skinned models must be Z-up, and vertex colours are ignored.** Hence
  `gen_assets.py:585` converts the rig and bakes a palette texture. Missing
  inverse bind matrices are computed from the rest pose engine-side.
  Skinning was added to the engine on branch `feat/skinning` of
  petrichor64-ws.
- **No `mod()` on the web** (the worker can't reach the renderer), so all
  meshes ship as generated `.glb` files.
- **`ent:bone(name)`** returns the bone's world *position* and its
  *override* rotation only, never the animated world rotation
  (`lua_ent.rs:231-277`, `guide/entity.md:42-49`).
- **Two Euler conventions:** entities use XYZ about world axes; bone
  overrides use ZYX in local space (§3).
- **`dtile()` and every `hit.*` hang the VM on the web.** The worker waits
  for a reply that never comes. Not character-specific, but it rules out
  engine collision for avatars, so `Avatar.walkable` and `footing` are done
  by hand.
- **`clock()` panics on the web.** Use the engine's `now()`. The web clock
  can also return the same time for consecutive frames (`dt = 0`), and
  movement handles that (`avatar.lua:523`).
- **`lot(parent, child)` exists** (`petrichor64 guide/lot.md`,
  `src/command.rs:1236`). The child's matrix becomes `parent * child`
  (`src/ent.rs:185-191`). It isn't used in sosh. It's unverified on the web
  worker and in the snapshot path, and you can't parent to a bone, only to
  an entity.

**silt (Lua compiler/VM)**
- **#5 / #15:** a table constructor holding a local, assigned to a field or
  `t[#t+1]`, miscompiles. Always build the table into a `local` first.
  That's why `character.lua` writes `local t = {}; t[1] = …` everywhere, and
  `pos = {}` at `:251-254`.
- **Nested call arguments followed by locals** (SILT-BUGS #1, #14) call the
  wrong function. Hoist nested calls into locals: for example `local raw =
  flr(...)` at `character.lua:175` and `local model = Carry.model(...)` at
  `carry.lua:89`.
- **No anonymous functions inside functions** (#10). Use named functions
  only.
- **No exponent literals** (`1e9`). Avoid `^`.
- **`table.insert(t, pos, v)` and `table.remove(t, pos)`** on tables grown by
  index don't shift (#2, #3). Re-check against current silt before relying
  on them. The append form `table.insert(t, v)` is what the character code
  uses.
- **Negative-step `for` loops** were avoided (unverified in silt). Use
  `while`.
- **Returning multiple values** was distrusted in places (`world_clamp` and
  `Avatar:top` return tables). `Ships.frame_pos` and `Ships.to_world` do
  return several values and work.
- **`pairs()`** once yielded keys that had been set to nil (fixed upstream,
  per `client/README.md`). Don't depend on removal during iteration.
- **Script load order isn't guaranteed.** The top level only defines
  things, and everything runs from `main()`.
- Always run `luac -p` on edited scripts. It catches syntax errors but none
  of the silt miscompiles above.

## 6. What I'd try next

1. **Parent rigid pieces to the head entity with `lot()`.**
   - Make hair and hat children of the head with a local offset of
     `(0, 0, f[5])`, and the face sprites children with local
     `(f[1]+layer, p.x*f[3], f[2]+p.y*f[4])` and a local roll. That fixes
     defects 1, 2 and 3 in one move. Only the head entity is then posed by
     hand.
   - First verify on the **web build** that `lot` works from the worker and
     that the child keeps its local transform when the parent moves. The
     guide says the child is offset "on its current position and rotation",
     so set the local transform after grouping.
   - Also check that killing the parent doesn't leave the children behind.
2. **Or add a small Lua quaternion helper** (multiply, convert to XYZ
   Euler) and compose every rigid and sprite orientation as
   `R_body * R_local`. Pure Lua, no engine change, and it also fixes defect
   5 (lying at any heading, smooth carried rotation).
3. **Engine change (if allowed):** make `ent:bone(name)` also return the
   animated world rotation (quaternion or matrix), or add bone parenting
   (`lot(ent, child, "head")`). That fixes defects 4 and 8 properly.
4. **Per-head hair**, or generate the scalp from each head's ellipsoid in
   `gen_character.py` instead of the round head's. Add a `hat_hides` rule,
   for example a short scalp under any hat.
5. **Author real clips** (`lie`, `carried`, `wave`, …) in the source rig, or
   generate them in `gen_assets.py`, instead of tipping the whole entity.
   Clips are per glb, and every clothes glb copies the rig's clips
   (`gen_character.py:128 skinned_glb`), so a new clip must be added before
   the clothes are generated.
6. **Remove the duplicated lists.** Have the creator and Android read
   `catalog/0` (it's already served: `me.ex` puts `catalog` in "everything")
   instead of hard-coding the options. Consider rendering the Android
   preview from the same assets, or accept the drift.

## 7. Open questions

- Does `lot()` work on the web worker, and is there a way to un-group?
- Is the face meant to show while lying (eyes closed sprites?), or is
  hiding it acceptable?
- Should a carried player face the carrier's way (across the shoulders, as
  now) or along their arms?
- The user said they will replace the models and textures. Will the
  replacement rig keep the bone names (`head`, `hand.r`, `shoulder.*`,
  `arm.*`, `waist.*`, and the `RIG.stretch` list)? `avatar.lua` and
  `gen_character.py` hard-code them.
- `play_emote` while lying: stand up first, or forbid it?

## 8. Files at a glance

| File | Role |
|---|---|
| `server/lib/sosh/character.ex` | the spec, clean, catalog |
| `server/lib/sosh/me.ex:71-97` | save and broadcast |
| `client/scripts/character.lua` | build and pose the pieces |
| `client/scripts/character_rig.lua` | generated rig numbers |
| `client/scripts/avatar.lua:741-895` | per-frame pose, lie, bed pose, carried |
| `client/scripts/carry.lua` | who carries whom; `Carry.carrier_of` |
| `client/scripts/creator.lua` | in-game creator |
| `client/scripts/furniture.lua:36,169` | `BED_TOP`, `Furn.under` |
| `client/scripts/tools.lua:684,882,975` | lie down, sit toggle, `change_anim` |
| `client/tools/gen_character.py` | parts and rig numbers |
| `client/tools/gen_assets.py:585` | player rig conversion |
| `android/.../ui/CreatorScreen.kt` | Android creator (2D) |
| `~/projects/petrichor64/src/lua_ent.rs:127-141,231-277` | entity matrix, `ent:bone` |
| `~/projects/petrichor64/src/skeleton.rs:100-115` | bone override Euler order |
| `~/projects/petrichor64/guide/{entity,lot}.md` | API docs |
| `~/projects/petrichor64/SILT-BUGS.md` | compiler bugs |
