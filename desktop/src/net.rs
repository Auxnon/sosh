//! The server: its JSON API (`/api`, as `android/.../net/Api.kt`) and its
//! Phoenix channels (`/socket/websocket`, as `Phoenix.kt`).
//!
//! Calls block, so they run on threads (`State::call` and friends); the
//! socket has a thread of its own that only moves frames. Channels, refs and
//! replies are kept on the UI thread (`Phoenix`), which hands what arrives
//! to `State` as `Inbound`s.

use std::collections::HashMap;
use std::io::Read;
use std::net::TcpStream;
use std::sync::mpsc::{Receiver, Sender, TryRecvError, channel};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

/// A refused request: `reason` is the server's (`bad_login`, `forbidden`...).
#[derive(Debug, Clone)]
pub struct ApiError {
    pub status: u16,
    pub reason: String,
    pub message: String,
    /// The server's whole answer (`update_required` carries `min`, `download`).
    pub body: Value,
}

/// Who we are, to the server (`X-Sosh-Client`): a release says its tag's
/// version (`SOSH_VERSION`, set by release.yml); anything else is a
/// development build, which servers never turn away.
pub const CLIENT: &str = match option_env!("SOSH_VERSION") {
    Some(v) => v,
    None => concat!(env!("CARGO_PKG_VERSION"), "-dev"),
};

pub type ApiResult = Result<Value, ApiError>;

const MAX_UPLOAD: usize = 8 * 1024 * 1024;

#[derive(Clone)]
pub struct Api {
    pub base: String,
    pub token: Option<String>,
}

impl Api {
    pub fn new(base: &str, token: Option<String>) -> Self {
        Api { base: base.trim_end_matches('/').to_owned(), token }
    }

    fn agent() -> ureq::Agent {
        ureq::Agent::config_builder()
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_recv_body(Some(Duration::from_secs(30)))
            .http_status_as_error(false)
            .build()
            .into()
    }

    pub fn get(&self, path: &str) -> ApiResult {
        self.call("GET", path, None)
    }

    pub fn post(&self, path: &str, body: Value) -> ApiResult {
        self.call("POST", path, Some(body))
    }

    pub fn delete(&self, path: &str) -> ApiResult {
        self.call("DELETE", path, None)
    }

    fn call(&self, method: &str, path: &str, body: Option<Value>) -> ApiResult {
        let url = format!("{}/api{}", self.base, path);
        let agent = Self::agent();
        let auth = self.token.as_ref().map(|t| format!("Bearer {t}"));
        let client = format!("desktop/{CLIENT}");
        let res = match method {
            "GET" | "DELETE" => {
                let mut r = if method == "GET" { agent.get(&url) } else { agent.delete(&url) };
                r = r.header("x-sosh-client", &client);
                if let Some(a) = &auth {
                    r = r.header("authorization", a);
                }
                r.call()
            }
            _ => {
                let mut r = match method {
                    "PUT" => agent.put(&url),
                    "PATCH" => agent.patch(&url),
                    _ => agent.post(&url),
                };
                r = r.header("x-sosh-client", &client);
                if let Some(a) = &auth {
                    r = r.header("authorization", a);
                }
                r.send_json(body.unwrap_or_else(|| json!({})))
            }
        };
        Self::finish(res)
    }

    /// Upload a file (`POST /api/media`): the bytes are the body.
    pub fn upload(&self, bytes: Vec<u8>, name: &str) -> ApiResult {
        if bytes.len() > MAX_UPLOAD {
            return Err(ApiError { status: 413, reason: "too_big".into(), message: describe("too_big", None), body: json!({}) });
        }
        let url = format!("{}/api/media?name={}", self.base, encode(name));
        let mut r = Self::agent().post(&url).header("content-type", "application/octet-stream").header("x-sosh-client", &format!("desktop/{CLIENT}"));
        if let Some(t) = &self.token {
            r = r.header("authorization", &format!("Bearer {t}"));
        }
        Self::finish(r.send(&bytes[..]))
    }

    /// Bytes from the server (a picture by its `url`).
    pub fn fetch(&self, path: &str) -> Result<Vec<u8>, String> {
        let url = format!("{}{}", self.base, path);
        let res = Self::agent().get(&url).call().map_err(|e| e.to_string())?;
        if !res.status().is_success() {
            return Err(format!("http {}", res.status().as_u16()));
        }
        let mut out = Vec::new();
        res.into_body().into_reader().take(16 * 1024 * 1024).read_to_end(&mut out).map_err(|e| e.to_string())?;
        Ok(out)
    }

    fn finish(res: Result<ureq::http::Response<ureq::Body>, ureq::Error>) -> ApiResult {
        let res = res.map_err(|_| ApiError { status: 0, reason: "offline".into(), message: "Can't reach the server.".into(), body: json!({}) })?;
        let status = res.status().as_u16();
        let text = res.into_body().read_to_string().unwrap_or_default();
        let obj: Value = serde_json::from_str(&text).unwrap_or(json!({}));
        if (200..300).contains(&status) {
            Ok(obj)
        } else {
            let reason = obj.get("error").and_then(Value::as_str).map(str::to_owned).unwrap_or_else(|| format!("http_{status}"));
            let message = describe(&reason, Some(&obj));
            Err(ApiError { status, reason, message, body: obj })
        }
    }

    /// The websocket address for this server, signed in.
    pub fn socket_url(&self) -> String {
        let ws = if let Some(rest) = self.base.strip_prefix("https://") {
            format!("wss://{rest}")
        } else if let Some(rest) = self.base.strip_prefix("http://") {
            format!("ws://{rest}")
        } else {
            self.base.clone()
        };
        format!("{ws}/socket/websocket?vsn=2.0.0&token={}", encode(self.token.as_deref().unwrap_or("")))
    }
}

/// Percent-encode a query value.
pub fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// A sentence for a reason (and the first field error, if invalid).
pub fn describe(reason: &str, body: Option<&Value>) -> String {
    if reason == "invalid" {
        if let Some(errors) = body.and_then(|b| b.get("errors")).and_then(Value::as_object) {
            if let Some((key, v)) = errors.iter().next() {
                let first = v.get(0).and_then(Value::as_str).unwrap_or("is invalid");
                return format!("{key} {first}");
            }
        }
    }
    let known = match reason {
        "bad_login" => "Wrong email or password.",
        "unconfirmed" => "Confirm your email first: we sent a new code.",
        "bad_code" => "That code didn't work.",
        "rate_limited" => "Too many tries. Wait a few minutes.",
        "forbidden" => "You can't do that here.",
        "signed_out" => "Signed out.",
        "no_such_user" => "No one has that handle.",
        "not_enough" => "You don't have that many.",
        "no_room" => "No room in your bag for that.",
        "not_yours" => "That isn't yours to open.",
        "already" => "That gift is already settled.",
        "banned" => "You're banned from that server.",
        "yourself" => "That's you.",
        "not_a_member" => "They aren't a member here.",
        "bad_media" => "Only png, jpeg, gif and webp pictures (and games).",
        "too_big" => "That's over 8 MB.",
        "offline" => "Can't reach the server.",
        "update_required" => "This app is too old for the server: update it.",
        "bag_full" => "No room in your pockets.",
        "not_in_a_server" => "Only server messages can be pinned.",
        _ => "",
    };
    if known.is_empty() { reason.replace('_', " ") } else { known.to_owned() }
}

// -- the socket

/// What the socket thread says.
pub enum Wire {
    Open,
    Closed,
    Frame(String),
}

/// Runs the websocket on a thread: connects (and reconnects with backoff),
/// sends what `out` gives it, and hands every frame to `to_ui`. `wake` asks
/// the window to look.
pub fn spawn_socket(url: String, to_ui: Sender<Wire>, wake: impl Fn() + Send + 'static) -> Sender<Option<String>> {
    let (tx, rx) = channel::<Option<String>>();
    std::thread::Builder::new().name("sosh-socket".into()).spawn(move || socket_loop(url, rx, to_ui, wake)).expect("socket thread");
    tx
}

fn set_timeout(ws: &mut WebSocket<MaybeTlsStream<TcpStream>>, t: Duration) {
    let s = match ws.get_mut() {
        MaybeTlsStream::Plain(s) => s,
        MaybeTlsStream::Rustls(s) => s.get_mut(),
        _ => return,
    };
    let _ = s.set_read_timeout(Some(t));
}

fn socket_loop(url: String, out: Receiver<Option<String>>, to_ui: Sender<Wire>, wake: impl Fn()) {
    let delays = [1u64, 2, 5, 10];
    let mut retries = 0usize;
    'connect: loop {
        let mut ws = match tungstenite::connect(url.as_str()) {
            Ok((ws, _)) => ws,
            Err(e) => {
                log::warn!("socket: {e}");
                // drop what was queued while down; channels rejoin on open
                loop {
                    match out.try_recv() {
                        Ok(None) | Err(TryRecvError::Disconnected) => return,
                        Ok(Some(_)) => {}
                        Err(TryRecvError::Empty) => break,
                    }
                }
                std::thread::sleep(Duration::from_secs(delays[retries.min(3)]));
                retries += 1;
                continue;
            }
        };
        retries = 0;
        set_timeout(&mut ws, Duration::from_millis(40));
        if to_ui.send(Wire::Open).is_err() {
            return;
        }
        wake();
        let mut last_beat = Instant::now();
        let mut beat_ref = 0u64;
        loop {
            // what to send
            loop {
                match out.try_recv() {
                    Ok(Some(text)) => {
                        if ws.send(Message::text(text)).is_err() {
                            break;
                        }
                    }
                    Ok(None) | Err(TryRecvError::Disconnected) => {
                        let _ = ws.close(None);
                        return;
                    }
                    Err(TryRecvError::Empty) => break,
                }
            }
            if last_beat.elapsed() > Duration::from_secs(25) {
                beat_ref += 1;
                let hb = json!([null, format!("hb{beat_ref}"), "phoenix", "heartbeat", {}]).to_string();
                if ws.send(Message::text(hb)).is_err() {
                    break;
                }
                last_beat = Instant::now();
            }
            match ws.read() {
                Ok(Message::Text(t)) => {
                    if to_ui.send(Wire::Frame(t.to_string())).is_err() {
                        return;
                    }
                    wake();
                }
                Ok(Message::Close(_)) => break,
                Ok(_) => {}
                Err(tungstenite::Error::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => break,
            }
        }
        if to_ui.send(Wire::Closed).is_err() {
            return;
        }
        wake();
        std::thread::sleep(Duration::from_secs(delays[retries.min(3)]));
        retries += 1;
        continue 'connect;
    }
}

/// A reply to a push: its status ("ok", "error", "offline") and response.
pub type Reply = Box<dyn FnOnce(&mut crate::state::State, &str, &Value)>;

struct Chan {
    params: Value,
    join_ref: Option<String>,
    joined: bool,
}

/// What arrived on a channel, for `State` to act on.
pub enum Inbound {
    Event { topic: String, event: String, payload: Value },
    Joined { topic: String, response: Value },
    JoinFailed { topic: String, response: Value },
    Reply { reply: Reply, status: String, response: Value },
    Online(bool),
}

/// The Phoenix v2 protocol on the UI thread: frames are
/// `[join_ref, ref, topic, event, payload]`.
pub struct Phoenix {
    out: Sender<Option<String>>,
    pub wire: Receiver<Wire>,
    open: bool,
    next: u64,
    chans: Vec<(String, Chan)>,
    replies: HashMap<String, Reply>,
    joins: HashMap<String, String>,
}

impl Phoenix {
    pub fn connect(url: String, wake: impl Fn() + Send + 'static) -> Self {
        let (to_ui, wire) = channel();
        let out = spawn_socket(url, to_ui, wake);
        Phoenix { out, wire, open: false, next: 0, chans: Vec::new(), replies: HashMap::new(), joins: HashMap::new() }
    }

    fn next_ref(&mut self) -> String {
        self.next += 1;
        self.next.to_string()
    }

    fn send(&self, frame: Value) {
        let _ = self.out.send(Some(frame.to_string()));
    }

    fn chan(&mut self, topic: &str) -> Option<&mut Chan> {
        self.chans.iter_mut().find(|(t, _)| t == topic).map(|(_, c)| c)
    }

    /// Join `topic` (again on every reconnect) until `leave`.
    pub fn join(&mut self, topic: &str, params: Value) {
        if self.chan(topic).is_none() {
            self.chans.push((topic.to_owned(), Chan { params, join_ref: None, joined: false }));
        }
        if self.open {
            self.rejoin(topic);
        }
    }

    fn rejoin(&mut self, topic: &str) {
        let r = self.next_ref();
        let Some(c) = self.chan(topic) else { return };
        c.join_ref = Some(r.clone());
        let params = c.params.clone();
        self.joins.insert(r.clone(), topic.to_owned());
        self.send(json!([r, r, topic, "phx_join", params]));
    }

    pub fn leave(&mut self, topic: &str) {
        let Some(i) = self.chans.iter().position(|(t, _)| t == topic) else { return };
        let (_, c) = self.chans.remove(i);
        if c.joined {
            let r = self.next_ref();
            self.send(json!([c.join_ref, r, topic, "phx_leave", {}]));
        }
    }

    /// Push an event; `reply` gets ("ok"|"error"|"offline", response).
    pub fn push(&mut self, topic: &str, event: &str, payload: Value, reply: Option<Reply>) -> Option<Reply> {
        let join_ref = match self.chan(topic) {
            Some(c) if c.joined => c.join_ref.clone(),
            _ => return reply, // not joined: the caller answers "offline"
        };
        let r = self.next_ref();
        if let Some(cb) = reply {
            self.replies.insert(r.clone(), cb);
        }
        self.send(json!([join_ref, r, topic, event, payload]));
        None
    }

    /// Everything that's arrived, in order.
    pub fn drain(&mut self) -> Vec<Inbound> {
        let mut got = Vec::new();
        while let Ok(w) = self.wire.try_recv() {
            match w {
                Wire::Open => {
                    self.open = true;
                    got.push(Inbound::Online(true));
                    let topics: Vec<String> = self.chans.iter().map(|(t, _)| t.clone()).collect();
                    for t in topics {
                        self.rejoin(&t);
                    }
                }
                Wire::Closed => {
                    self.open = false;
                    for (_, c) in &mut self.chans {
                        c.joined = false;
                    }
                    // pushes waiting on the dead connection won't be answered
                    for (_, cb) in self.replies.drain() {
                        got.push(Inbound::Reply { reply: cb, status: "offline".into(), response: json!({"reason": "offline"}) });
                    }
                    got.push(Inbound::Online(false));
                }
                Wire::Frame(text) => self.dispatch(&text, &mut got),
            }
        }
        got
    }

    fn dispatch(&mut self, text: &str, got: &mut Vec<Inbound>) {
        let Ok(Value::Array(msg)) = serde_json::from_str::<Value>(text) else { return };
        let s = |i: usize| msg.get(i).and_then(Value::as_str).map(str::to_owned);
        let (join_ref, msg_ref, topic, event) = (s(0), s(1), s(2).unwrap_or_default(), s(3).unwrap_or_default());
        let payload = msg.get(4).cloned().unwrap_or(json!({}));
        if event == "phx_reply" {
            let status = payload.get("status").and_then(Value::as_str).unwrap_or("").to_owned();
            let response = payload.get("response").cloned().unwrap_or(json!({}));
            let Some(r) = msg_ref else { return };
            if let Some(t) = self.joins.remove(&r) {
                if status == "ok" {
                    if let Some(c) = self.chan(&t) {
                        c.joined = true;
                    }
                    got.push(Inbound::Joined { topic: t, response });
                } else {
                    got.push(Inbound::JoinFailed { topic: t, response });
                }
            } else if let Some(cb) = self.replies.remove(&r) {
                got.push(Inbound::Reply { reply: cb, status, response });
            }
            return;
        }
        if event == "phx_error" || event == "phx_close" {
            let open = self.open;
            if let Some(c) = self.chan(&topic) {
                if join_ref.is_some() && join_ref == c.join_ref {
                    c.joined = false;
                    if event == "phx_error" && open {
                        self.rejoin(&topic);
                    }
                }
            }
            return;
        }
        if self.chan(&topic).is_some() {
            got.push(Inbound::Event { topic, event, payload });
        }
    }
}

impl Drop for Phoenix {
    fn drop(&mut self) {
        let _ = self.out.send(None);
    }
}
