//! The rail of servers (memory-card slots) and shortcuts, and the page
//! beside it: the open server, or the conversations. As `Drawer` in
//! `MainScreen.kt`.

use egui::{Align2, Color32, CornerRadius, Rect, RichText, Sense, Ui, UiBuilder, pos2, vec2};

use super::View;
use crate::state::{Pane, Place, Screen, State};
use crate::theme::*;

pub fn draw(ui: &mut Ui, st: &mut State, v: &mut View, r: Rect) {
    let r = Rect::from_min_max(pos2(r.left() + 10.0, r.top() + 8.0), pos2(r.right(), r.bottom() - 12.0));
    let rail = Rect::from_min_size(r.min, vec2(68.0, r.height()));
    let page = Rect::from_min_max(pos2(rail.right() + 10.0, r.top()), r.max);
    plastic(ui.painter(), rail, 24.0, PANEL, EDGE, 4.0, 0.2);
    ui.scope_builder(UiBuilder::new().max_rect(rail.shrink2(vec2(0.0, 12.0))), |ui| rail_contents(ui, st, v));
    paper(ui.painter(), page, 24.0);
    ui.scope_builder(UiBuilder::new().max_rect(page), |ui| page_contents(ui, st, v, page));
}

fn rail_contents(ui: &mut Ui, st: &mut State, v: &mut View) {
    ui.vertical_centered(|ui| {
        ui.spacing_mut().item_spacing = vec2(0.0, 12.0);
        if icon_button(ui, Icon::Mail, if v.dms { Tone::Green } else { Tone::Plastic }, "direct messages").clicked() {
            v.dms = true;
        }
        ui.label(RichText::new("SLOTS").font(font(TECH, 8.0)).color(TEXT_DIM));
        let bottom = 3.0 * 60.0;
        let h = (ui.available_height() - bottom).max(60.0);
        egui::ScrollArea::vertical().max_height(h).auto_shrink([false, true]).show(ui, |ui| {
            ui.vertical_centered(|ui| {
                ui.spacing_mut().item_spacing = vec2(0.0, 12.0);
                let slots: Vec<(i64, String)> = st.servers.iter().filter(|s| s.is_member()).map(|s| (s.id, s.name.clone())).collect();
                for (id, name) in slots {
                    let on = !v.dms && st.place == Some(Place::InServer(id));
                    if memory_slot(ui, &name, on).clicked() {
                        v.dms = false;
                        st.open(Some(Place::InServer(id)));
                        v.drawer_open = false;
                    }
                }
                let (r, resp) = ui.allocate_exact_size(vec2(48.0, 48.0), Sense::click());
                dashed_rect(ui.painter(), r, OUTLINE);
                Icon::Plus.paint(ui.painter(), r.shrink(14.0), Color32::from_rgb(0x9F, 0xE3, 0x8A));
                if resp.on_hover_text("find servers").clicked() {
                    st.screen = Screen::Explore;
                    v.drawer_open = false;
                }
            });
        });
        ui.with_layout(egui::Layout::bottom_up(egui::Align::Center), |ui| {
            ui.spacing_mut().item_spacing = vec2(0.0, 10.0);
            for (icon, hint, screen) in [(Icon::Backpack, "pockets", Screen::Bag), (Icon::People, "friends", Screen::Friends)] {
                let (r, resp) = ui.allocate_exact_size(vec2(48.0, 48.0), Sense::click());
                if resp.hovered() {
                    ui.painter().rect_filled(r, CornerRadius::same(24), PANEL_HI);
                }
                icon.paint(ui.painter(), r.shrink(13.0), TEXT_DIM);
                if resp.on_hover_text(hint).clicked() {
                    st.screen = screen;
                    v.drawer_open = false;
                }
            }
        });
    });
}

/// A server as a memory card: its colour, its initials; the open one is ringed.
fn memory_slot(ui: &mut Ui, name: &str, on: bool) -> egui::Response {
    let (r, resp) = ui.allocate_exact_size(vec2(48.0, 56.0), Sense::click());
    let p = ui.painter();
    plastic(p, r, 12.0, handle_color(name), EDGE, 3.0, 0.45);
    if on {
        p.rect_stroke(r.expand(3.0), CornerRadius::same(14), egui::Stroke::new(3.0, TEXT), egui::StrokeKind::Middle);
    }
    p.rect_filled(
        Rect::from_center_size(pos2(r.center().x, r.bottom() - 28.0), vec2(30.0, 6.0)),
        CornerRadius::same(3),
        Color32::from_rgba_unmultiplied(0x1A, 0x15, 0x40, 0x4D),
    );
    p.text(pos2(r.center().x, r.bottom() - 14.0), Align2::CENTER_CENTER, initials(name), font(EXTRA, 16.0), Color32::from_rgb(0x2A, 0x1F, 0x14));
    if resp.hovered() {
        ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
    }
    resp.on_hover_text(name)
}

fn page_contents(ui: &mut Ui, st: &mut State, v: &mut View, page: Rect) {
    let footer_h = 48.0;
    let body = Rect::from_min_max(page.min, pos2(page.right(), page.bottom() - footer_h));
    ui.scope_builder(UiBuilder::new().max_rect(body), |ui| {
        if v.dms {
            dm_list(ui, st, v);
        } else if let Some(s) = st.open_server().cloned() {
            let banner = Rect::from_min_size(page.min, vec2(page.width(), 116.0));
            island_banner(ui.painter(), banner);
            ui.add_space(116.0 + 14.0);
            ui.scope_builder(
                UiBuilder::new()
                    .max_rect(Rect::from_min_max(pos2(page.left() + 18.0, banner.bottom() + 14.0), pos2(page.right() - 18.0, body.bottom()))),
                |ui| {
                    egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                        ui.spacing_mut().item_spacing = vec2(8.0, 6.0);
                        label(
                            ui,
                            &format!("universe {},{} · {} · {}", s.universe.0, s.universe.1, s.policy, s.role.clone().unwrap_or("member".into())),
                            INK_FAINT,
                        );
                        ui.label(RichText::new(&s.name).font(font(EXTRA, 24.0)).color(INK));
                        if !s.description.is_empty() {
                            ui.label(RichText::new(&s.description).font(font(MEDIUM, 13.0)).color(INK_DIM));
                        }
                        ui.add_space(6.0);
                        let w = ui.available_width();
                        if text_button(ui, "Enter the world", vec2(w, 46.0), Tone::Orange).clicked() {
                            st.pane = Pane::World;
                            st.screen = Screen::Chat;
                            v.drawer_open = false;
                        }
                        if paper_button(ui, "Members", vec2(w, 46.0)).clicked() {
                            st.screen = Screen::Members;
                            v.drawer_open = false;
                        }
                        let people: Vec<String> =
                            st.members.iter().filter(|m| m.status == "member").take(12).map(|m| m.person.handle.clone()).collect();
                        if !people.is_empty() {
                            ui.add_space(8.0);
                            label(ui, "members", INK_FAINT);
                            ui.horizontal_wrapped(|ui| {
                                for h in people {
                                    name_tag(ui, &h, 13.0);
                                }
                            });
                        }
                    });
                },
            );
        } else {
            ui.add_space(18.0);
            ui.horizontal(|ui| {
                ui.add_space(18.0);
                ui.vertical(|ui| {
                    ui.label(RichText::new("Servers").font(font(EXTRA, 22.0)).color(INK));
                    ui.label(RichText::new("Pick one from the rail, or + to find more.").font(font(MEDIUM, 13.0)).color(INK_DIM));
                });
            });
        }
    });
    // you, and signing out
    let foot = Rect::from_min_max(pos2(page.left(), page.bottom() - footer_h), page.max);
    let p = ui.painter();
    p.extend(egui::Shape::dashed_line(&[foot.left_top(), foot.right_top()], egui::Stroke::new(2.0, Color32::from_rgb(0xE3, 0xCC, 0x98)), 12.0, 8.0));
    ui.scope_builder(UiBuilder::new().max_rect(foot.shrink2(vec2(18.0, 6.0))), |ui| {
        ui.horizontal_centered(|ui| {
            if let Some(me) = st.me.clone() {
                ui.label(RichText::new(&me.handle).font(font(EXTRA, 15.0)).color(handle_ink(&me.handle)));
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if link(ui, "Sign out").clicked() {
                    st.logout();
                }
                let dot = if st.online { GOOD } else { BAD };
                let (r, _) = ui.allocate_exact_size(vec2(10.0, 10.0), Sense::hover());
                ui.painter().circle_filled(r.center(), 4.0, dot);
            });
        });
    });
}

fn dm_list(ui: &mut Ui, st: &mut State, v: &mut View) {
    ui.add_space(18.0);
    ui.horizontal(|ui| {
        ui.add_space(18.0);
        ui.vertical(|ui| {
            label(ui, "conversations", INK_FAINT);
            ui.label(RichText::new("Direct messages").font(font(EXTRA, 22.0)).color(INK));
        });
    });
    // friends first (each with its conversation, if there is one), then anyone else we've talked to
    let mut rows: Vec<(String, Option<String>)> = st
        .friends
        .friends
        .iter()
        .map(|f| {
            let last = st.conversations.iter().find(|c| c.with.handle == f.handle).and_then(|c| c.last.as_ref()).map(|m| preview(m));
            (f.handle.clone(), last)
        })
        .collect();
    for c in &st.conversations {
        if !st.friends.friends.iter().any(|f| f.handle == c.with.handle) {
            rows.push((c.with.handle.clone(), c.last.as_ref().map(preview)));
        }
    }
    egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
        ui.add_space(4.0);
        if rows.is_empty() {
            ui.horizontal(|ui| {
                ui.add_space(18.0);
                ui.label(RichText::new("Add friends to talk to them here.").font(font(MEDIUM, 13.0)).color(INK_DIM));
            });
        }
        for (handle, last) in rows {
            let on = st.place == Some(Place::WithPerson(handle.clone()));
            let under = ui.painter().add(egui::Shape::Noop);
            let resp = ui
                .horizontal(|ui| {
                    ui.add_space(18.0);
                    ui.vertical(|ui| {
                        ui.add_space(6.0);
                        name_tag(ui, &handle, 13.0);
                        if let Some(l) = &last {
                            let t: String = l.chars().take(40).collect();
                            ui.label(RichText::new(t).font(font(MEDIUM, 12.0)).color(INK_DIM));
                        }
                        ui.add_space(4.0);
                    });
                })
                .response;
            let row = Rect::from_min_max(pos2(resp.rect.left() + 8.0, resp.rect.top()), pos2(ui.max_rect().right() - 8.0, resp.rect.bottom()));
            let click = ui.interact(row, ui.scope_id().with(("dm", &handle)), Sense::click());
            if on || click.hovered() {
                let fill = if on { PAPER_DEEP } else { PAPER_DEEP.gamma_multiply(0.6) };
                let stroke = egui::Stroke::new(if on { 2.0 } else { 0.0 }, PAPER_EDGE);
                ui.painter().set(under, egui::epaint::RectShape::new(row, CornerRadius::same(12), fill, stroke, egui::StrokeKind::Inside));
            }
            if click.hovered() {
                ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
            }
            if click.clicked() {
                st.open(Some(Place::WithPerson(handle.clone())));
                v.drawer_open = false;
            }
        }
    });
}

fn preview(m: &crate::models::Message) -> String {
    if !m.body.is_empty() {
        m.body.clone()
    } else if let Some(md) = &m.media {
        md.label()
    } else if m.gift.is_some() {
        "a present".into()
    } else {
        String::new()
    }
}
