//! Discord bridge files (host mode): the queue of changes made in Discord, the inbox the addon reads at /reload, and
//! the addon's answer read back from SavedVariables (addon Core/Bridge.lua documents the formats).
//!
//!   queue  <config>/DisasterZoneLauncher/bridge_queue.json      records the game has not taken yet
//!   inbox  <flavor>/Interface/AddOns/DisasterZone_Bridge/Inbox.lua   DZBridgeInbox = { v, written, records }
//!   answer <flavor>/WTF/Account/<acct>/SavedVariables/DisasterZone.lua   DisasterZoneBridgeDB.applied[id]
//! A record leaves the queue once the newest SavedVariables mark it applied.

use super::error::Result;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

pub const FOLDER: &str = "DisasterZone_Bridge";
const SV_NAME: &str = "DisasterZoneBridgeDB";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Record {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    /// unix seconds
    pub at: u64,
    /// who made it (a Discord name until accounts are linked)
    pub by: String,
    #[serde(default)]
    pub body: Value,
    /// the Discord user it came from (told if the game refuses it)
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub discord: String,
}

// ------------------------------------------------------------------------------------------------------------------
// Links: which character a Discord user is (the game confirms it: addon Core/Bridge.lua, Linking)
// ------------------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Links {
    /// Discord user id -> character key ("Lee-Thunderstrike")
    pub links: std::collections::BTreeMap<String, String>,
    /// code -> (Discord user id, unix time made)
    pub codes: std::collections::BTreeMap<String, (String, u64)>,
}

const CODE_DAYS: u64 = 7;

fn links_path() -> PathBuf {
    queue_path().with_file_name("bridge_links.json")
}

pub fn load_links_at(p: &Path) -> Links {
    fs::read(p).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

pub fn load_links() -> Links {
    load_links_at(&links_path())
}

/// A new code for a Discord user (their older codes go).
pub fn new_code_at(p: &Path, discord: &str, now: u64) -> Result<String> {
    let mut l = load_links_at(p);
    l.codes.retain(|_, (d, at)| d != discord && *at + CODE_DAYS * 86400 > now);
    const ABC: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut seed = now ^ discord.bytes().fold(0u64, |h, b| h.wrapping_mul(31).wrapping_add(b as u64));
    let code = loop {
        let mut c = String::new();
        for _ in 0..6 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            c.push(ABC[(seed >> 33) as usize % ABC.len()] as char);
        }
        if !l.codes.contains_key(&c) {
            break c;
        }
    };
    l.codes.insert(code.clone(), (discord.to_string(), now));
    save_json(p, &l)?;
    Ok(code)
}

pub fn new_code(discord: &str, now: u64) -> Result<String> {
    new_code_at(&links_path(), discord, now)
}

fn queue_path() -> PathBuf {
    dirs::config_dir().unwrap_or_else(std::env::temp_dir).join("DisasterZoneLauncher").join("bridge_queue.json")
}

pub fn load_queue_at(p: &Path) -> Vec<Record> {
    fs::read(p).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

pub fn save_queue_at(p: &Path, q: &[Record]) -> Result<()> {
    fs::create_dir_all(p.parent().unwrap())?;
    let tmp = p.with_extension("tmp");
    fs::write(&tmp, serde_json::to_vec_pretty(q).unwrap())?;
    fs::rename(&tmp, p)?;
    Ok(())
}

pub fn load_queue() -> Vec<Record> {
    load_queue_at(&queue_path())
}

pub fn save_queue(q: &[Record]) -> Result<()> {
    save_queue_at(&queue_path(), q)
}

// ------------------------------------------------------------------------------------------------------------------
// Inbox.lua (+ the folder's TOC: the folder exists only on the host's PC, the launcher makes it)
// ------------------------------------------------------------------------------------------------------------------

fn lua_str(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\0' => out.push_str("\\0"),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn lua_value(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("nil"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&n.to_string()),
        Value::String(s) => lua_str(s, out),
        Value::Array(a) => {
            out.push('{');
            for x in a {
                lua_value(x, out);
                out.push_str(", ");
            }
            out.push('}');
        }
        Value::Object(m) => {
            out.push('{');
            for (k, x) in m {
                out.push('[');
                lua_str(k, out);
                out.push_str("] = ");
                lua_value(x, out);
                out.push_str(", ");
            }
            out.push('}');
        }
    }
}

/// A Discord text channel the GM can post raids to (listed in the addon's Settings > Discord).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Channel {
    pub id: String,
    pub name: String,
}

fn channels_path() -> PathBuf {
    queue_path().with_file_name("bridge_channels.json")
}

pub fn load_channels() -> Vec<Channel> {
    fs::read(channels_path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

pub fn save_channels(c: &[Channel]) -> Result<()> {
    save_json(&channels_path(), c)
}

pub fn save_json<T: Serialize + ?Sized>(p: &Path, v: &T) -> Result<()> {
    fs::create_dir_all(p.parent().unwrap())?;
    let tmp = p.with_extension("tmp");
    fs::write(&tmp, serde_json::to_vec_pretty(v).unwrap())?;
    fs::rename(&tmp, p)?;
    Ok(())
}

pub fn inbox_lua(records: &[Record], written: u64, channels: &[Channel], linked: &[String]) -> String {
    let mut s = String::from("-- Written by the DisasterZone launcher (host mode). Do not edit: it is rewritten.\n");
    s.push_str(&format!("DZBridgeInbox = {{ v = 1, written = {written}, records = {{\n"));
    for r in records {
        s.push_str("  ");
        lua_value(&serde_json::to_value(r).unwrap(), &mut s);
        s.push_str(",\n");
    }
    s.push_str("}, channels = ");
    lua_value(&serde_json::to_value(channels).unwrap(), &mut s);
    s.push_str(", linked = ");
    lua_value(&serde_json::to_value(linked).unwrap(), &mut s);
    s.push_str(" }\n");
    s
}

/// The `## Interface:` line of DisasterZone's TOC, so the bridge folder never shows as out of date.
fn interface_of(addons: &Path) -> String {
    fs::read_to_string(addons.join("DisasterZone").join("DisasterZone.toc"))
        .ok()
        .and_then(|t| t.lines().find_map(|l| l.strip_prefix("## Interface:").map(|v| v.trim().to_string())))
        .unwrap_or_else(|| "20506".into())
}

fn write_atomic(p: &Path, text: &str) -> Result<()> {
    if fs::read_to_string(p).ok().as_deref() == Some(text) {
        return Ok(());
    }
    let tmp = p.with_extension("tmp");
    fs::write(&tmp, text)?;
    fs::rename(&tmp, p)?;
    Ok(())
}

/// Write the bridge folder for these records (the game reads it at its next login or /reload).
pub fn write_inbox(flavor_dir: &Path, records: &[Record], written: u64, linked: &[String]) -> Result<()> {
    let addons = flavor_dir.join("Interface").join("AddOns");
    let dir = addons.join(FOLDER);
    fs::create_dir_all(&dir)?;
    let toc = format!(
        "## Interface: {}\n## Title: |cffff8000Disaster|rZone Discord bridge\n## Notes: Made by the DisasterZone launcher on the host's PC: what the guild's Discord bot hands to the game.\n## Author: Casual Disaster\n## Version: 1\n\nInbox.lua\n",
        interface_of(&addons)
    );
    write_atomic(&dir.join(format!("{FOLDER}.toc")), &toc)?;
    write_atomic(&dir.join("Inbox.lua"), &inbox_lua(records, written, &load_channels(), linked))
}

// ------------------------------------------------------------------------------------------------------------------
// Reading SavedVariables: a small reader for the Lua WoW writes (tables, strings, numbers, booleans, nil, comments)
// ------------------------------------------------------------------------------------------------------------------

struct Lua<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Lua<'a> {
    fn skip(&mut self) {
        loop {
            while self.i < self.b.len() && self.b[self.i].is_ascii_whitespace() {
                self.i += 1;
            }
            if self.b[self.i..].starts_with(b"--") {
                while self.i < self.b.len() && self.b[self.i] != b'\n' {
                    self.i += 1;
                }
            } else {
                return;
            }
        }
    }

    fn eat(&mut self, c: u8) -> bool {
        self.skip();
        if self.b.get(self.i) == Some(&c) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    fn string(&mut self) -> Option<String> {
        let q = self.b[self.i];
        self.i += 1;
        let mut out = Vec::new();
        while let Some(&c) = self.b.get(self.i) {
            self.i += 1;
            if c == q {
                return Some(String::from_utf8_lossy(&out).into_owned());
            }
            if c != b'\\' {
                out.push(c);
                continue;
            }
            let e = *self.b.get(self.i)?;
            self.i += 1;
            match e {
                b'n' => out.push(b'\n'),
                b't' => out.push(b'\t'),
                b'r' => out.push(b'\r'),
                b'0'..=b'9' => {
                    let mut n = (e - b'0') as u32;
                    for _ in 0..2 {
                        match self.b.get(self.i) {
                            Some(d @ b'0'..=b'9') => {
                                n = n * 10 + (d - b'0') as u32;
                                self.i += 1;
                            }
                            _ => break,
                        }
                    }
                    out.push(n as u8);
                }
                b'\n' => out.push(b'\n'),
                other => out.push(other),
            }
        }
        None
    }

    fn value(&mut self) -> Option<Value> {
        self.skip();
        let c = *self.b.get(self.i)?;
        match c {
            b'{' => self.table(),
            b'"' | b'\'' => self.string().map(Value::String),
            _ => {
                let start = self.i;
                while self.i < self.b.len()
                    && (self.b[self.i].is_ascii_alphanumeric() || b"-+._".contains(&self.b[self.i]))
                {
                    self.i += 1;
                }
                if self.i == start {
                    return None; // (not a value: stop instead of looping)
                }
                let w = std::str::from_utf8(&self.b[start..self.i]).ok()?;
                match w {
                    "true" => Some(Value::Bool(true)),
                    "false" => Some(Value::Bool(false)),
                    "nil" => Some(Value::Null),
                    _ => {
                        if let Ok(n) = w.parse::<i64>() {
                            Some(Value::from(n))
                        } else {
                            // (inf / nan have no JSON form: null)
                            Some(w.parse::<f64>().ok().and_then(serde_json::Number::from_f64).map_or(Value::Null, Value::Number))
                        }
                    }
                }
            }
        }
    }

    /// `name =` (a key without brackets): the name, past the `=`; otherwise nothing is consumed.
    fn name_key(&mut self) -> Option<String> {
        let start = self.i;
        let mut j = start;
        while j < self.b.len() && (self.b[j].is_ascii_alphanumeric() || self.b[j] == b'_') {
            j += 1;
        }
        if j == start || self.b[start].is_ascii_digit() {
            return None;
        }
        let name = std::str::from_utf8(&self.b[start..j]).ok()?.to_string();
        if ["true", "false", "nil"].contains(&name.as_str()) {
            return None;
        }
        self.i = j;
        if self.eat(b'=') && self.b.get(self.i) != Some(&b'=') {
            Some(name)
        } else {
            self.i = start;
            None
        }
    }

    /// A table becomes a JSON object; array entries get keys "1", "2", ... (Lua's own numbering).
    fn table(&mut self) -> Option<Value> {
        self.i += 1;
        let mut m = Map::new();
        let mut n = 0;
        loop {
            if self.eat(b'}') {
                return Some(Value::Object(m));
            }
            self.skip();
            let key = if self.b.get(self.i) == Some(&b'[') {
                self.i += 1;
                let k = match self.value()? {
                    Value::String(s) => s,
                    other => other.to_string(),
                };
                if !self.eat(b']') || !self.eat(b'=') {
                    return None;
                }
                k
            } else if let Some(k) = self.name_key() {
                k
            } else {
                n += 1;
                n.to_string()
            };
            let v = self.value()?;
            m.insert(key, v);
            self.eat(b',');
            self.eat(b';');
        }
    }
}

/// The value assigned to the global `name` in a SavedVariables file (WoW writes `Name = value` at line start).
pub fn read_global(text: &str, name: &str) -> Option<Value> {
    let head = format!("{name} = ");
    let start = if text.starts_with(&head) { 0 } else { text.find(&format!("\n{head}"))? + 1 };
    let mut p = Lua { b: text.as_bytes(), i: start + head.len() };
    p.value()
}

/// DisasterZoneBridgeDB from the newest SavedVariables under a game folder.
pub fn read_bridge_db(flavor_dir: &Path) -> Option<Value> {
    let accounts = fs::read_dir(flavor_dir.join("WTF").join("Account")).ok()?;
    let (_, path) = accounts
        .flatten()
        .map(|a| a.path().join("SavedVariables").join("DisasterZone.lua"))
        .filter_map(|p| Some((fs::metadata(&p).ok()?.modified().ok()?, p)))
        .max()?;
    let text = fs::read(&path).map(|d| String::from_utf8_lossy(&d).into_owned()).ok()?;
    read_global(&text, SV_NAME)
}

/// Ids the addon has taken (DisasterZoneBridgeDB.applied).
pub fn applied_ids(flavor_dir: &Path) -> BTreeSet<String> {
    read_bridge_db(flavor_dir)
        .and_then(|v| v.get("applied").and_then(|a| a.as_object()).map(|a| a.keys().cloned().collect()))
        .unwrap_or_default()
}

/// A Lua array as read (an object with keys "1", "2", ...) in order; any other value: empty.
pub fn lua_list(v: Option<&Value>) -> Vec<&Value> {
    let Some(Value::Object(m)) = v else { return Vec::new() };
    let mut out: Vec<(usize, &Value)> = m.iter().filter_map(|(k, x)| Some((k.parse().ok()?, x))).collect();
    out.sort_by_key(|(i, _)| *i);
    out.into_iter().map(|(_, x)| x).collect()
}

/// Drop what the game took, rewrite the inbox. Returns the records still waiting.
#[derive(Debug, Default)]
pub struct Synced {
    /// still waiting for the game
    pub queue: Vec<Record>,
    /// taken but refused: (record, why)
    pub failed: Vec<(Record, String)>,
    /// new links: (Discord user id, character key)
    pub linked: Vec<(String, String)>,
}

/// Drop what the game took, take the link codes it confirmed, rewrite the inbox.
pub fn sync_at(queue: &Path, links: &Path, flavor_dir: &Path, now: u64) -> Result<Synced> {
    let db = read_bridge_db(flavor_dir).unwrap_or(Value::Null);
    let applied = db.get("applied").and_then(|a| a.as_object()).cloned().unwrap_or_default();
    let mut out = Synced::default();
    let all = load_queue_at(queue);
    let before = all.len();
    for r in all {
        match applied.get(&r.id) {
            None => out.queue.push(r),
            Some(m) => {
                if m.get("ok").and_then(|x| x.as_bool()) != Some(true) {
                    let why = m.get("why").and_then(|x| x.as_str()).unwrap_or("refused").to_string();
                    out.failed.push((r, why));
                }
            }
        }
    }
    if out.queue.len() != before {
        save_queue_at(queue, &out.queue)?;
    }
    let mut l = load_links_at(links);
    let mut changed = false;
    if let Some(claims) = db.get("claims").and_then(|c| c.as_object()) {
        for (code, c) in claims {
            let Some(key) = c.get("k").and_then(|k| k.as_str()) else { continue };
            if let Some((discord, _)) = l.codes.remove(code) {
                l.links.insert(discord.clone(), key.to_string());
                out.linked.push((discord, key.to_string()));
                changed = true;
            }
        }
    }
    if changed {
        save_json(links, &l)?;
    }
    let linked: Vec<String> = l.links.values().cloned().collect::<BTreeSet<_>>().into_iter().collect();
    write_inbox(flavor_dir, &out.queue, now, &linked)?;
    Ok(out)
}

pub fn sync(flavor_dir: &Path, now: u64) -> Result<Synced> {
    sync_at(&queue_path(), &links_path(), flavor_dir, now)
}

pub fn push_at(queue: &Path, flavor_dir: &Path, r: Record, now: u64) -> Result<Vec<Record>> {
    let mut q = load_queue_at(queue);
    q.push(r);
    save_queue_at(queue, &q)?;
    Ok(sync_at(queue, &queue.with_file_name("links.json"), flavor_dir, now)?.queue)
}

pub fn push(flavor_dir: &Path, r: Record, now: u64) -> Result<Vec<Record>> {
    let mut q = load_queue();
    q.push(r);
    save_queue(&q)?;
    Ok(sync(flavor_dir, now)?.queue)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const SV: &str = r#"
DisasterZoneDB = {
	["big"] = { 1, 2, 3, },
}
DisasterZoneBridgeDB = {
	["applied"] = {
		["dc_1"] = {
			["t"] = 1791900000,
			["ok"] = true,
		},
		["dc_2"] = {
			["why"] = "unknown type \"x\"\nline\124two",
			["ok"] = false,
			["t"] = 1.5e3,
		},
	},
	["loaded"] = 1791900001,
	["list"] = {
		"a", -- [1]
		'b', -- [2]
	},
}
"#;

    #[test]
    fn reads_what_wow_writes() {
        let v = read_global(SV, "DisasterZoneBridgeDB").unwrap();
        assert_eq!(v["applied"]["dc_1"]["ok"], json!(true));
        assert_eq!(v["applied"]["dc_2"]["why"], json!("unknown type \"x\"\nline|two"));
        assert_eq!(v["applied"]["dc_2"]["t"], json!(1500.0));
        assert_eq!(v["list"]["2"], json!("b"));
        assert_eq!(read_global(SV, "DisasterZoneDB").unwrap()["big"]["3"], json!(3));
        assert!(read_global(SV, "Nope").is_none());
    }

    fn rec(id: &str, text: &str) -> Record {
        Record { id: id.into(), kind: "test".into(), at: 1, by: "Tsumi".into(), body: json!({ "text": text }), discord: "42".into() }
    }

    #[test]
    fn inbox_round_trips_through_the_reader() {
        let lua = inbox_lua(&[rec("dc_1", "hi \"there\" | \\ \n")], 7, &[Channel { id: "1".into(), name: "raids".into() }],
            &["Lee-X".to_string()]);
        let v = read_global(&lua, "DZBridgeInbox").unwrap();
        assert_eq!(v["written"], json!(7));
        assert_eq!(lua_list(v.get("channels"))[0]["name"], json!("raids"));
        assert_eq!(lua_list(v.get("linked"))[0], &json!("Lee-X"));
        assert_eq!(v["records"]["1"]["id"], json!("dc_1"));
        assert_eq!(v["records"]["1"]["body"]["text"], json!("hi \"there\" | \\ \n"));
    }

    #[test]
    fn refused_records_are_reported() {
        let dir = tempfile::tempdir().unwrap();
        let flavor = dir.path().join("_anniversary_");
        let queue = dir.path().join("q.json");
        let links = dir.path().join("links.json");
        save_queue_at(&queue, &[rec("dc_2", "x")]).unwrap();
        let sv = flavor.join("WTF/Account/ACCT/SavedVariables");
        fs::create_dir_all(&sv).unwrap();
        fs::write(sv.join("DisasterZone.lua"), SV).unwrap();
        let out = sync_at(&queue, &links, &flavor, 1).unwrap();
        assert!(out.queue.is_empty());
        assert_eq!(out.failed.len(), 1);
        assert!(out.failed[0].1.starts_with("unknown type"));
        assert_eq!(out.failed[0].0.discord, "42");
    }

    #[test]
    fn codes_are_unique_and_replace_older_ones() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("l.json");
        let a = new_code_at(&p, "1", 100).unwrap();
        let b = new_code_at(&p, "1", 101).unwrap();
        let c = new_code_at(&p, "2", 101).unwrap();
        assert_eq!(a.len(), 6);
        let l = load_links_at(&p);
        assert!(!l.codes.contains_key(&a) && l.codes.contains_key(&b) && l.codes.contains_key(&c));
    }

    #[test]
    fn taken_records_leave_the_queue() {
        let dir = tempfile::tempdir().unwrap();
        let flavor = dir.path().join("_anniversary_");
        let queue = dir.path().join("q.json");
        let addon = flavor.join("Interface/AddOns/DisasterZone");
        fs::create_dir_all(&addon).unwrap();
        fs::write(addon.join("DisasterZone.toc"), "## Interface: 20504\n").unwrap();
        push_at(&queue, &flavor, rec("dc_1", "a"), 10).unwrap();
        let q = push_at(&queue, &flavor, rec("dc_9", "b"), 11).unwrap();
        assert_eq!(q.len(), 2);
        let toc = fs::read_to_string(flavor.join("Interface/AddOns/DisasterZone_Bridge/DisasterZone_Bridge.toc")).unwrap();
        assert!(toc.contains("## Interface: 20504"));
        let inbox = fs::read_to_string(flavor.join("Interface/AddOns/DisasterZone_Bridge/Inbox.lua")).unwrap();
        assert!(inbox.contains("dc_9"));
        // the game took dc_1 (and an old dc_2 no longer queued)
        let sv = flavor.join("WTF/Account/ACCT/SavedVariables");
        fs::create_dir_all(&sv).unwrap();
        fs::write(sv.join("DisasterZone.lua"), SV).unwrap();
        let links = dir.path().join("links.json");
        let code = new_code_at(&links, "42", 12).unwrap();
        let sv_text = SV.replace("[\"loaded\"]", &format!("[\"claims\"] = {{ [\"{code}\"] = {{ [\"k\"] = \"Lee-X\" }} }},\n\t[\"loaded\"]"));
        fs::write(sv.join("DisasterZone.lua"), sv_text).unwrap();
        let out = sync_at(&queue, &links, &flavor, 12).unwrap();
        let q = out.queue;
        assert_eq!(q.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), vec!["dc_9"]);
        assert!(out.failed.is_empty()); // (dc_1 was ok)
        assert_eq!(out.linked, vec![("42".to_string(), "Lee-X".to_string())]);
        assert_eq!(load_links_at(&links).links["42"], "Lee-X");
        assert!(load_links_at(&links).codes.is_empty());
        assert_eq!(load_queue_at(&queue).len(), 1);
        let inbox = fs::read_to_string(flavor.join("Interface/AddOns/DisasterZone_Bridge/Inbox.lua")).unwrap();
        assert!(!inbox.contains("dc_1") && inbox.contains("dc_9"));
    }
}
