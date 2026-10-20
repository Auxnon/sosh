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
    let site = s.start_site("chest", 0, (3, 3, 0), 0).unwrap();
    s.deposit(site, &mut bag).unwrap();
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
fn blueprints_build_from_ingredients_put_in() {
    let mut s = flat();
    let mut bag = bag_with(&[("wood", 5), ("stone", 1)]);
    assert_eq!(
        s.start_site("throne", 0, (4, 4, 0), 0),
        Err("no_such_blueprint")
    );
    let id = s.start_site("dresser", 0, (4, 4, 0), 1).unwrap();
    // turned once: the second cell is north of the first
    assert_eq!(s.terrain.get(4, 4, 0), Some(SCAFFOLD));
    assert_eq!(s.terrain.get(4, 5, 0), Some(SCAFFOLD));
    assert_eq!(s.start_site("chest", 0, (4, 5, 0), 0), Err("occupied"));
    // all five wood go in (it wants six), then the one stone
    assert_eq!(s.deposit(id, &mut bag), Ok(None));
    assert_eq!(s.sites[&id].has("wood"), 5);
    assert_eq!(s.deposit(id, &mut bag), Ok(None));
    assert_eq!(s.deposit(id, &mut bag), Err("missing_ingredients"));
    assert!(items::is_empty(&bag));
    items::add(&mut bag, "wood", 3);
    items::add(&mut bag, "stone", 2);
    assert_eq!(s.deposit(id, &mut bag), Ok(None));
    let fid = s.deposit(id, &mut bag).unwrap().expect("built");
    assert_eq!(count(&bag, "wood"), 2);
    assert_eq!(count(&bag, "stone"), 1);
    assert!(s.sites.is_empty());
    assert_eq!(s.terrain.get(4, 5, 0), Some(FURNITURE));
    assert_eq!(s.furniture_at(0, (4, 5, 0)), Some(fid));
    let f = &s.furniture[&fid];
    assert_eq!((f.kind.as_str(), f.rot, f.slots.len()), ("dresser", 1, 16));
}

#[test]
fn taking_scaffolding_down_gives_it_all_back() {
    let mut s = flat();
    let mut bag = bag_with(&[("wood", 3)]);
    let id = s.start_site("chest", 0, (4, 4, 0), 0).unwrap();
    s.deposit(id, &mut bag).unwrap();
    assert_eq!(count(&bag, "wood"), 0);
    assert_eq!(s.dig("p", 0, (4, 4, 0), &mut bag), Ok(()));
    assert_eq!(count(&bag, "wood"), 3);
    assert_eq!(s.terrain.get(4, 4, 0), Some(AIR));
}

#[test]
fn chests_hold_things_and_breaking_returns_them() {
    let mut s = flat();
    let mut bag = bag_with(&[("wood", 4), ("stone", 20), ("carrot", 7)]);
    let site = s.start_site("chest", 0, (4, 4, 0), 0).unwrap();
    let chest = s.deposit(site, &mut bag).unwrap().unwrap();
    let at = (4.0, 3.0, 0.0);
    // stone is in slot 0 now that the wood went in
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

    // broken: half the wood back, every stone back
    assert_eq!(s.dig("p", 0, (4, 4, 0), &mut bag), Ok(()));
    assert_eq!(count(&bag, "wood"), 2);
    assert_eq!(count(&bag, "stone"), 20);
    assert_eq!(count(&bag, "carrot"), 7);
    assert!(s.furniture.is_empty());
    assert_eq!(s.terrain.get(4, 4, 0), Some(AIR));
    assert!(s.drain_events().contains(&Event::FurnitureGone(chest)));
}

#[test]
fn what_does_not_fit_the_bag_is_left_in_a_sack() {
    let mut s = flat();
    let mut bag = bag_with(&[("wood", 8), ("stone", 1)]);
    let site = s.start_site("wardrobe", 0, (4, 4, 0), 0).unwrap();
    s.deposit(site, &mut bag).unwrap();
    let wardrobe = s.deposit(site, &mut bag).unwrap().unwrap();
    // fill it with 20 slots of dirt, and the bag with carrots but one slot
    {
        let f = s.furniture.get_mut(&wardrobe).unwrap();
        items::add(&mut f.slots, "dirt", 20 * 64);
    }
    let mut bag = bag_with(&[("carrot", 15 * 64)]);
    s.dig("p", 0, (4, 4, 1), &mut bag).unwrap();
    // the one free slot took wood; the dirt is in a sack where it stood
    assert_eq!(count(&bag, "wood"), 4);
    let sack = s.furniture_at(0, (4, 4, 0)).expect("a sack");
    assert_eq!(s.furniture[&sack].kind, "sack");
    assert_eq!(count(&s.furniture[&sack].slots, "dirt"), 20 * 64);
    // emptied, it goes
    let mut empty = bag_with(&[]);
    for slot in 0..20 {
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
    let mut bag = bag_with(&[("wood", 10), ("stone", 2)]);
    let a = s.start_site("chest", 0, (4, 4, 0), 0).unwrap();
    let chest = s.deposit(a, &mut bag).unwrap().unwrap();
    let b = s.start_site("dresser", 0, (8, 4, 0), 0).unwrap();
    s.deposit(b, &mut bag).unwrap();
    let dresser = s.deposit(b, &mut bag).unwrap().unwrap();
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
    let mut bag = bag_with(&[("wood", 2)]);
    let site = s.start_site("stool", 0, (4, 4, 0), 0).unwrap();
    let stool = s.deposit(site, &mut bag).unwrap().unwrap();
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
    let site = s.start_site("dresser", 0, (3, -3, 0), 0).unwrap();
    s.deposit(site, &mut bag).unwrap();
    let dresser = s.deposit(site, &mut bag).unwrap().unwrap();
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
    let mut bag = bag_with(&[("wood", 4)]);
    let shore = s.ships[0].pose.to_world((0.0, 4.0, 0.0));
    let (sx, sy) = (cell(shore.0), cell(shore.1));
    let site = s.start_site("chest", 0, (sx, sy, 0), 0).unwrap();
    s.deposit(site, &mut bag).unwrap();
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
