//! The /bis gear sheet: a character's list for one phase in the addon's look (item icons in their quality border, a
//! ready-check tick on what is obtained, where each item drops or the slot's alternative), two columns.

use super::{class_color, hex, rgba, Art, Canvas, GOLD, MUTED};

pub struct Slot {
    pub label: String,
    pub id: u32,
    pub name: String,
    /// item quality (3 rare, 4 epic, 5 legendary)
    pub quality: u8,
    pub got: bool,
    /// under the name: "alt · …" or where it drops
    pub sub: String,
    pub changed: bool,
}

pub struct Sheet<'a> {
    pub name: &'a str,
    pub class: &'a str,
    /// "Retribution Paladin · main spec"
    pub spec_line: &'a str,
    /// "Phase 2", "Pre-raid"
    pub phase: &'a str,
    pub slots: Vec<Slot>,
}

fn quality(q: u8) -> (image::Rgba<u8>, image::Rgba<u8>) {
    match q {
        5 => (hex(0xff8000), hex(0xff9a33)),
        3 => (hex(0x0070dd), hex(0x3d9bff)),
        2 => (hex(0x1eff00), hex(0x5aff3d)),
        _ => (hex(0xa335ee), hex(0xc070ff)),
    }
}

const W: f32 = 540.0;
const PAD: f32 = 19.0;
const ROW: f32 = 48.0;

pub fn draw(art: &Art, s: &Sheet) -> Vec<u8> {
    let rows = s.slots.len().div_ceil(2).max(1);
    let h = 86.0 + rows as f32 * ROW + 40.0;
    let mut cv = Canvas::new(W, h, hex(0x121016));
    // a soft glow behind the header, like the addon's panels
    cv.vgrad(0.0, 140.0, &[(0.0, rgba(60, 40, 75, 150)), (1.0, rgba(18, 16, 22, 0))]);

    // header: class icon, name, spec, phase
    let ci = art.image(&format!("class_{}.png", s.class));
    cv.rect(PAD - 3.0, PAD - 3.0, 46.0, 46.0, 7.0, hex(0x8a6a2a));
    cv.icon(ci.as_deref(), PAD, PAD, 40.0, None);
    cv.text(&art.friz, 26.0, PAD + 54.0, PAD - 1.0, s.name, class_color(s.class), true);
    cv.text(&art.sans, 14.0, PAD + 54.0, PAD + 28.0, s.spec_line, hex(0xb9ae96), false);
    let pw = Canvas::measure(&art.friz, 19.5, s.phase);
    cv.text(&art.friz, 19.5, W - PAD - pw, PAD + 8.0, s.phase, GOLD, true);

    // the slots
    let cw = (W - 2.0 * PAD - 16.0) / 2.0;
    let ready = art.image("ui_ready.png");
    if s.slots.is_empty() {
        cv.text(&art.semi, 15.0, PAD, 90.0, "Nothing picked for this phase yet.", MUTED, false);
    }
    for (i, sl) in s.slots.iter().enumerate() {
        let (x, y) = (PAD + (i % 2) as f32 * (cw + 16.0), 82.0 + (i / 2) as f32 * ROW);
        let (border, ink) = quality(sl.quality);
        let icon = art.image(&format!("item_{}.png", sl.id));
        if sl.changed {
            cv.rect(x - 5.0, y - 5.0, 50.0, 50.0, 8.0, rgba(255, 209, 0, 120));
        }
        cv.icon(icon.as_deref(), x, y, 40.0, Some(border));
        if sl.got {
            if let Some(r) = &ready {
                cv.image(r, None, x + 27.0, y + 27.0, 19.0, 19.0, 0.0, 1.0);
            }
        }
        let tx = x + 51.0;
        let tw = cw - 51.0;
        cv.text(&art.semi, 10.5, tx, y - 1.0, &sl.label.to_uppercase(), hex(0x8f8778), false);
        cv.text(&art.semi, 14.5, tx, y + 12.0, &Canvas::fit(&art.semi, 14.5, &sl.name, tw), ink, false);
        cv.text(&art.sans, 12.0, tx, y + 30.0, &Canvas::fit(&art.sans, 12.0, &sl.sub, tw), hex(0xa79fb3), false);
    }

    // footer
    let got = s.slots.iter().filter(|x| x.got).count();
    cv.rect(PAD, h - 34.0, W - 2.0 * PAD, 1.0, 0.0, rgba(255, 255, 255, 22));
    cv.text(&art.sans, 12.0, PAD, h - 27.0, &format!("{} of 17 picked · {got} obtained", s.slots.len()), MUTED, false);
    let brand = "DisasterZone · My BiS";
    cv.text(&art.sans, 12.0, W - PAD - Canvas::measure(&art.sans, 12.0, brand), h - 27.0, brand, MUTED, false);
    cv.stroke(0.0, 0.0, W, h, 6.0, 1.0, hex(0x5a4620));
    cv.png()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draws_the_prototype_sheet() {
        let Some(art) = crate::render::art() else { return };
        let sl = |l: &str, id, n: &str, got, sub: &str| Slot { label: l.into(), id, name: n.into(), quality: 4, got, sub: sub.into(), changed: false };
        let mut slots = vec![
            sl("Head", 30125, "Crystalforge Faceguard", true, "alt · Helm of the Fallen Champion"),
            sl("Neck", 30008, "Pendant of the Lost Ages", true, "Gruul's Lair · trash"),
            sl("Shoulder", 30127, "Crystalforge Shoulderguards", false, "Token · Void Reaver · Tempest Keep"),
            sl("Back", 28570, "Shadow-Cloak of Dalaran", true, "The Shade of Aran · Karazhan"),
            sl("Chest", 30134, "Crystalforge Chestpiece", false, "Token · Kael'thas · Tempest Keep"),
            sl("Waist", 30106, "Belt of One-Hundred Deaths", false, "Morogrim Tidewalker · Serpentshrine"),
            sl("Ring", 29997, "Band of the Ranger-General", false, "alt · Ring of a Thousand Marks"),
            sl("Trinket", 28830, "Dragonspine Trophy", true, "Gruul · Gruul's Lair"),
        ];
        slots[2].changed = true;
        let png = draw(art, &Sheet { name: "Tsumil", class: "PALADIN", spec_line: "Retribution Paladin · main spec", phase: "Phase 2", slots });
        std::fs::write(std::env::temp_dir().join("dz_sheet.png"), png).unwrap();
    }
}
