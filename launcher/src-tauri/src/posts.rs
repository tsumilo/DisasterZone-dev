//! Raid posts (host mode): every raid in the addon's snapshot (DisasterZoneBridgeDB.snap, addon Core/Bridge.lua) gets
//! a message in its team's channel (or the guild channel), edited when what it shows changes. Which message belongs to
//! which raid is kept in <config>/DisasterZoneLauncher/bridge_posts.json.

use crate::core::bridge::{lua_list, save_json};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::PathBuf;
use twilight_http::Client;
use twilight_model::channel::message::component::{ActionRow, Button, ButtonStyle, Component};
use twilight_model::channel::message::Embed;
use twilight_model::id::marker::{ChannelMarker, MessageMarker};
use twilight_model::id::Id;
use twilight_model::util::Timestamp;
use twilight_util::builder::embed::{EmbedBuilder, EmbedFieldBuilder, EmbedFooterBuilder};

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

pub struct Rendered {
    pub embed: Embed,
    pub components: Vec<Component>,
    /// changes only when what the post shows changes (not with every save)
    pub hash: String,
}

const ROLES: [(&str, &str); 4] = [("tank", "Tanks"), ("healer", "Healers"), ("melee", "Melee"), ("ranged", "Ranged")];

pub fn render(raid: &Value, teams: &Value, snap_at: i64) -> Rendered {
    let id = s(raid, "id").unwrap_or("?");
    let t = raid.get("t").and_then(|x| x.as_i64()).unwrap_or(0);
    let cancelled = raid.get("cancelled").and_then(|x| x.as_bool()).unwrap_or(false);
    let locked = raid.get("locked").and_then(|x| x.as_bool()).unwrap_or(false);
    let name = s(raid, "title").or(s(raid, "name")).unwrap_or("Raid");
    let mut lines = vec![format!("<t:{t}:F> · <t:{t}:R>")];
    let team_names: Vec<&str> =
        lua_list(raid.get("teams")).iter().filter_map(|x| x.as_str().and_then(|id| teams.get(id)).and_then(|n| n.as_str())).collect();
    let mut facts = Vec::new();
    if !team_names.is_empty() {
        facts.push(format!("Team {}", team_names.join(", ")));
    }
    if let Some(sz) = raid.get("size").and_then(|x| x.as_i64()) {
        facts.push(format!("{sz}-man"));
    }
    if s(raid, "title").is_some() {
        facts.push(s(raid, "name").unwrap_or("").to_string());
    }
    if let Some(l) = s(raid, "leader") {
        facts.push(format!("led by {}", short(l)));
    }
    if !facts.is_empty() {
        lines.push(facts.join(" · "));
    }
    if let Some(n) = s(raid, "note") {
        lines.push(format!("> {n}"));
    }
    if locked {
        lines.push("Locked: only the invited sign up.".into());
    }
    if cancelled {
        lines.push("**Cancelled.**".into());
    }
    let signups = lua_list(raid.get("signups"));
    let names = |pred: &dyn Fn(&Value) -> bool| -> Vec<String> {
        signups.iter().filter(|x| pred(x)).map(|x| short(s(x, "key").unwrap_or("?")).to_string()).collect()
    };
    let mut b = EmbedBuilder::new()
        .title(if cancelled { format!("Cancelled: {name}") } else { name.to_string() })
        .description(lines.join("\n"))
        .color(if cancelled { GREY } else { ORANGE })
        .footer(EmbedFooterBuilder::new("Sign up here or in game · DisasterZone"));
    if let Ok(ts) = Timestamp::from_secs(snap_at) {
        b = b.timestamp(ts);
    }
    let mut shown = String::new();
    if !cancelled {
        let accepted = |x: &Value| s(x, "st") == Some("accept");
        let total = names(&accepted).len();
        for (role, label) in ROLES {
            let list = names(&|x: &Value| accepted(x) && s(x, "role") == Some(role));
            shown.push_str(&format!("{label}:{};", list.join(",")));
            b = b.field(
                EmbedFieldBuilder::new(format!("{label} ({})", list.len()), if list.is_empty() { "—".into() } else { list.join("\n") })
                    .inline(),
            );
        }
        let other = names(&|x: &Value| accepted(x) && !ROLES.iter().any(|(r, _)| s(x, "role") == Some(r)));
        if !other.is_empty() {
            b = b.field(EmbedFieldBuilder::new(format!("Spec unknown ({})", other.len()), other.join("\n")).inline());
        }
        for (st, label) in [("tentative", "Tentative"), ("bench", "Bench"), ("absent", "Can't come")] {
            let list = names(&|x: &Value| s(x, "st") == Some(st));
            if !list.is_empty() {
                shown.push_str(&format!("{st}:{};", list.join(",")));
                b = b.field(EmbedFieldBuilder::new(format!("{label} ({})", list.len()), list.join(", ")));
            }
        }
        shown.push_str(&format!("total:{total};{other:?}"));
    }
    let embed = b.build();
    let components = if cancelled {
        Vec::new()
    } else {
        let btn = |st: &str, label: &str, style| {
            Component::Button(Button {
                id: None,
                custom_id: Some(format!("su:{id}:{st}")),
                disabled: false,
                emoji: None,
                label: Some(label.to_string()),
                style,
                url: None,
                sku_id: None,
            })
        };
        vec![Component::ActionRow(ActionRow {
            id: None,
            components: vec![
                btn("A", "Accept", ButtonStyle::Success),
                btn("T", "Tentative", ButtonStyle::Secondary),
                btn("X", "Can't come", ButtonStyle::Danger),
            ],
        })]
    };
    let mut h = Sha256::new();
    h.update(format!("{name}|{lines:?}|{cancelled}|{shown}").as_bytes());
    Rendered { embed, components, hash: hex::encode(&h.finalize()[..8]) }
}

fn chan(id: &str) -> Option<Id<ChannelMarker>> {
    id.parse::<u64>().ok().and_then(Id::new_checked)
}

/// Post new raids and edit changed ones. Returns how many messages were sent or edited.
pub async fn update(http: &Client, snap: &Value) -> usize {
    let dc = snap.get("dc").cloned().unwrap_or(Value::Null);
    let teams = snap.get("teams").cloned().unwrap_or(Value::Null);
    let at = snap.get("at").and_then(|x| x.as_i64()).unwrap_or(0);
    let mut posts = load_posts();
    let mut n = 0;
    for raid in lua_list(snap.get("raids")) {
        let Some(id) = s(raid, "id") else { continue };
        let Some(target) = target_channel(raid, &dc) else { continue };
        let r = render(raid, &teams, at);
        let old = posts.get(id).cloned();
        if old.as_ref().is_some_and(|p| p.channel == target && p.hash == r.hash) {
            continue;
        }
        let cancelled = raid.get("cancelled").and_then(|x| x.as_bool()).unwrap_or(false);
        let Some(ch) = chan(&target) else { continue };
        match old.filter(|p| p.channel == target) {
            Some(p) => {
                let Some(mid) = p.message.parse::<u64>().ok().and_then(Id::<MessageMarker>::new_checked) else { continue };
                let embeds = [r.embed];
                match http.update_message(ch, mid).embeds(Some(&embeds)).components(Some(&r.components)).await {
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
                let embeds = [r.embed];
                match http.create_message(ch).embeds(&embeds).components(&r.components).await {
                    Ok(resp) => {
                        if let Ok(m) = resp.model().await {
                            posts.insert(
                                id.into(),
                                Post { channel: target.clone(), message: m.id.get().to_string(), hash: r.hash },
                            );
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn raid() -> Value {
        json!({ "id": "r1", "t": 1791900000, "name": "Karazhan", "size": 10, "teams": { "1": "tm1" },
                "note": "Bring pots", "leader": "Tsumil-Thunderstrike",
                "signups": { "1": { "key": "Lee-Thunderstrike", "st": "accept", "role": "tank" },
                             "2": { "key": "Rita-Thunderstrike", "st": "tentative", "role": "healer" } } })
    }

    #[test]
    fn team_channel_wins_over_the_guild_one() {
        let dc = json!({ "guild": "111", "teams": { "tm1": "222" } });
        assert_eq!(target_channel(&raid(), &dc).as_deref(), Some("222"));
        assert_eq!(target_channel(&raid(), &json!({ "guild": "111" })).as_deref(), Some("111"));
        assert_eq!(target_channel(&raid(), &json!({})), None);
    }

    #[test]
    fn post_shows_roles_and_answers() {
        let r = render(&raid(), &json!({ "tm1": "Main" }), 1791800000);
        let e = &r.embed;
        assert_eq!(e.title.as_deref(), Some("Karazhan"));
        let d = e.description.as_deref().unwrap();
        assert!(d.contains("<t:1791900000:F>") && d.contains("Team Main") && d.contains("led by Tsumil") && d.contains("Bring pots"));
        assert!(e.fields.iter().any(|f| f.name == "Tanks (1)" && f.value == "Lee"));
        assert!(e.fields.iter().any(|f| f.name == "Tentative (1)" && f.value == "Rita"));
        assert_eq!(r.components.len(), 1);
    }

    #[test]
    fn hash_ignores_the_save_time_but_not_answers() {
        let a = render(&raid(), &json!({}), 1);
        assert_eq!(a.hash, render(&raid(), &json!({}), 2).hash);
        let mut changed = raid();
        changed["signups"]["2"]["st"] = json!("accept");
        assert_ne!(a.hash, render(&changed, &json!({}), 1).hash);
    }

    #[test]
    fn cancelled_raid_has_no_buttons() {
        let mut r = raid();
        r["cancelled"] = json!(true);
        let out = render(&r, &json!({}), 1);
        assert!(out.components.is_empty());
        assert!(out.embed.title.unwrap().starts_with("Cancelled"));
    }
}
