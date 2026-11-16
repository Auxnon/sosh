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

/// What a pocket's menu asks for.
enum PocketAct {
    Collect,
    Hold,
    Split,
    Drop,
}

/// The pockets: click one to put it in hand in the world; drag one onto
/// another to sort them (like stacks pour together, others swap);
/// right-click one for more: collect (marbles, into the wallet), hold,
/// split, drop (the whole stack, at your feet in the world).
pub fn bag(ui: &mut Ui, st: &mut State, v: &mut View) {
    page(ui, st, "Pockets", |ui, st| {
        small(ui, "Click a pocket to hold it in the world. Drag to sort them, right-click one for more.");
        ui.add_space(8.0);
        wallet(ui, st, v);
        ui.add_space(8.0);
        let size = 72.0;
        let cols = ((ui.available_width() + 10.0) / (size + 10.0)).floor().max(1.0) as usize;
        let slots = st.bag.clone();
        let pointer = ui.ctx().input(|i| i.pointer.interact_pos());
        let mut rects: Vec<Rect> = Vec::with_capacity(slots.len());
        let mut clicked: Option<usize> = None;
        let mut dropped: Option<usize> = None;
        let mut act: Option<(usize, PocketAct)> = None;
        egui::Grid::new("pockets").spacing(vec2(10.0, 10.0)).show(ui, |ui| {
            for (i, slot) in slots.iter().enumerate() {
                let (r, resp) = ui.allocate_exact_size(vec2(size, size), Sense::click_and_drag());
                rects.push(r);
                let p = ui.painter();
                let dragging = v.dragging == Some(i);
                let over = v.dragging.is_some() && !dragging && pointer.is_some_and(|at| r.contains(at));
                let held = slot.as_ref().map(|s| Some(&s.item) == st.held.as_ref()).unwrap_or(false);
                p.rect(
                    r,
                    CornerRadius::same(16),
                    PAPER_DEEP,
                    Stroke::new(
                        if over || held { 3.0 } else { 2.0 },
                        if over {
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
                    if !dragging {
                        paint_stack(p, r, s);
                    }
                    if resp.hovered() && v.dragging.is_none() {
                        ui.ctx().set_cursor_icon(egui::CursorIcon::Grab);
                    }
                    if resp.drag_started() {
                        v.dragging = Some(i);
                    }
                    if resp.drag_stopped() {
                        dropped = Some(i);
                    }
                    resp.context_menu(|ui| {
                        let have = s.marbles().unwrap_or(s.count);
                        ui.label(RichText::new(match s.marbles() {
                            Some(n) => format!("{} marbles", crate::models::grouped(n)),
                            None => format!("{} ×{}", s.item, s.count),
                        }).font(font(BOLD, 13.0)).color(INK_DIM));
                        let mut pick = |what| {
                            act = Some((i, what));
                        };
                        if s.marbles().is_some() && ui.button("Collect").clicked() {
                            pick(PocketAct::Collect);
                            ui.close();
                        }
                        if ui.button("Hold").clicked() {
                            pick(PocketAct::Hold);
                            ui.close();
                        }
                        if have > 1 && ui.button("Split…").clicked() {
                            pick(PocketAct::Split);
                            ui.close();
                        }
                        if ui.button("Drop").on_hover_text("The whole stack, at your feet in the world").clicked() {
                            pick(PocketAct::Drop);
                            ui.close();
                        }
                    });
                }
                if resp.clicked() {
                    clicked = Some(i);
                }
                if (i + 1) % cols == 0 {
                    ui.end_row();
                }
            }
        });
        // what's being dragged, under the pointer, over everything
        if let (Some(i), Some(at)) = (v.dragging, pointer) {
            if let Some(Some(s)) = slots.get(i) {
                ui.ctx().set_cursor_icon(egui::CursorIcon::Grabbing);
                let layer = egui::LayerId::new(egui::Order::Tooltip, ui.scope_id().with("pocket-ghost"));
                let p = ui.ctx().layer_painter(layer);
                let r = Rect::from_center_size(at, vec2(size, size));
                p.rect_filled(r.translate(vec2(0.0, 6.0)), CornerRadius::same(16), Color32::from_black_alpha(70));
                p.rect(r, CornerRadius::same(16), PAPER, Stroke::new(3.0, ACCENT), egui::StrokeKind::Inside);
                paint_stack(&p, r, s);
            }
        }
        if let Some(from) = dropped {
            v.dragging = None;
            let to = pointer.and_then(|at| rects.iter().position(|r| r.contains(at)));
            if let Some(to) = to.filter(|&to| to != from) {
                st.bag_move(from, to);
            }
        }
        if let Some(i) = clicked {
            if let Some(Some(s)) = slots.get(i) {
                st.hold(&s.item.clone());
            }
        }
        match act {
            Some((i, PocketAct::Collect)) => st.deposit(i),
            Some((i, PocketAct::Hold)) => {
                if let Some(Some(s)) = slots.get(i) {
                    st.hold(&s.item.clone());
                }
            }
            Some((i, PocketAct::Split)) => {
                if let Some(Some(s)) = slots.get(i) {
                    let have = s.marbles().unwrap_or(s.count);
                    v.split = Some((i, (have / 2).max(1)));
                }
            }
            Some((i, PocketAct::Drop)) => st.bag_drop(i),
            None => {}
        }
        if slots.is_empty() {
            small(ui, "Nothing in your pockets yet: pick things up in the world.");
        }
        split_dialog(ui.ctx(), st, v, &slots);
    });
}

/// A stack's tile, name and count in its pocket `r`.
fn paint_stack(p: &egui::Painter, r: Rect, s: &crate::models::Slot) {
    let tile = Rect::from_center_size(r.center() - vec2(0.0, 6.0), vec2(34.0, 34.0));
    let kind = crate::models::item_kind(&s.item);
    p.rect_filled(tile, CornerRadius::same(8), handle_color(kind));
    let letter: String = kind.chars().take(1).flat_map(|c| c.to_uppercase()).collect();
    p.text(tile.center(), Align2::CENTER_CENTER, letter, font(EXTRA, 17.0), INK);
    p.text(r.center_bottom() - vec2(0.0, 8.0), Align2::CENTER_BOTTOM, kind, font(BOLD, 11.0), INK_DIM);
    p.text(r.right_top() + vec2(-8.0, 6.0), Align2::RIGHT_TOP, s.label(), font(EXTRA, 12.0), INK);
}

/// How many to take off a stack (or a bag of marbles) into a pocket of their own.
fn split_dialog(ctx: &egui::Context, st: &mut State, v: &mut View, slots: &[Option<crate::models::Slot>]) {
    let Some((i, n)) = v.split.as_mut() else {
        return;
    };
    let Some(Some(s)) = slots.get(*i) else {
        v.split = None;
        return;
    };
    let have = s.marbles().unwrap_or(s.count);
    let mut done = false;
    let mut go = false;
    let modal = egui::Modal::new(egui::Id::unique("split"))
        .frame(egui::Frame::new().fill(PAPER).corner_radius(CornerRadius::same(24)).inner_margin(egui::Margin::same(20)));
    let resp = modal.show(ctx, |ui| {
        ui.set_width(320.0);
        let title = if s.marbles().is_some() { "Split the bag of marbles".to_owned() } else { format!("Split {}", s.item) };
        ui.label(RichText::new(title).font(font(EXTRA, 20.0)).color(INK));
        ui.horizontal(|ui| {
            ui.label(RichText::new(format!("how many off (of {})", crate::models::grouped(have))).font(font(BOLD, 14.0)).color(INK));
            ui.add(egui::DragValue::new(n).range(1..=(have - 1).max(1)));
        });
        ui.horizontal(|ui| {
            if link(ui, "One").clicked() {
                *n = 1;
            }
            if link(ui, "Half").clicked() {
                *n = (have / 2).max(1);
            }
            if link(ui, "All but one").clicked() {
                *n = (have - 1).max(1);
            }
        });
        ui.add_space(6.0);
        ui.horizontal(|ui| {
            if link(ui, "Cancel").clicked() {
                done = true;
            }
            ui.with_layout(egui::Layout::right_to_left(Align::Center), |ui| {
                if text_button(ui, "Split", vec2(100.0, 40.0), Tone::Orange).clicked() {
                    go = true;
                }
            });
        });
    });
    if go && (1..have).contains(n) {
        st.bag_split(*i, *n);
        done = true;
    }
    if done || resp.should_close() {
        v.split = None;
    }
}

/// The wallet: marbles kept out of the pockets. Bags of marbles go in
/// whole (each pocket's menu collects one; this, all of them); they come
/// back out a hundred, a thousand or however many at a time.
fn wallet(ui: &mut Ui, st: &mut State, v: &mut View) {
    let bags = st.bag.iter().flatten().filter(|s| s.marbles().is_some()).count();
    ui.horizontal(|ui| {
        ui.label(RichText::new("Wallet").font(font(BOLD, 13.0)).color(INK_DIM));
        ui.label(
            RichText::new(format!("{} marbles", crate::models::grouped(st.wallet)))
                .font(font(EXTRA, 18.0))
                .color(INK),
        );
        if bags > 0 && text_button(ui, &format!("Collect {bags}"), vec2(110.0, 34.0), Tone::Green).clicked() {
            st.deposit_all();
        }
    });
    if st.wallet <= 0 {
        return;
    }
    ui.horizontal(|ui| {
        label(ui, "take out", INK_FAINT);
        for n in [100, 1000] {
            if text_button(ui, &crate::models::grouped(n), vec2(80.0, 34.0), Tone::Green).clicked() {
                if st.wallet >= n {
                    st.withdraw(n);
                } else {
                    st.notify(&format!("You have {} marbles", crate::models::grouped(st.wallet)));
                }
            }
        }
        let tone = if v.withdraw_custom { Tone::Orange } else { Tone::Plastic };
        if text_button(ui, "Custom", vec2(90.0, 34.0), tone).clicked() {
            v.withdraw_custom = !v.withdraw_custom;
        }
    });
    if v.withdraw_custom {
        ui.horizontal(|ui| {
            let edit = egui::TextEdit::singleline(&mut v.withdraw_field)
                .hint_text(RichText::new("how many").color(INK_FAINT))
                .font(font(MEDIUM, 15.0))
                .text_color(INK)
                .background_color(PAPER_DEEP)
                .margin(egui::Margin::symmetric(14, 8))
                .desired_width(140.0);
            ui.add(edit);
            v.withdraw_field.retain(|c| c.is_ascii_digit());
            let n = v.withdraw_field.parse::<i64>().ok().filter(|n| (1..=st.wallet).contains(n));
            if text_button(ui, "Take out", vec2(100.0, 34.0), Tone::Green).clicked() {
                match n {
                    Some(n) => {
                        st.withdraw(n);
                        v.withdraw_field.clear();
                        v.withdraw_custom = false;
                    }
                    None => st.notify(&format!("You have {} marbles", crate::models::grouped(st.wallet))),
                }
            }
        });
    }
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
