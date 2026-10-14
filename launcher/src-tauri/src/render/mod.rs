//! The pictures the Discord bot posts (host mode), drawn in the addon's look: loading-screen art, the game's icons,
//! Friz Quadrata. The art comes from the host's own game client (dev/tools/bot_art.py exports it to
//! <config>/DisasterZoneLauncher/bot_art); it is never shipped with the launcher. Missing art just leaves a gap.
//!
//! Everything is laid out in "points" (the prototype's CSS pixels) and drawn at SCALE pixels per point.

pub mod raid;
pub mod week;

use ab_glyph::{Font, FontArc, PxScale, ScaleFont};
use image::{imageops, Rgba, RgbaImage};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

pub const SCALE: f32 = 2.0;

pub type Color = Rgba<u8>;

pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Color {
    Rgba([r, g, b, a])
}

pub const fn hex(v: u32) -> Color {
    rgba((v >> 16) as u8, (v >> 8) as u8, v as u8, 255)
}

pub fn with_alpha(c: Color, a: u8) -> Color {
    rgba(c[0], c[1], c[2], a)
}

pub const GOLD: Color = hex(0xffd100);
pub const WOW_GOLD: Color = hex(0xf8b700);
pub const PARCHMENT: Color = hex(0xe8dfc8);
pub const MUTED: Color = hex(0x8f8778);
pub const EPIC: Color = hex(0xa335ee);
pub const EPIC_TEXT: Color = hex(0xc070ff);
pub const NIGHT: Color = hex(0x0b0a10);
pub const BRASS: Color = hex(0x6b5420);

/// Class colours (WoW's own; the shaman's a little lighter so it reads on dark art).
pub fn class_color(class: &str) -> Color {
    match class {
        "WARRIOR" => hex(0xc69b6d),
        "PALADIN" => hex(0xf48cba),
        "HUNTER" => hex(0xaad372),
        "ROGUE" => hex(0xfff468),
        "PRIEST" => hex(0xffffff),
        "SHAMAN" => hex(0x2a8af0),
        "MAGE" => hex(0x3fc7eb),
        "WARLOCK" => hex(0x8788ee),
        "DRUID" => hex(0xff7c0a),
        _ => PARCHMENT,
    }
}

// ------------------------------------------------------------------------------------------------------------------
// Art and fonts
// ------------------------------------------------------------------------------------------------------------------

pub struct Art {
    dir: PathBuf,
    images: Mutex<HashMap<String, Option<Arc<RgbaImage>>>>,
    pub friz: FontArc,
    pub sans: FontArc,
    pub semi: FontArc,
    pub bold: FontArc,
    /// { planKey: { cx, cy, top } } (the raid art's focus, Data/Raids.lua)
    pub focus: serde_json::Value,
}

pub fn art_dir() -> PathBuf {
    dirs::config_dir().unwrap_or_else(std::env::temp_dir).join("DisasterZoneLauncher").join("bot_art")
}

static ART: OnceLock<Option<Art>> = OnceLock::new();

/// The art, or None while it has not been exported (the bot then posts text only).
pub fn art() -> Option<&'static Art> {
    ART.get_or_init(|| Art::load(art_dir())).as_ref()
}

impl Art {
    fn load(dir: PathBuf) -> Option<Art> {
        let font = |n: &str| std::fs::read(dir.join(n)).ok().and_then(|b| FontArc::try_from_vec(b).ok());
        let focus = std::fs::read(dir.join("art.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Some(Art {
            friz: font("friz.ttf")?,
            sans: font("sans.ttf")?,
            semi: font("sans_semibold.ttf")?,
            bold: font("sans_bold.ttf")?,
            focus,
            images: Mutex::new(HashMap::new()),
            dir,
        })
    }

    /// A picture by file name ("class_PALADIN.png"), decoded once.
    pub fn image(&self, name: &str) -> Option<Arc<RgbaImage>> {
        let mut m = self.images.lock().unwrap();
        m.entry(name.to_string())
            .or_insert_with(|| image::open(self.dir.join(name)).ok().map(|i| Arc::new(i.to_rgba8())))
            .clone()
    }

    pub fn file(&self, name: &str) -> Option<Vec<u8>> {
        std::fs::read(self.dir.join(name)).ok()
    }
}

// ------------------------------------------------------------------------------------------------------------------
// A canvas in points
// ------------------------------------------------------------------------------------------------------------------

pub struct Canvas {
    pub img: RgbaImage,
}

#[inline]
fn blend(dst: &mut Color, src: Color, cover: f32) {
    let a = src[3] as f32 / 255.0 * cover.clamp(0.0, 1.0);
    if a <= 0.0 {
        return;
    }
    let da = dst[3] as f32 / 255.0;
    let oa = a + da * (1.0 - a);
    for i in 0..3 {
        let c = (src[i] as f32 * a + dst[i] as f32 * da * (1.0 - a)) / oa.max(1e-6);
        dst[i] = c.round().clamp(0.0, 255.0) as u8;
    }
    dst[3] = (oa * 255.0).round() as u8;
}

pub fn px(v: f32) -> f32 {
    v * SCALE
}

impl Canvas {
    pub fn new(w: f32, h: f32, bg: Color) -> Canvas {
        Canvas { img: RgbaImage::from_pixel(px(w).round() as u32, px(h).round() as u32, bg) }
    }

    pub fn png(&self) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(self.img.clone()).write_to(&mut out, image::ImageFormat::Png).ok();
        out.into_inner()
    }

    /// Coverage of a rounded rectangle at pixel (x, y) (pixel centres; anti-aliased edge).
    fn rr_cover(x: f32, y: f32, l: f32, t: f32, r: f32, b: f32, rad: f32) -> f32 {
        if r <= l || b <= t {
            return 0.0;
        }
        let rad = rad.min((r - l) / 2.0).min((b - t) / 2.0).max(0.0);
        let cx = x.clamp(l + rad, r - rad);
        let cy = y.clamp(t + rad, b - rad);
        let d = ((x - cx).powi(2) + (y - cy).powi(2)).sqrt() - rad;
        let edge = (x - l).min(r - x).min(y - t).min(b - y);
        if rad > 0.0 && (x < l + rad || x > r - rad) && (y < t + rad || y > b - rad) {
            (0.5 - d).clamp(0.0, 1.0)
        } else {
            (edge + 0.5).clamp(0.0, 1.0)
        }
    }

    /// A filled rounded rectangle (points).
    pub fn rect(&mut self, x: f32, y: f32, w: f32, h: f32, r: f32, c: Color) {
        let (l, t, rr, b, rad) = (px(x), px(y), px(x + w), px(y + h), px(r));
        let (x0, y0) = (l.floor().max(0.0) as u32, t.floor().max(0.0) as u32);
        let (x1, y1) = ((rr.ceil() as u32).min(self.img.width()), (b.ceil() as u32).min(self.img.height()));
        for yy in y0..y1 {
            for xx in x0..x1 {
                let cov = Self::rr_cover(xx as f32 + 0.5, yy as f32 + 0.5, l, t, rr, b, rad);
                if cov > 0.0 {
                    blend(self.img.get_pixel_mut(xx, yy), c, cov);
                }
            }
        }
    }

    /// A rounded rectangle's outline, `w` points wide.
    pub fn stroke(&mut self, x: f32, y: f32, w: f32, h: f32, r: f32, width: f32, c: Color) {
        let (l, t, rr, b, rad, wd) = (px(x), px(y), px(x + w), px(y + h), px(r), px(width));
        let (x0, y0) = (l.floor().max(0.0) as u32, t.floor().max(0.0) as u32);
        let (x1, y1) = ((rr.ceil() as u32).min(self.img.width()), (b.ceil() as u32).min(self.img.height()));
        for yy in y0..y1 {
            for xx in x0..x1 {
                let (fx, fy) = (xx as f32 + 0.5, yy as f32 + 0.5);
                let outer = Self::rr_cover(fx, fy, l, t, rr, b, rad);
                let inner = Self::rr_cover(fx, fy, l + wd, t + wd, rr - wd, b - wd, (rad - wd).max(0.0));
                let cov = outer - inner;
                if cov > 0.0 {
                    blend(self.img.get_pixel_mut(xx, yy), c, cov);
                }
            }
        }
    }

    /// A vertical gradient over a band: stops = [(share of the band, colour)], blended over what is there.
    pub fn vgrad(&mut self, y: f32, h: f32, stops: &[(f32, Color)]) {
        let (t, b) = (px(y).max(0.0) as u32, (px(y + h) as u32).min(self.img.height()));
        for yy in t..b {
            let s = (yy - t) as f32 / (b - t).max(1) as f32;
            let i = stops.iter().rposition(|(p, _)| *p <= s).unwrap_or(0);
            let (p0, c0) = stops[i];
            let (p1, c1) = *stops.get(i + 1).unwrap_or(&stops[i]);
            let k = if p1 > p0 { (s - p0) / (p1 - p0) } else { 0.0 };
            let mix = |a: u8, b: u8| (a as f32 + (b as f32 - a as f32) * k).round() as u8;
            let c = rgba(mix(c0[0], c1[0]), mix(c0[1], c1[1]), mix(c0[2], c1[2]), mix(c0[3], c1[3]));
            for xx in 0..self.img.width() {
                blend(self.img.get_pixel_mut(xx, yy), c, 1.0);
            }
        }
    }

    /// Draw `src` (its region sx, sy, sw, sh in source pixels; None = all) into the box x, y, w, h (points),
    /// rounded corners r, at `alpha`.
    #[allow(clippy::too_many_arguments)]
    pub fn image(&mut self, src: &RgbaImage, region: Option<(u32, u32, u32, u32)>, x: f32, y: f32, w: f32, h: f32, r: f32, alpha: f32) {
        let (tw, th) = (px(w).round().max(1.0) as u32, px(h).round().max(1.0) as u32);
        let cut;
        let src = match region {
            Some((sx, sy, sw, sh)) => {
                cut = imageops::crop_imm(src, sx, sy, sw.max(1), sh.max(1)).to_image();
                &cut
            }
            None => src,
        };
        let scaled = imageops::resize(src, tw, th, imageops::FilterType::Lanczos3);
        let (ox, oy) = (px(x).round() as i64, px(y).round() as i64);
        let rad = px(r);
        for (sx, sy, p) in scaled.enumerate_pixels() {
            let (dx, dy) = (ox + sx as i64, oy + sy as i64);
            if dx < 0 || dy < 0 || dx >= self.img.width() as i64 || dy >= self.img.height() as i64 {
                continue;
            }
            let cov = if rad > 0.0 {
                Self::rr_cover(sx as f32 + 0.5, sy as f32 + 0.5, 0.0, 0.0, tw as f32, th as f32, rad)
            } else {
                1.0
            };
            blend(self.img.get_pixel_mut(dx as u32, dy as u32), *p, cov * alpha);
        }
    }

    /// An icon with the game's dark ring and a coloured border (item quality, class): size in points.
    pub fn icon(&mut self, src: Option<&RgbaImage>, x: f32, y: f32, size: f32, border: Option<Color>) {
        if let Some(b) = border {
            self.rect(x - 2.0, y - 2.0, size + 4.0, size + 4.0, 3.0, b);
        }
        self.rect(x - 1.0, y - 1.0, size + 2.0, size + 2.0, 2.5, rgba(0, 0, 0, 255));
        match src {
            // (the game's icons carry a dark rim of a few pixels: trimmed)
            Some(s) => {
                let m = (s.width() / 16).min(4);
                self.image(s, Some((m, m, s.width() - 2 * m, s.height() - 2 * m)), x, y, size, size, 2.0, 1.0)
            }
            None => self.rect(x, y, size, size, 2.0, hex(0x1a1720)),
        }
    }

    /// The width of a text (points).
    pub fn measure(font: &FontArc, size: f32, text: &str) -> f32 {
        let sf = font.as_scaled(PxScale::from(px(size)));
        let mut w = 0.0;
        let mut prev = None;
        for ch in text.chars() {
            let id = sf.glyph_id(ch);
            if let Some(p) = prev {
                w += sf.kern(p, id);
            }
            w += sf.h_advance(id);
            prev = Some(id);
        }
        w / SCALE
    }

    /// The text cut to fit `max` points, with an ellipsis.
    pub fn fit(font: &FontArc, size: f32, text: &str, max: f32) -> String {
        if Self::measure(font, size, text) <= max {
            return text.to_string();
        }
        let mut s: Vec<char> = text.chars().collect();
        while !s.is_empty() && Self::measure(font, size, &(s.iter().collect::<String>() + "…")) > max {
            s.pop();
        }
        s.into_iter().collect::<String>() + "…"
    }

    /// Text with its top-left at x, y (points); `shadow` draws a soft dark copy under it. Returns the width.
    #[allow(clippy::too_many_arguments)]
    pub fn text(&mut self, font: &FontArc, size: f32, x: f32, y: f32, text: &str, c: Color, shadow: bool) -> f32 {
        if shadow {
            for (dx, dy, a) in [(0.0, 1.5, 150u8), (0.0, 0.5, 120), (1.0, 1.0, 90)] {
                self.glyphs(font, size, x + dx, y + dy, text, rgba(0, 0, 0, a));
            }
        }
        self.glyphs(font, size, x, y, text, c)
    }

    fn glyphs(&mut self, font: &FontArc, size: f32, x: f32, y: f32, text: &str, c: Color) -> f32 {
        let scale = PxScale::from(px(size));
        let sf = font.as_scaled(scale);
        let mut caret = px(x);
        let base = px(y) + sf.ascent();
        let mut prev = None;
        for ch in text.chars() {
            let id = sf.glyph_id(ch);
            if let Some(p) = prev {
                caret += sf.kern(p, id);
            }
            let g = id.with_scale_and_position(scale, ab_glyph::point(caret, base));
            caret += sf.h_advance(id);
            prev = Some(id);
            if let Some(o) = font.outline_glyph(g) {
                let bb = o.px_bounds();
                let (w, h) = (self.img.width() as i64, self.img.height() as i64);
                o.draw(|gx, gy, cov| {
                    let (xx, yy) = (bb.min.x as i64 + gx as i64, bb.min.y as i64 + gy as i64);
                    if xx >= 0 && yy >= 0 && xx < w && yy < h {
                        blend(self.img.get_pixel_mut(xx as u32, yy as u32), c, cov);
                    }
                });
            }
        }
        (caret - px(x)) / SCALE
    }
}

/// A raid's loading screen cut to w:h around its focus, under the logo band: (image, region in source pixels).
pub fn raid_art(art: &Art, plan_key: &str, w: f32, h: f32) -> Option<(Arc<RgbaImage>, (u32, u32, u32, u32))> {
    let key = if art.focus.get(plan_key).is_some() { plan_key } else { "other" };
    let im = art.image(&format!("load_{key}.jpg"))?;
    let f = &art.focus[key];
    let (cx, cy, top) = (
        f["cx"].as_f64().unwrap_or(0.5) as f32,
        f["cy"].as_f64().unwrap_or(0.45) as f32,
        f["top"].as_f64().unwrap_or(0.29) as f32,
    );
    let (iw, ih) = (im.width() as f32, im.height() as f32);
    // (the texture's bottom fifth is the loading bar's frame: left out like the logo band at the top)
    let (y0, avail_h) = (ih * top, ih * (0.8 - top));
    // the largest box of the card's shape that fits under the band, centred on the focus
    let mut sh = avail_h;
    let mut sw = sh * w / h;
    if sw > iw {
        sw = iw;
        sh = sw * h / w;
    }
    // (max before min: rounding must never make the range empty)
    let sx = (cx * iw - sw / 2.0).min(iw - sw).max(0.0);
    let sy = (cy * ih - sh / 2.0).min(y0 + avail_h - sh).max(y0);
    Some((im, (sx as u32, sy as u32, sw as u32, sh as u32)))
}
