//! Items and the slots that hold them: a player's bag, a chest's insides.
//!
//! A slot is empty or a stack of one item. Adding fills matching stacks
//! before empty slots; nothing here ever drops an item: whatever doesn't fit
//! is handed back.

use serde::{Deserialize, Serialize};

use crate::terrain;

/// Slots in a player's bag.
pub const BAG_SLOTS: usize = 16;

pub struct ItemInfo {
    pub name: &'static str,
    /// Most of one item a slot holds.
    pub stack: u16,
    /// The block it places, for a block item.
    pub block: Option<u8>,
    /// The furniture it places, for furniture that packs into a bag.
    pub furniture: Option<&'static str>,
}

const fn block(name: &'static str, id: u8) -> ItemInfo {
    ItemInfo {
        name,
        stack: 64,
        block: Some(id),
        furniture: None,
    }
}

pub const ITEMS: &[ItemInfo] = &[
    block("grass", terrain::GRASS),
    block("dirt", terrain::DIRT),
    block("stone", terrain::STONE),
    block("wood", terrain::WOOD),
    block("path", terrain::PATH),
    block("pot", terrain::POT),
    block("deck", terrain::DECK),
    block("hull", terrain::HULL),
    block("balloon", terrain::BALLOON),
    block("rail", terrain::RAIL),
    block("helm", terrain::HELM),
    ItemInfo {
        name: "carrot",
        stack: 64,
        block: None,
        furniture: None,
    },
    ItemInfo {
        name: "drawer",
        stack: 4,
        block: None,
        furniture: Some("drawer"),
    },
    ItemInfo {
        name: "stool",
        stack: 4,
        block: None,
        furniture: Some("stool"),
    },
    ItemInfo {
        name: "door",
        stack: 4,
        block: None,
        furniture: Some("door"),
    },
    ItemInfo {
        name: "hyperdoor",
        stack: 1,
        block: None,
        furniture: Some("hyperdoor"),
    },
    // a chat message pinned (Sosh.Chat.pin): one of a kind, so a bag holds
    // it as `sign:<id>`, the pin's id; placed, it's a sign showing it
    ItemInfo {
        name: "sign",
        stack: 1,
        block: None,
        furniture: Some("sign"),
    },
    // a bag of marbles, the money: a bag holds it as `marbles:<n>`, one bag
    // to a slot; set down, it's a bag of marbles in the world. Marbles kept
    // in a wallet aren't items at all (Sosh.Players)
    ItemInfo {
        name: "marbles",
        stack: 1,
        block: None,
        furniture: Some("marbles"),
    },
];

/// Most marbles one bag of them holds.
pub const MARBLE_BAG_MAX: u32 = 99_999;

/// What a new player starts with: enough to build a few things.
pub const STARTER: &[(&str, u16)] = &[
    ("wood", 24),
    ("stone", 12),
    ("path", 8),
    ("pot", 2),
    ("deck", 12),
];

pub fn info(name: &str) -> Option<&'static ItemInfo> {
    let name = if sign_id(name).is_some() {
        "sign"
    } else if marbles_in(name).is_some() {
        "marbles"
    } else if name == "marbles" {
        // a bag of marbles always says how many
        return None;
    } else {
        name
    };
    ITEMS.iter().find(|i| i.name == name)
}

/// How many marbles a `marbles:<n>` bag holds.
pub fn marbles_in(name: &str) -> Option<u32> {
    let n: u32 = name.strip_prefix("marbles:")?.parse().ok()?;
    (1..=MARBLE_BAG_MAX).contains(&n).then_some(n)
}

pub fn marble_bag(n: u32) -> String {
    format!("marbles:{n}")
}

/// Put `n` marbles in `slots`: topping up the bags of them already there,
/// then in new bags. Returns how many didn't fit.
pub fn add_marbles(slots: &mut [Slot], mut n: u32) -> u32 {
    for s in slots.iter_mut().flatten() {
        if n == 0 {
            break;
        }
        if let Some(have) = marbles_in(&s.item) {
            let k = n.min(MARBLE_BAG_MAX - have);
            if k > 0 {
                s.item = marble_bag(have + k);
                n -= k;
            }
        }
    }
    for s in slots.iter_mut() {
        if n == 0 {
            break;
        }
        if s.is_none() {
            let k = n.min(MARBLE_BAG_MAX);
            *s = Some(Stack {
                item: marble_bag(k),
                n: 1,
            });
            n -= k;
        }
    }
    n
}

/// How many marbles would fit.
pub fn room_for_marbles(slots: &[Slot]) -> u64 {
    slots
        .iter()
        .map(|s| match s {
            None => MARBLE_BAG_MAX as u64,
            Some(s) => marbles_in(&s.item).map_or(0, |h| (MARBLE_BAG_MAX - h) as u64),
        })
        .sum()
}

/// The pin a `sign:<id>` item stands for.
pub fn sign_id(name: &str) -> Option<u64> {
    name.strip_prefix("sign:")?.parse().ok()
}

/// The item a dug block becomes.
pub fn for_block(id: u8) -> Option<&'static str> {
    ITEMS.iter().find(|i| i.block == Some(id)).map(|i| i.name)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stack {
    pub item: String,
    pub n: u16,
}

pub type Slot = Option<Stack>;

pub fn empty(n: usize) -> Vec<Slot> {
    vec![None; n]
}

pub fn starter_bag() -> Vec<Slot> {
    let mut bag = empty(BAG_SLOTS);
    for (item, n) in STARTER {
        add(&mut bag, item, *n);
    }
    bag
}

fn stack_of(item: &str) -> u16 {
    info(item).map_or(64, |i| i.stack)
}

/// Put `n` of `item` into `slots`; returns how many didn't fit.
pub fn add(slots: &mut [Slot], item: &str, mut n: u16) -> u16 {
    let max = stack_of(item);
    for s in slots.iter_mut().flatten() {
        if n == 0 {
            break;
        }
        if s.item == item && s.n < max {
            let k = n.min(max - s.n);
            s.n += k;
            n -= k;
        }
    }
    for s in slots.iter_mut() {
        if n == 0 {
            break;
        }
        if s.is_none() {
            let k = n.min(max);
            *s = Some(Stack {
                item: item.to_string(),
                n: k,
            });
            n -= k;
        }
    }
    n
}

/// How many of `item` would fit.
pub fn room_for(slots: &[Slot], item: &str) -> u32 {
    let max = stack_of(item) as u32;
    slots
        .iter()
        .map(|s| match s {
            None => max,
            Some(s) if s.item == item => max.saturating_sub(s.n as u32),
            Some(_) => 0,
        })
        .sum()
}

pub fn count(slots: &[Slot], item: &str) -> u32 {
    slots
        .iter()
        .flatten()
        .filter(|s| s.item == item)
        .map(|s| s.n as u32)
        .sum()
}

/// Take `n` of `item`, or nothing at all if there aren't that many.
pub fn take(slots: &mut [Slot], item: &str, mut n: u16) -> bool {
    if count(slots, item) < n as u32 {
        return false;
    }
    // from the last stacks first, so the first one stays put
    for s in slots.iter_mut().rev() {
        if n == 0 {
            break;
        }
        if let Some(st) = s {
            if st.item == item {
                let k = n.min(st.n);
                st.n -= k;
                n -= k;
                if st.n == 0 {
                    *s = None;
                }
            }
        }
    }
    true
}

/// Move what's in `from[slot]` into `to`, as much as fits.
/// False if the slot is empty or none of it fits.
pub fn shift(from: &mut [Slot], slot: usize, to: &mut [Slot]) -> bool {
    let Some(Some(st)) = from.get(slot).cloned() else {
        return false;
    };
    let left = add(to, &st.item, st.n);
    if left == st.n {
        return false;
    }
    from[slot] = if left == 0 {
        None
    } else {
        Some(Stack {
            item: st.item,
            n: left,
        })
    };
    true
}

pub fn is_empty(slots: &[Slot]) -> bool {
    slots.iter().all(|s| s.is_none())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stacks_fill_before_empty_slots() {
        let mut b = empty(3);
        assert_eq!(add(&mut b, "wood", 70), 0);
        assert_eq!(b[0].as_ref().unwrap().n, 64);
        assert_eq!(b[1].as_ref().unwrap().n, 6);
        assert_eq!(add(&mut b, "wood", 10), 0);
        assert_eq!(b[1].as_ref().unwrap().n, 16);
        assert!(b[2].is_none());
        // a stack of drawers is four
        assert_eq!(add(&mut b, "drawer", 6), 2);
        assert_eq!(room_for(&b, "wood"), 64 - 16);
        assert_eq!(room_for(&b, "drawer"), 0);
    }

    #[test]
    fn signs_are_one_of_a_kind() {
        assert_eq!(info("sign:42").unwrap().furniture, Some("sign"));
        assert!(info("sign:x").is_none());
        let mut b = empty(2);
        assert_eq!(add(&mut b, "sign:1", 1), 0);
        assert_eq!(add(&mut b, "sign:1", 1), 0, "another of the same pin takes its own slot");
        assert_eq!(add(&mut b, "sign:2", 1), 1, "no room left");
    }

    #[test]
    fn marbles_come_in_bags_that_top_up() {
        assert_eq!(info("marbles:5").unwrap().furniture, Some("marbles"));
        assert!(info("marbles").is_none());
        assert!(info("marbles:0").is_none());
        assert!(info("marbles:100000").is_none());
        let mut b = empty(2);
        assert_eq!(add_marbles(&mut b, 99_990), 0);
        assert_eq!(add_marbles(&mut b, 20), 0);
        assert_eq!(b[0].as_ref().unwrap().item, "marbles:99999");
        assert_eq!(b[1].as_ref().unwrap().item, "marbles:11");
        assert_eq!(room_for_marbles(&b), 99_988);
        assert_eq!(add_marbles(&mut b, 100_000), 12);
    }

    #[test]
    fn take_is_all_or_nothing() {
        let mut b = starter_bag();
        assert_eq!(count(&b, "wood"), 24);
        assert!(!take(&mut b, "wood", 25));
        assert_eq!(count(&b, "wood"), 24);
        assert!(take(&mut b, "wood", 24));
        assert_eq!(count(&b, "wood"), 0);
        assert!(b[0].is_none());
    }

    #[test]
    fn shifting_keeps_what_does_not_fit() {
        let mut from = empty(2);
        add(&mut from, "stone", 50);
        let mut to = empty(1);
        add(&mut to, "stone", 40);
        assert!(shift(&mut from, 0, &mut to));
        assert_eq!(count(&to, "stone"), 64);
        assert_eq!(count(&from, "stone"), 26);
        assert!(!shift(&mut from, 0, &mut to), "nothing fits");
        assert!(!shift(&mut from, 1, &mut to), "empty slot");
    }
}
