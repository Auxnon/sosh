use entity::Entity;
use hashbrown::HashMap;
use rustler::{NifResult, ResourceArc};
use uuid::Uuid;

mod entity;


struct Universe {
    entities: HashMap<Uuid, Entity>,
}

impl Universe {
    fn new() -> Self {
        Self {
            entities: Mutex::new(HashMap::default()),
        }
    }
}

type ArcUni = ResourceArc<Universe>;

#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

#[rustler::nif]
fn bigbang() -> NifResult<ArcUni> {
    let u = Universe::new();
    Ok(ResourceArc::new(u))
}

#[rustler::nif]
fn update(state:ArcUni, value: f64) -> ArcUni{
    // state.
    // let mut data = state.data.lock().unwrap();
    data.push(value);
    state
}

#[rustler::nif]
fn init_rust_state() -> NifResult<ResourceArc<StateResource>> {
    let state = StateResource {
        data: Mutex::new(Vec::new()),
    };
    Ok(ResourceArc::new(state))
}

rustler::init!("Elixir.ChatTest.Universe");
