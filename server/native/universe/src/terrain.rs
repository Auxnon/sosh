//! A universe's blocks: 16x16x16 chunks of one-byte block ids, and the
//! floating islands they start out as.
//!
//! A universe is a box of cells x, y in -HALF..HALF and z in Z_MIN..Z_MAX.
//! Nothing exists outside it: reads there are None and writes are refused.
//! Its islands are generated from the universe's seed; Postgres keeps only
//! the chunks someone has changed (`Sosh.World`).
//!
//! Coordinates are Z-up like the client: a block at integer (x, y, z) spans
//! x-0.5..x+0.5, y-0.5..y+0.5 and z..z+1, so standing on it puts your feet
//! at z + 1.

use std::collections::{HashMap, HashSet};

pub const CHUNK: i32 = 16;
pub const CHUNK_VOLUME: usize = (CHUNK * CHUNK * CHUNK) as usize;
/// Cells run -HALF..HALF on x and y: a universe is 96 blocks across.
pub const HALF: i32 = 48;
pub const Z_MIN: i32 = -32;
pub const Z_MAX: i32 = 32;

pub const AIR: u8 = 0;
pub const GRASS: u8 = 1;
pub const DIRT: u8 = 2;
pub const STONE: u8 = 3;
pub const WOOD: u8 = 4;
pub const PATH: u8 = 5;
pub const WATER: u8 = 6;
pub const POT: u8 = 7;
/// A cell taken by furniture: solid, drawn by the furniture's own model.
pub const FURNITURE: u8 = 8;
/// A cell taken by a blueprint being built: solid, drawn as scaffolding.
pub const SCAFFOLD: u8 = 9;
// what airships are built of (any of them can go on an island too)
pub const DECK: u8 = 10;
pub const HULL: u8 = 11;
pub const BALLOON: u8 = 12;
pub const RAIL: u8 = 13;
/// Whoever stands at it steers its ship.
pub const HELM: u8 = 14;

pub type Pos = (i32, i32, i32);

/// Every chunk key of a universe: 6 x 6 x 4 chunks.
pub fn chunk_keys() -> impl Iterator<Item = Pos> {
    let h = HALF / CHUNK;
    let (zl, zh) = (Z_MIN / CHUNK, Z_MAX / CHUNK);
    (zl..zh).flat_map(move |cz| (-h..h).flat_map(move |cy| (-h..h).map(move |cx| (cx, cy, cz))))
}

pub fn in_bounds(x: i32, y: i32, z: i32) -> bool {
    (-HALF..HALF).contains(&x) && (-HALF..HALF).contains(&y) && (Z_MIN..Z_MAX).contains(&z)
}

/// The cell a coordinate falls in.
pub fn cell(v: f64) -> i32 {
    (v + 0.5).floor() as i32
}

/// Chunk key and index within it (x fastest, then y, then z), as Sosh.World.
pub fn locate(x: i32, y: i32, z: i32) -> (Pos, usize) {
    let key = (
        x.div_euclid(CHUNK),
        y.div_euclid(CHUNK),
        z.div_euclid(CHUNK),
    );
    let i = x.rem_euclid(CHUNK) + y.rem_euclid(CHUNK) * CHUNK + z.rem_euclid(CHUNK) * CHUNK * CHUNK;
    (key, i as usize)
}

#[derive(Default)]
pub struct Terrain {
    chunks: HashMap<Pos, Box<[u8]>>,
    /// Chunks changed since the last `take_dirty`.
    dirty: HashSet<Pos>,
}

impl Terrain {
    /// Every chunk generated from `islands`.
    pub fn generate(islands: &[Island]) -> Self {
        let mut t = Terrain::default();
        for key in chunk_keys() {
            t.chunks.insert(key, gen_chunk(islands, key));
        }
        t
    }

    /// Replace a chunk with a saved one. False if it isn't one of ours.
    pub fn load_chunk(&mut self, key: Pos, blocks: &[u8]) -> bool {
        if blocks.len() != CHUNK_VOLUME || !self.chunks.contains_key(&key) {
            return false;
        }
        self.chunks.insert(key, blocks.into());
        true
    }

    pub fn chunk(&self, key: Pos) -> Option<&[u8]> {
        self.chunks.get(&key).map(|c| &c[..])
    }

    /// The chunks changed since last asked, to be saved.
    pub fn take_dirty(&mut self) -> Vec<Pos> {
        self.dirty.drain().collect()
    }

    /// None outside the universe.
    pub fn get(&self, x: i32, y: i32, z: i32) -> Option<u8> {
        if !in_bounds(x, y, z) {
            return None;
        }
        let (key, i) = locate(x, y, z);
        self.chunks.get(&key).map(|c| c[i])
    }

    /// False outside the universe.
    pub fn set(&mut self, x: i32, y: i32, z: i32, id: u8) -> bool {
        if !in_bounds(x, y, z) {
            return false;
        }
        let (key, i) = locate(x, y, z);
        match self.chunks.get_mut(&key) {
            Some(c) => {
                if c[i] != id {
                    c[i] = id;
                    self.dirty.insert(key);
                }
                true
            }
            None => false,
        }
    }

    /// Where feet rest at (x, y) for someone at height z: the top of the
    /// highest solid block at most one above their feet. None over water or
    /// the open air. Mirrors the client's Blocks.ground.
    pub fn ground(&self, x: f64, y: f64, z: f64) -> Option<f64> {
        let cx = cell(x);
        let cy = cell(y);
        let mut bz = (z + 0.01).floor() as i32;
        let stop = bz - 24;
        while bz >= stop {
            match self.get(cx, cy, bz)? {
                AIR => bz -= 1,
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
        self.get(cx, cy, gz) == Some(AIR) && self.get(cx, cy, gz + 1) == Some(AIR)
    }

    /// Every cell holding one of `ids`.
    pub fn find(&self, ids: &[u8]) -> Vec<Pos> {
        let mut out = Vec::new();
        for (key, c) in &self.chunks {
            for (i, b) in c.iter().enumerate() {
                if ids.contains(b) {
                    let i = i as i32;
                    out.push((
                        key.0 * CHUNK + i % CHUNK,
                        key.1 * CHUNK + (i / CHUNK) % CHUNK,
                        key.2 * CHUNK + i / (CHUNK * CHUNK),
                    ));
                }
            }
        }
        out
    }

    /// Run-length encode a chunk as `[id, count, id, count, ...]`.
    pub fn rle(&self, key: Pos) -> Option<Vec<u32>> {
        let c = self.chunks.get(&key)?;
        let mut out = Vec::new();
        let mut run = (c[0], 0u32);
        for &b in c.iter() {
            if b == run.0 {
                run.1 += 1;
            } else {
                out.extend([run.0 as u32, run.1]);
                run = (b, 1);
            }
        }
        out.extend([run.0 as u32, run.1]);
        Some(out)
    }
}

// -- islands

/// A floating island: a disc of grass over dirt over a stone underside that
/// tapers to a point. The plaza is universe (0, 0)'s first island, laid out
/// as the original plaza was.
#[derive(Clone, Debug, PartialEq)]
pub struct Island {
    pub x: i32,
    pub y: i32,
    /// The z of its grass; you stand at top + 1.
    pub top: i32,
    pub r: f64,
    pub plaza: bool,
    /// Shapes its outline.
    pub phase: f64,
    /// A wood pile: where, and how many logs.
    pub logs: Option<(i32, i32, i32)>,
}

const PLAZA_R: f64 = 18.0;
const POND: (f64, f64, f64) = (7.0, -6.0, 3.2);
const PLAZA_DEPTH: i32 = 4;

/// The islands of universe (gx, gy). The first is its home: where people
/// spawn, its helper lives and its airships dock.
pub fn islands(gx: i32, gy: i32, seed: u64) -> Vec<Island> {
    let mut rng = Rng::new(
        seed ^ (gx as i64 as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
            ^ (gy as i64 as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F),
    );
    let mut out = Vec::new();
    if (gx, gy) == (0, 0) {
        out.push(Island {
            x: 0,
            y: 0,
            top: -1,
            r: PLAZA_R,
            plaza: true,
            phase: 0.0,
            logs: None,
        });
    }
    let want = if out.is_empty() { 5 } else { 4 };
    let mut tries = 0;
    while out.len() < want && tries < 400 {
        tries += 1;
        let r = if out.is_empty() {
            10.0 + rng.next() * 4.0
        } else {
            5.0 + rng.next() * 5.0
        };
        // room for the wobble, and a ship's width to the edge
        let lim = HALF as f64 - r * 1.15 - 3.0;
        let x = ((rng.next() * 2.0 - 1.0) * lim).round() as i32;
        let y = ((rng.next() * 2.0 - 1.0) * lim).round() as i32;
        let clear = out.iter().all(|o: &Island| {
            let d = ((o.x - x) as f64).hypot((o.y - y) as f64);
            d > (o.r + r) * 1.15 + 7.0
        });
        if !clear {
            continue;
        }
        let top = -6 + (rng.next() * 13.0) as i32;
        let phase = rng.next() * std::f64::consts::TAU;
        let logs = if rng.next() < 0.8 {
            let a = rng.next() * std::f64::consts::TAU;
            let d = rng.next() * r * 0.5;
            Some((
                x + (a.cos() * d).round() as i32,
                y + (a.sin() * d).round() as i32,
                2 + (rng.next() * 3.0) as i32,
            ))
        } else {
            None
        };
        out.push(Island {
            x,
            y,
            top,
            r,
            plaza: false,
            phase,
            logs,
        });
    }
    out
}

fn gen_chunk(islands: &[Island], key: Pos) -> Box<[u8]> {
    let mut c = vec![AIR; CHUNK_VOLUME].into_boxed_slice();
    let (bx, by, bz) = (key.0 * CHUNK, key.1 * CHUNK, key.2 * CHUNK);
    for i in islands {
        // skip islands nowhere near this chunk
        let reach = i.r * 1.2 + 1.0;
        let nx = ((bx as f64 + 7.5) - i.x as f64).abs() - 8.0;
        let ny = ((by as f64 + 7.5) - i.y as f64).abs() - 8.0;
        if nx > reach || ny > reach {
            continue;
        }
        for lz in 0..CHUNK {
            for ly in 0..CHUNK {
                for lx in 0..CHUNK {
                    let b = island_block(i, bx + lx, by + ly, bz + lz);
                    if b != AIR {
                        c[(lx + ly * CHUNK + lz * CHUNK * CHUNK) as usize] = b;
                    }
                }
            }
        }
    }
    c
}

fn island_block(i: &Island, x: i32, y: i32, z: i32) -> u8 {
    if i.plaza {
        return plaza_block(x - i.x, y - i.y, z - i.top - 1);
    }
    if let Some((lx, ly, n)) = i.logs {
        if x == lx && y == ly && z > i.top && z <= i.top + n {
            return WOOD;
        }
    }
    let (dx, dy) = ((x - i.x) as f64, (y - i.y) as f64);
    let d = dx.hypot(dy);
    let a = dy.atan2(dx);
    let edge =
        i.r * (1.0 + 0.12 * (a * 3.0 + i.phase).sin() + 0.05 * (a * 7.0 + i.phase * 2.0).sin());
    if d > edge || z > i.top {
        return AIR;
    }
    // the underside: deepest in the middle, a few blocks at the rim
    let depth = 2.0 + (edge - d) * 0.75;
    let below = i.top - z;
    if below as f64 > depth {
        AIR
    } else if below == 0 {
        GRASS
    } else if below <= 2 {
        DIRT
    } else {
        STONE
    }
}

/// The original plaza, with its floor's top at z = 0 (the island's top + 1).
fn plaza_block(x: i32, y: i32, z: i32) -> u8 {
    let (xf, yf) = (x as f64, y as f64);
    let d = (xf * xf + yf * yf).sqrt();
    let (px, py, pr) = POND;
    let pond = ((xf - px) * (xf - px) + (yf - py) * (yf - py)).sqrt() < pr;
    if z >= 0 || z < -PLAZA_DEPTH || d > PLAZA_R {
        AIR
    } else if z < -2 {
        STONE
    } else if z == -2 {
        DIRT
    } else if pond {
        WATER
    } else if d > PLAZA_R - 1.5 {
        STONE
    } else if x == 0 || y == 0 || (d > 4.5 && d < 6.0) {
        PATH
    } else {
        GRASS
    }
}

/// xorshift64*, uniform in [0, 1).
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        // splitmix the seed so nearby seeds don't start alike
        let mut z = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        Rng((z ^ (z >> 31)) | 1)
    }

    pub fn next(&mut self) -> f64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        (x.wrapping_mul(0x2545F4914F6CDD1D) >> 11) as f64 / (1u64 << 53) as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plaza_is_where_it_always_was() {
        let t = Terrain::generate(&islands(0, 0, 7));
        assert_eq!(t.get(2, 2, -1), Some(GRASS));
        assert_eq!(t.get(0, 5, -1), Some(PATH));
        assert_eq!(t.get(7, -6, -1), Some(WATER));
        assert_eq!(t.get(17, 0, -1), Some(STONE));
        assert_eq!(t.get(2, 2, -2), Some(DIRT));
        assert_eq!(t.get(2, 2, -4), Some(STONE));
        assert_eq!(t.get(2, 2, -5), Some(AIR));
        assert_eq!(t.get(2, 2, 0), Some(AIR));
        assert_eq!(t.ground(2.0, 2.0, 0.0), Some(0.0));
        assert!(t.walkable(2.0, 2.0, 0.0));
    }

    #[test]
    fn islands_float_apart_inside_the_universe() {
        for (gx, gy) in [(0, 0), (1, 0), (-3, 7)] {
            let is = islands(gx, gy, 99);
            assert!(is.len() >= 3, "{gx},{gy}: {}", is.len());
            assert_eq!(is, islands(gx, gy, 99), "same seed, same islands");
            for (n, a) in is.iter().enumerate() {
                assert!((a.x.abs() as f64) + a.r * 1.15 < HALF as f64);
                for b in &is[n + 1..] {
                    let d = ((a.x - b.x) as f64).hypot((a.y - b.y) as f64);
                    assert!(d > a.r + b.r, "islands overlap");
                }
            }
            let t = Terrain::generate(&is);
            let home = &is[0];
            assert!(t.walkable(home.x as f64, home.y as f64, home.top as f64 + 1.0));
            // nothing under an island but sky
            assert!(t
                .ground(home.x as f64, home.y as f64, home.top as f64 - 18.0)
                .is_none());
        }
        assert_ne!(islands(1, 0, 99), islands(0, 1, 99));
    }

    #[test]
    fn bounds_and_dirty_chunks() {
        let mut t = Terrain::generate(&islands(0, 0, 7));
        assert_eq!(t.get(HALF, 0, 0), None);
        assert!(!t.set(-HALF - 1, 0, 0, STONE));
        assert!(t.take_dirty().is_empty());
        assert!(t.set(3, 3, 0, STONE));
        assert!(t.set(3, 3, 0, STONE));
        assert_eq!(t.take_dirty(), vec![(0, 0, 0)]);
        assert!(t.take_dirty().is_empty());
        assert_eq!(chunk_keys().count(), 144);
        let rle = t.rle((0, 0, 1)).unwrap();
        assert_eq!(rle, vec![0, 4096]);
    }
}
