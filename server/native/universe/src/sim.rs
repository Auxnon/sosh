//! A universe: one cell of the grid of worlds. It owns its blocks (floating
//! islands, see `terrain`), what grows on them, the cows that wander them,
//! the furniture built on them and what's inside it, the airships between
//! them, the helpers who carry heavy things, and what everyone holds.
//!
//! **Frames.** A cell is in the world, or in a ship's own frame (`on`, the
//! ship's id; 0 is the world). Ships are blocks too: whatever can be built
//! or set down in the world can be on a ship, and goes where it goes.
//! Players report where they stand in whichever frame they're on, so
//! someone on deck moves with the ship.
//!
//! **Time.** A universe counts world ticks (`TICK_MS` each) while someone
//! is in it. When everyone has left it sleeps: only `ambient` systems run
//! (ships fly home, a universe without one builds one, helpers and cows go
//! home). Growth doesn't tick at all; on waking it catches up on every tick
//! it slept through at once, since crops grow on the tick count alone.
//!
//! **Hands.** A player holds one thing: a carryable block, a cow, or a
//! piece of furniture. Furniture that takes two (`Kind::carriers`) stays put
//! when grabbed until a second player, or a helper, takes the other end.
//!
//! **Bags.** Players' bags belong to the caller (they follow players from
//! one universe to the next). Anything that gives or takes items is passed
//! the bag and changes it in place.
//!
//! Changes come out as `Event`s (`drain_events`) for the caller to
//! broadcast; continuous motion (cows, ships, helpers) comes out of `tick`.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::furniture::{self, Furniture, Grip, Site};
use crate::items::{self, Slot};
use crate::ships::{self, Helm, Pose, Ship, Side};
use crate::terrain::{
    self, cell, Island, Pos, Rng, Terrain, AIR, DIRT, FURNITURE, GRASS, POT, SCAFFOLD,
    WATER,
};

/// A world tick; growth counts these.
pub const TICK_MS: i64 = 100;
/// Blocks a player can pick up and carry.
pub const CARRYABLE: &[u8] = &[POT];
/// How far a player reaches to pick up or open something, feet to middle;
/// cells use the caller's reach check, the same 7.
pub const REACH: f64 = 7.0;
/// A carried thing rides this far above its holder's feet: over their head.
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

/// A grip on furniture that hasn't lifted yet lets go once its holder is
/// this far away: just past the reach they took hold from.
const GRIP_SLACK: f64 = REACH + 1.0;
/// Carriers further apart than this drop what they carry.
const CARRY_SPREAD: f64 = 5.0;
const HELPER_SPEED: f64 = 5.5; // a little faster than a player walks
const HELPER_CALL: f64 = 40.0; // how far away a helper hears you
const HELPER_GAP: f64 = 2.0; // how far from the player a helper carries
const HELPER_PATIENCE_MS: i64 = 30_000;
/// A pilot who hasn't been seen this long leaves the helm.
const PILOT_GONE_MS: i64 = 10_000;

pub struct Crop {
    /// The world tick it was planted at; before the universe began, for
    /// crops older than it.
    pub planted: i64,
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
    sent: Option<(f64, f64, f64, f64)>,
    pub carried: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Task {
    Idle,
    /// Walking over to take the other end of a piece of furniture.
    Fetch(u32),
    Carry(u32),
    Home,
}

/// A helper: someone who lives on the home island and takes the other end
/// of heavy furniture when asked.
pub struct Helper {
    pub id: u32,
    pub name: &'static str,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    vz: f64,
    pub heading: f64,
    home: (f64, f64, f64),
    pub task: Task,
    task_ms: i64,
    sent: Option<(f64, f64, f64, f64)>,
}

/// What a player has in their hands.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Held {
    Block(u8),
    Cow(u32),
    Furniture(u32),
}

struct Holder {
    held: Held,
    /// Where they last stood (feet), from the last tick or the pick up.
    at: (f64, f64, f64),
}

/// Something changed, for everyone in the universe to hear about.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Block(Pos, u8),
    /// A block of a ship's changed.
    ShipBlock(u32, Pos, u8),
    /// A ship appeared or changed hands at the helm.
    Ship(u32),
    /// A crop's stage, None once it's gone.
    Crop(Pos, Option<u8>),
    /// What a player holds now.
    Carry(String, Option<Held>),
    /// A piece of furniture changed (moved, lifted, its contents) or is gone.
    Furniture(u32),
    FurnitureGone(u32),
    Site(u32),
    SiteGone(u32),
    /// A ship flew into the neighbouring universe on `side`, with everyone
    /// and everything aboard.
    Departed(Box<Cargo>, Side),
}

/// A ship leaving for the next universe, and all it takes along.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Cargo {
    pub ship: Ship,
    pub furniture: Vec<Furniture>,
    pub sites: Vec<Site>,
    /// Who's aboard, and where they stand on it (feet, its frame).
    pub riders: Vec<(String, (f64, f64, f64))>,
}

/// Someone in the universe, as the caller tracks them: their feet, in the
/// world or (`on` a ship) in that ship's frame.
#[derive(Clone, Debug, PartialEq)]
pub struct Walker {
    pub id: String,
    pub on: u32,
    pub at: (f64, f64, f64),
}

/// Motion this tick, for broadcasting.
#[derive(Default)]
pub struct TickOut {
    /// (id, x, y, z, heading) for every cow that moved noticeably.
    pub cows: Vec<(u32, f64, f64, f64, f64)>,
    pub moos: Vec<u32>,
    /// [id, x, y, z, heading, vx, vy, vz, spin] for every ship that moved.
    pub ships: Vec<Vec<f64>>,
    pub helpers: Vec<(u32, f64, f64, f64, f64)>,
}

/// What `grab` did with the furniture.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Grabbed {
    /// Packed into the bag.
    Pocketed,
    /// Holding one end; it needs someone on the other.
    Gripped,
    Lifted,
}

/// What a universe keeps between runs, beside its changed chunks.
#[derive(Serialize, Deserialize, Default)]
pub struct Saved {
    pub world_tick: i64,
    /// When it was saved (wall clock ms): sleeping since then.
    pub at_ms: i64,
    pub crops: Vec<(Pos, i64)>,
    #[serde(deserialize_with = "readable")]
    pub furniture: Vec<Furniture>,
    #[serde(deserialize_with = "readable")]
    pub sites: Vec<Site>,
    #[serde(default, deserialize_with = "readable")]
    pub ships: Vec<Ship>,
    pub next_id: u32,
}

/// The entries of a saved list that still read: one saved in an older
/// shape is dropped rather than losing the whole universe's state.
fn readable<'de, D, T>(d: D) -> Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let all: Vec<serde_json::Value> = Vec::deserialize(d)?;
    Ok(all
        .into_iter()
        .filter_map(|v| serde_json::from_value(v).ok())
        .collect())
}

pub type Bag = Vec<Slot>;
type R<T> = Result<T, &'static str>;

pub struct Sim {
    pub terrain: Terrain,
    pub islands: Vec<Island>,
    pub crops: HashMap<Pos, Crop>,
    pub cows: Vec<Cow>,
    pub furniture: HashMap<u32, Furniture>,
    pub sites: HashMap<u32, Site>,
    pub ships: Vec<Ship>,
    pub helpers: Vec<Helper>,
    holders: HashMap<String, Holder>,
    // cows lifted since the last tick, mooing about it
    lifted: Vec<u32>,
    events: Vec<Event>,
    next_id: u32,
    next_cow: u32,
    stage_ms: i64,
    pub world_tick: i64,
    tick_acc_ms: i64,
    last_ms: Option<i64>,
    asleep_since: Option<i64>,
    /// Which sides have a neighbour to fly into, by `Side::index`.
    open: [bool; 4],
    /// People who flew in aboard a ship and haven't arrived yet: the ship,
    /// and where on it they stand.
    arrivals: HashMap<String, (u32, (f64, f64, f64))>,
    rng: Rng,
}

const HELPER_NAMES: [&str; 2] = ["Porter", "Hob"];

impl Sim {
    /// An empty universe: no islands, nobody.
    pub fn empty(stage_ms: i64, seed: u64) -> Self {
        Sim {
            terrain: Terrain::generate(&[]),
            islands: Vec::new(),
            crops: HashMap::new(),
            cows: Vec::new(),
            furniture: HashMap::new(),
            sites: HashMap::new(),
            ships: Vec::new(),
            helpers: Vec::new(),
            holders: HashMap::new(),
            lifted: Vec::new(),
            events: Vec::new(),
            next_id: 1,
            next_cow: 1,
            stage_ms: stage_ms.max(1),
            world_tick: 0,
            tick_acc_ms: 0,
            last_ms: None,
            asleep_since: None,
            open: [false; 4],
            arrivals: HashMap::new(),
            rng: Rng::new(seed),
        }
    }

    /// Universe (gx, gy) as generated from `seed`: its islands, a helper on
    /// the home island and an airship docked beside it.
    pub fn new(gx: i32, gy: i32, seed: u64, stage_ms: i64) -> Self {
        let islands = terrain::islands(gx, gy, seed);
        let mut s = Sim::empty(stage_ms, seed ^ 0x5eed);
        s.terrain = Terrain::generate(&islands);
        s.islands = islands;
        if let Some(home) = s.islands.first().cloned() {
            let feet = home.top as f64 + 1.0;
            let spots = [(1.5, 1.5), (-2.0, 2.5)];
            for (n, name) in HELPER_NAMES
                .iter()
                .take(if home.plaza { 2 } else { 1 })
                .enumerate()
            {
                let (dx, dy) = spots[n];
                let at = (home.x as f64 + dx, home.y as f64 + dy, feet);
                let id = s.new_id();
                s.helpers.push(Helper {
                    id,
                    name: *name,
                    x: at.0,
                    y: at.1,
                    z: at.2,
                    vz: 0.0,
                    heading: 0.0,
                    home: at,
                    task: Task::Idle,
                    task_ms: 0,
                    sent: None,
                });
            }
            if let Some(dock) = s.dock_by(&home) {
                let id = s.new_id();
                s.ships.push(Ship::standard(id, dock));
            }
        }
        s.terrain.take_dirty();
        s
    }

    fn new_id(&mut self) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Room for a ship beside `island`, its deck level with the grass and
    /// its side to the shore, close enough to step aboard from it; clear of
    /// the other ships and their berths.
    fn dock_by(&self, island: &Island) -> Option<Pose> {
        let z = island.top as f64 + 1.0;
        let probe = Ship::standard(0, Pose::default());
        let lim = terrain::HALF as f64 - probe.radius() - 1.0;
        let berths: Vec<Ship> = self
            .ships
            .iter()
            .map(|s| Ship::new(0, s.blocks.clone(), s.dock))
            .collect();
        let others: Vec<&Ship> = self.ships.iter().chain(berths.iter()).collect();
        let quarter = std::f64::consts::FRAC_PI_2;
        for step in 0..16 {
            // east first, then around
            let a = step as f64 * std::f64::consts::TAU / 16.0;
            let (c, s) = (a.cos(), a.sin());
            // its port side (+y) to the island, square to the world's cells
            // and on whole ones, so its deck meets the shore with no gap
            let h = ships::wrap(((a + quarter) / quarter).round() * quarter);
            // outward from the middle to the first spot clear of the island
            let mut d = island.r * 0.7;
            while d < island.r * 1.3 + 8.0 {
                let (x, y) = (
                    (island.x as f64 + c * d).round(),
                    (island.y as f64 + s * d).round(),
                );
                if x.abs() > lim || y.abs() > lim {
                    break;
                }
                let pose = Pose::new(x, y, z, h);
                if !probe.collides(&pose, &self.terrain, &[]) {
                    if probe.collides(&pose, &self.terrain, &others) {
                        break;
                    }
                    return Some(pose);
                }
                d += 0.4;
            }
        }
        None
    }

    /// A free berth by the home island.
    fn home_dock(&self) -> Option<Pose> {
        let home = self.islands.first()?;
        self.dock_by(home)
    }

    pub fn set_open(&mut self, open: [bool; 4]) {
        self.open = open;
    }

    pub fn open(&self) -> [bool; 4] {
        self.open
    }

    pub fn drain_events(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.events)
    }

    pub fn ship(&self, id: u32) -> Option<&Ship> {
        self.ships.iter().find(|s| s.id == id)
    }

    fn ship_mut(&mut self, id: u32) -> Option<&mut Ship> {
        self.ships.iter_mut().find(|s| s.id == id)
    }

    /// The block at `p` in frame `on` (0 the world, else a ship's): None
    /// outside the universe, past what a ship can hold, or with no such ship.
    pub fn get(&self, on: u32, p: Pos) -> Option<u8> {
        if on == 0 {
            return self.terrain.get(p.0, p.1, p.2);
        }
        let s = self.ship(on)?;
        ships::within(p).then(|| s.get(p))
    }

    fn set_block(&mut self, on: u32, p: Pos, id: u8) {
        if on == 0 {
            if self.terrain.set(p.0, p.1, p.2, id) {
                self.events.push(Event::Block(p, id));
            }
        } else if let Some(s) = self.ship_mut(on) {
            if s.set(p, id) {
                self.events.push(Event::ShipBlock(on, p, id));
            }
        }
    }

    /// Room for a block or furniture at `p` in frame `on`: air or water,
    /// nothing growing; on a ship, nothing it would bump into there.
    pub fn free(&self, on: u32, p: Pos) -> bool {
        if !matches!(self.get(on, p), Some(AIR) | Some(WATER)) {
            return false;
        }
        if on == 0 {
            return !self.crops.contains_key(&p);
        }
        let Some(s) = self.ship(on) else {
            return false;
        };
        let others: Vec<&Ship> = self.ships.iter().filter(|o| o.id != on).collect();
        s.room_for(p, &self.terrain, &others)
    }

    /// Frame `on`'s point `l`, in the world.
    pub fn world_of(&self, on: u32, l: (f64, f64, f64)) -> Option<(f64, f64, f64)> {
        if on == 0 {
            return Some(l);
        }
        self.ship(on).map(|s| s.pose.to_world(l))
    }

    /// Which frame someone at world point `w` stands in, and where in it:
    /// a ship whose deck is underfoot, else the world.
    pub fn frame_at(&self, w: (f64, f64, f64)) -> (u32, (f64, f64, f64)) {
        for s in &self.ships {
            if let Some(l) = s.underfoot(w) {
                return (s.id, l);
            }
        }
        (0, w)
    }

    fn cell_in(l: (f64, f64, f64)) -> Pos {
        (cell(l.0), cell(l.1), (l.2 + 0.01).floor() as i32)
    }

    /// Where `user` should stand: aboard the ship they flew in on, `at` if
    /// there's ground there, else on the home island. With the ship and
    /// where on it, if they're aboard.
    pub fn spawn(
        &mut self,
        user: &str,
        at: Option<(f64, f64, f64)>,
    ) -> ((f64, f64, f64), Option<(u32, (f64, f64, f64))>) {
        if let Some((ship, l)) = self.arrivals.remove(user) {
            if let Some(w) = self.world_of(ship, l) {
                return (w, Some((ship, l)));
            }
        }
        if let Some((x, y, z)) = at {
            if let Some(g) = self.terrain.ground(x, y, z + 0.5) {
                if (g - z).abs() < 1.5 && self.terrain.walkable(x, y, g) {
                    return ((x, y, g), None);
                }
            }
        }
        let (hx, hy, hz) = match self.islands.first() {
            Some(i) => (i.x as f64, i.y as f64, i.top as f64 + 1.0),
            None => (0.0, 0.0, 0.0),
        };
        for _ in 0..40 {
            let (x, y) = (
                hx + self.rng.next() * 4.0 - 2.0,
                hy + self.rng.next() * 4.0 - 2.0,
            );
            if self.terrain.walkable(x, y, hz) {
                let z = self.terrain.ground(x, y, hz).unwrap_or(hz);
                return ((x, y, z), None);
            }
        }
        ((hx, hy, hz), None)
    }

    // -- sleep

    pub fn asleep(&self) -> bool {
        self.asleep_since.is_some()
    }

    /// Everyone's gone: stop ticking until `wake`.
    pub fn sleep(&mut self, now_ms: i64) {
        if self.asleep_since.is_none() {
            self.asleep_since = Some(now_ms);
        }
    }

    /// Someone's here: catch up on every world tick slept through. Returns
    /// how many that was. A universe that has never ticked starts its clock.
    pub fn wake(&mut self, now_ms: i64) -> i64 {
        let Some(since) = self.asleep_since.take() else {
            self.last_ms.get_or_insert(now_ms);
            return 0;
        };
        let missed = (now_ms - since).max(0) / TICK_MS;
        self.world_tick += missed;
        self.last_ms = Some(now_ms);
        self.tick_acc_ms = 0;
        self.grow();
        missed
    }

    /// What runs while nobody is here: empty ships fly back to their docks,
    /// a universe left without a ship builds one, helpers put down what they
    /// hold and go home, cows amble home.
    pub fn ambient(&mut self, now_ms: i64) {
        if self.ships.is_empty() {
            if let Some(dock) = self.home_dock() {
                let id = self.new_id();
                self.ships.push(Ship::standard(id, dock));
                self.events.push(Event::Ship(id));
            }
        }
        for i in 0..self.ships.len() {
            let s = &self.ships[i];
            if !s.riders.is_empty() || s.pose == s.dock {
                continue;
            }
            let others: Vec<&Ship> = self.ships.iter().filter(|o| o.id != s.id).collect();
            if !s.collides(&s.dock, &self.terrain, &others) {
                let s = &mut self.ships[i];
                s.pose = s.dock;
                s.halt();
                s.pilot = None;
            }
        }
        let carried: Vec<u32> = self
            .furniture
            .values()
            .filter(|f| !f.grips.is_empty())
            .map(|f| f.id)
            .collect();
        for fid in carried {
            self.drop_near(fid);
        }
        for h in self.helpers.iter_mut() {
            (h.x, h.y, h.z) = h.home;
            h.task = Task::Idle;
        }
        for c in self.cows.iter_mut() {
            if !c.carried {
                c.target = Some(c.home);
                c.idle_until_ms = now_ms;
            }
        }
    }

    // -- saving

    pub fn save(&self, now_ms: i64) -> Saved {
        let mut furniture: Vec<Furniture> = self.furniture.values().cloned().collect();
        furniture.sort_by_key(|f| f.id);
        let mut sites: Vec<Site> = self.sites.values().cloned().collect();
        sites.sort_by_key(|s| s.id);
        let mut ships = self.ships.clone();
        for s in ships.iter_mut() {
            s.halt();
            s.pilot = None;
        }
        Saved {
            world_tick: self.world_tick,
            at_ms: self.asleep_since.unwrap_or(now_ms),
            crops: self.crops.iter().map(|(p, c)| (*p, c.planted)).collect(),
            furniture,
            sites,
            ships,
            next_id: self.next_id,
        }
    }

    /// Back as saved, asleep since it was saved. Call after loading the
    /// saved chunks: furniture whose cells were built over meanwhile moves
    /// to the nearest room.
    pub fn restore(&mut self, saved: Saved) {
        self.world_tick = saved.world_tick;
        self.asleep_since = Some(saved.at_ms);
        self.next_id = self.next_id.max(saved.next_id);
        self.crops.clear();
        for (p, planted) in saved.crops {
            self.crops.insert(p, Crop { planted, stage: 0 });
        }
        self.grow();
        // ships first: furniture can be aboard them
        self.ships = saved.ships;
        for mut f in saved.furniture {
            let n = f.info().slots.max(f.slots.len());
            f.slots.resize(n, None);
            let on = f.on;
            let ok = f
                .cells()
                .iter()
                .all(|&c| self.free(on, c) || self.get(on, c) == Some(FURNITURE));
            if !ok {
                match self.find_room(on, f.origin, f.info().size, f.rot, 10) {
                    Some(o) => f.origin = o,
                    None => continue,
                }
            }
            for c in f.cells() {
                self.set_block(on, c, FURNITURE);
            }
            self.furniture.insert(f.id, f);
        }
        for s in saved.sites {
            let on = s.on;
            let ok = s
                .cells()
                .iter()
                .all(|&c| self.free(on, c) || self.get(on, c) == Some(SCAFFOLD));
            if ok {
                for c in s.cells() {
                    self.set_block(on, c, SCAFFOLD);
                }
                self.sites.insert(s.id, s);
            }
        }
        // cells left taken by furniture or a blueprint that's gone (one that
        // didn't read, say) are freed
        let taken: std::collections::HashSet<Pos> = self
            .furniture
            .values()
            .filter(|f| f.on == 0)
            .flat_map(|f| f.cells())
            .chain(self.sites.values().filter(|s| s.on == 0).flat_map(|s| s.cells()))
            .collect();
        for p in self.terrain.find(&[FURNITURE, SCAFFOLD]) {
            if !taken.contains(&p) {
                self.terrain.set(p.0, p.1, p.2, AIR);
            }
        }
        if self.ships.is_empty() {
            if let Some(dock) = self.home_dock() {
                let id = self.new_id();
                self.ships.push(Ship::standard(id, dock));
            }
        }
        self.events.clear();
    }

    // -- crops

    fn stage_at(&self, planted: i64) -> u8 {
        let grown = (self.world_tick - planted).max(0) * TICK_MS / self.stage_ms;
        grown.min(RIPE as i64) as u8
    }

    /// Bring every crop's stage up to the world tick.
    fn grow(&mut self) {
        let mut changed = Vec::new();
        for (p, c) in self.crops.iter() {
            let stage = self.stage_at(c.planted);
            if stage != c.stage {
                changed.push((*p, stage));
            }
        }
        for (p, stage) in changed {
            if let Some(c) = self.crops.get_mut(&p) {
                c.stage = stage;
            }
            self.events.push(Event::Crop(p, Some(stage)));
        }
    }

    /// A crop planted `ago_ms` of world time ago (an old save, a test).
    pub fn plant_aged(&mut self, p: Pos, ago_ms: i64) {
        let planted = self.world_tick - (ago_ms / TICK_MS).max(0);
        let stage = self.stage_at(planted);
        self.crops.insert(p, Crop { planted, stage });
    }

    /// Plant in the air cell `p`, over grass (tilled to dirt) or dirt.
    pub fn plant(&mut self, p: Pos) -> R<()> {
        match self.terrain.get(p.0, p.1, p.2) {
            None => return Err("edge_of_the_world"),
            Some(AIR) => {}
            Some(_) => return Err("occupied"),
        }
        if self.crops.contains_key(&p) {
            return Err("occupied");
        }
        let below = (p.0, p.1, p.2 - 1);
        match self.terrain.get(below.0, below.1, below.2) {
            Some(GRASS) => self.set_block(0, below, DIRT),
            Some(DIRT) => {}
            _ => return Err("needs_soil"),
        }
        let planted = self.world_tick;
        self.crops.insert(p, Crop { planted, stage: 0 });
        self.events.push(Event::Crop(p, Some(0)));
        Ok(())
    }

    /// Pick the ripe crop in `p` into `bag`.
    pub fn harvest(&mut self, p: Pos, bag: &mut Bag) -> R<()> {
        match self.crops.get(&p) {
            None => return Err("nothing_growing"),
            Some(c) if c.stage < RIPE => return Err("not_ripe"),
            Some(_) => {}
        }
        if items::add(bag, "carrot", 1) > 0 {
            return Err("bag_full");
        }
        self.crops.remove(&p);
        self.events.push(Event::Crop(p, None));
        Ok(())
    }

    fn uproot(&mut self, p: Pos) {
        if self.crops.remove(&p).is_some() {
            self.events.push(Event::Crop(p, None));
        }
    }

    // -- digging and building

    /// Dig the block at `p` in frame `on` into `bag`. Furniture breaks
    /// (`break_furniture`) and scaffolding gives back what was put into it.
    /// A ship keeps its last block.
    pub fn dig(&mut self, user: &str, on: u32, p: Pos, bag: &mut Bag) -> R<()> {
        match self.get(on, p) {
            None => Err("edge_of_the_world"),
            Some(AIR) => Err("nothing_there"),
            Some(WATER) => Err("cannot_dig_water"),
            Some(FURNITURE) => match self.furniture_at(on, p) {
                Some(id) => self.break_furniture(user, id, bag),
                None => Err("nothing_there"),
            },
            Some(SCAFFOLD) => match self.site_at(on, p) {
                Some(id) => self.cancel_site(id, bag),
                None => Err("nothing_there"),
            },
            Some(id) => {
                let item = items::for_block(id).ok_or("cannot_dig")?;
                if items::room_for(bag, item) == 0 {
                    return Err("bag_full");
                }
                let last = self.ship(on).is_some_and(|s| {
                    s.blocks
                        .values()
                        .filter(|&&b| b != FURNITURE && b != SCAFFOLD)
                        .count()
                        <= 1
                });
                if last {
                    return Err("last_block");
                }
                items::add(bag, item, 1);
                self.set_block(on, p, AIR);
                // whatever grew on it goes too
                if on == 0 {
                    self.uproot((p.0, p.1, p.2 + 1));
                }
                Ok(())
            }
        }
    }

    /// Place one `item` from `bag` at `p` in frame `on`: a block, or
    /// furniture that packs into a bag, turned `rot`.
    pub fn place(&mut self, on: u32, p: Pos, item: &str, rot: u8, bag: &mut Bag) -> R<()> {
        let info = items::info(item).ok_or("cannot_place")?;
        if !self.holds(on, p) {
            return Err("edge_of_the_world");
        }
        if let Some(id) = info.block {
            if !self.free(on, p) {
                return Err("occupied");
            }
            if !items::take(bag, item, 1) {
                return Err("none_left");
            }
            self.set_block(on, p, id);
            return Ok(());
        }
        let kind = info
            .furniture
            .and_then(furniture::kind)
            .ok_or("cannot_place")?;
        if !self.room(on, p, kind.size, rot) {
            return Err("occupied");
        }
        if !items::take(bag, item, 1) {
            return Err("none_left");
        }
        let id = self.new_id();
        let mut f = Furniture::new(id, kind, p, rot);
        f.on = on;
        self.put_furniture(f);
        Ok(())
    }

    /// Is `p` a cell of frame `on` at all: in the universe, or in a ship's
    /// reach?
    fn holds(&self, on: u32, p: Pos) -> bool {
        self.get(on, p).is_some()
    }

    fn room(&self, on: u32, origin: Pos, size: (i32, i32, i32), rot: u8) -> bool {
        furniture::cells(origin, size, rot)
            .iter()
            .all(|&c| self.free(on, c))
    }

    /// The nearest origin in frame `on` within `r` of `near` with room for
    /// `size`.
    fn find_room(
        &self,
        on: u32,
        near: Pos,
        size: (i32, i32, i32),
        rot: u8,
        r: i32,
    ) -> Option<Pos> {
        let mut best: Option<(i32, Pos)> = None;
        for dz in [0, 1, -1, 2, -2, 3] {
            for dy in -r..=r {
                for dx in -r..=r {
                    let o = (near.0 + dx, near.1 + dy, near.2 + dz);
                    let d = dx * dx + dy * dy + dz * dz * 4;
                    if best.is_some_and(|(b, _)| b <= d) {
                        continue;
                    }
                    // something to rest on, or it stays where it was
                    let below = self.get(on, (o.0, o.1, o.2 - 1));
                    let rests = !matches!(below, Some(AIR) | Some(WATER) | None);
                    if (rests || o == near) && self.room(on, o, size, rot) {
                        best = Some((d, o));
                    }
                }
            }
        }
        best.map(|(_, o)| o)
    }

    // -- furniture

    pub fn furniture_at(&self, on: u32, p: Pos) -> Option<u32> {
        self.furniture
            .values()
            .find(|f| !f.lifted && f.on == on && f.cells().contains(&p))
            .map(|f| f.id)
    }

    /// The middle of its footprint at its base, in the world; where its
    /// carriers are while it's lifted.
    pub fn furniture_middle(&self, f: &Furniture) -> (f64, f64, f64) {
        if f.lifted {
            return f.at;
        }
        self.world_of(f.on, f.center()).unwrap_or(f.at)
    }

    /// Into its frame at its origin, filling its cells.
    fn put_furniture(&mut self, f: Furniture) {
        for c in f.cells() {
            self.set_block(f.on, c, FURNITURE);
        }
        let id = f.id;
        self.furniture.insert(id, f);
        self.events.push(Event::Furniture(id));
    }

    fn remove_furniture(&mut self, id: u32) -> Option<Furniture> {
        let f = self.furniture.remove(&id)?;
        if !f.lifted {
            for c in f.cells() {
                self.set_block(f.on, c, AIR);
            }
        }
        self.events.push(Event::FurnitureGone(id));
        Some(f)
    }

    /// Break furniture apart: some of what it was made of and everything it
    /// held go into `bag`, and what doesn't fit is left in a sack.
    pub fn break_furniture(&mut self, _user: &str, id: u32, bag: &mut Bag) -> R<()> {
        let f = self.furniture.get(&id).ok_or("no_such_furniture")?;
        if f.lifted || !f.grips.is_empty() {
            return Err("in_use");
        }
        let (on, origin, rot) = (f.on, f.origin, f.rot);
        let mut back: Vec<(String, u16)> = furniture::salvage(f.info())
            .into_iter()
            .map(|(i, n)| (i.to_string(), n))
            .collect();
        back.extend(f.slots.iter().flatten().map(|s| (s.item.clone(), s.n)));
        self.remove_furniture(id);
        self.give(bag, back, on, origin, rot);
        Ok(())
    }

    /// Put `stuff` in `bag`; what doesn't fit goes in a sack at `at` in
    /// frame `on`.
    fn give(&mut self, bag: &mut Bag, stuff: Vec<(String, u16)>, on: u32, at: Pos, rot: u8) {
        let mut over: Vec<Slot> = Vec::new();
        for (item, n) in stuff {
            let mut left = items::add(bag, &item, n);
            while left > 0 {
                over.push(None);
                left = items::add(&mut over, &item, left);
            }
        }
        if over.is_empty() {
            return;
        }
        let sack = furniture::kind("sack").expect("sacks exist");
        let spot = if self.free(on, at) {
            Some(at)
        } else {
            self.find_room(on, at, sack.size, 0, 6)
        };
        if let Some(p) = spot {
            let id = self.new_id();
            let mut f = Furniture::new(id, sack, p, rot);
            f.on = on;
            f.slots = over;
            self.put_furniture(f);
        }
    }

    /// Move the stack in `bag[slot]` into furniture `id`.
    pub fn stash(&mut self, at: (f64, f64, f64), id: u32, bag: &mut Bag, slot: usize) -> R<()> {
        let f = self.reachable_box(at, id)?;
        if f.info().name == "sack" {
            return Err("cannot_stash");
        }
        let f = self.furniture.get_mut(&id).expect("checked");
        if !items::shift(bag, slot, &mut f.slots) {
            return Err("no_room");
        }
        self.events.push(Event::Furniture(id));
        Ok(())
    }

    /// Move the stack in furniture `id`'s `slot` into `bag`.
    pub fn take(&mut self, at: (f64, f64, f64), id: u32, slot: usize, bag: &mut Bag) -> R<()> {
        self.reachable_box(at, id)?;
        let f = self.furniture.get_mut(&id).expect("checked");
        if !items::shift(&mut f.slots, slot, bag) {
            return Err("bag_full");
        }
        let empty_sack = f.info().name == "sack" && items::is_empty(&f.slots);
        if empty_sack {
            self.remove_furniture(id);
        } else {
            self.events.push(Event::Furniture(id));
        }
        Ok(())
    }

    fn reachable_box(&self, at: (f64, f64, f64), id: u32) -> R<&Furniture> {
        let f = self.furniture.get(&id).ok_or("no_such_furniture")?;
        if f.slots.is_empty() {
            return Err("not_a_container");
        }
        if f.lifted {
            return Err("in_use");
        }
        if dist(at, self.furniture_middle(f)) > REACH {
            return Err("out_of_reach");
        }
        Ok(f)
    }

    /// `user`, standing at `at`, takes hold of furniture `id`. Small empty
    /// pieces that pack away go into `bag` instead, if there's room.
    pub fn grab(&mut self, user: &str, at: (f64, f64, f64), id: u32, bag: &mut Bag) -> R<Grabbed> {
        if self.holders.contains_key(user) {
            return Err("hands_full");
        }
        let f = self.furniture.get(&id).ok_or("no_such_furniture")?;
        if dist(at, self.furniture_middle(f)) > REACH {
            return Err("out_of_reach");
        }
        if f.lifted || f.grips.len() >= f.info().carriers {
            return Err("already_carried");
        }
        let k = f.info();
        if k.itemizable
            && f.grips.is_empty()
            && items::is_empty(&f.slots)
            && items::room_for(bag, k.name) > 0
        {
            self.remove_furniture(id);
            items::add(bag, k.name, 1);
            return Ok(Grabbed::Pocketed);
        }
        let f = self.furniture.get_mut(&id).expect("checked");
        f.grips.push(Grip::Player(user.to_string()));
        let held = Held::Furniture(id);
        self.holders.insert(user.to_string(), Holder { held, at });
        self.events.push(Event::Carry(user.to_string(), Some(held)));
        if self.try_lift(id) {
            Ok(Grabbed::Lifted)
        } else {
            self.events.push(Event::Furniture(id));
            Ok(Grabbed::Gripped)
        }
    }

    /// Where someone holding furniture is.
    fn grip_at(&self, g: &Grip) -> Option<(f64, f64, f64)> {
        match g {
            Grip::Player(u) => self.holders.get(u).map(|h| h.at),
            Grip::Helper(id) => self
                .helpers
                .iter()
                .find(|h| h.id == *id)
                .map(|h| (h.x, h.y, h.z)),
        }
    }

    fn grips_middle(&self, f: &Furniture) -> Option<(f64, f64, f64)> {
        let ps: Vec<_> = f.grips.iter().filter_map(|g| self.grip_at(g)).collect();
        if ps.is_empty() {
            return None;
        }
        let n = ps.len() as f64;
        let s = ps
            .iter()
            .fold((0.0, 0.0, 0.0), |a, p| (a.0 + p.0, a.1 + p.1, a.2 + p.2));
        Some((s.0 / n, s.1 / n, s.2 / n))
    }

    /// Enough hands: up it comes, out of the world.
    fn try_lift(&mut self, id: u32) -> bool {
        let Some(f) = self.furniture.get(&id) else {
            return false;
        };
        if f.lifted || f.grips.len() < f.info().carriers {
            return false;
        }
        let at = self
            .grips_middle(f)
            .unwrap_or_else(|| self.furniture_middle(f));
        let (on, cells) = (f.on, f.cells());
        for c in cells {
            self.set_block(on, c, AIR);
        }
        let f = self.furniture.get_mut(&id).expect("checked");
        f.lifted = true;
        f.at = at;
        self.events.push(Event::Furniture(id));
        true
    }

    /// Set lifted furniture down in frame `on` with its origin at `origin`,
    /// turned `rot`; everyone holding it lets go.
    fn set_down(&mut self, id: u32, on: u32, origin: Pos, rot: u8) -> R<()> {
        let f = self.furniture.get(&id).ok_or("no_such_furniture")?;
        if !self.holds(on, origin) {
            return Err("edge_of_the_world");
        }
        if !self.room(on, origin, f.info().size, rot) {
            return Err("occupied");
        }
        let grips = f.grips.clone();
        let mut f = self.furniture.remove(&id).expect("checked");
        f.on = on;
        f.origin = origin;
        f.rot = rot % 4;
        f.lifted = false;
        f.grips.clear();
        self.let_go_all(&grips);
        self.put_furniture(f);
        Ok(())
    }

    /// Everyone in `grips` has empty hands now; helpers head home.
    fn let_go_all(&mut self, grips: &[Grip]) {
        for g in grips {
            match g {
                Grip::Player(u) => {
                    if self.holders.remove(u).is_some() {
                        self.events.push(Event::Carry(u.clone(), None));
                    }
                }
                Grip::Helper(h) => {
                    if let Some(h) = self.helpers.iter_mut().find(|x| x.id == *h) {
                        h.task = Task::Home;
                    }
                }
            }
        }
    }

    /// Dropped: down in the nearest room to where it was carried, or where
    /// it was picked up.
    fn drop_near(&mut self, id: u32) {
        let Some(f) = self.furniture.get(&id) else {
            return;
        };
        if !f.lifted {
            let grips = f.grips.clone();
            self.furniture.get_mut(&id).expect("checked").grips.clear();
            self.let_go_all(&grips);
            self.events.push(Event::Furniture(id));
            return;
        }
        let (on, l) = self.frame_at(f.at);
        let near = Self::cell_in(l);
        let (size, rot, origin, was) = (f.info().size, f.rot, f.origin, f.on);
        let spot = self
            .find_room(on, near, size, rot, 6)
            .map(|o| (on, o))
            .or_else(|| self.find_room(was, origin, size, rot, 12).map(|o| (was, o)));
        match spot {
            Some((on, o)) => {
                let _ = self.set_down(id, on, o, rot);
            }
            None => {
                // nowhere at all: it's broken up where it was
                let grips = f.grips.clone();
                self.let_go_all(&grips);
                self.furniture.remove(&id);
                self.events.push(Event::FurnitureGone(id));
            }
        }
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

    /// `holder`, standing at `at`, lifts the block at `p` in frame `on`.
    pub fn pick_block(&mut self, holder: &str, at: (f64, f64, f64), on: u32, p: Pos) -> R<u8> {
        if self.holders.contains_key(holder) {
            return Err("hands_full");
        }
        let id = self.get(on, p).unwrap_or(AIR);
        if !Self::carryable(id) {
            return Err("cannot_carry");
        }
        self.set_block(on, p, AIR);
        let held = Held::Block(id);
        self.holders.insert(holder.to_string(), Holder { held, at });
        self.events
            .push(Event::Carry(holder.to_string(), Some(held)));
        Ok(id)
    }

    /// `holder`, standing at `at`, lifts cow `id` over their head.
    pub fn pick_cow(&mut self, holder: &str, at: (f64, f64, f64), id: u32) -> R<()> {
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
        if dx * dx + dy * dy + dz * dz > REACH * REACH {
            return Err("out_of_reach");
        }
        cow.carried = true;
        cow.target = None;
        cow.vz = 0.0;
        (cow.x, cow.y, cow.z) = (at.0, at.1, at.2 + CARRY_Z);
        self.lifted.push(id);
        let held = Held::Cow(id);
        self.holders.insert(holder.to_string(), Holder { held, at });
        self.events
            .push(Event::Carry(holder.to_string(), Some(held)));
        Ok(())
    }

    /// `holder` puts what they carry at cell `p` of frame `on` (furniture
    /// with its origin there, turned `rot`). Furniture still waiting for a
    /// second carrier is just let go of. Cows stay ashore.
    pub fn put_down(&mut self, holder: &str, on: u32, p: Pos, rot: u8) -> R<Held> {
        let Some(h) = self.holders.get(holder) else {
            return Err("hands_empty");
        };
        let held = h.held;
        match held {
            Held::Block(id) => {
                if !self.free(on, p) {
                    return Err("occupied");
                }
                self.set_block(on, p, id);
            }
            Held::Cow(id) => {
                if on != 0 {
                    return Err("cows_stay_ashore");
                }
                if !self.free(0, p) {
                    return Err("occupied");
                }
                let (x, y, z) = (p.0 as f64, p.1 as f64, p.2 as f64);
                if !self.terrain.walkable(x, y, z) {
                    return Err("no_room_for_a_cow");
                }
                let ground = self.terrain.ground(x, y, z).unwrap_or(z);
                self.land_cow(id, x, y, ground);
            }
            Held::Furniture(id) => {
                let lifted = self.furniture.get(&id).is_some_and(|f| f.lifted);
                if lifted {
                    return self.set_down(id, on, p, rot).map(|_| held);
                }
                self.let_go(holder, id);
                return Ok(held);
            }
        }
        self.holders.remove(holder);
        self.events.push(Event::Carry(holder.to_string(), None));
        Ok(held)
    }

    /// `user` lets go of furniture `id` that hasn't lifted.
    fn let_go(&mut self, user: &str, id: u32) {
        if let Some(f) = self.furniture.get_mut(&id) {
            f.grips
                .retain(|g| !matches!(g, Grip::Player(p) if p == user));
            let helpers: Vec<u32> = f.helpers().collect();
            if !f.grips.iter().any(|g| matches!(g, Grip::Player(_))) {
                // nobody to help: helpers let go too
                f.grips.clear();
                for h in self.helpers.iter_mut() {
                    if helpers.contains(&h.id) || h.task == Task::Fetch(id) {
                        h.task = Task::Home;
                    }
                }
            }
            self.events.push(Event::Furniture(id));
        }
        if self.holders.remove(user).is_some() {
            self.events.push(Event::Carry(user.to_string(), None));
        }
    }

    /// `holder` left the universe: whatever they carried is set down where
    /// they last stood, and they leave any helm.
    pub fn release(&mut self, holder: &str) {
        self.leave_helm(holder);
        self.set_down_held(holder);
    }

    /// Whatever `holder` carries is set down where they stand.
    fn set_down_held(&mut self, holder: &str) {
        let Some(h) = self.holders.get(holder) else {
            return;
        };
        let (held, (x, y, z)) = (h.held, h.at);
        match held {
            Held::Block(id) => {
                // back where they stood (on deck, if they were), or the
                // first free cell above; else it's lost
                let (on, l) = self.frame_at((x, y, z));
                let p = Self::cell_in(l);
                if let Some(z) = (p.2..p.2 + 4).find(|&z| self.free(on, (p.0, p.1, z))) {
                    self.set_block(on, (p.0, p.1, z), id);
                }
            }
            Held::Cow(id) => {
                let spot = match self.terrain.ground(x, y, z) {
                    Some(g) if self.terrain.walkable(x, y, z) => Some((x, y, g)),
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
                        (hx, hy, self.terrain.ground(hx, hy, 8.0).unwrap_or(0.0))
                    }
                };
                self.land_cow(id, cx, cy, cz);
            }
            Held::Furniture(id) => {
                let lifted = self.furniture.get(&id).is_some_and(|f| f.lifted);
                if lifted {
                    self.drop_near(id);
                } else {
                    self.let_go(holder, id);
                }
            }
        }
        if self.holders.remove(holder).is_some() {
            self.events.push(Event::Carry(holder.to_string(), None));
        }
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

    // -- blueprints

    pub fn site_at(&self, on: u32, p: Pos) -> Option<u32> {
        self.sites
            .values()
            .find(|s| s.on == on && s.cells().contains(&p))
            .map(|s| s.id)
    }

    /// Lay out blueprint `kind` with its origin at `p` in frame `on`, turned
    /// `rot`: its footprint fills with scaffolding until the ingredients are
    /// in.
    pub fn start_site(&mut self, kind: &str, on: u32, p: Pos, rot: u8) -> R<u32> {
        let k = furniture::buildable(kind).ok_or("no_such_blueprint")?;
        let cells = furniture::cells(p, k.size, rot);
        if cells.iter().any(|&c| !self.holds(on, c)) {
            return Err("edge_of_the_world");
        }
        if !cells.iter().all(|&c| self.free(on, c)) {
            return Err("occupied");
        }
        let id = self.new_id();
        for c in cells {
            self.set_block(on, c, SCAFFOLD);
        }
        self.sites.insert(
            id,
            Site {
                id,
                kind: k.name.to_string(),
                on,
                origin: p,
                rot: rot % 4,
                have: Vec::new(),
            },
        );
        self.events.push(Event::Site(id));
        Ok(id)
    }

    /// Put ingredients from `bag` into site `id`: as much as it still needs
    /// of the first missing ingredient the bag has. Once nothing is missing
    /// the scaffolding becomes the furniture, whose id is returned.
    pub fn deposit(&mut self, id: u32, bag: &mut Bag) -> R<Option<u32>> {
        let site = self.sites.get(&id).ok_or("no_such_site")?;
        let pick = site
            .missing()
            .into_iter()
            .find(|(i, _)| items::count(bag, i) > 0);
        let Some((item, need)) = pick else {
            return Err("missing_ingredients");
        };
        let n = need.min(items::count(bag, item).min(u16::MAX as u32) as u16);
        items::take(bag, item, n);
        let site = self.sites.get_mut(&id).expect("checked");
        site.put(item, n);
        if !site.missing().is_empty() {
            self.events.push(Event::Site(id));
            return Ok(None);
        }
        let site = self.sites.remove(&id).expect("checked");
        self.events.push(Event::SiteGone(id));
        let fid = self.new_id();
        let mut f = Furniture::new(fid, site.info(), site.origin, site.rot);
        f.on = site.on;
        self.put_furniture(f);
        Ok(Some(fid))
    }

    /// Take the scaffolding down; everything put in comes back.
    fn cancel_site(&mut self, id: u32, bag: &mut Bag) -> R<()> {
        let site = self.sites.remove(&id).ok_or("no_such_site")?;
        for c in site.cells() {
            self.set_block(site.on, c, AIR);
        }
        self.events.push(Event::SiteGone(id));
        self.give(bag, site.have.clone(), site.on, site.origin, site.rot);
        Ok(())
    }

    // -- ships

    /// `user`, standing at `at`, takes the helm of the ship it's on.
    pub fn take_helm(&mut self, user: &str, at: (f64, f64, f64)) -> R<u32> {
        let near = self.ships.iter().find_map(|s| {
            let helm = s.helm_cell()?;
            (dist(at, s.center_of(helm)) <= ships::HELM_REACH + 0.5).then_some(s.id)
        });
        let id = near.ok_or("no_helm_here")?;
        self.leave_helm(user);
        let s = self.ship_mut(id).expect("found");
        match &s.pilot {
            Some(p) if p != user => return Err("someone_else_steers"),
            _ => {}
        }
        s.pilot = Some(user.to_string());
        self.events.push(Event::Ship(id));
        Ok(id)
    }

    /// `user` lets go of any helm they hold; the ship slows to a stop.
    /// True if they held one.
    pub fn leave_helm(&mut self, user: &str) -> bool {
        let mut left = Vec::new();
        for s in self.ships.iter_mut() {
            if s.pilot.as_deref() == Some(user) {
                s.pilot = None;
                left.push(s.id);
            }
        }
        let held = !left.is_empty();
        for id in left {
            self.events.push(Event::Ship(id));
        }
        held
    }

    /// The pilot of a ship asks for thrust, turn and lift.
    pub fn steer(&mut self, user: &str, helm: Helm) -> R<()> {
        let s = self
            .ships
            .iter_mut()
            .find(|s| s.pilot.as_deref() == Some(user))
            .ok_or("not_piloting")?;
        s.helm = helm;
        Ok(())
    }

    /// A ship flown in from the neighbour on `from`, with all it carries.
    /// It and everything aboard get ids of ours; its riders are aboard when
    /// they arrive (`spawn`). Returns its id here.
    pub fn arrive(&mut self, cargo: Cargo, from: Side) -> u32 {
        let mut ship = cargo.ship;
        ship.enter_from(from);
        ship.id = self.new_id();
        ship.riders.clear();
        // it docks here from now on, by the home island (or where it came
        // in, if there's no room there)
        ship.dock = self.home_dock().unwrap_or(ship.pose);
        let id = ship.id;
        self.ships.push(ship);
        self.events.push(Event::Ship(id));
        for mut f in cargo.furniture {
            f.id = self.new_id();
            f.on = id;
            f.grips.clear();
            f.lifted = false;
            let fid = f.id;
            self.furniture.insert(fid, f);
            self.events.push(Event::Furniture(fid));
        }
        for mut site in cargo.sites {
            site.id = self.new_id();
            site.on = id;
            let sid = site.id;
            self.sites.insert(sid, site);
            self.events.push(Event::Site(sid));
        }
        for (user, at) in cargo.riders {
            self.arrivals.insert(user, (id, at));
        }
        id
    }

    // -- helpers

    /// `user`, holding one end of something heavy, asks helper `id` for the
    /// other end: they walk over and take it.
    pub fn call_helper(&mut self, user: &str, id: u32) -> R<()> {
        let Some(Held::Furniture(fid)) = self.held(user) else {
            return Err("nothing_to_help_with");
        };
        let f = self.furniture.get(&fid).ok_or("nothing_to_help_with")?;
        if f.lifted || f.grips.len() >= f.info().carriers {
            return Err("nothing_to_help_with");
        }
        let c = self.furniture_middle(f);
        let h = self
            .helpers
            .iter_mut()
            .find(|h| h.id == id)
            .ok_or("no_such_helper")?;
        if !matches!(h.task, Task::Idle | Task::Home) {
            return Err("busy");
        }
        if (h.x - c.0).hypot(h.y - c.1) > HELPER_CALL {
            return Err("too_far");
        }
        h.task = Task::Fetch(fid);
        // the clock starts on its next step
        h.task_ms = -1;
        Ok(())
    }

    fn step_helper(&mut self, i: usize, now_ms: i64, dt: f64) {
        if self.helpers[i].task_ms < 0 {
            self.helpers[i].task_ms = now_ms;
        }
        let h = &self.helpers[i];
        let (hid, pos, task, home, task_ms) = (h.id, (h.x, h.y, h.z), h.task, h.home, h.task_ms);
        let target = match task {
            Task::Idle => None,
            Task::Home => {
                if (home.0 - pos.0).hypot(home.1 - pos.1) < 0.4 {
                    self.helpers[i].task = Task::Idle;
                    None
                } else {
                    Some((home.0, home.1))
                }
            }
            Task::Fetch(fid) => {
                let still = self
                    .furniture
                    .get(&fid)
                    .filter(|f| !f.lifted && f.grips.iter().any(|g| matches!(g, Grip::Player(_))));
                match still {
                    _ if now_ms - task_ms > HELPER_PATIENCE_MS => {
                        self.helpers[i].task = Task::Home;
                        None
                    }
                    None => {
                        self.helpers[i].task = Task::Home;
                        None
                    }
                    Some(f) => {
                        let c = self.furniture_middle(f);
                        if (c.0 - pos.0).hypot(c.1 - pos.1) <= 1.7 {
                            let f = self.furniture.get_mut(&fid).expect("checked");
                            f.grips.push(Grip::Helper(hid));
                            self.helpers[i].task = Task::Carry(fid);
                            if !self.try_lift(fid) {
                                self.events.push(Event::Furniture(fid));
                            }
                            None
                        } else {
                            Some((c.0, c.1))
                        }
                    }
                }
            }
            Task::Carry(fid) => {
                let holder = self.furniture.get(&fid).and_then(|f| {
                    let mine = f.grips.contains(&Grip::Helper(hid));
                    let player = f.grips.iter().find_map(|g| match g {
                        Grip::Player(p) => Some(p.clone()),
                        _ => None,
                    });
                    if mine {
                        player
                    } else {
                        None
                    }
                });
                match holder.and_then(|p| self.holders.get(&p).map(|h| h.at)) {
                    None => {
                        self.helpers[i].task = Task::Home;
                        None
                    }
                    Some(p) => {
                        // keep to the far end, trailing the player
                        let (ox, oy) = (pos.0 - p.0, pos.1 - p.1);
                        let d = ox.hypot(oy);
                        let (nx, ny) = if d > 0.01 {
                            (ox / d, oy / d)
                        } else {
                            (1.0, 0.0)
                        };
                        Some((p.0 + nx * HELPER_GAP, p.1 + ny * HELPER_GAP))
                    }
                }
            }
        };
        let Some((tx, ty)) = target else {
            return;
        };
        let h = &mut self.helpers[i];
        let (ex, ey) = (tx - h.x, ty - h.y);
        let d = ex.hypot(ey);
        if d < 0.1 {
            return;
        }
        h.heading = ey.atan2(ex);
        let step = (HELPER_SPEED * dt).min(d);
        let (dx, dy) = (ex / d * step, ey / d * step);
        let mut body = (h.x, h.y, h.z, h.vz);
        move_body(&self.terrain, &mut body, dx, dy, dt);
        let h = &mut self.helpers[i];
        (h.x, h.y, h.z, h.vz) = body;
    }

    // -- cows

    pub fn spawn_cow(&mut self, x: f64, y: f64) -> u32 {
        let id = self.next_cow;
        self.next_cow += 1;
        let z = self.terrain.ground(x, y, 16.0).unwrap_or(0.0);
        let heading = self.rng.next() * std::f64::consts::TAU;
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
            sent: None,
            carried: false,
        });
        id
    }

    /// `n` cows somewhere on the home island.
    pub fn spawn_cows(&mut self, n: usize) {
        let Some(home) = self.islands.first().cloned() else {
            return;
        };
        let feet = home.top as f64 + 1.0;
        let mut placed = 0;
        let mut tries = 0;
        while placed < n && tries < 200 {
            tries += 1;
            let a = self.rng.next() * std::f64::consts::TAU;
            let d = 3.0 + self.rng.next() * home.r * 0.6;
            let (x, y) = (home.x as f64 + a.cos() * d, home.y as f64 + a.sin() * d);
            if self.terrain.walkable(x, y, feet) {
                self.spawn_cow(x, y);
                placed += 1;
            }
        }
    }

    // -- the tick

    /// Advance to `now_ms` (wall clock) with everyone where they stand.
    pub fn tick(&mut self, now_ms: i64, players: &[Walker]) -> TickOut {
        self.wake(now_ms);
        let mut out = TickOut::default();
        out.moos.append(&mut self.lifted);
        let (dt, elapsed) = match self.last_ms {
            // a long stall (or the first tick) shouldn't teleport anything
            Some(last) => (
                ((now_ms - last) as f64 / 1000.0).clamp(0.0, 0.25),
                (now_ms - last).max(0),
            ),
            None => (0.0, 0),
        };
        self.last_ms = Some(now_ms);
        self.tick_acc_ms += elapsed;
        self.world_tick += self.tick_acc_ms / TICK_MS;
        self.tick_acc_ms %= TICK_MS;
        self.grow();

        // everyone in the world's frame, and who's on which ship
        for s in self.ships.iter_mut() {
            s.riders.clear();
        }
        let mut feet: Vec<(String, f64, f64, f64)> = Vec::with_capacity(players.len());
        for w in players {
            let at = match self.ships.iter_mut().find(|s| w.on != 0 && s.id == w.on) {
                Some(s) => {
                    s.riders.push((w.id.clone(), w.at));
                    s.pose.to_world(w.at)
                }
                None => w.at,
            };
            feet.push((w.id.clone(), at.0, at.1, at.2));
        }
        self.check_pilots(now_ms, &feet);

        // carried cows ride over their holders
        for (id, x, y, z) in &feet {
            if let Some(h) = self.holders.get_mut(id) {
                h.at = (*x, *y, *z);
                if let Held::Cow(cid) = h.held {
                    if let Some(cow) = self.cows.iter_mut().find(|c| c.id == cid) {
                        (cow.x, cow.y, cow.z) = (*x, *y, *z + CARRY_Z);
                    }
                }
            }
        }

        for i in 0..self.helpers.len() {
            self.step_helper(i, now_ms, dt);
        }
        self.carry_furniture();

        let walkers: Vec<(f64, f64, f64)> = feet.iter().map(|&(_, x, y, z)| (x, y, z)).collect();
        for i in 0..self.cows.len() {
            if !self.cows[i].carried {
                self.step_cow(i, now_ms, dt, &walkers, &mut out);
            }
        }
        self.separate_cows();

        self.fly(dt);

        for c in self.cows.iter_mut() {
            if moved(&mut c.sent, (c.x, c.y, c.z, c.heading)) {
                out.cows.push((c.id, c.x, c.y, c.z, c.heading));
            }
        }
        for s in self.ships.iter_mut() {
            let p = s.pose;
            if moved(&mut s.sent, (p.x, p.y, p.z, p.h)) {
                let (vx, vy, vz, spin) = s.velocity();
                out.ships
                    .push(vec![s.id as f64, p.x, p.y, p.z, p.h, vx, vy, vz, spin]);
            }
        }
        for h in self.helpers.iter_mut() {
            if moved(&mut h.sent, (h.x, h.y, h.z, h.heading)) {
                out.helpers.push((h.id, h.x, h.y, h.z, h.heading));
            }
        }
        out
    }

    /// A pilot keeps the helm while they stand at it. One who walks away
    /// leaves it; one who isn't seen for a while (gone, or yet to arrive
    /// aboard from the last universe) too.
    fn check_pilots(&mut self, now_ms: i64, feet: &[(String, f64, f64, f64)]) {
        let mut left = Vec::new();
        for s in self.ships.iter_mut() {
            let Some(p) = s.pilot.clone() else {
                s.pilot_gone = None;
                continue;
            };
            let helm = s
                .helm_cell()
                .map(|h| (h.0 as f64, h.1 as f64, h.2 as f64 + 0.5));
            let at_helm = s.riders.iter().any(|(r, l)| {
                *r == p && helm.is_some_and(|h| dist(*l, h) <= ships::HELM_REACH + 1.0)
            });
            if at_helm {
                s.pilot_gone = None;
                continue;
            }
            let gone = if feet.iter().any(|f| f.0 == p) {
                true
            } else {
                now_ms - *s.pilot_gone.get_or_insert(now_ms) > PILOT_GONE_MS
            };
            if gone {
                s.pilot = None;
                s.pilot_gone = None;
                left.push(s.id);
            }
        }
        for id in left {
            self.events.push(Event::Ship(id));
        }
    }

    /// Grips that wandered off let go; lifted furniture follows its carriers
    /// and drops if they pull apart.
    fn carry_furniture(&mut self) {
        let ids: Vec<u32> = self
            .furniture
            .values()
            .filter(|f| !f.grips.is_empty())
            .map(|f| f.id)
            .collect();
        for id in ids {
            let f = &self.furniture[&id];
            if !f.lifted {
                let c = self.furniture_middle(f);
                let gone: Vec<String> =
                    f.grips
                        .iter()
                        .filter_map(|g| match g {
                            Grip::Player(u) => {
                                let far = self.holders.get(u).is_none_or(|h| {
                                    (h.at.0 - c.0).hypot(h.at.1 - c.1) > GRIP_SLACK
                                });
                                far.then(|| u.clone())
                            }
                            _ => None,
                        })
                        .collect();
                for u in gone {
                    self.let_go(&u, id);
                }
                continue;
            }
            let ps: Vec<_> = f.grips.iter().filter_map(|g| self.grip_at(g)).collect();
            let spread = ps.iter().enumerate().any(|(i, a)| {
                ps[i + 1..]
                    .iter()
                    .any(|b| (a.0 - b.0).hypot(a.1 - b.1) > CARRY_SPREAD)
            });
            let lost = ps.len() < f.grips.len();
            let mid = self.grips_middle(f).unwrap_or(f.at);
            self.furniture.get_mut(&id).expect("checked").at = mid;
            if lost || spread {
                self.drop_near(id);
            }
        }
    }

    fn fly(&mut self, dt: f64) {
        let mut departed = Vec::new();
        for i in 0..self.ships.len() {
            // out of the list while it moves, so the rest are what it bumps
            let mut s = self.ships.remove(i);
            let others: Vec<&Ship> = self.ships.iter().collect();
            let side = s.step(&self.terrain, &others, dt, self.open);
            if let Some(side) = side {
                departed.push((s.id, side));
            }
            self.ships.insert(i, s);
        }
        for (id, side) in departed {
            self.depart(id, side);
        }
    }

    /// Ship `id` flew off the `side` edge into the neighbour there: it goes,
    /// with everyone on it (whatever they held set down aboard first), the
    /// furniture and blueprints on it and what's in them.
    fn depart(&mut self, id: u32, side: Side) {
        let riders: Vec<String> = match self.ship(id) {
            Some(s) => s.riders.iter().map(|r| r.0.clone()).collect(),
            None => return,
        };
        for r in &riders {
            self.set_down_held(r);
        }
        let Some(i) = self.ships.iter().position(|s| s.id == id) else {
            return;
        };
        let ship = self.ships.remove(i);
        let mut furniture = Vec::new();
        let ids: Vec<u32> = self
            .furniture
            .values()
            .filter(|f| f.on == id)
            .map(|f| f.id)
            .collect();
        for fid in ids {
            let f = self.furniture.get(&fid).expect("listed");
            if f.lifted {
                // carried ashore: it isn't aboard any more
                self.furniture.get_mut(&fid).expect("listed").on = 0;
                continue;
            }
            let grips = f.grips.clone();
            self.let_go_all(&grips);
            let mut f = self.furniture.remove(&fid).expect("listed");
            f.grips.clear();
            self.events.push(Event::FurnitureGone(fid));
            furniture.push(f);
        }
        let sids: Vec<u32> = self
            .sites
            .values()
            .filter(|s| s.on == id)
            .map(|s| s.id)
            .collect();
        let mut sites = Vec::new();
        for sid in sids {
            sites.push(self.sites.remove(&sid).expect("listed"));
            self.events.push(Event::SiteGone(sid));
        }
        let cargo = Cargo {
            riders: ship.riders.clone(),
            ship,
            furniture,
            sites,
        };
        self.events.push(Event::Departed(Box::new(cargo), side));
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
            if self.rng.next() < 0.6 {
                let (hx, hy) = self.cows[i].home;
                let a = self.rng.next() * std::f64::consts::TAU;
                let r = self.rng.next().sqrt() * COW_LEASH;
                let (tx, ty) = (hx + a.cos() * r, hy + a.sin() * r);
                if self.terrain.walkable(tx, ty, self.cows[i].z) {
                    self.cows[i].target = Some((tx, ty));
                }
            }
            if self.cows[i].target.is_none() {
                // graze a while
                let wait = 2000.0 + self.rng.next() * 5000.0;
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

        let c = &self.cows[i];
        let mut body = (c.x, c.y, c.z, c.vz);
        let blocked = move_body(&self.terrain, &mut body, dx, dy, dt);
        let c = &mut self.cows[i];
        (c.x, c.y, c.z, c.vz) = body;
        if blocked && c.target.is_some() {
            // walked into something: pick another plan
            c.target = None;
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
                for (i, sx, sy) in [(a, -nx, -ny), (b, nx, ny)] {
                    let c = &self.cows[i];
                    let mut body = (c.x, c.y, c.z, c.vz);
                    move_body(&self.terrain, &mut body, sx, sy, 0.0);
                    let c = &mut self.cows[i];
                    (c.x, c.y, c.z, c.vz) = body;
                }
            }
        }
    }
}

/// Slide (x, y, z, vz) along walls by (dx, dy): each axis separately,
/// refused where not walkable; then fall to the ground. True if it was
/// blocked.
fn move_body(t: &Terrain, b: &mut (f64, f64, f64, f64), dx: f64, dy: f64, dt: f64) -> bool {
    let (x, y, z, _) = *b;
    let mut nx = x;
    let mut ny = y;
    if dx != 0.0 && t.walkable(x + dx, y, z) {
        nx = x + dx;
    }
    if dy != 0.0 && t.walkable(nx, y + dy, z) {
        ny = y + dy;
    }
    let blocked = nx != x + dx || ny != y + dy;
    b.0 = nx;
    b.1 = ny;
    if let Some(g) = t.ground(nx, ny, z) {
        if g >= b.2 {
            b.2 = g;
            b.3 = 0.0;
        } else {
            b.3 -= GRAVITY * dt;
            b.2 = (b.2 + b.3 * dt).max(g);
            if b.2 == g {
                b.3 = 0.0;
            }
        }
    }
    blocked
}

/// Whether (x, y, z, heading) moved noticeably from what was last sent;
/// remembers it if so.
fn moved(sent: &mut Option<(f64, f64, f64, f64)>, now: (f64, f64, f64, f64)) -> bool {
    let changed = match *sent {
        None => true,
        Some((x, y, z, h)) => {
            (now.0 - x).abs() > 0.01
                || (now.1 - y).abs() > 0.01
                || (now.2 - z).abs() > 0.01
                || angle_diff(h, now.3).abs() > 0.03
        }
    };
    if changed {
        *sent = Some(now);
    }
    changed
}

fn dist(a: (f64, f64, f64), b: (f64, f64, f64)) -> f64 {
    let (dx, dy, dz) = (a.0 - b.0, a.1 - b.1, a.2 - b.2);
    (dx * dx + dy * dy + dz * dz).sqrt()
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
mod tests;
