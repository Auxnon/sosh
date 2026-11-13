//! Petrichor64 inside the window: the world (the sosh game, signed in as us)
//! and a shared cart being played, each an engine `Instance` on our own GPU
//! device drawing into a texture of its own, which egui shows like any
//! picture.
//!
//! The UI only says where each one goes (`State::world.rect`,
//! `State::play.rect`) and shows `tex`; this runs them, once a frame after
//! the UI: makes, resizes and ticks the instances, and hands them input that
//! lands on them.
//!
//! The world runs our own game, trusted (`Policy::open`), and is handed the
//! session over the host channel, so it never sees a sign-in screen. Before
//! that it's the sign-in page's backdrop (told `backdrop`: the sea and the
//! sky turning), and the same instance is signed in when we are. A
//! shared cart is someone else's: `Policy::sandbox()` (no network, files,
//! clipboard, console, other carts, microphone or host channel).

use std::time::{Duration, Instant};

use petrichor64::Instance;
use petrichor64::host::{Button, Cart, HostGpu, Input, Options, Policy, Request};
use winit::event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent};
use winit::keyboard::{Key, NamedKey, PhysicalKey};

use crate::state::{GameCart, State};

/// The world's key while it's the sign-in page's backdrop.
const BACKDROP: &str = "backdrop";

/// What the engine renders into, and egui samples like its own pictures.
const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8UnormSrgb;

/// Where one instance shows, and whether it has the keys. Set by the UI.
#[derive(Default)]
pub struct Spot {
    /// In egui points, this frame; `None` when it isn't shown.
    pub rect: Option<egui::Rect>,
    /// What to paint there, once it's running.
    pub tex: Option<egui::TextureId>,
    /// The pointer is over it (not over something on top of it), last frame.
    pub hover: bool,
    /// Keys go to it (a click on it gives them, a click elsewhere takes them).
    pub focus: bool,
    /// Why it isn't running, to say in its place.
    pub status: Option<String>,
}

struct Slot {
    inst: Instance,
    tex: egui::TextureId,
    view: wgpu::TextureView,
    /// What it was made for: the world's session, or the cart's key.
    key: String,
    /// The server we last told the world to open.
    entered: Option<i64>,
}

pub struct Stages {
    gpu: HostGpu,
    start: Instant,
    world: Option<Slot>,
    play: Option<Slot>,
    /// In the window's physical pixels, last frame.
    world_px: Option<[f32; 4]>,
    play_px: Option<[f32; 4]>,
    scale: f32,
    /// Where the pointer is, in physical pixels.
    cursor: (f32, f32),
}

impl Stages {
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue) -> Stages {
        Stages {
            gpu: HostGpu { device: device.clone(), queue: queue.clone(), format: FORMAT },
            start: Instant::now(),
            world: None,
            play: None,
            world_px: None,
            play_px: None,
            scale: 1.0,
            cursor: (0.0, 0.0),
        }
    }

    /// After the UI: run what's shown, at the size it's shown.
    pub fn update(&mut self, st: &mut State, renderer: &mut egui_wgpu::Renderer, ppp: f32) {
        self.scale = ppp;
        let now = self.start.elapsed();

        // the world: our game, signed in, once there's a server open; before
        // anyone's signed in, the sign-in page's backdrop, kept until then
        let session = st.world_session();
        let have = self.world.as_ref().map(|w| w.key.as_str());
        let backdrop = st.me.is_none() && st.world.rect.is_some() || st.me.is_some() && have == Some(BACKDROP);
        if backdrop && st.me.is_none() {
            st.want_backdrop();
        }
        let want = match (&session, &st.game) {
            (Some(s), GameCart::Ready(_)) => Some(s.key.clone()),
            (None, GameCart::Ready(_)) if backdrop => Some(BACKDROP.to_owned()),
            _ => None,
        };
        // signed in over the backdrop: the same instance, told who we are
        if let (Some(slot), Some(s)) = (self.world.as_mut(), &session) {
            if slot.key == BACKDROP && want.as_ref() == Some(&s.key) {
                slot.inst.post(s.hello.clone());
                slot.key = s.key.clone();
            }
        }
        if self.world.as_ref().map(|w| &w.key) != want.as_ref() {
            self.drop_slot(renderer, true);
            st.world.tex = None;
            if let (Some(s), GameCart::Ready(cart), Some(r)) = (&session, &st.game, st.world.rect) {
                match self.make(renderer, cart.clone(), Policy::open(), px(r, ppp), s.key.clone()) {
                    Ok(mut slot) => {
                        slot.inst.post(s.hello.clone());
                        self.world = Some(slot);
                        st.world.status = None;
                    }
                    Err(e) => {
                        log::warn!("world: {e}");
                        st.world.status = Some(format!("The world didn't start: {e}"));
                    }
                }
            } else if let (Some(BACKDROP), GameCart::Ready(cart), Some(r)) = (want.as_deref(), &st.game, st.world.rect) {
                // a backdrop that doesn't start just leaves the plain ground
                match self.make(renderer, cart.clone(), Policy::open(), px(r, ppp), BACKDROP.to_owned()) {
                    Ok(mut slot) => {
                        slot.inst.post("backdrop".into());
                        self.world = Some(slot);
                    }
                    Err(e) => log::warn!("backdrop: {e}"),
                }
            }
        }
        if let (Some(slot), Some(s)) = (self.world.as_mut(), &session) {
            if slot.entered != Some(s.server) {
                slot.inst.post(format!("enter {}", s.server));
                slot.entered = Some(s.server);
            }
        }
        self.world_px = st.world.rect.map(|r| px(r, ppp));
        if let Some(slot) = self.world.as_mut() {
            st.world.tex = Some(slot.tex);
            run(slot, renderer, &self.gpu, self.world_px, ppp, now, st, true);
        }

        // a shared cart, while it's open
        let want = st.playing.as_ref().and_then(|p| p.bytes.as_ref().map(|_| p.media.key.clone()));
        if self.play.as_ref().map(|p| &p.key) != want.as_ref() {
            self.drop_slot(renderer, false);
            st.play.tex = None;
            if let (Some(p), Some(r)) = (&st.playing, st.play.rect) {
                if let Some(bytes) = &p.bytes {
                    match self.make(renderer, Cart::Bytes(bytes.clone()), Policy::sandbox(), px(r, ppp), p.media.key.clone()) {
                        Ok(slot) => {
                            self.play = Some(slot);
                            st.play.focus = true;
                            st.play.status = None;
                        }
                        Err(e) => {
                            log::warn!("cart {}: {e}", p.media.key);
                            st.play.status = Some(format!("It didn't start: {e}"));
                        }
                    }
                }
            }
        }
        self.play_px = st.play.rect.map(|r| px(r, ppp));
        if let Some(slot) = self.play.as_mut().filter(|_| st.playing.is_some()) {
            st.play.tex = Some(slot.tex);
            run(slot, renderer, &self.gpu, self.play_px, ppp, now, st, false);
        }
    }

    fn make(&self, renderer: &mut egui_wgpu::Renderer, cart: Cart, policy: Policy, r: [f32; 4], key: String) -> Result<Slot, String> {
        let size = (r[2].round().max(1.0) as u32, r[3].round().max(1.0) as u32);
        let inst = Instance::new(&self.gpu, Options { cart, size, scale: self.scale, policy })?;
        let view = inst.texture().clone();
        let tex = renderer.register_native_texture(&self.gpu.device, &view, wgpu::FilterMode::Nearest);
        Ok(Slot { inst, tex, view, key, entered: None })
    }

    fn drop_slot(&mut self, renderer: &mut egui_wgpu::Renderer, world: bool) {
        let slot = if world { self.world.take() } else { self.play.take() };
        if let Some(s) = slot {
            renderer.free_texture(&s.tex);
        }
    }

    /// When an instance next wants to run, for the event loop.
    pub fn next(&self) -> Option<Instant> {
        [&self.world, &self.play].iter().filter_map(|s| s.as_ref()?.inst.next_frame()).min().map(|d| self.start + d)
    }

    /// Input from the window, for the instance under the pointer or with the
    /// keys. `egui_keys`: egui is typing (a text field has focus), so keys
    /// stay there.
    pub fn event(&mut self, st: &mut State, event: &WindowEvent, egui_keys: bool) {
        match event {
            WindowEvent::CursorMoved { position, .. } => {
                self.cursor = (position.x as f32, position.y as f32);
                for (slot, r) in [(&mut self.world, self.world_px), (&mut self.play, self.play_px)] {
                    if let (Some(slot), Some(r)) = (slot.as_mut(), r) {
                        slot.inst.input(Input::PointerMoved { x: self.cursor.0 - r[0], y: self.cursor.1 - r[1] });
                    }
                }
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let pressed = *state == ElementState::Pressed;
                let button = match button {
                    MouseButton::Left => Button::Left,
                    MouseButton::Right => Button::Right,
                    MouseButton::Middle => Button::Middle,
                    MouseButton::Forward => Button::Forward,
                    _ => return,
                };
                // the cart's window sits over the world: it's hit first
                let on_play = self.play.is_some() && st.play.rect.is_some() && st.play.hover;
                let on_world = !on_play && self.world.is_some() && st.world.rect.is_some() && st.world.hover;
                if pressed {
                    self.focus(st, on_world, on_play);
                }
                for (slot, on, has) in [(&mut self.world, on_world, st.world.focus), (&mut self.play, on_play, st.play.focus)] {
                    // a release goes where the press went
                    if let Some(slot) = slot.as_mut().filter(|_| on || (!pressed && has)) {
                        slot.inst.input(Input::Button { button, pressed });
                    }
                }
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let (x, y) = match delta {
                    MouseScrollDelta::LineDelta(x, y) => (*x, *y),
                    MouseScrollDelta::PixelDelta(p) => (p.x as f32 / 120.0, p.y as f32 / 120.0),
                };
                let target = if st.play.hover && st.play.rect.is_some() {
                    self.play.as_mut()
                } else if st.world.hover && st.world.rect.is_some() {
                    self.world.as_mut()
                } else {
                    None
                };
                if let Some(slot) = target {
                    slot.inst.input(Input::Wheel { x, y });
                }
            }
            WindowEvent::KeyboardInput { event, .. } => {
                let Some(slot) = self.keyed(st) else { return };
                if egui_keys {
                    return;
                }
                let pressed = event.state == ElementState::Pressed;
                if let PhysicalKey::Code(code) = event.physical_key {
                    slot.inst.input(Input::Key { code, pressed });
                }
                if pressed {
                    match &event.logical_key {
                        Key::Character(c) => slot.inst.input(Input::Text(c.to_string())),
                        Key::Named(NamedKey::Space) => slot.inst.input(Input::Text(" ".into())),
                        _ => {}
                    }
                }
            }
            WindowEvent::ModifiersChanged(m) => {
                let s = m.state();
                let ev = Input::Modifiers { alt: s.alt_key(), ctrl: s.control_key(), shift: s.shift_key(), logo: s.super_key() };
                for slot in [self.world.as_mut(), self.play.as_mut()].into_iter().flatten() {
                    slot.inst.input(ev.clone());
                }
            }
            WindowEvent::Focused(false) => self.focus(st, false, false),
            _ => {}
        }
    }

    /// The instance the keys go to.
    fn keyed(&mut self, st: &State) -> Option<&mut Slot> {
        if st.play.focus && st.play.rect.is_some() {
            self.play.as_mut()
        } else if st.world.focus && st.world.rect.is_some() {
            self.world.as_mut()
        } else {
            None
        }
    }

    fn focus(&mut self, st: &mut State, world: bool, play: bool) {
        if st.world.focus && !world {
            if let Some(s) = self.world.as_mut() {
                s.inst.input(Input::FocusLost);
            }
        }
        if st.play.focus && !play {
            if let Some(s) = self.play.as_mut() {
                s.inst.input(Input::FocusLost);
            }
        }
        st.world.focus = world;
        st.play.focus = play;
    }
}

/// Tick one instance and draw it if it's shown, follow its size, and deal with
/// what it asked for.
#[allow(clippy::too_many_arguments)]
fn run(
    slot: &mut Slot,
    renderer: &mut egui_wgpu::Renderer,
    gpu: &HostGpu,
    r: Option<[f32; 4]>,
    ppp: f32,
    now: Duration,
    st: &mut State,
    trusted: bool,
) {
    // hidden, it keeps running (its socket stays up) but isn't drawn
    let ticked = slot.inst.frame(now);
    let Some(r) = r else { return };
    let size = (r[2].round().max(1.0) as u32, r[3].round().max(1.0) as u32);
    if slot.inst.size() != size {
        slot.inst.resize(size, ppp);
    }
    if ticked {
        slot.inst.render();
    }
    // a resize makes a new texture (when it settles)
    let view = slot.inst.texture();
    if *view != slot.view {
        slot.view = view.clone();
        renderer.update_egui_texture_from_wgpu_texture(&gpu.device, &slot.view, wgpu::FilterMode::Nearest, slot.tex);
    }
    for req in slot.inst.requests() {
        match req {
            Request::Clipboard(text) if trusted => st.ctx.copy_text(text),
            // the window is the app's: title, size, fullscreen, quit and
            // grabbing the pointer are declined
            _ => {}
        }
    }
    for msg in slot.inst.messages() {
        log::info!("world says: {msg}");
    }
}

fn px(r: egui::Rect, ppp: f32) -> [f32; 4] {
    [(r.left() * ppp).round(), (r.top() * ppp).round(), r.width() * ppp, r.height() * ppp]
}
