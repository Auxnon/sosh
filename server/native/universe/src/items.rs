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
];

/// What a new player starts with: enough to build a few things.
pub const STARTER: &[(&str, u16)] = &[
    ("wood", 24),
    ("stone", 12),
    ("path", 8),
    ("pot", 2),
    ("deck", 12),
];

pub fn info(name: &str) -> Option<&'static ItemInfo> {
    ITEMS.iter().find(|i| i.name == name)
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
