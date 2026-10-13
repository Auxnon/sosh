//! NIFs for `Sosh.Universe`: the crop, cow and carrying simulation in
//! `sim.rs`, held in a resource and driven by `Sosh.Sim`.

use std::sync::{Mutex, MutexGuard};

use rustler::{Atom, Binary, Error, NifResult, Resource, ResourceArc};

mod sim;

use sim::{Held, Sim};

rustler::atoms! {
    block,
    cow,
}

struct SimLock(Mutex<Sim>);

#[rustler::resource_impl]
impl Resource for SimLock {}

type Uni = ResourceArc<SimLock>;
type Pos = (i32, i32, i32);
type CowRow = (u32, f64, f64, f64, f64);
type Feet = (f64, f64, f64);
/// `{:block, id}` or `{:cow, id}`.
type HeldTerm = (Atom, u32);

fn held_term(h: Held) -> HeldTerm {
    match h {
        Held::Block(id) => (block(), id as u32),
        Held::Cow(id) => (cow(), id),
    }
}

fn reason<T>(r: Result<T, &'static str>) -> Result<T, String> {
    r.map_err(str::to_string)
}

fn lock(u: &Uni) -> NifResult<MutexGuard<'_, Sim>> {
    u.0.lock()
        .map_err(|_| Error::Term(Box::new("universe lock poisoned")))
}

/// A new universe; crops advance one stage every `stage_ms`.
#[rustler::nif]
fn bigbang(stage_ms: i64, seed: u64) -> Uni {
    ResourceArc::new(SimLock(Mutex::new(Sim::new(stage_ms, seed))))
}

/// Mirror a 16x16x16 chunk of `Sosh.World` (4096 block ids).
#[rustler::nif]
fn load_chunk(u: Uni, key: Pos, blocks: Binary) -> NifResult<bool> {
    Ok(lock(&u)?.load_chunk(key, blocks.as_slice()))
}

#[rustler::nif]
fn set_block(u: Uni, pos: Pos, id: u8) -> NifResult<()> {
    lock(&u)?.set_block(pos.0, pos.1, pos.2, id);
    Ok(())
}

/// False if a crop is already there.
#[rustler::nif]
fn plant(u: Uni, pos: Pos, planted_ms: i64, now_ms: i64) -> NifResult<bool> {
    Ok(lock(&u)?.plant(pos, planted_ms, now_ms))
}

/// The crop's stage, or nil.
#[rustler::nif]
fn crop(u: Uni, pos: Pos) -> NifResult<Option<u8>> {
    Ok(lock(&u)?.crops.get(&pos).map(|c| c.stage))
}

/// Remove a crop; its stage, or nil if there was none.
#[rustler::nif]
fn remove_crop(u: Uni, pos: Pos) -> NifResult<Option<u8>> {
    Ok(lock(&u)?.remove_crop(pos))
}

/// Every crop as `{{x, y, z}, stage}`.
#[rustler::nif]
fn crops(u: Uni) -> NifResult<Vec<(Pos, u8)>> {
    Ok(lock(&u)?.crops.iter().map(|(p, c)| (*p, c.stage)).collect())
}

#[rustler::nif]
fn spawn_cow(u: Uni, x: f64, y: f64) -> NifResult<u32> {
    Ok(lock(&u)?.spawn_cow(x, y))
}

/// Every cow as `{id, x, y, z, heading}`.
#[rustler::nif]
fn cows(u: Uni) -> NifResult<Vec<CowRow>> {
    Ok(lock(&u)?
        .cows
        .iter()
        .map(|c| (c.id, c.x, c.y, c.z, c.heading))
        .collect())
}

/// Block ids a player may carry.
#[rustler::nif]
fn carryable() -> Vec<u8> {
    sim::CARRYABLE.to_vec()
}

/// `holder` standing at `at` lifts block `id`: `{:ok, {:block, id}}` or
/// `{:error, reason}`. Taking it out of the world is the caller's job.
#[rustler::nif]
fn pick_block(u: Uni, holder: String, at: Feet, id: u8) -> NifResult<Result<HeldTerm, String>> {
    let r = lock(&u)?.pick_block(&holder, at, id);
    Ok(reason(r.map(|_| held_term(Held::Block(id)))))
}

/// `holder` standing at `at` lifts cow `id`: `{:ok, {:cow, id}}` or
/// `{:error, reason}`.
#[rustler::nif]
fn pick_cow(u: Uni, holder: String, at: Feet, id: u32) -> NifResult<Result<HeldTerm, String>> {
    let r = lock(&u)?.pick_cow(&holder, at, id);
    Ok(reason(r.map(|_| held_term(Held::Cow(id)))))
}

/// `holder` puts what they carry in cell `pos`; `free` says the world has
/// room for a block there. `{:ok, held}` or `{:error, reason}`.
#[rustler::nif]
fn put_down(u: Uni, holder: String, pos: Pos, free: bool) -> NifResult<Result<HeldTerm, String>> {
    let r = lock(&u)?.put_down(&holder, pos, free);
    Ok(reason(r.map(held_term)))
}

/// `holder` left: `{held, cell_they_stood_in}`, or nil if empty-handed.
#[rustler::nif]
fn release(u: Uni, holder: String) -> NifResult<Option<(HeldTerm, Pos)>> {
    Ok(lock(&u)?
        .release(&holder)
        .map(|(h, cell)| (held_term(h), cell)))
}

/// Everyone carrying something, as `{holder, held}`.
#[rustler::nif]
fn holding(u: Uni) -> NifResult<Vec<(String, HeldTerm)>> {
    Ok(lock(&u)?
        .holding()
        .map(|(k, h)| (k.clone(), held_term(h)))
        .collect())
}

/// Advance to `now_ms` with players standing at `players` (`{id, x, y, z}`,
/// feet). Returns `{moved_cows, mooing_cow_ids, grown_crops}`.
#[rustler::nif]
fn tick(
    u: Uni,
    now_ms: i64,
    players: Vec<(String, f64, f64, f64)>,
) -> NifResult<(Vec<CowRow>, Vec<u32>, Vec<(Pos, u8)>)> {
    let out = lock(&u)?.tick(now_ms, &players);
    Ok((out.cows, out.moos, out.crops))
}

rustler::init!("Elixir.Sosh.Universe");
