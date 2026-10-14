//! The raid post's picture: the raid's loading screen, its name and start, and the sign-ups by role filling up
//! against the target comp (class icon, name in class colour, spec icon; Discord answers not in the game yet are
//! shown faded as "pending"). Laid out like the prototype (dev/art/casc/discord_mockup).

use super::{class_color, hex, raid_art, rgba, with_alpha, Art, Canvas, BRASS, GOLD, MUTED, NIGHT, WOW_GOLD};

/// One person on the card.
#[derive(Debug, Clone, PartialEq)]
pub struct Person {
    pub name: String,
    pub class: String,
    /// 1-based spec index (addon ns.SPECS), 0 = unknown
    pub spec: u32,
    /// "tank" | "heal" | "dps"
    pub role: String,
    pub pending: bool,
}

pub struct RaidCard<'a> {
    pub plan_key: &'a str,
    pub title: &'a str,
    /// "Tuesday 21 October · 19:00 server time"
    pub when: &'a str,
    /// "10-man · Team Spark"
    pub pill: &'a str,
    pub accepted: Vec<Person>,
    pub tentative: Vec<String>,
    pub absent: Vec<String>,
    /// tanks, healers, damage wanted
    pub target: (usize, usize, usize),
    pub cancelled: bool,
}

const W: f32 = 520.0;
const COL_TOP: f32 = 150.0;
const ROW: f32 = 20.5;

pub fn draw(art: &Art, c: &RaidCard) -> Vec<u8> {
    let by = |r: &str| c.accepted.iter().filter(|p| p.role == r).cloned().collect::<Vec<_>>();
    let (tanks, heals, dps) = (by("tank"), by("heal"), by("dps"));
    // (a 25-man's damage dealers take two columns)
    let split = dps.len() > 8;
    let dps_rows = if split { dps.len().div_ceil(2) } else { dps.len() };
    let rows = tanks.len().max(heals.len()).max(dps_rows).max(2);
    let others = !c.tentative.is_empty() || !c.absent.is_empty();
    let h = (COL_TOP + 32.0 + rows as f32 * ROW + if others { 30.0 } else { 14.0 }).max(300.0);
    let mut cv = Canvas::new(W, h, NIGHT);

    // art, then the shade that makes the roster readable
    if let Some((im, region)) = raid_art(art, c.plan_key, W, h.min(340.0)) {
        cv.image(&im, Some(region), 0.0, 0.0, W, h.min(340.0), 6.0, if c.cancelled { 0.45 } else { 1.0 });
    }
    cv.vgrad(0.0, COL_TOP, &[(0.0, rgba(0, 0, 0, 0)), (0.55, rgba(0, 0, 0, 110)), (1.0, with_alpha(NIGHT, 235))]);
    cv.rect(0.0, COL_TOP, W, h - COL_TOP, 0.0, with_alpha(NIGHT, 235));

    // header
    let title = if c.cancelled { format!("{} · cancelled", c.title) } else { c.title.to_string() };
    cv.text(&art.friz, 34.0, 22.0, 18.0, &Canvas::fit(&art.friz, 34.0, &title, 330.0), WOW_GOLD, true);
    cv.text(&art.semi, 15.0, 22.0, 62.0, c.when, hex(0xf2ead6), true);
    let pw = Canvas::measure(&art.semi, 12.5, c.pill) + 22.0;
    cv.rect(W - 22.0 - pw, 22.0, pw, 24.0, 12.0, rgba(0, 0, 0, 170));
    cv.stroke(W - 22.0 - pw, 22.0, pw, 24.0, 12.0, 1.0, rgba(255, 255, 255, 42));
    cv.text(&art.semi, 12.5, W - 22.0 - pw + 11.0, 26.0, c.pill, hex(0xf0e6cf), false);

    // the role columns
    let gap = 16.0;
    let cols = if split { 4 } else { 3 };
    let cw = (W - 44.0 - gap * (cols as f32 - 1.0)) / cols as f32;
    let col_x = |i: usize| 22.0 + i as f32 * (cw + gap);
    let roles = art.image("ui_roles.png");
    let head = |cv: &mut Canvas, x: f32, w: f32, label: &str, cell: (u32, u32), n: usize, need: usize| {
        if let Some(r) = &roles {
            // (UI-LFG-ICON-ROLES: 67 px cells on a 256 px sheet)
            let s = r.width() * 67 / 256;
            cv.image(r, Some((cell.0 * s, cell.1 * s, s, s)), x, COL_TOP - 2.0, 17.0, 17.0, 0.0, 1.0);
        }
        cv.text(&art.friz, 15.0, x + 21.0, COL_TOP - 1.0, label, GOLD, true);
        let count = format!("{n}/{need}");
        let short = n < need;
        let cwid = Canvas::measure(&art.bold, 13.0, &count);
        cv.text(&art.bold, 13.0, x + w - cwid, COL_TOP, &count, if short { hex(0xffb84d) } else { hex(0xffffff) }, true);
        cv.rect(x, COL_TOP + 22.0, w, 4.0, 2.0, rgba(255, 255, 255, 36));
        let share = if need == 0 { 1.0 } else { (n as f32 / need as f32).min(1.0) };
        if share > 0.0 {
            cv.rect(x, COL_TOP + 22.0, w * share, 4.0, 2.0, if short { hex(0xffb000) } else { hex(0x43d14a) });
        }
    };
    let person = |cv: &mut Canvas, x: f32, y: f32, w: f32, p: &Person| {
        let a = if p.pending { 0.55 } else { 1.0 };
        let fade = |c: image::Rgba<u8>| with_alpha(c, (255.0 * a) as u8);
        if let Some(i) = art.image(&format!("class_{}.png", p.class)) {
            let m = i.width() / 16;
            cv.image(&i, Some((m, m, i.width() - 2 * m, i.height() - 2 * m)), x, y, 17.0, 17.0, 3.0, a);
        }
        let label = if p.pending { format!("{} · pending", p.name) } else { p.name.clone() };
        let name = Canvas::fit(&art.semi, 13.5, &label, w - 44.0);
        let tw = cv.text(&art.semi, 13.5, x + 23.0, y - 0.5, &name, fade(if p.pending { MUTED } else { class_color(&p.class) }), true);
        if p.spec > 0 && !p.pending {
            if let Some(i) = art.image(&format!("spec_{}_{}.png", p.class, p.spec)) {
                let m = i.width() / 16;
                cv.image(&i, Some((m, m, i.width() - 2 * m, i.height() - 2 * m)), x + 27.0 + tw, y + 2.5, 12.0, 12.0, 2.0, 0.9);
            }
        }
    };
    let list_y = COL_TOP + 34.0;
    head(&mut cv, col_x(0), cw, "Tanks", (0, 1), tanks.len(), c.target.0);
    for (i, p) in tanks.iter().enumerate() {
        person(&mut cv, col_x(0), list_y + i as f32 * ROW, cw, p);
    }
    head(&mut cv, col_x(1), cw, "Healers", (1, 0), heals.len(), c.target.1);
    for (i, p) in heals.iter().enumerate() {
        person(&mut cv, col_x(1), list_y + i as f32 * ROW, cw, p);
    }
    let dw = if split { cw * 2.0 + gap } else { cw };
    head(&mut cv, col_x(2), dw, "Damage", (1, 1), dps.len(), c.target.2);
    for (i, p) in dps.iter().enumerate() {
        let (col, row) = if split { (2 + i / dps_rows, i % dps_rows) } else { (2, i) };
        person(&mut cv, col_x(col), list_y + row as f32 * ROW, cw, p);
    }

    // tentative / can't come under the columns
    if others {
        let mut parts = Vec::new();
        if !c.tentative.is_empty() {
            parts.push(format!("Tentative: {}", c.tentative.join(", ")));
        }
        if !c.absent.is_empty() {
            parts.push(format!("Can't come: {}", c.absent.join(", ")));
        }
        let line = Canvas::fit(&art.sans, 12.0, &parts.join("   ·   "), W - 44.0);
        cv.text(&art.sans, 12.0, 22.0, h - 26.0, &line, MUTED, false);
    }
    cv.stroke(0.0, 0.0, W, h, 6.0, 1.0, BRASS);
    cv.png()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Renders the prototype's Karazhan card into the temp folder (needs the exported art; skipped without it).
    #[test]
    fn draws_the_prototype_card() {
        let Some(art) = crate::render::art() else { return };
        let p = |n: &str, c: &str, s: u32, r: &str, pending: bool| Person { name: n.into(), class: c.into(), spec: s, role: r.into(), pending };
        let card = RaidCard {
            plan_key: "kara",
            title: "Karazhan",
            when: "Tuesday 21 October · 19:00 server time",
            pill: "10-man · Team Spark",
            accepted: vec![
                p("Lee", "WARRIOR", 3, "tank", false), p("Bramble", "DRUID", 3, "tank", false),
                p("Rita", "PRIEST", 2, "heal", false), p("Tidecall", "SHAMAN", 3, "heal", false),
                p("Tsumil", "PALADIN", 3, "dps", false), p("Frostie", "MAGE", 3, "dps", false),
                p("Shank", "ROGUE", 2, "dps", false), p("Grimoire", "WARLOCK", 3, "dps", false),
                p("Arrowz", "HUNTER", 1, "dps", true),
            ],
            tentative: vec!["Mojo".into()],
            absent: vec!["Bubbles".into()],
            target: (2, 3, 5),
            cancelled: false,
        };
        let png = draw(art, &card);
        assert!(png.len() > 10_000);
        std::fs::write(std::env::temp_dir().join("dz_raid_card.png"), png).unwrap();
    }
}
