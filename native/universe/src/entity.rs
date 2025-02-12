use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Vec3 {
    x: f64,
    y: f64,
    z: f64,
}

impl Vec3 {
    fn new(x: f64, y: f64, z: f64) -> Self {
        Self { x, y, z }
    }
}

pub struct Entity {
    pos: Vec3,
    id: Uuid,
}

impl Entity {
    fn new() -> Self {
        let id = Uuid::new_v4();
        Self {
            pos: Vec3::new(0., 0., 0.),
            id,
        }
    }
}
