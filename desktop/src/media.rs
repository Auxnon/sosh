//! Pictures shared in chat: fetched from the server once, decoded on a
//! thread (png and apng, jpeg, gif, webp), and kept as textures. Moving
//! ones (gif, animated webp and png) keep every frame and play.

use std::collections::HashMap;
use std::io::Cursor;
use std::time::Duration;

use egui::{ColorImage, TextureHandle, TextureOptions};
use image::{AnimationDecoder, DynamicImage, ImageFormat, RgbaImage};

use crate::models::Media;
use crate::state::State;

/// Bigger pictures are scaled down to this on their longest side.
const MAX_SIDE: u32 = 1280;
/// At most this many frames of a moving picture are kept.
const MAX_FRAMES: usize = 240;

pub enum Pic {
    Loading,
    Ready { frames: Vec<(TextureHandle, f32)>, total: f32 },
    Failed,
}

#[derive(Default)]
pub struct Pics {
    pub by_key: HashMap<String, Pic>,
}

impl Pics {
    /// The frame to show now (asking for the picture the first time).
    pub fn frame(st: &mut State, m: &Media, time: f64) -> Option<TextureHandle> {
        match st.pics.by_key.get(&m.key) {
            None => {
                st.pics.by_key.insert(m.key.clone(), Pic::Loading);
                load(st, m);
                None
            }
            Some(Pic::Ready { frames, total }) => {
                if frames.len() == 1 || *total <= 0.0 {
                    return frames.first().map(|f| f.0.clone());
                }
                st.ctx.request_repaint_after(Duration::from_millis(16));
                let mut t = (time as f32) % total;
                for (tex, d) in frames {
                    if t < *d {
                        return Some(tex.clone());
                    }
                    t -= d;
                }
                frames.last().map(|f| f.0.clone())
            }
            _ => None,
        }
    }

    pub fn failed(st: &State, key: &str) -> bool {
        matches!(st.pics.by_key.get(key), Some(Pic::Failed))
    }
}

fn load(st: &mut State, m: &Media) {
    let url = m.url.clone();
    let key = m.key.clone();
    st.spawn(move |api| {
        let frames = api.fetch(&url).and_then(|b| decode(&b));
        Box::new(move |st: &mut State| match frames {
            Ok(frames) => {
                let mut total = 0.0;
                let mut out = Vec::new();
                for (i, (img, d)) in frames.into_iter().enumerate() {
                    let size = [img.width() as usize, img.height() as usize];
                    let ci = ColorImage::from_rgba_unmultiplied(size, img.as_raw());
                    let tex = st.ctx.load_texture(format!("pic-{key}-{i}"), ci, TextureOptions::LINEAR);
                    total += d;
                    out.push((tex, d));
                }
                st.pics.by_key.insert(key, Pic::Ready { frames: out, total });
            }
            Err(e) => {
                log::warn!("picture {key}: {e}");
                st.pics.by_key.insert(key, Pic::Failed);
            }
        })
    });
}

fn fit(img: RgbaImage) -> RgbaImage {
    let (w, h) = img.dimensions();
    if w.max(h) <= MAX_SIDE {
        return img;
    }
    let s = MAX_SIDE as f32 / w.max(h) as f32;
    image::imageops::resize(&img, ((w as f32 * s) as u32).max(1), ((h as f32 * s) as u32).max(1), image::imageops::FilterType::Triangle)
}

/// Every frame, with how long it shows (seconds).
pub fn decode(bytes: &[u8]) -> Result<Vec<(RgbaImage, f32)>, String> {
    let format = image::guess_format(bytes).map_err(|e| e.to_string())?;
    let frames: Option<Vec<image::Frame>> = match format {
        ImageFormat::Gif => image::codecs::gif::GifDecoder::new(Cursor::new(bytes))
            .ok()
            .and_then(|d| d.into_frames().take(MAX_FRAMES).collect::<Result<Vec<_>, _>>().ok()),
        ImageFormat::WebP => image::codecs::webp::WebPDecoder::new(Cursor::new(bytes))
            .ok()
            .and_then(|d| if d.has_animation() { d.into_frames().take(MAX_FRAMES).collect::<Result<Vec<_>, _>>().ok() } else { None }),
        ImageFormat::Png => image::codecs::png::PngDecoder::new(Cursor::new(bytes)).ok().and_then(|d| {
            if d.is_apng().unwrap_or(false) {
                d.apng().ok().and_then(|a| a.into_frames().take(MAX_FRAMES).collect::<Result<Vec<_>, _>>().ok())
            } else {
                None
            }
        }),
        _ => None,
    };
    if let Some(frames) = frames.filter(|f| f.len() > 1) {
        return Ok(frames
            .into_iter()
            .map(|f| {
                let (n, d) = f.delay().numer_denom_ms();
                let secs = if d == 0 { 0.1 } else { (n as f32 / d as f32 / 1000.0).max(0.02) };
                (fit(f.into_buffer()), secs)
            })
            .collect());
    }
    let img: DynamicImage = image::load_from_memory(bytes).map_err(|e| e.to_string())?;
    Ok(vec![(fit(img.to_rgba8()), 0.0)])
}
