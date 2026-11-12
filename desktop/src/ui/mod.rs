//! The screens, laid out like the Android app's (`android/.../ui/`): sign
//! in; then the rail of servers with its page (docked beside the chat on a
//! wide window, sliding over it on a narrow one), and the open place: a
//! server's chat and world, or a conversation.

mod auth;
mod chat;
mod drawer;
mod pages;

use egui::{Align2, Area, CornerRadius, Frame, Id, Margin, Order, Rect, RichText, Ui, UiBuilder, pos2, vec2};

use crate::state::{Screen, State};
use crate::theme::{self, *};

/// Wider than this (logical px), the rail and its page stay open beside the chat.
pub const DOCK_W: f32 = 840.0;
/// The rail and its page.
pub const DRAWER_W: f32 = 340.0;

/// What the screens remember between frames that the app state doesn't.
#[derive(Default)]
pub struct View {
    pub auth: auth::Auth,
    pub drawer_open: bool,
    /// In the drawer: conversations rather than the server's page.
    pub dms: bool,
    pub composer: String,
    pub gift: Option<chat::GiftForm>,
    pub big_picture: Option<crate::models::Media>,
    pub friend_field: String,
    pub invite_field: String,
    /// The pocket picked up to swap.
    pub picked: Option<usize>,
    pub last_gen: u64,
}

pub fn draw(root: &mut Ui, st: &mut State, v: &mut View) {
    let ctx = root.ctx().clone();
    let full = root.max_rect();
    theme::ground(root.painter(), full);

    if st.me.is_none() {
        if st.restoring {
            root.scope_builder(UiBuilder::new().max_rect(full), |ui| {
                ui.centered_and_justified(|ui| {
                    ui.label(RichText::new("signing in…").font(font(TECH, 12.0)).color(TEXT_DIM));
                });
            });
        } else {
            auth::draw(root, st, v, full);
        }
        notice(&ctx, st);
        return;
    }

    let docked = full.width() >= DOCK_W;
    let pad = 10.0;
    let body = if docked {
        let rail = Rect::from_min_max(full.min, pos2(full.left() + DRAWER_W, full.bottom()));
        root.scope_builder(UiBuilder::new().max_rect(rail), |ui| drawer::draw(ui, st, v, rail));
        Rect::from_min_max(pos2(rail.right(), full.top()), full.max)
    } else {
        full
    };
    let body = body.shrink2(vec2(pad, 0.0));
    let body = Rect::from_min_max(pos2(body.left(), body.top() + 8.0), pos2(body.right(), body.bottom() - 12.0));
    root.scope_builder(UiBuilder::new().max_rect(body), |ui| match st.screen {
        Screen::Chat => chat::place(ui, st, v, !docked),
        Screen::Explore => pages::explore(ui, st),
        Screen::Friends => pages::friends(ui, st, v),
        Screen::Bag => pages::bag(ui, st, v),
        Screen::Members => pages::members(ui, st, v),
    });

    // narrow: the drawer slides in over everything, the rest dimmed
    if !docked && v.drawer_open {
        let dim = Area::new(Id::unique("drawer-dim")).order(Order::Foreground).fixed_pos(full.min).show(&ctx, |ui| {
            let (r, resp) = ui.allocate_exact_size(full.size(), egui::Sense::click());
            ui.painter().rect_filled(r, 0.0, egui::Color32::from_black_alpha(140));
            resp
        });
        if dim.inner.clicked() {
            v.drawer_open = false;
        }
        Area::new(Id::unique("drawer")).order(Order::Foreground).fixed_pos(full.min).show(&ctx, |ui| {
            let r = Rect::from_min_size(full.min, vec2(DRAWER_W.min(full.width()), full.height()));
            ui.scope_builder(UiBuilder::new().max_rect(r), |ui| {
                ui.set_min_size(r.size());
                drawer::draw(ui, st, v, r)
            });
        });
        if ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
            v.drawer_open = false;
        }
    }

    chat::dialogs(&ctx, st, v);
    notice(&ctx, st);
}

/// The line to show briefly (errors, confirmations), on paper at the bottom.
fn notice(ctx: &egui::Context, st: &State) {
    let Some(text) = st.notice().map(str::to_owned) else { return };
    Area::new(Id::unique("notice")).anchor(Align2::CENTER_BOTTOM, vec2(0.0, -96.0)).order(Order::Tooltip).interactable(false).show(ctx, |ui| {
        Frame::new()
            .fill(PAPER)
            .stroke(egui::Stroke::new(2.0, PAPER_EDGE))
            .corner_radius(CornerRadius::same(14))
            .inner_margin(Margin::symmetric(16, 10))
            .show(ui, |ui| {
                ui.label(RichText::new(text).font(font(BOLD, 14.0)).color(INK));
            });
    });
}

/// A page over the chat: plastic bar with back and a title, then paper.
pub fn page(ui: &mut Ui, st: &mut State, title: &str, body: impl FnOnce(&mut Ui, &mut State)) {
    let r = ui.max_rect();
    let bar = Rect::from_min_size(r.min, vec2(r.width(), 60.0));
    plastic(ui.painter(), bar, 22.0, PANEL, EDGE, 4.0, 0.2);
    ui.scope_builder(UiBuilder::new().max_rect(bar.shrink2(vec2(8.0, 8.0))), |ui| {
        ui.horizontal_centered(|ui| {
            if icon_button(ui, Icon::Back, Tone::Plastic, "back").clicked() {
                st.screen = Screen::Chat;
            }
            ui.label(RichText::new(title).font(font(EXTRA, 20.0)).color(TEXT));
        });
    });
    let sheet = Rect::from_min_max(pos2(r.left(), bar.bottom() + 14.0), r.max);
    paper(ui.painter(), sheet, 24.0);
    ui.scope_builder(UiBuilder::new().max_rect(sheet.shrink(18.0)), |ui| {
        egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
            ui.set_width(ui.available_width());
            body(ui, st)
        });
    });
}

/// A section's heading on paper.
pub fn section(ui: &mut Ui, title: &str) {
    ui.add_space(6.0);
    label(ui, title, INK_FAINT);
}
