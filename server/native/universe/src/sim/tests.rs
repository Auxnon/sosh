use super::*;
use crate::items::{count, starter_bag};
use crate::terrain::{STONE, WOOD};

/// A flat grass floor at z = -1 across x, y in 0..16, so the standing
/// height there is 0; awake.
fn flat() -> Sim {
    let mut s = Sim::empty(1000, 42);
    for x in 0..16 {
        for y in 0..16 {
            s.terrain.set(x, y, -1, GRASS);
        }
    }
    s.terrain.take_dirty();
    s.tick(0, &[]);
    s.drain_events();
    s
}

/// A player called "p" standing at (x, y, z).
fn p(x: f64, y: f64, z: f64) -> Walker {
    Walker {
        id: "p".to_string(),
        on: 0,
        at: (x, y, z),
    }
}

/// Player `id` standing at (x, y, z).
fn who(id: &str, x: f64, y: f64, z: f64) -> Walker {
    Walker {
        id: id.to_string(),
        on: 0,
        at: (x, y, z),
    }
}

/// Furniture `kind` put straight into frame `on` at `p`, turned `rot`.
fn build(s: &mut Sim, kind: &str, on: u32, p: Pos, rot: u8) -> u32 {
    let id = s.new_id();
    let mut f = Furniture::new(id, furniture::kind(kind).unwrap(), p, rot);
    f.on = on;
    s.put_furniture(f);
    id
}

/// A blueprint laid out before they were retired, with `have` put in.
fn old_site(s: &mut Sim, kind: &str, p: Pos, have: &[(&str, u16)]) -> u32 {
    let id = s.new_id();
    let site = Site {
        id,
        kind: kind.into(),
        on: 0,
        origin: p,
        rot: 0,
        have: have.iter().map(|(i, n)| (i.to_string(), *n)).collect(),
    };
    for c in site.cells() {
        s.set_block(0, c, SCAFFOLD);
    }
    s.sites.insert(id, site);
    id
}

fn bag_with(stuff: &[(&str, u16)]) -> Bag {
    let mut b = items::empty(items::BAG_SLOTS);
    for (i, n) in stuff {
        items::add(&mut b, i, *n);
    }
    b
}

#[test]
fn ground_and_walls() {
    let mut s = flat();
    assert_eq!(s.terrain.ground(4.0, 4.0, 0.0), Some(0.0));
    assert!(s.terrain.walkable(4.0, 4.0, 0.0));
    // open air is never walkable
    assert!(!s.terrain.walkable(-4.0, 4.0, 0.0));
    s.terrain.set(5, 4, 0, STONE);
    assert_eq!(s.terrain.ground(5.0, 4.0, 0.0), Some(1.0)); // a step
    s.terrain.set(5, 4, 1, STONE);
    assert!(!s.terrain.walkable(5.0, 4.0, 0.0)); // a wall
}

#[test]
fn crops_grow_on_world_ticks() {
    let mut s = flat();
    assert_eq!(s.plant((3, 3, 0)), Ok(()));
    assert_eq!(s.plant((3, 3, 0)), Err("occupied"));
    // the grass under it is tilled
    assert_eq!(s.terrain.get(3, 3, -1), Some(DIRT));
    s.drain_events();
    s.tick(500, &[]);
    assert!(s.drain_events().is_empty());
    s.tick(1000, &[]);
    assert_eq!(s.drain_events(), vec![Event::Crop((3, 3, 0), Some(1))]);
    // a long stall jumps straight to the right stage, and ripeness caps
    s.tick(99_000, &[]);
    assert_eq!(s.drain_events(), vec![Event::Crop((3, 3, 0), Some(RIPE))]);
    let mut bag = bag_with(&[]);
    assert_eq!(s.harvest((3, 3, 0), &mut bag), Ok(()));
    assert_eq!(count(&bag, "carrot"), 1);
    assert_eq!(s.harvest((3, 3, 0), &mut bag), Err("nothing_growing"));
    // planted long ago (an old save): already ripe
    s.plant_aged((4, 4, 0), 99_000);
    assert_eq!(s.crops[&(4, 4, 0)].stage, RIPE);
    assert_eq!(s.plant((6, 6, 1)), Err("needs_soil"));
}

#[test]
fn asleep_nothing_ticks_and_waking_catches_up() {
    let mut s = flat();
    s.plant((3, 3, 0)).unwrap();
    s.tick(1000, &[]);
    s.drain_events();
    let t = s.world_tick;
    s.sleep(1000);
    assert!(s.asleep());
    // ambient runs, but the world clock stands still
    s.ambient(5000);
    assert_eq!(s.world_tick, t);
    assert_eq!(s.crops[&(3, 3, 0)].stage, 1);
    // back 3.5 world seconds later: 35 ticks, three stages
    assert_eq!(s.wake(4500), 35);
    assert_eq!(s.world_tick, t + 35);
    assert_eq!(s.drain_events(), vec![Event::Crop((3, 3, 0), Some(3))]);
    assert_eq!(s.wake(9000), 0, "already awake");
}

#[test]
fn saved_and_restored_it_wakes_to_the_time_since() {
    let mut s = Sim::new(0, 0, 7, 1000);
    s.tick(10_000, &[]);
    s.plant((2, 2, 0)).unwrap();
    let mut bag = starter_bag();
    build(&mut s, "chest", 0, (3, 3, 0), 0);
    s.place(0, (5, 5, 0), "pot", 0, &mut bag).unwrap();
    let saved = serde_json::to_string(&s.save(10_000)).unwrap();

    let mut t = Sim::new(0, 0, 7, 1000);
    for key in s.terrain.take_dirty() {
        t.terrain.load_chunk(key, s.terrain.chunk(key).unwrap());
    }
    t.restore(serde_json::from_str(&saved).unwrap());
    assert!(t.asleep());
    assert_eq!(t.crops[&(2, 2, 0)].stage, 0);
    assert_eq!(t.terrain.get(5, 5, 0), Some(POT));
    let chest = t.furniture_at(0, (3, 3, 0)).expect("the chest came back");
    assert_eq!(t.furniture[&chest].kind, "chest");
    assert_eq!(t.terrain.get(3, 3, 0), Some(FURNITURE));
    // down for two world seconds: two stages
    t.wake(12_000);
    assert_eq!(t.crops[&(2, 2, 0)].stage, 2);
}

#[test]
fn an_older_save_keeps_what_still_reads() {
    // a ship saved before ships were blocks, and a chest's cell left over
    // from furniture that's gone
    let saved = r#"{"world_tick":50,"at_ms":1000,"crops":[[[2,2,0],10]],
        "furniture":[],"sites":[],"next_id":9,
        "ships":[{"id":3,"x":21.0,"y":0.0,"z":0.0,"heading":0.0,"v":[0,0,0],
                  "want":[0,0,0],"riders":[],"dock":[21.0,0.0,0.0]}]}"#;
    let mut s = Sim::new(0, 0, 7, 1000);
    s.terrain.set(4, 4, 0, FURNITURE);
    s.restore(serde_json::from_str(saved).unwrap());
    assert!(s.crops.contains_key(&(2, 2, 0)));
    assert_eq!(s.terrain.get(4, 4, 0), Some(AIR), "freed");
    assert_eq!(s.ships.len(), 1, "a new ship in place of the old");
    assert!(s.ships[0].id >= 9);
}

#[test]
fn a_player_shoves_a_cow() {
    let mut s = flat();
    let id = s.spawn_cow(8.0, 8.0);
    s.cows[0].idle_until_ms = i64::MAX; // stand still
    s.tick(0, &[]);
    let out = s.tick(100, &[p(7.8, 8.0, 0.0)]);
    assert!(s.cows[0].x > 8.5, "pushed along +x: {}", s.cows[0].x);
    assert!(
        s.cows[0].x <= 8.0 + PUSH_SPEED * 0.1 + 1e-9,
        "too fast: {}",
        s.cows[0].x
    );
    assert!((s.cows[0].y - 8.0).abs() < 0.001);
    assert_eq!(out.moos, vec![id]);
    // no second moo straight away
    let out = s.tick(200, &[p(s.cows[0].x - 0.3, 8.0, 0.0)]);
    assert!(out.moos.is_empty());
}

#[test]
fn cows_wander_but_stay_on_ground() {
    let mut s = flat();
    for _ in 0..3 {
        s.spawn_cow(8.0, 8.0);
    }
    let mut t = 0;
    for _ in 0..3000 {
        t += 100;
        s.tick(t, &[]);
    }
    for c in &s.cows {
        assert!(
            s.terrain.walkable(c.x, c.y, c.z),
            "cow {} off the floor at {},{}",
            c.id,
            c.x,
            c.y
        );
        assert_eq!(c.z, 0.0);
    }
    // and they spread out rather than stacking
    let (a, b) = (&s.cows[0], &s.cows[1]);
    assert!((a.x - b.x).hypot(a.y - b.y) > 0.5);
}

#[test]
fn pushed_into_a_wall_stays_out() {
    let mut s = flat();
    for y in 0..16 {
        s.terrain.set(10, y, 0, STONE);
        s.terrain.set(10, y, 1, STONE);
    }
    s.spawn_cow(9.0, 8.0);
    s.cows[0].idle_until_ms = i64::MAX;
    s.tick(0, &[]);
    for t in 1..20 {
        let x = s.cows[0].x - 0.5;
        s.tick(t * 100, &[p(x, 8.0, 0.0)]);
    }
    assert!(s.cows[0].x < 9.5, "went through the wall: {}", s.cows[0].x);
}

#[test]
fn digging_and_building_spend_and_fill_the_bag() {
    let mut s = flat();
    let mut bag = bag_with(&[("stone", 1)]);
    assert_eq!(s.dig("p", 0, (2, 2, -1), &mut bag), Ok(()));
    assert_eq!(count(&bag, "grass"), 1);
    assert_eq!(s.terrain.get(2, 2, -1), Some(AIR));
    assert_eq!(s.dig("p", 0, (2, 2, -1), &mut bag), Err("nothing_there"));
    assert_eq!(s.dig("p", 0, (2, 2, 40), &mut bag), Err("edge_of_the_world"));
    assert_eq!(s.place(0, (2, 2, -1), "stone", 0, &mut bag), Ok(()));
    assert_eq!(s.place(0, (2, 2, 0), "stone", 0, &mut bag), Err("none_left"));
    assert_eq!(s.place(0, (2, 2, -1), "grass", 0, &mut bag), Err("occupied"));
    assert_eq!(
        s.place(0, (2, 2, 0), "carrot", 0, &mut bag),
        Err("cannot_place")
    );
    // a full bag can't dig
    let mut full = bag_with(&[]);
    for slot in full.iter_mut() {
        *slot = Some(items::Stack {
            item: "wood".into(),
            n: 64,
        });
    }
    assert_eq!(s.dig("p", 0, (3, 3, -1), &mut full), Err("bag_full"));
    assert_eq!(s.terrain.get(3, 3, -1), Some(GRASS));
}

#[test]
fn taking_old_scaffolding_down_gives_it_all_back() {
    let mut s = flat();
    let mut bag = bag_with(&[]);
    old_site(&mut s, "chest", (4, 4, 0), &[("wood", 3)]);
    assert_eq!(s.terrain.get(4, 4, 0), Some(SCAFFOLD));
    assert_eq!(s.dig("p", 0, (4, 4, 0), &mut bag), Ok(()));
    assert_eq!(count(&bag, "wood"), 3);
    assert_eq!(s.terrain.get(4, 4, 0), Some(AIR));
    assert!(s.sites.is_empty());
}

#[test]
fn chests_hold_things_and_breaking_returns_them() {
    let mut s = flat();
    let mut bag = bag_with(&[("stone", 20), ("carrot", 7)]);
    let chest = build(&mut s, "chest", 0, (4, 4, 0), 0);
    let at = (4.0, 3.0, 0.0);
    let stone = bag
        .iter()
        .position(|x| x.as_ref().is_some_and(|x| x.item == "stone"))
        .unwrap();
    assert_eq!(s.stash(at, chest, &mut bag, stone), Ok(()));
    assert_eq!(count(&bag, "stone"), 0);
    assert_eq!(s.stash(at, chest, &mut bag, stone), Err("no_room"));
    assert_eq!(
        s.stash((15.0, 15.0, 0.0), chest, &mut bag, 1),
        Err("out_of_reach")
    );
    assert_eq!(count(&s.furniture[&chest].slots, "stone"), 20);
    assert_eq!(s.take(at, chest, 0, &mut bag), Ok(()));
    assert_eq!(count(&bag, "stone"), 20);
    let stone = bag
        .iter()
        .position(|x| x.as_ref().is_some_and(|x| x.item == "stone"))
        .unwrap();
    s.stash(at, chest, &mut bag, stone).unwrap();
    s.drain_events();

    // broken: three quarters of its four planks' wood back, every stone back
    assert_eq!(s.dig("p", 0, (4, 4, 0), &mut bag), Ok(()));
    assert_eq!(count(&bag, "wood"), 3);
    assert_eq!(count(&bag, "stone"), 20);
    assert_eq!(count(&bag, "carrot"), 7);
    assert!(s.furniture.is_empty());
    assert_eq!(s.terrain.get(4, 4, 0), Some(AIR));
    assert!(s.drain_events().contains(&Event::FurnitureGone(chest)));
}

#[test]
fn what_does_not_fit_the_bag_is_left_in_a_sack() {
    let mut s = flat();
    let wardrobe = build(&mut s, "wardrobe", 0, (4, 4, 0), 0);
    // fill it with 20 slots of dirt, and the bag with carrots but one slot
    {
        let f = s.furniture.get_mut(&wardrobe).unwrap();
        items::add(&mut f.slots, "dirt", 20 * 64);
    }
    let mut bag = bag_with(&[("carrot", 15 * 64)]);
    s.dig("p", 0, (4, 4, 1), &mut bag).unwrap();
    // the one free slot took wood (seven planks' worth, three quarters of
    // it); the stone and the dirt are in a sack where it stood
    assert_eq!(count(&bag, "wood"), 5);
    let sack = s.furniture_at(0, (4, 4, 0)).expect("a sack");
    assert_eq!(s.furniture[&sack].kind, "sack");
    assert_eq!(count(&s.furniture[&sack].slots, "dirt"), 20 * 64);
    assert_eq!(count(&s.furniture[&sack].slots, "stone"), 1);
    // emptied, it goes
    let mut empty = bag_with(&[]);
    for slot in 0..21 {
        assert_eq!(s.take((4.0, 3.0, 0.0), sack, slot, &mut empty), Ok(()));
        if slot == 15 {
            empty = bag_with(&[]);
        }
    }
    assert!(!s.furniture.contains_key(&sack));
    assert_eq!(s.terrain.get(4, 4, 0), Some(AIR));
}

#[test]
fn only_carryable_blocks_and_one_thing_at_a_time() {
    let mut s = flat();
    let at = (4.0, 4.0, 0.0);
    s.terrain.set(5, 4, 0, STONE);
    s.terrain.set(6, 4, 0, POT);
    s.terrain.set(7, 4, 0, POT);
    assert_eq!(s.pick_block("p", at, 0, (5, 4, 0)), Err("cannot_carry"));
    assert_eq!(s.held("p"), None);
    assert_eq!(s.pick_block("p", at, 0, (6, 4, 0)), Ok(POT));
    assert_eq!(s.terrain.get(6, 4, 0), Some(AIR));
    assert_eq!(s.held("p"), Some(Held::Block(POT)));
    assert_eq!(s.pick_block("p", at, 0, (7, 4, 0)), Err("hands_full"));
    assert_eq!(s.put_down("p", 0, (5, 4, 0), 0), Err("occupied"));
    assert_eq!(s.put_down("p", 0, (5, 5, 0), 0), Ok(Held::Block(POT)));
    assert_eq!(s.terrain.get(5, 5, 0), Some(POT));
    assert_eq!(s.put_down("p", 0, (5, 4, 0), 0), Err("hands_empty"));
}

#[test]
fn a_carried_cow_rides_overhead_then_is_set_down() {
    let mut s = flat();
    let id = s.spawn_cow(8.0, 8.0);
    s.tick(0, &[]);
    assert_eq!(s.pick_cow("p", (1.0, 1.0, 0.0), id), Err("out_of_reach"));
    assert_eq!(s.pick_cow("p", (7.0, 8.0, 0.0), id), Ok(()));
    assert_eq!(s.pick_cow("q", (7.0, 8.0, 0.0), id), Err("already_carried"));
    // it moos about it, follows its holder and nobody shoves it
    let out = s.tick(100, &[p(5.0, 6.0, 0.0), who("q", 5.2, 6.0, 0.0)]);
    assert_eq!(out.moos, vec![id]);
    let c = &s.cows[0];
    assert_eq!((c.x, c.y, c.z), (5.0, 6.0, CARRY_Z));
    // a cow needs somewhere to stand
    s.terrain.set(6, 6, 1, STONE);
    assert_eq!(s.put_down("p", 0, (6, 6, 1), 0), Err("occupied"));
    assert_eq!(s.put_down("p", 0, (6, 6, 0), 0), Err("no_room_for_a_cow"));
    assert_eq!(s.put_down("p", 0, (6, 7, 0), 0), Ok(Held::Cow(id)));
    // and falls back to the ground
    for t in 2..20 {
        s.tick(t * 100, &[]);
    }
    let c = &s.cows[0];
    assert!(!c.carried);
    assert_eq!(c.z, 0.0);
    assert!(s.terrain.walkable(c.x, c.y, c.z));
}

#[test]
fn leaving_lets_go() {
    let mut s = flat();
    let id = s.spawn_cow(8.0, 8.0);
    s.tick(0, &[]);
    assert_eq!(s.pick_cow("p", (7.0, 8.0, 0.0), id), Ok(()));
    s.tick(100, &[p(3.2, 2.9, 0.0)]);
    s.release("p");
    assert_eq!((s.cows[0].x, s.cows[0].y), (3.2, 2.9));
    assert_eq!(s.held("p"), None);
    s.terrain.set(9, 9, 0, POT);
    assert_eq!(s.pick_block("p", (2.0, 2.0, 0.0), 0, (9, 9, 0)), Ok(POT));
    s.release("p");
    assert_eq!(s.terrain.get(2, 2, 0), Some(POT));
}

/// A chest at (4, 4, 0) and a dresser at (8, 4, 0)..(9, 4, 0).
fn furnished() -> (Sim, u32, u32) {
    let mut s = flat();
    let chest = build(&mut s, "chest", 0, (4, 4, 0), 0);
    let dresser = build(&mut s, "dresser", 0, (8, 4, 0), 0);
    s.drain_events();
    (s, chest, dresser)
}

#[test]
fn furniture_is_carried_whole_and_set_down_turned() {
    let (mut s, chest, _) = furnished();
    let mut bag = bag_with(&[]);
    let at = (4.0, 3.0, 0.0);
    assert_eq!(s.grab("p", at, chest, &mut bag), Ok(Grabbed::Lifted));
    assert_eq!(s.terrain.get(4, 4, 0), Some(AIR));
    assert_eq!(s.held("p"), Some(Held::Furniture(chest)));
    assert_eq!(s.grab("q", at, chest, &mut bag), Err("already_carried"));
    s.tick(100, &[p(2.0, 2.0, 0.0)]);
    assert_eq!(s.furniture[&chest].at, (2.0, 2.0, 0.0));
    assert_eq!(s.put_down("p", 0, (2, 3, 0), 3), Ok(Held::Furniture(chest)));
    assert_eq!(s.terrain.get(2, 3, 0), Some(FURNITURE));
    assert_eq!(s.furniture[&chest].rot, 3);
    assert_eq!(s.held("p"), None);
}

#[test]
fn small_empty_furniture_packs_into_the_bag() {
    let mut s = flat();
    let mut bag = bag_with(&[]);
    let stool = build(&mut s, "stool", 0, (4, 4, 0), 0);
    assert_eq!(
        s.grab("p", (4.0, 3.0, 0.0), stool, &mut bag),
        Ok(Grabbed::Pocketed)
    );
    assert_eq!(count(&bag, "stool"), 1);
    assert!(s.furniture.is_empty());
    assert_eq!(s.place(0, (6, 6, 0), "stool", 2, &mut bag), Ok(()));
    assert_eq!(count(&bag, "stool"), 0);
    let id = s.furniture_at(0, (6, 6, 0)).unwrap();
    assert_eq!(s.furniture[&id].rot, 2);
}

#[test]
fn a_sign_stays_itself_placed_pocketed_broken_and_saved() {
    let mut s = flat();
    let mut bag = bag_with(&[("sign:7", 1)]);
    assert_eq!(s.place(0, (4, 4, 0), "sign:7", 1, &mut bag), Ok(()));
    assert_eq!(count(&bag, "sign:7"), 0);
    let id = s.furniture_at(0, (4, 4, 0)).unwrap();
    assert_eq!(s.furniture[&id].note.as_deref(), Some("7"));

    // it survives a save
    let mut t = flat();
    let json = serde_json::to_string(&s.save(0)).unwrap();
    t.restore(serde_json::from_str(&json).unwrap());
    assert_eq!(t.furniture[&id].note.as_deref(), Some("7"));

    assert_eq!(s.grab("p", (4.0, 3.0, 0.0), id, &mut bag), Ok(Grabbed::Pocketed));
    assert_eq!(count(&bag, "sign:7"), 1);
    assert_eq!(count(&bag, "sign"), 0);

    // broken, it comes back whole (it isn't made of anything)
    s.place(0, (4, 4, 0), "sign:7", 0, &mut bag).unwrap();
    s.dig("p", 0, (4, 4, 0), &mut bag).unwrap();
    assert_eq!(count(&bag, "sign:7"), 1);
    assert!(s.furniture.is_empty());
}

#[test]
fn heavy_furniture_needs_two() {
    let (mut s, _, dresser) = furnished();
    let mut bag = bag_with(&[]);
    assert_eq!(
        s.grab("p", (8.0, 3.0, 0.0), dresser, &mut bag),
        Ok(Grabbed::Gripped)
    );
    // still in the world, waiting for help
    assert_eq!(s.terrain.get(8, 4, 0), Some(FURNITURE));
    assert!(!s.furniture[&dresser].lifted);
    assert_eq!(
        s.grab("q", (9.0, 3.0, 0.0), dresser, &mut bag),
        Ok(Grabbed::Lifted)
    );
    assert_eq!(s.terrain.get(8, 4, 0), Some(AIR));
    assert_eq!(s.terrain.get(9, 4, 0), Some(AIR));
    // it rides between them
    s.tick(100, &[p(4.0, 2.0, 0.0), who("q", 6.0, 2.0, 0.0)]);
    assert_eq!(s.furniture[&dresser].at, (5.0, 2.0, 0.0));
    // either can set it down, and both let go
    assert_eq!(s.put_down("q", 0, (5, 6, 0), 0), Ok(Held::Furniture(dresser)));
    assert_eq!(s.held("p"), None);
    assert_eq!(s.held("q"), None);
    assert_eq!(s.terrain.get(6, 6, 0), Some(FURNITURE));
}

#[test]
fn a_lone_grip_lets_go_when_walking_off() {
    let (mut s, _, dresser) = furnished();
    let mut bag = bag_with(&[]);
    s.grab("p", (8.0, 3.0, 0.0), dresser, &mut bag).unwrap();
    s.tick(100, &[p(8.0, 3.0, 0.0)]);
    assert_eq!(s.held("p"), Some(Held::Furniture(dresser)));
    s.tick(200, &[p(2.0, 3.0, 0.0)]);
    assert_eq!(
        s.held("p"),
        Some(Held::Furniture(dresser)),
        "still in reach"
    );
    s.tick(300, &[p(0.0, 14.0, 0.0)]);
    assert_eq!(s.held("p"), None);
    assert!(s.furniture[&dresser].grips.is_empty());
}

#[test]
fn carriers_pulling_apart_drop_it_nearby() {
    let (mut s, _, dresser) = furnished();
    let mut bag = bag_with(&[]);
    s.grab("p", (8.0, 3.0, 0.0), dresser, &mut bag).unwrap();
    s.grab("q", (9.0, 3.0, 0.0), dresser, &mut bag).unwrap();
    s.tick(100, &[p(3.0, 10.0, 0.0), who("q", 12.0, 10.0, 0.0)]);
    let f = &s.furniture[&dresser];
    assert!(!f.lifted && f.grips.is_empty());
    assert_eq!(s.held("p"), None);
    let (x, y, _) = f.center();
    assert!((x - 7.5).hypot(y - 10.0) < 7.0, "dropped near: {x},{y}");
}

#[test]
fn a_helper_takes_the_other_end() {
    let mut s = Sim::new(0, 0, 7, 1000);
    s.tick(0, &[]);
    let mut bag = starter_bag();
    let dresser = build(&mut s, "dresser", 0, (3, -3, 0), 0);
    let helper = s.helpers[0].id;
    let me = |x: f64| who("p", x, -4.0, 0.0);
    assert_eq!(s.call_helper("p", helper), Err("nothing_to_help_with"));
    assert_eq!(
        s.grab("p", (3.0, -4.0, 0.0), dresser, &mut bag),
        Ok(Grabbed::Gripped)
    );
    assert_eq!(s.call_helper("p", 999), Err("no_such_helper"));
    assert_eq!(s.call_helper("p", helper), Ok(()));
    let mut t = 0;
    while !s.furniture[&dresser].lifted && t < 10_000 {
        t += 100;
        s.tick(t, &[me(3.0)]);
    }
    assert!(
        s.furniture[&dresser].lifted,
        "the helper came and lifted it"
    );
    assert_eq!(s.helpers[0].task, Task::Carry(dresser));
    // walk it west together; the helper keeps up
    for n in 1..=20 {
        t += 100;
        s.tick(t, &[me(3.0 - n as f64 * 0.3)]);
    }
    let f = &s.furniture[&dresser];
    assert!(f.lifted, "still carried");
    assert!(f.at.0 < 1.0, "moved west: {:?}", f.at);
    assert_eq!(
        s.put_down("p", 0, (-4, -4, 0), 0),
        Ok(Held::Furniture(dresser))
    );
    assert_eq!(s.helpers[0].task, Task::Home);
    for _ in 0..100 {
        t += 100;
        s.tick(t, &[me(-3.0)]);
    }
    assert_eq!(s.helpers[0].task, Task::Idle);
}

/// "p" standing on ship `ship` at `at` in its frame.
fn aboard(ship: u32, at: (f64, f64, f64)) -> Walker {
    Walker {
        id: "p".to_string(),
        on: ship,
        at,
    }
}

/// Where you stand to steer the standard ship: just astern of its helm.
const AT_HELM: (f64, f64, f64) = (-4.0, 0.0, 0.0);

#[test]
fn riders_stand_on_deck_and_whoever_is_at_the_helm_steers() {
    let mut s = Sim::new(0, 0, 7, 1000);
    s.tick(0, &[]);
    let ship = s.ships[0].clone();
    // docked by the plaza, deck level with its floor
    assert_eq!(ship.pose.z, 0.0);
    let helm = ship.pose.to_world(AT_HELM);
    assert_eq!(s.take_helm("p", (0.0, 0.0, 0.0)), Err("no_helm_here"));
    assert_eq!(s.take_helm("p", helm), Ok(ship.id));
    assert_eq!(s.take_helm("q", helm), Err("someone_else_steers"));
    assert_eq!(s.steer("q", Helm::new(1.0, 0.0, 0.0)), Err("not_piloting"));
    s.steer("p", Helm::new(0.0, 0.0, 1.0)).unwrap();
    let mut t = 0;
    for _ in 0..30 {
        t += 100;
        s.tick(t, &[aboard(ship.id, AT_HELM)]);
    }
    let up = &s.ships[0];
    assert!(up.pose.z > 3.0, "climbed to {}", up.pose.z);
    assert_eq!(up.riders, vec![("p".to_string(), AT_HELM)]);
    // walking off to the bow leaves the helm, and the ship stops
    t += 100;
    s.tick(t, &[aboard(ship.id, (3.0, 0.0, 0.0))]);
    assert_eq!(s.ships[0].pilot, None);
    for _ in 0..30 {
        t += 100;
        s.tick(t, &[aboard(ship.id, (3.0, 0.0, 0.0))]);
    }
    let z = s.ships[0].pose.z;
    t += 1000;
    s.tick(t, &[aboard(ship.id, (3.0, 0.0, 0.0))]);
    assert!((s.ships[0].pose.z - z).abs() < 0.05);
}

#[test]
fn ships_dock_flush_with_the_shore() {
    for (gx, gy) in [(0, 0), (1, 0), (2, -5)] {
        let s = Sim::new(gx, gy, 7, 1000);
        let ship = &s.ships[0];
        let p = ship.pose;
        assert_eq!((p.x.fract(), p.y.fract()), (0.0, 0.0), "on whole cells");
        // somewhere along its port side the shore is the very next cell
        let flush = (-4..=4).any(|x| {
            let (wx, wy, wz) = p.to_world((x as f64, 3.0, -0.5));
            s.terrain.get(cell(wx), cell(wy), wz.floor() as i32)
                .is_some_and(|b| b != AIR && b != WATER)
        });
        assert!(flush, "{gx},{gy}: docked at {p:?}");
    }
}

#[test]
fn a_pilot_who_vanishes_leaves_the_helm() {
    let mut s = Sim::new(0, 0, 7, 1000);
    s.tick(0, &[]);
    let ship = s.ships[0].clone();
    s.take_helm("p", ship.pose.to_world(AT_HELM)).unwrap();
    s.tick(1000, &[]);
    s.tick(5000, &[]);
    assert!(s.ships[0].pilot.is_some(), "still on their way, perhaps");
    s.tick(12_000, &[]);
    assert_eq!(s.ships[0].pilot, None);
}

/// A ship of `blocks` alone in an empty sky, its deck at z 10.
fn adrift(blocks: &[(Pos, u8)]) -> (Sim, u32) {
    let mut s = Sim::empty(1000, 1);
    let ship = Ship::new(5, blocks.iter().copied().collect(), Pose::new(0.0, 0.0, 10.0, 0.0));
    s.ships.push(ship);
    s.next_id = 6;
    s.tick(0, &[]);
    (s, 5)
}

#[test]
fn blocks_and_furniture_go_aboard() {
    let (mut s, id) = adrift(&[((0, 0, -1), terrain::DECK), ((1, 0, -1), terrain::DECK)]);
    let mut bag = bag_with(&[("deck", 4), ("drawer", 1), ("stone", 1)]);
    s.place(id, (2, 0, -1), "deck", 0, &mut bag).unwrap();
    assert_eq!(s.get(id, (2, 0, -1)), Some(terrain::DECK));
    assert_eq!(
        s.drain_events().last(),
        Some(&Event::ShipBlock(id, (2, 0, -1), terrain::DECK))
    );
    // too far out for a ship to hold
    assert_eq!(
        s.place(id, (40, 0, -1), "deck", 0, &mut bag),
        Err("edge_of_the_world")
    );
    // a drawer on deck
    s.place(id, (1, 0, 0), "drawer", 0, &mut bag).unwrap();
    let f = s.furniture_at(id, (1, 0, 0)).expect("aboard");
    assert_eq!(s.furniture[&f].on, id);
    assert_eq!(s.get(id, (1, 0, 0)), Some(FURNITURE));
    // and it's in reach from where it is in the world, not in the ship's frame
    let mut bag2 = bag_with(&[]);
    assert_eq!(
        s.grab("p", (1.0, 0.0, 10.0), f, &mut bag2),
        Ok(Grabbed::Pocketed)
    );
    // nor can a block go where the world's blocks are
    s.terrain.set(0, 2, 9, STONE);
    assert_eq!(s.place(id, (0, 2, -1), "stone", 0, &mut bag), Err("occupied"));
    // digging gives the block back; the ship keeps its last
    s.dig("p", id, (2, 0, -1), &mut bag).unwrap();
    s.dig("p", id, (1, 0, -1), &mut bag).unwrap();
    assert_eq!(s.dig("p", id, (0, 0, -1), &mut bag), Err("last_block"));
    assert_eq!(count(&bag, "deck"), 5);
}

#[test]
fn furniture_carried_aboard_moves_with_the_ship() {
    let mut s = Sim::new(0, 0, 7, 1000);
    s.tick(0, &[]);
    let id = s.ships[0].id;
    let mut bag = bag_with(&[]);
    let shore = s.ships[0].pose.to_world((0.0, 4.0, 0.0));
    let (sx, sy) = (cell(shore.0), cell(shore.1));
    build(&mut s, "chest", 0, (sx, sy, 0), 0);
    let chest = s.furniture_at(0, (sx, sy, 0)).unwrap();
    assert_eq!(
        s.grab("p", shore, chest, &mut bag),
        Ok(Grabbed::Lifted)
    );
    // onto the deck amidships, then fly off with it
    s.put_down("p", id, (0, 0, 0), 1).unwrap();
    assert_eq!(s.furniture[&chest].on, id);
    assert_eq!(s.furniture_at(id, (0, 0, 0)), Some(chest));
    let before = s.furniture_middle(&s.furniture[&chest]);
    s.take_helm("p", s.ships[0].pose.to_world(AT_HELM)).unwrap();
    s.steer("p", Helm::new(0.0, 0.0, 1.0)).unwrap();
    let mut t = 0;
    for _ in 0..20 {
        t += 100;
        s.tick(t, &[aboard(id, AT_HELM)]);
    }
    let after = s.furniture_middle(&s.furniture[&chest]);
    assert!(after.2 > before.2 + 2.0, "rose with it: {before:?} -> {after:?}");
    assert_eq!((after.0, after.1), (before.0, before.1));
}

#[test]
fn a_ship_crosses_into_the_next_universe_with_all_aboard() {
    let mut a = Sim::new(0, 0, 7, 1000);
    let mut b = Sim::new(1, 0, 7, 1000);
    a.tick(0, &[]);
    b.tick(0, &[]);
    let ship = a.ships[0].id;
    let mut bag = bag_with(&[("drawer", 1), ("stone", 3)]);
    a.place(ship, (2, 0, 0), "drawer", 0, &mut bag).unwrap();
    let drawer = a.furniture_at(ship, (2, 0, 0)).unwrap();
    a.stash((0.0, 0.0, 0.0), drawer, &mut bag, 0).ok();
    a.furniture.get_mut(&drawer).unwrap().slots[0] = Some(items::Stack {
        item: "stone".into(),
        n: 3,
    });
    a.take_helm("p", a.ships[0].pose.to_world(AT_HELM)).unwrap();
    // up above the islands, then east
    a.steer("p", Helm::new(0.0, 0.0, 1.0)).unwrap();
    let mut t = 0;
    for _ in 0..50 {
        t += 100;
        a.tick(t, &[aboard(ship, AT_HELM)]);
    }
    // face east and go
    while ships::wrap(a.ships[0].pose.h).abs() > 0.05 {
        let turn = -ships::wrap(a.ships[0].pose.h).signum();
        a.steer("p", Helm::new(0.0, turn * 0.3, 0.0)).unwrap();
        t += 100;
        a.tick(t, &[aboard(ship, AT_HELM)]);
    }
    a.steer("p", Helm::new(1.0, 0.0, 0.0)).unwrap();
    // no neighbour: it stops at the edge
    for _ in 0..300 {
        t += 100;
        a.tick(t, &[aboard(ship, AT_HELM)]);
    }
    assert_eq!(a.ships[0].pose.x, terrain::HALF as f64 - 0.5);
    a.drain_events();
    a.set_open([true, false, false, false]);
    t += 100;
    a.tick(t, &[aboard(ship, AT_HELM)]);
    let ev = a.drain_events();
    assert!(ev.contains(&Event::FurnitureGone(drawer)));
    let Some(Event::Departed(cargo, Side::East)) =
        ev.into_iter().find(|e| matches!(e, Event::Departed(..)))
    else {
        panic!("it left");
    };
    assert!(a.ships.is_empty());
    assert!(a.furniture.is_empty());
    assert_eq!(cargo.riders, vec![("p".to_string(), AT_HELM)]);
    assert_eq!(cargo.furniture.len(), 1);
    // through JSON, as it goes from one universe's process to the next
    let json = serde_json::to_string(&*cargo).unwrap();
    let id = b.arrive(serde_json::from_str(&json).unwrap(), Side::West);
    let s = b.ship(id).unwrap().clone();
    assert!(s.pose.x < -terrain::HALF as f64 + 1.0);
    assert_eq!(s.pilot.as_deref(), Some("p"));
    // the drawer, its stones still in it
    let f = b.furniture.values().find(|f| f.on == id).expect("aboard");
    assert_eq!(f.slots[0].as_ref().map(|s| s.n), Some(3));
    assert_eq!(b.furniture_at(id, (2, 0, 0)), Some(f.id));
    // the pilot arrives at the helm, and steers on from there
    let (at, on) = b.spawn("p", None);
    assert_eq!(on, Some((id, AT_HELM)));
    assert_eq!(at, s.pose.to_world(AT_HELM));
    assert_eq!(b.steer("p", Helm::new(1.0, 0.0, 0.0)), Ok(()));
    b.tick(t + 100, &[aboard(id, AT_HELM)]);
    assert_eq!(b.ship(id).unwrap().pilot.as_deref(), Some("p"));
    // it berths by b's home island from now on, apart from b's own ship
    let home = &b.islands[0];
    let d = s.dock;
    assert!((d.x - home.x as f64).hypot(d.y - home.y as f64) < home.r * 1.4 + 8.0);
    let own = b.ships.iter().find(|o| o.id != id).unwrap();
    let mut berth = own.clone();
    berth.pose = own.dock;
    let mine = Ship::new(0, s.blocks.clone(), d);
    assert!(!mine.collides(&d, &b.terrain, &[&berth]));

    // a universe a ship left builds another while it sleeps
    a.sleep(t);
    a.ambient(t + 2000);
    assert_eq!(a.ships.len(), 1);
    assert!(!a.ships[0].collides(&a.ships[0].pose, &a.terrain, &[]));
}

#[test]
fn sleeping_sends_ships_home_and_drops_what_helpers_hold() {
    let mut s = Sim::new(0, 0, 7, 1000);
    s.tick(0, &[]);
    let dock = s.ships[0].dock;
    s.ships[0].pose.x += 3.0;
    s.ships[0].pose.z += 4.0;
    s.sleep(100);
    s.ambient(2100);
    assert_eq!(s.ships[0].pose, dock);
}

#[test]
fn the_new_universe_has_room_to_stand_and_a_ship() {
    for (gx, gy) in [(0, 0), (1, 0), (2, -5)] {
        let mut s = Sim::new(gx, gy, 3, 1000);
        let ((x, y, z), aboard) = s.spawn("p", None);
        assert_eq!(aboard, None);
        assert!(s.terrain.walkable(x, y, z), "{gx},{gy}");
        assert_eq!(s.ships.len(), 1, "{gx},{gy}: a ship docked");
        assert!(!s.helpers.is_empty());
        let h = &s.helpers[0];
        assert!(s.terrain.walkable(h.x, h.y, h.z), "helper stands");
        // a spot in the air isn't somewhere to stand
        let ((_, _, z2), _) = s.spawn("p", Some((40.0, 40.0, 30.0)));
        assert!(z2 < 20.0);
        let _ = (WOOD, STONE);
    }
}

/// Through a hyperdoor at (4, 4, 0) facing -y: the room it leads to.
fn through(s: &mut Sim, user: &str, name: &str, door: u32) -> Door {
    s.use_door(user, name, (4.0, 3.0, 0.0), door).unwrap()
}

#[test]
fn a_hyperdoor_leads_to_a_room_that_outlives_it() {
    let mut s = flat();
    let mut bag = bag_with(&[("hyperdoor", 3)]);
    s.place(0, (4, 4, 0), "hyperdoor", 0, &mut bag).unwrap();
    let door = s.furniture_at(0, (4, 4, 1)).unwrap();
    let inside = through(&mut s, "p", "ann", door);
    let room = inside.on;
    let pocket = s.pocket(room).unwrap();
    assert_eq!((pocket.owner.as_str(), pocket.door), ("ann", Some(door)));
    assert_eq!(s.furniture[&door].pocket(), Some(room));
    // the same door, the same room, whoever goes through
    assert_eq!(through(&mut s, "q", "bob", door).on, room);

    // its walls hold, its way out stays, and nothing's built past them
    assert_eq!(s.dig("p", room, (5, 0, 1), &mut bag), Err("the_walls_hold"));
    assert_eq!(s.dig("p", room, (0, 0, -1), &mut bag), Err("the_walls_hold"));
    let exit = s.furniture_at(room, (0, -4, 0)).unwrap();
    assert_eq!(s.dig("p", room, (0, -4, 0), &mut bag), Err("the_walls_hold"));
    assert_eq!(s.grab("p", inside.at, exit, &mut bag), Err("the_walls_hold"));
    let mut stone = bag_with(&[("stone", 2)]);
    assert_eq!(s.place(room, (8, 0, 0), "stone", 0, &mut stone), Err("edge_of_the_world"));
    assert_eq!(s.place(room, (1, 1, 0), "stone", 0, &mut stone), Ok(()));

    // out the way it came, in front of the door
    s.tick(100, &[aboard(room, inside.at)]);
    let at = s.world_of(room, inside.at).unwrap();
    let out = s.use_door("p", "ann", at, exit).unwrap();
    assert_eq!((out.on, out.at), (0, (4.0, 3.0, 0.0)));

    // broken, the room shuts with its things in it, and whoever's inside
    // is put out where the door was
    s.tick(200, &[aboard(room, inside.at)]);
    s.drain_events();
    s.dig("p", 0, (4, 4, 0), &mut bag).unwrap();
    assert!(s.drain_events().iter().any(|e| matches!(e,
        Event::Evicted(r, d) if *r == room && d.on == 0 && d.at == (4.0, 3.0, 0.0))));
    assert_eq!(s.pocket(room).unwrap().door, None);
    assert_eq!(s.get(room, (1, 1, 0)), Some(STONE));

    // someone else's new door makes them a room of their own...
    s.place(0, (4, 4, 0), "hyperdoor", 0, &mut bag).unwrap();
    let second = s.furniture_at(0, (4, 4, 0)).unwrap();
    let theirs = through(&mut s, "q", "bob", second).on;
    assert_ne!(theirs, room);
    // ...and the owner's next door leads back to theirs
    s.place(0, (6, 4, 0), "hyperdoor", 0, &mut bag).unwrap();
    let third = s.furniture_at(0, (6, 4, 0)).unwrap();
    let back = s.use_door("p", "ann", (6.0, 3.0, 0.0), third).unwrap();
    assert_eq!(back.on, room);

    // rooms are kept, and they never count as the universe's ship
    let mut t = flat();
    let json = serde_json::to_string(&s.save(0)).unwrap();
    t.restore(serde_json::from_str(&json).unwrap());
    assert_eq!(t.pocket(room).unwrap().door, Some(third));
    assert_eq!(t.get(room, (1, 1, 0)), Some(STONE));
    // (this flat universe has nowhere to dock one)
    assert!(!t.has_ship());
}

#[test]
fn no_room_inside_a_room_and_doors_stay_doors() {
    let mut s = flat();
    let mut bag = bag_with(&[("hyperdoor", 2), ("door", 1)]);
    s.place(0, (4, 4, 0), "hyperdoor", 0, &mut bag).unwrap();
    let door = s.furniture_at(0, (4, 4, 0)).unwrap();
    let inside = through(&mut s, "p", "ann", door);
    s.place(inside.on, (2, 2, 0), "hyperdoor", 0, &mut bag).unwrap();
    let nested = s.furniture_at(inside.on, (2, 2, 0)).unwrap();
    let at = s.world_of(inside.on, (2.0, 1.0, 0.0)).unwrap();
    assert_eq!(s.use_door("p", "ann", at, nested), Err("no_room_in_a_room"));
    s.place(0, (8, 4, 0), "door", 0, &mut bag).unwrap();
    let plain = s.furniture_at(0, (8, 4, 0)).unwrap();
    assert_eq!(s.use_door("p", "ann", (8.0, 3.0, 0.0), plain), Err("not_a_door"));
    // picked up, a hyperdoor comes back as a plain one and its room shuts
    assert_eq!(s.grab("p", (4.0, 3.0, 0.0), door, &mut bag), Ok(Grabbed::Pocketed));
    assert_eq!(count(&bag, "hyperdoor"), 1);
    assert_eq!(s.pocket(inside.on).unwrap().door, None);
}

#[test]
fn a_cow_carried_into_a_room_wanders_it() {
    let mut s = flat();
    let cow = s.spawn_cow(4.0, 2.0);
    let mut bag = bag_with(&[("hyperdoor", 1)]);
    s.place(0, (4, 4, 0), "hyperdoor", 0, &mut bag).unwrap();
    let door = s.furniture_at(0, (4, 4, 0)).unwrap();
    s.pick_cow("p", (4.0, 3.0, 0.0), cow).unwrap();
    let inside = through(&mut s, "p", "ann", door);
    let room = inside.on;
    s.tick(100, &[aboard(room, inside.at)]);
    let w = s.world_of(room, inside.at).unwrap();
    let c = s.cows.iter().find(|c| c.id == cow).unwrap();
    assert_eq!((c.x, c.y, c.z), (w.0, w.1, w.2 + CARRY_Z));
    assert_eq!(s.put_down("p", room, (2, 2, 0), 0), Ok(Held::Cow(cow)));
    let pose = s.ship(room).unwrap().pose;
    for t in 0..300 {
        s.tick(200 + t * 100, &[]);
        let c = s.cows.iter().find(|c| c.id == cow).unwrap();
        assert_eq!(c.pen, Some(room));
        let l = pose.to_local((c.x, c.y, c.z));
        assert!(ships::inside(l), "the cow left the room: {l:?}");
        assert!((l.2 - 0.0).abs() < 1e-6, "the cow isn't on the floor: {l:?}");
    }
}

#[test]
fn a_helper_carrying_with_you_comes_through_and_goes_home_after() {
    let mut s = flat();
    let (hid, home) = (s.new_id(), (8.0, 8.0, 0.0));
    s.helpers.push(Helper {
        id: hid,
        name: "Hob",
        x: home.0,
        y: home.1,
        z: home.2,
        vz: 0.0,
        heading: 0.0,
        home,
        task: Task::Idle,
        task_ms: 0,
        sent: None,
        pen: None,
    });
    let mut bag = bag_with(&[("hyperdoor", 1), ("wood", 12)]);
    s.place(0, (4, 4, 0), "hyperdoor", 0, &mut bag).unwrap();
    let door = s.furniture_at(0, (4, 4, 0)).unwrap();
    let id = s.new_id();
    let mut bed = Furniture::new(id, furniture::kind("bed").unwrap(), (4, 1, 0), 1);
    bed.on = 0;
    s.put_furniture(bed);
    s.grab("p", (4.0, 2.0, 0.0), id, &mut bag).unwrap();
    s.call_helper("p", hid).unwrap();
    let mut t = 0;
    while !s.furniture[&id].lifted {
        t += 100;
        s.tick(t, &[p(4.0, 2.0, 0.0)]);
        assert!(t < 20_000, "the helper never lifted it");
    }
    // anyone else on the other end would have to come too
    let inside = through(&mut s, "p", "ann", door);
    let h = s.helpers.iter().find(|h| h.id == hid).unwrap();
    assert_eq!(h.pen, Some(inside.on));
    s.tick(t + 100, &[aboard(inside.on, inside.at)]);
    assert!(s.furniture[&id].lifted, "dropped on the way through");
    assert_eq!(s.put_down("p", inside.on, (-2, 0, 0), 0), Ok(Held::Furniture(id)));
    assert_eq!(s.furniture[&id].on, inside.on);
    // done, it heads straight home: no walking out of a pocket room
    s.tick(t + 200, &[aboard(inside.on, inside.at)]);
    let h = s.helpers.iter().find(|h| h.id == hid).unwrap();
    assert_eq!((h.pen, (h.x, h.y, h.z)), (None, home));
}

#[test]
fn a_carried_player_wiggles_free() {
    let mut s = flat();
    assert_eq!(s.pick_player("p", (4.0, 4.0, 0.0), "p", (4.0, 4.0, 0.0)), Err("cannot_carry"));
    assert_eq!(s.pick_player("p", (4.0, 4.0, 0.0), "q", (14.0, 4.0, 0.0)), Err("out_of_reach"));
    s.pick_player("p", (4.0, 4.0, 0.0), "q", (5.0, 4.0, 0.0)).unwrap();
    assert_eq!(s.held("p"), Some(Held::Player("q".into())));
    // carried, they can't pick anyone up, nor be picked up again
    assert_eq!(s.pick_player("q", (5.0, 4.0, 0.0), "r", (5.0, 5.0, 0.0)), Err("carried"));
    assert_eq!(s.pick_player("r", (5.0, 5.0, 0.0), "q", (5.0, 4.0, 0.0)), Err("already_carried"));
    s.drain_events();
    let mut t = 100;
    for n in 1..WIGGLES_FREE {
        s.tick(t, &[]);
        assert_eq!(s.wiggle("q"), Ok(false), "free after {n}");
        // twice in one tick counts once
        assert_eq!(s.wiggle("q"), Ok(false));
        t += 100;
    }
    s.tick(t, &[]);
    assert_eq!(s.wiggle("q"), Ok(true));
    assert_eq!(s.held("p"), None);
    assert_eq!(s.drain_events(), vec![Event::Carry("p".into(), None)]);
    assert_eq!(s.wiggle("q"), Err("not_carried"));

    // slow wiggles never add up
    s.pick_player("p", (4.0, 4.0, 0.0), "q", (5.0, 4.0, 0.0)).unwrap();
    for _ in 0..WIGGLES_FREE * 2 {
        t += 2000;
        s.tick(t, &[]);
        assert_eq!(s.wiggle("q"), Ok(false));
    }
    // whoever's carried leaving frees the carrier's hands
    s.release("q");
    assert_eq!(s.held("p"), None);
}

#[test]
fn a_bag_of_marbles_is_set_down_and_picked_up_whole() {
    let mut s = flat();
    let mut bag = bag_with(&[("marbles:250", 1)]);
    assert_eq!(s.place(0, (4, 4, 0), "marbles:250", 0, &mut bag), Ok(()));
    assert_eq!(count(&bag, "marbles:250"), 0);
    let id = s.furniture_at(0, (4, 4, 0)).unwrap();
    assert_eq!(s.furniture[&id].note.as_deref(), Some("250"));
    assert_eq!(s.grab("p", (4.0, 3.0, 0.0), id, &mut bag), Ok(Grabbed::Pocketed));
    assert_eq!(count(&bag, "marbles:250"), 1);
    s.place(0, (4, 4, 0), "marbles:250", 0, &mut bag).unwrap();
    s.dig("p", 0, (4, 4, 0), &mut bag).unwrap();
    assert_eq!(count(&bag, "marbles:250"), 1, "broken, it's given back whole");
    assert_eq!(s.place(0, (4, 4, 0), "marbles", 0, &mut bag), Err("cannot_place"));
}

#[test]
fn digging_stone_sometimes_turns_up_marbles() {
    let mut s = flat();
    for x in 0..16 {
        for y in 0..16 {
            s.terrain.set(x, y, -2, STONE);
        }
    }
    s.drain_events();
    let mut bag = items::empty(items::BAG_SLOTS);
    let mut found = 0;
    for x in 0..16 {
        for y in 0..16 {
            s.dig("p", 0, (x, y, -1), &mut bag).unwrap();
            s.dig("p", 0, (x, y, -2), &mut bag).unwrap();
            // keep the bag from filling with stone and grass
            for slot in bag.iter_mut() {
                if slot.as_ref().is_some_and(|st| items::marbles_in(&st.item).is_none()) {
                    *slot = None;
                }
            }
        }
        for e in s.drain_events() {
            if let Event::Found(who, n) = e {
                assert_eq!(who, "p");
                assert!((MARBLE_FIND.0..=MARBLE_FIND.1).contains(&n));
                found += n;
            }
        }
    }
    assert!(found > 0, "256 stones and no marbles");
    let have: u32 = bag.iter().flatten().filter_map(|st| items::marbles_in(&st.item)).sum();
    assert_eq!(have, found);
    assert_eq!(bag.iter().flatten().count(), 1, "they top up one bag");
}

#[test]
fn a_dropped_stack_falls_into_a_sack_and_marbles_drop_as_themselves() {
    let mut s = flat();
    let mut bag = bag_with(&[("wood", 30), ("marbles:75", 1)]);
    let wood = bag.iter().position(|x| x.as_ref().is_some_and(|st| st.item == "wood")).unwrap();
    let id = s.drop_stack(0, (4, 4, 5), &mut bag, wood).unwrap();
    assert_eq!(count(&bag, "wood"), 0);
    let f = &s.furniture[&id];
    assert_eq!((f.kind.as_str(), f.origin), ("sack", (4, 4, 0)), "it falls to the ground");
    assert_eq!(items::count(&f.slots, "wood"), 30);
    // the spot's taken: the next one goes beside it
    let m = bag.iter().position(|x| x.as_ref().is_some_and(|st| st.item == "marbles:75")).unwrap();
    let id2 = s.drop_stack(0, (4, 4, 0), &mut bag, m).unwrap();
    let f2 = &s.furniture[&id2];
    assert_eq!((f2.kind.as_str(), f2.note.as_deref()), ("marbles", Some("75")));
    assert_ne!(f2.origin, (4, 4, 0));
    assert_eq!(s.drop_stack(0, (4, 4, 0), &mut bag, m), Err("empty_slot"));
    // taking the sack's insides back leaves nothing behind
    s.take((4.0, 3.0, 0.0), id, 0, &mut bag).unwrap();
    assert_eq!(count(&bag, "wood"), 30);
    assert!(!s.furniture.contains_key(&id));
}

// -- crafting

/// A straight cut square across the saw's plank.
fn clean_cut() -> Vec<(f64, f64)> {
    (0..=10).map(|i| (0.5, i as f64 / 10.0)).collect()
}

/// The `Stations` events among `ev`.
fn station_events(ev: &[Event]) -> Vec<(String, Vec<&'static str>)> {
    ev.iter()
        .filter_map(|e| match e {
            Event::Stations(u, k) => Some((u.clone(), k.clone())),
            _ => None,
        })
        .collect()
}

#[test]
fn stations_in_reach_are_noted_on_tick_and_only_when_they_change() {
    let mut s = flat();
    build(&mut s, "bench", 0, (4, 4, 0), 0);
    build(&mut s, "veneer", 0, (12, 12, 0), 0);
    assert_eq!(s.stations_near(0, (4.0, 3.0, 0.0)), vec!["bench"]);
    assert_eq!(s.stations_near(0, (8.0, 8.0, 0.0)), vec!["veneer", "bench"]);
    assert!(s.stations_near(0, (0.0, 15.0, 0.0)).is_empty());
    // in another frame, it isn't near
    assert!(s.stations_near(7, (4.0, 3.0, 0.0)).is_empty());
    s.drain_events();

    s.tick(100, &[p(4.0, 3.0, 0.0)]);
    let ev = s.drain_events();
    assert_eq!(station_events(&ev), vec![("p".to_string(), vec!["bench"])]);
    assert_eq!(s.access("p"), vec!["bench"]);
    s.tick(200, &[p(4.5, 3.0, 0.0)]);
    assert!(station_events(&s.drain_events()).is_empty(), "nothing changed");
    s.tick(300, &[p(0.0, 15.0, 0.0)]);
    assert_eq!(
        station_events(&s.drain_events()),
        vec![("p".to_string(), vec![])]
    );
    s.tick(400, &[p(0.0, 15.0, 0.0)]);
    assert!(station_events(&s.drain_events()).is_empty());
    // gone from the universe: near nothing
    s.tick(500, &[p(4.0, 3.0, 0.0)]);
    s.drain_events();
    s.tick(600, &[]);
    assert_eq!(
        station_events(&s.drain_events()),
        vec![("p".to_string(), vec![])]
    );
    s.tick(700, &[p(4.0, 3.0, 0.0)]);
    s.drain_events();
    s.release("p");
    assert_eq!(
        station_events(&s.drain_events()),
        vec![("p".to_string(), vec![])]
    );
    assert!(s.access("p").is_empty());
}

#[test]
fn out_of_range_a_station_step_is_refused() {
    let mut s = flat();
    build(&mut s, "bench", 0, (4, 4, 0), 0);
    let mut bag = bag_with(&[("plank", 4)]);
    s.tick(100, &[p(14.0, 14.0, 0.0)]);
    let near = s.access("p");
    assert_eq!(
        s.craft("p", "post", &clean_cut(), &near, None, &mut bag),
        Err("no_station_near")
    );
    assert_eq!(count(&bag, "plank"), 4, "nothing taken");
    s.tick(200, &[p(4.0, 3.0, 0.0)]);
    let near = s.access("p");
    let c = s.craft("p", "post", &clean_cut(), &near, None, &mut bag).unwrap();
    assert_eq!((c.made.item, c.made.n, c.furniture), ("post", 4, None));
    assert_eq!(count(&bag, "post"), 4);
    // a stroke along the plank rather than across it still cuts, wastefully
    let along: Vec<(f64, f64)> = (0..=10).map(|i| (i as f64 / 10.0, 0.5)).collect();
    let c = s.craft("p", "post", &along, &near, None, &mut bag).unwrap();
    assert_eq!((c.made.n, c.made.score), (2, 0.0));
    assert_eq!(count(&bag, "post"), 6);
    assert_eq!(count(&bag, "plank"), 0);
    assert_eq!(
        s.craft("p", "post", &clean_cut(), &near, None, &mut bag),
        Err("missing_ingredients")
    );
}

#[test]
fn a_pocket_room_doubles_station_reach() {
    let mut s = flat();
    let mut bag = bag_with(&[("hyperdoor", 1)]);
    s.place(0, (4, 4, 0), "hyperdoor", 0, &mut bag).unwrap();
    let door = s.furniture_at(0, (4, 4, 0)).unwrap();
    let room = through(&mut s, "p", "ann", door).on;
    build(&mut s, "bench", room, (3, 3, 0), 0);
    // 9.6 from its middle: past REACH, within twice it
    let at = (-4.0, -3.0, 0.0);
    assert!(dist(at, (3.5, 3.0, 0.0)) > REACH);
    assert_eq!(s.stations_near(room, at), vec!["bench"]);
    s.tick(100, &[aboard(room, at)]);
    assert_eq!(s.access("p"), vec!["bench"]);
    // the same distance in the world is too far
    build(&mut s, "bench", 0, (10, 10, 0), 0);
    assert!(s.stations_near(0, (3.0, 4.0, 0.0)).is_empty());
}

#[test]
fn heavy_furniture_is_built_where_chosen_or_carried() {
    let mut s = flat();
    build(&mut s, "bench", 0, (4, 4, 0), 0);
    let near = vec!["bench"];
    let parts: &[(&str, u16)] = &[("plank", 2), ("post", 8), ("cloth", 6)];
    let mut bag = bag_with(parts);
    // it doesn't fit a bag: place or carry
    assert_eq!(
        s.craft("p", "bed", &[], &near, None, &mut bag),
        Err("place_or_carry")
    );
    // somewhere taken: refused, and nothing used up
    assert_eq!(
        s.craft("p", "bed", &[], &near, Some(Finish::Place(0, (4, 4, 0), 0)), &mut bag),
        Err("occupied")
    );
    assert_eq!(
        s.craft("p", "bed", &[], &near, Some(Finish::Place(0, (4, 4, 90), 0)), &mut bag),
        Err("edge_of_the_world")
    );
    assert_eq!(count(&bag, "cloth"), 6);
    let c = s
        .craft("p", "bed", &[], &near, Some(Finish::Place(0, (8, 8, 0), 1)), &mut bag)
        .unwrap();
    let bed = c.furniture.expect("built");
    assert!(!c.carried);
    assert_eq!(s.furniture_at(0, (8, 9, 0)), None, "turned: along -x");
    assert_eq!(s.furniture_at(0, (7, 8, 0)), Some(bed));
    assert_eq!(s.furniture[&bed].rot, 1);
    assert_eq!(count(&bag, "cloth"), 3);
    assert_eq!(count(&bag, "post"), 4);

    // carried: not with full hands, and nothing's used up trying
    s.terrain.set(6, 6, 0, POT);
    s.pick_block("p", (6.0, 5.0, 0.0), 0, (6, 6, 0)).unwrap();
    let carry = Some(Finish::Carry((0, (6.0, 5.0, 0.0))));
    assert_eq!(s.craft("p", "bed", &[], &near, carry, &mut bag), Err("hands_full"));
    assert_eq!(count(&bag, "cloth"), 3);
    s.put_down("p", 0, (6, 6, 0), 0).unwrap();
    let c = s.craft("p", "bed", &[], &near, carry, &mut bag).unwrap();
    let bed = c.furniture.unwrap();
    assert!(c.carried);
    assert_eq!(s.held("p"), Some(Held::Furniture(bed)));
    let f = &s.furniture[&bed];
    assert!(f.lifted);
    assert_eq!(f.grips, vec![Grip::Player("p".into())]);
    assert!(items::is_empty(&bag));
    // a chest takes one: carried off at once, nobody pinned
    let mut planks = bag_with(&[("plank", 4)]);
    let c = s
        .craft("q", "chest", &[], &near, Some(Finish::Carry((0, (3.0, 3.0, 0.0)))), &mut planks)
        .unwrap();
    assert!(c.carried);
    assert_eq!(s.pinned("q"), None);
    // a stool packs into the bag even when asked to carry it
    let mut b = bag_with(&[("plank", 1), ("post", 2)]);
    let c = s.craft("r", "stool", &[], &near, carry, &mut b).unwrap();
    assert_eq!(c.furniture, None);
    assert_eq!(count(&b, "stool"), 1);
}

#[test]
fn overencumbered_until_someone_takes_the_other_end() {
    let mut s = flat();
    build(&mut s, "bench", 0, (4, 4, 0), 0);
    let mut bag = bag_with(&[("plank", 1), ("post", 4), ("cloth", 3)]);
    let spot = (0, (6.0, 6.0, 0.0));
    let c = s
        .craft("p", "bed", &[], &["bench"], Some(Finish::Carry(spot)), &mut bag)
        .unwrap();
    let bed = c.furniture.unwrap();
    assert_eq!(s.pinned("p"), Some(spot));
    let ev = s.drain_events();
    assert!(ev.contains(&Event::Encumbered("p".into(), Some(spot))));
    // walking off: it stays where they're stuck, and they're told once
    s.tick(100, &[p(6.0, 6.2, 0.0)]);
    let ev = s.drain_events();
    assert!(!ev.iter().any(|e| matches!(e, Event::Encumbered(..))), "within the slack");
    s.tick(200, &[p(9.0, 6.0, 0.0)]);
    let ev = s.drain_events();
    assert_eq!(
        ev.iter().filter(|e| matches!(e, Event::Encumbered(..))).count(),
        1
    );
    assert!(ev.contains(&Event::Encumbered("p".into(), Some(spot))));
    s.tick(300, &[p(10.0, 6.0, 0.0)]);
    assert!(!s.drain_events().iter().any(|e| matches!(e, Event::Encumbered(..))));
    assert_eq!(s.furniture[&bed].at, (6.0, 6.0, 0.0));
    assert_eq!(s.held("p"), Some(Held::Furniture(bed)));
    // nobody carries them off, and they go through no doors
    assert_eq!(
        s.pick_player("q", (6.0, 5.0, 0.0), "p", (6.0, 6.0, 0.0)),
        Err("cannot_carry")
    );
    // too far to take the other end
    let mut none = bag_with(&[]);
    assert_eq!(s.grab("q", (6.0, 14.0, 0.0), bed, &mut none), Err("out_of_reach"));
    // a second carrier frees them
    assert_eq!(s.grab("q", (7.0, 6.0, 0.0), bed, &mut none), Ok(Grabbed::Lifted));
    assert_eq!(s.pinned("p"), None);
    assert!(s.drain_events().contains(&Event::Encumbered("p".into(), None)));
    assert_eq!(s.grab("r", (7.0, 6.0, 0.0), bed, &mut none), Err("already_carried"));
    // and off they go together
    s.tick(400, &[p(6.0, 8.0, 0.0), who("q", 7.0, 8.0, 0.0)]);
    assert_eq!(s.furniture[&bed].at, (6.5, 8.0, 0.0));
    assert_eq!(s.put_down("q", 0, (6, 10, 0), 0), Ok(Held::Furniture(bed)));
    assert!(!s.drain_events().iter().any(|e| matches!(e, Event::Encumbered(..))));
}

#[test]
fn a_helper_frees_someone_overencumbered() {
    let mut s = Sim::new(0, 0, 7, 1000);
    s.tick(0, &[]);
    let mut bag = bag_with(&[("plank", 4), ("post", 2), ("stone", 2)]);
    let h = (s.helpers[0].x, s.helpers[0].y, s.helpers[0].z);
    let spot = (0, (h.0 + 2.0, h.1, h.2));
    s.craft("p", "dresser", &[], &["bench"], Some(Finish::Carry(spot)), &mut bag)
        .unwrap();
    assert!(s.pinned("p").is_some());
    s.call_helper("p", s.helpers[0].id).unwrap();
    let mut t = 0;
    while s.pinned("p").is_some() {
        t += 100;
        s.tick(t, &[who("p", spot.1 .0, spot.1 .1, spot.1 .2)]);
        assert!(t < 10_000, "the helper never came");
    }
    assert!(s.drain_events().contains(&Event::Encumbered("p".into(), None)));
}

#[test]
fn breaking_gives_back_three_quarters_and_the_rest_goes_in_a_sack() {
    let mut s = flat();
    let mut bag = bag_with(&[("plank", 1), ("post", 4), ("cloth", 3)]);
    let spot = (0, (6.0, 6.0, 0.0));
    let bed = s
        .craft("p", "bed", &[], &["bench"], Some(Finish::Carry(spot)), &mut bag)
        .unwrap()
        .furniture
        .unwrap();
    // in their arms, too heavy: broken where they stand
    let b = s.break_apart("p", 0, spot.1, None, &mut bag).unwrap();
    // a bed is 3 wood and 12 wool, all the way down
    assert_eq!(b.back, vec![("wood".to_string(), 2), ("wool".to_string(), 9)]);
    assert_eq!(b.sack, None);
    assert_eq!((count(&bag, "wood"), count(&bag, "wool")), (2, 9));
    assert!(!s.furniture.contains_key(&bed));
    assert_eq!(s.held("p"), None);
    assert_eq!(s.pinned("p"), None);
    let ev = s.drain_events();
    assert!(ev.contains(&Event::FurnitureGone(bed)));
    assert!(ev.contains(&Event::Carry("p".into(), None)));
    assert!(ev.contains(&Event::Encumbered("p".into(), None)));
    assert_eq!(s.break_apart("p", 0, spot.1, None, &mut bag), Err("nothing_to_break"));

    // empty furniture in reach; a full bag sends it to a sack at their feet
    let table = build(&mut s, "table", 0, (4, 4, 0), 0);
    let chest = build(&mut s, "chest", 0, (8, 4, 0), 0);
    items::add(&mut s.furniture.get_mut(&chest).unwrap().slots, "dirt", 3);
    let feet = (4.0, 2.0, 0.0);
    assert_eq!(
        s.break_apart("p", 0, (4.0, 14.0, 0.0), Some(table), &mut bag),
        Err("out_of_reach")
    );
    assert_eq!(s.break_apart("p", 0, feet, Some(chest), &mut bag), Err("not_empty"));
    assert_eq!(s.break_apart("p", 0, feet, Some(999), &mut bag), Err("no_such_furniture"));
    let mut full = bag_with(&[]);
    for slot in full.iter_mut() {
        *slot = Some(items::Stack {
            item: "stone".into(),
            n: 64,
        });
    }
    let b = s.break_apart("p", 0, feet, Some(table), &mut full).unwrap();
    // two planks and four posts: four wood's worth, three of it back
    assert_eq!(b.back, vec![("wood".to_string(), 3)]);
    let sack = b.sack.expect("a sack");
    let f = &s.furniture[&sack];
    assert_eq!((f.kind.as_str(), f.origin), ("sack", (4, 2, 0)));
    assert_eq!(count(&f.slots, "wood"), 3);
    assert!(!s.furniture.contains_key(&table));
    assert_eq!(s.terrain.get(4, 4, 0), Some(AIR));
    // someone else's in their hands is in use
    let mut none = bag_with(&[]);
    s.grab("q", (8.0, 3.0, 0.0), chest, &mut none).unwrap();
    assert_eq!(s.break_apart("p", 0, (8.0, 3.0, 0.0), Some(chest), &mut bag), Err("in_use"));
}

#[test]
fn an_old_blueprint_breaks_for_everything_put_in() {
    let mut s = flat();
    let site = old_site(&mut s, "dresser", (4, 4, 0), &[("wood", 5), ("stone", 1)]);
    let mut bag = bag_with(&[]);
    assert_eq!(
        s.break_apart("p", 0, (4.0, 14.0, 0.0), Some(site), &mut bag),
        Err("out_of_reach")
    );
    let b = s.break_apart("p", 0, (4.0, 3.0, 0.0), Some(site), &mut bag).unwrap();
    assert_eq!(b.back, vec![("wood".to_string(), 5), ("stone".to_string(), 1)]);
    assert_eq!((count(&bag, "wood"), count(&bag, "stone")), (5, 1));
    assert!(s.sites.is_empty());
    assert_eq!(s.terrain.get(4, 4, 0), Some(AIR));
    assert_eq!(s.terrain.get(5, 4, 0), Some(AIR));
    assert!(s.drain_events().contains(&Event::SiteGone(site)));
}

#[test]
fn an_old_save_with_blueprints_and_no_sheep_still_loads() {
    // from before recipes: two blueprints (one in a shape that no longer
    // reads) and a chest, and no sheep anywhere
    let saved = r#"{"world_tick":50,"at_ms":1000,"crops":[],
        "furniture":[{"id":3,"kind":"chest","origin":[8,8,0],"rot":0,
                      "slots":[null,null,null,null,null,null,null,null,null,null,null,null]}],
        "sites":[{"id":4,"kind":"bed","on":0,"origin":[3,3,0],"rot":0,"have":[["wood",5]]},
                 {"id":"five","kind":"chest"}],
        "ships":[],"next_id":9}"#;
    let mut s = flat();
    s.restore(serde_json::from_str(saved).unwrap());
    assert_eq!(s.sites.len(), 1);
    assert_eq!(s.terrain.get(3, 3, 0), Some(SCAFFOLD));
    assert_eq!(s.terrain.get(3, 4, 0), Some(SCAFFOLD));
    assert_eq!(s.furniture[&3].kind, "chest");
    assert!(s.sheep.is_empty());
    // saved again, it still has its blueprint
    let json = serde_json::to_string(&s.save(2000)).unwrap();
    let mut t = flat();
    t.restore(serde_json::from_str(&json).unwrap());
    assert_eq!(t.site_at(0, (3, 4, 0)), Some(4));
    let mut bag = bag_with(&[]);
    t.break_apart("p", 0, (3.0, 2.0, 0.0), Some(4), &mut bag).unwrap();
    assert_eq!(count(&bag, "wood"), 5);
}

// -- sheep

#[test]
fn sheep_are_shorn_and_regrow_on_world_ticks_even_asleep() {
    let mut s = flat();
    let id = s.spawn_sheep_at(8.0, 8.0);
    s.sheep[0].body.idle_until_ms = i64::MAX;
    s.tick(100, &[]);
    s.drain_events();
    let mut bag = bag_with(&[]);
    assert_eq!(s.shear((1.0, 1.0, 0.0), id, &mut bag), Err("out_of_reach"));
    assert_eq!(s.shear((8.0, 7.0, 0.0), 99, &mut bag), Err("no_such_sheep"));
    assert_eq!(s.shear((8.0, 7.0, 0.0), id, &mut bag), Ok(SHEAR_WOOL));
    assert_eq!(count(&bag, "wool"), SHEAR_WOOL as u32);
    assert_eq!(s.drain_events(), vec![Event::Sheep(id)]);
    assert_eq!(s.shear((8.0, 7.0, 0.0), id, &mut bag), Err("already_shorn"));
    // not yet
    s.tick(100 + (WOOL_REGROW_TICKS - 10) * TICK_MS, &[]);
    assert!(!s.sheep[0].woolly);
    assert!(!s.drain_events().contains(&Event::Sheep(id)));
    // shorn again later, then everyone leaves: it grows back while asleep,
    // caught up on waking
    s.tick(100 + WOOL_REGROW_TICKS * TICK_MS, &[]);
    assert!(s.sheep[0].woolly);
    assert!(s.drain_events().contains(&Event::Sheep(id)));
    let t0 = 200 + WOOL_REGROW_TICKS * TICK_MS;
    s.tick(t0, &[]);
    s.shear((8.0, 7.0, 0.0), id, &mut bag).unwrap();
    s.drain_events();
    s.sleep(t0);
    s.ambient(t0 + 60_000);
    assert!(!s.sheep[0].woolly, "asleep, the clock stands still");
    s.wake(t0 + WOOL_REGROW_TICKS * TICK_MS + 1000);
    assert!(s.sheep[0].woolly);
    assert_eq!(s.drain_events(), vec![Event::Sheep(id)]);
    // a full bag takes no wool
    s.sheep[0].woolly = true;
    let mut full = bag_with(&[]);
    for slot in full.iter_mut() {
        *slot = Some(items::Stack {
            item: "stone".into(),
            n: 64,
        });
    }
    assert_eq!(s.shear((8.0, 7.0, 0.0), id, &mut full), Err("bag_full"));
    assert!(s.sheep[0].woolly);
}

#[test]
fn sheep_spawn_on_the_home_island_and_wander_it() {
    let mut s = Sim::new(0, 0, 7, 1000);
    s.spawn_sheep(4);
    assert_eq!(s.sheep.len(), 4);
    assert!(s.sheep.iter().all(|sh| sh.woolly));
    let mut t = 0;
    let mut moved = false;
    for _ in 0..600 {
        t += 100;
        let out = s.tick(t, &[]);
        moved |= !out.sheep.is_empty();
    }
    assert!(moved);
    for sh in &s.sheep {
        let b = &sh.body;
        assert!(s.terrain.walkable(b.x, b.y, b.z), "sheep {} off the island", b.id);
    }
}
