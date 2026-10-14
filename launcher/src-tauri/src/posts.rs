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

pub fn render(raid: &Value, teams: &Value, queue: &[Record]) -> Rendered {
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
    let png = crate::render::art().map(|art| crate::render::raid::draw(art, &card));
    let mut b = EmbedBuilder::new()
        .description(lines.join("\n"))
        .color(if cancelled { GREY } else { ORANGE })
        .footer(EmbedFooterBuilder::new("Sign up below or in game · DisasterZone"));
    if png.is_some() {
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
    h.update(format!("{lines:?}|{cancelled}|{when}|{pill}|{target:?}|{acc:?}|{tent:?}|{absent:?}|{}", png.is_some()).as_bytes());
    Rendered { embed, components, png, filename, hash: hex::encode(&h.finalize()[..8]) }
}

fn chan(id: &str) -> Option<Id<ChannelMarker>> {
    id.parse::<u64>().ok().and_then(Id::new_checked)
}

/// Post new raids and edit changed ones. Returns how many messages were sent or edited.
pub async fn update(http: &Client, snap: &Value) -> usize {
    let dc = snap.get("dc").cloned().unwrap_or(Value::Null);
    let teams = snap.get("teams").cloned().unwrap_or(Value::Null);
    let queue = bridge::load_queue();
    let mut posts = load_posts();
    let mut n = 0;
    for raid in lua_list(snap.get("raids")) {
        let Some(id) = s(raid, "id") else { continue };
        let Some(target) = target_channel(raid, &dc) else { continue };
        let old = posts.get(id).cloned();
        let r = render(raid, &teams, &queue);
        if old.as_ref().is_some_and(|p| p.channel == target && p.hash == r.hash) {
            continue;
        }
        let cancelled = raid.get("cancelled").and_then(|x| x.as_bool()).unwrap_or(false);
        let Some(ch) = chan(&target) else { continue };
        let files: Vec<Attachment> =
            r.png.clone().map(|png| vec![Attachment::from_bytes(r.filename.clone(), png, 1)]).unwrap_or_default();
        let embeds = [r.embed.clone()];
        match old.filter(|p| p.channel == target) {
            Some(p) => {
                let Some(mid) = p.message.parse::<u64>().ok().and_then(Id::<MessageMarker>::new_checked) else { continue };
                // (the new picture replaces the old one: attachments not kept are dropped)
                match http.update_message(ch, mid).embeds(Some(&embeds)).components(Some(&r.components)).attachments(&files).await {
                    Ok(_) => {
                        posts.insert(id.into(), Post { hash: r.hash, ..p });
                        n += 1;
                    }
                    Err(e) => {
                        eprintln!("posts: edit {id}: {e}");
                        if e.to_string().contains("404") {
                            posts.remove(id); // (deleted by hand: posted again next time)
                        }
                    }
                }
            }
            None => {
                if cancelled {
                    continue; // (never posted: nothing to say)
                }
                match http.create_message(ch).embeds(&embeds).components(&r.components).attachments(&files).await {
                    Ok(resp) => {
                        if let Ok(m) = resp.model().await {
                            posts.insert(id.into(), Post { channel: target.clone(), message: m.id.get().to_string(), hash: r.hash });
                            n += 1;
                        }
                    }
                    Err(e) => eprintln!("posts: post {id} in {target}: {e}"),
                }
            }
        }
    }
    if n > 0 {
        if let Err(e) = save_json(&posts_path(), &posts) {
            eprintln!("posts: save: {e}");
        }
    }
    n
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
        let a = render(&raid(), &json!({ "tm1": "Main" }), &[]);
        assert_eq!(a.hash, render(&raid(), &json!({ "tm1": "Main" }), &[]).hash);
        assert_ne!(a.hash, render(&raid(), &json!({ "tm1": "Main" }), &[rec("Rita", "A")]).hash);
        assert!(a.embed.description.unwrap().contains("Led by **Tsumil**"));
    }

    #[test]
    fn cancelled_raid_has_no_buttons() {
        let mut r = raid();
        r["cancelled"] = json!(true);
        let out = render(&r, &json!({}), &[]);
        assert!(out.components.is_empty());
    }
}
