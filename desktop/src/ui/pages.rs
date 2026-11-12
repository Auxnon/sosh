//! The pages over the chat, as `Screens.kt`: finding servers, friends, the
//! pockets, a server's members.

use egui::{Align, Align2, Color32, CornerRadius, Rect, RichText, Sense, Stroke, Ui, vec2};

use super::{View, page, section};
use crate::state::{Place, Screen, State};
use crate::theme::*;

fn row(ui: &mut Ui, left: impl FnOnce(&mut Ui), right: impl FnOnce(&mut Ui)) {
    ui.horizontal(|ui| {
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing = vec2(0.0, 2.0);
            left(ui)
        });
        ui.with_layout(egui::Layout::right_to_left(Align::Center), right);
    });
}

fn small(ui: &mut Ui, text: &str) {
    ui.label(RichText::new(text).font(font(MEDIUM, 13.0)).color(INK_DIM));
}

pub fn explore(ui: &mut Ui, st: &mut State) {
    page(ui, st, "Servers", |ui, st| {
        small(ui, "Each server is a universe of floating islands, with its own chat.");
        ui.add_space(8.0);
        let all = st.servers.clone();
        for s in all {
            row(
                ui,
                |ui| {
                    ui.label(RichText::new(&s.name).font(font(EXTRA, 17.0)).color(INK));
                    let who = match s.status.as_deref() {
                        Some("member") => "you're in".to_owned(),
                        Some("pending") => "asked to join".to_owned(),
                        Some("invited") => "you're invited".to_owned(),
                        Some("banned") => "banned".to_owned(),
                        _ => format!("{} · {} members", s.policy, s.members),
                    };
                    label(ui, &format!("universe {},{} · {who}", s.universe.0, s.universe.1), INK_FAINT);
                    if !s.description.is_empty() {
                        small(ui, &s.description);
                    }
                },
                |ui| match s.status.as_deref() {
                    Some("member") => {
                        if text_button(ui, "Open", vec2(80.0, 40.0), Tone::Green).clicked() {
                            st.open(Some(Place::InServer(s.id)));
                        }
                        if link(ui, "Leave").clicked() {
                            st.leave(&s);
                        }
                    }
                    Some("banned") | Some("pending") => {}
                    Some("invited") => {
                        if text_button(ui, "Accept", vec2(90.0, 40.0), Tone::Orange).clicked() {
                            st.join(&s);
                        }
                    }
                    _ => {
                        let t = if s.policy == "open" { "Join" } else { "Ask" };
                        if text_button(ui, t, vec2(80.0, 40.0), Tone::Orange).clicked() {
                            st.join(&s);
                        }
                    }
                },
            );
            ui.separator();
        }
    });
}

pub fn friends(ui: &mut Ui, st: &mut State, v: &mut View) {
    page(ui, st, "Friends", |ui, st| {
        ui.horizontal(|ui| {
            let w = ui.available_width() - 90.0;
            let edit = egui::TextEdit::singleline(&mut v.friend_field)
                .hint_text(RichText::new("@handle").color(INK_FAINT))
                .font(font(MEDIUM, 15.0))
                .text_color(INK)
                .background_color(PAPER_DEEP)
                .margin(egui::Margin::symmetric(14, 10))
                .desired_width(w);
            let r = ui.add(edit);
            let enter = r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
            if text_button(ui, "Add", vec2(80.0, 40.0), Tone::Green).clicked() || enter {
                let h = v.friend_field.clone();
                st.add_friend(&h);
                v.friend_field.clear();
            }
        });
        let f = st.friends.clone();
        if !f.incoming.is_empty() {
            section(ui, "asking you");
            for p in &f.incoming {
                row(
                    ui,
                    |ui| {
                        name_tag(ui, &p.handle, 14.0);
                    },
                    |ui| {
                        if link(ui, "No").clicked() {
                            st.remove_friend(&p.handle);
                        }
                        if text_button(ui, "Yes", vec2(70.0, 38.0), Tone::Green).clicked() {
                            st.accept_friend(&p.handle);
                        }
                    },
                );
            }
        }
        section(ui, "friends");
        if f.friends.is_empty() {
            small(ui, "No friends yet: add someone by their handle.");
        }
        for p in &f.friends {
            row(
                ui,
                |ui| {
                    name_tag(ui, &p.handle, 14.0);
                },
                |ui| {
                    if link(ui, "Unfriend").clicked() {
                        st.remove_friend(&p.handle);
                    }
                    if text_button(ui, "Message", vec2(100.0, 38.0), Tone::Plastic).clicked() {
                        st.open(Some(Place::WithPerson(p.handle.clone())));
                        v.dms = true;
                    }
                },
            );
        }
        if !f.outgoing.is_empty() {
            section(ui, "asked");
            for p in &f.outgoing {
                row(
                    ui,
                    |ui| {
                        name_tag(ui, &p.handle, 14.0);
                    },
                    |ui| {
                        if link(ui, "Cancel").clicked() {
                            st.remove_friend(&p.handle);
                        }
                    },
                );
            }
        }
    });
}

/// The pockets: click one to put it in hand in the world; click two in
/// turn to swap them.
pub fn bag(ui: &mut Ui, st: &mut State, v: &mut View) {
    page(ui, st, "Pockets", |ui, st| {
        small(ui, "Click a pocket to hold it in the world. Click one, then another, to swap them.");
        ui.add_space(8.0);
        let size = 72.0;
        let cols = ((ui.available_width() + 10.0) / (size + 10.0)).floor().max(1.0) as usize;
        let slots = st.bag.clone();
        let mut clicked: Option<usize> = None;
        egui::Grid::new("pockets").spacing(vec2(10.0, 10.0)).show(ui, |ui| {
            for (i, slot) in slots.iter().enumerate() {
                let (r, resp) = ui.allocate_exact_size(vec2(size, size), Sense::click());
                let p = ui.painter();
                let picked = v.picked == Some(i);
                let held = slot.as_ref().map(|s| Some(&s.item) == st.held.as_ref()).unwrap_or(false);
                p.rect(
                    r,
                    CornerRadius::same(16),
                    PAPER_DEEP,
                    Stroke::new(
                        if picked || held { 3.0 } else { 2.0 },
                        if picked {
                            ACCENT
                        } else if held {
                            GOOD
                        } else {
                            PAPER_EDGE
                        },
                    ),
                    egui::StrokeKind::Inside,
                );
                if let Some(s) = slot {
                    let tile = Rect::from_center_size(r.center() - vec2(0.0, 6.0), vec2(34.0, 34.0));
                    p.rect_filled(tile, CornerRadius::same(8), handle_color(&s.item));
                    let letter: String = s.item.chars().take(1).flat_map(|c| c.to_uppercase()).collect();
                    p.text(tile.center(), Align2::CENTER_CENTER, letter, font(EXTRA, 17.0), INK);
                    p.text(r.center_bottom() - vec2(0.0, 8.0), Align2::CENTER_BOTTOM, &s.item, font(BOLD, 11.0), INK_DIM);
                    p.text(r.right_top() + vec2(-8.0, 6.0), Align2::RIGHT_TOP, s.count.to_string(), font(EXTRA, 12.0), INK);
                }
                if resp.hovered() {
                    ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
                }
                if resp.clicked() {
                    clicked = Some(i);
                }
                if (i + 1) % cols == 0 {
                    ui.end_row();
                }
            }
        });
        if let Some(i) = clicked {
            match v.picked.take() {
                Some(j) if j != i => st.bag_swap(j, i),
                Some(_) => {}
                None => {
                    if let Some(Some(s)) = slots.get(i) {
                        st.hold(&s.item.clone());
                    }
                    v.picked = Some(i);
                }
            }
        }
        if slots.is_empty() {
            small(ui, "Nothing in your pockets yet: pick things up in the world.");
        }
    });
}

pub fn members(ui: &mut Ui, st: &mut State, v: &mut View) {
    let Some(s) = st.open_server().cloned() else {
        st.screen = Screen::Chat;
        return;
    };
    page(ui, st, &format!("{} · members", s.name), |ui, st| {
        if s.can("invite") {
            ui.horizontal(|ui| {
                let w = ui.available_width() - 100.0;
                let edit = egui::TextEdit::singleline(&mut v.invite_field)
                    .hint_text(RichText::new("invite @handle").color(INK_FAINT))
                    .font(font(MEDIUM, 15.0))
                    .text_color(INK)
                    .background_color(PAPER_DEEP)
                    .margin(egui::Margin::symmetric(14, 10))
                    .desired_width(w);
                ui.add(edit);
                if text_button(ui, "Invite", vec2(90.0, 40.0), Tone::Green).clicked() {
                    let h = v.invite_field.clone();
                    st.invite(s.id, &h);
                    v.invite_field.clear();
                }
            });
        }
        let members = st.members.clone();
        let me = st.me.as_ref().map(|m| m.id);
        for status in ["pending", "member", "invited", "banned"] {
            let list: Vec<_> = members.iter().filter(|m| m.status == status).collect();
            if list.is_empty() {
                continue;
            }
            section(
                ui,
                match status {
                    "pending" => "asking to join",
                    "member" => "members",
                    "invited" => "invited",
                    _ => "banned",
                },
            );
            for m in list {
                let handle = m.person.handle.clone();
                let is_me = Some(m.person.id) == me;
                row(
                    ui,
                    |ui| {
                        ui.horizontal(|ui| {
                            name_tag(ui, &handle, 14.0);
                            if m.role != "member" {
                                label(ui, &m.role, INK_FAINT);
                            }
                        });
                    },
                    |ui| {
                        if is_me {
                            return;
                        }
                        match status {
                            "pending" if s.can("approve") => {
                                if text_button(ui, "Let in", vec2(84.0, 38.0), Tone::Green).clicked() {
                                    st.member_action(s.id, &handle, "approve", None);
                                }
                                if link(ui, "No").clicked() {
                                    st.member_action(s.id, &handle, "reject", None);
                                }
                            }
                            "member" => {
                                if s.can("ban") && link(ui, "Ban").clicked() {
                                    st.member_action(s.id, &handle, "ban", None);
                                }
                                if s.can("kick") && link(ui, "Remove").clicked() {
                                    st.member_action(s.id, &handle, "kick", None);
                                }
                                if s.can("set_roles") {
                                    let next = match m.role.as_str() {
                                        "member" => Some("moderator"),
                                        "moderator" => Some("member"),
                                        _ => None,
                                    };
                                    if let Some(r) = next {
                                        let t = if r == "moderator" { "Make moderator" } else { "Make member" };
                                        if link(ui, t).clicked() {
                                            st.member_action(s.id, &handle, "role", Some(r));
                                        }
                                    }
                                }
                            }
                            "banned" if s.can("ban") => {
                                if link(ui, "Unban").clicked() {
                                    st.member_action(s.id, &handle, "unban", None);
                                }
                            }
                            _ => {}
                        }
                    },
                );
            }
        }
        let _ = Color32::TRANSPARENT;
    });
}
