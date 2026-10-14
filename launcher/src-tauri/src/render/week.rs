//! The "this week" board: a tile per raid of the next seven days (its loading screen, day and time, how full it is
//! and what it still needs), two to a row. Laid out like the prototype.

use super::{hex, raid_art, rgba, with_alpha, Art, Canvas, BRASS, GOLD, MUTED, WOW_GOLD};

pub struct Tile {
    pub plan_key: String,
    /// "Thursday 20:00"
    pub day: String,
    pub name: String,
    pub have: usize,
    pub size: usize,
    /// "needs 2 tanks", or ""
    pub need: String,
    pub cancelled: bool,
}

const W: f32 = 540.0;
const PAD: f32 = 19.0;
const GAP: f32 = 11.0;
const TILE_H: f32 = 113.0;

pub fn draw(art: &Art, title: &str, sub: &str, tiles: &[Tile]) -> Vec<u8> {
    let rows = tiles.len().div_ceil(2).max(1);
    let h = 56.0 + rows as f32 * (TILE_H + GAP) - GAP + PAD;
    let mut cv = Canvas::new(W, h, hex(0x121016));
    cv.text(&art.friz, 27.0, PAD, 16.0, title, WOW_GOLD, true);
    let sw = Canvas::measure(&art.sans, 12.5, sub);
    cv.text(&art.sans, 12.5, W - PAD - sw, 26.0, sub, MUTED, false);
    let tw = (W - 2.0 * PAD - GAP) / 2.0;
    if tiles.is_empty() {
        cv.text(&art.semi, 15.0, PAD, 70.0, "No raids planned in the next seven days.", MUTED, false);
    }
    for (i, t) in tiles.iter().enumerate() {
        let (x, y) = (PAD + (i % 2) as f32 * (tw + GAP), 56.0 + (i / 2) as f32 * (TILE_H + GAP));
        if let Some((im, region)) = raid_art(art, &t.plan_key, tw, TILE_H) {
            cv.image(&im, Some(region), x, y, tw, TILE_H, 6.0, if t.cancelled { 0.35 } else { 1.0 });
        }
        // (the shade, inside the tile's corners)
        let mut shade = Canvas::new(tw, TILE_H, rgba(0, 0, 0, 0));
        shade.vgrad(0.0, TILE_H, &[(0.0, rgba(0, 0, 0, 40)), (0.45, rgba(0, 0, 0, 90)), (1.0, rgba(0, 0, 0, 225))]);
        cv.image(&shade.img, None, x, y, tw, TILE_H, 6.0, 1.0);
        cv.stroke(x, y, tw, TILE_H, 6.0, 1.0, rgba(255, 255, 255, 26));
        let bx = x + 12.0;
        let mut by = y + TILE_H - 72.0;
        cv.text(&art.bold, 11.0, bx, by, &t.day.to_uppercase(), hex(0xd9cfb6), true);
        by += 16.0;
        let name = Canvas::fit(&art.friz, 18.0, &t.name, tw - 24.0);
        cv.text(&art.friz, 18.0, bx, by, &name, GOLD, true);
        by += 24.0;
        if t.cancelled {
            cv.text(&art.semi, 12.5, bx, by, "Cancelled", hex(0xff8080), true);
            continue;
        }
        let count = format!("{} / {}", t.have, t.size);
        let cw = cv.text(&art.semi, 12.5, bx, by, &count, hex(0xffffff), true);
        if !t.need.is_empty() {
            cv.text(&art.semi, 12.5, bx + cw + 7.0, by, &t.need, hex(0xffb84d), true);
        }
        by += 19.0;
        let bw = tw - 24.0;
        cv.rect(bx, by, bw, 4.0, 2.0, rgba(255, 255, 255, 40));
        let share = if t.size == 0 { 0.0 } else { (t.have as f32 / t.size as f32).min(1.0) };
        if share > 0.0 {
            cv.rect(bx, by, bw * share, 4.0, 2.0, if t.have < t.size { hex(0xffb000) } else { hex(0x43d14a) });
        }
    }
    cv.stroke(0.0, 0.0, W, h, 6.0, 1.0, BRASS);
    let _ = with_alpha;
    cv.png()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draws_the_prototype_board() {
        let Some(art) = crate::render::art() else { return };
        let t = |k: &str, d: &str, n: &str, have, size, need: &str| Tile {
            plan_key: k.into(), day: d.into(), name: n.into(), have, size, need: need.into(), cancelled: false,
        };
        let png = draw(art, "This week", "Week 43 · updated 2 min ago", &[
            t("ssc", "Thursday 20:00", "Serpentshrine", 13, 25, "needs 2 tanks"),
            t("mag", "Friday 19:00", "Magtheridon + Gruul", 25, 25, ""),
            t("kara", "Saturday 19:00", "Karazhan · Spark", 9, 10, "needs a healer"),
            t("tk", "Sunday 19:00", "Tempest Keep", 6, 25, ""),
        ]);
        std::fs::write(std::env::temp_dir().join("dz_week.png"), png).unwrap();
    }
}
