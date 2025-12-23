use rustler::{Decoder, Encoder, NifMap, Error, Term};
use std::fmt;
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

impl fmt::Display for Vec3 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // Use `self.number` to refer to each positional data point.
        write!(f, "({}, {}, {})", self.x,self.y,self.z)
    }
}

// impl Decoder<'_> for Vec3 {
//     fn decode(term: rustler::Term<'_>) -> rustler::NifResult<Self> {
//         // term.
//         Ok(Vec3::new(0., 0., 0.))
//     }
// }

// #[derive(NifMap)]
pub struct Entity {
    pos: Vec3,
    id: Uuid,
}

// impl Encoder for Uuid{
//     fn encode<'a>(&self, env: rustler::Env<'a>) -> rustler::Term<'a> {
//         self.encode(env)
//     }
// }
//
// impl<'a> Decoder<'a> for Uuid {
//     // fn decode(term: rustler::Term<'a>) -> rustler::NifResult<Self> {
//     //   Ok(Self::from( term.decode()?))
//     // }
//     
//      fn decode(term: Term<'a>) -> rustler::NifResult<Self> {
//         // First try to decode as binary
//         if term.is_binary() {
//             let bytes: Vec<u8> = term.decode()?;
//             return Uuid::from_slice(&bytes)
//                 .map_err(|_| Error::RaiseAtom("invalid_uuid_binary"));
//         }
//
//         // Then try to decode as string
//         let string_val: &str = term.decode()?;
//         Uuid::parse_str(string_val)
//             .map_err(|_| Error::RaiseAtom("invalid_uuid_string"))
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

    pub fn into_term<'a>(&self, env: rustler::Env<'a>) -> rustler::Term<'a> {
        let map = rustler::types::map::map_new(env);
        // println!("to term {}",self.id);
        map.map_put("id", self.id.as_bytes().encode(env)).unwrap();
        map.map_put("pos", self.pos).unwrap();
        map.encode(env)
    }
}

impl fmt::Display for Entity {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // Use `self.number` to refer to each positional data point.
        write!(f, "({}, {})", self.id, self.pos)
    }
}
