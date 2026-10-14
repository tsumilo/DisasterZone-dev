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

/// The last snapshot, when the bot has read one.
pub fn current_snap() -> Option<Value> {
    SNAP.lock().unwrap().clone()
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

/// The role a class's spec plays on a raid card: "tank" | "heal" | "dps" (addon ns.SPECS roles).
pub fn role_of(class: &str, spec: u32) -> &'static str {
    match (class, spec) {
        ("WARRIOR", 3) | ("PALADIN", 2) | ("DRUID", 3) => "tank",
        ("PALADIN", 1) | ("PRIEST", 1) | ("PRIEST", 2) | ("SHAMAN", 3) | ("DRUID", 4) => "heal",
        _ => "dps",
    }
}

/// A spec's index by its label ("Protection" -> 3 for a warrior), 0 when unknown.
pub fn spec_index(class: &str, label: &str) -> u32 {
    class_info(class).and_then(|(_, s)| s.iter().position(|x| *x == label)).map_or(0, |i| i as u32 + 1)
}

fn class_info(class: &str) -> Option<(&'static str, &'static [&'static str])> {
    CLASSES.iter().find(|(c, _, _)| *c == class).map(|(_, n, s)| (*n, *s))
}

fn spec_name(class: &str, spec: u32) -> &'static str {
    class_info(class).and_then(|(_, s)| s.get(spec as usize - 1).copied()).unwrap_or("?")
}

pub enum Answer {
    /// a private message with a picture (the gear sheet from the week board)
    Sheet(twilight_model::channel::message::Embed, Vec<Component>, String, Vec<u8>),
    /// replace the private message the menu was on with an embed
    UpdateCard(twilight_model::channel::message::Embed, Vec<Component>),
    /// a new private message with an embed (the character card)
    Card(twilight_model::channel::message::Embed, Vec<Component>),
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

/// Every spec name once (25: exactly what one Discord menu holds), for the form's spec menu.
fn all_specs() -> Vec<&'static str> {
    let mut out: Vec<&str> = Vec::new();
    for (_, _, specs) in CLASSES {
        for s in specs.iter() {
            if !out.contains(s) {
                out.push(s);
            }
        }
    }
    out
}

/// The character form: name, class and spec.
#[allow(deprecated)] // (TextInput::label: the Label around it carries the words)
fn form(raid: &str, st: &str) -> Answer {
    let classes = CLASSES.iter().map(|(c, n, _)| option(n.to_string(), c.to_string(), None, false)).collect();
    let specs = all_specs().into_iter().map(|s| option(s.to_string(), s.to_string(), None, false)).collect();
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
            Component::Label(Label {
                id: None,
                label: "Spec".into(),
                description: Some("The one you raid as. Change it any time with Change spec.".into()),
                component: Box::new(match menu("spec".into(), "Spec", specs) {
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
                options.push(option(format!("{} · {s}", c.name), format!("{ci}|{}", si + 1), Some(if si as u32 + 1 == c.spec { format!("{cname} · current") } else { cname.to_string() }), false));
            }
        }
    }
    options.push(option("Another character…".into(), "new".into(), Some("Make a new one".into()), false));
    Answer::Text(format!("**{}**: which character and spec?", raid_name(snap, raid)), vec![menu(format!("sp:{raid}"), "Character and spec", options)])
}

/// A raid post's button: custom id "su:<raid>:<A|T|X>".
pub fn button(user: &str, name: &str, custom: &str, now: u64) -> Answer {
    let parts: Vec<&str> = custom.splitn(3, ':').collect();
    if custom == "ch:add" {
        return form("-", "-");
    }
    if custom == "wk:raids" {
        return my_raids(user, None);
    }
    if custom == "wk:chars" {
        return characters(user);
    }
    if custom == "rt:toggle" {
        crate::remind::toggle(user);
        return match characters(user) {
            Answer::Text(t, c) => Answer::Update(t, c),
            other => other,
        };
    }
    if custom == "wk:bis" {
        // (the board's button: the sheet privately; /bis show posts it in the channel)
        return match crate::bis::show(user, None) {
            crate::bis::Reply::Pic { embed: Some(e), comps, file: Some((f, b)), .. } => Answer::Sheet(e, comps, f, b),
            _ => text(bis_text(user, None, now)),
        };
    }
    if let ["mr", raid, st] = parts[..] {
        // an answer from My raids: my main character, then the list again
        let chars = bridge::load_profiles().get(user).cloned().unwrap_or_default();
        let Some(c) = chars.first() else { return form(raid, st) };
        let snap = snap();
        let done = queue(raid, c, None, st, user, name, now, &snap);
        return match my_raids(user, None) {
            Answer::Card(e, comps) => {
                let mut e = e;
                e.description = Some(format!("{}\n\n{done}", e.description.unwrap_or_default()));
                Answer::UpdateCard(e, comps)
            }
            other => other,
        };
    }
    let ["su", raid, st] = parts[..] else { return text("Unknown button.") };
    let profiles = bridge::load_profiles();
    let chars = profiles.get(user).cloned().unwrap_or_default();
    if chars.is_empty() {
        return form(raid, if st == "S" { "A" } else { st });
    }
    let snap = snap();
    // Change spec: the character × spec menu. Accept / Tentative / Can't come: at once with my only character (its
    // spec), else a character menu. (Menus never pre-select: picking the option already shown is no choice in
    // Discord, so nothing would happen.)
    if st == "S" {
        return accept_menu(raid, &chars, &snap);
    }
    if chars.len() == 1 {
        return text(queue(raid, &chars[0], None, st, user, name, now, &snap));
    }
    let options = chars
        .iter()
        .enumerate()
        .map(|(i, c)| option(c.name.clone(), i.to_string(), Some(format!("{} {}", spec_name(&c.class, c.spec), class_info(&c.class).map_or("", |x| x.0))), false))
        .collect();
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
            made(user, name, raid, st, cname, class, spec, "", now, &snap)
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
        // My raids: a raid picked, its answers under it
        ["mr", "pick"] => match my_raids(user, Some(v)) {
            Answer::Card(e, c) => Answer::UpdateCard(e, c),
            other => other,
        },
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

/// Save a character made in Discord, then sign it up (raid "-" = only saved): the private character card.
#[allow(clippy::too_many_arguments)]
fn made(user: &str, name: &str, raid: &str, st: &str, cname: &str, class: &str, spec: u32, lead: &str, now: u64, snap: &Value) -> Answer {
    let mut profiles = bridge::load_profiles();
    if bridge::owner_of(&profiles, cname).is_some_and(|o| o != user) {
        return text(format!("**{cname}** is already someone else's. Ask an officer if that's you."));
    }
    let c = Char { name: cname.to_string(), class: class.to_string(), spec, by: name.to_string() };
    let list = profiles.entry(user.to_string()).or_default();
    list.retain(|x| !x.name.eq_ignore_ascii_case(cname));
    list.push(c.clone());
    if let Err(e) = bridge::save_profiles(&profiles) {
        return text(format!("Could not save it: {e}"));
    }
    // (the addon's Discord badges: the host's inbox carries the new name at once)
    if let Some(dir) = crate::core::state::load().flavor_dir() {
        let _ = bridge::sync(&dir, now);
    }
    let mut d = format!(
        "{lead}{}**{cname}** · {} {}\nSaved. This is how the guild sees you. Next time, the buttons sign you up straight away.",
        crate::emoji::class_tag(class),
        spec_name(class, spec),
        class_info(class).map_or("", |x| x.0)
    );
    if raid != "-" {
        d.push_str("\n\n");
        d.push_str(&queue(raid, &c, Some(spec), st, user, name, now, snap));
    }
    let embed = twilight_util::builder::embed::EmbedBuilder::new().description(d).color(0x23a55a).build();
    let add = Component::ActionRow(ActionRow {
        id: None,
        components: vec![Component::Button(Button {
            id: None,
            custom_id: Some("ch:add".into()),
            disabled: false,
            emoji: None,
            label: Some("Add an alt".into()),
            style: ButtonStyle::Secondary,
            url: None,
            sku_id: None,
        })],
    });
    Answer::Card(embed, vec![add])
}

/// The character form was sent: "mk:<raid>:<st>".
pub fn form_sent(user: &str, data: &ModalInteractionData) -> Answer {
    let parts: Vec<&str> = data.custom_id.split(':').collect();
    let ["mk", raid, st] = parts[..] else { return text("Unknown form.") };
    let (mut typed, mut class, mut spec) = (String::new(), String::new(), String::new());
    fn walk(c: &ModalInteractionComponent, out: &mut (&mut String, &mut String, &mut String)) {
        match c {
            ModalInteractionComponent::Label(l) => walk(&l.component, out),
            ModalInteractionComponent::ActionRow(r) => r.components.iter().for_each(|x| walk(x, out)),
            ModalInteractionComponent::TextInput(t) if t.custom_id == "name" => *out.0 = t.value.clone(),
            ModalInteractionComponent::StringSelect(s) if s.custom_id == "class" => *out.1 = s.values.first().cloned().unwrap_or_default(),
            ModalInteractionComponent::StringSelect(s) if s.custom_id == "spec" => *out.2 = s.values.first().cloned().unwrap_or_default(),
            _ => {}
        }
    }
    let mut out = (&mut typed, &mut class, &mut spec);
    data.components.iter().for_each(|c| walk(c, &mut out));
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
    // the spec picked in the form, when that class has it; else the class's own spec menu
    match spec_index(&class, &spec) {
        0 => spec_menu(raid, st, &name, &class, lead),
        i => made(user, &user_name_of(user), raid, st, &name, &class, i, &lead, crate::bot::unix_now(), &snap),
    }
}

/// The Discord name kept with a user's characters (their first), else "Discord".
fn user_name_of(user: &str) -> String {
    bridge::load_profiles().get(user).and_then(|c| c.first()).map(|c| c.by.clone()).filter(|b| !b.is_empty()).unwrap_or_else(|| "Discord".into())
}

/// /character: my characters, with remove and add.
pub fn characters(user: &str) -> Answer {
    let chars = bridge::load_profiles().get(user).cloned().unwrap_or_default();
    let on = crate::remind::is_on(user);
    let add = Component::ActionRow(ActionRow {
        id: None,
        components: vec![
            Component::Button(Button {
                id: None,
                custom_id: Some("ch:add".into()),
                disabled: false,
                emoji: None,
                label: Some("Add a character".into()),
                style: ButtonStyle::Primary,
                url: None,
                sku_id: None,
            }),
            Component::Button(Button {
                id: None,
                custom_id: Some("rt:toggle".into()),
                disabled: false,
                emoji: crate::emoji::button("dz_hourglass"),
                label: Some(if on { "Reminders: DM 1 h before" } else { "Reminders: off" }.into()),
                style: ButtonStyle::Secondary,
                url: None,
                sku_id: None,
            }),
        ],
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
    let t = lua_list(snap.get("raids"))
        .into_iter()
        .find(|r| r.get("id").and_then(|x| x.as_str()) == Some(raid))
        .and_then(|r| r.get("t").and_then(|x| x.as_i64()));
    let when = t.map(|t| format!(", <t:{t}:f>")).unwrap_or_default();
    let who = format!("{}**{}**", crate::emoji::class_tag(&c.class), c.name);
    match st {
        "A" => format!(
            "{}{who} is in for **{}**{when}, as {}. It shows as *pending* on the post until the raid leader's next sync.",
            crate::emoji::tag("dz_ready"),
            raid_name(snap, raid),
            spec_name(&c.class, sp)
        ),
        "T" => format!("{}{who} is tentative for **{}**{when}.", crate::emoji::tag("dz_waiting"), raid_name(snap, raid)),
        _ => format!("{}{who} can't come to **{}**{when}.", crate::emoji::tag("dz_notready"), raid_name(snap, raid)),
    }
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
// My raids (/raids and the week board's button): this week's raids, my answer to each, answer from here
// ------------------------------------------------------------------------------------------------------------------

/// My answer to a raid: the newest of the queue (pending) and the snapshot, for any of my characters.
fn my_answer(raid: &Value, mine: &[String], queue: &[bridge::Record]) -> Option<(String, bool)> {
    let id = raid.get("id").and_then(|x| x.as_str()).unwrap_or("");
    let is_mine = |n: &str| mine.contains(&n.split('-').next().unwrap_or(n).to_lowercase());
    if let Some(r) = queue.iter().rev().find(|r| {
        r.kind == "signup" && r.body.get("raid").and_then(|x| x.as_str()) == Some(id) && r.body.get("name").and_then(|x| x.as_str()).is_some_and(is_mine)
    }) {
        return r.body.get("st").and_then(|x| x.as_str()).map(|s| (s.to_string(), true));
    }
    lua_list(raid.get("signups")).into_iter().find_map(|s| {
        let key = s.get("key")?.as_str()?;
        is_mine(key).then(|| {
            let st = match s.get("st").and_then(|x| x.as_str()) {
                Some("accept") => "A",
                Some("tentative") | Some("bench") => "T",
                _ => "X",
            };
            (st.to_string(), false)
        })
    })
}

/// The private "Your raids this week" card; `picked` = the raid whose answer buttons show.
pub fn my_raids(user: &str, picked: Option<&str>) -> Answer {
    let snap = snap();
    let queue = bridge::load_queue();
    let posts = crate::posts::load_posts();
    let guild = GUILD.lock().unwrap().clone();
    let mine: Vec<String> =
        bridge::load_profiles().get(user).map(|cs| cs.iter().map(|c| c.name.to_lowercase()).collect()).unwrap_or_default();
    let now = crate::bot::unix_now() as i64;
    let mut lines = Vec::new();
    let mut options = Vec::new();
    for raid in lua_list(snap.get("raids")) {
        let t = raid.get("t").and_then(|x| x.as_i64()).unwrap_or(0);
        if t + 4 * 3600 < now || t > now + 7 * 86400 || raid.get("cancelled").and_then(|x| x.as_bool()) == Some(true) {
            continue;
        }
        let id = raid.get("id").and_then(|x| x.as_str()).unwrap_or("");
        let name = raid.get("title").or(raid.get("name")).and_then(|x| x.as_str()).unwrap_or("Raid");
        let (acc, _, _) = crate::posts::people(raid, &queue);
        let size = raid.get("size").and_then(|x| x.as_u64()).unwrap_or(25);
        let need = crate::posts::needs(raid, &acc);
        let ans = my_answer(raid, &mine, &queue);
        let chip = match ans.as_ref().map(|a| a.0.as_str()) {
            Some("A") => format!("{}In", crate::emoji::tag("dz_ready")),
            Some("T") => format!("{}Tentative", crate::emoji::tag("dz_waiting")),
            Some(_) => format!("{}Can't come", crate::emoji::tag("dz_notready")),
            None => "**Not answered**".to_string(),
        };
        let pend = if ans.as_ref().is_some_and(|a| a.1) { " *(pending)*" } else { "" };
        let title = match posts.get(id) {
            Some(p) if !guild.is_empty() => format!("[{name}](https://discord.com/channels/{guild}/{}/{})", p.channel, p.message),
            _ => name.to_string(),
        };
        lines.push(format!(
            "{chip}{pend} · {title} · <t:{t}:f> · {}/{size}{}",
            acc.len(),
            if need.is_empty() { String::new() } else { format!(" · **{need}**") }
        ));
        if options.len() < 25 {
            use chrono::{Local, TimeZone};
            let day = Local.timestamp_opt(t, 0).single().map(|d| d.format("%a %H:%M").to_string()).unwrap_or_default();
            options.push(option(
                format!("{name} · {day}"),
                id.to_string(),
                Some(if ans.is_some() { "answered" } else { "not answered" }.into()),
                false, // (never pre-selected: picking it again must still count)
            ));
        }
    }
    let age = snap.get("at").and_then(|x| x.as_u64()).map(|a| crate::bot::fmt_age((now as u64).saturating_sub(a))).unwrap_or_default();
    let embed = twilight_util::builder::embed::EmbedBuilder::new()
        .title("Your raids this week")
        .description(if lines.is_empty() { "No raids in the next seven days.".to_string() } else { lines.join("\n") })
        .footer(twilight_util::builder::embed::EmbedFooterBuilder::new(format!("As of the raid leader's last sync, {age}")))
        .color(0xFF8000)
        .build();
    let mut comps = Vec::new();
    if !options.is_empty() {
        comps.push(menu("mr:pick".into(), "Answer a raid…", options));
    }
    if let Some(raid) = picked {
        let b = |st: &str, label: &str, style, emoji: &str| {
            Component::Button(Button {
                id: None,
                custom_id: Some(format!("mr:{raid}:{st}")),
                disabled: false,
                emoji: crate::emoji::button(emoji),
                label: Some(label.into()),
                style,
                url: None,
                sku_id: None,
            })
        };
        comps.push(Component::ActionRow(ActionRow {
            id: None,
            components: vec![
                b("A", "Accept", ButtonStyle::Success, "dz_ready"),
                b("T", "Tentative", ButtonStyle::Secondary, "dz_waiting"),
                b("X", "Can't come", ButtonStyle::Danger, "dz_notready"),
            ],
        }));
    }
    Answer::Card(embed, comps)
}

/// The server's id (for links to posts), set when the bot connects.
pub static GUILD: Mutex<String> = Mutex::new(String::new());

// ------------------------------------------------------------------------------------------------------------------
// /raids as text (kept for the tests; the command answers with My raids)
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
    // one line a slot: the main pick, then the alternative (as the addon's My BiS shows them)
    let pick = |s: &Value, id_k: &str, name_k: &str, got_k: &str| -> Option<String> {
        let id = s.get(id_k).and_then(|x| x.as_i64()).filter(|i| *i > 0)?;
        let item = s.get(name_k).and_then(|x| x.as_str()).map(str::to_string).unwrap_or_else(|| format!("Item {id}"));
        let got = if s.get(got_k).and_then(|x| x.as_bool()) == Some(true) { " ✓" } else { "" };
        Some(format!("[{item}](<https://www.wowhead.com/tbc/item={id}>){got}"))
    };
    for s in slots {
        let main = pick(s, "id", "name", "got").unwrap_or_else(|| "—".into());
        let alt = pick(s, "alt", "altName", "altGot").map(|a| format!(" · *alt* {a}")).unwrap_or_default();
        lines.push(format!("**{}**: {main}{alt}", s.get("slot").and_then(|x| x.as_str()).unwrap_or("?")));
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
            "1": { "sid": 1, "slot": "Head", "id": 29011, "name": "Warbringer Greathelm", "got": true, "alt": 29068 },
            "2": { "sid": 2, "slot": "Neck", "id": 28244 } } } } });
        let mut p = bridge::Profiles::new();
        p.insert("9".into(), vec![Char { name: "Lee".into(), class: "WARRIOR".into(), spec: 3, by: String::new() }]);
        let t = bis_text_from(&snap, &p, "9", None, 160);
        assert!(t.starts_with("**Lee** · Protection · Phase 2"), "{t}");
        assert!(t.contains("**Head**: [Warbringer Greathelm](<https://www.wowhead.com/tbc/item=29011>) ✓ · *alt* [Item 29068]"), "{t}");
        assert!(t.contains("**Neck**: [Item 28244]"), "{t}");
        assert!(bis_text_from(&snap, &p, "9", Some("rita"), 160).contains("No BiS list for **Rita**"));
        assert!(bis_text_from(&snap, &p, "other", None, 160).contains("Whose list?"));
    }
}

// ------------------------------------------------------------------------------------------------------------------
// /bis set: change one slot of one of my characters' lists (a "bis" record; the host's addon routes it)
// ------------------------------------------------------------------------------------------------------------------

/// The addon's slots, by number (ns.SLOTS).
pub const SLOTS: [&str; 17] = [
    "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet", "Ring 1", "Ring 2",
    "Trinket 1", "Trinket 2", "Main Hand", "Off Hand", "Ranged / Relic",
];

#[allow(clippy::too_many_arguments)]
pub fn bis_set(user: &str, name: &str, sid: i64, item: &str, who: Option<&str>, alt: bool, phase: Option<i64>, now: u64) -> String {
    let chars = bridge::load_profiles().get(user).cloned().unwrap_or_default();
    let c = match who.map(str::trim).filter(|w| !w.is_empty()) {
        Some(w) => {
            let w = w.to_lowercase();
            chars.iter().find(|c| {
                let n = c.name.to_lowercase();
                n == w || n.split('-').next() == Some(w.as_str())
            })
        }
        None => chars.first(),
    };
    let Some(c) = c else {
        return "You can change your own characters' lists only. Make yours with /character.".into();
    };
    let Some(slot) = usize::try_from(sid).ok().filter(|s| (1..=17).contains(s)) else { return "Pick a slot.".into() };
    let clear = matches!(item.trim().to_lowercase().as_str(), "" | "0" | "none" | "empty");
    let id = if clear {
        0
    } else {
        match crate::items::resolve(item) {
            Some(id) => id,
            None => return format!("No item called \"{item}\". Pick one from the list as you type."),
        }
    };
    let snap = snap();
    let phase = phase.unwrap_or_else(|| snap.get("phase").and_then(|p| p.as_i64()).unwrap_or(1)).clamp(0, 5);
    let Some(dir) = crate::core::state::load().flavor_dir() else { return "The host has no game folder set.".into() };
    let r = bridge::Record {
        id: format!("bis_{now}_{user}_{}", NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)),
        kind: "bis".into(),
        at: now,
        by: name.to_string(),
        body: json!({ "name": c.name, "phase": phase, "sid": slot, "item": id, "which": if alt { "alt" } else { "main" } }),
        discord: user.to_string(),
    };
    if let Err(e) = bridge::push(&dir, r, now) {
        return format!("Could not save it: {e}");
    }
    let what = if clear {
        "emptied".to_string()
    } else {
        let n = crate::items::name_of(id).unwrap_or_else(|| format!("item {id}"));
        format!("{} set to [{n}](<https://www.wowhead.com/tbc/item={id}>)", if alt { "alternative" } else { "main pick" })
    };
    let ph = if phase == 0 { "Pre-raid".to_string() } else { format!("phase {phase}") };
    format!(
        "**{}**'s {} ({ph}): {what}. It reaches the game at the host's next /reload; with the addon, the list changes when {} is next online.",
        c.name,
        SLOTS[slot - 1],
        c.name
    )
}
