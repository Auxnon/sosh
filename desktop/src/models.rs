//! What the server sends, as `android/.../data/Models.kt` reads it.

use serde_json::Value;

fn s(v: &Value, k: &str) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or("").to_owned()
}

fn opt_s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty() && *s != "false").map(str::to_owned)
}

fn i(v: &Value, k: &str) -> i64 {
    v.get(k).and_then(Value::as_i64).unwrap_or(0)
}

/// Someone as anyone sees them.
#[derive(Clone, Debug, PartialEq)]
pub struct Person {
    pub id: i64,
    pub handle: String,
}

impl Person {
    pub fn from(v: Option<&Value>) -> Option<Person> {
        let v = v.filter(|v| v.is_object())?;
        Some(Person { id: i(v, "id"), handle: s(v, "handle") })
    }
}

#[derive(Clone, Debug)]
pub struct Me {
    pub id: i64,
    pub handle: String,
}

impl Me {
    pub fn from(v: &Value) -> Me {
        Me { id: i(v, "id"), handle: s(v, "handle") }
    }
}

/// A server (a universe) and our place in it.
#[derive(Clone, Debug)]
pub struct Server {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub universe: (i64, i64),
    pub policy: String,
    /// "member", "pending", "invited", "banned", or None
    pub status: Option<String>,
    pub role: Option<String>,
    pub members: i64,
}

const RANKS: [&str; 4] = ["member", "moderator", "admin", "owner"];

impl Server {
    pub fn from(v: &Value) -> Server {
        let u = v.get("universe");
        let ux = u.and_then(|u| u.get(0)).and_then(Value::as_i64).unwrap_or(0);
        let uy = u.and_then(|u| u.get(1)).and_then(Value::as_i64).unwrap_or(0);
        Server {
            id: i(v, "id"),
            name: s(v, "name"),
            description: s(v, "description"),
            universe: (ux, uy),
            policy: s(v, "policy"),
            status: opt_s(v, "status"),
            role: opt_s(v, "role"),
            members: i(v, "members"),
        }
    }

    pub fn is_member(&self) -> bool {
        self.status.as_deref() == Some("member")
    }

    /// What the role may do (the server's `Sosh.Servers.perms/1`).
    pub fn can(&self, perm: &str) -> bool {
        let needs = match perm {
            "approve" | "kick" | "manage_messages" => "moderator",
            "invite" | "ban" | "set_roles" => "admin",
            "manage_server" => "owner",
            _ => "member",
        };
        let Some(role) = &self.role else { return false };
        let r = RANKS.iter().position(|x| x == role);
        let n = RANKS.iter().position(|x| *x == needs);
        matches!((r, n), (Some(r), Some(n)) if r >= n)
    }
}

#[derive(Clone, Debug)]
pub struct Member {
    pub person: Person,
    pub role: String,
    pub status: String,
}

impl Member {
    pub fn from(v: &Value) -> Option<Member> {
        Some(Member { person: Person::from(v.get("user"))?, role: s(v, "role"), status: s(v, "status") })
    }
}

#[derive(Clone, Debug, Default)]
pub struct Friends {
    pub friends: Vec<Person>,
    pub incoming: Vec<Person>,
    pub outgoing: Vec<Person>,
}

pub fn people(v: Option<&Value>) -> Vec<Person> {
    v.and_then(Value::as_array).map(|a| a.iter().filter_map(|p| Person::from(Some(p))).collect()).unwrap_or_default()
}

impl Friends {
    pub fn from(v: &Value) -> Friends {
        Friends { friends: people(v.get("friends")), incoming: people(v.get("incoming")), outgoing: people(v.get("outgoing")) }
    }
}

/// Items for one person, carried by a message.
#[derive(Clone, Debug)]
pub struct Gift {
    pub to: Option<Person>,
    /// "sealed", "opened", "returned"
    pub state: String,
    pub item: Option<String>,
    pub count: Option<i64>,
}

impl Gift {
    pub fn from(v: Option<&Value>) -> Option<Gift> {
        let v = v.filter(|v| v.is_object())?;
        Some(Gift { to: Person::from(v.get("to")), state: s(v, "state"), item: opt_s(v, "item"), count: v.get("count").and_then(Value::as_i64) })
    }
}

/// A picture or a Petrichor64 cart shared in a message (`Sosh.Media.view`).
#[derive(Clone, Debug)]
pub struct Media {
    pub key: String,
    /// relative to the server
    pub url: String,
    /// "image" or "cart"
    pub kind: String,
    pub animated: bool,
    pub w: i64,
    pub h: i64,
    pub size: i64,
    pub name: Option<String>,
}

impl Media {
    pub fn from(v: Option<&Value>) -> Option<Media> {
        let v = v.filter(|v| v.get("key").is_some())?;
        Some(Media {
            key: s(v, "key"),
            url: s(v, "url"),
            kind: opt_s(v, "kind").unwrap_or_else(|| "image".into()),
            animated: v.get("animated").and_then(Value::as_bool).unwrap_or(false),
            w: i(v, "w").max(1),
            h: i(v, "h").max(1),
            size: i(v, "size"),
            name: opt_s(v, "name"),
        })
    }

    pub fn is_cart(&self) -> bool {
        self.kind == "cart"
    }

    /// What it's called where it can't be shown.
    pub fn label(&self) -> String {
        if self.is_cart() {
            let n = self.name.clone().unwrap_or_else(|| "a game".into());
            n.trim_end_matches(".png").trim_end_matches(".game").to_owned()
        } else if self.animated {
            "a moving picture".into()
        } else {
            "a picture".into()
        }
    }
}

#[derive(Clone, Debug)]
pub struct Message {
    pub id: i64,
    pub author: Option<Person>,
    pub body: String,
    pub at: String,
    pub gift: Option<Gift>,
    pub media: Option<Media>,
    pub edited_at: Option<String>,
    pub reactions: Vec<Reaction>,
    /// How many signs were made of it (pinned).
    pub pins: i64,
}

/// What messages can be reacted with (`Sosh.Chat.reactions/0`).
pub const EMOJI: [&str; 6] = ["👍", "❤️", "😂", "😮", "😢", "🎉"];

/// One emoji on a message, and who put it there (user ids).
#[derive(Clone, Debug)]
pub struct Reaction {
    pub emoji: String,
    pub users: Vec<i64>,
}

impl Reaction {
    pub fn list(v: Option<&Value>) -> Vec<Reaction> {
        v.and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .map(|r| Reaction {
                        emoji: s(r, "emoji"),
                        users: r.get("users").and_then(Value::as_array).map(|u| u.iter().filter_map(Value::as_i64).collect()).unwrap_or_default(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// What kind of thing an item is: a pinned message's sign is `sign:<id>`.
pub fn item_kind(item: &str) -> &str {
    match item.split_once(':') {
        Some((k, n)) if !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) => k,
        _ => item,
    }
}

impl Message {
    pub fn from(v: &Value) -> Message {
        Message {
            id: i(v, "id"),
            author: Person::from(v.get("author")),
            body: s(v, "body"),
            at: s(v, "at"),
            gift: Gift::from(v.get("gift")),
            media: Media::from(v.get("media")),
            edited_at: opt_s(v, "edited_at"),
            reactions: Reaction::list(v.get("reactions")),
            pins: i(v, "pins"),
        }
    }

    pub fn list(v: Option<&Value>) -> Vec<Message> {
        v.and_then(Value::as_array).map(|a| a.iter().map(Message::from).collect()).unwrap_or_default()
    }

    /// "HH:MM" from the ISO time.
    pub fn time(&self) -> &str {
        self.at.get(11..16).unwrap_or("")
    }
}

#[derive(Clone, Debug)]
pub struct Conversation {
    pub with: Person,
    pub last: Option<Message>,
}

impl Conversation {
    pub fn from(v: &Value) -> Option<Conversation> {
        Some(Conversation { with: Person::from(v.get("with"))?, last: v.get("last").filter(|l| l.is_object()).map(Message::from) })
    }
}

#[derive(Clone, Debug)]
pub struct Slot {
    pub item: String,
    pub count: i64,
}

pub fn bag(v: Option<&Value>) -> Vec<Option<Slot>> {
    v.and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .map(|s| {
                    let item = s.get(0)?.as_str()?.to_owned();
                    let count = s.get(1)?.as_i64()?;
                    Some(Slot { item, count })
                })
                .collect()
        })
        .unwrap_or_default()
}
