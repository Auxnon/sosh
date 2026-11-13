//! The look, the same as the Android app's (`android/.../ui/Theme.kt`,
//! `Kit.kt`): a console's boot menu around cozy paper. Indigo plastic on a
//! faint grid, cream paper in brown ink, leaf green and orange; the Android
//! app's own rounded and techy fonts.

use egui::{
    Align2, Color32, Context, CornerRadius, FontData, FontDefinitions, FontFamily, FontId, Painter, Pos2, Rect, Response, RichText, Sense, Shape,
    Stroke, StrokeKind, Ui, Vec2, pos2, vec2,
};

pub const NIGHT: Color32 = Color32::from_rgb(0x24, 0x1E, 0x4E);
pub const GRID: Color32 = Color32::from_rgb(0x2C, 0x26, 0x60);
pub const PANEL: Color32 = Color32::from_rgb(0x3B, 0x33, 0x80);
pub const PANEL_HI: Color32 = Color32::from_rgb(0x4D, 0x44, 0xA0);
pub const EDGE: Color32 = Color32::from_rgb(0x1A, 0x15, 0x40);
pub const ACCENT: Color32 = Color32::from_rgb(0xF7, 0xA5, 0x31);
pub const ACCENT_EDGE: Color32 = Color32::from_rgb(0xB8, 0x6F, 0x12);
pub const ON_ACCENT: Color32 = Color32::from_rgb(0x3A, 0x24, 0x10);
pub const GOOD: Color32 = Color32::from_rgb(0x5D, 0xBB, 0x46);
pub const GOOD_EDGE: Color32 = Color32::from_rgb(0x2F, 0x7A, 0x22);
pub const ON_GOOD: Color32 = Color32::from_rgb(0x16, 0x30, 0x0C);
pub const BAD: Color32 = Color32::from_rgb(0xF0, 0x71, 0x67);
pub const TEXT: Color32 = Color32::from_rgb(0xF2, 0xEF, 0xFF);
pub const TEXT_DIM: Color32 = Color32::from_rgb(0xC3, 0xBC, 0xF5);
pub const PAPER: Color32 = Color32::from_rgb(0xFF, 0xF4, 0xD6);
pub const PAPER_DEEP: Color32 = Color32::from_rgb(0xF0, 0xDF, 0xB4);
pub const PAPER_EDGE: Color32 = Color32::from_rgb(0xC9, 0xA8, 0x6A);
pub const INK: Color32 = Color32::from_rgb(0x4A, 0x3B, 0x2A);
pub const INK_DIM: Color32 = Color32::from_rgb(0x6E, 0x5A, 0x40);
pub const INK_FAINT: Color32 = Color32::from_rgb(0x8A, 0x74, 0x58);
pub const INK_LINK: Color32 = Color32::from_rgb(0xA3, 0x5E, 0x00);
pub const OUTLINE: Color32 = Color32::from_rgb(0x8B, 0x82, 0xD8);
pub const DANGER_INK: Color32 = Color32::from_rgb(0xC2, 0x41, 0x3A);

/// Rounded weights, and the techy label face.
pub const REGULAR: &str = "rounded";
pub const MEDIUM: &str = "rounded-medium";
pub const BOLD: &str = "rounded-bold";
pub const EXTRA: &str = "rounded-extrabold";
pub const TECH: &str = "tech";

pub fn font(name: &str, size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(name.into()))
}

pub fn setup(ctx: &Context) {
    let mut fonts = FontDefinitions::default();
    let faces: [(&str, &'static [u8]); 5] = [
        (REGULAR, include_bytes!("../../android/app/src/main/res/font/rounded_regular.ttf")),
        (MEDIUM, include_bytes!("../../android/app/src/main/res/font/rounded_medium.ttf")),
        (BOLD, include_bytes!("../../android/app/src/main/res/font/rounded_bold.ttf")),
        (EXTRA, include_bytes!("../../android/app/src/main/res/font/rounded_extrabold.ttf")),
        (TECH, include_bytes!("../../android/app/src/main/res/font/tech.ttf")),
    ];
    // egui's own faces stay behind each one, for what ours don't have (emoji, arrows)
    let fallback: Vec<String> = fonts.families.get(&FontFamily::Proportional).cloned().unwrap_or_default();
    for (name, bytes) in faces {
        fonts.font_data.insert(name.to_owned(), FontData::from_static(bytes).into());
        let mut chain = vec![name.to_owned()];
        chain.extend(fallback.iter().cloned());
        fonts.families.insert(FontFamily::Name(name.into()), chain);
    }
    // plain text (fields, egui's own widgets) in the medium weight
    fonts.families.entry(FontFamily::Proportional).or_default().insert(0, MEDIUM.to_owned());
    ctx.set_fonts(fonts);

    let mut v = egui::Visuals::dark();
    v.panel_fill = NIGHT;
    v.window_fill = PAPER;
    v.window_stroke = Stroke::NONE;
    v.window_corner_radius = CornerRadius::same(24);
    v.extreme_bg_color = PAPER;
    v.override_text_color = None;
    v.selection.bg_fill = ACCENT.gamma_multiply(0.5);
    v.selection.stroke = Stroke::new(1.0, INK);
    v.text_cursor.stroke = Stroke::new(2.0, INK);
    v.hyperlink_color = INK_LINK;
    v.widgets.inactive.bg_fill = PANEL_HI;
    v.widgets.inactive.weak_bg_fill = PANEL_HI;
    v.widgets.hovered.weak_bg_fill = Color32::from_rgb(0x5A, 0x50, 0xB4);
    v.widgets.active.weak_bg_fill = PANEL;
    v.popup_shadow = egui::epaint::Shadow { offset: [0, 4], blur: 0, spread: 0, color: EDGE };
    ctx.set_visuals(v);
    ctx.all_styles_mut(|s| {
        s.spacing.item_spacing = vec2(8.0, 8.0);
        s.spacing.button_padding = vec2(12.0, 6.0);
        s.text_styles.insert(egui::TextStyle::Body, font(MEDIUM, 15.0));
        s.text_styles.insert(egui::TextStyle::Button, font(BOLD, 15.0));
        s.text_styles.insert(egui::TextStyle::Small, font(MEDIUM, 12.0));
        s.text_styles.insert(egui::TextStyle::Heading, font(EXTRA, 22.0));
    });
}

/// The indigo ground with its faint grid.
pub fn ground(p: &Painter, r: Rect) {
    p.rect_filled(r, 0.0, NIGHT);
    let step = 26.0;
    let mut x = r.left();
    while x < r.right() {
        p.line_segment([pos2(x, r.top()), pos2(x, r.bottom())], Stroke::new(1.0, GRID));
        x += step;
    }
    let mut y = r.top();
    while y < r.bottom() {
        p.line_segment([pos2(r.left(), y), pos2(r.right(), y)], Stroke::new(1.0, GRID));
        y += step;
    }
}

/// Chunky console plastic: `color` with a light line along its top and a
/// solid `edge` under it, so it looks like it would press in.
pub fn plastic(p: &Painter, r: Rect, radius: f32, color: Color32, edge: Color32, drop: f32, shine: f32) {
    let cr = CornerRadius::same(radius.round() as u8);
    p.rect_filled(r.translate(vec2(0.0, drop)), cr, edge);
    p.rect_filled(r, cr, color);
    if shine > 0.0 {
        let line = Rect::from_min_max(pos2(r.left() + radius * 0.6, r.top() + 1.0), pos2(r.right() - radius * 0.6, r.top() + 3.0));
        p.rect_filled(line, CornerRadius::same(1), Color32::from_white_alpha((shine * 255.0) as u8));
    }
}

/// Paper: a cream card with a solid shadow under it.
pub fn paper(p: &Painter, r: Rect, radius: f32) {
    plastic(p, r, radius, PAPER, EDGE, 4.0, 0.0);
}

#[derive(Clone, Copy, PartialEq)]
pub enum Tone {
    Plastic,
    Orange,
    Green,
}

impl Tone {
    pub fn colors(self) -> (Color32, Color32, Color32) {
        match self {
            Tone::Plastic => (PANEL_HI, EDGE, TEXT),
            Tone::Orange => (ACCENT, ACCENT_EDGE, ON_ACCENT),
            Tone::Green => (GOOD, GOOD_EDGE, ON_GOOD),
        }
    }
}

/// A pressable plastic button of `size`, its label drawn by `content`
/// (given the text colour). It sinks while pressed.
pub fn plastic_button(ui: &mut Ui, size: Vec2, tone: Tone, enabled: bool, content: impl FnOnce(&Painter, Rect, Color32)) -> Response {
    let (rect, resp) = ui.allocate_exact_size(size, if enabled { Sense::click() } else { Sense::hover() });
    let (mut color, edge, mut on) = if enabled { tone.colors() } else { Tone::Plastic.colors() };
    if !enabled {
        on = TEXT_DIM;
    }
    if resp.hovered() && enabled {
        color = lighten(color, 0.08);
        ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
    }
    let pressed = resp.is_pointer_button_down_on();
    let r = if pressed { rect.translate(vec2(0.0, 2.0)) } else { rect };
    let drop = if pressed { 1.0 } else { 3.0 };
    let shine = if tone == Tone::Plastic { 0.25 } else { 0.4 };
    plastic(ui.painter(), r, 14.0, color, edge, drop, shine);
    content(ui.painter(), r, on);
    resp
}

/// A plastic button with a text label.
pub fn text_button(ui: &mut Ui, label: &str, size: Vec2, tone: Tone) -> Response {
    plastic_button(ui, size, tone, true, |p, r, on| {
        p.text(r.center(), Align2::CENTER_CENTER, label, font(EXTRA, 15.0), on);
    })
}

/// A plastic button with a drawn icon (see `Icon`).
pub fn icon_button(ui: &mut Ui, icon: Icon, tone: Tone, hint: &str) -> Response {
    let resp = plastic_button(ui, vec2(44.0, 44.0), tone, true, |p, r, on| icon.paint(p, r.shrink(12.0), on));
    resp.on_hover_text(hint)
}

/// A plain bordered button on paper.
pub fn paper_button(ui: &mut Ui, label: &str, size: Vec2) -> Response {
    let (rect, resp) = ui.allocate_exact_size(size, Sense::click());
    let fill = if resp.hovered() { PAPER_DEEP } else { Color32::TRANSPARENT };
    ui.painter().rect(rect, CornerRadius::same(16), fill, Stroke::new(2.0, PAPER_EDGE), StrokeKind::Inside);
    ui.painter().text(rect.center(), Align2::CENTER_CENTER, label, font(BOLD, 15.0), INK);
    if resp.hovered() {
        ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
    }
    resp
}

/// A link-like text button on paper.
pub fn link(ui: &mut Ui, label: &str) -> Response {
    let r = ui.add(egui::Label::new(RichText::new(label).font(font(BOLD, 14.0)).color(INK_LINK)).sense(Sense::click()));
    if r.hovered() {
        ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
    }
    r
}

/// Small wide capitals: the console's labels.
pub fn label(ui: &mut Ui, text: &str, color: Color32) -> Response {
    ui.label(RichText::new(text.to_uppercase()).font(font(TECH, 10.0)).color(color).extra_letter_spacing(1.4))
}

const TAGS: [u32; 8] = [0x9FE3D0, 0xFFD35C, 0xD9B8F5, 0xBFD7FF, 0xFFB8A8, 0xC8EB9A, 0xFFC6E0, 0xE6C9A8];

/// Kotlin's String.hashCode, so a handle gets the same colour as on Android.
fn java_hash(s: &str) -> i32 {
    let mut h: i32 = 0;
    for c in s.encode_utf16() {
        h = h.wrapping_mul(31).wrapping_add(c as i32);
    }
    h
}

/// A steady pastel per handle: a name tag's colour.
pub fn handle_color(handle: &str) -> Color32 {
    let c = TAGS[((java_hash(handle) & 0x7fff_ffff) as usize) % TAGS.len()];
    Color32::from_rgb((c >> 16) as u8, (c >> 8) as u8, c as u8)
}

/// The same person's colour dark enough to read on paper.
pub fn handle_ink(handle: &str) -> Color32 {
    lerp(handle_color(handle), INK, 0.62)
}

pub fn lerp(a: Color32, b: Color32, t: f32) -> Color32 {
    let m = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    Color32::from_rgb(m(a.r(), b.r()), m(a.g(), b.g()), m(a.b(), b.b()))
}

pub fn lighten(c: Color32, t: f32) -> Color32 {
    lerp(c, Color32::WHITE, t)
}

/// Someone's name on a tilted pastel tag, as over a speech bubble. Drawn at
/// `at` (its left middle); returns its rect.
pub fn name_tag_at(p: &Painter, at: Pos2, handle: &str, size: f32, tilt: f32) -> Rect {
    let galley = p.layout_no_wrap(handle.to_owned(), font(EXTRA, size), Color32::from_rgb(0x3A, 0x2C, 0x1C));
    let r = Rect::from_min_size(at - vec2(0.0, galley.size().y / 2.0 + 2.0), galley.size() + vec2(22.0, 4.0));
    let color = handle_color(handle);
    if tilt == 0.0 {
        p.rect_filled(r, CornerRadius::same(12), color);
        p.galley(r.min + vec2(11.0, 2.0), galley, INK);
    } else {
        // a tilted tag: a rotated rounded box under the text
        let c = r.center();
        let (s, co) = tilt.to_radians().sin_cos();
        let rot = |v: Vec2| c + vec2(v.x * co - v.y * s, v.x * s + v.y * co);
        let h = r.size() / 2.0;
        let pts = vec![rot(vec2(-h.x, -h.y)), rot(vec2(h.x, -h.y)), rot(vec2(h.x, h.y)), rot(vec2(-h.x, h.y))];
        p.add(Shape::convex_polygon(pts, color, Stroke::NONE));
        let mut text = egui::epaint::TextShape::new(rot(vec2(-h.x + 11.0, -h.y + 2.0)), galley, INK);
        text.angle = tilt.to_radians();
        p.add(text);
    }
    r
}

/// A name tag as a widget (no tilt), clickable.
pub fn name_tag(ui: &mut Ui, handle: &str, size: f32) -> Response {
    let galley = ui.painter().layout_no_wrap(handle.to_owned(), font(EXTRA, size), INK);
    let want = galley.size() + vec2(22.0, 4.0);
    let (rect, resp) = ui.allocate_exact_size(want, Sense::click());
    name_tag_at(ui.painter(), pos2(rect.left(), rect.center().y), handle, size, 0.0);
    resp
}

/// Two letters for a server's memory card.
pub fn initials(name: &str) -> String {
    let words: Vec<&str> = name.split(' ').filter(|w| !w.is_empty()).collect();
    let s: String = if words.len() >= 2 {
        words.iter().take(2).filter_map(|w| w.chars().next()).flat_map(|c| c.to_uppercase()).collect()
    } else {
        let mut cs = name.chars();
        match cs.next() {
            Some(f) => f.to_uppercase().chain(cs.take(1)).collect(),
            None => String::new(),
        }
    };
    if s.is_empty() { "?".into() } else { s }
}

/// Icons drawn with shapes (no icon font needed).
#[derive(Clone, Copy)]
pub enum Icon {
    Menu,
    Group,
    Mail,
    People,
    Backpack,
    Plus,
    Send,
    Picture,
    Hourglass,
    Gift,
    Chat,
    Split,
    Globe,
    Play,
    Back,
    Close,
}

impl Icon {
    /// Draw into `r` (a square) in `c`.
    pub fn paint(self, p: &Painter, r: Rect, c: Color32) {
        let s = Stroke::new(2.2, c);
        let u = r.width() / 20.0;
        let at = |x: f32, y: f32| r.min + vec2(x * u, y * u);
        match self {
            Icon::Menu => {
                for y in [4.0, 10.0, 16.0] {
                    p.line_segment([at(2.0, y), at(18.0, y)], s);
                }
            }
            Icon::Group | Icon::People => {
                p.circle_stroke(at(7.0, 6.0), 3.2 * u, s);
                p.circle_stroke(at(14.0, 7.0), 2.6 * u, s);
                p.add(Shape::line(vec![at(1.5, 18.0), at(2.5, 13.0), at(7.0, 11.5), at(11.5, 13.0), at(12.5, 18.0)], s));
                p.add(Shape::line(vec![at(13.0, 12.0), at(17.0, 12.5), at(18.5, 17.0)], s));
            }
            Icon::Mail => {
                p.rect_stroke(Rect::from_min_max(at(2.0, 4.0), at(18.0, 16.0)), CornerRadius::same(2), s, StrokeKind::Middle);
                p.add(Shape::line(vec![at(2.5, 5.0), at(10.0, 11.0), at(17.5, 5.0)], s));
            }
            Icon::Backpack => {
                p.rect_stroke(Rect::from_min_max(at(4.0, 5.0), at(16.0, 18.0)), CornerRadius::same(4), s, StrokeKind::Middle);
                p.add(Shape::line(vec![at(7.0, 5.0), at(8.0, 2.0), at(12.0, 2.0), at(13.0, 5.0)], s));
                p.line_segment([at(6.5, 11.0), at(13.5, 11.0)], s);
            }
            Icon::Plus => {
                p.line_segment([at(10.0, 3.0), at(10.0, 17.0)], s);
                p.line_segment([at(3.0, 10.0), at(17.0, 10.0)], s);
            }
            Icon::Send => {
                p.add(Shape::convex_polygon(vec![at(2.0, 3.0), at(18.0, 10.0), at(2.0, 17.0), at(5.0, 10.0)], c, Stroke::NONE));
            }
            Icon::Picture => {
                p.rect_stroke(Rect::from_min_max(at(2.0, 3.0), at(18.0, 17.0)), CornerRadius::same(2), s, StrokeKind::Middle);
                p.circle_filled(at(13.5, 7.5), 1.8 * u, c);
                p.add(Shape::line(vec![at(3.0, 15.0), at(8.0, 9.0), at(12.0, 13.0), at(14.0, 11.0), at(17.0, 14.0)], s));
            }
            Icon::Hourglass => {
                p.add(Shape::line(vec![at(5.0, 2.0), at(15.0, 2.0), at(5.0, 18.0), at(15.0, 18.0), at(5.0, 2.0)], s));
            }
            Icon::Gift => {
                p.rect_stroke(Rect::from_min_max(at(3.0, 8.0), at(17.0, 18.0)), CornerRadius::same(2), s, StrokeKind::Middle);
                p.rect_stroke(Rect::from_min_max(at(2.0, 5.0), at(18.0, 8.0)), CornerRadius::same(1), s, StrokeKind::Middle);
                p.line_segment([at(10.0, 5.0), at(10.0, 18.0)], s);
                p.circle_stroke(at(7.5, 3.5), 2.0 * u, s);
                p.circle_stroke(at(12.5, 3.5), 2.0 * u, s);
            }
            Icon::Chat => {
                p.rect_stroke(Rect::from_min_max(at(2.0, 3.0), at(18.0, 14.0)), CornerRadius::same(4), s, StrokeKind::Middle);
                p.add(Shape::line(vec![at(6.0, 14.0), at(5.0, 18.0), at(10.0, 14.0)], s));
            }
            Icon::Split => {
                p.rect_stroke(Rect::from_min_max(at(2.0, 3.0), at(18.0, 17.0)), CornerRadius::same(2), s, StrokeKind::Middle);
                p.line_segment([at(10.0, 3.0), at(10.0, 17.0)], s);
            }
            Icon::Globe => {
                p.circle_stroke(at(10.0, 10.0), 8.0 * u, s);
                p.line_segment([at(2.0, 10.0), at(18.0, 10.0)], s);
                p.add(Shape::ellipse_stroke(at(10.0, 10.0), vec2(3.5 * u, 8.0 * u), s));
            }
            Icon::Play => {
                p.add(Shape::convex_polygon(vec![at(5.0, 3.0), at(17.0, 10.0), at(5.0, 17.0)], c, Stroke::NONE));
            }
            Icon::Back => {
                p.add(Shape::line(vec![at(11.0, 3.0), at(4.0, 10.0), at(11.0, 17.0)], s));
                p.line_segment([at(4.0, 10.0), at(17.0, 10.0)], s);
            }
            Icon::Close => {
                p.line_segment([at(4.0, 4.0), at(16.0, 16.0)], s);
                p.line_segment([at(16.0, 4.0), at(4.0, 16.0)], s);
            }
        }
    }
}

/// A wrapped present with a ribbon, in `r`.
pub fn present(p: &Painter, r: Rect, alpha: f32) {
    let u = r.width() / 40.0;
    let at = |x: f32, y: f32| r.min + vec2(x * u, y * u);
    let a = |c: Color32| c.gamma_multiply(alpha);
    p.rect_filled(Rect::from_min_size(at(6.0, 14.0), vec2(28.0 * u, 22.0 * u)), CornerRadius::same((4.0 * u) as u8), a(GOOD));
    p.rect_filled(
        Rect::from_min_size(at(4.0, 10.0), vec2(32.0 * u, 8.0 * u)),
        CornerRadius::same((3.0 * u) as u8),
        a(Color32::from_rgb(0x7C, 0xCB, 0x5A)),
    );
    p.rect_filled(Rect::from_min_size(at(17.0, 10.0), vec2(6.0 * u, 26.0 * u)), 0.0, a(ACCENT));
    p.add(Shape::ellipse_filled(at(14.5, 7.0), vec2(5.5 * u, 4.0 * u), a(ACCENT)));
    p.add(Shape::ellipse_filled(at(25.5, 7.0), vec2(5.5 * u, 4.0 * u), a(ACCENT)));
}

/// A cartridge: the plastic, a notch, its label and grip.
pub fn cartridge(p: &Painter, r: Rect) {
    let w = r.width();
    let h = r.height();
    let cr = CornerRadius::same((w * 0.12) as u8);
    let at = |x: f32, y: f32| r.min + vec2(x * w, y * h);
    p.rect_filled(Rect::from_min_size(at(0.0, 0.06), vec2(w, h * 0.94)), cr, EDGE);
    p.rect_filled(Rect::from_min_size(at(0.0, 0.0), vec2(w, h * 0.94)), cr, PANEL_HI);
    p.rect_filled(Rect::from_min_size(at(0.72, 0.0), vec2(w * 0.28, h * 0.14)), 0.0, PAPER_DEEP);
    p.rect_filled(Rect::from_min_size(at(0.14, 0.14), vec2(w * 0.72, h * 0.42)), CornerRadius::same((w * 0.06) as u8), PAPER);
    p.circle_filled(at(0.32, 0.32), w * 0.1, ACCENT);
    for i in 0..4 {
        p.rect_filled(Rect::from_min_size(at(0.2 + i as f32 * 0.17, 0.66), vec2(w * 0.08, h * 0.18)), 0.0, EDGE);
    }
}

/// A small floating island over the sea, for a server's page.
pub fn island_banner(p: &Painter, r: Rect) {
    p.rect_filled(r, CornerRadius { nw: 24, ne: 24, sw: 0, se: 0 }, Color32::from_rgb(0x8F, 0xC9, 0xF0));
    p.rect_filled(Rect::from_min_max(pos2(r.left(), r.top() + r.height() * 0.76), r.max), 0.0, Color32::from_rgb(0x4A, 0x8F, 0xD0));
    islands(p, r);
}

/// Just the islands and a cloud of the banner, in `r` (252 by 116 units).
pub fn islands(p: &Painter, r: Rect) {
    let u = r.width() / 252.0;
    let at = |x: f32, y: f32| r.min + vec2(x * u, y * u);
    p.add(Shape::ellipse_filled(at(200.0, 16.0), vec2(24.0 * u, 7.0 * u), Color32::from_white_alpha(204)));
    let brown = Color32::from_rgb(0xB0, 0x7A, 0x45);
    p.add(Shape::convex_polygon(vec![at(30.0, 62.0), at(150.0, 62.0), at(128.0, 88.0), at(74.0, 94.0)], brown, Stroke::NONE));
    p.add(Shape::convex_polygon(vec![at(178.0, 40.0), at(238.0, 40.0), at(224.0, 60.0), at(194.0, 64.0)], brown, Stroke::NONE));
    let green = Color32::from_rgb(0x7C, 0xCB, 0x5A);
    p.rect_filled(Rect::from_min_size(at(26.0, 50.0), vec2(128.0 * u, 16.0 * u)), CornerRadius::same((8.0 * u) as u8), green);
    p.rect_filled(Rect::from_min_size(at(174.0, 30.0), vec2(68.0 * u, 13.0 * u)), CornerRadius::same((6.0 * u) as u8), green);
    p.rect_filled(Rect::from_min_size(at(52.0, 40.0), vec2(5.0 * u, 12.0 * u)), 0.0, Color32::from_rgb(0x7A, 0x52, 0x30));
    p.circle_filled(at(54.0, 38.0), 12.0 * u, Color32::from_rgb(0x4F, 0xA8, 0x3A));
}

/// A dashed rounded outline (the add-server slot, presents).
pub fn dashed_rect(p: &Painter, r: Rect, color: Color32) {
    let pts = vec![r.left_top(), r.right_top(), r.right_bottom(), r.left_bottom(), r.left_top()];
    p.extend(Shape::dashed_line(&pts, Stroke::new(2.0, color), 6.0, 5.0));
}
