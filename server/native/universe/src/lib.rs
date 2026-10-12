//! NIFs for `Sosh.Universe`: the crop and cow simulation in `sim.rs`, held
//! in a resource and driven by `Sosh.Sim`.

use std::sync::{Mutex, MutexGuard};

use rustler::{Binary, Error, NifResult, Resource, ResourceArc};

mod sim;

use sim::Sim;

struct SimLock(Mutex<Sim>);

#[rustler::resource_impl]
impl Resource for SimLock {}

type Uni = ResourceArc<SimLock>;
type Pos = (i32, i32, i32);
type CowRow = (u32, f64, f64, f64, f64);

fn lock(u: &Uni) -> NifResult<MutexGuard<'_, Sim>> {
    u.0.lock().map_err(|_| Error::Term(Box::new("universe lock poisoned")))
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
    Ok(lock(&u)?.cows.iter().map(|c| (c.id, c.x, c.y, c.z, c.heading)).collect())
}

/// Advance to `now_ms` with players standing at `players` (`{x, y, z}` feet).
/// Returns `{moved_cows, mooing_cow_ids, grown_crops}`.
#[rustler::nif]
fn tick(
    u: Uni,
    now_ms: i64,
    players: Vec<(f64, f64, f64)>,
) -> NifResult<(Vec<CowRow>, Vec<u32>, Vec<(Pos, u8)>)> {
    let out = lock(&u)?.tick(now_ms, &players);
    Ok((out.cows, out.moos, out.crops))
}

rustler::init!("Elixir.Sosh.Universe");
