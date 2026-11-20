//! The blueprints book, as Android's `Screen.Book`: an egui search field on
//! paper, and under it the game's own 3D book: the same game cart, running
//! in book mode in an instance of its own while the page shows
//! (`stage.rs`). The field filters the book's index (`book_search`); the
//! pages are turned and steps done in the book itself, with the pointer.
//!
//! In a world, the same field sits over the world pane while the world's
//! book is open (the game said `book("open")`), and searches that book.
//! The calls are `client/README.md`'s "The book's calls".

use egui::{Color32, CornerRadius, Id, Rect, RichText, Sense, Stroke, Ui, UiBuilder, pos2, vec2};
use petrichor64::host::Arg;

use super::{View, page_bar};
use crate::stage::Spot;
use crate::state::{GameCart, State};
use crate::theme::*;

/// As long as the game's own search goes (`BOOK_QUERY_MAX` in book.lua).
const QUERY_MAX: usize = 24;

/// The search field. A change is sent to `spot`'s game as `book_search`.
fn search_field(ui: &mut Ui, text: &mut String, spot: &mut Spot, width: f32, salt: &str) -> egui::Response {
    let edit = egui::TextEdit::singleline(text)
        .id_salt(salt)
        .hint_text(RichText::new("search the book: bed, cloth…").color(INK_FAINT))
        .font(font(MEDIUM, 15.0))
        .text_color(INK)
        .background_color(PAPER_DEEP)
        .margin(egui::Margin::symmetric(14, 10))
        .char_limit(QUERY_MAX)
        .desired_width(width);
    let resp = ui.add(edit);
    if resp.changed() {
        spot.call("book_search", vec![Arg::Str(text.clone())]);
    }
    resp
}

/// A recipe's item as words (`cloth_sheet` → "cloth sheet").
fn pretty(item: &str) -> String {
    item.replace('_', " ")
}

pub fn page(ui: &mut Ui, st: &mut State, v: &mut View) {
    let below = page_bar(ui, st, "The book");
    // the field takes the keys when the page comes up
    let pass = ui.ctx().cumulative_pass_nr();
    let fresh = v.book_pass + 1 < pass;
    v.book_pass = pass;

    let strip = Rect::from_min_size(below.min, vec2(below.width(), 64.0));
    paper(ui.painter(), strip, 24.0);
    let (recipe, spread) = st.book.book_step.clone();
    ui.scope_builder(UiBuilder::new().max_rect(strip.shrink2(vec2(14.0, 10.0))), |ui| {
        ui.horizontal_centered(|ui| {
            let in_recipe = !recipe.is_empty();
            let side = if in_recipe { 210.0 } else { 0.0 };
            let w = (ui.available_width() - side).max(120.0);
            let resp = search_field(ui, &mut v.book_query, &mut st.book, w, "book-page-search");
            if fresh {
                resp.request_focus();
            }
            if in_recipe {
                // the search (even unchanged) goes back to the index
                if paper_button(ui, "Index", vec2(84.0, 40.0)).clicked() {
                    st.book.call("book_search", vec![Arg::Str(v.book_query.clone())]);
                }
                let at = if spread == 0 { "overview".to_owned() } else { format!("step {spread}") };
                ui.add(egui::Label::new(RichText::new(format!("{} · {at}", pretty(&recipe))).font(font(BOLD, 13.0)).color(INK_DIM)).truncate());
            }
        });
    });

    let area = Rect::from_min_max(pos2(below.left(), strip.bottom() + 12.0), below.max);
    st.book.rect = Some(area);
    let resp = ui.interact(area, Id::unique("book-pane"), Sense::click_and_drag());
    st.book.hover = resp.hovered() || resp.dragged();
    let p = ui.painter();
    p.rect_filled(area.translate(vec2(0.0, 4.0)), CornerRadius::same(24), EDGE);
    if let Some(tex) = st.book.tex {
        egui::Image::from_texture((tex, area.size())).corner_radius(CornerRadius::same(24)).paint_at(ui, area);
        let edge = if st.book.focus { Color32::from_rgb(0xFF, 0xB0, 0x3A) } else { EDGE };
        ui.painter().rect_stroke(area, CornerRadius::same(24), Stroke::new(3.0, edge), egui::StrokeKind::Inside);
    } else {
        p.rect_filled(area, CornerRadius::same(24), PANEL);
        let line = match (&st.book.status, &st.game) {
            (Some(s), _) => s.clone(),
            (None, GameCart::Failed) => "The game didn't load.".to_owned(),
            _ => "opening the book…".to_owned(),
        };
        p.text(area.center(), egui::Align2::CENTER_CENTER, line, font(MEDIUM, 15.0), TEXT_DIM);
        if matches!(st.game, GameCart::Failed) {
            let b = Rect::from_center_size(pos2(area.center().x, area.center().y + 44.0), vec2(84.0, 40.0));
            ui.scope_builder(UiBuilder::new().max_rect(b), |ui| {
                if text_button(ui, "Again", vec2(84.0, 40.0), Tone::Orange).clicked() {
                    st.retry_game();
                }
            });
        }
    }
}

/// Over the world pane `r`, while the world's book is open: the search
/// field, for that book. Esc in it shuts the book, as in the game.
pub fn over_world(ui: &mut Ui, st: &mut State, v: &mut View, r: Rect) {
    if !st.world.book_open || st.world.tex.is_none() || r.width() < 220.0 || r.height() < 160.0 {
        return;
    }
    let w = (r.width() - 24.0).min(460.0);
    let strip = Rect::from_min_size(pos2(r.center().x - w / 2.0, r.top() + 12.0), vec2(w, 56.0));
    paper(ui.painter(), strip, 18.0);
    // the pointer over the field isn't over the world
    let over = ui.interact(strip, Id::unique("world-book-strip"), Sense::click());
    if over.hovered() || ui.rect_contains_pointer(strip) {
        st.world.hover = false;
    }
    ui.scope_builder(UiBuilder::new().max_rect(strip.shrink2(vec2(10.0, 7.0))), |ui| {
        ui.horizontal_centered(|ui| {
            let fw = ui.available_width();
            let resp = search_field(ui, &mut v.world_query, &mut st.world, fw, "world-book-search");
            if resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                st.world.call("book_close", vec![]);
            }
        });
    });
}
