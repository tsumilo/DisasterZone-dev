//! Raid posts (host mode): every raid in the addon's snapshot (DisasterZoneBridgeDB.snap, addon Core/Bridge.lua) gets
//! a message in its team's channel (or the guild channel): a short embed and a picture of the sign-ups
//! (render::raid), with Accept / Tentative / Can't come / Change spec. Answers given in Discord show at once as
//! "pending" (from the bridge queue) until the host's addon has taken them. A post is edited when what it shows
//! changes. Which message belongs to which raid is kept in <config>/DisasterZoneLauncher/bridge_posts.json.

use crate::core::bridge::{self, lua_list, save_json, Record};
use crate::render::raid::{Person, RaidCard};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::PathBuf;
use twilight_http::Client;
use twilight_model::channel::message::component::{ActionRow, Button, ButtonStyle, Component};
use twilight_model::channel::message::Embed;
use twilight_model::http::attachment::Attachment;
use twilight_model::id::marker::{ChannelMarker, MessageMarker};
use twilight_model::id::Id;
use twilight_util::builder::embed::{EmbedBuilder, EmbedFooterBuilder, ImageSource};

const ORANGE: u32 = 0xFF8000;
const GREY: u32 = 0x5C5C66;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Post {
    pub channel: String,
    pub message: String,
    pub hash: String,
}

fn posts_path() -> PathBuf {
    dirs::config_dir().unwrap_or_else(std::env::temp_dir).join("DisasterZoneLauncher").join("bridge_posts.json")
}

pub fn load_posts() -> BTreeMap<String, Post> {
    std::fs::read(posts_path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

fn s<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(|x| x.as_str())
}

fn short(key: &str) -> &str {
    key.split('-').next().unwrap_or(key)
}

/// The channel a raid goes to: its first team that has one, else the guild channel.
pub fn target_channel(raid: &Value, dc: &Value) -> Option<String> {
    for t in lua_list(raid.get("teams")) {
        if let Some(ch) = t.as_str().and_then(|id| dc.get("teams").and_then(|m| m.get(id))).and_then(|c| c.as_str()) {
            return Some(ch.to_string());
        }
    }
    s(dc, "guild").map(str::to_string)
}

/// The raid's people as the card shows them: the snapshot's answers, then the Discord answers still on their way
/// (the newest per name wins, shown pending).
pub fn people(raid: &Value, queue: &[Record]) -> (Vec<Person>, Vec<String>, Vec<String>) {
    let id = s(raid, "id").unwrap_or("");
    let mut acc: Vec<Person> = Vec::new();
    let mut tent = Vec::new();
    let mut absent = Vec::new();
    for su in lua_list(raid.get("signups")) {
        let name = short(s(su, "key").unwrap_or("?")).to_string();
        let class = s(su, "class").unwrap_or("").to_string();
        match s(su, "st") {
            Some("accept") => {
                let spec = s(su, "spec").map_or(0, |l| crate::signup::spec_index(&class, l));
                let role = match s(su, "role") {
                    Some("tank") => "tank",
                    Some("healer") => "heal",
                    Some(_) => "dps",
                    None if spec > 0 => crate::signup::role_of(&class, spec),
                    None => "dps",
                };
                acc.push(Person { name, class, spec, role: role.into(), pending: false });
            }
            Some("tentative") | Some("bench") => tent.push(name),
            _ => absent.push(name),
        }
    }
    for r in queue.iter().filter(|r| r.kind == "signup" && r.body.get("raid").and_then(|x| x.as_str()) == Some(id)) {
        let b = &r.body;
        let name = short(s(b, "name").unwrap_or("?")).to_string();
        let lower = name.to_lowercase();
        acc.retain(|p| p.name.to_lowercase() != lower);
        tent.retain(|n: &String| n.to_lowercase() != lower);
        absent.retain(|n: &String| n.to_lowercase() != lower);
        let class = s(b, "class").unwrap_or("").to_string();
        match s(b, "st") {
            Some("A") => {
                let spec = b.get("sp").and_then(|x| x.as_u64()).unwrap_or(0) as u32;
                let role = crate::signup::role_of(&class, spec).to_string();
                acc.push(Person { name, class, spec, role, pending: true });
            }
            Some("T") => tent.push(name),
            _ => absent.push(name),
        }
    }
    (acc, tent, absent)
}

/// "Tuesday 21 October · 19:00" in the host's clock (the realm's, for a guild on its own time zone).
fn day_line(t: i64) -> String {
    use chrono::{Local, TimeZone};
    match Local.timestamp_opt(t, 0).single() {
        Some(d) => d.format("%A %-d %B · %H:%M server time").to_string(),
        None => String::new(),
    }
}

pub struct Rendered {
    pub embed: Embed,
    pub components: Vec<Component>,
    /// the picture, when the bot's art is there (bot_art.py)
    pub png: Option<Vec<u8>>,
    pub filename: String,
    /// changes only when what the post shows changes (not with every save)
    pub hash: String,
}

/// `draw`: make the picture too (the hash alone says whether the post changed; drawing takes a moment).
pub fn render(raid: &Value, teams: &Value, queue: &[Record], draw: bool) -> Rendered {
    let id = s(raid, "id").unwrap_or("?");
    let t = raid.get("t").and_then(|x| x.as_i64()).unwrap_or(0);
    let cancelled = raid.get("cancelled").and_then(|x| x.as_bool()).unwrap_or(false);
    let locked = raid.get("locked").and_then(|x| x.as_bool()).unwrap_or(false);
    let name = s(raid, "title").or(s(raid, "name")).unwrap_or("Raid");
    let size = raid.get("size").and_then(|x| x.as_i64()).unwrap_or(25);
    let team_names: Vec<&str> =
        lua_list(raid.get("teams")).iter().filter_map(|x| x.as_str().and_then(|id| teams.get(id)).and_then(|n| n.as_str())).collect();
    let (acc, tent, absent) = people(raid, queue);

    // the embed: the words; the picture: the people
    let mut lines = vec![format!("**{name}** · <t:{t}:F> · <t:{t}:R>")];
    let mut second = Vec::new();
    if let Some(l) = s(raid, "leader") {
        second.push(format!("Led by **{}**", short(l)));
    }
    if let Some(n) = s(raid, "note") {
        second.push(format!("“{n}”"));
    }
    if !second.is_empty() {
        lines.push(second.join(" · "));
    }
    if locked {
        lines.push("Locked: only the team and invited players sign up.".into());
    }
    if cancelled {
        lines.push("**This raid is cancelled.**".into());
    }
    let filename = format!("raid-{}.png", id.replace(|c: char| !c.is_ascii_alphanumeric(), "-"));
    let need = raid.get("need");
    let target = match need {
        Some(n) => (
            n.get("tank").and_then(|x| x.as_u64()).unwrap_or(0) as usize,
            n.get("heal").and_then(|x| x.as_u64()).unwrap_or(0) as usize,
            n.get("dps").and_then(|x| x.as_u64()).unwrap_or(0) as usize,
        ),
        None if size <= 10 => (2, 3, 5),
        None => (3, 6, 16),
    };
    let pill = if team_names.is_empty() { format!("{size}-man") } else { format!("{size}-man · Team {}", team_names.join(", ")) };
    let when = day_line(t);
    let card = RaidCard {
        plan_key: s(raid, "inst").unwrap_or("other"),
        title: name,
        when: &when,
        pill: &pill,
        accepted: acc.clone(),
        tentative: tent.clone(),
        absent: absent.clone(),
        target,
        cancelled,
    };
    let has_art = crate::render::art().is_some() && pictures();
    let png = if draw { crate::render::art().map(|art| crate::render::raid::draw(art, &card)) } else { None };
    let mut b = EmbedBuilder::new()
        .description(lines.join("\n"))
        .color(if cancelled { GREY } else { ORANGE })
        .footer(EmbedFooterBuilder::new("Sign up below or in game · DisasterZone"));
    if has_art {
        if let Ok(src) = ImageSource::attachment(&filename) {
            b = b.image(src);
        }
    } else {
        // (no art exported: the names as text)
        let names = |r: &str| acc.iter().filter(|p| p.role == r).map(|p| p.name.clone()).collect::<Vec<_>>().join(", ");
        b = b.description(format!(
            "{}\n\n**Tanks** {}\n**Healers** {}\n**Damage** {}",
            lines.join("\n"),
            names("tank"),
            names("heal"),
            names("dps")
        ));
    }
    let embed = b.build();
    let components = if cancelled {
        Vec::new()
    } else {
        let btn = |st: &str, label: &str, style, emoji: &str| {
            Component::Button(Button {
                id: None,
                custom_id: Some(format!("su:{id}:{st}")),
                disabled: false,
                emoji: crate::emoji::button(emoji),
                label: Some(label.to_string()),
                style,
                url: None,
                sku_id: None,
            })
        };
        vec![Component::ActionRow(ActionRow {
            id: None,
            components: vec![
                btn("A", "Accept", ButtonStyle::Success, "dz_ready"),
                btn("T", "Tentative", ButtonStyle::Secondary, "dz_waiting"),
                btn("X", "Can't come", ButtonStyle::Danger, "dz_notready"),
                btn("S", "Change spec", ButtonStyle::Secondary, ""),
            ],
        })]
    };
    let mut h = Sha256::new();
    h.update(format!("{lines:?}|{cancelled}|{when}|{pill}|{target:?}|{acc:?}|{tent:?}|{absent:?}|{has_art}").as_bytes());
    Rendered { embed, components, png, filename, hash: hex::encode(&h.finalize()[..8]) }
}

fn chan(id: &str) -> Option<Id<ChannelMarker>> {
    id.parse::<u64>().ok().and_then(Id::new_checked)
}

/// Post a message under `key` in `target`, or edit the one posted before when what it shows changed (its hash).
/// `fresh_only`: don't post it new (a cancelled raid never posted). Returns true when Discord was written to.
// ------------------------------------------------------------------------------------------------------------------
// When Discord says no: a missing permission is reported once (log + the launcher's Host section), not retried
// every few seconds
// ------------------------------------------------------------------------------------------------------------------

/// Pictures go with the posts (false once Discord refused one: the bot lacks Attach Files; text until a restart).
static ATTACH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
/// channel -> until when it is skipped (the bot can't post there at all)
static BLOCKED: std::sync::Mutex<BTreeMap<String, i64>> = std::sync::Mutex::new(BTreeMap::new());
/// What the launcher's Host section says (a missing permission), if anything.
pub static WARN: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

pub fn pictures() -> bool {
    ATTACH.load(std::sync::atomic::Ordering::Relaxed)
}

fn refused(e: &impl std::fmt::Display) -> bool {
    let t = e.to_string();
    t.contains("50013") || t.contains("50001")
}

fn channel_name(target: &str) -> String {
    bridge::load_channels().into_iter().find(|c| c.id == target).map(|c| c.name).unwrap_or_else(|| format!("channel {target}"))
}

/// A refusal: the pictures go first (Attach Files), then the channel (no access).
fn on_refused(target: &str, with_files: bool) {
    if with_files && pictures() {
        ATTACH.store(false, std::sync::atomic::Ordering::Relaxed);
        let w = format!(
            "Discord won't take the bot's pictures in {}: give the bot's role Attach Files, then restart the launcher. Posting text meanwhile.",
            channel_name(target)
        );
        eprintln!("posts: {w}");
        *WARN.lock().unwrap() = Some(w);
        return;
    }
    let now = crate::bot::unix_now() as i64;
    let mut b = BLOCKED.lock().unwrap();
    if b.get(target).is_none_or(|t| *t < now) {
        let w = format!(
            "The bot can't post in {}: check its permissions there (View Channel, Send Messages, Embed Links). Trying again in 15 minutes.",
            channel_name(target)
        );
        eprintln!("posts: {w}");
        *WARN.lock().unwrap() = Some(w);
    }
    b.insert(target.to_string(), now + 900);
}

async fn publish(http: &Client, posts: &mut BTreeMap<String, Post>, key: &str, target: &str, r: &Rendered, fresh_only: bool) -> bool {
    let old = posts.get(key).cloned();
    if old.as_ref().is_some_and(|p| p.channel == target && p.hash == r.hash) {
        return false;
    }
    if BLOCKED.lock().unwrap().get(target).is_some_and(|t| *t > crate::bot::unix_now() as i64) {
        return false;
    }
    let Some(ch) = chan(target) else { return false };
    let files: Vec<Attachment> =
        r.png.clone().map(|png| vec![Attachment::from_bytes(r.filename.clone(), png, 1)]).unwrap_or_default();
    let embeds = [r.embed.clone()];
    match old.filter(|p| p.channel == target) {
        Some(p) => {
            let Some(mid) = p.message.parse::<u64>().ok().and_then(Id::<MessageMarker>::new_checked) else { return false };
            // (the new picture replaces the old one: attachments not kept are dropped)
            match http.update_message(ch, mid).embeds(Some(&embeds)).components(Some(&r.components)).attachments(&files).await {
                Ok(_) => {
                    posts.insert(key.into(), Post { hash: r.hash.clone(), ..p });
                    true
                }
                Err(e) => {
                    if refused(&e) {
                        on_refused(target, !files.is_empty());
                    } else {
                        eprintln!("posts: edit {key}: {e}");
                    }
                    if e.to_string().contains("404") {
                        posts.remove(key); // (deleted by hand: posted again next time)
                    }
                    false
                }
            }
        }
        None if fresh_only => false,
        None => match http.create_message(ch).embeds(&embeds).components(&r.components).attachments(&files).await {
            Ok(resp) => match resp.model().await {
                Ok(m) => {
                    posts.insert(key.into(), Post { channel: target.to_string(), message: m.id.get().to_string(), hash: r.hash.clone() });
                    true
                }
                Err(_) => false,
            },
            Err(e) => {
                if refused(&e) {
                    on_refused(target, !files.is_empty());
                } else {
                    eprintln!("posts: post {key} in {target}: {e}");
                }
                false
            }
        },
    }
}

/// Post new raids and edit changed ones, then the week board. Returns how many messages were sent or edited.
pub async fn update(http: &Client, snap: &Value) -> usize {
    // (answers and saves both start an update: one at a time, so a post is never written twice at once)
    static ONE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _one = ONE.lock().await;
    let dc = snap.get("dc").cloned().unwrap_or(Value::Null);
    let teams = snap.get("teams").cloned().unwrap_or(Value::Null);
    let queue = bridge::load_queue();
    let mut posts = load_posts();
    let before = posts.clone();
    let unchanged = |posts: &BTreeMap<String, Post>, key: &str, target: &str, hash: &str| {
        posts.get(key).is_some_and(|p| p.channel == target && p.hash == hash)
    };
    let mut n = 0;
    for raid in lua_list(snap.get("raids")) {
        let Some(id) = s(raid, "id") else { continue };
        let Some(target) = target_channel(raid, &dc) else { continue };
        if unchanged(&posts, id, &target, &render(raid, &teams, &queue, false).hash) {
            continue;
        }
        let r = render(raid, &teams, &queue, true);
        let cancelled = raid.get("cancelled").and_then(|x| x.as_bool()).unwrap_or(false);
        if publish(http, &mut posts, id, &target, &r, cancelled).await
            || (r.png.is_some() && !pictures() && publish(http, &mut posts, id, &target, &render(raid, &teams, &queue, true), cancelled).await)
        {
            n += 1;
        }
    }
    if let Some(target) = s(&dc, "week") {
        let now = crate::bot::unix_now() as i64;
        if !unchanged(&posts, "_week", target, &render_week(snap, &queue, now, false).hash) {
            let r = render_week(snap, &queue, now, true);
            if publish(http, &mut posts, "_week", target, &r, false).await
                || (r.png.is_some() && !pictures() && publish(http, &mut posts, "_week", target, &render_week(snap, &queue, now, true), false).await)
            {
                n += 1;
            }
        }
    }
    if posts != before {
        if let Err(e) = save_json(&posts_path(), &posts) {
            eprintln!("posts: save: {e}");
        }
    }
    n
}

// ------------------------------------------------------------------------------------------------------------------
// The week board
// ------------------------------------------------------------------------------------------------------------------

/// What a raid still needs, the role furthest from its target: "needs 2 tanks", "needs a healer", or "".
pub fn needs(raid: &Value, acc: &[Person]) -> String {
    let size = raid.get("size").and_then(|x| x.as_i64()).unwrap_or(25);
    let need = raid.get("need");
    let want = |k: &str, d10: usize, d25: usize| {
        need.and_then(|n| n.get(k)).and_then(|x| x.as_u64()).map(|x| x as usize).unwrap_or(if size <= 10 { d10 } else { d25 })
    };
    let count = |r: &str| acc.iter().filter(|p| p.role == r).count();
    let short = [
        (want("tank", 2, 3).saturating_sub(count("tank")), "a tank", "tanks"),
        (want("heal", 3, 6).saturating_sub(count("heal")), "a healer", "healers"),
        (want("dps", 5, 16).saturating_sub(count("dps")), "a damage dealer", "damage dealers"),
    ];
    match short.iter().filter(|s| s.0 > 0).max_by_key(|s| s.0) {
        Some((1, one, _)) => format!("needs {one}"),
        Some((n, _, many)) => format!("needs {n} {many}"),
        None => String::new(),
    }
}

/// The coming seven days' raids as the board's tiles (soonest first).
pub fn week_tiles(snap: &Value, queue: &[Record], now: i64) -> Vec<crate::render::week::Tile> {
    use chrono::{Local, TimeZone};
    let mut out = Vec::new();
    for raid in lua_list(snap.get("raids")) {
        let t = raid.get("t").and_then(|x| x.as_i64()).unwrap_or(0);
        if t + 4 * 3600 < now || t > now + 7 * 86400 {
            continue;
        }
        let (acc, _, _) = people(raid, queue);
        let teams = snap.get("teams").cloned().unwrap_or(Value::Null);
        let team: Vec<&str> =
            lua_list(raid.get("teams")).iter().filter_map(|x| x.as_str().and_then(|id| teams.get(id)).and_then(|n| n.as_str())).collect();
        let base = s(raid, "title").or(s(raid, "name")).unwrap_or("Raid");
        out.push(crate::render::week::Tile {
            plan_key: s(raid, "inst").unwrap_or("other").into(),
            day: Local.timestamp_opt(t, 0).single().map(|d| d.format("%A %H:%M").to_string()).unwrap_or_default(),
            name: if team.is_empty() { base.into() } else { format!("{base} · {}", team.join(", ")) },
            have: acc.len(),
            size: raid.get("size").and_then(|x| x.as_u64()).unwrap_or(25) as usize,
            need: needs(raid, &acc),
            cancelled: raid.get("cancelled").and_then(|x| x.as_bool()).unwrap_or(false),
        });
    }
    out
}

pub fn render_week(snap: &Value, queue: &[Record], now: i64, draw: bool) -> Rendered {
    use chrono::{Local, TimeZone};
    let tiles = week_tiles(snap, queue, now);
    let week = Local.timestamp_opt(now, 0).single().map(|d| d.format("Week %V").to_string()).unwrap_or_default();
    let stamp = Local.timestamp_opt(now, 0).single().map(|d| d.format("%H:%M").to_string()).unwrap_or_default();
    let has_art = crate::render::art().is_some() && pictures();
    let png = if draw {
        crate::render::art().map(|art| crate::render::week::draw(art, "This week", &format!("{week} · updated {stamp}"), &tiles))
    } else {
        None
    };
    let filename = "week.png".to_string();
    let mut b = EmbedBuilder::new().color(ORANGE);
    if has_art {
        if let Ok(src) = ImageSource::attachment(&filename) {
            b = b.image(src);
        }
    } else {
        let lines: Vec<String> = tiles.iter().map(|t| format!("**{}** · {} · {}/{} {}", t.name, t.day, t.have, t.size, t.need)).collect();
        b = b.description(if lines.is_empty() { "No raids planned in the next seven days.".into() } else { lines.join("\n") });
    }
    let btn = |id: &str, label: &str, style| {
        Component::Button(Button {
            id: None,
            custom_id: Some(id.into()),
            disabled: false,
            emoji: None,
            label: Some(label.into()),
            style,
            url: None,
            sku_id: None,
        })
    };
    let components = vec![Component::ActionRow(ActionRow {
        id: None,
        components: vec![
            btn("wk:raids", "My raids", ButtonStyle::Primary),
            btn("wk:bis", "My BiS", ButtonStyle::Secondary),
            btn("wk:chars", "My characters", ButtonStyle::Secondary),
        ],
    })];
    let mut h = Sha256::new();
    // (the time stamp is left out: the board is only edited when a raid on it changes)
    h.update(format!("{:?}", tiles.iter().map(|t| (&t.day, &t.name, t.have, t.size, &t.need, t.cancelled)).collect::<Vec<_>>()).as_bytes());
    h.update(week.as_bytes());
    Rendered { embed: b.build(), components, png, filename, hash: hex::encode(&h.finalize()[..8]) }
}

/// After an answer in Discord: the posts again from the last snapshot (only the changed one is edited).
pub async fn refresh(http: &Client) {
    if let Some(snap) = crate::signup::current_snap() {
        update(http, &snap).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn raid() -> Value {
        json!({ "id": "r1", "t": 1791900000, "name": "Karazhan", "inst": "kara", "size": 10, "teams": { "1": "tm1" },
                "note": "Bring pots", "leader": "Tsumil-Thunderstrike",
                "signups": { "1": { "key": "Lee-Thunderstrike", "st": "accept", "role": "tank", "class": "WARRIOR", "spec": "Protection" },
                             "2": { "key": "Rita-Thunderstrike", "st": "tentative", "class": "PRIEST" } } })
    }

    fn rec(name: &str, st: &str) -> Record {
        Record {
            id: "x".into(), kind: "signup".into(), at: 1, by: "u".into(), discord: "9".into(),
            body: json!({ "raid": "r1", "name": name, "class": "PRIEST", "sp": 2, "st": st }),
        }
    }

    #[test]
    fn team_channel_wins_over_the_guild_one() {
        let dc = json!({ "guild": "111", "teams": { "tm1": "222" } });
        assert_eq!(target_channel(&raid(), &dc).as_deref(), Some("222"));
        assert_eq!(target_channel(&raid(), &json!({ "guild": "111" })).as_deref(), Some("111"));
        assert_eq!(target_channel(&raid(), &json!({})), None);
    }

    #[test]
    fn discord_answers_show_pending_until_the_game_has_them() {
        let (acc, tent, _) = people(&raid(), &[rec("Rita", "A")]);
        assert_eq!(acc.len(), 2);
        let rita = acc.iter().find(|p| p.name == "Rita").unwrap();
        assert!(rita.pending && rita.role == "heal" && rita.spec == 2);
        assert!(tent.is_empty());
        let lee = acc.iter().find(|p| p.name == "Lee").unwrap();
        assert!(!lee.pending && lee.spec == 3 && lee.role == "tank");
    }

    #[test]
    fn hash_follows_the_answers() {
        let a = render(&raid(), &json!({ "tm1": "Main" }), &[], false);
        assert_eq!(a.hash, render(&raid(), &json!({ "tm1": "Main" }), &[], true).hash);
        assert_ne!(a.hash, render(&raid(), &json!({ "tm1": "Main" }), &[rec("Rita", "A")], false).hash);
        assert!(a.embed.description.unwrap().contains("Led by **Tsumil**"));
    }

    #[test]
    fn cancelled_raid_has_no_buttons() {
        let mut r = raid();
        r["cancelled"] = json!(true);
        let out = render(&r, &json!({}), &[], false);
        assert!(out.components.is_empty());
    }
}
