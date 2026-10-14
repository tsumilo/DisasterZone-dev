//! Raid reminders: an hour before a raid, a DM to everyone who is in and made their character in Discord,
//! with "Running late" (how late: the raid leader hears of it, the sign-up note in game says it) and "Can't make it"
//! (they're marked can't come, and whoever is tentative or benched for that raid gets a ping that a spot opened).
//! Who was reminded is kept in <config>/DisasterZoneLauncher/bridge_reminders.json; /character turns them off.
//!
//! Custom ids: rl:<raid>:<name> Running late · rm:<raid>:<name> its minutes menu · rx:<raid>:<name> Can't make it
//! · rt:<user> the /character toggle.

use crate::core::bridge::{self, lua_list, save_json};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use twilight_http::Client;
use twilight_model::channel::message::component::{ActionRow, Button, ButtonStyle, Component, SelectMenu, SelectMenuOption, SelectMenuType};
use twilight_model::channel::message::Embed;
use twilight_util::builder::embed::EmbedBuilder;

const AHEAD: i64 = 3600;

fn cfg(name: &str) -> PathBuf {
    crate::data_dir().join(name)
}

/// raid id -> Discord users reminded
fn load_sent() -> BTreeMap<String, BTreeSet<String>> {
    std::fs::read(cfg("bridge_reminders.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

/// Discord users who turned reminders off
fn load_off() -> BTreeSet<String> {
    std::fs::read(cfg("bridge_reminders_off.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

pub fn is_on(user: &str) -> bool {
    !load_off().contains(user)
}

/// /character's button: reminders on or off for this user. Returns the new state.
pub fn toggle(user: &str) -> bool {
    let mut off = load_off();
    let on = if off.remove(user) { true } else { off.insert(user.to_string()); false };
    let _ = save_json(&cfg("bridge_reminders_off.json"), &off);
    on
}

fn short(k: &str) -> &str {
    k.split('-').next().unwrap_or(k)
}

/// Who is in a raid (snapshot + pending Discord answers): (name, class, spec) of everyone accepted.
fn accepted(raid: &Value) -> Vec<(String, String, u32)> {
    let (acc, _, _) = crate::posts::people(raid, &bridge::load_queue());
    acc.into_iter().map(|p| (p.name, p.class, p.spec)).collect()
}

/// The Discord user who made this character, if any.
fn owner(profiles: &bridge::Profiles, name: &str) -> Option<String> {
    bridge::owner_of(profiles, name)
}

fn button(id: String, label: &str, style: ButtonStyle, emoji: &str) -> Component {
    Component::Button(Button {
        id: None,
        custom_id: Some(id),
        disabled: false,
        emoji: crate::emoji::button(emoji),
        label: Some(label.into()),
        style,
        url: None,
        sku_id: None,
    })
}

fn raid_name(r: &Value) -> String {
    r.get("title").or(r.get("name")).and_then(|x| x.as_str()).unwrap_or("The raid").to_string()
}

fn reminder(raid: &Value, name: &str, class: &str, spec: u32) -> (Embed, Vec<Component>) {
    let t = raid.get("t").and_then(|x| x.as_i64()).unwrap_or(0);
    let id = raid.get("id").and_then(|x| x.as_str()).unwrap_or("");
    let leader = raid.get("leader").and_then(|x| x.as_str()).map(short);
    let spec_name = crate::signup::CLASSES.iter().find(|c| c.0 == class).and_then(|c| c.2.get(spec.saturating_sub(1) as usize)).copied();
    let mut d = format!(
        "You're in as {}**{name}**{}.",
        crate::emoji::class_tag(class),
        spec_name.map(|s| format!(", {s}")).unwrap_or_default()
    );
    if let Some(l) = leader {
        d.push_str(&format!("\nInvites from **{l}** at <t:{}:t>.", t - 600));
    }
    if let Some(n) = raid.get("note").and_then(|x| x.as_str()) {
        d.push_str(&format!("\n“{n}”"));
    }
    let embed = EmbedBuilder::new()
        .title(format!("{} starts <t:{t}:R>", raid_name(raid)))
        .description(d)
        .color(0xFF8000)
        .build();
    let comps = vec![Component::ActionRow(ActionRow {
        id: None,
        components: vec![
            button(format!("rl:{id}:{name}"), "Running late", ButtonStyle::Secondary, "dz_hourglass"),
            button(format!("rx:{id}:{name}"), "Can't make it", ButtonStyle::Danger, "dz_notready"),
        ],
    })];
    (embed, comps)
}

async fn dm(http: &Client, user: &str, embed: Option<Embed>, text: Option<&str>, comps: &[Component]) -> bool {
    let Some(uid) = user.parse::<u64>().ok().and_then(twilight_model::id::Id::new_checked) else { return false };
    let Ok(resp) = http.create_private_channel(uid).await else { return false };
    let Ok(ch) = resp.model().await else { return false };
    let embeds: Vec<Embed> = embed.into_iter().collect();
    let mut req = http.create_message(ch.id).embeds(&embeds).components(comps);
    if let Some(t) = text {
        req = req.content(t);
    }
    req.await.is_ok()
}

/// Is it time for a raid's reminders: in its last hour, but not under ten minutes before (too late to help)?
pub fn due(raid: &Value, now: i64) -> bool {
    let t = raid.get("t").and_then(|x| x.as_i64()).unwrap_or(0);
    t - now <= AHEAD && t - now >= 600 && raid.get("cancelled").and_then(|x| x.as_bool()) != Some(true)
}

/// Called every minute or so: DMs for raids starting within the hour (once per raid and person).
pub async fn tick(http: &Client, snap: &Value, now: i64) {
    let mut sent = load_sent();
    let profiles = bridge::load_profiles();
    let mut changed = false;
    for raid in lua_list(snap.get("raids")) {
        if !due(raid, now) {
            continue;
        }
        let id = raid.get("id").and_then(|x| x.as_str()).unwrap_or("").to_string();
        for (name, class, spec) in accepted(raid) {
            let Some(user) = owner(&profiles, &name) else { continue };
            if !is_on(&user) || sent.get(&id).is_some_and(|s| s.contains(&user)) {
                continue;
            }
            let (e, c) = reminder(raid, &name, &class, spec);
            dm(http, &user, Some(e), None, &c).await;
            sent.entry(id.clone()).or_default().insert(user);
            changed = true;
        }
    }
    // (raids long over are forgotten)
    let live: BTreeSet<String> =
        lua_list(snap.get("raids")).iter().filter_map(|r| r.get("id").and_then(|x| x.as_str()).map(str::to_string)).collect();
    let before = sent.len();
    sent.retain(|k, _| live.contains(k));
    if changed || sent.len() != before {
        let _ = save_json(&cfg("bridge_reminders.json"), &sent);
    }
}

fn find_raid<'a>(snap: &'a Value, id: &str) -> Option<&'a Value> {
    lua_list(snap.get("raids")).into_iter().find(|r| r.get("id").and_then(|x| x.as_str()) == Some(id))
}

/// A click on a reminder (or its menu). Returns the edited reminder: (text, embed, components).
pub async fn click(http: &Client, user: &str, by: &str, custom: &str, values: &[String]) -> (String, Option<Embed>, Vec<Component>) {
    let snap = crate::signup::current_snap().unwrap_or(Value::Null);
    let parts: Vec<&str> = custom.splitn(3, ':').collect();
    let [kind, id, name] = parts[..] else { return ("Unknown button.".into(), None, Vec::new()) };
    let Some(raid) = find_raid(&snap, id) else { return ("That raid is gone.".into(), None, Vec::new()) };
    let rname = raid_name(raid);
    let profiles = bridge::load_profiles();
    if owner(&profiles, name).as_deref() != Some(user) {
        return ("That's someone else's reminder.".into(), None, Vec::new());
    }
    let ch = profiles.get(user).and_then(|cs| cs.iter().find(|c| short(&c.name).eq_ignore_ascii_case(short(name))).cloned());
    match kind {
        "rl" => {
            let opts = [("10 minutes", "10"), ("15 minutes", "15"), ("30 minutes", "30"), ("An hour or more", "60")]
                .iter()
                .map(|(l, v)| SelectMenuOption { default: false, description: None, emoji: None, label: (*l).into(), value: (*v).into() })
                .collect();
            let m = Component::SelectMenu(SelectMenu {
                id: None,
                channel_types: None,
                custom_id: format!("rm:{id}:{name}"),
                default_values: None,
                disabled: false,
                kind: SelectMenuType::Text,
                max_values: Some(1),
                min_values: Some(1),
                options: Some(opts),
                placeholder: Some("How late?".into()),
                required: None,
            });
            (format!("How late will you be for **{rname}**?"), None, vec![Component::ActionRow(ActionRow { id: None, components: vec![m] })])
        }
        "rm" => {
            let mins = values.first().map(String::as_str).unwrap_or("15");
            let label = if mins == "60" { "an hour or more".to_string() } else { format!("{mins} minutes") };
            // the sign-up note in game says it
            if let Some(c) = &ch {
                queue_signup(id, c, "A", Some(format!("late {}", if mins == "60" { "1h+".to_string() } else { format!("{mins} min") })), user, by);
            }
            let leader = raid.get("leader").and_then(|x| x.as_str()).map(short).unwrap_or("The raid leader").to_string();
            let line = format!("{}**{}** will be about {label} late for **{rname}**.", crate::emoji::tag("dz_hourglass"), short(name));
            tell_leader(http, raid, &profiles, &line).await;
            (format!("Got it. **{leader}** knows you'll be about {label} late. Your spot is kept."), None, Vec::new())
        }
        "rx" => {
            if let Some(c) = &ch {
                queue_signup(id, c, "X", None, user, by);
            }
            let pinged = ping_bench(http, raid, &profiles).await;
            let after = if pinged.is_empty() {
                String::new()
            } else {
                format!(" The bench got a ping: {}.", pinged.join(", "))
            };
            (format!("You're off **{rname}**.{after}"), None, Vec::new())
        }
        _ => ("Unknown button.".into(), None, Vec::new()),
    }
}

fn queue_signup(raid: &str, c: &bridge::Char, st: &str, note: Option<String>, user: &str, by: &str) {
    let now = crate::bot::unix_now();
    let r = bridge::Record {
        id: format!("rm_{now}_{user}_{st}"),
        kind: "signup".into(),
        at: now,
        by: by.to_string(),
        body: json!({ "raid": raid, "name": c.name, "class": c.class, "sp": c.spec, "st": st, "note": note }),
        discord: user.to_string(),
        sig: String::new(),
    };
    let _ = bridge::push(r);
}

/// The raid leader hears it: by DM when they made their character in Discord, else in the raid's channel.
async fn tell_leader(http: &Client, raid: &Value, profiles: &bridge::Profiles, line: &str) {
    if let Some(user) = raid.get("leader").and_then(|x| x.as_str()).and_then(|l| owner(profiles, l)) {
        if dm(http, &user, None, Some(line), &[]).await {
            return;
        }
    }
    let id = raid.get("id").and_then(|x| x.as_str()).unwrap_or("");
    if let Some(p) = crate::posts::load_posts().get(id) {
        if let Some(ch) = p.channel.parse::<u64>().ok().and_then(twilight_model::id::Id::new_checked) {
            let _ = http.create_message(ch).content(line).await;
        }
    }
}

/// Everyone tentative or benched for the raid who made a character in Discord: a DM with an Accept button.
async fn ping_bench(http: &Client, raid: &Value, profiles: &bridge::Profiles) -> Vec<String> {
    let (_, tent, _) = crate::posts::people(raid, &bridge::load_queue());
    let id = raid.get("id").and_then(|x| x.as_str()).unwrap_or("");
    let t = raid.get("t").and_then(|x| x.as_i64()).unwrap_or(0);
    let mut out = Vec::new();
    for name in tent {
        let Some(user) = owner(profiles, &name) else { continue };
        let comps = vec![Component::ActionRow(ActionRow {
            id: None,
            components: vec![button(format!("su:{id}:A"), "Take the spot", ButtonStyle::Success, "dz_ready")],
        })];
        let text = format!("A spot opened in **{}**, <t:{t}:R>. Want it?", raid_name(raid));
        if dm(http, &user, None, Some(&text), &comps).await {
            out.push(name);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reminders_go_in_the_last_hour() {
        let r = |t: i64| json!({ "id": "r", "t": t });
        assert!(!due(&r(10_000 + 3700), 10_000));
        assert!(due(&r(10_000 + 3600), 10_000));
        assert!(due(&r(10_000 + 900), 10_000));
        assert!(!due(&r(10_000 + 300), 10_000));
        assert!(!due(&json!({ "t": 10_000 + 1800, "cancelled": true }), 10_000));
    }
}
