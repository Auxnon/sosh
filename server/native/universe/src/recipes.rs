//! Recipes: how everything that's made is made, one step at a time.
//!
//! A step turns its inputs into its output, at a station (a kind of
//! furniture the player has to be near) or by hand (no station: it can be
//! done anywhere, even outside a world). Each step has a gesture: what the
//! player draws at the station. The stroke they drew is scored here, and a
//! better stroke yields more: the listed output is the best case (a batch
//! for the gesture steps, 4 planks or 2 yarn at a time), a poor stroke gives
//! as little as half of it, never less than one. A gesture never fails
//! outright, and only the server decides what came out.
//!
//! Each item is made by one step at most, named after it; anything no step
//! makes (blocks, wool, carrots) is a raw material. Breaking something made
//! gives back three quarters of the raw materials its recipe comes to,
//! expanded all the way down (`salvage`).

use crate::furniture;
use crate::items::{self, Slot};

/// What the player does at a station to carry out a step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gesture {
    /// Putting the parts together: no stroke to draw.
    Assemble,
    /// One straight line across the plank (it lies along x).
    Saw,
    /// One long stroke along the block (it lies along x).
    Veneer,
    /// A circle round the wheel.
    Spin,
    /// Swipes across the loom (along x), back and forth.
    Weave,
}

pub const GESTURES: &[Gesture] = &[
    Gesture::Assemble,
    Gesture::Saw,
    Gesture::Veneer,
    Gesture::Spin,
    Gesture::Weave,
];

impl Gesture {
    pub fn name(self) -> &'static str {
        match self {
            Gesture::Assemble => "assemble",
            Gesture::Saw => "saw",
            Gesture::Veneer => "veneer",
            Gesture::Spin => "spin",
            Gesture::Weave => "weave",
        }
    }

    /// Whether it's drawn: a stroke is scored. Assembling needs none.
    pub fn stroke(self) -> bool {
        self != Gesture::Assemble
    }
}

pub struct Step {
    /// The step's name: what it makes.
    pub id: &'static str,
    pub inputs: &'static [(&'static str, u16)],
    /// What it makes and, with the best stroke, how many.
    pub output: (&'static str, u16),
    /// The station kind it's done at; None for a hand step.
    pub station: Option<&'static str>,
    pub gesture: Gesture,
}

/// The kinds of furniture that are stations.
pub const STATIONS: &[&str] = &["veneer", "bench", "spinning_wheel", "loom"];

const fn step(
    id: &'static str,
    inputs: &'static [(&'static str, u16)],
    n: u16,
    station: Option<&'static str>,
    gesture: Gesture,
) -> Step {
    Step {
        id,
        inputs,
        output: (id, n),
        station,
        gesture,
    }
}

use Gesture::*;

const BENCH: Option<&str> = Some("bench");

pub const STEPS: &[Step] = &[
    // parts
    // gestures make batches: a poor stroke loses some, a good one nothing
    step("plank", &[("wood", 4)], 4, Some("veneer"), Veneer),
    step("post", &[("plank", 2)], 4, BENCH, Saw),
    step("yarn", &[("wool", 4)], 2, Some("spinning_wheel"), Spin),
    step("cloth", &[("yarn", 4)], 2, Some("loom"), Weave),
    // stations: the veneer from raw blocks by hand, so anyone can start;
    // then the bench by hand from its planks; the rest at the bench
    step("veneer", &[("wood", 4), ("stone", 2)], 1, None, Assemble),
    step("bench", &[("plank", 3), ("wood", 2)], 1, None, Assemble),
    step("spinning_wheel", &[("plank", 2), ("post", 3)], 1, BENCH, Assemble),
    step("loom", &[("plank", 3), ("post", 4)], 1, BENCH, Assemble),
    // furniture
    step("chest", &[("plank", 4)], 1, BENCH, Assemble),
    step("drawer", &[("plank", 2), ("stone", 1)], 1, BENCH, Assemble),
    step("dresser", &[("plank", 4), ("post", 2), ("stone", 2)], 1, BENCH, Assemble),
    step("table", &[("plank", 2), ("post", 4)], 1, BENCH, Assemble),
    step("stool", &[("plank", 1), ("post", 2)], 1, BENCH, Assemble),
    step("wardrobe", &[("plank", 6), ("post", 2), ("stone", 1)], 1, BENCH, Assemble),
    step("bed", &[("plank", 1), ("post", 4), ("cloth", 3)], 1, BENCH, Assemble),
    step("door", &[("plank", 3)], 1, BENCH, Assemble),
    step("hyperdoor", &[("plank", 4), ("stone", 6)], 1, BENCH, Assemble),
];

/// Step `id`.
pub fn find(id: &str) -> Option<&'static Step> {
    STEPS.iter().find(|s| s.id == id)
}

/// The step that makes `item`, if anything does.
pub fn making(item: &str) -> Option<&'static Step> {
    STEPS.iter().find(|s| s.output.0 == item)
}

pub fn is_station(kind: &str) -> bool {
    STATIONS.contains(&kind)
}

/// Whether what `s` makes goes into a bag: an item, or furniture that packs
/// into one. Anything else is placed in the world or carried.
pub fn to_bag(s: &Step) -> bool {
    furniture::kind(s.output.0).is_none_or(|k| k.itemizable)
}

/// Most points of a stroke that count; the rest are ignored.
pub const MAX_POINTS: usize = 1024;

/// How well `stroke` (points 0..1 each way in the station's drawing area)
/// does `g`, 0..1. Assembling needs no stroke and always scores 1.
pub fn score(g: Gesture, stroke: &[(f64, f64)]) -> f64 {
    let pts: Vec<(f64, f64)> = stroke
        .iter()
        .take(MAX_POINTS)
        .filter(|p| p.0.is_finite() && p.1.is_finite())
        .map(|p| (p.0.clamp(0.0, 1.0), p.1.clamp(0.0, 1.0)))
        .collect();
    let s = match g {
        Assemble => 1.0,
        Saw => saw(&pts),
        Veneer => veneer(&pts),
        Spin => spin(&pts),
        Weave => weave(&pts),
    };
    s.clamp(0.0, 1.0)
}

/// How many of the best case `n` a stroke scoring `score` yields: half for
/// the worst (rounded), all for the best, never less than one.
pub fn yield_of(n: u16, score: f64) -> u16 {
    let s = score.clamp(0.0, 1.0);
    ((n as f64 * (0.5 + 0.5 * s)).round() as u16).clamp(1, n.max(1))
}

/// The plank across the saw's drawing area: it spans these heights.
pub const PLANK: (f64, f64) = (0.35, 0.65);
/// The block under the veneer: it spans these widths.
pub const BLOCK: (f64, f64) = (0.1, 0.9);
/// A circle this big round the wheel is a whole one.
pub const WHEEL_RADIUS: f64 = 0.25;
/// Passes across the loom for a whole sheet, each at least `PASS` wide.
pub const PASSES: usize = 4;
pub const PASS: f64 = 0.6;

fn lerp01(x: f64, zero: f64, one: f64) -> f64 {
    ((x - zero) / (one - zero)).clamp(0.0, 1.0)
}

/// For a stroke meant to be one straight line: its chord (first point to
/// last), and how straight it is, 0..1 (wobble off the chord, and doubling
/// back, both count against it).
fn line(pts: &[(f64, f64)]) -> Option<((f64, f64), f64)> {
    let (a, b) = (*pts.first()?, *pts.last()?);
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len = dx.hypot(dy);
    if pts.len() < 2 || len < 1e-3 {
        return None;
    }
    let off: f64 = pts
        .iter()
        .map(|p| {
            let d = ((p.0 - a.0) * dy - (p.1 - a.1) * dx) / len;
            d * d
        })
        .sum::<f64>()
        / pts.len() as f64;
    let path: f64 = pts.windows(2).map(|w| (w[1].0 - w[0].0).hypot(w[1].1 - w[0].1)).sum();
    let wobble = 1.0 - lerp01(off.sqrt() / len, 0.0, 1.0 / 6.0);
    let direct = lerp01(len / path.max(len), 0.5, 1.0);
    Some(((dx, dy), wobble * direct))
}

/// How much of `want` the span lo..hi covers, 0..1.
fn cover(lo: f64, hi: f64, want: (f64, f64)) -> f64 {
    ((hi.min(want.1) - lo.max(want.0)).max(0.0)) / (want.1 - want.0)
}

/// A straight line square across the plank, all the way through it.
fn saw(pts: &[(f64, f64)]) -> f64 {
    let Some(((dx, dy), straight)) = line(pts) else {
        return 0.0;
    };
    // off square: 0 straight across (along y), 45 degrees scores nothing
    let tilt = dx.abs().atan2(dy.abs());
    let square = 1.0 - lerp01(tilt, 0.0, std::f64::consts::FRAC_PI_4);
    let (lo, hi) = span(pts.iter().map(|p| p.1));
    straight * square * cover(lo, hi, PLANK)
}

/// One long straight stroke along the block, end to end.
fn veneer(pts: &[(f64, f64)]) -> f64 {
    let Some(((dx, dy), straight)) = line(pts) else {
        return 0.0;
    };
    let tilt = dy.abs().atan2(dx.abs());
    let along = 1.0 - lerp01(tilt, 0.0, std::f64::consts::FRAC_PI_4);
    let (lo, hi) = span(pts.iter().map(|p| p.0));
    straight * along * cover(lo, hi, BLOCK)
}

/// Once round, evenly, big enough.
fn spin(pts: &[(f64, f64)]) -> f64 {
    if pts.len() < 3 {
        return 0.0;
    }
    let n = pts.len() as f64;
    let c = (
        pts.iter().map(|p| p.0).sum::<f64>() / n,
        pts.iter().map(|p| p.1).sum::<f64>() / n,
    );
    let r: Vec<f64> = pts.iter().map(|p| (p.0 - c.0).hypot(p.1 - c.1)).collect();
    let mean = r.iter().sum::<f64>() / n;
    if mean < 0.01 {
        return 0.0;
    }
    let sd = (r.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / n).sqrt();
    let round = 1.0 - lerp01(sd / mean, 0.0, 0.5);
    let mut swept = 0.0;
    for w in pts.windows(2) {
        let a = (w[0].1 - c.1).atan2(w[0].0 - c.0);
        let b = (w[1].1 - c.1).atan2(w[1].0 - c.0);
        let mut d = b - a;
        while d > std::f64::consts::PI {
            d -= std::f64::consts::TAU;
        }
        while d < -std::f64::consts::PI {
            d += std::f64::consts::TAU;
        }
        swept += d;
    }
    let whole = lerp01(swept.abs(), 0.0, std::f64::consts::TAU);
    let size = lerp01(mean, 0.0, WHEEL_RADIUS);
    round * whole * size
}

/// Passes across, turning back each time: `PASSES` of them at least `PASS`
/// wide make a whole sheet.
fn weave(pts: &[(f64, f64)]) -> f64 {
    // a turn counts once the stroke has come back this far from its furthest
    const TURN: f64 = 0.05;
    let Some(first) = pts.first() else {
        return 0.0;
    };
    let (mut start, mut far, mut dir) = (first.0, first.0, 0.0f64);
    let mut good = 0;
    for p in &pts[1..] {
        let x = p.0;
        if dir == 0.0 {
            if (x - start).abs() > TURN {
                dir = (x - start).signum();
                far = x;
            }
            continue;
        }
        if (x - far) * dir > 0.0 {
            far = x;
        } else if (far - x) * dir > TURN {
            if (far - start).abs() >= PASS {
                good += 1;
            }
            (start, dir) = (far, -dir);
            far = x;
        }
    }
    if dir != 0.0 && (far - start).abs() >= PASS {
        good += 1;
    }
    (good.min(PASSES) as f64) / PASSES as f64
}

fn span(xs: impl Iterator<Item = f64>) -> (f64, f64) {
    xs.fold((f64::INFINITY, f64::NEG_INFINITY), |(lo, hi), x| {
        (lo.min(x), hi.max(x))
    })
}

/// Step `id`, if it can be done with `stations` near and `bag` holding
/// its inputs.
pub fn check(id: &str, stations: &[&str], bag: &[Slot]) -> Result<&'static Step, &'static str> {
    let s = find(id).ok_or("no_such_step")?;
    if let Some(k) = s.station {
        if !stations.contains(&k) {
            return Err("no_station_near");
        }
    }
    if !has_inputs(s, bag) {
        return Err("missing_ingredients");
    }
    Ok(s)
}

fn has_inputs(s: &Step, bag: &[Slot]) -> bool {
    s.inputs.iter().all(|&(item, n)| {
        let need: u32 = s
            .inputs
            .iter()
            .filter(|(i, _)| *i == item)
            .map(|(_, k)| *k as u32)
            .sum();
        n == 0 || items::count(bag, item) >= need
    })
}

/// Take step `s`'s inputs from `bag`, all or nothing.
pub fn take_inputs(s: &Step, bag: &mut [Slot]) -> bool {
    if !has_inputs(s, bag) {
        return false;
    }
    for &(item, n) in s.inputs {
        items::take(bag, item, n);
    }
    true
}

/// What a step made: how many of what, and how well it was drawn (0..1).
#[derive(Clone, Debug, PartialEq)]
pub struct Made {
    pub step: &'static str,
    pub item: &'static str,
    pub n: u16,
    pub score: f64,
}

/// Do step `id` on `bag` with `stations` near and `stroke` drawn: its
/// inputs come out and what the stroke earned goes in, or nothing changes.
/// Needs no world: a hand step works anywhere. Furniture too big for a bag
/// has to be placed or carried, in a world (`Sim::craft`).
pub fn craft(
    id: &str,
    stroke: &[(f64, f64)],
    stations: &[&str],
    bag: &mut Vec<Slot>,
) -> Result<Made, &'static str> {
    let s = check(id, stations, bag)?;
    if !to_bag(s) {
        return Err("place_or_carry");
    }
    let made = outcome(s, stroke);
    let mut trial = bag.clone();
    take_inputs(s, &mut trial);
    if items::add(&mut trial, made.item, made.n) > 0 {
        return Err("bag_full");
    }
    *bag = trial;
    Ok(made)
}

/// What `stroke` earns at step `s`.
pub fn outcome(s: &'static Step, stroke: &[(f64, f64)]) -> Made {
    let score = score(s.gesture, stroke);
    Made {
        step: s.id,
        item: s.output.0,
        n: yield_of(s.output.1, score),
        score,
    }
}

/// The raw materials one `item` comes to, its recipe expanded all the way
/// down (per unit at the best case's yields, so a batch's size doesn't
/// matter, only its ratio); nothing for a raw material itself.
pub fn raw(item: &str) -> Vec<(&'static str, f64)> {
    let mut out = Vec::new();
    if let Some(s) = making(item) {
        expand(s, 1.0, &mut out, 0);
    }
    out
}

fn expand(s: &Step, n: f64, out: &mut Vec<(&'static str, f64)>, depth: usize) {
    let per = n / s.output.1 as f64;
    for &(item, k) in s.inputs {
        let k = k as f64 * per;
        match making(item) {
            Some(sub) if depth < 16 => expand(sub, k, out, depth + 1),
            _ => match out.iter_mut().find(|(i, _)| *i == item) {
                Some((_, have)) => *have += k,
                None => out.push((item, k)),
            },
        }
    }
}

/// What breaking one `kind` gives back: three quarters of each raw material
/// it's made of, rounded down, at least one. Nothing for what isn't made.
pub fn salvage(kind: &str) -> Vec<(&'static str, u16)> {
    raw(kind)
        .into_iter()
        .map(|(i, n)| (i, ((n * 0.75 + 1e-9).floor() as u16).max(1)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_item_has_one_maker_and_every_input_is_known() {
        for s in STEPS {
            assert_eq!(s.id, s.output.0);
            assert_eq!(STEPS.iter().filter(|o| o.output.0 == s.id).count(), 1, "{}", s.id);
            assert!(items::info(s.id).is_some() || furniture::kind(s.id).is_some(), "{}", s.id);
            for (i, _) in s.inputs {
                assert!(items::info(i).is_some(), "{}: {i}", s.id);
            }
            if let Some(k) = s.station {
                assert!(is_station(k) && furniture::kind(k).is_some(), "{k}");
            }
        }
        // every kind that's built has a recipe; the rest aren't made
        for k in furniture::KINDS {
            let made = !matches!(k.name, "hyperexit" | "sign" | "marbles" | "sack");
            assert_eq!(making(k.name).is_some(), made, "{}", k.name);
        }
        // the first station is made by hand from raw blocks alone
        let v = find("veneer").unwrap();
        assert!(v.station.is_none());
        assert!(v.inputs.iter().all(|(i, _)| making(i).is_none()));
    }

    #[test]
    fn a_bed_comes_down_to_wood_and_wool() {
        let mut r = raw("bed");
        r.sort_by(|a, b| a.0.cmp(b.0));
        assert_eq!(r, vec![("wood", 3.0), ("wool", 12.0)]);
        assert_eq!(salvage("bed"), vec![("wood", 2), ("wool", 9)]);
        // half a plank of wood is still one back
        assert_eq!(salvage("stool"), vec![("wood", 1)]);
        assert!(salvage("sack").is_empty());
        // per unit at the best case, whatever the batch: a post is half a plank
        assert_eq!(raw("post"), vec![("wood", 0.5)]);
        assert_eq!(raw("cloth"), vec![("wool", 4.0)]);
        assert!(raw("wood").is_empty());
    }

    #[test]
    fn yield_is_half_to_all_never_none() {
        assert_eq!(yield_of(2, 0.0), 1);
        assert_eq!(yield_of(2, 0.49), 1);
        assert_eq!(yield_of(2, 0.5), 2);
        assert_eq!(yield_of(2, 1.0), 2);
        assert_eq!(yield_of(1, 0.0), 1);
        assert_eq!(yield_of(10, 0.0), 5);
        assert_eq!(yield_of(10, 1.0), 10);
        assert_eq!(yield_of(10, 7.0), 10);
    }

    #[test]
    fn a_batch_step_gives_its_whole_batch_on_a_clean_stroke_and_less_on_a_bad_one() {
        let clean_line = line_of((0.5, 0.0), (0.5, 1.0), 20);
        let veneer_line = line_of((0.05, 0.5), (0.95, 0.5), 20);
        let circle: Vec<(f64, f64)> = (0..=48)
            .map(|i| {
                let a = i as f64 / 48.0 * std::f64::consts::TAU;
                (0.5 + 0.3 * a.cos(), 0.5 + 0.3 * a.sin())
            })
            .collect();
        let mut four = Vec::new();
        for k in 0..4 {
            let (a, b) = if k % 2 == 0 { (0.1, 0.9) } else { (0.9, 0.1) };
            four.extend(line_of((a, 0.2 + k as f64 * 0.2), (b, 0.2 + k as f64 * 0.2), 10));
        }
        let scribble = line_of((0.5, 0.5), (0.52, 0.5), 5);
        let cases: [(&str, u16, &[(f64, f64)]); 4] = [
            ("plank", 4, &veneer_line),
            ("post", 4, &clean_line),
            ("yarn", 2, &circle),
            ("cloth", 2, &four),
        ];
        for (id, n, clean) in cases {
            let s = find(id).unwrap();
            assert_eq!(s.output.1, n, "{id}");
            let good = outcome(s, clean);
            assert_eq!(good.n, n, "{id} clean: {}", good.score);
            let bad = outcome(s, &scribble);
            assert!(bad.n < n && bad.n >= n.div_ceil(2) && bad.n >= 1, "{id} bad: {}", bad.n);
        }
        // a middling stroke of four still gives three
        assert_eq!(yield_of(4, 0.5), 3);
        assert_eq!(yield_of(4, 0.2), 2);
    }

    fn line_of(a: (f64, f64), b: (f64, f64), n: usize) -> Vec<(f64, f64)> {
        (0..=n)
            .map(|i| {
                let t = i as f64 / n as f64;
                (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
            })
            .collect()
    }

    #[test]
    fn a_square_straight_cut_scores_best() {
        let good = score(Saw, &line_of((0.5, 0.1), (0.5, 0.9), 20));
        assert!(good > 0.99, "{good}");
        let slanted = score(Saw, &line_of((0.3, 0.1), (0.7, 0.9), 20));
        assert!(slanted < good && slanted > 0.0, "{slanted}");
        let short = score(Saw, &line_of((0.5, 0.1), (0.5, 0.5), 20));
        assert!(short < 0.6, "only partway through: {short}");
        let along = score(Saw, &line_of((0.1, 0.5), (0.9, 0.5), 20));
        assert_eq!(along, 0.0);
        let mut wobbly = line_of((0.5, 0.1), (0.5, 0.9), 20);
        for (i, p) in wobbly.iter_mut().enumerate() {
            p.0 += if i % 2 == 0 { 0.08 } else { -0.08 };
        }
        assert!(score(Saw, &wobbly) < good * 0.7);
        assert_eq!(score(Saw, &[]), 0.0);
        assert_eq!(score(Saw, &[(0.5, 0.5)]), 0.0);
        assert_eq!(score(Saw, &[(f64::NAN, 0.5), (0.5, f64::INFINITY)]), 0.0);
    }

    #[test]
    fn veneer_wants_one_long_stroke_along() {
        assert!(score(Veneer, &line_of((0.05, 0.5), (0.95, 0.5), 30)) > 0.99);
        let half = score(Veneer, &line_of((0.1, 0.5), (0.5, 0.5), 30));
        assert!((half - 0.5).abs() < 0.01, "{half}");
        // there and back again isn't one stroke
        let mut back = line_of((0.1, 0.5), (0.9, 0.5), 20);
        back.extend(line_of((0.9, 0.5), (0.2, 0.5), 20));
        assert!(score(Veneer, &back) < 0.3);
    }

    #[test]
    fn spinning_wants_a_round_whole_circle() {
        let circle: Vec<(f64, f64)> = (0..=48)
            .map(|i| {
                let a = i as f64 / 48.0 * std::f64::consts::TAU;
                (0.5 + 0.3 * a.cos(), 0.5 + 0.3 * a.sin())
            })
            .collect();
        assert!(score(Spin, &circle) > 0.95);
        let half: Vec<(f64, f64)> = circle[..=24].to_vec();
        assert!(score(Spin, &half) < 0.7);
        assert!(score(Spin, &line_of((0.1, 0.1), (0.9, 0.9), 20)) < 0.1);
    }

    #[test]
    fn weaving_counts_passes_across() {
        let mut four = Vec::new();
        for k in 0..4 {
            let (a, b) = if k % 2 == 0 { (0.1, 0.9) } else { (0.9, 0.1) };
            let y = 0.2 + k as f64 * 0.2;
            four.extend(line_of((a, y), (b, y), 10));
        }
        assert_eq!(score(Weave, &four), 1.0);
        let two: Vec<_> = four[..22].to_vec();
        assert_eq!(score(Weave, &two), 0.5);
        // little scribbles aren't passes
        let mut scribble = Vec::new();
        for k in 0..10 {
            scribble.push((0.45 + 0.1 * (k % 2) as f64, 0.5));
        }
        assert_eq!(score(Weave, &scribble), 0.0);
    }

    fn bag(stuff: &[(&str, u16)]) -> Vec<Slot> {
        let mut b = items::empty(items::BAG_SLOTS);
        for (i, n) in stuff {
            items::add(&mut b, i, *n);
        }
        b
    }

    #[test]
    fn a_hand_step_needs_only_the_bag() {
        let mut b = bag(&[("wood", 5), ("stone", 2)]);
        let made = craft("veneer", &[], &[], &mut b).unwrap();
        assert_eq!((made.item, made.n, made.score), ("veneer", 1, 1.0));
        assert_eq!(items::count(&b, "veneer"), 1);
        assert_eq!(items::count(&b, "wood"), 1);
        assert_eq!(items::count(&b, "stone"), 0);
        assert_eq!(craft("veneer", &[], &[], &mut b), Err("missing_ingredients"));
        assert_eq!(items::count(&b, "wood"), 1, "nothing taken");
        assert_eq!(craft("nope", &[], &[], &mut b), Err("no_such_step"));
    }

    #[test]
    fn a_station_step_needs_its_station() {
        let mut b = bag(&[("plank", 6)]);
        let cut = line_of((0.5, 0.0), (0.5, 1.0), 10);
        assert_eq!(craft("post", &cut, &[], &mut b), Err("no_station_near"));
        assert_eq!(craft("post", &cut, &["veneer"], &mut b), Err("no_station_near"));
        let made = craft("post", &cut, &["bench"], &mut b).unwrap();
        assert_eq!(made.n, 4);
        assert_eq!(items::count(&b, "post"), 4);
        // a poor cut wastes some
        let poor = line_of((0.1, 0.4), (0.9, 0.6), 10);
        let made = craft("post", &poor, &["bench"], &mut b).unwrap();
        assert_eq!(made.n, 2);
        assert_eq!(items::count(&b, "post"), 6);
        assert_eq!(items::count(&b, "plank"), 2);
    }

    #[test]
    fn heavy_furniture_does_not_go_in_a_bag() {
        let mut b = bag(&[("plank", 1), ("post", 4), ("cloth", 3)]);
        assert_eq!(craft("bed", &[], &["bench"], &mut b), Err("place_or_carry"));
        assert_eq!(items::count(&b, "cloth"), 3);
        let mut b = bag(&[("plank", 2), ("stone", 1)]);
        assert_eq!(craft("drawer", &[], &["bench"], &mut b).unwrap().item, "drawer");
        assert_eq!(items::count(&b, "drawer"), 1);
    }

    #[test]
    fn a_full_bag_takes_nothing() {
        let mut b = bag(&[("wool", 4)]);
        for s in b.iter_mut().skip(1) {
            *s = Some(items::Stack { item: "dirt".into(), n: 64 });
        }
        // the wool's slot frees up for the yarn
        assert!(craft("yarn", &[], &["spinning_wheel"], &mut b).is_ok());
        let mut b = bag(&[("wool", 8)]);
        for s in b.iter_mut().skip(1) {
            *s = Some(items::Stack { item: "dirt".into(), n: 64 });
        }
        let before = b.clone();
        assert_eq!(craft("yarn", &[], &["spinning_wheel"], &mut b), Err("bag_full"));
        assert_eq!(b, before);
    }
}
