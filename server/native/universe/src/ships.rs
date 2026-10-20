//! Airships: blocks that fly together, between islands and from one
//! universe to the next.
//!
//! A ship is a grid of blocks in its own frame (+x ahead, +y to port, z up,
//! the same cell convention as the world's: a block at (x, y, z) spans
//! x-0.5..x+0.5, y-0.5..y+0.5, z..z+1) and a `Pose` placing that frame in
//! the world. It only turns about z. Its deck's top is at local z 0, so
//! someone standing on deck has their feet at the pose's z.
//!
//! Whoever stands at its helm steers: thrust ahead or astern, turn, climb or
//! sink (`Helm`). It can't fly into the world's blocks or another ship's:
//! each block is tested by points at its corners and middle, which is close
//! enough for a ship that only yaws. Furniture and blueprints aboard sit in
//! its cells (`terrain::FURNITURE`, `SCAFFOLD`) like they do in the world's.
//!
//! At the edge of the universe it crosses into the neighbouring one if
//! there is one (`Sim::tick` hands it over), else it stops there.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::terrain::{
    cell, Pos, Terrain, AIR, BALLOON, DECK, HALF, HELM, HULL, RAIL, WATER, WOOD, Z_MAX, Z_MIN,
};

pub const SPEED: f64 = 7.0; // tiles a second, flat out
pub const CLIMB: f64 = 3.0;
pub const TURN: f64 = 0.9; // radians a second, hard over
const ACCEL: f64 = 1.5; // rate it closes on what the pilot asks, per second
/// How near the helm (feet to the helm's middle) the pilot has to stand.
pub const HELM_REACH: f64 = 2.5;
/// A ship's blocks stay within this many cells of its middle, across.
pub const LIMIT: i32 = 12;
/// And this many below and above its deck.
pub const LIMIT_Z: i32 = 8;
/// Collision points sit this far inside a block's faces, so blocks that
/// only touch don't collide.
const INSET: f64 = 0.1;

/// Where a ship's frame is in the world: its middle at deck level, turned
/// `h` radians about z.
#[derive(Clone, Copy, Debug, PartialEq, Default, Serialize, Deserialize)]
pub struct Pose {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub h: f64,
}

impl Pose {
    pub fn new(x: f64, y: f64, z: f64, h: f64) -> Self {
        Pose { x, y, z, h }
    }

    pub fn to_world(self, l: (f64, f64, f64)) -> (f64, f64, f64) {
        let (c, s) = (self.h.cos(), self.h.sin());
        (
            self.x + l.0 * c - l.1 * s,
            self.y + l.0 * s + l.1 * c,
            self.z + l.2,
        )
    }

    pub fn to_local(self, w: (f64, f64, f64)) -> (f64, f64, f64) {
        let (c, s) = (self.h.cos(), self.h.sin());
        let (dx, dy) = (w.0 - self.x, w.1 - self.y);
        (dx * c + dy * s, -dx * s + dy * c, w.2 - self.z)
    }
}

/// What the pilot asks for, each -1..1: ahead (+) or astern, turn to port
/// (+) or starboard, climb (+) or sink.
#[derive(Clone, Copy, Debug, PartialEq, Default, Serialize, Deserialize)]
pub struct Helm {
    pub thrust: f64,
    pub turn: f64,
    pub lift: f64,
}

impl Helm {
    pub fn new(thrust: f64, turn: f64, lift: f64) -> Self {
        let c = |v: f64| if v.is_finite() { v.clamp(-1.0, 1.0) } else { 0.0 };
        Helm {
            thrust: c(thrust),
            turn: c(turn),
            lift: c(lift),
        }
    }
}

/// A side of the universe, to cross into the neighbour there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    East,
    West,
    North,
    South,
}

impl Side {
    pub const ALL: [Side; 4] = [Side::East, Side::West, Side::North, Side::South];

    pub fn index(self) -> usize {
        self as usize
    }

    /// The step to the neighbour, in universe grid coordinates (+y north).
    pub fn step(self) -> (i32, i32) {
        match self {
            Side::East => (1, 0),
            Side::West => (-1, 0),
            Side::North => (0, 1),
            Side::South => (0, -1),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Side::East => "east",
            Side::West => "west",
            Side::North => "north",
            Side::South => "south",
        }
    }

    pub fn from_name(s: &str) -> Option<Side> {
        Side::ALL.into_iter().find(|d| d.name() == s)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Ship {
    pub id: u32,
    pub pose: Pose,
    /// Ahead (tiles a second, along its heading), climbing, turning.
    #[serde(default)]
    pub speed: f64,
    #[serde(default)]
    pub vz: f64,
    #[serde(default)]
    pub spin: f64,
    #[serde(default)]
    pub helm: Helm,
    #[serde(with = "cells")]
    pub blocks: BTreeMap<Pos, u8>,
    /// Where it waits when nobody needs it.
    pub dock: Pose,
    /// Who's at the helm, by player id.
    #[serde(default)]
    pub pilot: Option<String>,
    /// Who's standing on it, and where (feet, in its frame), as of the last
    /// tick.
    #[serde(skip)]
    pub riders: Vec<(String, (f64, f64, f64))>,
    /// Since when (ms) the pilot hasn't been seen.
    #[serde(skip)]
    pub pilot_gone: Option<i64>,
    #[serde(skip)]
    pub sent: Option<(f64, f64, f64, f64)>,
}

/// Blocks as a list of `[x, y, z, block]`: JSON keys can't be tuples.
mod cells {
    use std::collections::BTreeMap;

    use serde::{Deserialize, Deserializer, Serializer};

    use crate::terrain::Pos;

    pub fn serialize<S: Serializer>(m: &BTreeMap<Pos, u8>, s: S) -> Result<S::Ok, S::Error> {
        s.collect_seq(m.iter().map(|(p, b)| (p.0, p.1, p.2, *b)))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<BTreeMap<Pos, u8>, D::Error> {
        let v: Vec<(i32, i32, i32, u8)> = Vec::deserialize(d)?;
        Ok(v.into_iter().map(|(x, y, z, b)| ((x, y, z), b)).collect())
    }
}

/// The ship every universe starts with: a hull, a deck with rails (open
/// amidships to step aboard), the helm at the stern, and a balloon on four
/// masts.
pub fn standard_blocks() -> BTreeMap<Pos, u8> {
    let mut b = BTreeMap::new();
    for x in -2..=2 {
        b.insert((x, 0, -3), HULL);
    }
    for x in -3..=3 {
        for y in -1..=1 {
            b.insert((x, y, -2), HULL);
        }
    }
    for x in -4..=4 {
        for y in -2..=2 {
            b.insert((x, y, -1), DECK);
        }
    }
    for x in -3..=4 {
        if x == 0 || x == -1 {
            continue;
        }
        b.insert((x, -2, 0), RAIL);
        b.insert((x, 2, 0), RAIL);
    }
    for y in -1..=1 {
        b.insert((4, y, 0), RAIL);
    }
    b.insert((-3, 0, 0), HELM);
    for (x, y) in [(-2, -1), (-2, 1), (2, -1), (2, 1)] {
        for z in 0..=2 {
            b.insert((x, y, z), WOOD);
        }
    }
    for x in -3..=3 {
        for y in -2..=2 {
            for z in 3..=4 {
                b.insert((x, y, z), BALLOON);
            }
        }
    }
    b
}

/// Can a ship hold block `p`?
pub fn within(p: Pos) -> bool {
    p.0.abs() <= LIMIT && p.1.abs() <= LIMIT && p.2.abs() <= LIMIT_Z
}

/// The points a block is tested by: its corners, pulled in by INSET, and
/// its middle.
fn samples(p: Pos) -> [(f64, f64, f64); 9] {
    let (x, y, z) = (p.0 as f64, p.1 as f64, p.2 as f64);
    let e = 0.5 - INSET;
    let (lo, hi) = (z + INSET, z + 1.0 - INSET);
    [
        (x - e, y - e, lo),
        (x + e, y - e, lo),
        (x - e, y + e, lo),
        (x + e, y + e, lo),
        (x - e, y - e, hi),
        (x + e, y - e, hi),
        (x - e, y + e, hi),
        (x + e, y + e, hi),
        (x, y, z + 0.5),
    ]
}

fn cell_of(l: (f64, f64, f64)) -> Pos {
    (cell(l.0), cell(l.1), l.2.floor() as i32)
}

impl Ship {
    pub fn new(id: u32, blocks: BTreeMap<Pos, u8>, pose: Pose) -> Self {
        Ship {
            id,
            pose,
            speed: 0.0,
            vz: 0.0,
            spin: 0.0,
            helm: Helm::default(),
            blocks,
            dock: pose,
            pilot: None,
            riders: Vec::new(),
            pilot_gone: None,
            sent: None,
        }
    }

    pub fn standard(id: u32, pose: Pose) -> Self {
        Ship::new(id, standard_blocks(), pose)
    }

    pub fn get(&self, p: Pos) -> u8 {
        self.blocks.get(&p).copied().unwrap_or(AIR)
    }

    /// True if it changed.
    pub fn set(&mut self, p: Pos, id: u8) -> bool {
        if id == AIR {
            self.blocks.remove(&p).is_some()
        } else {
            self.blocks.insert(p, id) != Some(id)
        }
    }

    /// The middle of block `p`, in the world.
    pub fn center_of(&self, p: Pos) -> (f64, f64, f64) {
        self.pose
            .to_world((p.0 as f64, p.1 as f64, p.2 as f64 + 0.5))
    }

    pub fn helm_cell(&self) -> Option<Pos> {
        self.blocks
            .iter()
            .find(|(_, &b)| b == HELM)
            .map(|(p, _)| *p)
    }

    /// Furthest any block reaches from its middle, across.
    pub fn radius(&self) -> f64 {
        self.blocks
            .keys()
            .map(|p| (p.0.abs() as f64 + 0.5).hypot(p.1.abs() as f64 + 0.5))
            .fold(0.0, f64::max)
    }

    /// Where feet rest at local (x, y) for someone at local height z: the
    /// top of the highest block at most one above their feet, as
    /// `Terrain::ground` does. Local heights.
    pub fn ground_local(&self, l: (f64, f64, f64)) -> Option<f64> {
        let (cx, cy) = (cell(l.0), cell(l.1));
        let top = (l.2 + 0.01).floor() as i32;
        (top - 6..=top)
            .rev()
            .find(|&z| self.get((cx, cy, z)) != AIR)
            .map(|z| z as f64 + 1.0)
    }

    /// Standing on it at world point `w`: where (local feet), if its deck
    /// (or any block) is underfoot.
    pub fn underfoot(&self, w: (f64, f64, f64)) -> Option<(f64, f64, f64)> {
        let l = self.pose.to_local(w);
        let g = self.ground_local(l)?;
        ((l.2 - g).abs() < 1.1).then_some((l.0, l.1, g))
    }

    fn hits_terrain(&self, pose: &Pose, t: &Terrain) -> bool {
        self.blocks.keys().any(|&p| {
            samples(p).iter().any(|&s| {
                let w = pose.to_world(s);
                let c = (cell(w.0), cell(w.1), w.2.floor() as i32);
                !matches!(t.get(c.0, c.1, c.2), None | Some(AIR) | Some(WATER))
            })
        })
    }

    /// Would this ship at `pose` overlap `other` where it is?
    fn hits_ship(&self, pose: &Pose, other: &Ship) -> bool {
        let gap = (pose.x - other.pose.x).hypot(pose.y - other.pose.y);
        if gap > self.radius() + other.radius() + 1.0 {
            return false;
        }
        let mine = self.blocks.keys().any(|&p| {
            samples(p).iter().any(|&s| {
                let w = pose.to_world(s);
                other.get(cell_of(other.pose.to_local(w))) != AIR
            })
        });
        mine || other.blocks.keys().any(|&p| {
            samples(p).iter().any(|&s| {
                let w = other.pose.to_world(s);
                self.get(cell_of(pose.to_local(w))) != AIR
            })
        })
    }

    /// Would it overlap the world's blocks or another ship at `pose`?
    pub fn collides(&self, pose: &Pose, t: &Terrain, others: &[&Ship]) -> bool {
        self.hits_terrain(pose, t) || others.iter().any(|o| self.hits_ship(pose, o))
    }

    /// Room for a new block at `p`, where the ship is now.
    pub fn room_for(&self, p: Pos, t: &Terrain, others: &[&Ship]) -> bool {
        let mut one = Ship::new(self.id, BTreeMap::new(), self.pose);
        one.blocks.insert(p, DECK);
        !one.collides(&self.pose, t, others)
    }

    fn z_range(&self) -> (f64, f64) {
        let lo = self.blocks.keys().map(|p| p.2).min().unwrap_or(0);
        let hi = self.blocks.keys().map(|p| p.2).max().unwrap_or(0);
        ((Z_MIN - lo + 1) as f64, (Z_MAX - hi - 2) as f64)
    }

    /// Move for `dt` seconds as the pilot asks, if anyone's at the helm.
    /// Returns the side it flew out of, if it crossed one with a neighbour
    /// (`open`, by `Side::index`); the caller hands it over. A side without
    /// one stops it, as do blocks: it slides along what it can't go through.
    pub fn step(
        &mut self,
        t: &Terrain,
        others: &[&Ship],
        dt: f64,
        open: [bool; 4],
    ) -> Option<Side> {
        if self.pilot.is_none() {
            self.helm = Helm::default();
        }
        let k = (ACCEL * dt).min(1.0);
        self.speed += (self.helm.thrust * SPEED - self.speed) * k;
        self.spin += (self.helm.turn * TURN - self.spin) * k;
        self.vz += (self.helm.lift * CLIMB - self.vz) * k;
        for v in [&mut self.speed, &mut self.spin, &mut self.vz] {
            if v.abs() < 0.01 {
                *v = 0.0;
            }
        }
        if self.speed == 0.0 && self.spin == 0.0 && self.vz == 0.0 {
            return None;
        }

        // wedged in already (built into, arrived inside an island): let it
        // move until it's free
        let stuck = self.collides(&self.pose, t, others);
        let fits = |s: &Ship, p: &Pose| stuck || !s.collides(p, t, others);
        let mut p = self.pose;
        if self.spin != 0.0 {
            let q = Pose {
                h: wrap(p.h + self.spin * dt),
                ..p
            };
            if fits(self, &q) {
                p = q;
            } else {
                self.spin = 0.0;
            }
        }
        let (dx, dy) = (p.h.cos() * self.speed * dt, p.h.sin() * self.speed * dt);
        let mut blocked = 0;
        if dx != 0.0 {
            let q = Pose { x: p.x + dx, ..p };
            if fits(self, &q) {
                p = q;
            } else {
                blocked += 1;
            }
        }
        if dy != 0.0 {
            let q = Pose { y: p.y + dy, ..p };
            if fits(self, &q) {
                p = q;
            } else {
                blocked += 1;
            }
        }
        if blocked == 2 {
            self.speed = 0.0;
        }
        if self.vz != 0.0 {
            let (lo, hi) = self.z_range();
            let q = Pose {
                z: (p.z + self.vz * dt).clamp(lo, hi),
                ..p
            };
            if fits(self, &q) {
                p = q;
            } else {
                self.vz = 0.0;
            }
        }
        self.pose = p;

        // the universe's edge: cross, or stop
        let edge = HALF as f64 - 0.5;
        let out = [
            (self.pose.x > edge, Side::East),
            (self.pose.x < -edge - 1.0, Side::West),
            (self.pose.y > edge, Side::North),
            (self.pose.y < -edge - 1.0, Side::South),
        ];
        for (past, side) in out {
            if !past {
                continue;
            }
            if open[side.index()] {
                return Some(side);
            }
            match side {
                Side::East => self.pose.x = edge,
                Side::West => self.pose.x = -edge - 1.0,
                Side::North => self.pose.y = edge,
                Side::South => self.pose.y = -edge - 1.0,
            }
        }
        None
    }

    /// Arriving from the neighbour on `from`: come in at our opposite edge.
    pub fn enter_from(&mut self, from: Side) {
        let w = 2.0 * HALF as f64;
        match from {
            // it flew out of the east edge of the universe to our west
            Side::West => self.pose.x -= w,
            Side::East => self.pose.x += w,
            Side::South => self.pose.y -= w,
            Side::North => self.pose.y += w,
        }
        self.sent = None;
    }

    /// Stopped where it is, nobody at the helm.
    pub fn halt(&mut self) {
        self.speed = 0.0;
        self.vz = 0.0;
        self.spin = 0.0;
        self.helm = Helm::default();
    }

    /// World velocity: (vx, vy, vz, spin).
    pub fn velocity(&self) -> (f64, f64, f64, f64) {
        let h = self.pose.h;
        (
            h.cos() * self.speed,
            h.sin() * self.speed,
            self.vz,
            self.spin,
        )
    }
}

pub fn wrap(a: f64) -> f64 {
    let tau = std::f64::consts::TAU;
    (a + std::f64::consts::PI).rem_euclid(tau) - std::f64::consts::PI
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terrain::{islands, Terrain, STONE};

    fn sky() -> Terrain {
        // universe (0, 0): the plaza, r 18 around the origin, floor at z 0
        Terrain::generate(&islands(0, 0, 1)[..1])
    }

    fn fly(s: &mut Ship, t: &Terrain, others: &[&Ship], secs: f64, open: [bool; 4]) -> Option<Side> {
        let mut n = 0.0;
        while n < secs {
            if let Some(side) = s.step(t, others, 0.1, open) {
                return Some(side);
            }
            n += 0.1;
        }
        None
    }

    fn piloted(id: u32, pose: Pose) -> Ship {
        let mut s = Ship::standard(id, pose);
        s.pilot = Some("p".into());
        s
    }

    #[test]
    fn poses_round_trip() {
        let p = Pose::new(3.0, -2.0, 5.0, 1.1);
        let w = p.to_world((1.5, -0.5, 2.0));
        let l = p.to_local(w);
        assert!((l.0 - 1.5).abs() < 1e-9 && (l.1 + 0.5).abs() < 1e-9 && (l.2 - 2.0).abs() < 1e-9);
        let q = Pose::new(0.0, 0.0, 0.0, std::f64::consts::FRAC_PI_2);
        let w = q.to_world((1.0, 0.0, 0.0));
        assert!(w.0.abs() < 1e-9 && (w.1 - 1.0).abs() < 1e-9, "ahead is +y at a quarter turn");
    }

    #[test]
    fn it_flies_ahead_and_turns_but_not_through_islands() {
        let t = sky();
        // east of the plaza (r 18), heading west at it, deck level with it
        let mut s = piloted(1, Pose::new(30.0, 0.0, 1.0, std::f64::consts::PI));
        assert!(!s.collides(&s.pose, &t, &[]));
        assert!(s.collides(&Pose::new(10.0, 0.0, 1.0, 0.0), &t, &[]), "inside the plaza");
        s.helm = Helm::new(1.0, 0.0, 0.0);
        fly(&mut s, &t, &[], 10.0, [false; 4]);
        // its hull stopped against the rim, its bow (4.5 ahead) over it
        assert!(s.pose.x > 18.0 && s.pose.x < 25.0, "x {}", s.pose.x);
        let stopped = s.pose.x;
        // up and over
        s.helm = Helm::new(0.0, 0.0, 1.0);
        fly(&mut s, &t, &[], 3.0, [false; 4]);
        assert!(s.pose.z > 4.0, "z {}", s.pose.z);
        s.helm = Helm::new(1.0, 0.0, 0.0);
        fly(&mut s, &t, &[], 3.0, [false; 4]);
        assert!(s.pose.x < stopped - 8.0, "over the plaza now: {}", s.pose.x);
        // turning to port
        let h0 = s.pose.h;
        s.helm = Helm::new(0.0, 1.0, 0.0);
        fly(&mut s, &t, &[], 1.0, [false; 4]);
        assert!(wrap(s.pose.h - h0) > 0.2, "turned {}", wrap(s.pose.h - h0));
    }

    #[test]
    fn no_pilot_no_flying() {
        let t = sky();
        let mut s = Ship::standard(1, Pose::new(30.0, 0.0, 1.0, 0.0));
        s.helm = Helm::new(1.0, 0.0, 0.0);
        fly(&mut s, &t, &[], 2.0, [false; 4]);
        assert_eq!(s.pose.x, 30.0);
    }

    #[test]
    fn ships_bump_into_each_other() {
        let t = sky();
        let other = Ship::standard(2, Pose::new(40.0, 0.0, 1.0, std::f64::consts::FRAC_PI_2));
        let mut s = piloted(1, Pose::new(25.0, 0.0, 1.0, 0.0));
        s.helm = Helm::new(1.0, 0.0, 0.0);
        fly(&mut s, &t, &[&other], 6.0, [false; 4]);
        // the other lies across our way, 2.5 wide each side of x 40; our bow
        // is 4.5 ahead
        assert!(s.pose.x < 40.0 - 2.5 - 4.0 && s.pose.x > 30.0, "x {}", s.pose.x);
        assert!(!s.collides(&s.pose, &t, &[&other]));
        // a ship well above passes over
        let mut high = piloted(3, Pose::new(25.0, 0.0, 12.0, 0.0));
        high.helm = Helm::new(1.0, 0.0, 0.0);
        fly(&mut high, &t, &[&other], 6.0, [false; 4]);
        assert!(high.pose.x > 45.0);
    }

    #[test]
    fn the_edge_stops_it_unless_theres_a_neighbour() {
        let mut t = sky();
        let mut s = piloted(1, Pose::new(40.0, 0.0, 1.0, 0.0));
        s.helm = Helm::new(1.0, 0.0, 0.0);
        assert_eq!(fly(&mut s, &t, &[], 5.0, [false; 4]), None);
        assert_eq!(s.pose.x, HALF as f64 - 0.5);
        assert_eq!(
            fly(&mut s, &t, &[], 5.0, [true, false, false, false]),
            Some(Side::East)
        );
        s.enter_from(Side::West);
        assert!(s.pose.x < -HALF as f64 + 1.0);
        // and blocks still stop it in the next one
        t.set(-40, 0, 0, STONE);
        assert!(s.collides(&Pose::new(-40.0, 0.0, 1.0, 0.0), &t, &[]));
    }

    #[test]
    fn standing_on_deck() {
        let s = Ship::standard(1, Pose::new(10.0, 10.0, 5.0, std::f64::consts::FRAC_PI_2));
        // a quarter turn: local +x (ahead) is world +y
        let on = s.underfoot((10.0, 11.0, 5.0)).expect("on deck");
        assert!((on.0 - 1.0).abs() < 1e-9 && on.1.abs() < 1e-9 && on.2 == 0.0);
        assert_eq!(s.underfoot((10.0, 30.0, 5.0)), None, "off the bow");
        assert_eq!(s.underfoot((10.0, 11.0, 20.0)), None, "well above it");
        // on top of the balloon
        assert_eq!(s.underfoot((10.0, 11.0, 9.8)).map(|l| l.2), Some(5.0));
        assert_eq!(s.get(cell_of(s.pose.to_local(s.center_of((-3, 0, 0))))), HELM);
    }

    #[test]
    fn saves_as_json() {
        let s = Ship::standard(4, Pose::new(1.0, 2.0, 3.0, 0.5));
        let json = serde_json::to_string(&s).unwrap();
        let back: Ship = serde_json::from_str(&json).unwrap();
        assert_eq!(back.blocks, s.blocks);
        assert_eq!(back.pose, s.pose);
    }
}
