//! Everything the app knows and does, as `android/.../AppState.kt`: the API
//! signs in and manages things; the socket brings everything live:
//! `user:<id>` for our own changes, and one chat channel at a time
//! (`server:<id>` or `dm:<id>`) for the place that's open.
//!
//! Calls run on threads and come back as `Job`s, applied here on the UI
//! thread once a frame (`pump`), so nothing in here is shared.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::media::Pics;
use crate::models::*;
use crate::net::{Api, ApiError, ApiResult, Inbound, Phoenix, Reply, describe};
use crate::store::Saved;

pub type Job = Box<dyn FnOnce(&mut State) + Send>;
pub type Wake = Arc<dyn Fn() + Send + Sync>;

#[derive(Clone, Debug, PartialEq)]
pub enum Place {
    InServer(i64),
    WithPerson(String),
}

/// How much of a server's world shows beside its chat.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Pane {
    Chat,
    Both,
    World,
}

/// The pages over the chat.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Screen {
    Chat,
    Explore,
    Friends,
    Bag,
    Members,
}

/// The sosh game the world runs: fetched from the server (the same
/// `/game.game.png` the web plays), or a folder on disk (`SOSH_GAME`, for
/// working on the game).
pub enum GameCart {
    Wanted,
    Loading,
    Ready(petrichor64::host::Cart),
    Failed,
}

/// A shared cart being played in the app.
pub struct Playing {
    pub media: Media,
    /// Its bytes, once fetched.
    pub bytes: Option<Vec<u8>>,
}

/// What the world is made for and told when it starts.
pub struct WorldSession {
    /// Its socket and token: a new one remakes the world.
    pub key: String,
    /// The first thing it hears (`client/scripts/hosted.lua`).
    pub hello: String,
    /// The server it should be in.
    pub server: i64,
}

/// A newer app the server needs: at least `min`, from `download` (a web page).
#[derive(Clone, Debug)]
pub struct Update {
    pub min: String,
    pub download: String,
}

pub struct State {
    /// The server needs a newer app; nothing else shows.
    pub update: Option<Update>,
    pub ctx: egui::Context,
    pub wake: Wake,
    jobs_tx: Sender<Job>,
    jobs: Receiver<Job>,
    saved: Saved,
    pub api: Api,
    socket: Option<Phoenix>,

    pub me: Option<Me>,
    /// Signing in from a saved token, before we know it's still good.
    pub restoring: bool,
    /// The sign-in screen's next step, once the server says so ("confirm", "reset").
    pub auth_step: Option<&'static str>,
    pub online: bool,
    pub servers: Vec<Server>,
    pub friends: Friends,
    pub conversations: Vec<Conversation>,
    pub bag: Vec<Option<Slot>>,
    pub held: Option<String>,

    pub place: Option<Place>,
    chat_topic: Option<String>,
    pub messages: Vec<Message>,
    /// Bumped when messages change, so the list scrolls to the newest.
    pub messages_gen: u64,
    pub members: Vec<Member>,
    pub pane: Pane,
    pub screen: Screen,
    pub loading_older: bool,
    /// A picture or cart going up to the open place.
    pub sharing: bool,
    pub pics: Pics,

    /// The world pane and a cart's window: where the UI puts them
    /// (`stage.rs` runs them).
    pub world: crate::stage::Spot,
    pub play: crate::stage::Spot,
    pub game: GameCart,
    pub playing: Option<Playing>,
    /// The last server opened: the world stays in it while a DM is open.
    world_server: Option<i64>,

    notice: Option<(String, Instant)>,
}

impl State {
    pub fn new(ctx: egui::Context, wake: Wake) -> State {
        let saved = Saved::load();
        let (jobs_tx, jobs) = channel();
        let api = Api::new(&saved.server_or_default(), saved.token.clone());
        let mut st = State {
            ctx,
            wake,
            jobs_tx,
            jobs,
            api,
            socket: None,
            me: None,
            restoring: false,
            auth_step: None,
            online: false,
            servers: Vec::new(),
            friends: Friends::default(),
            conversations: Vec::new(),
            bag: Vec::new(),
            held: None,
            place: None,
            chat_topic: None,
            messages: Vec::new(),
            messages_gen: 0,
            members: Vec::new(),
            pane: Pane::Chat,
            screen: Screen::Chat,
            loading_older: false,
            sharing: false,
            pics: Pics::default(),
            world: Default::default(),
            play: Default::default(),
            game: GameCart::Wanted,
            playing: None,
            world_server: None,
            notice: None,
            saved,
            update: None,
        };
        st.check_version();
        if st.saved.token.is_some() {
            st.restoring = true;
            st.run(
                |api| api.get("/me"),
                |st, r| {
                    st.restoring = false;
                    match r {
                        Ok(all) => {
                            let t = st.saved.token.clone().unwrap_or_default();
                            st.start_session(t, Me::from(&all["user"]));
                            st.absorb(&all);
                        }
                        Err(e) => {
                            if e.status == 401 {
                                st.saved.token = None;
                                st.saved.save();
                                st.api.token = None;
                            } else {
                                st.notify("Can't reach the server.");
                            }
                        }
                    }
                },
            );
        }
        st
    }

    // -- plumbing

    /// Run `call` on a thread; `done` gets its result here.
    pub fn run(&self, call: impl FnOnce(&Api) -> ApiResult + Send + 'static, done: impl FnOnce(&mut State, ApiResult) + Send + 'static) {
        let api = self.api.clone();
        let tx = self.jobs_tx.clone();
        let wake = self.wake.clone();
        std::thread::spawn(move || {
            let r = call(&api);
            let _ = tx.send(Box::new(move |st: &mut State| {
                if let Err(e) = &r {
                    st.refused(e);
                }
                done(st, r)
            }));
            wake();
        });
    }

    /// A server that needs a newer app says so on every request: from then
    /// on that's all there is (`ui::update`).
    fn refused(&mut self, e: &ApiError) {
        if e.reason == "update_required" {
            let s = |k: &str| e.body.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            self.update = Some(Update { min: s("min"), download: s("download") });
        }
    }

    /// Ask the server whether this app is new enough (before signing in).
    pub fn check_version(&mut self) {
        self.update = None;
        self.run(|api| api.get("/client"), |_, _| {});
    }

    /// Run `call`, putting any error in the notice; `ok` gets the answer.
    pub fn attempt(&self, call: impl FnOnce(&Api) -> ApiResult + Send + 'static, ok: impl FnOnce(&mut State, Value) + Send + 'static) {
        self.run(call, |st, r| match r {
            Ok(v) => ok(st, v),
            Err(e) => st.notify(&e.message),
        });
    }

    /// Run any work on a thread, then `Job` here.
    pub fn spawn(&self, work: impl FnOnce(Api) -> Job + Send + 'static) {
        let api = self.api.clone();
        let tx = self.jobs_tx.clone();
        let wake = self.wake.clone();
        std::thread::spawn(move || {
            let job = work(api);
            let _ = tx.send(job);
            wake();
        });
    }

    pub fn notify(&mut self, text: &str) {
        self.notice = Some((text.to_owned(), Instant::now()));
        self.ctx.request_repaint_after(Duration::from_secs(4));
    }

    /// The line to show, for a few seconds.
    pub fn notice(&self) -> Option<&str> {
        self.notice.as_ref().filter(|(_, at)| at.elapsed() < Duration::from_secs(4)).map(|(t, _)| t.as_str())
    }

    /// Apply what's come back from threads and the socket. Once a frame.
    pub fn pump(&mut self) {
        while let Ok(job) = self.jobs.try_recv() {
            job(self);
        }
        let got = match self.socket.as_mut() {
            Some(s) => s.drain(),
            None => Vec::new(),
        };
        for i in got {
            self.inbound(i);
        }
    }

    pub fn server_url(&self) -> &str {
        &self.api.base
    }

    // -- the world and shared carts

    /// What the world runs as, once we're signed in and have opened a
    /// server (and asks for the game the first time).
    pub fn world_session(&mut self) -> Option<WorldSession> {
        let me = self.me.as_ref()?.id;
        let token = self.api.token.clone()?;
        let server = self.world_server?;
        if matches!(self.game, GameCart::Wanted) {
            self.load_game();
        }
        // the game adds `&token=` itself
        let url = self.api.socket_url();
        let url = url.split("&token=").next().unwrap_or(&url).to_owned();
        Some(WorldSession { key: format!("{url} {token}"), hello: format!("session {url} {token} {} {server}", me), server })
    }

    /// The game behind the sign-in page: the same one, before anyone's
    /// signed in (asks for it the first time).
    pub fn want_backdrop(&mut self) {
        if matches!(self.game, GameCart::Wanted) {
            self.load_game();
        }
    }

    fn load_game(&mut self) {
        if let Some(dir) = std::env::var_os("SOSH_GAME") {
            self.game = GameCart::Ready(petrichor64::host::Cart::Path(dir.into()));
            return;
        }
        self.game = GameCart::Loading;
        self.spawn(|api| {
            let r = api.fetch("/game.game.png");
            Box::new(move |st: &mut State| {
                st.game = match r {
                    Ok(b) => GameCart::Ready(petrichor64::host::Cart::Bytes(b)),
                    Err(e) => {
                        log::warn!("game: {e}");
                        st.world.status = Some(format!("Couldn't get the world from the server ({e})."));
                        GameCart::Failed
                    }
                };
            })
        });
    }

    /// Fetch the game again after it failed.
    pub fn retry_game(&mut self) {
        self.world.status = None;
        self.load_game();
    }

    /// Play a shared cart here, fenced off (`stage.rs`).
    pub fn play_cart(&mut self, m: &Media) {
        self.playing = Some(Playing { media: m.clone(), bytes: None });
        self.play.status = None;
        let url = m.url.clone();
        let key = m.key.clone();
        self.spawn(move |api| {
            let r = api.fetch(&url);
            Box::new(move |st: &mut State| {
                let Some(p) = st.playing.as_mut().filter(|p| p.media.key == key) else { return };
                match r {
                    Ok(b) => p.bytes = Some(b),
                    Err(e) => st.play.status = Some(format!("Couldn't get it: {e}")),
                }
            })
        });
    }

    pub fn stop_cart(&mut self) {
        self.playing = None;
        self.play.focus = false;
    }

    pub fn set_server(&mut self, url: &str) {
        let u = url.trim().trim_end_matches('/').to_owned();
        if u.is_empty() {
            return;
        }
        self.saved.server = Some(u.clone());
        self.saved.save();
        self.api = Api::new(&u, self.api.token.clone());
        self.check_version();
        // the game comes from the server: a new one may have it
        if matches!(self.game, GameCart::Failed) {
            self.game = GameCart::Wanted;
        }
    }

    // -- signing in

    pub fn login(&mut self, email: &str, password: &str, unconfirmed: impl FnOnce(&mut State) + Send + 'static) {
        let body = json!({"email": email, "password": password});
        self.run(
            move |api| api.post("/auth/login", body),
            move |st, r| match r {
                Ok(v) => st.signed_in(v),
                Err(e) => {
                    if e.reason == "unconfirmed" {
                        unconfirmed(st);
                    }
                    st.notify(&e.message);
                }
            },
        );
    }

    /// Sign up: `coded` when a code was emailed.
    pub fn register(&mut self, email: &str, handle: &str, password: &str, coded: impl FnOnce(&mut State) + Send + 'static) {
        let body = json!({"email": email, "handle": handle, "password": password});
        self.attempt(
            move |api| api.post("/auth/register", body),
            move |st, r| {
                if r.get("token").is_some() { st.signed_in(r) } else { coded(st) }
            },
        );
    }

    pub fn confirm(&mut self, email: &str, code: &str) {
        let body = json!({"email": email, "code": code});
        self.attempt(move |api| api.post("/auth/confirm", body), |st, r| st.signed_in(r));
    }

    pub fn resend(&mut self, email: &str) {
        let body = json!({"email": email});
        self.attempt(move |api| api.post("/auth/resend", body), |_, _| {});
        self.notify("If that address needs it, a new code is on its way.");
    }

    pub fn forgot(&mut self, email: &str, sent: impl FnOnce(&mut State) + Send + 'static) {
        let body = json!({"email": email});
        self.attempt(move |api| api.post("/auth/forgot", body), move |st, _| sent(st));
    }

    pub fn reset(&mut self, email: &str, code: &str, password: &str) {
        let body = json!({"email": email, "code": code, "password": password});
        self.attempt(move |api| api.post("/auth/reset", body), |st, r| st.signed_in(r));
    }

    fn signed_in(&mut self, r: Value) {
        let Some(t) = r.get("token").and_then(Value::as_str).map(str::to_owned) else {
            self.notify("The server didn't sign us in.");
            return;
        };
        self.saved.token = Some(t.clone());
        self.saved.save();
        self.api.token = Some(t.clone());
        self.start_session(t, Me::from(&r["user"]));
        self.attempt(|api| api.get("/me"), |st, all| st.absorb(&all));
    }

    fn start_session(&mut self, token: String, me: Me) {
        self.api.token = Some(token);
        self.me = Some(me);
        self.connect();
    }

    pub fn logout(&mut self) {
        if self.api.token.is_some() {
            self.run(|api| api.delete("/auth/session"), |_, _| {});
        }
        self.socket = None;
        self.chat_topic = None;
        self.saved.token = None;
        self.saved.save();
        self.api.token = None;
        self.me = None;
        self.place = None;
        self.world_server = None;
        self.playing = None;
        self.online = false;
        self.servers.clear();
        self.conversations.clear();
        self.messages.clear();
        self.members.clear();
        self.friends = Friends::default();
        self.bag.clear();
        self.screen = Screen::Chat;
    }

    // -- live

    fn user_topic(&self) -> Option<String> {
        self.me.as_ref().map(|m| format!("user:{}", m.id))
    }

    fn connect(&mut self) {
        let wake = self.wake.clone();
        let mut s = Phoenix::connect(self.api.socket_url(), move || wake());
        if let Some(t) = self.user_topic() {
            s.join(&t, json!({}));
        }
        self.socket = Some(s);
        self.chat_topic = None;
        if let Some(p) = self.place.clone() {
            self.open(Some(p));
        }
    }

    fn inbound(&mut self, i: Inbound) {
        match i {
            Inbound::Online(on) => self.online = on,
            Inbound::Reply { reply, status, response } => reply(self, &status, &response),
            Inbound::Joined { topic, response } => {
                if Some(&topic) == self.user_topic().as_ref() {
                    self.absorb(&response);
                } else if Some(&topic) == self.chat_topic.as_ref() {
                    if let Some(m) = response.get("messages") {
                        self.set_messages(Message::list(Some(m)));
                    }
                }
            }
            Inbound::JoinFailed { topic, response } => {
                let reason = response.get("reason").and_then(Value::as_str).unwrap_or("").to_owned();
                if Some(&topic) == self.user_topic().as_ref() {
                    if reason == "signed_out" {
                        self.logout();
                    }
                } else if !reason.is_empty() {
                    self.notify(&describe(&reason, None));
                }
            }
            Inbound::Event { topic, event, payload } => {
                if Some(&topic) == self.user_topic().as_ref() {
                    self.user_event(&event, &payload);
                } else if Some(&topic) == self.chat_topic.as_ref() {
                    self.chat_event(&event, &payload);
                }
            }
        }
    }

    fn user_event(&mut self, event: &str, p: &Value) {
        match event {
            "servers" => self.refresh_servers(),
            "friends" => self.refresh_friends(),
            "bag" => self.bag = bag(p.get("bag")),
            "hold" => self.held = p.get("item").and_then(Value::as_str).map(str::to_owned),
            "dm" => self.refresh_conversations(),
            "gift" => {
                let from = p.pointer("/from/handle").and_then(Value::as_str).unwrap_or("someone").to_owned();
                self.notify(&format!("@{from} sent you a gift"));
            }
            "removed" => {
                let id = p.get("server_id").and_then(Value::as_i64).unwrap_or(-1);
                if self.place == Some(Place::InServer(id)) {
                    self.open(None);
                }
                self.refresh_servers();
            }
            _ => {}
        }
    }

    fn chat_event(&mut self, event: &str, p: &Value) {
        match event {
            "message" => self.upsert(Message::from(p), false),
            "gift" => self.upsert(Message::from(p), true),
            "deleted" => {
                let id = p.get("id").and_then(Value::as_i64).unwrap_or(-1);
                self.messages.retain(|m| m.id != id);
            }
            "edited" => {
                let (body, at) = (p.get("body").and_then(Value::as_str).unwrap_or("").to_owned(), p.get("edited_at").and_then(Value::as_str).map(str::to_owned));
                self.change(p, |m| {
                    m.body = body;
                    m.edited_at = at;
                });
            }
            "reactions" => {
                let rs = Reaction::list(p.get("reactions"));
                self.change(p, |m| m.reactions = rs);
            }
            "pins" => {
                let n = p.get("pins").and_then(Value::as_i64).unwrap_or(0);
                self.change(p, |m| m.pins = n);
            }
            "members" => self.load_members(),
            "removed" => {
                self.open(None);
                self.refresh_servers();
            }
            _ => {}
        }
    }

    /// Take in an "everything" answer (`Sosh.Me.everything/1`).
    fn absorb(&mut self, all: &Value) {
        if let Some(u) = all.get("user").filter(|u| u.is_object()) {
            self.me = Some(Me::from(u));
        }
        if let Some(a) = all.get("servers").and_then(Value::as_array) {
            self.servers = a.iter().map(Server::from).collect();
        }
        if let Some(f) = all.get("friends").filter(|f| f.is_object()) {
            self.friends = Friends::from(f);
        }
        if let Some(a) = all.get("conversations").and_then(Value::as_array) {
            self.conversations = a.iter().filter_map(Conversation::from).collect();
        }
        if all.get("bag").is_some() {
            self.bag = bag(all.get("bag"));
        }
        if self.place.is_none() {
            if let Some(id) = self.servers.iter().find(|s| s.is_member()).map(|s| s.id) {
                self.open(Some(Place::InServer(id)));
            }
        }
    }

    pub fn refresh_servers(&self) {
        self.attempt(
            |api| api.get("/servers"),
            |st, r| {
                if let Some(a) = r.get("servers").and_then(Value::as_array) {
                    st.servers = a.iter().map(Server::from).collect();
                }
            },
        );
    }

    pub fn refresh_friends(&self) {
        self.attempt(|api| api.get("/friends"), |st, r| st.friends = Friends::from(&r));
    }

    pub fn refresh_conversations(&self) {
        self.attempt(
            |api| api.get("/dms"),
            |st, r| {
                if let Some(a) = r.get("conversations").and_then(Value::as_array) {
                    st.conversations = a.iter().filter_map(Conversation::from).collect();
                }
            },
        );
    }

    pub fn server(&self, id: i64) -> Option<&Server> {
        self.servers.iter().find(|s| s.id == id)
    }

    /// The server that's open, if one is.
    pub fn open_server(&self) -> Option<&Server> {
        match &self.place {
            Some(Place::InServer(id)) => self.server(*id),
            _ => None,
        }
    }

    // -- the open place

    /// Show a server's chat or a conversation (None: nothing).
    pub fn open(&mut self, p: Option<Place>) {
        if let (Some(t), Some(s)) = (self.chat_topic.take(), self.socket.as_mut()) {
            s.leave(&t);
        }
        self.place = p.clone();
        self.screen = Screen::Chat;
        self.messages.clear();
        self.members.clear();
        self.messages_gen += 1;
        if self.socket.is_none() {
            return;
        }
        match p {
            None => {}
            Some(Place::InServer(id)) => {
                self.world_server = Some(id);
                let topic = format!("server:{id}");
                if let Some(s) = self.socket.as_mut() {
                    s.join(&topic, json!({}));
                }
                self.chat_topic = Some(topic);
                self.load_members();
            }
            Some(Place::WithPerson(handle)) => {
                let path = format!("/dms/{}/messages", crate::net::encode(&handle));
                self.attempt(
                    move |api| api.get(&path),
                    move |st, r| {
                        if st.place != Some(Place::WithPerson(handle)) {
                            return;
                        }
                        let id = r.get("conversation_id").and_then(Value::as_i64).unwrap_or(0);
                        let topic = format!("dm:{id}");
                        if let Some(s) = st.socket.as_mut() {
                            s.join(&topic, json!({}));
                        }
                        st.chat_topic = Some(topic);
                        st.set_messages(Message::list(r.get("messages")));
                    },
                );
            }
        }
    }

    fn set_messages(&mut self, m: Vec<Message>) {
        self.messages = m;
        self.messages_gen += 1;
    }

    /// A message in (or changed). Broadcasts carry gifts sealed for
    /// everyone; what we know of our own (what we sent, what we opened) stays.
    fn upsert(&mut self, m: Message, keep_mine: bool) {
        match self.messages.iter().position(|x| x.id == m.id) {
            None => {
                self.messages.push(m);
                self.messages_gen += 1;
            }
            Some(i) => {
                let old = &self.messages[i];
                let mut gift = m.gift.clone();
                if keep_mine {
                    if let (Some(og), Some(g)) = (&old.gift, gift.as_mut()) {
                        if og.item.is_some() {
                            g.item = og.item.clone();
                            g.count = og.count;
                        }
                    }
                }
                let gift = gift.or_else(|| old.gift.clone());
                self.messages[i] = Message { gift, ..m };
            }
        }
    }

    /// Push on the open chat channel; `reply` hears back (or "offline").
    fn push_chat(&mut self, event: &str, payload: Value, reply: Reply) {
        let Some(topic) = self.chat_topic.clone() else {
            reply(self, "offline", &json!({"reason": "offline"}));
            return;
        };
        let left = match self.socket.as_mut() {
            Some(s) => s.push(&topic, event, payload, Some(reply)),
            None => Some(reply),
        };
        if let Some(r) = left {
            r(self, "offline", &json!({"reason": "offline"}));
        }
    }

    fn push_user(&mut self, event: &str, payload: Value, reply: Option<Reply>) {
        let Some(topic) = self.user_topic() else { return };
        let left = match self.socket.as_mut() {
            Some(s) => s.push(&topic, event, payload, reply),
            None => reply,
        };
        if let Some(r) = left {
            r(self, "offline", &json!({"reason": "offline"}));
        }
    }

    pub fn load_older(&mut self) {
        let Some(first) = self.messages.first().map(|m| m.id) else { return };
        if self.loading_older {
            return;
        }
        self.loading_older = true;
        self.push_chat(
            "history",
            json!({"before": first}),
            Box::new(|st, status, r| {
                st.loading_older = false;
                if status == "ok" {
                    let mut older = Message::list(r.get("messages"));
                    older.append(&mut st.messages);
                    st.messages = older;
                }
            }),
        );
    }

    /// Post to the open place: text, a picture we uploaded (`media`, its
    /// key), or items for someone.
    pub fn post(&mut self, body: &str, media: Option<String>, gift: Option<(String, i64, String)>) {
        let mut payload = json!({"body": body});
        if let Some(k) = media {
            payload["media"] = json!(k);
        }
        if let Some((item, count, to)) = gift {
            payload["gift"] = json!({"item": item, "count": count, "to": to});
        }
        self.push_chat(
            "post",
            payload,
            Box::new(|st, status, r| {
                if status == "ok" {
                    if let Some(m) = r.get("message") {
                        st.upsert(Message::from(m), false);
                    }
                } else if status == "offline" {
                    st.notify("Not connected.");
                } else {
                    st.notify(&describe(r.get("reason").and_then(Value::as_str).unwrap_or(""), None));
                }
            }),
        );
    }

    /// Share a picture (or a .game.png) into the open place.
    pub fn share(&mut self, bytes: Vec<u8>, name: String) {
        if self.chat_topic.is_none() {
            self.notify("Open a chat to share a picture there.");
            return;
        }
        self.sharing = true;
        self.run(
            move |api| api.upload(bytes, &name),
            |st, r| {
                st.sharing = false;
                match r {
                    Ok(v) => {
                        let key = v.pointer("/media/key").and_then(Value::as_str).map(str::to_owned);
                        if key.is_some() {
                            st.post("", key, None);
                        }
                    }
                    Err(ApiError { message, .. }) => st.notify(&message),
                }
            },
        );
    }

    /// Share a file from disk.
    pub fn share_path(&mut self, path: &std::path::Path) {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "picture".into());
        match std::fs::metadata(path) {
            Ok(m) if m.len() > 8 * 1024 * 1024 => self.notify("That's over 8 MB."),
            Ok(_) => match std::fs::read(path) {
                Ok(b) => self.share(b, name),
                Err(_) => self.notify("Couldn't read that file."),
            },
            Err(_) => self.notify("Couldn't read that file."),
        }
    }

    pub fn claim(&mut self, m: &Message) {
        self.settle(m.id, "claim");
    }

    pub fn cancel(&mut self, m: &Message) {
        self.settle(m.id, "cancel");
    }

    fn settle(&mut self, id: i64, how: &'static str) {
        self.attempt(
            move |api| api.post(&format!("/messages/{id}/{how}"), json!({})),
            move |st, r| {
                if let Some(m) = r.get("message") {
                    let m = Message::from(m);
                    if how == "claim" {
                        if let Some(g) = &m.gift {
                            if let Some(item) = &g.item {
                                st.notify(&format!("{} {}: in your bag.", g.count.unwrap_or(1), item));
                            }
                        }
                    }
                    st.upsert(m, false);
                }
            },
        );
    }

    pub fn delete_message(&mut self, id: i64) {
        self.attempt(move |api| api.delete(&format!("/messages/{id}")), |_, _| {});
    }

    /// The message `p.id` names, changed by `f`.
    fn change(&mut self, p: &Value, f: impl FnOnce(&mut Message)) {
        let id = p.get("id").and_then(Value::as_i64).unwrap_or(-1);
        if let Some(m) = self.messages.iter_mut().find(|m| m.id == id) {
            f(m);
        }
    }

    /// Push `event` about a message on the open chat; `done` hears the reply.
    fn act(&mut self, event: &str, payload: Value, done: fn(&mut State, &Value)) {
        self.push_chat(
            event,
            payload,
            Box::new(move |st, status, r| {
                if status == "ok" {
                    done(st, r);
                } else if status == "offline" {
                    st.notify("Not connected.");
                } else {
                    st.notify(&describe(r.get("reason").and_then(Value::as_str).unwrap_or(""), None));
                }
            }),
        );
    }

    pub fn edit_message(&mut self, id: i64, body: &str) {
        self.act("edit", json!({"id": id, "body": body}), |st, r| {
            if let Some(m) = r.get("message") {
                st.upsert(Message::from(m), true);
            }
        });
    }

    /// Our `emoji` on `m`, or off it if it's there already.
    pub fn react(&mut self, m: &Message, emoji: &str) {
        let me = self.me.as_ref().map(|me| me.id);
        let on = !m.reactions.iter().any(|r| r.emoji == emoji && me.is_some_and(|me| r.users.contains(&me)));
        self.act("react", json!({"id": m.id, "emoji": emoji, "on": on}), |st, r| {
            let rs = Reaction::list(r.get("reactions"));
            st.change(r, |m| m.reactions = rs);
        });
    }

    /// A sign of message `id` into our pockets, to place in the world.
    pub fn pin(&mut self, id: i64) {
        self.act("pin", json!({"id": id}), |st, r| {
            let n = r.get("pins").and_then(Value::as_i64).unwrap_or(0);
            st.change(r, |m| m.pins = n);
            st.notify("A sign of it is in your pockets: place it in the world.");
        });
    }

    // -- servers and members

    pub fn load_members(&mut self) {
        let Some(Place::InServer(id)) = self.place.clone() else { return };
        self.attempt(
            move |api| api.get(&format!("/servers/{id}/members")),
            move |st, r| {
                if st.place == Some(Place::InServer(id)) {
                    st.members = r.get("members").and_then(Value::as_array).map(|a| a.iter().filter_map(Member::from).collect()).unwrap_or_default();
                }
            },
        );
    }

    pub fn join(&mut self, s: &Server) {
        let (id, name) = (s.id, s.name.clone());
        self.attempt(
            move |api| api.post(&format!("/servers/{id}/join"), json!({})),
            move |st, r| {
                let status = r.get("status").and_then(Value::as_str).unwrap_or("");
                if status == "member" {
                    st.notify(&format!("Joined {name}."));
                    st.refresh_servers();
                    st.open(Some(Place::InServer(id)));
                } else {
                    st.notify(&format!("Asked to join {name}: someone there has to let you in."));
                    st.refresh_servers();
                }
            },
        );
    }

    pub fn leave(&mut self, s: &Server) {
        let id = s.id;
        self.attempt(
            move |api| api.post(&format!("/servers/{id}/leave"), json!({})),
            move |st, _| {
                if st.place == Some(Place::InServer(id)) {
                    st.open(None);
                }
                st.refresh_servers();
            },
        );
    }

    pub fn member_action(&mut self, server: i64, handle: &str, action: &'static str, role: Option<&str>) {
        let path = format!("/servers/{server}/members/{}/{action}", crate::net::encode(handle));
        let body = match role {
            Some(r) => json!({"role": r}),
            None => json!({}),
        };
        self.attempt(move |api| api.post(&path, body), |st, _| st.load_members());
    }

    pub fn invite(&mut self, server: i64, handle: &str) {
        let h = handle.trim().trim_start_matches('@').to_owned();
        let body = json!({"handle": h});
        self.attempt(move |api| api.post(&format!("/servers/{server}/invite"), body), move |st, _| st.notify(&format!("Invited @{h}.")));
    }

    // -- friends

    pub fn add_friend(&mut self, handle: &str) {
        let h = handle.trim().trim_start_matches('@').to_owned();
        if h.is_empty() {
            return;
        }
        let body = json!({"handle": h});
        self.attempt(
            move |api| api.post("/friends", body),
            move |st, r| {
                let accepted = r.get("status").and_then(Value::as_str) == Some("accepted");
                st.notify(&if accepted { "You're friends now.".to_owned() } else { format!("Asked @{h}.") });
                st.refresh_friends();
            },
        );
    }

    pub fn accept_friend(&mut self, handle: &str) {
        let path = format!("/friends/{}/accept", crate::net::encode(handle));
        self.attempt(move |api| api.post(&path, json!({})), |st, _| st.refresh_friends());
    }

    pub fn remove_friend(&mut self, handle: &str) {
        let path = format!("/friends/{}", crate::net::encode(handle));
        self.attempt(move |api| api.delete(&path), |st, _| st.refresh_friends());
    }

    // -- you

    /// Swap two bag slots: here straight away, then for real; put back if refused.
    pub fn bag_swap(&mut self, a: usize, b: usize) {
        if a == b || a >= self.bag.len() || b >= self.bag.len() {
            return;
        }
        let before = self.bag.clone();
        self.bag.swap(a, b);
        self.push_user(
            "bag_swap",
            json!({"a": a, "b": b}),
            Some(Box::new(move |st, status, r| {
                if status == "ok" {
                    st.bag = bag(r.get("bag"));
                } else {
                    st.bag = before;
                    st.notify(&describe(r.get("reason").and_then(Value::as_str).unwrap_or(""), None));
                }
            })),
        );
    }

    /// Put `item` in hand in the world.
    pub fn hold(&mut self, item: &str) {
        self.held = Some(item.to_owned());
        self.push_user("hold", json!({"item": item}), None);
    }

    /// Items in the bag by kind, with how many.
    pub fn bag_totals(&self) -> Vec<(String, i64)> {
        let mut out: Vec<(String, i64)> = Vec::new();
        let mut at: HashMap<String, usize> = HashMap::new();
        for s in self.bag.iter().flatten() {
            match at.get(&s.item) {
                Some(&i) => out[i].1 += s.count,
                None => {
                    at.insert(s.item.clone(), out.len());
                    out.push((s.item.clone(), s.count));
                }
            }
        }
        out
    }
}
