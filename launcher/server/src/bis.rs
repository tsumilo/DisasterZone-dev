//! /bis in Discord: the gear sheet picture (render::sheet) with phase buttons and the off spec, and
//! "Edit a slot" for the list's owner (slot menu → a small form for the item → a menu of matches). An edit becomes a
//! "bis" record in the bridge queue (the first game that loads it routes it: addon Core/Bridge.lua) and shows on the sheet at once
//! as pending.
//!
//! Custom ids (Discord allows 100 characters):
//!   bs:<p>:<l>:<name>              switch phase / list (also Back)     l = "m" main spec, "o" off spec
//!   be:<p>:<l>:<name>              Edit a slot (the owner): the slot menu under the sheet
//!   bq:<p>:<l>:<name>              the slot menu
//!   bm:<p>:<l>:<sid>:<name>        the item form
//!   bi:<p>:<l>:<sid>:<w>:<name>    the matches menu  (w = "m" main pick, "a" alternative)
//! The sheet is private; every step edits that same message.

use crate::core::bridge::{self, lua_list, Record};
use crate::render::sheet::{Sheet, Slot};
use serde_json::{json, Value};
use twilight_model::application::interaction::modal::{ModalInteractionComponent, ModalInteractionData};
use twilight_model::channel::message::component::{
    ActionRow, Button, ButtonStyle, Component, Label, SelectMenu, SelectMenuOption, SelectMenuType, TextInput, TextInputStyle,
};
use twilight_model::channel::message::Embed;
use twilight_util::builder::embed::{EmbedBuilder, ImageSource};

/// What the bot answers with.
pub enum Reply {
    /// a message (public or private) or an edit of the one clicked, with a picture
    Pic { update: bool, private: bool, text: Option<String>, embed: Option<Embed>, comps: Vec<Component>, file: Option<(String, Vec<u8>)> },
    Modal { custom_id: String, title: String, components: Vec<Component> },
}

fn private(text: impl Into<String>) -> Reply {
    Reply::Pic { update: false, private: true, text: Some(text.into()), embed: None, comps: Vec::new(), file: None }
}

fn short(key: &str) -> &str {
    key.split('-').next().unwrap_or(key)
}

const SLOTS: [&str; 17] = crate::signup::SLOTS;

fn phase_name(p: u8) -> String {
    if p == 0 { "Pre-raid".into() } else { format!("Phase {p}") }
}

/// The snapshot's list of a character (by name, any case, with or without realm): (key, entry).
fn find<'a>(snap: &'a Value, name: &str) -> Option<(&'a String, &'a Value)> {
    let want = name.to_lowercase();
    snap.get("bis")?.as_object()?.iter().find(|(k, _)| {
        let k = k.to_lowercase();
        k == want || k.split('-').next() == Some(want.as_str())
    })
}

/// The sheet's slots for one phase and list: the snapshot's, with this character's pending Discord edits on top.
fn slots(snap: &Value, entry: &Value, name: &str, phase: u8, off: bool, queue: &[Record]) -> Vec<Slot> {
    let items = snap.get("items").cloned().unwrap_or(Value::Null);
    let item = |id: u64| -> (String, u8, String) {
        let it = items.get(id.to_string());
        let n = it.and_then(|x| x.get("n")).and_then(|x| x.as_str()).map(str::to_string)
            .or_else(|| crate::items::name_of(id as u32)).unwrap_or_else(|| format!("Item {id}"));
        let q = it.and_then(|x| x.get("q")).and_then(|x| x.as_u64()).unwrap_or(4) as u8;
        let s = it.and_then(|x| x.get("s")).and_then(|x| x.as_str()).unwrap_or("").to_string();
        (n, q, s)
    };
    // sid -> (main, main got, alt)
    let mut by: std::collections::BTreeMap<u64, (u64, bool, u64, bool)> = Default::default();
    let mut ph = entry.get(if off { "oph" } else { "ph" }).and_then(|p| p.get(phase.to_string()));
    // (a snapshot from before 1.4.2's phases: only the guild phase's main-spec picks, in "slots")
    if entry.get("ph").is_none() && !off && snap.get("phase").and_then(|p| p.as_u64()) == Some(phase as u64) {
        ph = entry.get("slots");
    }
    for s in lua_list(ph) {
        let sid = s.get("sid").and_then(|x| x.as_u64()).unwrap_or(0);
        by.insert(sid, (
            s.get("id").and_then(|x| x.as_u64()).unwrap_or(0),
            s.get("got").and_then(|x| x.as_bool()).unwrap_or(false),
            s.get("alt").and_then(|x| x.as_u64()).unwrap_or(0),
            false,
        ));
    }
    let lower = name.to_lowercase();
    for r in queue.iter().filter(|r| r.kind == "bis") {
        let b = &r.body;
        let n = b.get("name").and_then(|x| x.as_str()).unwrap_or("").to_lowercase();
        if short(&n) != short(&lower)
            || b.get("phase").and_then(|x| x.as_u64()) != Some(phase as u64)
            || (b.get("list").and_then(|x| x.as_str()) == Some("os")) != off
        {
            continue;
        }
        let sid = b.get("sid").and_then(|x| x.as_u64()).unwrap_or(0);
        let it = b.get("item").and_then(|x| x.as_u64()).unwrap_or(0);
        let e = by.entry(sid).or_insert((0, false, 0, false));
        if b.get("which").and_then(|x| x.as_str()) == Some("alt") {
            e.2 = it;
        } else {
            e.0 = it;
            e.1 = false;
        }
        e.3 = true;
    }
    by.into_iter()
        .filter(|(_, v)| v.0 > 0 || v.2 > 0)
        .map(|(sid, (main, got, alt, changed))| {
            let label = SLOTS.get(sid as usize - 1).copied().unwrap_or("?").to_string();
            let (n, q, src) = if main > 0 { item(main) } else { ("nothing picked".into(), 4, String::new()) };
            let sub = if alt > 0 { format!("alt · {}", item(alt).0) } else { src };
            Slot { label, id: main as u32, name: n, quality: q, got, sub: if changed { format!("pending · {sub}") } else { sub }, changed }
        })
        .collect()
}

/// The sheet message of a character: (embed, components, file).
fn sheet(snap: &Value, name: &str, phase: Option<u8>, off: bool) -> Option<(Embed, Vec<Component>, Option<(String, Vec<u8>)>)> {
    let (key, entry) = find(snap, name)?;
    // (the class from the list, else from the guild roster)
    let roster_class = lua_list(snap.get("roster"))
        .into_iter()
        .find(|m| m.get("key").and_then(|k| k.as_str()) == Some(key.as_str()))
        .and_then(|m| m.get("class").and_then(|c| c.as_str()));
    let class = entry.get("class").and_then(|x| x.as_str()).or(roster_class).unwrap_or("");
    let phase = phase.unwrap_or_else(|| snap.get("phase").and_then(|p| p.as_u64()).unwrap_or(1) as u8);
    let has_off = entry.get("oph").is_some();
    let off = off && has_off;
    let queue = bridge::load_queue();
    let list = slots(snap, entry, key, phase, off, &queue);
    let spec = if off { entry.get("os") } else { entry.get("spec") }.and_then(|x| x.as_str()).unwrap_or("");
    let cname = crate::signup::CLASSES.iter().find(|c| c.0 == class).map_or("", |c| c.1);
    let spec_line = format!("{spec} {cname} · {}", if off { "off spec" } else { "main spec" }).trim().to_string();
    let file = crate::render::art().map(|art| {
        let png = crate::render::sheet::draw(art, &Sheet { name: short(key), class, spec_line: &spec_line, phase: &phase_name(phase), slots: list });
        ("bis.png".to_string(), png)
    });
    let mut e = EmbedBuilder::new().color(0xa335ee);
    if file.is_some() {
        if let Ok(src) = ImageSource::attachment("bis.png") {
            e = e.image(src);
        }
    } else {
        e = e.description(crate::signup::bis_text_from(snap, &bridge::load_profiles(), "", Some(key), crate::bot::unix_now()));
    }
    let l = if off { "o" } else { "m" };
    let n = short(key);
    let btn = |id: String, label: &str, style, on: bool| {
        Component::Button(Button {
            id: None,
            custom_id: Some(id),
            disabled: on,
            emoji: None,
            label: Some(label.into()),
            style,
            url: None,
            sku_id: None,
        })
    };
    let phases: Vec<Component> = (0..=4u8)
        .map(|p| btn(format!("bs:{p}:{l}:{n}"), &if p == 0 { "Pre-raid".into() } else { format!("Phase {p}") }, if p == phase { ButtonStyle::Primary } else { ButtonStyle::Secondary }, p == phase))
        .collect();
    let mut row2 = vec![btn(format!("bs:5:{l}:{n}"), "Phase 5", if phase == 5 { ButtonStyle::Primary } else { ButtonStyle::Secondary }, phase == 5)];
    if has_off {
        let other = if off { "m" } else { "o" };
        row2.push(btn(format!("bs:{phase}:{other}:{n}"), if off { "Main spec" } else { "Off spec" }, ButtonStyle::Secondary, false));
    }
    row2.push(btn(format!("be:{phase}:{l}:{n}"), "✎ Edit a slot", ButtonStyle::Primary, false));
    let comps = vec![
        Component::ActionRow(ActionRow { id: None, components: phases }),
        Component::ActionRow(ActionRow { id: None, components: row2 }),
    ];
    Some((e.build(), comps, file))
}

/// The sheet as a reply. `edit`: the controls under it are replaced (a menu + Back), `note`: a line above it.
fn sheet_reply(snap: &Value, name: &str, phase: u8, off: bool, update: bool, edit: Option<Component>, note: Option<String>) -> Reply {
    match sheet(snap, name, Some(phase), off) {
        Some((e, comps, file)) => {
            let comps = match edit {
                Some(c) => {
                    let l = if off { "o" } else { "m" };
                    let back = Component::Button(Button {
                        id: None,
                        custom_id: Some(format!("bs:{phase}:{l}:{}", short(name))),
                        disabled: false,
                        emoji: None,
                        label: Some("Back".into()),
                        style: ButtonStyle::Secondary,
                        url: None,
                        sku_id: None,
                    });
                    vec![row(c), Component::ActionRow(ActionRow { id: None, components: vec![back] })]
                }
                None => comps,
            };
            Reply::Pic { update, private: true, text: Some(note.unwrap_or_default()), embed: Some(e), comps, file }
        }
        None => private("That list is gone."),
    }
}

/// /bis show [character]: the sheet, privately (everything after happens in that one message).
pub fn show(user: &str, who: Option<&str>) -> Reply {
    let snap = crate::signup::current_snap().unwrap_or(Value::Null);
    let name = match who.map(str::trim).filter(|w| !w.is_empty()) {
        Some(w) => w.to_string(),
        None => match bridge::load_profiles().get(user).and_then(|c| c.first()) {
            Some(c) => c.name.clone(),
            None => return private("Whose list? `/bis show character:Name`, or make your character with /character."),
        },
    };
    if find(&snap, &name).is_none() {
        return private(format!("No BiS list for **{}** yet. Lists come from the addon's My BiS.", bridge::tidy_name(&name)));
    }
    let phase = snap.get("phase").and_then(|p| p.as_u64()).unwrap_or(1) as u8;
    sheet_reply(&snap, &name, phase, false, false, None, None)
}

fn owns(user: &str, name: &str) -> bool {
    let n = short(name).to_lowercase();
    bridge::load_profiles().get(user).is_some_and(|cs| cs.iter().any(|c| short(&c.name).to_lowercase() == n))
}

fn option(label: String, value: String, description: Option<String>) -> SelectMenuOption {
    SelectMenuOption { default: false, description, emoji: None, label, value }
}

fn menu(custom_id: String, placeholder: &str, options: Vec<SelectMenuOption>) -> SelectMenu {
    SelectMenu {
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
    }
}

fn row(c: Component) -> Component {
    Component::ActionRow(ActionRow { id: None, components: vec![c] })
}

/// A click on a sheet button.
pub fn button(user: &str, custom: &str) -> Reply {
    let parts: Vec<&str> = custom.splitn(4, ':').collect();
    let snap = crate::signup::current_snap().unwrap_or(Value::Null);
    match parts[..] {
        ["bs", p, l, name] => sheet_reply(&snap, name, p.parse().unwrap_or(1), l == "o", true, None, None),
        ["be", p, l, name] => {
            if !owns(user, name) {
                return private(format!("Only {name}'s player edits this list. Your own: `/bis show`."));
            }
            let opts = SLOTS.iter().enumerate().map(|(i, s)| option(s.to_string(), (i + 1).to_string(), None)).collect();
            let m = Component::SelectMenu(menu(format!("bq:{p}:{l}:{name}"), "Which slot?", opts));
            sheet_reply(&snap, name, p.parse().unwrap_or(1), l == "o", true, Some(m), None)
        }
        _ => private("Unknown button."),
    }
}

/// A choice in the slot menu or the matches menu.
pub fn select(user: &str, by: &str, custom: &str, values: &[String]) -> Reply {
    let v = values.first().map(String::as_str).unwrap_or("");
    let parts: Vec<&str> = custom.split(':').collect();
    match parts[..] {
        ["bq", p, l, name] => Reply::Modal {
            custom_id: format!("bm:{p}:{l}:{v}:{name}"),
            title: format!("{} · {}", SLOTS.get(v.parse::<usize>().unwrap_or(1).saturating_sub(1)).unwrap_or(&"Slot"), name),
            components: item_form(),
        },
        ["bi", p, l, sid, w, name] => apply(user, by, p, l, sid, w, name, v),
        _ => private("Unknown menu."),
    }
}

#[allow(deprecated)] // (TextInput::label: the Label around it carries the words)
fn item_form() -> Vec<Component> {
    vec![
        Component::Label(Label {
            id: None,
            label: "Item".into(),
            description: Some("A few letters of its name are enough. Empty = empty the slot.".into()),
            component: Box::new(Component::TextInput(TextInput {
                id: None,
                custom_id: "item".into(),
                label: None,
                max_length: Some(60),
                min_length: None,
                placeholder: Some("e.g. dragonspine".into()),
                required: Some(false),
                style: TextInputStyle::Short,
                value: None,
            })),
        }),
        Component::Label(Label {
            id: None,
            label: "Pick".into(),
            description: None,
            component: Box::new(Component::SelectMenu(SelectMenu {
                required: Some(false),
                ..menu("which".into(), "Main pick", vec![
                    option("Main pick".into(), "m".into(), None),
                    option("Alternative".into(), "a".into(), Some("The slot's second choice".into())),
                ])
            })),
        }),
    ]
}

/// The item form was sent (from the sheet's message): one clear match is set at once, else the matches menu.
pub fn form_sent(user: &str, by: &str, data: &ModalInteractionData) -> Reply {
    let parts: Vec<&str> = data.custom_id.split(':').collect();
    let ["bm", p, l, sid, name] = parts[..] else { return private("Unknown form.") };
    let (mut typed, mut which) = (String::new(), "m".to_string());
    fn walk(c: &ModalInteractionComponent, t: &mut String, w: &mut String) {
        match c {
            ModalInteractionComponent::Label(x) => walk(&x.component, t, w),
            ModalInteractionComponent::ActionRow(r) => r.components.iter().for_each(|x| walk(x, t, w)),
            ModalInteractionComponent::TextInput(x) if x.custom_id == "item" => *t = x.value.clone(),
            ModalInteractionComponent::StringSelect(x) if x.custom_id == "which" => {
                if let Some(v) = x.values.first() {
                    *w = v.clone();
                }
            }
            _ => {}
        }
    }
    data.components.iter().for_each(|c| walk(c, &mut typed, &mut which));
    let typed = typed.trim();
    if typed.is_empty() {
        return apply(user, by, p, l, sid, &which, name, "0");
    }
    let found = crate::items::search(typed);
    if let Some((id, _)) = found.iter().find(|(_, n)| n.eq_ignore_ascii_case(typed)).or(if found.len() == 1 { found.first() } else { None }) {
        return apply(user, by, p, l, sid, &which, name, &id.to_string());
    }
    let snap = crate::signup::current_snap().unwrap_or(Value::Null);
    let (phase, off) = (p.parse().unwrap_or(1), l == "o");
    if found.is_empty() {
        return sheet_reply(&snap, name, phase, off, true, None, Some(format!("No raid item called \"{typed}\". Try fewer letters.")));
    }
    let opts = found.into_iter().map(|(id, n)| option(n, id.to_string(), crate::items::source_hint(id))).collect();
    let slot = SLOTS.get(sid.parse::<usize>().unwrap_or(1).saturating_sub(1)).unwrap_or(&"the slot");
    let m = Component::SelectMenu(menu(format!("bi:{p}:{l}:{sid}:{which}:{name}"), &format!("Which one for {slot}?"), opts));
    sheet_reply(&snap, name, phase, off, true, Some(m), None)
}

/// Queue the edit and show the sheet with it (pending).
#[allow(clippy::too_many_arguments)]
fn apply(user: &str, by: &str, p: &str, l: &str, sid: &str, w: &str, name: &str, item: &str) -> Reply {
    if !owns(user, name) {
        return private("Only that character's player edits this list.");
    }
    let (phase, slot, id) = (p.parse::<u8>().unwrap_or(1), sid.parse::<usize>().unwrap_or(0), item.parse::<u64>().unwrap_or(0));
    if !(1..=17).contains(&slot) {
        return private("Pick a slot.");
    }
    let now = crate::bot::unix_now();
    let r = Record {
        id: format!("bis_{now}_{user}_{slot}_{w}"),
        kind: "bis".into(),
        at: now,
        by: by.to_string(),
        body: json!({ "name": name, "phase": phase, "sid": slot, "item": id, "which": if w == "a" { "alt" } else { "main" },
                      "list": if l == "o" { "os" } else { "ms" } }),
        discord: user.to_string(),
        sig: String::new(),
    };
    if let Err(e) = bridge::push(r) {
        return private(format!("Could not save it: {e}"));
    }
    let slot_name = SLOTS[slot - 1];
    let what = if id == 0 {
        format!("**{slot_name}** emptied")
    } else {
        let n = crate::items::name_of(id as u32).unwrap_or_else(|| format!("item {id}"));
        format!("**{slot_name}** {} set to **{n}**", if w == "a" { "alternative" } else { "main pick" })
    };
    let snap = crate::signup::current_snap().unwrap_or(Value::Null);
    sheet_reply(&snap, name, phase, l == "o", true, None, Some(format!("{what}. Your addon takes it when you're both online; until then it shows as pending.")))
}
