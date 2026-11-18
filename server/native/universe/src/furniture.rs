//! Furniture: how big it is, what it holds and how many it takes to carry.
//! What it's made of is its recipe (`recipes`). Some kinds are stations,
//! where recipe steps are done (`recipes::STATIONS`).
//!
//! Blueprints (`Site`) are retired: nothing starts one any more, but those
//! laid out before are kept where they are, scaffolding and all, until
//! they're broken for what was put into them.
//!
//! A piece sits in cells from its origin along +x (width), +y (depth) and +z
//! (height), turned by `rot` quarter turns about the origin cell, so a model
//! drawn from its origin cell along +x and +y lines up when rotated by
//! rot * 90 degrees.

use serde::{Deserialize, Serialize};

use crate::items::{self, Slot};
use crate::terrain::Pos;

pub struct Kind {
    pub name: &'static str,
    /// Width (x), depth (y), height (z) in cells, unturned.
    pub size: (i32, i32, i32),
    /// Container slots; 0 holds nothing.
    pub slots: usize,
    /// How many have to hold it before it lifts.
    pub carriers: usize,
    /// Packs into a bag (as the item of the same name) when empty.
    pub itemizable: bool,
}

pub const KINDS: &[Kind] = &[
    Kind {
        name: "chest",
        size: (1, 1, 1),
        slots: 12,
        carriers: 1,
        itemizable: false,
    },
    Kind {
        name: "drawer",
        size: (1, 1, 1),
        slots: 4,
        carriers: 1,
        itemizable: true,
    },
    Kind {
        name: "dresser",
        size: (2, 1, 1),
        slots: 16,
        carriers: 2,
        itemizable: false,
    },
    Kind {
        name: "table",
        size: (2, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: false,
    },
    Kind {
        name: "stool",
        size: (1, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: true,
    },
    Kind {
        name: "wardrobe",
        size: (1, 1, 2),
        slots: 20,
        carriers: 2,
        itemizable: false,
    },
    // somewhere to lie down (the game lays you on it)
    Kind {
        name: "bed",
        size: (1, 2, 1),
        slots: 0,
        carriers: 2,
        itemizable: false,
    },
    // a door to walk through (the game lets you pass its cells)
    Kind {
        name: "door",
        size: (1, 1, 2),
        slots: 0,
        carriers: 1,
        itemizable: true,
    },
    // a door into a pocket room of its own (`Sim::use_door`): the room
    // belongs to whoever first goes through, and outlives the door
    Kind {
        name: "hyperdoor",
        size: (1, 1, 2),
        slots: 0,
        carriers: 1,
        itemizable: true,
    },
    // the way back out, inside a pocket room; part of the room, so it
    // can't be broken or moved
    Kind {
        name: "hyperexit",
        size: (1, 1, 2),
        slots: 0,
        carriers: 1,
        itemizable: false,
    },
    // a pinned chat message, placed (its item is `sign:<pin id>`, kept in
    // `Furniture::note`); never built, and it packs back into a bag
    Kind {
        name: "sign",
        size: (1, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: true,
    },
    // a bag of marbles set down (its item is `marbles:<n>`, the count kept
    // in `Furniture::note`); never built, and it packs back into a bag
    Kind {
        name: "marbles",
        size: (1, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: true,
    },
    // stations (`recipes::STATIONS`): where wood is veneered into planks,
    // planks sawn and furniture put together, wool spun and yarn woven
    Kind {
        name: "veneer",
        size: (1, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: true,
    },
    Kind {
        name: "bench",
        size: (2, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: true,
    },
    Kind {
        name: "spinning_wheel",
        size: (1, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: true,
    },
    Kind {
        name: "loom",
        size: (2, 1, 2),
        slots: 0,
        carriers: 2,
        itemizable: false,
    },
    // what's left when furniture breaks and its contents don't fit the
    // breaker's bag; it goes when emptied
    Kind {
        name: "sack",
        size: (1, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: false,
    },
];

pub fn kind(name: &str) -> Option<&'static Kind> {
    KINDS.iter().find(|k| k.name == name)
}

/// The cells of something `size` big at `origin`, turned `rot` quarter
/// turns counter-clockwise about the origin cell.
pub fn cells(origin: Pos, size: (i32, i32, i32), rot: u8) -> Vec<Pos> {
    let mut out = Vec::new();
    for k in 0..size.2 {
        for j in 0..size.1 {
            for i in 0..size.0 {
                let (dx, dy) = match rot % 4 {
                    0 => (i, j),
                    1 => (-j, i),
                    2 => (-i, -j),
                    _ => (j, -i),
                };
                out.push((origin.0 + dx, origin.1 + dy, origin.2 + k));
            }
        }
    }
    out
}

/// Who has hold of a piece: a player, by id, or a helper.
#[derive(Clone, Debug, PartialEq)]
pub enum Grip {
    Player(String),
    Helper(u32),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Furniture {
    pub id: u32,
    pub kind: String,
    /// The ship it stands on, by id, or 0 for the world: `origin` and its
    /// cells are in that frame.
    #[serde(default)]
    pub on: u32,
    pub origin: Pos,
    pub rot: u8,
    pub slots: Vec<Slot>,
    /// What makes this one itself: a sign's pin id, how many marbles a bag
    /// of them holds, the room a hyperdoor leads to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// Who's holding it; it lifts once there are `carriers` of them.
    #[serde(skip)]
    pub grips: Vec<Grip>,
    #[serde(skip)]
    pub lifted: bool,
    /// Where it is while lifted: its carriers' middle, at their feet.
    #[serde(skip)]
    pub at: (f64, f64, f64),
}

impl Furniture {
    pub fn new(id: u32, kind: &Kind, origin: Pos, rot: u8) -> Self {
        Furniture {
            id,
            kind: kind.name.to_string(),
            on: 0,
            origin,
            rot: rot % 4,
            slots: items::empty(kind.slots),
            note: None,
            grips: Vec::new(),
            lifted: false,
            at: (0.0, 0.0, 0.0),
        }
    }

    pub fn info(&self) -> &'static Kind {
        kind(&self.kind).unwrap_or(&KINDS[0])
    }

    pub fn cells(&self) -> Vec<Pos> {
        cells(self.origin, self.info().size, self.rot)
    }

    /// The middle of its footprint, at its base, in its frame.
    pub fn center(&self) -> (f64, f64, f64) {
        middle(&self.cells(), self.origin.2)
    }

    /// The item it packs into: its kind's, or a sign's or a marble bag's own.
    pub fn item(&self) -> String {
        match &self.note {
            Some(n) if self.whole() => format!("{}:{n}", self.kind),
            _ => self.kind.clone(),
        }
    }

    /// Not made of anything, so breaking it gives it back whole.
    pub fn whole(&self) -> bool {
        matches!(self.kind.as_str(), "sign" | "marbles")
    }

    /// Part of where it stands: never broken, picked up or carried.
    pub fn fixed(&self) -> bool {
        self.kind == "hyperexit"
    }

    /// The pocket room a hyperdoor leads to, once someone's been through.
    pub fn pocket(&self) -> Option<u32> {
        if self.kind != "hyperdoor" {
            return None;
        }
        self.note.as_deref()?.parse().ok()
    }

    /// One cell out from its front (-y, turned with it), at its base: where
    /// someone coming out of it stands, in its frame.
    pub fn front(&self) -> (f64, f64, f64) {
        let (dx, dy) = match self.rot % 4 {
            0 => (0, -1),
            1 => (1, 0),
            2 => (0, 1),
            _ => (-1, 0),
        };
        let o = self.origin;
        ((o.0 + dx) as f64, (o.1 + dy) as f64, o.2 as f64)
    }

    pub fn helpers(&self) -> impl Iterator<Item = u32> + '_ {
        self.grips.iter().filter_map(|g| match g {
            Grip::Helper(h) => Some(*h),
            _ => None,
        })
    }
}

/// A blueprint laid out before blueprints were retired: scaffolding in its
/// footprint, and what was put in so far. Kept as it is; breaking it gives
/// back everything put in.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Site {
    pub id: u32,
    pub kind: String,
    /// As `Furniture::on`.
    #[serde(default)]
    pub on: u32,
    pub origin: Pos,
    pub rot: u8,
    pub have: Vec<(String, u16)>,
}

impl Site {
    pub fn info(&self) -> &'static Kind {
        kind(&self.kind).unwrap_or(&KINDS[0])
    }

    pub fn cells(&self) -> Vec<Pos> {
        cells(self.origin, self.info().size, self.rot)
    }

    /// The middle of its footprint, at its base, in its frame.
    pub fn center(&self) -> (f64, f64, f64) {
        middle(&self.cells(), self.origin.2)
    }
}

fn middle(cs: &[Pos], z: i32) -> (f64, f64, f64) {
    let n = cs.len().max(1) as f64;
    let (sx, sy) = cs
        .iter()
        .fold((0.0, 0.0), |(a, b), c| (a + c.0 as f64, b + c.1 as f64));
    (sx / n, sy / n, z as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn footprints_turn_about_the_origin() {
        let size = kind("dresser").unwrap().size;
        assert_eq!(cells((5, 5, 0), size, 0), vec![(5, 5, 0), (6, 5, 0)]);
        assert_eq!(cells((5, 5, 0), size, 1), vec![(5, 5, 0), (5, 6, 0)]);
        assert_eq!(cells((5, 5, 0), size, 2), vec![(5, 5, 0), (4, 5, 0)]);
        assert_eq!(cells((5, 5, 0), size, 3), vec![(5, 5, 0), (5, 4, 0)]);
        let tall = kind("wardrobe").unwrap().size;
        assert_eq!(cells((0, 0, 0), tall, 1), vec![(0, 0, 0), (0, 0, 1)]);
    }
}
