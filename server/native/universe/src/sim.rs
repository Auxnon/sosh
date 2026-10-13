//! The living part of the world: crops that grow on wall-clock time, cows
//! that wander the plaza and get shoved by players, and what players carry.
//!
//! Carrying is decided here: a player holds one thing, either a block the
//! sim deems carryable (`CARRYABLE`) or a cow, which then rides over their
//! head instead of wandering until it is put down.
//!
//! The block world itself belongs to `Sosh.World` (Elixir); the sim keeps a
//! read-only mirror of the chunks it needs for walking (`load_chunk`,
//! `set_block`). Coordinates follow the client and `Sosh.World`: Z-up, a block
//! at integer (x, y, z) spans x-0.5..x+0.5, y-0.5..y+0.5 and z..z+1, so
//! standing on it puts your feet at z + 1.

use std::collections::HashMap;

pub const CHUNK: i32 = 16;
pub const CHUNK_VOLUME: usize = (CHUNK * CHUNK * CHUNK) as usize;
const WATER: u8 = 6;
pub const POT: u8 = 7;
/// Blocks a player can pick up and carry.
pub const CARRYABLE: &[u8] = &[POT];
/// How far a player reaches to pick a cow up, from feet to the cow's middle;
/// blocks use `Sosh.World`'s reach check, the same 7.
const CARRY_REACH: f64 = 7.0;
/// A carried cow rides this far above its holder's feet: over their head.
pub const CARRY_Z: f64 = 1.5;

/// Ripe at this stage.
pub const RIPE: u8 = 3;

const COW_SPEED: f64 = 0.9; // tiles per second
const COW_TURN: f64 = 4.0; // radians per second
const COW_RADIUS: f64 = 0.55;
const PLAYER_RADIUS: f64 = 0.35;
const COW_LEASH: f64 = 13.0; // how far from home a cow wanders
const GRAVITY: f64 = 18.0;
const MOO_COOLDOWN_MS: i64 = 4000;
// a shove moves a cow at most this fast: a little over a player's walk, so a
// client claiming to stand deep inside a cow can't fling it
const PUSH_SPEED: f64 = 6.0; // tiles per second

pub struct Crop {
    pub planted_ms: i64,
    pub stage: u8,
}

pub struct Cow {
    pub id: u32,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub vz: f64,
    pub heading: f64,
    home: (f64, f64),
    target: Option<(f64, f64)>,
    idle_until_ms: i64,
    last_moo_ms: i64,
    sent: (f64, f64, f64, f64),
    pub carried: bool,
}

/// What a player has in their hands.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Held {
    Block(u8),
    Cow(u32),
}

struct Holder {
    held: Held,
    /// Where they last stood (feet), from the last tick or the pick up.
    at: (f64, f64, f64),
}

/// What changed in a tick, for broadcasting.
#[derive(Default)]
pub struct TickOut {
    /// (id, x, y, z, heading) for every cow that moved noticeably.
    pub cows: Vec<(u32, f64, f64, f64, f64)>,
    pub moos: Vec<u32>,
    /// ((x, y, z), stage) for every crop that grew.
    pub crops: Vec<((i32, i32, i32), u8)>,
}

pub struct Sim {
    chunks: HashMap<(i32, i32, i32), Box<[u8]>>,
    pub crops: HashMap<(i32, i32, i32), Crop>,
    pub cows: Vec<Cow>,
    holders: HashMap<String, Holder>,
    // cows lifted since the last tick, mooing about it
    lifted: Vec<u32>,
    next_cow: u32,
    stage_ms: i64,
    last_ms: Option<i64>,
    rng: u64,
}

impl Sim {
    pub fn new(stage_ms: i64, seed: u64) -> Self {
        Self {
            chunks: HashMap::new(),
            crops: HashMap::new(),
            cows: Vec::new(),
            holders: HashMap::new(),
            lifted: Vec::new(),
            next_cow: 1,
            stage_ms: stage_ms.max(1),
            last_ms: None,
            rng: seed | 1,
        }
    }

    // -- terrain mirror

    pub fn load_chunk(&mut self, key: (i32, i32, i32), blocks: &[u8]) -> bool {
        if blocks.len() != CHUNK_VOLUME {
            return false;
        }
        self.chunks.insert(key, blocks.into());
        true
    }

    /// Only applies inside loaded chunks; the sim never walks anywhere else.
    pub fn set_block(&mut self, x: i32, y: i32, z: i32, id: u8) {
        let (key, i) = locate(x, y, z);
        if let Some(c) = self.chunks.get_mut(&key) {
            c[i] = id;
        }
    }

    /// None outside the loaded chunks.
    pub fn block(&self, x: i32, y: i32, z: i32) -> Option<u8> {
        let (key, i) = locate(x, y, z);
        self.chunks.get(&key).map(|c| c[i])
    }

    /// Where feet rest at (x, y) for someone at height z: the top of the
    /// highest solid block at most one above their feet. None over water, the
    /// void, or unloaded ground. Mirrors the client's Blocks.ground.
    pub fn ground(&self, x: f64, y: f64, z: f64) -> Option<f64> {
        let cx = cell(x);
        let cy = cell(y);
        let mut bz = (z + 0.01).floor() as i32;
        let stop = bz - 24;
        while bz >= stop {
            match self.block(cx, cy, bz)? {
                0 => bz -= 1,
                WATER => return None,
                _ => return Some(bz as f64 + 1.0),
            }
        }
        None
    }

    /// Ground to stand on with two clear cells of headroom.
    pub fn walkable(&self, x: f64, y: f64, z: f64) -> bool {
        let Some(g) = self.ground(x, y, z) else {
            return false;
        };
        let (cx, cy, gz) = (cell(x), cell(y), g as i32);
        self.block(cx, cy, gz) == Some(0) && self.block(cx, cy, gz + 1) == Some(0)
    }

    // -- crops

    pub fn stage_at(&self, planted_ms: i64, now_ms: i64) -> u8 {
        let grown = (now_ms - planted_ms).max(0) / self.stage_ms;
        grown.min(RIPE as i64) as u8
    }

    /// False if something already grows there.
    pub fn plant(&mut self, pos: (i32, i32, i32), planted_ms: i64, now_ms: i64) -> bool {
        if self.crops.contains_key(&pos) {
            return false;
        }
        let stage = self.stage_at(planted_ms, now_ms);
        self.crops.insert(pos, Crop { planted_ms, stage });
        true
    }

    pub fn remove_crop(&mut self, pos: (i32, i32, i32)) -> Option<u8> {
        self.crops.remove(&pos).map(|c| c.stage)
    }

    // -- cows

    pub fn spawn_cow(&mut self, x: f64, y: f64) -> u32 {
        let id = self.next_cow;
        self.next_cow += 1;
        let z = self.ground(x, y, 8.0).unwrap_or(0.0);
        let heading = self.rand() * std::f64::consts::TAU;
        self.cows.push(Cow {
            id,
            x,
            y,
            z,
            vz: 0.0,
            heading,
            home: (x, y),
            target: None,
            idle_until_ms: 0,
            last_moo_ms: i64::MIN / 2,
            sent: (f64::NAN, 0.0, 0.0, 0.0),
            carried: false,
        });
        id
    }

    // -- carrying

    pub fn carryable(id: u8) -> bool {
        CARRYABLE.contains(&id)
    }

    /// What `holder` carries, if anything.
    pub fn held(&self, holder: &str) -> Option<Held> {
        self.holders.get(holder).map(|h| h.held)
    }

    /// Everyone carrying something.
    pub fn holding(&self) -> impl Iterator<Item = (&String, Held)> {
        self.holders.iter().map(|(k, h)| (k, h.held))
    }

    /// `holder`, standing at `at`, lifts the block `id` (the caller takes it
    /// out of the world once this agrees).
    pub fn pick_block(
        &mut self,
        holder: &str,
        at: (f64, f64, f64),
        id: u8,
    ) -> Result<(), &'static str> {
        if self.holders.contains_key(holder) {
            return Err("hands_full");
        }
        if !Self::carryable(id) {
            return Err("cannot_carry");
        }
        let held = Held::Block(id);
        self.holders.insert(holder.to_string(), Holder { held, at });
        Ok(())
    }

    /// `holder`, standing at `at`, lifts cow `id` over their head.
    pub fn pick_cow(
        &mut self,
        holder: &str,
        at: (f64, f64, f64),
        id: u32,
    ) -> Result<(), &'static str> {
        if self.holders.contains_key(holder) {
            return Err("hands_full");
        }
        let Some(cow) = self.cows.iter_mut().find(|c| c.id == id) else {
            return Err("no_such_cow");
        };
        if cow.carried {
            return Err("already_carried");
        }
        let (dx, dy, dz) = (cow.x - at.0, cow.y - at.1, cow.z + 0.5 - at.2);
        if dx * dx + dy * dy + dz * dz > CARRY_REACH * CARRY_REACH {
            return Err("out_of_reach");
        }
        cow.carried = true;
        cow.target = None;
        cow.vz = 0.0;
        (cow.x, cow.y, cow.z) = (at.0, at.1, at.2 + CARRY_Z);
        self.lifted.push(id);
        self.holders.insert(
            holder.to_string(),
            Holder {
                held: Held::Cow(id),
                at,
            },
        );
        Ok(())
    }

    /// `holder` puts what they carry into the cell `pos`. `free` is whether
    /// the world has room for a block there (no block, no crop): the caller
    /// knows the whole world, the sim only its mirror. A cow also needs
    /// ground to stand on. On success they're empty-handed and it's theirs
    /// to put in the world if it's a block.
    pub fn put_down(
        &mut self,
        holder: &str,
        pos: (i32, i32, i32),
        free: bool,
    ) -> Result<Held, &'static str> {
        let Some(h) = self.holders.get(holder) else {
            return Err("hands_empty");
        };
        if !free {
            return Err("occupied");
        }
        let held = h.held;
        if let Held::Cow(id) = held {
            let (x, y, z) = (pos.0 as f64, pos.1 as f64, pos.2 as f64);
            if !self.walkable(x, y, z) {
                return Err("no_room_for_a_cow");
            }
            let ground = self.ground(x, y, z).unwrap_or(z);
            self.land_cow(id, x, y, ground);
        }
        self.holders.remove(holder);
        Ok(held)
    }

    /// `holder` left: a cow is set down where they last stood (or sent home
    /// if it can't stand there). Returns what they held and the cell they
    /// stood in, where the caller can try to put a block back.
    pub fn release(&mut self, holder: &str) -> Option<(Held, (i32, i32, i32))> {
        let h = self.holders.remove(holder)?;
        let (x, y, z) = h.at;
        if let Held::Cow(id) = h.held {
            let spot = match self.ground(x, y, z) {
                Some(g) if self.walkable(x, y, z) => Some((x, y, g)),
                _ => None,
            };
            let (cx, cy, cz) = match spot {
                Some(s) => s,
                None => {
                    let (hx, hy) = self
                        .cows
                        .iter()
                        .find(|c| c.id == id)
                        .map_or((0.0, 0.0), |c| c.home);
                    (hx, hy, self.ground(hx, hy, 8.0).unwrap_or(0.0))
                }
            };
            self.land_cow(id, cx, cy, cz);
        }
        Some((h.held, (cell(x), cell(y), (z + 0.01).floor() as i32)))
    }

    /// Back on its feet at (x, y), falling from where it was carried down to
    /// height `z`.
    fn land_cow(&mut self, id: u32, x: f64, y: f64, z: f64) {
        let now = self.last_ms.unwrap_or(0);
        if let Some(cow) = self.cows.iter_mut().find(|c| c.id == id) {
            cow.carried = false;
            cow.x = x;
            cow.y = y;
            // it drops from overhead under gravity; never start below ground
            cow.z = cow.z.max(z);
            cow.vz = 0.0;
            cow.target = None;
            cow.idle_until_ms = now + 1500;
        }
    }

    // -- the tick

    /// Advance to `now_ms` (wall clock). `players` are (id, feet position).
    pub fn tick(&mut self, now_ms: i64, players: &[(String, f64, f64, f64)]) -> TickOut {
        let mut out = TickOut::default();
        out.moos.append(&mut self.lifted);
        let dt = match self.last_ms {
            // a long stall (or the first tick) shouldn't teleport anything
            Some(last) => ((now_ms - last) as f64 / 1000.0).clamp(0.0, 0.25),
            None => 0.0,
        };
        self.last_ms = Some(now_ms);

        let stage_ms = self.stage_ms;
        for (pos, crop) in self.crops.iter_mut() {
            let stage = (((now_ms - crop.planted_ms).max(0) / stage_ms).min(RIPE as i64)) as u8;
            if stage != crop.stage {
                crop.stage = stage;
                out.crops.push((*pos, stage));
            }
        }

        // carried cows ride over their holders
        for (id, x, y, z) in players {
            if let Some(h) = self.holders.get_mut(id) {
                h.at = (*x, *y, *z);
                if let Held::Cow(cid) = h.held {
                    if let Some(cow) = self.cows.iter_mut().find(|c| c.id == cid) {
                        (cow.x, cow.y, cow.z) = (*x, *y, *z + CARRY_Z);
                    }
                }
            }
        }

        let feet: Vec<(f64, f64, f64)> = players.iter().map(|&(_, x, y, z)| (x, y, z)).collect();
        for i in 0..self.cows.len() {
            if !self.cows[i].carried {
                self.step_cow(i, now_ms, dt, &feet, &mut out);
            }
        }
        self.separate_cows();

        for cow in self.cows.iter_mut() {
            let (sx, sy, sz, sh) = cow.sent;
            let moved = sx.is_nan()
                || (cow.x - sx).abs() > 0.01
                || (cow.y - sy).abs() > 0.01
                || (cow.z - sz).abs() > 0.01
                || angle_diff(sh, cow.heading).abs() > 0.03;
            if moved {
                cow.sent = (cow.x, cow.y, cow.z, cow.heading);
                out.cows.push((cow.id, cow.x, cow.y, cow.z, cow.heading));
            }
        }
        out
    }

    fn step_cow(
        &mut self,
        i: usize,
        now_ms: i64,
        dt: f64,
        players: &[(f64, f64, f64)],
        out: &mut TickOut,
    ) {
        // pick something to do
        if self.cows[i].target.is_none() && now_ms >= self.cows[i].idle_until_ms {
            if self.rand() < 0.6 {
                let (hx, hy) = self.cows[i].home;
                let a = self.rand() * std::f64::consts::TAU;
                let r = self.rand().sqrt() * COW_LEASH;
                let (tx, ty) = (hx + a.cos() * r, hy + a.sin() * r);
                if self.walkable(tx, ty, self.cows[i].z) {
                    self.cows[i].target = Some((tx, ty));
                }
            }
            if self.cows[i].target.is_none() {
                // graze a while
                let wait = 2000.0 + self.rand() * 5000.0;
                self.cows[i].idle_until_ms = now_ms + wait as i64;
            }
        }

        let mut dx = 0.0;
        let mut dy = 0.0;

        // walk toward the target
        if let Some((tx, ty)) = self.cows[i].target {
            let cow = &mut self.cows[i];
            let (ex, ey) = (tx - cow.x, ty - cow.y);
            let dist = (ex * ex + ey * ey).sqrt();
            if dist < 0.15 {
                cow.target = None;
                cow.idle_until_ms = now_ms + 1500;
            } else {
                let want = ey.atan2(ex);
                let turn = angle_diff(cow.heading, want);
                let max = COW_TURN * dt;
                cow.heading = wrap(cow.heading + turn.clamp(-max, max));
                // walk once roughly facing the way
                if turn.abs() < 0.8 {
                    let step = (COW_SPEED * dt).min(dist);
                    dx += cow.heading.cos() * step;
                    dy += cow.heading.sin() * step;
                }
            }
        }

        // shoved by anyone overlapping it
        let mut pushed = false;
        let (mut px_sum, mut py_sum) = (0.0, 0.0);
        let reach = COW_RADIUS + PLAYER_RADIUS;
        for &(px, py, pz) in players {
            let cow = &self.cows[i];
            if (pz - cow.z).abs() > 1.5 {
                continue;
            }
            let (ox, oy) = (cow.x + dx - px, cow.y + dy - py);
            let d = (ox * ox + oy * oy).sqrt();
            if d >= reach {
                continue;
            }
            let (nx, ny) = if d > 0.0001 {
                (ox / d, oy / d)
            } else {
                (cow.heading.cos(), cow.heading.sin())
            };
            let overlap = reach - d;
            px_sum += nx * overlap;
            py_sum += ny * overlap;
            pushed = true;
        }
        let len = (px_sum * px_sum + py_sum * py_sum).sqrt();
        let max = PUSH_SPEED * dt;
        if len > max {
            px_sum *= max / len;
            py_sum *= max / len;
        }
        dx += px_sum;
        dy += py_sum;
        if pushed {
            let cow = &mut self.cows[i];
            // stop and think about it
            cow.target = None;
            cow.idle_until_ms = now_ms + 1200;
            if now_ms - cow.last_moo_ms > MOO_COOLDOWN_MS {
                cow.last_moo_ms = now_ms;
                out.moos.push(cow.id);
            }
        }

        self.move_cow(i, dx, dy, dt);
    }

    /// Slide along walls: each axis separately, refused where not walkable.
    fn move_cow(&mut self, i: usize, dx: f64, dy: f64, dt: f64) {
        let (x, y, z) = (self.cows[i].x, self.cows[i].y, self.cows[i].z);
        let mut nx = x;
        let mut ny = y;
        if dx != 0.0 && self.walkable(x + dx, y, z) {
            nx = x + dx;
        }
        if dy != 0.0 && self.walkable(nx, y + dy, z) {
            ny = y + dy;
        }
        if (nx != x + dx || ny != y + dy) && self.cows[i].target.is_some() {
            // walked into something: pick another plan
            self.cows[i].target = None;
        }
        let ground = self.ground(nx, ny, z);
        let cow = &mut self.cows[i];
        cow.x = nx;
        cow.y = ny;
        if let Some(g) = ground {
            if g >= cow.z {
                cow.z = g;
                cow.vz = 0.0;
            } else {
                cow.vz -= GRAVITY * dt;
                cow.z = (cow.z + cow.vz * dt).max(g);
                if cow.z == g {
                    cow.vz = 0.0;
                }
            }
        }
    }

    fn separate_cows(&mut self) {
        let n = self.cows.len();
        for a in 0..n {
            for b in (a + 1)..n {
                let (ox, oy) = (
                    self.cows[b].x - self.cows[a].x,
                    self.cows[b].y - self.cows[a].y,
                );
                let d = (ox * ox + oy * oy).sqrt();
                let min = COW_RADIUS * 2.0;
                let carried = self.cows[a].carried || self.cows[b].carried;
                if carried
                    || d >= min
                    || d < 0.0001
                    || (self.cows[a].z - self.cows[b].z).abs() > 1.5
                {
                    continue;
                }
                let push = (min - d) / 2.0;
                let (nx, ny) = (ox / d * push, oy / d * push);
                self.move_cow(a, -nx, -ny, 0.0);
                self.move_cow(b, nx, ny, 0.0);
            }
        }
    }

    /// xorshift64*, uniform in [0, 1).
    fn rand(&mut self) -> f64 {
        let mut x = self.rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.rng = x;
        (x.wrapping_mul(0x2545F4914F6CDD1D) >> 11) as f64 / (1u64 << 53) as f64
    }
}

pub fn cell(v: f64) -> i32 {
    (v + 0.5).floor() as i32
}

/// Chunk key and index within it (x fastest, then y, then z), as Sosh.World.
fn locate(x: i32, y: i32, z: i32) -> ((i32, i32, i32), usize) {
    let key = (
        x.div_euclid(CHUNK),
        y.div_euclid(CHUNK),
        z.div_euclid(CHUNK),
    );
    let i = x.rem_euclid(CHUNK) + y.rem_euclid(CHUNK) * CHUNK + z.rem_euclid(CHUNK) * CHUNK * CHUNK;
    (key, i as usize)
}

fn wrap(a: f64) -> f64 {
    let tau = std::f64::consts::TAU;
    (a + std::f64::consts::PI).rem_euclid(tau) - std::f64::consts::PI
}

/// Signed shortest turn from `a` to `b`.
fn angle_diff(a: f64, b: f64) -> f64 {
    wrap(b - a)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A flat grass floor: chunk (0, 0, -1) full of grass at z = -1, so the
    /// standing height is 0 across x, y in 0..16.
    fn flat() -> Sim {
        let mut s = Sim::new(1000, 42);
        let mut floor = vec![0u8; CHUNK_VOLUME];
        for i in 0..(CHUNK * CHUNK) as usize {
            floor[i + 15 * 256] = 1;
        }
        s.load_chunk((0, 0, -1), &floor);
        s.load_chunk((0, 0, 0), &vec![0u8; CHUNK_VOLUME]);
        s
    }

    /// A player called "p" standing at (x, y, z).
    fn p(x: f64, y: f64, z: f64) -> (String, f64, f64, f64) {
        ("p".to_string(), x, y, z)
    }

    #[test]
    fn ground_and_walls() {
        let mut s = flat();
        assert_eq!(s.ground(4.0, 4.0, 0.0), Some(0.0));
        assert!(s.walkable(4.0, 4.0, 0.0));
        // unloaded is never walkable
        assert!(!s.walkable(-4.0, 4.0, 0.0));
        s.set_block(5, 4, 0, 3);
        assert_eq!(s.ground(5.0, 4.0, 0.0), Some(1.0)); // a step
        s.set_block(5, 4, 1, 3);
        assert!(!s.walkable(5.0, 4.0, 0.0)); // a wall
    }

    #[test]
    fn crops_grow_on_the_clock() {
        let mut s = flat();
        assert!(s.plant((3, 3, 0), 10_000, 10_000));
        assert!(!s.plant((3, 3, 0), 10_000, 10_000));
        assert!(s.tick(10_500, &[]).crops.is_empty());
        assert_eq!(s.tick(11_000, &[]).crops, vec![((3, 3, 0), 1)]);
        // a stall jumps straight to the right stage, and ripeness caps
        assert_eq!(s.tick(99_000, &[]).crops, vec![((3, 3, 0), RIPE)]);
        assert_eq!(s.remove_crop((3, 3, 0)), Some(RIPE));
        // planted long ago (loaded from the database): already ripe
        assert!(s.plant((4, 4, 0), 0, 99_000));
        assert_eq!(s.crops[&(4, 4, 0)].stage, RIPE);
    }

    #[test]
    fn a_player_shoves_a_cow() {
        let mut s = flat();
        let id = s.spawn_cow(8.0, 8.0);
        s.cows[0].idle_until_ms = i64::MAX; // stand still
        s.tick(0, &[]);
        let out = s.tick(100, &[p(7.8, 8.0, 0.0)]);
        assert!(s.cows[0].x > 8.5, "pushed along +x: {}", s.cows[0].x);
        assert!(
            s.cows[0].x <= 8.0 + PUSH_SPEED * 0.1 + 1e-9,
            "too fast: {}",
            s.cows[0].x
        );
        assert!((s.cows[0].y - 8.0).abs() < 0.001);
        assert_eq!(out.moos, vec![id]);
        // no second moo straight away
        let out = s.tick(200, &[p(s.cows[0].x - 0.3, 8.0, 0.0)]);
        assert!(out.moos.is_empty());
    }

    #[test]
    fn cows_wander_but_stay_on_ground() {
        let mut s = flat();
        for _ in 0..3 {
            s.spawn_cow(8.0, 8.0);
        }
        let mut t = 0;
        for _ in 0..3000 {
            t += 100;
            s.tick(t, &[]);
        }
        for c in &s.cows {
            assert!(
                s.walkable(c.x, c.y, c.z),
                "cow {} off the floor at {},{}",
                c.id,
                c.x,
                c.y
            );
            assert_eq!(c.z, 0.0);
        }
        // and they spread out rather than stacking
        let (a, b) = (&s.cows[0], &s.cows[1]);
        assert!((a.x - b.x).hypot(a.y - b.y) > 0.5);
    }

    #[test]
    fn pushed_into_a_wall_stays_out() {
        let mut s = flat();
        for y in 0..16 {
            s.set_block(10, y, 0, 3);
            s.set_block(10, y, 1, 3);
        }
        s.spawn_cow(9.0, 8.0);
        s.cows[0].idle_until_ms = i64::MAX;
        s.tick(0, &[]);
        for t in 1..20 {
            let x = s.cows[0].x - 0.5;
            s.tick(t * 100, &[p(x, 8.0, 0.0)]);
        }
        assert!(s.cows[0].x < 9.5, "went through the wall: {}", s.cows[0].x);
    }

    #[test]
    fn only_carryable_blocks_and_one_thing_at_a_time() {
        let mut s = flat();
        let at = (4.0, 4.0, 0.0);
        assert_eq!(s.pick_block("p", at, 3), Err("cannot_carry"));
        assert_eq!(s.held("p"), None);
        assert_eq!(s.pick_block("p", at, POT), Ok(()));
        assert_eq!(s.held("p"), Some(Held::Block(POT)));
        assert_eq!(s.pick_block("p", at, POT), Err("hands_full"));
        // the world has no room there: still holding it
        assert_eq!(s.put_down("p", (5, 4, 0), false), Err("occupied"));
        assert_eq!(s.put_down("p", (5, 4, 0), true), Ok(Held::Block(POT)));
        assert_eq!(s.put_down("p", (5, 4, 0), true), Err("hands_empty"));
    }

    #[test]
    fn a_carried_cow_rides_overhead_then_is_set_down() {
        let mut s = flat();
        let id = s.spawn_cow(8.0, 8.0);
        s.tick(0, &[]);
        assert_eq!(s.pick_cow("p", (1.0, 1.0, 0.0), id), Err("out_of_reach"));
        assert_eq!(s.pick_cow("p", (7.0, 8.0, 0.0), id), Ok(()));
        assert_eq!(s.pick_cow("q", (7.0, 8.0, 0.0), id), Err("already_carried"));
        // it moos about it, follows its holder and nobody shoves it
        let out = s.tick(100, &[p(5.0, 6.0, 0.0), ("q".to_string(), 5.2, 6.0, 0.0)]);
        assert_eq!(out.moos, vec![id]);
        let c = &s.cows[0];
        assert_eq!((c.x, c.y, c.z), (5.0, 6.0, CARRY_Z));
        // a cow needs somewhere to stand
        s.set_block(6, 6, 0, 3);
        s.set_block(6, 6, 1, 3);
        assert_eq!(s.put_down("p", (6, 6, 0), true), Err("no_room_for_a_cow"));
        assert_eq!(s.put_down("p", (6, 7, 0), true), Ok(Held::Cow(id)));
        // and falls back to the ground
        for t in 2..20 {
            s.tick(t * 100, &[]);
        }
        let c = &s.cows[0];
        assert!(!c.carried);
        assert_eq!(c.z, 0.0);
        assert!(s.walkable(c.x, c.y, c.z));
    }

    #[test]
    fn leaving_lets_go() {
        let mut s = flat();
        let id = s.spawn_cow(8.0, 8.0);
        s.tick(0, &[]);
        assert_eq!(s.pick_cow("p", (7.0, 8.0, 0.0), id), Ok(()));
        s.tick(100, &[p(3.2, 2.9, 0.0)]);
        assert_eq!(s.release("p"), Some((Held::Cow(id), (3, 3, 0))));
        assert_eq!((s.cows[0].x, s.cows[0].y), (3.2, 2.9));
        assert_eq!(s.release("p"), None);
        assert_eq!(s.pick_block("p", (2.0, 2.0, 0.0), POT), Ok(()));
        assert_eq!(s.release("p"), Some((Held::Block(POT), (2, 2, 0))));
    }
}
