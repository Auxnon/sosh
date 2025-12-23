use std::{ops::DerefMut, sync::{Mutex, RwLock}};

use entity::{Entity, Vec3};
use hashbrown::HashMap;
use rustler::{env, Decoder, Encoder, Env, Error, NifResult, Resource, ResourceArc, Term};
use uuid::Uuid;

mod entity;

struct Universe {
    pub entities: HashMap<Uuid, Entity>,
}

impl Universe {
    fn new() -> Self {
        Self {
            entities: HashMap::default(),
        }
    }
    fn get_state<'a>(&self, env: Env<'a>) -> Vec<Term<'a>> {
        self.entities
            .values()
            .map(|e| e.into_term(env))
            .collect()
    }
}


struct UniLock(RwLock<Universe>);
impl std::ops::Deref for UniLock {
    type Target = RwLock<Universe>;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl DerefMut for UniLock {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
        // let a=self.deref_mut();
    }
}
impl Resource for UniLock {}
type ArcUni = ResourceArc<UniLock>;

fn load(env: Env, _term: Term) -> bool {
    // let _a=env.register::<UL>().is_ok();
    let _b=env.register::<UniLock>().is_ok();
    true
}

#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

#[rustler::nif]
fn bigbang() -> ArcUni {
    let u = Universe::new();
    ResourceArc::new(UniLock(RwLock::new(u)))
    // ResourceArc::new(UL{ mutex: Mutex::new(u)})
}
// #[rustler::nif]
// fn bigbang() -> Universe {
//     Universe::new()
// }

// #[rustler::nif]
// fn update(state: ArcUni, value: f64) -> ArcUni {
//     // state.
//     // let mut data = state.data.lock().unwrap();
//     // data.push(value);
//     state
// }

// impl Decoder for Uuid{
//     decode
// }
// fn none_err<T>(option: Option<T>)-> NifResult<>

// return rust uuid as an elixir binary
#[rustler::nif]
fn new_ent(env: Env, state: ArcUni) -> NifResult<Term> {
    match state.write() {
        Ok(mut u) => {
            let e = Entity::new();
            let id = e.get_id();
            u.entities.insert(e.get_id(), e);
            println!("got ent");
            u.entities.iter().for_each(|(k,v)|{
                println!("key {} ent {}", k,v);
            });
            Ok(id.as_bytes().encode(env))
        }
        Err(_) => Err(Error::Term(Box::new("Universe lock poisoned"))),
    }
}

#[rustler::nif]
fn move_ent(state: ArcUni, id: Term, pos: Vec3) -> NifResult<()> {
    // let n = uuid::Uuid::fr
    //
    // if let Ok(bytes) =id.decode::<rustler::Binary>() {
    //     return Uuid::from_slice(bytes.as_slice())
    //         .map_err(|_| Error::Term(Box::new("Invalid UUID bytes")));
    // }

    state.write().unwrap().entities.get_mut(&Uuid::new_v4());

    match (id.decode_as_binary(), state.write()) {
        (Ok(b), Ok(mut u)) => {
            let id = Uuid::from_slice(b.as_slice())
                .map_err(|_| Error::Term(Box::new("Invalid UUID bytes")))?;
            match u.entities.get_mut(&id) {
                Some(e) => {
                    e.nav(pos);
                    Ok(())
                }
                None => Err(Error::Term(Box::new("Entity missing"))),
            }
        }
        (Err(e), _) => Err(e),
        (_, Err(_)) => Err(Error::Term(Box::new("Universe lock poisoned"))),
    }
}

#[rustler::nif]
fn get_state(env: Env, state: ArcUni) -> NifResult<Vec<Term>> {
    match state.read() {
        Ok(u) => Ok(u.get_state(env)),
        Err(_) => Err(Error::Term(Box::new("Universe lock poisoned"))),
    }
}

// #[rustler::nif]
// fn init_rust_state() -> NifResult<ResourceArc<StateResource>> {
//     let state = StateResource {
//         data: Mutex::new(Vec::new()),
//     };
//     Ok(ResourceArc::new(state))
// }

rustler::init!("Elixir.ChatTest.Universe", load = load);
