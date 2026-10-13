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

pub fn inbox_lua(records: &[Record], written: u64) -> String {
    let mut s = String::from("-- Written by the DisasterZone launcher (host mode). Do not edit: it is rewritten.\n");
    s.push_str(&format!("DZBridgeInbox = {{ v = 1, written = {written}, records = {{\n"));
    for r in records {
        s.push_str("  ");
        lua_value(&serde_json::to_value(r).unwrap(), &mut s);
        s.push_str(",\n");
    }
    s.push_str("} }\n");
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
pub fn write_inbox(flavor_dir: &Path, records: &[Record], written: u64) -> Result<()> {
    let addons = flavor_dir.join("Interface").join("AddOns");
    let dir = addons.join(FOLDER);
    fs::create_dir_all(&dir)?;
    let toc = format!(
        "## Interface: {}\n## Title: |cffff8000Disaster|rZone Discord bridge\n## Notes: Made by the DisasterZone launcher on the host's PC: what the guild's Discord bot hands to the game.\n## Author: Casual Disaster\n## Version: 1\n\nInbox.lua\n",
        interface_of(&addons)
    );
    write_atomic(&dir.join(format!("{FOLDER}.toc")), &toc)?;
    write_atomic(&dir.join("Inbox.lua"), &inbox_lua(records, written))
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

/// Ids the addon has taken (DisasterZoneBridgeDB.applied) in the newest SavedVariables under a game folder.
pub fn applied_ids(flavor_dir: &Path) -> BTreeSet<String> {
    let Ok(accounts) = fs::read_dir(flavor_dir.join("WTF").join("Account")) else { return BTreeSet::new() };
    let newest = accounts
        .flatten()
        .map(|a| a.path().join("SavedVariables").join("DisasterZone.lua"))
        .filter_map(|p| Some((fs::metadata(&p).ok()?.modified().ok()?, p)))
        .max();
    let Some((_, path)) = newest else { return BTreeSet::new() };
    let text = fs::read(&path).map(|d| String::from_utf8_lossy(&d).into_owned()).unwrap_or_default();
    read_global(&text, SV_NAME)
        .and_then(|v| v.get("applied").and_then(|a| a.as_object()).map(|a| a.keys().cloned().collect()))
        .unwrap_or_default()
}

/// Drop what the game took, rewrite the inbox. Returns the records still waiting.
pub fn sync_at(queue: &Path, flavor_dir: &Path, now: u64) -> Result<Vec<Record>> {
    let mut q = load_queue_at(queue);
    let taken = applied_ids(flavor_dir);
    let before = q.len();
    q.retain(|r| !taken.contains(&r.id));
    if q.len() != before {
        save_queue_at(queue, &q)?;
    }
    write_inbox(flavor_dir, &q, now)?;
    Ok(q)
}

pub fn sync(flavor_dir: &Path, now: u64) -> Result<Vec<Record>> {
    sync_at(&queue_path(), flavor_dir, now)
}

pub fn push_at(queue: &Path, flavor_dir: &Path, r: Record, now: u64) -> Result<Vec<Record>> {
    let mut q = load_queue_at(queue);
    q.push(r);
    save_queue_at(queue, &q)?;
    sync_at(queue, flavor_dir, now)
}

pub fn push(flavor_dir: &Path, r: Record, now: u64) -> Result<Vec<Record>> {
    push_at(&queue_path(), flavor_dir, r, now)
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
        Record { id: id.into(), kind: "test".into(), at: 1, by: "Tsumi".into(), body: json!({ "text": text }) }
    }

    #[test]
    fn inbox_round_trips_through_the_reader() {
        let lua = inbox_lua(&[rec("dc_1", "hi \"there\" | \\ \n")], 7);
        let v = read_global(&lua, "DZBridgeInbox").unwrap();
        assert_eq!(v["written"], json!(7));
        assert_eq!(v["records"]["1"]["id"], json!("dc_1"));
        assert_eq!(v["records"]["1"]["body"]["text"], json!("hi \"there\" | \\ \n"));
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
        let q = sync_at(&queue, &flavor, 12).unwrap();
        assert_eq!(q.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), vec!["dc_9"]);
        assert_eq!(load_queue_at(&queue).len(), 1);
        let inbox = fs::read_to_string(flavor.join("Interface/AddOns/DisasterZone_Bridge/Inbox.lua")).unwrap();
        assert!(!inbox.contains("dc_1") && inbox.contains("dc_9"));
    }
}
