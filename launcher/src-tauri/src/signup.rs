//! Signing up from Discord (host mode): /link, the raid post's buttons and the spec picker. A sign-up becomes a
//! "signup" record in the bridge queue; the host's addon applies it at its next /reload (RaidPlan:SignUpFor, the same
//! checks as signing up in game) and shares it with the guild. A refusal comes back as a DM (bot.rs).

use crate::core::bridge::{self, lua_list};
use serde_json::{json, Value};
use std::sync::Mutex;
use twilight_model::channel::message::component::{ActionRow, Component, SelectMenu, SelectMenuOption, SelectMenuType};

/// The newest snapshot the host's addon wrote (DisasterZoneBridgeDB.snap), kept by the bot's watch.
static SNAP: Mutex<Option<Value>> = Mutex::new(None);
static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub fn set_snap(v: Value) {
    *SNAP.lock().unwrap() = Some(v);
}

fn snap() -> Value {
    SNAP.lock().unwrap().clone().unwrap_or(Value::Null)
}

pub enum Answer {
    Text(String),
    Picker(String, Vec<Component>),
}

fn short(key: &str) -> &str {
    key.split('-').next().unwrap_or(key)
}

fn raid_name(snap: &Value, raid: &str) -> String {
    lua_list(snap.get("raids"))
        .into_iter()
        .find(|r| r.get("id").and_then(|x| x.as_str()) == Some(raid))
        .and_then(|r| r.get("title").or(r.get("name")).and_then(|x| x.as_str()).map(str::to_string))
        .unwrap_or_else(|| "the raid".into())
}

const NOT_LINKED: &str =
    "Link your character first: type **/link** here, then the code it gives you in game (`/dz link CODE`).";

pub fn link_cmd(user: &str, now: u64) -> String {
    let had = bridge::load_links().links.get(user).cloned();
    match bridge::new_code(user, now) {
        Ok(code) => {
            let was = had.map(|k| format!("You are linked to **{}** now; this moves the link.\n", short(&k))).unwrap_or_default();
            format!(
                "{was}In game, on your character, type:\n`/dz link {code}`\nThe code works for 7 days. The bot knows you after the host's next /reload."
            )
        }
        Err(e) => format!("Could not make a code: {e}"),
    }
}

/// A raid post's button: custom id "su:<raid>:<A|T|X>".
pub fn button(user: &str, name: &str, custom: &str, now: u64) -> Answer {
    let mut parts = custom.splitn(3, ':');
    let (Some("su"), Some(raid), Some(st)) = (parts.next(), parts.next(), parts.next()) else {
        return Answer::Text("Unknown button.".into());
    };
    let Some(key) = bridge::load_links().links.get(user).cloned() else { return Answer::Text(NOT_LINKED.into()) };
    let snap = snap();
    if st != "A" {
        return Answer::Text(queue(raid, &key, st, None, user, name, now, &snap));
    }
    // Accept: which character and spec
    let chars = snap.get("chars").cloned().unwrap_or(Value::Null);
    let me = chars.get(&key);
    let alts: Vec<String> = me
        .map(|c| lua_list(c.get("alts")).iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
        .filter(|v: &Vec<String>| !v.is_empty())
        .unwrap_or_else(|| vec![key.clone()]);
    let mut options = Vec::new();
    for k in &alts {
        let Some(c) = chars.get(k) else { continue };
        let last = c.get("last").and_then(|x| x.as_i64());
        for (i, spec) in lua_list(c.get("specs")).iter().enumerate() {
            let Some(label) = spec.as_str() else { continue };
            if options.len() >= 25 {
                break;
            }
            options.push(SelectMenuOption {
                default: k == &key && last == Some(i as i64 + 1),
                description: c.get("class").and_then(|x| x.as_str()).map(|cl| cl[..1].to_string() + &cl[1..].to_lowercase()),
                emoji: None,
                label: format!("{} · {label}", short(k)),
                value: format!("{k}|{}", i + 1),
            });
        }
    }
    if options.is_empty() {
        // (the snapshot doesn't know the character yet: their last spec, as in game)
        return Answer::Text(queue(raid, &key, "A", None, user, name, now, &snap));
    }
    let menu = Component::SelectMenu(SelectMenu {
        id: None,
        channel_types: None,
        custom_id: format!("sp:{raid}"),
        default_values: None,
        disabled: false,
        kind: SelectMenuType::Text,
        max_values: Some(1),
        min_values: Some(1),
        options: Some(options),
        placeholder: Some("Character and spec".into()),
        required: None,
    });
    Answer::Picker(
        format!("Accept **{}**: pick your character and spec.", raid_name(&snap, raid)),
        vec![Component::ActionRow(ActionRow { id: None, components: vec![menu] })],
    )
}

/// The spec picker: custom id "sp:<raid>", value "<key>|<spec index>".
pub fn select(user: &str, name: &str, custom: &str, values: &[String], now: u64) -> String {
    let Some(raid) = custom.strip_prefix("sp:") else { return "Unknown menu.".into() };
    let Some((key, sp)) = values.first().and_then(|v| v.split_once('|')) else { return "Pick one.".into() };
    let Some(linked) = bridge::load_links().links.get(user).cloned() else { return NOT_LINKED.into() };
    let snap = snap();
    // (only the linked character or one of its alts)
    let ok = key == linked
        || snap
            .get("chars")
            .and_then(|c| c.get(&linked))
            .map(|c| lua_list(c.get("alts")).iter().any(|a| a.as_str() == Some(key)))
            .unwrap_or(false);
    if !ok {
        return "That character is not yours.".into();
    }
    queue(raid, key, "A", sp.parse().ok(), user, name, now, &snap)
}

#[allow(clippy::too_many_arguments)]
fn queue(raid: &str, key: &str, st: &str, sp: Option<u32>, user: &str, name: &str, now: u64, snap: &Value) -> String {
    let Some(dir) = crate::core::state::load().flavor_dir() else { return "The host has no game folder set.".into() };
    let r = bridge::Record {
        // (two clicks in one second are two records)
        id: format!("su_{now}_{user}_{}", NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)),
        kind: "signup".into(),
        at: now,
        by: name.to_string(),
        body: json!({ "raid": raid, "key": key, "st": st, "sp": sp }),
        discord: user.to_string(),
    };
    if let Err(e) = bridge::push(&dir, r, now) {
        return format!("Could not save it: {e}");
    }
    let spec = sp
        .and_then(|i| {
            let c = snap.get("chars")?.get(key)?;
            lua_list(c.get("specs")).get(i as usize - 1)?.as_str().map(|s| format!(" ({s})"))
        })
        .unwrap_or_default();
    let what = match st {
        "A" => "Signed up",
        "T" => "Marked tentative",
        _ => "Marked as can't come",
    };
    format!(
        "{what}: **{}**{spec} for {}. It reaches the game, and the post, at the host's next /reload.",
        short(key),
        raid_name(snap, raid)
    )
}
