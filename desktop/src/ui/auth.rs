//! Signing in, signing up, codes and the server address, as `AuthScreen.kt`.

use egui::{Align2, Rect, RichText, Ui, UiBuilder, pos2, vec2};

use super::View;
use crate::state::State;
use crate::theme::*;

#[derive(Clone, Copy, PartialEq, Default)]
pub enum Mode {
    #[default]
    Login,
    Register,
    Confirm,
    Forgot,
    Reset,
    Server,
}

#[derive(Default)]
pub struct Auth {
    pub mode: Mode,
    pub email: String,
    pub handle: String,
    pub password: String,
    pub code: String,
    pub server: Option<String>,
}

pub fn draw(root: &mut Ui, st: &mut State, v: &mut View, full: Rect) {
    let a = &mut v.auth;
    match st.auth_step.take() {
        Some("confirm") => a.mode = Mode::Confirm,
        Some("reset") => a.mode = Mode::Reset,
        _ => {}
    }
    if a.server.is_none() {
        a.server = Some(st.server_url().to_owned());
    }
    let w = 440.0f32.min(full.width() - 32.0);
    let card_h = match a.mode {
        Mode::Server => 210.0,
        Mode::Register => 330.0,
        Mode::Login | Mode::Reset => 270.0,
        _ => 220.0,
    };
    let logo_h = 150.0;
    let total = logo_h + card_h + 70.0;
    let top = (full.center().y - total / 2.0).max(full.top() + 16.0);
    let p = root.painter();
    cube_logo(p, Rect::from_center_size(pos2(full.center().x, top + 50.0), vec2(80.0, 86.0)));
    p.text(pos2(full.center().x, top + 112.0), Align2::CENTER_CENTER, "sosh", font(EXTRA, 46.0), PAPER);
    p.text(pos2(full.center().x, top + 142.0), Align2::CENTER_CENTER, "ISLANDS IN THE SKY", font(TECH, 10.0), TEXT_DIM);

    let card = Rect::from_min_size(pos2(full.center().x - w / 2.0, top + logo_h + 10.0), vec2(w, card_h));
    plastic(root.painter(), card, 28.0, PAPER, EDGE, 5.0, 0.0);
    root.scope_builder(UiBuilder::new().max_rect(card.shrink(20.0)), |ui| {
        ui.spacing_mut().item_spacing = vec2(8.0, 10.0);
        let title = match a.mode {
            Mode::Login => "Sign in",
            Mode::Register => "Make an account",
            Mode::Confirm => "Check your email",
            Mode::Forgot => "Forgot your password",
            Mode::Reset => "Set a new password",
            Mode::Server => "Server",
        };
        ui.label(RichText::new(title).font(font(EXTRA, 22.0)).color(INK));
        let full_w = ui.available_width();
        if a.mode == Mode::Server {
            let server = a.server.get_or_insert_with(String::new);
            field(ui, "server address", server, false);
            ui.label(RichText::new("Your own: http://localhost:4000").font(font(MEDIUM, 12.0)).color(INK_DIM));
            if text_button(ui, "Use it", vec2(full_w, 48.0), Tone::Green).clicked() {
                st.set_server(server);
                a.mode = Mode::Login;
            }
            return;
        }
        let mut submit = false;
        submit |= field(ui, "email", &mut a.email, false);
        if a.mode == Mode::Register {
            submit |= field(ui, "handle: what everyone sees", &mut a.handle, false);
            a.handle.retain(|c| c.is_alphanumeric() || c == '_');
            a.handle.truncate(16);
        }
        if a.mode == Mode::Confirm || a.mode == Mode::Reset {
            submit |= field(ui, "6-digit code", &mut a.code, false);
            a.code.retain(|c| c.is_ascii_digit());
            a.code.truncate(6);
        }
        if matches!(a.mode, Mode::Login | Mode::Register | Mode::Reset) {
            let hint = if a.mode == Mode::Login { "password" } else { "password (10+ characters)" };
            submit |= field(ui, hint, &mut a.password, true);
        }
        let label = match a.mode {
            Mode::Login => "Sign in",
            Mode::Register => "Sign up",
            Mode::Confirm => "Confirm",
            Mode::Forgot => "Email me a code",
            Mode::Reset => "Set password",
            Mode::Server => "",
        };
        if text_button(ui, label, vec2(full_w, 48.0), Tone::Green).clicked() || submit {
            let email = a.email.trim().to_owned();
            // the next step comes back with the answer (`auth_step`)
            match a.mode {
                Mode::Login => st.login(&email, &a.password, |st| st.auth_step = Some("confirm")),
                Mode::Register => st.register(&email, &a.handle, &a.password, |st| st.auth_step = Some("confirm")),
                Mode::Confirm => st.confirm(&email, &a.code),
                Mode::Forgot => st.forgot(&email, |st| st.auth_step = Some("reset")),
                Mode::Reset => st.reset(&email, &a.code, &a.password),
                Mode::Server => {}
            }
        }
        ui.horizontal(|ui| {
            let (left, right): (Option<(&str, Mode)>, Option<(&str, Mode)>) = match a.mode {
                Mode::Login => (Some(("New here?", Mode::Register)), Some(("Forgot?", Mode::Forgot))),
                Mode::Register => (Some(("Sign in", Mode::Login)), Some(("Have a code?", Mode::Confirm))),
                Mode::Confirm => (Some(("Sign in", Mode::Login)), None),
                _ => (Some(("Sign in", Mode::Login)), None),
            };
            if let Some((t, m)) = left {
                if link(ui, t).clicked() {
                    a.mode = m;
                }
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if let Some((t, m)) = right {
                    if link(ui, t).clicked() {
                        a.mode = m;
                    }
                }
                if a.mode == Mode::Confirm && link(ui, "Send again").clicked() {
                    st.resend(a.email.trim());
                }
            });
        });
    });

    // the server, under the card
    let server = st.server_url().split("://").nth(1).unwrap_or(st.server_url()).to_owned();
    let label = format!("SERVER · {server}");
    let lw = root.painter().layout_no_wrap(label.clone(), font(TECH, 10.0), TEXT_DIM).size().x + 32.0;
    let br = Rect::from_center_size(pos2(full.center().x, card.bottom() + 40.0), vec2(lw, 40.0));
    root.scope_builder(UiBuilder::new().max_rect(br), |ui| {
        let r = plastic_button(ui, br.size(), Tone::Plastic, true, |p, r, on| {
            p.text(r.center(), Align2::CENTER_CENTER, &label, font(TECH, 10.0), on);
        });
        if r.clicked() {
            v.auth.mode = Mode::Server;
        }
    });
}

/// A labelled paper field; true when Enter was pressed in it.
pub fn field(ui: &mut Ui, hint: &str, text: &mut String, secret: bool) -> bool {
    let edit = egui::TextEdit::singleline(text)
        .hint_text(RichText::new(hint).color(INK_FAINT))
        .password(secret)
        .font(font(MEDIUM, 16.0))
        .text_color(INK)
        .background_color(PAPER_DEEP)
        .margin(egui::Margin::symmetric(14, 10))
        .desired_width(f32::INFINITY);
    let r = ui.add(edit);
    r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter))
}

/// The cube: a grassy block floating over the sea.
fn cube_logo(p: &egui::Painter, r: Rect) {
    use egui::{Color32, Shape, Stroke};
    let c = r.center();
    let s = r.width() / 2.0;
    let top = vec![c + vec2(0.0, -s), c + vec2(s, -s * 0.5), c + vec2(0.0, 0.0), c + vec2(-s, -s * 0.5)];
    let left = vec![c + vec2(-s, -s * 0.5), c, c + vec2(0.0, s), c + vec2(-s, s * 0.5)];
    let right = vec![c + vec2(s, -s * 0.5), c, c + vec2(0.0, s), c + vec2(s, s * 0.5)];
    p.add(Shape::convex_polygon(left, Color32::from_rgb(0xB0, 0x7A, 0x45), Stroke::new(3.0, EDGE)));
    p.add(Shape::convex_polygon(right, Color32::from_rgb(0x8E, 0x5F, 0x34), Stroke::new(3.0, EDGE)));
    p.add(Shape::convex_polygon(top, Color32::from_rgb(0x7C, 0xCB, 0x5A), Stroke::new(3.0, EDGE)));
}
