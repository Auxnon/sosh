//! The open place, as `MainScreen.kt`: the plastic bar on top, then a
//! server (its chat and its world, side by side on a wide window, stacked
//! on a tall one) or a conversation; the tray with the composer at the
//! bottom.

use egui::text::LayoutJob;
use egui::{Align, Align2, Color32, CornerRadius, Frame, Id, Margin, Rect, RichText, Sense, Shape, Stroke, TextFormat, Ui, UiBuilder, pos2, vec2};

use super::View;
use crate::media::Pics;
use crate::models::{Media, Message};
use crate::state::{GameCart, Pane, Place, Screen, State};
use crate::theme::*;

pub struct GiftForm {
    pub item: Option<String>,
    pub count: i64,
    pub to: String,
}

pub fn place(ui: &mut Ui, st: &mut State, v: &mut View, narrow: bool) {
    let r = ui.max_rect();
    let header = Rect::from_min_size(r.min, vec2(r.width(), 60.0));
    header_bar(ui, st, v, header, narrow);
    let below = Rect::from_min_max(pos2(r.left(), header.bottom() + 14.0), r.max);
    match st.place.clone() {
        None => {
            ui.painter().text(below.center(), Align2::CENTER_CENTER, "Pick a server or a friend from the menu.", font(MEDIUM, 15.0), TEXT_DIM);
        }
        Some(Place::InServer(_)) => {
            let tray_h = tray_height(st, true);
            let view = Rect::from_min_max(below.min, pos2(below.right(), below.bottom() - tray_h - 12.0));
            server_view(ui, st, v, view);
            tray(ui, st, v, Rect::from_min_max(pos2(below.left(), view.bottom() + 12.0), below.max), true);
        }
        Some(Place::WithPerson(_)) => {
            let tray_h = tray_height(st, false);
            let view = Rect::from_min_max(below.min, pos2(below.right(), below.bottom() - tray_h - 12.0));
            ui.scope_builder(UiBuilder::new().max_rect(view), |ui| messages(ui, st, v));
            tray(ui, st, v, Rect::from_min_max(pos2(below.left(), view.bottom() + 12.0), below.max), false);
        }
    }
}

fn header_bar(ui: &mut Ui, st: &mut State, v: &mut View, r: Rect, narrow: bool) {
    plastic(ui.painter(), r, 22.0, PANEL, EDGE, 4.0, 0.2);
    ui.scope_builder(UiBuilder::new().max_rect(r.shrink2(vec2(8.0, 8.0))), |ui| {
        ui.horizontal_centered(|ui| {
            if narrow && icon_button(ui, Icon::Menu, Tone::Plastic, "servers").clicked() {
                v.drawer_open = true;
            }
            let in_server = matches!(st.place, Some(Place::InServer(_)));
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing = vec2(0.0, 2.0);
                match st.place.clone() {
                    Some(Place::InServer(id)) => {
                        let s = st.server(id).cloned();
                        ui.label(RichText::new(s.as_ref().map(|s| s.name.as_str()).unwrap_or("server")).font(font(EXTRA, 20.0)).color(TEXT));
                        let line = match (&s, st.online) {
                            (_, false) => "connecting...".to_owned(),
                            (Some(s), true) => format!("universe {},{} · {} members", s.universe.0, s.universe.1, s.members),
                            (None, true) => String::new(),
                        };
                        label(ui, &line, TEXT_DIM);
                    }
                    Some(Place::WithPerson(h)) => {
                        name_tag(ui, &h, 16.0);
                        label(ui, "direct messages", TEXT_DIM);
                    }
                    None => {
                        ui.label(RichText::new("sosh").font(font(EXTRA, 20.0)).color(PAPER));
                    }
                }
            });
            if in_server {
                ui.with_layout(egui::Layout::right_to_left(Align::Center), |ui| {
                    if icon_button(ui, Icon::Group, Tone::Plastic, "members").clicked() {
                        st.screen = Screen::Members;
                    }
                });
            }
        });
    });
}

/// A server: its chat, its world, or both. The world takes the left (on a
/// wide view) or the top (on a tall one) share.
fn server_view(ui: &mut Ui, st: &mut State, v: &mut View, r: Rect) {
    let wide = r.width() > r.height();
    let target = match st.pane {
        Pane::Chat => 0.0,
        Pane::Both => {
            if wide {
                0.6
            } else {
                0.5
            }
        }
        Pane::World => 1.0,
    };
    let share = ui.ctx().animate_value_with_time(Id::unique("world-share"), target, 0.22);
    let shown = share > 0.01;
    let gap = if shown && share < 0.99 { 10.0 } else { 0.0 };
    let across = if wide { r.width() } else { r.height() };
    let world_len = (across * share).round();
    let (world, chat) = if wide {
        (Rect::from_min_size(r.min, vec2(world_len, r.height())), Rect::from_min_max(pos2(r.left() + world_len + gap, r.top()), r.max))
    } else {
        (Rect::from_min_size(r.min, vec2(r.width(), world_len)), Rect::from_min_max(pos2(r.left(), r.top() + world_len + gap), r.max))
    };
    if shown {
        world_pane(ui, st, v, world);
    }
    if share < 0.99 && chat.width() > 40.0 && chat.height() > 40.0 {
        ui.scope_builder(UiBuilder::new().max_rect(chat), |ui| messages(ui, st, v));
    }
}

/// Where the world goes. Until Petrichor64 can run inside the app (its
/// library mode: petrichor64 HANDOFF-host-library.md) it's a window onto
/// the islands that opens the world in the browser.
fn world_pane(ui: &mut Ui, st: &mut State, v: &mut View, r: Rect) {
    st.world.rect = Some(r);
    let resp = ui.interact(r, Id::unique("world"), Sense::click_and_drag());
    st.world.hover = resp.hovered() || resp.dragged();
    let p = ui.painter();
    p.rect_filled(r.translate(vec2(0.0, 4.0)), CornerRadius::same(24), EDGE);
    if let Some(tex) = st.world.tex {
        egui::Image::from_texture((tex, r.size())).corner_radius(CornerRadius::same(24)).paint_at(ui, r);
        let edge = if st.world.focus { Color32::from_rgb(0xFF, 0xB0, 0x3A) } else { EDGE };
        ui.painter().rect_stroke(r, CornerRadius::same(24), Stroke::new(3.0, edge), egui::StrokeKind::Inside);
    } else {
        // sky, sea and islands until the world is running
        p.rect_filled(r, CornerRadius::same(24), Color32::from_rgb(0x8F, 0xC9, 0xF0));
        let sea = Rect::from_min_max(pos2(r.left(), r.top() + r.height() * 0.72), r.max);
        p.rect_filled(sea, CornerRadius { nw: 0, ne: 0, sw: 24, se: 24 }, Color32::from_rgb(0x4A, 0x8F, 0xD0));
        let w = (r.width() * 0.8).min(420.0);
        let banner = Rect::from_center_size(pos2(r.center().x, r.top() + r.height() * 0.42), vec2(w, w * 116.0 / 252.0));
        if banner.height() < r.height() * 0.8 {
            islands(p, banner);
        }
        p.rect_stroke(r, CornerRadius::same(24), Stroke::new(3.0, EDGE), egui::StrokeKind::Inside);
        let failed = matches!(st.game, GameCart::Failed);
        let line = st.world.status.clone().unwrap_or_else(|| "on its way…".into());
        if r.height() > 140.0 && r.width() > 220.0 {
            let card = Rect::from_center_size(pos2(r.center().x, r.bottom() - 54.0), vec2(w.max(220.0).min(r.width() - 24.0), 64.0));
            paper(ui.painter(), card, 18.0);
            ui.scope_builder(UiBuilder::new().max_rect(card.shrink2(vec2(14.0, 10.0))), |ui| {
                ui.horizontal_centered(|ui| {
                    ui.vertical(|ui| {
                        ui.spacing_mut().item_spacing = vec2(0.0, 2.0);
                        ui.label(RichText::new("The world").font(font(EXTRA, 16.0)).color(INK));
                        ui.add(egui::Label::new(RichText::new(line).font(font(MEDIUM, 12.0)).color(INK_DIM)).truncate());
                    });
                    if failed {
                        ui.with_layout(egui::Layout::right_to_left(Align::Center), |ui| {
                            if text_button(ui, "Again", vec2(84.0, 40.0), Tone::Orange).clicked() {
                                st.retry_game();
                            }
                        });
                    }
                });
            });
        }
    }
    // all world: the latest lines over it, as the game's own chat log was
    if st.pane == Pane::World && r.height() > 260.0 {
        let lines: Vec<Message> = st.messages.iter().rev().take(3).rev().cloned().collect();
        if !lines.is_empty() {
            let box_r =
                Rect::from_min_size(pos2(r.left() + 12.0, r.top() + 12.0), vec2((r.width() - 24.0).min(420.0), 30.0 + lines.len() as f32 * 22.0));
            paper(ui.painter(), box_r, 18.0);
            let resp = ui.interact(box_r, Id::unique("world-overlay"), Sense::click());
            let mut y = box_r.top() + 12.0;
            for m in &lines {
                let who = m.author.as_ref().map(|a| a.handle.clone()).unwrap_or("someone".into());
                let mut job = LayoutJob::default();
                job.append(&who, 0.0, TextFormat::simple(font(EXTRA, 13.0), handle_ink(&who)));
                job.append(&format!("  {}", line_text(m)), 0.0, TextFormat::simple(font(MEDIUM, 13.0), INK));
                job.wrap.max_width = box_r.width() - 24.0;
                job.wrap.max_rows = 1;
                let g = ui.painter().layout_job(job);
                ui.painter().galley(pos2(box_r.left() + 12.0, y), g, INK);
                y += 22.0;
            }
            ui.painter().text(pos2(box_r.left() + 12.0, y + 2.0), Align2::LEFT_TOP, "CLICK FOR CHAT", font(TECH, 9.0), INK_FAINT);
            if resp.clicked() {
                st.pane = Pane::Both;
            }
        }
    }
    let _ = v;
}

fn line_text(m: &Message) -> String {
    if let Some(g) = &m.gift {
        format!("a present for {}", g.to.as_ref().map(|t| t.handle.as_str()).unwrap_or("someone"))
    } else if m.body.is_empty() {
        m.media.as_ref().map(|md| md.label()).unwrap_or_default()
    } else {
        m.body.clone()
    }
}

/// The chat as speech bubbles on paper, each with its speaker's name tag.
fn messages(ui: &mut Ui, st: &mut State, v: &mut View) {
    let jump = v.last_gen != st.messages_gen;
    v.last_gen = st.messages_gen;
    let time = ui.input(|i| i.time);
    egui::ScrollArea::vertical().auto_shrink([false, false]).stick_to_bottom(true).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.add_space(18.0);
        if st.messages.len() >= 50 {
            let t = if st.loading_older { "loading..." } else { "Older messages" };
            if ui.add(egui::Label::new(RichText::new(t).font(font(BOLD, 13.0)).color(TEXT_DIM)).sense(Sense::click())).clicked() {
                st.load_older();
            }
        }
        if st.messages.is_empty() {
            ui.label(RichText::new("No messages yet. Say hello!").font(font(MEDIUM, 14.0)).color(TEXT_DIM));
        }
        let list = st.messages.clone();
        for m in &list {
            bubble(ui, st, v, m, time);
            ui.add_space(20.0);
        }
        if jump {
            ui.scroll_to_cursor(Some(Align::BOTTOM));
        }
    });
}

fn bubble(ui: &mut Ui, st: &mut State, v: &mut View, m: &Message, time: f64) {
    let who = m.author.as_ref().map(|a| a.handle.clone()).unwrap_or_else(|| "someone".into());
    // right-click: what can be done with it. Made before what's inside (on
    // last frame's rect), so that it's under the picture, Play and present
    // buttons and they get their clicks.
    let id = ui.scope_id().with(("msg", m.id));
    if let Some(r) = ui.data(|d| d.get_temp::<Rect>(id)) {
        let click = ui.interact(r, id, Sense::click());
        let mine = st.me.as_ref().map(|me| me.id) == m.author.as_ref().map(|a| a.id);
        let moderator = st.open_server().map(|s| s.can("manage_messages")).unwrap_or(false);
        click.context_menu(|ui| {
            if !m.body.is_empty() && ui.button("Copy text").clicked() {
                ui.ctx().copy_text(m.body.clone());
                ui.close();
            }
            if (mine || moderator) && ui.button(RichText::new("Delete").color(DANGER_INK)).clicked() {
                st.delete_message(m.id);
                ui.close();
            }
        });
    }
    let frame = Frame::new()
        .fill(PAPER)
        .corner_radius(CornerRadius::same(22))
        .shadow(egui::epaint::Shadow { offset: [0, 4], blur: 0, spread: 0, color: EDGE })
        .inner_margin(Margin { left: 16, right: 16, top: 18, bottom: 12 });
    let resp = frame
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.spacing_mut().item_spacing = vec2(8.0, 8.0);
            if !m.body.is_empty() {
                let me = st.me.as_ref().map(|m| m.handle.clone());
                ui.label(mentions(&m.body, me.as_deref(), ui.available_width()));
            }
            if let Some(md) = &m.media {
                media_card(ui, st, v, md, time);
            }
            if m.gift.is_some() {
                present_card(ui, st, m);
            }
        })
        .response;
    let r = resp.rect;
    name_tag_at(ui.painter(), pos2(r.left() + 14.0, r.top() - 2.0), &who, 13.0, -3.0);
    ui.painter().text(pos2(r.right() - 14.0, r.top() + 9.0), Align2::RIGHT_TOP, m.time(), font(TECH, 9.0), INK_FAINT);
    ui.data_mut(|d| d.insert_temp(id, r));
}

/// @handles highlighted, ours most of all.
fn mentions(body: &str, me: Option<&str>, width: f32) -> LayoutJob {
    let mut job = LayoutJob::default();
    job.wrap.max_width = width;
    let plain = TextFormat::simple(font(MEDIUM, 15.0), INK);
    let words: Vec<&str> = body.split(' ').collect();
    for (i, w) in words.iter().enumerate() {
        if w.starts_with('@') && w.len() > 1 {
            let name = w[1..].trim_end_matches([',', '.', '!', '?', ':']);
            let is_me = me.map(|m| m.eq_ignore_ascii_case(name)).unwrap_or(false);
            let mut f = TextFormat::simple(font(EXTRA, 15.0), if is_me { ON_ACCENT } else { INK_LINK });
            if is_me {
                f.background = ACCENT;
            }
            job.append(w, 0.0, f);
        } else {
            job.append(w, 0.0, plain.clone());
        }
        if i + 1 < words.len() {
            job.append(" ", 0.0, plain.clone());
        }
    }
    job
}

/// A picture as it was shared (moving ones moving; click for it large), or
/// a cart to play.
fn media_card(ui: &mut Ui, st: &mut State, v: &mut View, m: &Media, time: f64) {
    if m.is_cart() {
        cart_card(ui, st, m);
        return;
    }
    let ratio = (m.w as f32 / m.h as f32).clamp(0.4, 3.0);
    let max_w = ui.available_width().min(320.0);
    let mut w = max_w;
    let mut h = w / ratio;
    if h > 360.0 {
        h = 360.0;
        w = h * ratio;
    }
    let size = vec2(w, h);
    match Pics::frame(st, m, time) {
        Some(tex) => {
            let img = egui::Image::new(&tex).fit_to_exact_size(size).corner_radius(CornerRadius::same(16)).sense(Sense::click());
            let r = ui.add(img);
            ui.painter().rect_stroke(r.rect, CornerRadius::same(16), Stroke::new(2.0, PAPER_EDGE), egui::StrokeKind::Inside);
            if r.hovered() {
                ui.ctx().set_cursor_icon(egui::CursorIcon::ZoomIn);
            }
            if r.clicked() {
                v.big_picture = Some(m.clone());
            }
        }
        None => {
            let (r, _) = ui.allocate_exact_size(size, Sense::hover());
            ui.painter().rect(r, CornerRadius::same(16), PAPER_DEEP, Stroke::new(2.0, PAPER_EDGE), egui::StrokeKind::Inside);
            let failed = Pics::failed(st, &m.key);
            let t = if failed { "couldn't load the picture" } else { "loading…" };
            ui.painter().text(r.center(), Align2::CENTER_CENTER, t, font(MEDIUM, 13.0), INK_FAINT);
        }
    }
}

fn cart_card(ui: &mut Ui, st: &mut State, m: &Media) {
    Frame::new().fill(PAPER_DEEP).stroke(Stroke::new(2.0, PAPER_EDGE)).corner_radius(CornerRadius::same(18)).inner_margin(Margin::same(10)).show(
        ui,
        |ui| {
            ui.set_width(ui.available_width().min(420.0));
            ui.horizontal(|ui| {
                let (r, _) = ui.allocate_exact_size(vec2(34.0, 40.0), Sense::hover());
                cartridge(ui.painter(), r);
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing = vec2(0.0, 2.0);
                    ui.label(RichText::new(m.label()).font(font(EXTRA, 15.0)).color(INK));
                    ui.label(RichText::new(format!("a Petrichor64 game · {} KB", m.size / 1024)).font(font(MEDIUM, 12.0)).color(INK_DIM));
                });
                ui.with_layout(egui::Layout::right_to_left(Align::Center), |ui| {
                    let r = plastic_button(ui, vec2(92.0, 40.0), Tone::Orange, true, |p, r, on| {
                        Icon::Play.paint(p, Rect::from_center_size(pos2(r.left() + 24.0, r.center().y), vec2(16.0, 16.0)), on);
                        p.text(pos2(r.left() + 40.0, r.center().y), Align2::LEFT_CENTER, "Play", font(EXTRA, 15.0), on);
                    });
                    if r.on_hover_text("plays here, fenced off from sosh and your files").clicked() {
                        st.play_cart(m);
                    }
                });
            });
        },
    );
}

/// A present: wrapped for everyone, opened by the one it's for. Its sender
/// sees what's in it and can take it back until then.
fn present_card(ui: &mut Ui, st: &mut State, m: &Message) {
    let Some(g) = m.gift.clone() else { return };
    let me = st.me.as_ref().map(|m| m.id);
    let for_me = me.is_some() && g.to.as_ref().map(|t| t.id) == me;
    let mine = me.is_some() && m.author.as_ref().map(|a| a.id) == me;
    let under = ui.painter().add(Shape::Noop);
    let inner = Frame::new().inner_margin(Margin::same(10)).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            let (r, _) = ui.allocate_exact_size(vec2(38.0, 38.0), Sense::hover());
            present(ui.painter(), r, if g.state == "sealed" { 1.0 } else { 0.45 });
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing = vec2(0.0, 2.0);
                let to = g.to.as_ref().map(|t| t.handle.clone()).unwrap_or("someone".into());
                ui.label(RichText::new(format!("A present for {to}")).font(font(EXTRA, 15.0)).color(INK));
                let inside = g.item.as_ref().map(|i| format!("{} {}", g.count.unwrap_or(1), i));
                let line = match g.state.as_str() {
                    "opened" => inside.map(|i| format!("opened: {i}")).unwrap_or("opened".into()),
                    "returned" => "taken back".into(),
                    _ => match (mine, inside) {
                        (true, Some(i)) => format!("wrapped: {i}"),
                        _ => "still wrapped".into(),
                    },
                };
                ui.label(RichText::new(line).font(font(MEDIUM, 12.0)).color(INK_DIM));
            });
            ui.with_layout(egui::Layout::right_to_left(Align::Center), |ui| {
                if g.state == "sealed" && for_me && text_button(ui, "Open", vec2(76.0, 38.0), Tone::Orange).clicked() {
                    st.claim(m);
                }
                if g.state == "sealed" && mine && link(ui, "Take back").clicked() {
                    st.cancel(m);
                }
            });
        });
    });
    let r = inner.response.rect;
    ui.painter().set(under, egui::epaint::RectShape::filled(r, CornerRadius::same(18), PAPER_DEEP));
    dashed_rect(ui.painter(), r.shrink(1.0), PAPER_EDGE);
}

fn tray_height(st: &State, in_server: bool) -> f32 {
    let _ = st;
    let composer = 44.0;
    let panes = if in_server { 46.0 + 10.0 } else { 0.0 };
    composer + panes + 20.0 + suggestions_height()
}

fn suggestions_height() -> f32 {
    0.0
}

/// Typing, the present and picture buttons, and (in a server) Chat / Both / World.
fn tray(ui: &mut Ui, st: &mut State, v: &mut View, r: Rect, panes: bool) {
    plastic(ui.painter(), r, 24.0, PANEL, EDGE, 4.0, 0.2);
    ui.scope_builder(UiBuilder::new().max_rect(r.shrink(10.0)), |ui| {
        ui.spacing_mut().item_spacing = vec2(6.0, 10.0);
        composer(ui, st, v);
        if panes {
            pane_bar(ui, st);
        }
    });
}

fn composer(ui: &mut Ui, st: &mut State, v: &mut View) {
    // @mentions offered from the members, over the field
    let partial = v.composer.rsplit(' ').next().filter(|w| w.starts_with('@')).map(|w| w[1..].to_owned());
    if let Some(partial) = partial {
        let me = st.me.as_ref().map(|m| m.handle.clone()).unwrap_or_default();
        let names: Vec<String> = match &st.place {
            Some(Place::InServer(_)) => st.members.iter().filter(|m| m.status == "member").map(|m| m.person.handle.clone()).collect(),
            Some(Place::WithPerson(h)) => vec![h.clone()],
            None => vec![],
        };
        let matches: Vec<String> = names.into_iter().filter(|h| *h != me && h.to_lowercase().starts_with(&partial.to_lowercase())).take(8).collect();
        if !matches.is_empty() {
            egui::Area::new(Id::unique("mentions")).order(egui::Order::Foreground).fixed_pos(ui.max_rect().left_top() - vec2(0.0, 40.0)).show(
                ui.ctx(),
                |ui| {
                    ui.horizontal(|ui| {
                        for h in matches {
                            if name_tag(ui, &h, 14.0).clicked() {
                                let cut = v.composer.len() - partial.len() - 1;
                                v.composer.truncate(cut);
                                v.composer.push_str(&format!("@{h} "));
                            }
                        }
                    });
                },
            );
        }
    }
    ui.horizontal(|ui| {
        if plastic_button(ui, vec2(44.0, 44.0), Tone::Plastic, true, |p, r, _| {
            Icon::Gift.paint(p, r.shrink(11.0), Color32::from_rgb(0xFF, 0xC5, 0x66))
        })
        .on_hover_text("send a present")
        .clicked()
        {
            let to = match &st.place {
                Some(Place::WithPerson(h)) => h.clone(),
                _ => String::new(),
            };
            v.gift = Some(GiftForm { item: st.bag_totals().first().map(|t| t.0.clone()), count: 1, to });
        }
        let icon = if st.sharing { Icon::Hourglass } else { Icon::Picture };
        if plastic_button(ui, vec2(44.0, 44.0), Tone::Plastic, true, |p, r, _| icon.paint(p, r.shrink(11.0), Color32::from_rgb(0x9F, 0xE3, 0xD0)))
            .on_hover_text("share a picture or a game (or drop one on the window)")
            .clicked()
            && !st.sharing
        {
            pick_file(st);
        }
        let send_w = 44.0;
        let field_w = ui.available_width() - send_w - 6.0;
        let edit = egui::TextEdit::singleline(&mut v.composer)
            .hint_text(RichText::new("Say something…").color(INK_FAINT))
            .font(font(MEDIUM, 15.0))
            .text_color(INK)
            .background_color(PAPER)
            .margin(Margin::symmetric(16, 12))
            .char_limit(2000)
            .desired_width(field_w);
        let resp = ui.add_sized(vec2(field_w, 44.0), edit);
        let enter = resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        let send = plastic_button(ui, vec2(send_w, 44.0), Tone::Orange, true, |p, r, on| Icon::Send.paint(p, r.shrink(12.0), on))
            .on_hover_text("send")
            .clicked();
        if (enter || send) && !v.composer.trim().is_empty() {
            let text = v.composer.trim().to_owned();
            st.post(&text, None, None);
            v.composer.clear();
            resp.request_focus();
        }
    });
}

/// Ask for a picture (or a .game.png) to share. The dialog runs on a
/// thread, except on macOS, where it must be on the main one.
fn pick_file(st: &mut State) {
    let dialog = || {
        rfd::FileDialog::new()
            .set_title("Share a picture or a game")
            .add_filter("Pictures and games", &["png", "jpg", "jpeg", "gif", "webp"])
            .pick_file()
    };
    #[cfg(target_os = "macos")]
    {
        if let Some(p) = dialog() {
            st.share_path(&p);
        }
    }
    #[cfg(not(target_os = "macos"))]
    st.spawn(move |_| {
        let picked = dialog();
        Box::new(move |st: &mut State| {
            if let Some(p) = picked {
                st.share_path(&p);
            }
        })
    });
}

/// Chat, both, or the world: one click between them.
fn pane_bar(ui: &mut Ui, st: &mut State) {
    let options = [(Pane::Chat, "CHAT", Icon::Chat), (Pane::Both, "BOTH", Icon::Split), (Pane::World, "WORLD", Icon::Globe)];
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing = vec2(8.0, 0.0);
        let w = (ui.available_width() - 16.0) / 3.0;
        for (pane, text, icon) in options {
            let on = st.pane == pane;
            let r = plastic_button(ui, vec2(w, 46.0), if on { Tone::Green } else { Tone::Plastic }, true, |p, r, c| {
                let tw = p.layout_no_wrap(text.to_owned(), font(TECH, 11.0), c).size().x;
                let x0 = r.center().x - (tw + 26.0) / 2.0;
                icon.paint(p, Rect::from_min_size(pos2(x0, r.center().y - 9.0), vec2(18.0, 18.0)), c);
                p.text(pos2(x0 + 26.0, r.center().y), Align2::LEFT_CENTER, text, font(TECH, 11.0), c);
            });
            if r.clicked() {
                st.pane = pane;
            }
        }
    });
}

/// What floats over everything: a cart being played, a picture large, the
/// present form.
pub fn dialogs(ctx: &egui::Context, st: &mut State, v: &mut View) {
    if st.playing.is_some() {
        cart_window(ctx, st);
    }
    if let Some(m) = v.big_picture.clone() {
        let screen = ctx.content_rect();
        let mut close = ctx.input(|i| i.key_pressed(egui::Key::Escape));
        egui::Area::new(Id::unique("big-picture")).order(egui::Order::Foreground).fixed_pos(screen.min).show(ctx, |ui| {
            let (r, resp) = ui.allocate_exact_size(screen.size(), Sense::click());
            ui.painter().rect_filled(r, 0.0, Color32::from_rgba_unmultiplied(0x12, 0x0F, 0x2A, 0xE6));
            let time = ui.input(|i| i.time);
            if let Some(tex) = Pics::frame(st, &m, time) {
                let avail = r.shrink(24.0).size();
                let ratio = m.w as f32 / m.h as f32;
                let mut size = vec2(avail.x, avail.x / ratio);
                if size.y > avail.y {
                    size = vec2(avail.y * ratio, avail.y);
                }
                let at = Rect::from_center_size(r.center(), size);
                egui::Image::new(&tex).paint_at(ui, at);
            }
            if resp.clicked() {
                close = true;
            }
        });
        if close {
            v.big_picture = None;
        }
    }

    let mut done = false;
    if let Some(g) = v.gift.as_mut() {
        let have = st.bag_totals();
        let fixed_to = matches!(st.place, Some(Place::WithPerson(_)));
        let modal =
            egui::Modal::new(Id::unique("gift")).frame(Frame::new().fill(PAPER).corner_radius(CornerRadius::same(24)).inner_margin(Margin::same(20)));
        let resp = modal.show(ctx, |ui| {
            ui.set_width(360.0);
            ui.label(RichText::new("Wrap a present").font(font(EXTRA, 22.0)).color(INK));
            ui.label(RichText::new("Everyone here sees it; only they can open it.").font(font(MEDIUM, 13.0)).color(INK_DIM));
            ui.add_space(6.0);
            if have.is_empty() {
                ui.label(RichText::new("Your pockets are empty.").font(font(MEDIUM, 14.0)).color(INK_DIM));
            }
            ui.horizontal_wrapped(|ui| {
                for (item, n) in &have {
                    let on = g.item.as_deref() == Some(item.as_str());
                    let text = RichText::new(format!("{item} ×{n}")).font(font(BOLD, 14.0)).color(if on { ON_GOOD } else { INK });
                    let b = egui::Button::new(text).fill(if on { GOOD } else { PAPER_DEEP }).corner_radius(CornerRadius::same(12));
                    if ui.add(b).clicked() {
                        g.item = Some(item.clone());
                        g.count = g.count.min(*n).max(1);
                    }
                }
            });
            let max = g.item.as_ref().and_then(|i| have.iter().find(|h| &h.0 == i)).map(|h| h.1).unwrap_or(1);
            ui.horizontal(|ui| {
                ui.label(RichText::new("how many").font(font(BOLD, 14.0)).color(INK));
                ui.add(egui::DragValue::new(&mut g.count).range(1..=max.max(1)));
            });
            if !fixed_to {
                super::auth::field(ui, "for @handle", &mut g.to, false);
            } else {
                ui.horizontal(|ui| {
                    ui.label(RichText::new("for").font(font(BOLD, 14.0)).color(INK));
                    name_tag(ui, &g.to, 14.0);
                });
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if link(ui, "Cancel").clicked() {
                    done = true;
                }
                ui.with_layout(egui::Layout::right_to_left(Align::Center), |ui| {
                    let ok = g.item.is_some() && !g.to.trim().trim_start_matches('@').is_empty();
                    let r = plastic_button(ui, vec2(110.0, 44.0), Tone::Orange, ok, |p, r, on| {
                        p.text(r.center(), Align2::CENTER_CENTER, "Wrap it", font(EXTRA, 15.0), on);
                    });
                    if r.clicked() && ok {
                        let to = g.to.trim().trim_start_matches('@').to_owned();
                        st.post("", None, Some((g.item.clone().unwrap_or_default(), g.count, to)));
                        done = true;
                    }
                });
            });
        });
        if resp.should_close() {
            done = true;
        }
    }
    if done {
        v.gift = None;
    }
}

/// A shared cart, running in the app in a window of its own over a dimmed
/// chat: Esc or the cross closes it (and stops it).
fn cart_window(ctx: &egui::Context, st: &mut State) {
    let Some(name) = st.playing.as_ref().map(|p| p.media.label()) else { return };
    let screen = ctx.content_rect();
    let mut close = false;
    egui::Area::new(Id::unique("cart-window")).order(egui::Order::Foreground).fixed_pos(screen.min).show(ctx, |ui| {
        let (all, _) = ui.allocate_exact_size(screen.size(), Sense::click());
        ui.painter().rect_filled(all, 0.0, Color32::from_rgba_unmultiplied(0x12, 0x0F, 0x2A, 0xD0));
        // 4:3 like the engine's own window, as big as fits under a bar
        let bar_h = 52.0;
        let avail = all.shrink(28.0);
        let mut size = vec2(avail.width(), avail.width() * 0.75);
        if size.y + bar_h > avail.height() {
            size = vec2((avail.height() - bar_h) / 0.75, avail.height() - bar_h);
        }
        let frame = Rect::from_center_size(all.center(), vec2(size.x, size.y + bar_h));
        paper(ui.painter(), frame.expand(8.0), 26.0);
        let bar = Rect::from_min_size(frame.min, vec2(frame.width(), bar_h));
        let game = Rect::from_min_max(pos2(frame.left(), bar.bottom()), frame.max);
        ui.scope_builder(UiBuilder::new().max_rect(bar.shrink2(vec2(8.0, 6.0))), |ui| {
            ui.horizontal_centered(|ui| {
                let (c, _) = ui.allocate_exact_size(vec2(26.0, 30.0), Sense::hover());
                cartridge(ui.painter(), c);
                ui.label(RichText::new(name).font(font(EXTRA, 17.0)).color(INK));
                ui.label(RichText::new("fenced off: no network, no files").font(font(MEDIUM, 12.0)).color(INK_FAINT));
                ui.with_layout(egui::Layout::right_to_left(Align::Center), |ui| {
                    if icon_button(ui, Icon::Close, Tone::Plastic, "close").clicked() {
                        close = true;
                    }
                });
            });
        });
        st.play.rect = Some(game);
        let resp = ui.interact(game, Id::unique("cart-game"), Sense::click_and_drag());
        st.play.hover = resp.hovered() || resp.dragged();
        ui.painter().rect_filled(game, CornerRadius::same(12), Color32::BLACK);
        if let Some(tex) = st.play.tex {
            egui::Image::from_texture((tex, game.size())).corner_radius(CornerRadius::same(12)).paint_at(ui, game);
        } else {
            let line = st.play.status.clone().unwrap_or_else(|| "loading…".into());
            ui.painter().text(game.center(), Align2::CENTER_CENTER, line, font(TECH, 12.0), TEXT_DIM);
        }
    });
    // Esc closes it even while the cart has the keys: the way out can't be a cart's to take
    if close || ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
        st.stop_cart();
    }
}
