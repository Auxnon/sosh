use std::sync::RwLock;
use rustler::{Encoder, Env, NifResult, Resource, ResourceArc, Term};
use uuid::Uuid;
use serde::{Serialize, Deserialize};

mod entity;

pub use entity::{Entity, Vec3};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum BlockType {
    Air,
    Stone,
    Dirt,
    Grass,
    Wood,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerrainAction {
    pub id: String,
    pub user_id: String,
    pub action_type: String,
    pub position: (i32, i32, i32),
    pub block_type: Option<BlockType>,
    pub timestamp: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionResult {
    pub success: bool,
    pub block_removed: Option<String>,
    pub items_dropped: Vec<ItemDrop>,
    pub new_block_state: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ItemDrop {
    pub item_id: String,
    pub quantity: u32,
}

struct Universe {
    pub entities: std::collections::HashMap<Uuid, Entity>,
    pub terrain: std::collections::HashMap<(i32, i32, i32), BlockType>,
    pub actions: Vec<TerrainAction>,
}

impl Universe {
    fn new() -> Self {
        Self {
            entities: std::collections::HashMap::new(),
            terrain: std::collections::HashMap::new(),
            actions: Vec::new(),
        }
    }
    
    fn get_state<'a>(&self, env: Env<'a>) -> Vec<Term<'a>> {
        self.entities
            .values()
            .map(|e| e.into_term(env))
            .collect()
    }
    
    fn dig_block(&mut self, user_id: &str, position: (i32, i32, i32), face: &str) -> Result<ActionResult, String> {
        let target_pos = apply_face_offset(position, face);
        
        let current_block = self.terrain.get(&target_pos).unwrap_or(&BlockType::Air);
        
        match current_block {
            BlockType::Air => Err("cannot_dig_air".to_string()),
            BlockType::Stone => Err("stone_too_hard".to_string()),
            _ => {
                // Remove the block
                let removed_block = current_block.clone();
                self.terrain.insert(target_pos, BlockType::Air);
                
                // Create action record
                let action = TerrainAction {
                    id: Uuid::new_v4().to_string(),
                    user_id: user_id.to_string(),
                    action_type: "dig".to_string(),
                    position: target_pos,
                    block_type: Some(removed_block.clone()),
                    timestamp: std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_secs(),
                };
                
                self.actions.push(action);
                
                // Return success with items
                let block_name = block_type_to_string(&removed_block);
                Ok(ActionResult {
                    success: true,
                    block_removed: Some(block_name.to_string()),
                    items_dropped: vec![ItemDrop {
                        item_id: format!("{}_block", block_name),
                        quantity: 1,
                    }],
                    new_block_state: Some("air".to_string()),
                })
            }
        }
    }
    
    fn place_block(&mut self, user_id: &str, position: (i32, i32, i32), block_type: &str) -> Result<ActionResult, String> {
        let block_type_enum = match block_type {
            "stone" => BlockType::Stone,
            "dirt" => BlockType::Dirt,
            "grass" => BlockType::Grass,
            "wood" => BlockType::Wood,
            _ => return Err("invalid_block_type".to_string()),
        };
        
        // Check if position is empty
        if self.terrain.get(&position).is_some() {
            return Err("position_occupied".to_string());
        }
        
        // Place the block
        self.terrain.insert(position, block_type_enum.clone());
        
        // Create action record
        let action = TerrainAction {
            id: Uuid::new_v4().to_string(),
            user_id: user_id.to_string(),
            action_type: "place".to_string(),
            position: position,
            block_type: Some(block_type_enum.clone()),
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs(),
        };
        
        self.actions.push(action);
        
        Ok(ActionResult {
            success: true,
            block_removed: None,
            items_dropped: vec![],
            new_block_state: Some(block_type.to_string()),
        })
    }
}

struct UniLock(RwLock<Universe>);

impl std::ops::Deref for UniLock {
    type Target = RwLock<Universe>;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for UniLock {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

impl Resource for UniLock {}

type ArcUni = ResourceArc<UniLock>;

fn load(_env: Env, _term: Term) -> bool {
    true
}

#[rustler::nif]
fn bigbang() -> ArcUni {
    let u = Universe::new();
    ResourceArc::new(UniLock(RwLock::new(u)))
}

#[rustler::nif]
fn new_ent(env: Env, state: ArcUni) -> NifResult<Term> {
    match state.write() {
        Ok(mut u) => {
            let e = Entity::new();
            let id = e.get_id();
            u.entities.insert(e.get_id(), e);
            Ok(id.as_bytes().encode(env))
        }
        Err(_) => Err(rustler::Error::Term(Box::new("Universe lock poisoned"))),
    }
}

#[rustler::nif]
fn move_ent(state: ArcUni, id: Term, pos: Vec3) -> NifResult<()> {
    if let Ok(bytes) = id.decode_as_binary() {
        let uuid = Uuid::from_slice(bytes.as_slice())
            .map_err(|_| rustler::Error::Term(Box::new("Invalid UUID bytes")))?;
        
        match state.write() {
            Ok(mut u) => {
                match u.entities.get_mut(&uuid) {
                    Some(e) => {
                        e.nav(pos);
                        Ok(())
                    }
                    None => Err(rustler::Error::Term(Box::new("Entity missing"))),
                }
            }
            Err(_) => Err(rustler::Error::Term(Box::new("Universe lock poisoned"))),
        }
    } else {
        Err(rustler::Error::Term(Box::new("Invalid UUID format")))
    }
}

#[rustler::nif]
fn dig_block(state: ArcUni, user_id: String, position: (i32, i32, i32), face: String) -> NifResult<String> {
    match state.write() {
        Ok(mut u) => {
            match u.dig_block(&user_id, position, &face) {
                Ok(result) => {
                    let action_id = u.actions.last().unwrap().id.clone();
                    println!("DIG action: User {} at {:?} face {:?}", user_id, position, face);
                    Ok(action_id)
                }
                Err(reason) => Err(rustler::Error::Term(Box::new(reason))),
            }
        }
        Err(_) => Err(rustler::Error::Term(Box::new("Universe lock poisoned"))),
    }
}

#[rustler::nif]
fn place_block(state: ArcUni, user_id: String, position: (i32, i32, i32), block_type: String) -> NifResult<String> {
    match state.write() {
        Ok(mut u) => {
            match u.place_block(&user_id, position, &block_type) {
                Ok(result) => {
                    let action_id = u.actions.last().unwrap().id.clone();
                    println!("PLACE action: User {} at {:?} type {}", user_id, position, block_type);
                    Ok(action_id)
                }
                Err(reason) => Err(rustler::Error::Term(Box::new(reason))),
            }
        }
        Err(_) => Err(rustler::Error::Term(Box::new("Universe lock poisoned"))),
    }
}

#[rustler::nif]
fn get_state(env: Env, state: ArcUni) -> NifResult<Vec<Term>> {
    match state.read() {
        Ok(u) => Ok(u.get_state(env)),
        Err(_) => Err(rustler::Error::Term(Box::new("Universe lock poisoned"))),
    }
}

// Helper functions
fn apply_face_offset(pos: (i32, i32, i32), face: &str) -> (i32, i32, i32) {
    match face {
        "top" => (pos.0, pos.1 + 1, pos.2),
        "bottom" => (pos.0, pos.1 - 1, pos.2),
        "north" => (pos.0, pos.1, pos.2 - 1),
        "south" => (pos.0, pos.1, pos.2 + 1),
        "east" => (pos.0 + 1, pos.1, pos.2),
        "west" => (pos.0 - 1, pos.1, pos.2),
        _ => pos,
    }
}

fn block_type_to_string(block_type: &BlockType) -> &'static str {
    match block_type {
        BlockType::Air => "air",
        BlockType::Stone => "stone",
        BlockType::Dirt => "dirt",
        BlockType::Grass => "grass",
        BlockType::Wood => "wood",
    }
}

rustler::init!("Elixir.ChatTest.Universe", load = load);