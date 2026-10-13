//! Signing up from Discord (host mode). A Discord user makes their character once (name, class, spec: a form, then a
//! spec menu) and the raid posts' buttons sign that character up. No proof is asked; one name belongs to one Discord
//! user (bridge::owner_of). A sign-up becomes a "signup" record { raid, name, class, sp, st } in the bridge queue; the
//! host's addon applies it at its next /reload (a guild member as themselves, anyone else as a guest) and shares it
//! with the guild. A refusal comes back as a DM (bot.rs).
//!
//! Custom ids: su:<raid>:<st> post button · mk:<raid>:<st> character form · ms:<raid>:<st>:<name>:<CLASS> spec menu
//! · sp:<raid> accept menu ("<char>|<spec>" or "new") · pc:<raid>:<st> character menu · ch:rm / ch:add (/character).
//! <raid> "-" = no raid (making a character from /character).

use crate::core::bridge::{self, lua_list, Char};
use serde_json::{json, Value};
use std::sync::Mutex;
use twilight_model::application::interaction::modal::{ModalInteractionComponent, ModalInteractionData};
use twilight_model::channel::message::component::{
    ActionRow, Button, ButtonStyle, Component, Label, SelectMenu, SelectMenuOption, SelectMenuType, TextInput, TextInputStyle,
};

/// The newest snapshot the host's addon wrote (DisasterZoneBridgeDB.snap), kept by the bot's watch.
static SNAP: Mutex<Option<Value>> = Mutex::new(None);
static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub fn set_snap(v: Value) {
    *SNAP.lock().unwrap() = Some(v);
}

fn snap() -> Value {
    SNAP.lock().unwrap().clone().unwrap_or(Value::Null)
}

/// The classes and their specs, in the addon's order (ns.SPECS: the spec index is the same number).
pub const CLASSES: [(&str, &str, &[&str]); 9] = [
    ("WARRIOR", "Warrior", &["Arms", "Fury", "Protection"]),
    ("PALADIN", "Paladin", &["Holy", "Protection", "Retribution"]),
    ("HUNTER", "Hunter", &["Beast Mastery", "Marksmanship", "Survival"]),
    ("ROGUE", "Rogue", &["Assassination", "Combat", "Subtlety"]),
    ("PRIEST", "Priest", &["Discipline", "Holy", "Shadow"]),
    ("SHAMAN", "Shaman", &["Elemental", "Enhancement", "Restoration"]),
    ("MAGE", "Mage", &["Arcane", "Fire", "Frost"]),
    ("WARLOCK", "Warlock", &["Affliction", "Demonology", "Destruction"]),
    ("DRUID", "Druid", &["Balance", "Feral (Cat)", "Feral (Bear)", "Restoration"]),
];

fn class_info(class: &str) -> Option<(&'static str, &'static [&'static str])> {
    CLASSES.iter().find(|(c, _, _)| *c == class).map(|(_, n, s)| (*n, *s))
}

fn spec_name(class: &str, spec: u32) -> &'static str {
    class_info(class).and_then(|(_, s)| s.get(spec as usize - 1).copied()).unwrap_or("?")
}

pub enum Answer {
    /// a new private message
    Text(String, Vec<Component>),
    /// replace the private message the menu was on
    Update(String, Vec<Component>),
    /// open a form
    Modal { custom_id: String, title: String, components: Vec<Component> },
}

fn text(t: impl Into<String>) -> Answer {
    Answer::Text(t.into(), Vec::new())
}

fn raid_name(snap: &Value, raid: &str) -> String {
    lua_list(snap.get("raids"))
        .into_iter()
        .find(|r| r.get("id").and_then(|x| x.as_str()) == Some(raid))
        .and_then(|r| r.get("title").or(r.get("name")).and_then(|x| x.as_str()).map(str::to_string))
        .unwrap_or_else(|| "the raid".into())
}

/// The guild member with this name (snapshot roster): (key, class).
fn roster_find(snap: &Value, name: &str) -> Option<(String, String)> {
    let want = name.to_lowercase();
    let short = !want.contains('-');
    lua_list(snap.get("roster")).into_iter().find_map(|m| {
        let key = m.get("key")?.as_str()?;
        let k = key.to_lowercase();
        let hit = k == want || (short && k.split('-').next() == Some(want.as_str()));
        hit.then(|| (key.to_string(), m.get("class").and_then(|c| c.as_str()).unwrap_or("").to_string()))
    })
}

fn menu(custom_id: String, placeholder: &str, options: Vec<SelectMenuOption>) -> Component {
    Component::ActionRow(ActionRow {
        id: None,
        components: vec![Component::SelectMenu(SelectMenu {
            id: None,
            channel_types: None,
            custom_id,
            default_values: None,
            disabled: false,
            kind: SelectMenuType::Text,
            max_values: Some(1),
            min_values: Some(1),
            options: Some(options),
            placeholder: Some(placeholder.into()),
            required: None,
        })],
    })
}

fn option(label: String, value: String, description: Option<String>, default: bool) -> SelectMenuOption {
    SelectMenuOption { default, description, emoji: None, label, value }
}

/// The character form: name and class.
#[allow(deprecated)] // (TextInput::label: the Label around it carries the words)
fn form(raid: &str, st: &str) -> Answer {
    let classes = CLASSES.iter().map(|(c, n, _)| option(n.to_string(), c.to_string(), None, false)).collect();
    Answer::Modal {
        custom_id: format!("mk:{raid}:{st}"),
        title: "Your character".into(),
        components: vec![
            Component::Label(Label {
                id: None,
                label: "Character name".into(),
                description: Some("As in game. Add -Realm if it's not on our realm.".into()),
                component: Box::new(Component::TextInput(TextInput {
                    id: None,
                    custom_id: "name".into(),
                    label: None,
                    max_length: Some(40),
                    min_length: Some(2),
                    placeholder: None,
                    required: Some(true),
                    style: TextInputStyle::Short,
                    value: None,
                })),
            }),
            Component::Label(Label {
                id: None,
                label: "Class".into(),
                description: Some("Guild members: the guild roster's class counts.".into()),
                component: Box::new(match menu("class".into(), "Class", classes) {
                    Component::ActionRow(mut r) => r.components.remove(0),
                    c => c,
                }),
            }),
        ],
    }
}

/// The spec menu for a character being made.
fn spec_menu(raid: &str, st: &str, name: &str, class: &str, lead: String) -> Answer {
    let Some((cname, specs)) = class_info(class) else { return text("Unknown class.") };
    let options = specs.iter().enumerate().map(|(i, s)| option(s.to_string(), (i + 1).to_string(), None, false)).collect();
    Answer::Text(
        format!("{lead}**{name}**, {cname}. Which spec?"),
        vec![menu(format!("ms:{raid}:{st}:{name}:{class}"), "Spec", options)],
    )
}

/// The accept menu: every character × spec of the user, and "make another character".
fn accept_menu(raid: &str, chars: &[Char], snap: &Value) -> Answer {
    let mut options = Vec::new();
    for (ci, c) in chars.iter().enumerate() {
        let Some((cname, specs)) = class_info(&c.class) else { continue };
        for (si, s) in specs.iter().enumerate() {
            if options.len() < 24 {
                options.push(option(format!("{} · {s}", c.name), format!("{ci}|{}", si + 1), Some(cname.into()), ci == 0 && si as u32 + 1 == c.spec));
            }
        }
    }
    options.push(option("Another character…".into(), "new".into(), Some("Make a new one".into()), false));
    Answer::Text(format!("Accept **{}**: which character and spec?", raid_name(snap, raid)), vec![menu(format!("sp:{raid}"), "Character and spec", options)])
}

/// A raid post's button: custom id "su:<raid>:<A|T|X>".
pub fn button(user: &str, name: &str, custom: &str, now: u64) -> Answer {
    let parts: Vec<&str> = custom.splitn(3, ':').collect();
    if custom == "ch:add" {
        return form("-", "-");
    }
    let ["su", raid, st] = parts[..] else { return text("Unknown button.") };
    let profiles = bridge::load_profiles();
    let chars = profiles.get(user).cloned().unwrap_or_default();
    if chars.is_empty() {
        return form(raid, st);
    }
    let snap = snap();
    if st == "A" {
        return accept_menu(raid, &chars, &snap);
    }
    if chars.len() == 1 {
        return text(queue(raid, &chars[0], None, st, user, name, now, &snap));
    }
    let options = chars.iter().enumerate().map(|(i, c)| option(c.name.clone(), i.to_string(), None, i == 0)).collect();
    Answer::Text("Which character?".into(), vec![menu(format!("pc:{raid}:{st}"), "Character", options)])
}

/// A menu choice.
pub fn select(user: &str, name: &str, custom: &str, values: &[String], now: u64) -> Answer {
    let v = values.first().map(String::as_str).unwrap_or("");
    let parts: Vec<&str> = custom.split(':').collect();
    let snap = snap();
    let mut profiles = bridge::load_profiles();
    let chars = profiles.get(user).cloned().unwrap_or_default();
    match parts[..] {
        // the spec of a character being made: save it, then sign up
        ["ms", raid, st, cname, class] => {
            let Ok(spec) = v.parse::<u32>() else { return text("Pick a spec.") };
            if let Some(owner) = bridge::owner_of(&profiles, cname).filter(|o| o != user) {
                let _ = owner;
                return Answer::Update(format!("**{cname}** is already someone else's. Ask an officer if that's you."), Vec::new());
            }
            let c = Char { name: cname.to_string(), class: class.to_string(), spec, by: name.to_string() };
            let list = profiles.entry(user.to_string()).or_default();
            list.retain(|x| !x.name.eq_ignore_ascii_case(cname));
            list.push(c.clone());
            if let Err(e) = bridge::save_profiles(&profiles) {
                return Answer::Update(format!("Could not save it: {e}"), Vec::new());
            }
            let made = format!("Saved **{cname}** ({}). ", spec_name(class, spec));
            // (the addon's Discord badges: the host's inbox carries the new name at once)
            if let Some(dir) = crate::core::state::load().flavor_dir() {
                let _ = bridge::sync(&dir, now);
            }
            if raid == "-" {
                return Answer::Update(format!("{made}The raid posts' buttons use it now."), Vec::new());
            }
            Answer::Update(made + &queue(raid, &c, Some(spec), st, user, name, now, &snap), Vec::new())
        }
        // accept with one of my characters and a spec
        ["sp", raid] => {
            if v == "new" {
                return form(raid, "A");
            }
            let Some((ci, sp)) = v.split_once('|') else { return text("Pick one.") };
            let (Ok(ci), Ok(sp)) = (ci.parse::<usize>(), sp.parse::<u32>()) else { return text("Pick one.") };
            let Some(c) = chars.get(ci) else { return text("That character is gone.") };
            Answer::Update(queue(raid, c, Some(sp), "A", user, name, now, &snap), Vec::new())
        }
        // tentative / can't come with one of my characters
        ["pc", raid, st] => {
            let Some(c) = v.parse::<usize>().ok().and_then(|i| chars.get(i)) else { return text("Pick one.") };
            Answer::Update(queue(raid, c, None, st, user, name, now, &snap), Vec::new())
        }
        // /character: remove one
        ["ch", "rm"] => {
            let Some(i) = v.parse::<usize>().ok().filter(|i| *i < chars.len()) else { return text("Pick one.") };
            let gone = chars[i].name.clone();
            if let Some(list) = profiles.get_mut(user) {
                list.remove(i);
            }
            let _ = bridge::save_profiles(&profiles);
            if let Some(dir) = crate::core::state::load().flavor_dir() {
                let _ = bridge::sync(&dir, now);
            }
            Answer::Update(format!("Removed **{gone}**."), Vec::new())
        }
        _ => text("Unknown menu."),
    }
}

/// The character form was sent: "mk:<raid>:<st>".
pub fn form_sent(user: &str, data: &ModalInteractionData) -> Answer {
    let parts: Vec<&str> = data.custom_id.split(':').collect();
    let ["mk", raid, st] = parts[..] else { return text("Unknown form.") };
    let mut typed = String::new();
    let mut class = String::new();
    fn walk(c: &ModalInteractionComponent, typed: &mut String, class: &mut String) {
        match c {
            ModalInteractionComponent::Label(l) => walk(&l.component, typed, class),
            ModalInteractionComponent::ActionRow(r) => r.components.iter().for_each(|x| walk(x, typed, class)),
            ModalInteractionComponent::TextInput(t) if t.custom_id == "name" => *typed = t.value.clone(),
            ModalInteractionComponent::StringSelect(s) if s.custom_id == "class" => *class = s.values.first().cloned().unwrap_or_default(),
            _ => {}
        }
    }
    data.components.iter().for_each(|c| walk(c, &mut typed, &mut class));
    let name = bridge::tidy_name(&typed);
    if name.chars().count() < 2 || name.chars().any(|c| !(c.is_alphabetic() || c == '-' || c == '\'')) {
        return text("That doesn't look like a character name.");
    }
    if bridge::owner_of(&bridge::load_profiles(), &name).is_some_and(|o| o != user) {
        return text(format!("**{name}** is already someone else's. Ask an officer if that's you."));
    }
    let snap = snap();
    let mut lead = String::new();
    let (name, class) = match roster_find(&snap, &name) {
        Some((key, rc)) if !rc.is_empty() => {
            if !class.is_empty() && class != rc {
                lead = format!("The guild roster says {} is a {}. ", key.split('-').next().unwrap_or(&key), class_info(&rc).map_or("?", |c| c.0));
            }
            (key.split('-').next().unwrap_or(&key).to_string(), rc)
        }
        _ => {
            if class.is_empty() {
                return text("Pick your class too.");
            }
            if !name.contains('-') {
                lead = "Not in the guild roster: you join raids as a guest. ".into();
            }
            (name, class)
        }
    };
    spec_menu(raid, st, &name, &class, lead)
}

/// /character: my characters, with remove and add.
pub fn characters(user: &str) -> Answer {
    let chars = bridge::load_profiles().get(user).cloned().unwrap_or_default();
    let add = Component::ActionRow(ActionRow {
        id: None,
        components: vec![Component::Button(Button {
            id: None,
            custom_id: Some("ch:add".into()),
            disabled: false,
            emoji: None,
            label: Some("Add a character".into()),
            style: ButtonStyle::Primary,
            url: None,
            sku_id: None,
        })],
    });
    if chars.is_empty() {
        return Answer::Text("You have no characters yet. Add one, or just press a raid post's Accept.".into(), vec![add]);
    }
    let list: Vec<String> = chars.iter().map(|c| format!("• **{}**, {} {}", c.name, spec_name(&c.class, c.spec), class_info(&c.class).map_or("", |x| x.0))).collect();
    let options = chars.iter().enumerate().map(|(i, c)| option(c.name.clone(), i.to_string(), None, false)).collect();
    Answer::Text(format!("Your characters:\n{}", list.join("\n")), vec![menu("ch:rm".into(), "Remove a character", options), add])
}

#[allow(clippy::too_many_arguments)]
fn queue(raid: &str, c: &Char, sp: Option<u32>, st: &str, user: &str, name: &str, now: u64, snap: &Value) -> String {
    let Some(dir) = crate::core::state::load().flavor_dir() else { return "The host has no game folder set.".into() };
    let sp = sp.unwrap_or(c.spec);
    let r = bridge::Record {
        // (two clicks in one second are two records)
        id: format!("su_{now}_{user}_{}", NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)),
        kind: "signup".into(),
        at: now,
        by: name.to_string(),
        body: json!({ "raid": raid, "name": c.name, "class": c.class, "sp": sp, "st": st }),
        discord: user.to_string(),
    };
    if let Err(e) = bridge::push(&dir, r, now) {
        return format!("Could not save it: {e}");
    }
    let what = match st {
        "A" => "Signed up",
        "T" => "Marked tentative",
        _ => "Marked as can't come",
    };
    let spec = if st == "A" { format!(" ({})", spec_name(&c.class, sp)) } else { String::new() };
    format!("{what}: **{}**{spec} for {}. It reaches the game, and the post, at the host's next /reload.", c.name, raid_name(snap, raid))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roster_finds_members_by_short_name() {
        let snap = json!({ "roster": { "1": { "key": "Lee-Thunderstrike", "class": "WARRIOR" } } });
        assert_eq!(roster_find(&snap, "lee"), Some(("Lee-Thunderstrike".into(), "WARRIOR".into())));
        assert_eq!(roster_find(&snap, "Lee-Thunderstrike").map(|x| x.1), Some("WARRIOR".into()));
        assert_eq!(roster_find(&snap, "Leeroy"), None);
    }

    #[test]
    fn specs_match_the_addon() {
        assert_eq!(spec_name("DRUID", 3), "Feral (Bear)");
        assert_eq!(spec_name("PALADIN", 2), "Protection");
        assert_eq!(spec_name("NOPE", 1), "?");
    }
}

// ------------------------------------------------------------------------------------------------------------------
// /raids: the coming raids, their sign-ups and my answer (from the host's last snapshot)
// ------------------------------------------------------------------------------------------------------------------

/// The text of /raids for a Discord user; `guild` = the server id (for links to the raid posts).
pub fn raids_text(user: &str, guild: &str, now: u64) -> String {
    raids_text_from(&snap(), &bridge::load_profiles(), &crate::posts::load_posts(), user, guild, now)
}

pub fn raids_text_from(
    snap: &Value,
    profiles: &bridge::Profiles,
    posts: &std::collections::BTreeMap<String, crate::posts::Post>,
    user: &str,
    guild: &str,
    now: u64,
) -> String {
    let mine: Vec<String> =
        profiles.get(user).map(|cs| cs.iter().map(|c| c.name.to_lowercase()).collect()).unwrap_or_default();
    let teams = snap.get("teams").cloned().unwrap_or(Value::Null);
    let mut lines = Vec::new();
    for r in lua_list(snap.get("raids")) {
        let t = r.get("t").and_then(|x| x.as_i64()).unwrap_or(0);
        if t + 3 * 3600 < now as i64 || r.get("cancelled").and_then(|x| x.as_bool()) == Some(true) {
            continue;
        }
        let id = r.get("id").and_then(|x| x.as_str()).unwrap_or("");
        let name = r.get("title").or(r.get("name")).and_then(|x| x.as_str()).unwrap_or("Raid");
        let signups = lua_list(r.get("signups"));
        let count = |role: &str| {
            signups.iter().filter(|s| s.get("st").and_then(|x| x.as_str()) == Some("accept") && s.get("role").and_then(|x| x.as_str()) == Some(role)).count()
        };
        let accepted = signups.iter().filter(|s| s.get("st").and_then(|x| x.as_str()) == Some("accept")).count();
        let team: Vec<&str> =
            lua_list(r.get("teams")).iter().filter_map(|x| x.as_str().and_then(|id| teams.get(id)).and_then(|n| n.as_str())).collect();
        let me = signups.iter().find_map(|s| {
            let key = s.get("key")?.as_str()?;
            let short = key.split('-').next().unwrap_or(key).to_lowercase();
            mine.contains(&short).then(|| {
                let st = match s.get("st").and_then(|x| x.as_str()) {
                    Some("accept") => "accepted",
                    Some("tentative") => "tentative",
                    Some("bench") => "on the bench",
                    _ => "can't come",
                };
                format!("**{}** {st}", key.split('-').next().unwrap_or(key))
            })
        });
        // (the name opens the raid's post, where the buttons are)
        let title = match posts.get(id) {
            Some(p) => format!("[**{name}**](https://discord.com/channels/{guild}/{}/{})", p.channel, p.message),
            None => format!("**{name}**"),
        };
        let n = |k: usize, one: &str, many: &str| format!("{k} {}", if k == 1 { one } else { many });
        lines.push(format!(
            "{title} · <t:{t}:f>{}\n{accepted} in ({}, {}, {} dps) · {}",
            if team.is_empty() { String::new() } else { format!(" · {}", team.join(", ")) },
            n(count("tank"), "tank", "tanks"),
            n(count("healer"), "healer", "healers"),
            count("melee") + count("ranged"),
            me.unwrap_or_else(|| "you haven't answered".into()),
        ));
        if lines.len() >= 10 {
            break;
        }
    }
    if lines.is_empty() {
        return "No raids planned in the next two weeks.".into();
    }
    let age = snap.get("at").and_then(|x| x.as_u64()).map(|a| crate::bot::fmt_age(now.saturating_sub(a))).unwrap_or_default();
    format!("{}\n-# As of the host's last reload, {age}.", lines.join("\n\n"))
}

#[cfg(test)]
mod raids_tests {
    use super::*;

    #[test]
    fn raids_show_counts_and_my_answer() {
        let snap = json!({ "at": 1000, "teams": { "t1": "Main" }, "raids": {
            "1": { "id": "r1", "t": 5000, "name": "Karazhan", "teams": { "1": "t1" }, "signups": {
                "1": { "key": "Lee-X", "st": "accept", "role": "tank" },
                "2": { "key": "Rita-X", "st": "accept", "role": "healer" } } },
            "2": { "id": "r2", "t": 6000, "name": "Gruul", "cancelled": true } } });
        let mut p = bridge::Profiles::new();
        p.insert("9".into(), vec![Char { name: "Lee".into(), class: "WARRIOR".into(), spec: 3, by: String::new() }]);
        let mut posts = std::collections::BTreeMap::new();
        posts.insert("r1".to_string(), crate::posts::Post { channel: "c".into(), message: "m".into(), hash: String::new() });
        let t = raids_text_from(&snap, &p, &posts, "9", "g", 1060);
        assert!(t.contains("[**Karazhan**](https://discord.com/channels/g/c/m) · <t:5000:f> · Main"), "{t}");
        assert!(t.contains("2 in (1 tank, 1 healer, 0 dps)") && t.contains("**Lee** accepted"), "{t}");
        assert!(!t.contains("Gruul"), "{t}");
        assert!(t.contains("1 min ago"), "{t}");
        assert!(raids_text_from(&snap, &p, &posts, "other", "g", 1060).contains("you haven't answered"));
    }
}

// ------------------------------------------------------------------------------------------------------------------
// /bis [character]: a BiS list, this phase (the lists the host's addon holds)
// ------------------------------------------------------------------------------------------------------------------

pub fn bis_text(user: &str, who: Option<&str>, now: u64) -> String {
    bis_text_from(&snap(), &bridge::load_profiles(), user, who, now)
}

pub fn bis_text_from(snap: &Value, profiles: &bridge::Profiles, user: &str, who: Option<&str>, now: u64) -> String {
    let name = match who.map(str::trim).filter(|w| !w.is_empty()) {
        Some(w) => w.to_string(),
        None => match profiles.get(user).and_then(|cs| cs.first()) {
            Some(c) => c.name.clone(),
            None => return "Whose list? `/bis character:Name`, or make your character with /character.".into(),
        },
    };
    let want = name.to_lowercase();
    let bis = snap.get("bis").and_then(|b| b.as_object());
    let found = bis.and_then(|b| {
        b.iter().find(|(k, _)| {
            let k = k.to_lowercase();
            k == want || k.split('-').next() == Some(want.as_str())
        })
    });
    let Some((key, list)) = found else {
        return format!("No BiS list for **{}** yet. Lists come from the addon: make one in My BiS.", bridge::tidy_name(&name));
    };
    let phase = snap.get("phase").and_then(|p| p.as_i64()).unwrap_or(1);
    let spec = list.get("spec").and_then(|s| s.as_str()).map(|s| format!(" · {s}")).unwrap_or_default();
    let mut lines = vec![format!("**{}**{spec} · Phase {phase}", key.split('-').next().unwrap_or(key))];
    let slots = lua_list(list.get("slots"));
    if slots.is_empty() {
        lines.push("Nothing picked for this phase yet.".into());
    }
    for s in slots {
        let id = s.get("id").and_then(|x| x.as_i64()).unwrap_or(0);
        let item = s.get("name").and_then(|x| x.as_str()).map(str::to_string).unwrap_or_else(|| format!("Item {id}"));
        let got = if s.get("got").and_then(|x| x.as_bool()) == Some(true) { " ✓" } else { "" };
        lines.push(format!(
            "{}: [{item}](https://www.wowhead.com/tbc/item={id}){got}",
            s.get("slot").and_then(|x| x.as_str()).unwrap_or("?")
        ));
    }
    let age = snap.get("at").and_then(|x| x.as_u64()).map(|a| crate::bot::fmt_age(now.saturating_sub(a))).unwrap_or_default();
    lines.push(format!("-# ✓ = has it. As of the host's last reload, {age}."));
    lines.join("\n")
}

#[cfg(test)]
mod bis_tests {
    use super::*;

    #[test]
    fn bis_shows_my_main_list() {
        let snap = json!({ "at": 100, "phase": 2, "bis": { "Lee-X": { "spec": "Protection", "slots": {
            "1": { "sid": 1, "slot": "Head", "id": 29011, "name": "Warbringer Greathelm", "got": true },
            "2": { "sid": 2, "slot": "Neck", "id": 28244 } } } } });
        let mut p = bridge::Profiles::new();
        p.insert("9".into(), vec![Char { name: "Lee".into(), class: "WARRIOR".into(), spec: 3, by: String::new() }]);
        let t = bis_text_from(&snap, &p, "9", None, 160);
        assert!(t.starts_with("**Lee** · Protection · Phase 2"), "{t}");
        assert!(t.contains("Head: [Warbringer Greathelm](https://www.wowhead.com/tbc/item=29011) ✓"), "{t}");
        assert!(t.contains("Neck: [Item 28244]"), "{t}");
        assert!(bis_text_from(&snap, &p, "9", Some("rita"), 160).contains("No BiS list for **Rita**"));
        assert!(bis_text_from(&snap, &p, "other", None, 160).contains("Whose list?"));
    }
}
