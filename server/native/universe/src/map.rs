//! A universe's map: a rough isometric picture of its blocks (the islands,
//! what's been built on them, and its airships), seen from above one
//! corner, on a sky. Servers use it as their banner (`Sosh.Maps`).
//!
//! Each block is a little cube, drawn back to front. The view looks down
//! (1, 1, 1), so a cube shows its top and its +x (right) and +y (left)
//! faces, and the cubes nearer the viewer (a larger x + y + z) go over the
//! ones behind. Only blocks with one of those faces open are drawn.

use hashbrown::HashMap;

use crate::ships::Ship;
use crate::terrain::{
    self, Terrain, AIR, BALLOON, DECK, DIRT, FURNITURE, GRASS, HALF, HELM, HULL, PATH, POT, RAIL, SCAFFOLD, STONE,
    WATER, WOOD, Z_MAX, Z_MIN,
};

/// Pixels per unit of the projection: a block is 4S wide and 4S tall.
const S: i32 = 2;
const CUBE: i32 = 4 * S;
/// Kept around the blocks, and the picture's width over its height.
const MARGIN: i32 = 12;
const ASPECT: f64 = 2.0;
const SKY_TOP: [u8; 3] = [0x8F, 0xC9, 0xF2];
const SKY_LOW: [u8; 3] = [0xE4, 0xF3, 0xFB];

pub struct Picture {
    pub w: u32,
    pub h: u32,
    /// Rows of RGB, top first.
    pub rgb: Vec<u8>,
}

fn color(id: u8) -> Option<[u8; 3]> {
    Some(match id {
        GRASS => [0x70, 0xA8, 0x60],
        DIRT => [0x86, 0x60, 0x3E],
        STONE => [0x78, 0x7C, 0x88],
        WOOD | DECK => [0xA8, 0x78, 0x48],
        PATH => [0xC4, 0xB2, 0x8C],
        WATER => [0x4A, 0x90, 0xD8],
        POT => [0xC4, 0x68, 0x3E],
        FURNITURE => [0xC4, 0x96, 0x6A],
        SCAFFOLD => [0xD8, 0xB0, 0x60],
        HULL => [0x6B, 0x4A, 0x2B],
        BALLOON => [0xE8, 0x5D, 0x5D],
        RAIL => [0x7A, 0x52, 0x30],
        HELM => [0x5A, 0x3A, 0x1A],
        AIR => return None,
        _ => [0x99, 0x99, 0x99],
    })
}

#[derive(Clone, Copy, PartialEq)]
enum Face {
    None,
    Top,
    Right,
    Left,
}

/// Which face of a cube each pixel of its CUBE x CUBE square shows.
fn sprite() -> Vec<Face> {
    let mut out = Vec::with_capacity((CUBE * CUBE) as usize);
    let (a, s) = (2.0 * S as f64, S as f64);
    for py in 0..CUBE {
        for px in 0..CUBE {
            // the pixel's centre from the cube's centre, in projection units:
            // u = (x - y)·2S, v = (x + y)·S - z·2S, for a cube [0,1]³
            let u = px as f64 + 0.5 - CUBE as f64 / 2.0;
            let v = py as f64 + 0.5 - CUBE as f64 / 2.0;
            let inside = |p: f64, q: f64| (0.0..=1.0).contains(&p) && (0.0..=1.0).contains(&q);
            // the top (z = 1)
            let (d, sum) = (u / a, (v + 2.0 * s) / s);
            let (x, y) = ((d + sum) / 2.0, (sum - d) / 2.0);
            let face = if inside(x, y) {
                Face::Top
            } else {
                // the right (x = 1): u = (1 - y)·2S
                let y = 1.0 - u / a;
                let z = ((1.0 + y) * s - v) / a;
                if inside(y, z) {
                    Face::Right
                } else {
                    // the left (y = 1): u = (x - 1)·2S
                    let x = 1.0 + u / a;
                    let z = ((x + 1.0) * s - v) / a;
                    if inside(x, z) { Face::Left } else { Face::None }
                }
            };
            out.push(face);
        }
    }
    out
}

/// The picture of `t` with `ships` (pocket rooms left out: they're far
/// above, out of reach).
pub fn render(t: &Terrain, ships: &[Ship]) -> Picture {
    let mut aboard: HashMap<(i32, i32, i32), u8> = HashMap::new();
    for s in ships.iter().filter(|s| s.pocket.is_none()) {
        for (&(lx, ly, lz), &id) in &s.blocks {
            let (x, y, z) = s.pose.to_world((lx as f64, ly as f64, lz as f64));
            aboard.insert((terrain::cell(x), terrain::cell(y), terrain::cell(z)), id);
        }
    }
    let at = |x: i32, y: i32, z: i32| aboard.get(&(x, y, z)).copied().or_else(|| t.get(x, y, z)).unwrap_or(AIR);
    let open = |x: i32, y: i32, z: i32| at(x + 1, y, z) == AIR || at(x, y + 1, z) == AIR || at(x, y, z + 1) == AIR;

    let mut blocks: Vec<(i32, i32, i32, u8)> = Vec::new();
    for z in Z_MIN..Z_MAX {
        for y in -HALF..HALF {
            for x in -HALF..HALF {
                if aboard.contains_key(&(x, y, z)) {
                    continue;
                }
                let id = t.get(x, y, z).unwrap_or(AIR);
                if id != AIR && open(x, y, z) {
                    blocks.push((x, y, z, id));
                }
            }
        }
    }
    for (&(x, y, z), &id) in &aboard {
        if id != AIR && open(x, y, z) {
            blocks.push((x, y, z, id));
        }
    }
    // back to front
    blocks.sort_unstable_by_key(|&(x, y, z, _)| (x + y + z, z, x));

    // a cube's top left corner on the page
    let corner = |x: i32, y: i32, z: i32| ((x - y) * 2 * S - CUBE / 2, (x + y) * S - z * 2 * S - CUBE / 2);

    // the page: the blocks' extent plus a margin, widened or heightened to
    // ASPECT around them; a whole universe's worth if there are none
    let (mut l, mut tp, mut r, mut b) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
    for &(x, y, z, _) in &blocks {
        let (cx, cy) = corner(x, y, z);
        l = l.min(cx);
        tp = tp.min(cy);
        r = r.max(cx + CUBE);
        b = b.max(cy + CUBE);
    }
    if blocks.is_empty() {
        (l, tp, r, b) = (-HALF * 4 * S, -HALF * 2 * S, HALF * 4 * S, HALF * 2 * S);
    }
    let (mut w, mut h) = (r - l + 2 * MARGIN, b - tp + 2 * MARGIN);
    let (mut ox, mut oy) = (l - MARGIN, tp - MARGIN);
    if (w as f64) < h as f64 * ASPECT {
        let nw = (h as f64 * ASPECT).ceil() as i32;
        ox -= (nw - w) / 2;
        w = nw;
    } else {
        let nh = (w as f64 / ASPECT).ceil() as i32;
        oy -= (nh - h) / 2;
        h = nh;
    }

    let mut rgb = Vec::with_capacity((w * h * 3) as usize);
    for py in 0..h {
        let f = py as f64 / (h - 1).max(1) as f64;
        let c = mix(SKY_TOP, SKY_LOW, f);
        for _ in 0..w {
            rgb.extend_from_slice(&c);
        }
    }

    let faces = sprite();
    for &(x, y, z, id) in &blocks {
        let Some(base) = color(id) else { continue };
        let base = speckle(base, x, y, z);
        // a little haze on what's low
        let haze = ((Z_MAX - 1 - z) as f64 / (Z_MAX - Z_MIN) as f64 * 0.35).clamp(0.0, 0.35);
        let shade = |k: f64| mix(scale(base, k), SKY_LOW, haze);
        let (top, right, left) = (shade(1.0), shade(0.72), shade(0.86));
        let (cx, cy) = corner(x, y, z);
        for sy in 0..CUBE {
            let py = cy - oy + sy;
            if py < 0 || py >= h {
                continue;
            }
            for sx in 0..CUBE {
                let px = cx - ox + sx;
                if px < 0 || px >= w {
                    continue;
                }
                let c = match faces[(sy * CUBE + sx) as usize] {
                    Face::None => continue,
                    Face::Top => top,
                    Face::Right => right,
                    Face::Left => left,
                };
                let i = ((py * w + px) * 3) as usize;
                rgb[i..i + 3].copy_from_slice(&c);
            }
        }
    }
    Picture { w: w as u32, h: h as u32, rgb }
}

fn mix(a: [u8; 3], b: [u8; 3], f: f64) -> [u8; 3] {
    let m = |p: u8, q: u8| (p as f64 + (q as f64 - p as f64) * f).round().clamp(0.0, 255.0) as u8;
    [m(a[0], b[0]), m(a[1], b[1]), m(a[2], b[2])]
}

fn scale(c: [u8; 3], k: f64) -> [u8; 3] {
    let m = |p: u8| (p as f64 * k).round().clamp(0.0, 255.0) as u8;
    [m(c[0]), m(c[1]), m(c[2])]
}

/// The same block a touch lighter or darker by where it is, for texture.
fn speckle(c: [u8; 3], x: i32, y: i32, z: i32) -> [u8; 3] {
    let mut n = (x as u32).wrapping_mul(73_856_093) ^ (y as u32).wrapping_mul(19_349_663) ^ (z as u32).wrapping_mul(83_492_791);
    n ^= n >> 13;
    n = n.wrapping_mul(0x5bd1_e995);
    n ^= n >> 15;
    scale(c, 0.94 + (n % 13) as f64 / 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn green(c: &[u8]) -> bool {
        let (r, g, b) = (c[0] as i32, c[1] as i32, c[2] as i32);
        g > r + 20 && g > b + 20
    }

    #[test]
    fn a_cube_is_a_hexagon_of_three_faces() {
        let f = sprite();
        let count = |k: Face| f.iter().filter(|&&x| x == k).count();
        // the three faces are about the same size, and fill most of the square
        let (t, r, l) = (count(Face::Top), count(Face::Right), count(Face::Left));
        assert!(t > 0 && r > 0 && l > 0);
        assert!(t.abs_diff(r) <= 4 && r.abs_diff(l) <= 4, "{t} {r} {l}");
        assert!(t + r + l >= (CUBE * CUBE) as usize * 2 / 3);
        // the top's at the top, the right face on the right
        assert!(f[(CUBE / 2) as usize] == Face::Top);
        let low = ((CUBE - 2) * CUBE) as usize;
        assert!(f[low + 1] == Face::Left && f[low + CUBE as usize - 2] == Face::Right);
    }

    #[test]
    fn a_universe_draws_its_islands_on_the_sky() {
        let islands = terrain::islands(0, 0, 7);
        let t = Terrain::generate(&islands);
        let p = render(&t, &[]);
        assert_eq!(p.rgb.len(), (p.w * p.h * 3) as usize);
        assert!((p.w as f64 / p.h as f64 - ASPECT).abs() < 0.05);
        // the corner is sky, and some of it is grass-ish (green over red and blue)
        assert_eq!(&p.rgb[0..3], &SKY_TOP);
        let n = p.rgb.chunks(3).filter(|c| green(c)).count();
        assert!(n > 500, "{n} green pixels");
        // SOSH_MAP_OUT=<file.ppm> to look at it
        if let Ok(out) = std::env::var("SOSH_MAP_OUT") {
            let mut f = format!("P6 {} {} 255\n", p.w, p.h).into_bytes();
            f.extend_from_slice(&p.rgb);
            std::fs::write(out, f).unwrap();
        }

        // an empty universe is all sky: nothing green
        let empty = render(&Terrain::generate(&[]), &[]);
        assert!(!empty.rgb.chunks(3).any(green));
    }
}
