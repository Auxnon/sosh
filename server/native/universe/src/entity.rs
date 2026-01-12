use rustler::{Encoder, NifMap, Term};
use std::fmt;
use uuid::Uuid;
use serde::{Serialize, Deserialize};

#[derive(Debug, Clone, Copy, PartialEq, NifMap, Serialize, Deserialize)]
pub struct Vec3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, NifMap, Serialize, Deserialize)]
pub struct Vec3i {
    pub x: i32,
    pub y: i32,
    pub z: i32,
}

impl Vec3 {
    fn new(x: f64, y: f64, z: f64) -> Self {
        Self { x, y, z }
    }
}

impl Vec3i {
    fn new(x: i32, y: i32, z: i32) -> Self {
        Self { x, y, z }
    }
}

impl fmt::Display for Vec3 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "({}, {}, {})", self.x, self.y, self.z)
    }
}

impl fmt::Display for Vec3i {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "({}, {}, {})", self.x, self.y, self.z)
    }
}
// #[derive(NifMap)]
pub struct Entity {
    pub pos: Vec3,
    pub id: Uuid,
}

// impl NifMap for Entity {
//     fn map<'a>(&self, env: rustler::Env<'a>) -> rustler::Term<'a> {
//         let map = rustler::types::map::map_new(env);
//         map.map_put("id", self.id.as_bytes().encode(env)).unwrap();
//         map.map_put("pos", self.pos).unwrap();
//         map.encode(env)
//     }
// }

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
    
    pub fn into_term<'a>(&self, env: rustler::Env<'a>) -> Term<'a> {
        let map = rustler::types::map::map_new(env);
        map.map_put("id", self.id.as_bytes().encode(env)).unwrap();
        map.map_put("pos", self.pos).unwrap();
        map.encode(env)
    }
}

impl fmt::Display for Entity {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "({}, {})", self.id, self.pos)
    }
}
