//! NIFs for `Sosh.Universe`: one universe of the grid (`sim.rs`), held in a
//! resource and driven by its `Sosh.Sim` process.
//!
//! Fallible calls return `:ok`, `{:ok, value}` (or `{:ok, a, b}`) or
//! `{:error, "reason"}`. Bags travel as lists of `nil | {item, count}`.
//! Everything meant for clients (events, snapshots, the catalog) comes out
//! as maps with atom keys and list positions, ready to encode as JSON.

use std::sync::{Mutex, MutexGuard};

use rustler::{
    Atom, Binary, Encoder, Env, Error, NifResult, OwnedBinary, Resource, ResourceArc, Term,
};

mod furniture;
mod items;
mod ships;
mod sim;
mod terrain;

use furniture::{Furniture, Grip, Site};
use items::{Slot, Stack};
use ships::{Helm, Ship, Side};
use sim::{Cargo, Event, Grabbed, Held, Sim, Walker};

rustler::atoms! {
    ok,
    error,
    nil,
    pocketed,
    gripped,
    lifted,
    block_changed,
    crop,
    carry,
    furniture_changed = "furniture",
    furniture_gone,
    site,
    site_gone,
    ship,
    ship_block,
    departed,
}

struct SimLock(Mutex<Sim>);

#[rustler::resource_impl]
impl Resource for SimLock {}

type Uni = ResourceArc<SimLock>;
type Pos = (i32, i32, i32);
type Feet = (f64, f64, f64);
type Row = (u32, f64, f64, f64, f64);
/// A player as the caller tracks them: `{id, on, {x, y, z}}`, feet in the
/// world (`on` 0) or in ship `on`'s frame.
type WalkerTerm = (String, u32, Feet);
/// A bag as Elixir holds it.
type BagTerm = Vec<Option<(String, u16)>>;

fn lock(u: &Uni) -> NifResult<MutexGuard<'_, Sim>> {
    u.0.lock()
        .map_err(|_| Error::Term(Box::new("universe lock poisoned")))
}

fn bag_in(b: BagTerm) -> Vec<Slot> {
    b.into_iter()
        .map(|s| s.map(|(item, n)| Stack { item, n }))
        .collect()
}

fn bag_out(b: Vec<Slot>) -> BagTerm {
    b.into_iter().map(|s| s.map(|s| (s.item, s.n))).collect()
}

// -- term building

fn map<'a>(env: Env<'a>, kv: &[(&str, Term<'a>)]) -> Term<'a> {
    let mut m = Term::map_new(env);
    for (k, v) in kv {
        let key = Atom::from_str(env, k).expect("atom").encode(env);
        m = m.map_put(key, *v).expect("map");
    }
    m
}

fn none<'a>(env: Env<'a>) -> Term<'a> {
    nil().encode(env)
}

fn opt<'a, T: Encoder>(env: Env<'a>, v: Option<T>) -> Term<'a> {
    match v {
        Some(v) => v.encode(env),
        None => none(env),
    }
}

fn pos<'a>(env: Env<'a>, p: Pos) -> Term<'a> {
    vec![p.0, p.1, p.2].encode(env)
}

fn fail<'a>(env: Env<'a>, why: &str) -> Term<'a> {
    (error(), why).encode(env)
}

fn done<'a>(env: Env<'a>, r: Result<(), &str>) -> Term<'a> {
    match r {
        Ok(()) => ok().encode(env),
        Err(e) => fail(env, e),
    }
}

/// Container slots as `[[item, count] | []]`: an empty slot is an empty
/// list, not null, which a Lua client would read as a hole in the array.
fn slots<'a>(env: Env<'a>, s: &[Slot]) -> Term<'a> {
    s.iter()
        .map(|s| match s {
            Some(s) => (s.item.as_str(), s.n).encode(env).map_list(env),
            None => Vec::<Term>::new().encode(env),
        })
        .collect::<Vec<Term>>()
        .encode(env)
}

trait AsList<'a> {
    fn map_list(self, env: Env<'a>) -> Term<'a>;
}

impl<'a> AsList<'a> for Term<'a> {
    /// A 2-tuple as a 2-list (JSON has no tuples).
    fn map_list(self, env: Env<'a>) -> Term<'a> {
        match rustler::types::tuple::get_tuple(self) {
            Ok(items) => items.encode(env),
            Err(_) => self,
        }
    }
}

fn pairs<'a>(env: Env<'a>, p: &[(impl AsRef<str>, u16)]) -> Term<'a> {
    p.iter()
        .map(|(i, n)| (i.as_ref(), *n).encode(env).map_list(env))
        .collect::<Vec<Term>>()
        .encode(env)
}

fn held_term<'a>(env: Env<'a>, user: &str, h: Option<Held>) -> Term<'a> {
    let (mut b, mut c, mut f) = (None, None, None);
    match h {
        Some(Held::Block(id)) => b = Some(id as u32),
        Some(Held::Cow(id)) => c = Some(id),
        Some(Held::Furniture(id)) => f = Some(id),
        None => {}
    }
    map(
        env,
        &[
            ("user_id", user.encode(env)),
            ("block", opt(env, b)),
            ("cow", opt(env, c)),
            ("furniture", opt(env, f)),
        ],
    )
}

fn furniture_term<'a>(env: Env<'a>, f: &Furniture) -> Term<'a> {
    let carriers: Vec<&str> = f
        .grips
        .iter()
        .filter_map(|g| match g {
            Grip::Player(p) => Some(p.as_str()),
            _ => None,
        })
        .collect();
    let helpers: Vec<u32> = f.helpers().collect();
    map(
        env,
        &[
            ("id", f.id.encode(env)),
            ("kind", f.kind.encode(env)),
            ("on", f.on.encode(env)),
            ("origin", pos(env, f.origin)),
            ("rot", f.rot.encode(env)),
            ("lifted", f.lifted.encode(env)),
            ("carriers", carriers.encode(env)),
            ("helpers", helpers.encode(env)),
            ("slots", slots(env, &f.slots)),
        ],
    )
}

fn site_term<'a>(env: Env<'a>, s: &Site) -> Term<'a> {
    map(
        env,
        &[
            ("id", s.id.encode(env)),
            ("kind", s.kind.encode(env)),
            ("on", s.on.encode(env)),
            ("origin", pos(env, s.origin)),
            ("rot", s.rot.encode(env)),
            ("have", pairs(env, &s.have)),
            ("need", pairs(env, s.info().recipe)),
        ],
    )
}

/// A ship: where it is, who steers, and its blocks as `[[x, y, z, block]]`
/// in its own frame.
fn ship_term<'a>(env: Env<'a>, s: &Ship) -> Term<'a> {
    let blocks: Vec<Vec<i32>> = s
        .blocks
        .iter()
        .map(|(p, b)| vec![p.0, p.1, p.2, *b as i32])
        .collect();
    let (vx, vy, vz, spin) = s.velocity();
    map(
        env,
        &[
            ("id", s.id.encode(env)),
            ("x", s.pose.x.encode(env)),
            ("y", s.pose.y.encode(env)),
            ("z", s.pose.z.encode(env)),
            ("heading", s.pose.h.encode(env)),
            ("v", vec![vx, vy, vz, spin].encode(env)),
            ("pilot", opt(env, s.pilot.as_deref())),
            ("blocks", blocks.encode(env)),
        ],
    )
}

fn event_term<'a>(env: Env<'a>, sim: &Sim, e: Event) -> Option<Term<'a>> {
    let (tag, payload) = match e {
        Event::Block(p, id) => (
            block_changed(),
            map(env, &[("position", pos(env, p)), ("block", id.encode(env))]),
        ),
        Event::Crop(p, stage) => (
            crop(),
            map(
                env,
                &[("position", pos(env, p)), ("stage", opt(env, stage))],
            ),
        ),
        Event::Carry(user, h) => (carry(), held_term(env, &user, h)),
        Event::Furniture(id) => (
            furniture_changed(),
            furniture_term(env, sim.furniture.get(&id)?),
        ),
        Event::FurnitureGone(id) => (furniture_gone(), map(env, &[("id", id.encode(env))])),
        Event::Site(id) => (site(), site_term(env, sim.sites.get(&id)?)),
        Event::SiteGone(id) => (site_gone(), map(env, &[("id", id.encode(env))])),
        Event::ShipBlock(id, p, b) => (
            ship_block(),
            map(
                env,
                &[
                    ("ship", id.encode(env)),
                    ("position", pos(env, p)),
                    ("block", b.encode(env)),
                ],
            ),
        ),
        Event::Ship(id) => (ship(), ship_term(env, sim.ship(id)?)),
        Event::Departed(cargo, side) => {
            let json = serde_json::to_string(&*cargo).ok()?;
            let riders: Vec<&str> = cargo.riders.iter().map(|r| r.0.as_str()).collect();
            (
                departed(),
                map(
                    env,
                    &[
                        ("id", cargo.ship.id.encode(env)),
                        ("cargo", json.encode(env)),
                        ("side", side.name().encode(env)),
                        ("step", vec![side.step().0, side.step().1].encode(env)),
                        ("riders", riders.encode(env)),
                    ],
                ),
            )
        }
    };
    Some((tag, payload).encode(env))
}

// -- making and keeping a universe

/// Universe (gx, gy) as generated from `seed`; crops advance a stage every
/// `stage_ms` of world time.
#[rustler::nif]
fn bigbang(gx: i32, gy: i32, seed: u64, stage_ms: i64) -> Uni {
    ResourceArc::new(SimLock(Mutex::new(Sim::new(gx, gy, seed, stage_ms))))
}

/// Every chunk key of a universe.
#[rustler::nif]
fn chunk_keys() -> Vec<Pos> {
    terrain::chunk_keys().collect()
}

/// Replace a generated chunk with a saved one (4096 block ids).
#[rustler::nif]
fn load_chunk(u: Uni, key: Pos, blocks: Binary) -> NifResult<bool> {
    Ok(lock(&u)?.terrain.load_chunk(key, blocks.as_slice()))
}

/// The chunks changed since last asked, as `{key, binary}`, for saving.
#[rustler::nif]
fn take_dirty<'a>(env: Env<'a>, u: Uni) -> NifResult<Vec<(Pos, Binary<'a>)>> {
    let mut s = lock(&u)?;
    let mut out = Vec::new();
    for key in s.terrain.take_dirty() {
        if let Some(c) = s.terrain.chunk(key) {
            let mut b = OwnedBinary::new(c.len()).ok_or(Error::BadArg)?;
            b.as_mut_slice().copy_from_slice(c);
            out.push((key, Binary::from_owned(b, env)));
        }
    }
    Ok(out)
}

/// A chunk run-length encoded as `[id, count, id, count, ...]`, or nil.
#[rustler::nif]
fn rle(u: Uni, key: Pos) -> NifResult<Option<Vec<u32>>> {
    Ok(lock(&u)?.terrain.rle(key))
}

/// The block at `p` in frame `on` (0 the world, else a ship).
#[rustler::nif]
fn block(u: Uni, on: u32, p: Pos) -> NifResult<Option<u8>> {
    Ok(lock(&u)?.get(on, p))
}

/// Frame `on`'s point `at`, in the world; nil if there's no such ship.
#[rustler::nif]
fn world_of(u: Uni, on: u32, at: Feet) -> NifResult<Option<Feet>> {
    Ok(lock(&u)?.world_of(on, at))
}

/// What to keep (a JSON string) besides the chunks.
#[rustler::nif]
fn save(u: Uni, now_ms: i64) -> NifResult<String> {
    serde_json::to_string(&lock(&u)?.save(now_ms)).map_err(|e| Error::Term(Box::new(e.to_string())))
}

/// Back as `save` left it; call after loading saved chunks.
#[rustler::nif]
fn restore<'a>(env: Env<'a>, u: Uni, json: String) -> NifResult<Term<'a>> {
    match serde_json::from_str(&json) {
        Ok(saved) => {
            lock(&u)?.restore(saved);
            Ok(ok().encode(env))
        }
        Err(e) => Ok(fail(env, &e.to_string())),
    }
}

/// Which sides have a neighbour to fly into: `[east, west, north, south]`.
#[rustler::nif]
fn set_open(u: Uni, open: Vec<bool>) -> NifResult<()> {
    let mut o = [false; 4];
    for (i, v) in open.into_iter().take(4).enumerate() {
        o[i] = v;
    }
    lock(&u)?.set_open(o);
    Ok(())
}

#[rustler::nif]
fn asleep(u: Uni) -> NifResult<bool> {
    Ok(lock(&u)?.asleep())
}

#[rustler::nif]
fn sleep(u: Uni, now_ms: i64) -> NifResult<()> {
    lock(&u)?.sleep(now_ms);
    Ok(())
}

/// How many world ticks it caught up on.
#[rustler::nif]
fn wake(u: Uni, now_ms: i64) -> NifResult<i64> {
    Ok(lock(&u)?.wake(now_ms))
}

#[rustler::nif]
fn ambient(u: Uni, now_ms: i64) -> NifResult<()> {
    lock(&u)?.ambient(now_ms);
    Ok(())
}

/// Where `user` stands: aboard the ship they flew in on, at `at` if it's
/// ground, else on the home island. `{feet, nil | {ship, feet_aboard}}`.
#[rustler::nif]
fn spawn(u: Uni, user: String, at: Option<Feet>) -> NifResult<(Feet, Option<(u32, Feet)>)> {
    Ok(lock(&u)?.spawn(&user, at))
}

#[rustler::nif]
fn spawn_cows(u: Uni, n: usize) -> NifResult<()> {
    lock(&u)?.spawn_cows(n);
    Ok(())
}

/// A crop planted `ago_ms` of world time ago (from an older save).
#[rustler::nif]
fn plant_aged(u: Uni, p: Pos, ago_ms: i64) -> NifResult<()> {
    lock(&u)?.plant_aged(p, ago_ms);
    Ok(())
}

// -- doing things

#[rustler::nif]
fn plant(env: Env, u: Uni, p: Pos) -> NifResult<Term> {
    Ok(done(env, lock(&u)?.plant(p)))
}

/// `{:ok, bag}` with the carrot in it.
#[rustler::nif]
fn harvest(env: Env, u: Uni, p: Pos, bag: BagTerm) -> NifResult<Term> {
    let mut b = bag_in(bag);
    Ok(match lock(&u)?.harvest(p, &mut b) {
        Ok(()) => (ok(), bag_out(b)).encode(env),
        Err(e) => fail(env, e),
    })
}

#[rustler::nif]
fn crop_at(u: Uni, p: Pos) -> NifResult<Option<u8>> {
    Ok(lock(&u)?.crops.get(&p).map(|c| c.stage))
}

/// Dig the block at `p` (breaking furniture, taking scaffolding down) into
/// the bag: `{:ok, bag}`.
#[rustler::nif]
fn dig(env: Env, u: Uni, user: String, on: u32, p: Pos, bag: BagTerm) -> NifResult<Term> {
    let mut b = bag_in(bag);
    Ok(match lock(&u)?.dig(&user, on, p, &mut b) {
        Ok(()) => (ok(), bag_out(b)).encode(env),
        Err(e) => fail(env, e),
    })
}

/// Place one `item` from the bag at `p`, turned `rot`: `{:ok, bag}`.
#[rustler::nif]
fn place(
    env: Env,
    u: Uni,
    on: u32,
    p: Pos,
    item: String,
    rot: u8,
    bag: BagTerm,
) -> NifResult<Term> {
    let mut b = bag_in(bag);
    Ok(match lock(&u)?.place(on, p, &item, rot, &mut b) {
        Ok(()) => (ok(), bag_out(b)).encode(env),
        Err(e) => fail(env, e),
    })
}

/// Lay out a blueprint: `{:ok, site_id}`.
#[rustler::nif]
fn start_site(env: Env, u: Uni, kind: String, on: u32, p: Pos, rot: u8) -> NifResult<Term> {
    Ok(match lock(&u)?.start_site(&kind, on, p, rot) {
        Ok(id) => (ok(), id).encode(env),
        Err(e) => fail(env, e),
    })
}

/// Put ingredients in: `{:ok, built_furniture_id | nil, bag}`.
#[rustler::nif]
fn deposit(env: Env, u: Uni, site_id: u32, bag: BagTerm) -> NifResult<Term> {
    let mut b = bag_in(bag);
    Ok(match lock(&u)?.deposit(site_id, &mut b) {
        Ok(built) => (ok(), built, bag_out(b)).encode(env),
        Err(e) => fail(env, e),
    })
}

#[rustler::nif]
fn site_at(u: Uni, on: u32, p: Pos) -> NifResult<Option<u32>> {
    Ok(lock(&u)?.site_at(on, p))
}

#[rustler::nif]
fn furniture_at(u: Uni, on: u32, p: Pos) -> NifResult<Option<u32>> {
    Ok(lock(&u)?.furniture_at(on, p))
}

/// Bag slot `slot` into furniture `id`: `{:ok, bag}`.
#[rustler::nif]
fn stash(env: Env, u: Uni, at: Feet, id: u32, bag: BagTerm, slot: usize) -> NifResult<Term> {
    let mut b = bag_in(bag);
    Ok(match lock(&u)?.stash(at, id, &mut b, slot) {
        Ok(()) => (ok(), bag_out(b)).encode(env),
        Err(e) => fail(env, e),
    })
}

/// Furniture `id`'s slot `slot` into the bag: `{:ok, bag}`.
#[rustler::nif]
fn take(env: Env, u: Uni, at: Feet, id: u32, slot: usize, bag: BagTerm) -> NifResult<Term> {
    let mut b = bag_in(bag);
    Ok(match lock(&u)?.take(at, id, slot, &mut b) {
        Ok(()) => (ok(), bag_out(b)).encode(env),
        Err(e) => fail(env, e),
    })
}

/// Take hold of furniture: `{:ok, :pocketed | :gripped | :lifted, bag}`.
#[rustler::nif]
fn grab(env: Env, u: Uni, user: String, at: Feet, id: u32, bag: BagTerm) -> NifResult<Term> {
    let mut b = bag_in(bag);
    Ok(match lock(&u)?.grab(&user, at, id, &mut b) {
        Ok(g) => {
            let how = match g {
                Grabbed::Pocketed => pocketed(),
                Grabbed::Gripped => gripped(),
                Grabbed::Lifted => lifted(),
            };
            (ok(), how, bag_out(b)).encode(env)
        }
        Err(e) => fail(env, e),
    })
}

/// Lift the carryable block at `p` out of the world: `{:ok, block_id}`.
#[rustler::nif]
fn pick_block(env: Env, u: Uni, user: String, at: Feet, on: u32, p: Pos) -> NifResult<Term> {
    Ok(match lock(&u)?.pick_block(&user, at, on, p) {
        Ok(id) => (ok(), id).encode(env),
        Err(e) => fail(env, e),
    })
}

#[rustler::nif]
fn pick_cow(env: Env, u: Uni, user: String, at: Feet, id: u32) -> NifResult<Term> {
    Ok(done(env, lock(&u)?.pick_cow(&user, at, id)))
}

/// Put down what's carried at `p`, turned `rot`.
#[rustler::nif]
fn put_down(env: Env, u: Uni, user: String, on: u32, p: Pos, rot: u8) -> NifResult<Term> {
    Ok(match lock(&u)?.put_down(&user, on, p, rot) {
        Ok(_) => ok().encode(env),
        Err(e) => fail(env, e),
    })
}

/// `user` left: set down what they carried, leave any helm.
#[rustler::nif]
fn release(u: Uni, user: String) -> NifResult<()> {
    lock(&u)?.release(&user);
    Ok(())
}

/// `user`, standing at `at` (world), takes the helm beside them:
/// `{:ok, ship_id}`.
#[rustler::nif]
fn take_helm(env: Env, u: Uni, user: String, at: Feet) -> NifResult<Term> {
    Ok(match lock(&u)?.take_helm(&user, at) {
        Ok(id) => (ok(), id).encode(env),
        Err(e) => fail(env, e),
    })
}

/// True if they were at a helm.
#[rustler::nif]
fn leave_helm(u: Uni, user: String) -> NifResult<bool> {
    Ok(lock(&u)?.leave_helm(&user))
}

/// The pilot asks for `{thrust, turn, lift}`, each -1..1.
#[rustler::nif]
fn steer(env: Env, u: Uni, user: String, helm: Feet) -> NifResult<Term> {
    let h = Helm::new(helm.0, helm.1, helm.2);
    Ok(done(env, lock(&u)?.steer(&user, h)))
}

/// A ship and its cargo (as `departed` gave them) fly in from the
/// neighbour on `from`: `{:ok, ship_id}`.
#[rustler::nif]
fn arrive(env: Env, u: Uni, cargo: String, from: String) -> NifResult<Term> {
    let Some(side) = Side::from_name(&from) else {
        return Ok(fail(env, "bad_side"));
    };
    Ok(match serde_json::from_str::<Cargo>(&cargo) {
        Ok(c) => (ok(), lock(&u)?.arrive(c, side)).encode(env),
        Err(e) => fail(env, &e.to_string()),
    })
}

#[rustler::nif]
fn call_helper(env: Env, u: Uni, user: String, id: u32) -> NifResult<Term> {
    Ok(done(env, lock(&u)?.call_helper(&user, id)))
}

/// Advance to `now_ms` with players standing where `players` say
/// (`{id, on, {x, y, z}}`). Returns `{cows, moos, ships, helpers}`: rows of
/// `{id, x, y, z, heading}` for the cows and helpers that moved, cows that
/// mooed, and `[id, x, y, z, heading, vx, vy, vz, spin]` for ships.
#[rustler::nif]
fn tick(
    u: Uni,
    now_ms: i64,
    players: Vec<WalkerTerm>,
) -> NifResult<(Vec<Row>, Vec<u32>, Vec<Vec<f64>>, Vec<Row>)> {
    let walkers: Vec<Walker> = players
        .into_iter()
        .map(|(id, on, at)| Walker { id, on, at })
        .collect();
    let out = lock(&u)?.tick(now_ms, &walkers);
    Ok((out.cows, out.moos, out.ships, out.helpers))
}

/// Everything that changed since last asked, as `{event, payload}`.
#[rustler::nif]
fn drain<'a>(env: Env<'a>, u: Uni) -> NifResult<Vec<Term<'a>>> {
    let mut s = lock(&u)?;
    let events = s.drain_events();
    Ok(events
        .into_iter()
        .filter_map(|e| event_term(env, &s, e))
        .collect())
}

/// Everything a newcomer needs to see.
#[rustler::nif]
fn snapshot<'a>(env: Env<'a>, u: Uni) -> NifResult<Term<'a>> {
    let s = lock(&u)?;
    let row = |id: u32, x: f64, y: f64, z: f64, h: f64| (id, x, y, z, h);
    let cows: Vec<Row> = s
        .cows
        .iter()
        .map(|c| row(c.id, c.x, c.y, c.z, c.heading))
        .collect();
    let crops: Vec<Term> = s
        .crops
        .iter()
        .map(|(p, c)| {
            map(
                env,
                &[("position", pos(env, *p)), ("stage", c.stage.encode(env))],
            )
        })
        .collect();
    let held: Vec<Term> = s
        .holding()
        .map(|(u, h)| held_term(env, u, Some(h)))
        .collect();
    let mut furn: Vec<&Furniture> = s.furniture.values().collect();
    furn.sort_by_key(|f| f.id);
    let furn: Vec<Term> = furn.into_iter().map(|f| furniture_term(env, f)).collect();
    let sites: Vec<Term> = s.sites.values().map(|x| site_term(env, x)).collect();
    let ships: Vec<Term> = s.ships.iter().map(|x| ship_term(env, x)).collect();
    let helpers: Vec<Term> = s
        .helpers
        .iter()
        .map(|h| {
            map(
                env,
                &[
                    ("id", h.id.encode(env)),
                    ("name", h.name.encode(env)),
                    ("x", h.x.encode(env)),
                    ("y", h.y.encode(env)),
                    ("z", h.z.encode(env)),
                    ("heading", h.heading.encode(env)),
                ],
            )
        })
        .collect();
    Ok(map(
        env,
        &[
            ("cows", cows.encode(env)),
            ("crops", crops.encode(env)),
            ("held", held.encode(env)),
            ("carryable", sim::CARRYABLE.to_vec().encode(env)),
            ("furniture", furn.encode(env)),
            ("sites", sites.encode(env)),
            ("ships", ships.encode(env)),
            ("helpers", helpers.encode(env)),
            ("open", s.open().to_vec().encode(env)),
        ],
    ))
}

/// What there is: furniture kinds and items, for clients.
#[rustler::nif]
fn catalog(env: Env) -> Term {
    let kinds: Vec<Term> = furniture::KINDS
        .iter()
        .map(|k| {
            map(
                env,
                &[
                    ("name", k.name.encode(env)),
                    ("size", vec![k.size.0, k.size.1, k.size.2].encode(env)),
                    ("slots", k.slots.encode(env)),
                    ("carriers", k.carriers.encode(env)),
                    ("itemizable", k.itemizable.encode(env)),
                    ("recipe", pairs(env, k.recipe)),
                ],
            )
        })
        .collect();
    let items: Vec<Term> = items::ITEMS
        .iter()
        .map(|i| {
            map(
                env,
                &[
                    ("name", i.name.encode(env)),
                    ("stack", i.stack.encode(env)),
                    ("block", opt(env, i.block)),
                    ("furniture", opt(env, i.furniture)),
                ],
            )
        })
        .collect();
    map(
        env,
        &[
            ("kinds", kinds.encode(env)),
            ("items", items.encode(env)),
            ("bag_slots", items::BAG_SLOTS.encode(env)),
        ],
    )
}

/// A new player's bag.
#[rustler::nif]
fn starter_bag() -> BagTerm {
    bag_out(items::starter_bag())
}

/// Add `n` of `item` to a bag: `{bag, didnt_fit}`.
#[rustler::nif]
fn bag_add(bag: BagTerm, item: String, n: u16) -> (BagTerm, u16) {
    let mut b = bag_in(bag);
    let left = items::add(&mut b, &item, n);
    (bag_out(b), left)
}

rustler::init!("Elixir.Sosh.Universe");
