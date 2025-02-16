use rustler::{Decoder, Encoder, NifMap};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, NifMap)]
pub struct Vec3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Vec3 {
    fn new(x: f64, y: f64, z: f64) -> Self {
        Self { x, y, z }
    }
    // fn set(&mut self, v: &Vec3){
    //     self.x
    // }
}

// impl Decoder<'_> for Vec3 {
//     fn decode(term: rustler::Term<'_>) -> rustler::NifResult<Self> {
//         // term.
//         Ok(Vec3::new(0., 0., 0.))
//     }
// }

pub struct Entity {
    pos: Vec3,
    id: Uuid,
}

impl Entity {
    pub fn new() -> Self {
        let id = Uuid::new_v4();
        Self {
            pos: Vec3::new(0., 0., 0.),
            id,
        }
    }
    pub fn nav(&mut self, v: Vec3) {
        self.pos = v;
    }

    pub fn get_id(&self) -> Uuid {
        self.id
    }

    pub fn into_term<'a>(&self, env: rustler::Env<'a>) -> rustler::Term<'a> {
        let map = rustler::types::map::map_new(env);
        map.map_put("id", self.id.as_bytes().encode(env)).unwrap();
        map.map_put("pos", self.pos).unwrap();
        map
    }
}
