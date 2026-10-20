//! Furniture: what it's made of, how big it is, what it holds and how many
//! it takes to carry. Built from blueprints (`Site`): a footprint of
//! scaffolding that ingredients are put into until the recipe is met.
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
    pub recipe: &'static [(&'static str, u16)],
}

pub const KINDS: &[Kind] = &[
    Kind {
        name: "chest",
        size: (1, 1, 1),
        slots: 12,
        carriers: 1,
        itemizable: false,
        recipe: &[("wood", 4)],
    },
    Kind {
        name: "drawer",
        size: (1, 1, 1),
        slots: 4,
        carriers: 1,
        itemizable: true,
        recipe: &[("wood", 2), ("stone", 1)],
    },
    Kind {
        name: "dresser",
        size: (2, 1, 1),
        slots: 16,
        carriers: 2,
        itemizable: false,
        recipe: &[("wood", 6), ("stone", 2)],
    },
    Kind {
        name: "table",
        size: (2, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: false,
        recipe: &[("wood", 5)],
    },
    Kind {
        name: "stool",
        size: (1, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: true,
        recipe: &[("wood", 2)],
    },
    Kind {
        name: "wardrobe",
        size: (1, 1, 2),
        slots: 20,
        carriers: 2,
        itemizable: false,
        recipe: &[("wood", 8), ("stone", 1)],
    },
    // what's left when furniture breaks and its contents don't fit the
    // breaker's bag; it goes when emptied
    Kind {
        name: "sack",
        size: (1, 1, 1),
        slots: 0,
        carriers: 1,
        itemizable: false,
        recipe: &[],
    },
];

pub fn kind(name: &str) -> Option<&'static Kind> {
    KINDS.iter().find(|k| k.name == name)
}

/// Buildable from a blueprint.
pub fn buildable(name: &str) -> Option<&'static Kind> {
    kind(name).filter(|k| !k.recipe.is_empty())
}

/// What breaking it gives back: half of each ingredient, rounded down.
pub fn salvage(k: &Kind) -> Vec<(&'static str, u16)> {
    k.recipe
        .iter()
        .map(|&(i, n)| (i, n / 2))
        .filter(|&(_, n)| n > 0)
        .collect()
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
        let cs = self.cells();
        let n = cs.len() as f64;
        let (sx, sy) = cs
            .iter()
            .fold((0.0, 0.0), |(a, b), c| (a + c.0 as f64, b + c.1 as f64));
        (sx / n, sy / n, self.origin.2 as f64)
    }

    pub fn helpers(&self) -> impl Iterator<Item = u32> + '_ {
        self.grips.iter().filter_map(|g| match g {
            Grip::Helper(h) => Some(*h),
            _ => None,
        })
    }
}

/// A blueprint being built: scaffolding in the footprint, and what's been
/// put in so far.
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

    pub fn has(&self, item: &str) -> u16 {
        self.have
            .iter()
            .find(|(i, _)| i == item)
            .map_or(0, |(_, n)| *n)
    }

    /// Each ingredient still missing, and how many.
    pub fn missing(&self) -> Vec<(&'static str, u16)> {
        self.info()
            .recipe
            .iter()
            .map(|&(i, n)| (i, n.saturating_sub(self.has(i))))
            .filter(|&(_, n)| n > 0)
            .collect()
    }

    pub fn put(&mut self, item: &str, n: u16) {
        match self.have.iter_mut().find(|(i, _)| i == item) {
            Some((_, have)) => *have += n,
            None => self.have.push((item.to_string(), n)),
        }
    }
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

    #[test]
    fn breaking_gives_back_some_not_all() {
        let k = kind("dresser").unwrap();
        assert_eq!(salvage(k), vec![("wood", 3), ("stone", 1)]);
        let drawer = kind("drawer").unwrap();
        assert_eq!(salvage(drawer), vec![("wood", 1)]);
        assert!(buildable("sack").is_none());
    }

    #[test]
    fn a_site_counts_what_is_missing() {
        let mut s = Site {
            id: 1,
            kind: "drawer".into(),
            on: 0,
            origin: (0, 0, 0),
            rot: 0,
            have: vec![],
        };
        assert_eq!(s.missing(), vec![("wood", 2), ("stone", 1)]);
        s.put("wood", 2);
        assert_eq!(s.missing(), vec![("stone", 1)]);
    }
}
