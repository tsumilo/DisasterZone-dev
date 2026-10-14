//! The bot's own files (in the data folder) and the signed queue of changes made in Discord.
//!
//!   bridge_queue.json     records the game has not taken yet (each signed when it is made: dz_proto::Record)
//!   bridge_profiles.json  the characters each Discord user made in Discord
//!   bridge_channels.json  the server's text channels (for the addon's Settings > Discord dropdowns)
//!   bridge_key.json(+.leaves)  the signing key (dz-server keygen)
//!
//! A record leaves the queue once any member's game marked it applied (DisasterZoneBridgeDB.applied, uploaded by
//! their launcher after the save).

use crate::core::error::Result;
use dz_proto::wots::Signer;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub use dz_proto::{Channel, Record};

static SIGNER: Mutex<Option<Signer>> = Mutex::new(None);
/// (one writer of the queue at a time: answers run on their own tasks)
static QUEUE_LOCK: Mutex<()> = Mutex::new(());

pub fn set_signer(s: Signer) {
    *SIGNER.lock().unwrap() = Some(s);
}

/// Signatures the key has left (None: no key loaded).
pub fn signatures_left() -> Option<u64> {
    SIGNER.lock().unwrap().as_ref().map(|s| s.left())
}

pub fn path(name: &str) -> PathBuf {
    crate::data_dir().join(name)
}

// ------------------------------------------------------------------------------------------------------------------
// Profiles: the characters each Discord user made in Discord (name, class, spec). No proof is asked; one name
// belongs to one Discord user.
// ------------------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Char {
    /// as the game writes it: "Lee" or "Lee-Thunderstrike"
    pub name: String,
    /// class file: "WARRIOR"
    pub class: String,
    /// 1-based index into the class's specs (addon ns.SPECS)
    pub spec: u32,
    /// the Discord name of whoever made it (the addon shows a badge after the character's name)
    #[serde(default)]
    pub by: String,
}

/// Discord user id -> their characters (the first is their main)
pub type Profiles = std::collections::BTreeMap<String, Vec<Char>>;

pub fn load_profiles_at(p: &Path) -> Profiles {
    fs::read(p).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

pub fn load_profiles() -> Profiles {
    load_profiles_at(&path("bridge_profiles.json"))
}

/// Save the characters made in Discord; the game's badges follow (a new signed "links" record).
pub fn save_profiles(p: &Profiles) -> Result<()> {
    save_json(&path("bridge_profiles.json"), p)?;
    push_links(p)
}

/// The badges as a signed record { rev, l = { [character] = Discord name } } (addon Core/Bridge.lua "links"); an
/// older one still waiting is dropped. Nothing when they are the ones last sent (bridge_links.json keeps their hash).
pub fn push_links(p: &Profiles) -> Result<()> {
    let l: serde_json::Map<String, Value> = links(p).into_iter().map(|k| (k.name, Value::String(k.discord))).collect();
    let hash = hex::encode(<sha2::Sha256 as sha2::Digest>::digest(serde_json::to_vec(&l).unwrap_or_default()));
    let state = path("bridge_links.json");
    let last: Value = fs::read(&state).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or(Value::Null);
    if last.get("hash").and_then(|h| h.as_str()) == Some(hash.as_str()) {
        return Ok(());
    }
    let now = crate::bot::unix_now();
    // (a rev above the last one even if the clock stepped back: the game keeps the higher)
    let rev = now.max(last.get("rev").and_then(|r| r.as_u64()).unwrap_or(0) + 1);
    {
        let _g = QUEUE_LOCK.lock().unwrap();
        let q = path("bridge_queue.json");
        let mut all = load_queue_at(&q);
        let before = all.len();
        all.retain(|r| r.kind != "links");
        if all.len() != before {
            save_json(&q, &all)?;
        }
    }
    push(Record {
        id: format!("ln_{rev}"),
        kind: "links".into(),
        at: now,
        by: "DisasterZone".into(),
        body: serde_json::json!({ "rev": rev, "l": l }),
        discord: String::new(),
        sig: String::new(),
    })?;
    save_json(&state, &serde_json::json!({ "hash": hash, "rev": rev }))
}

/// The characters made in Discord, for the addon's badges.
pub fn links(p: &Profiles) -> Vec<dz_proto::Link> {
    p.values()
        .flatten()
        .map(|c| dz_proto::Link { name: c.name.clone(), discord: if c.by.is_empty() { "Discord".into() } else { c.by.clone() } })
        .collect()
}

fn short_lower(name: &str) -> String {
    name.split('-').next().unwrap_or(name).to_lowercase()
}

/// Who has this character already (another user's claim on "Lee" is refused).
pub fn owner_of(p: &Profiles, name: &str) -> Option<String> {
    let want = short_lower(name);
    p.iter().find(|(_, chars)| chars.iter().any(|c| short_lower(&c.name) == want)).map(|(u, _)| u.clone())
}

/// A name as WoW writes it: first letter upper, the rest lower ("lEE" -> "Lee"); a realm after '-' is kept as typed.
pub fn tidy_name(name: &str) -> String {
    let name = name.trim();
    let (n, realm) = match name.split_once('-') {
        Some((n, r)) => (n, Some(r)),
        None => (name, None),
    };
    let mut out: String = n.chars().take(1).flat_map(|c| c.to_uppercase()).collect();
    out.extend(n.chars().skip(1).flat_map(|c| c.to_lowercase()));
    if let Some(r) = realm.filter(|r| !r.is_empty()) {
        out.push('-');
        out.push_str(r);
    }
    out
}

// ------------------------------------------------------------------------------------------------------------------
// Files
// ------------------------------------------------------------------------------------------------------------------

pub fn save_json<T: Serialize + ?Sized>(p: &Path, v: &T) -> Result<()> {
    fs::create_dir_all(p.parent().unwrap())?;
    let tmp = p.with_extension("tmp");
    fs::write(&tmp, serde_json::to_vec_pretty(v).unwrap())?;
    fs::rename(&tmp, p)?;
    Ok(())
}

pub fn load_channels() -> Vec<Channel> {
    fs::read(path("bridge_channels.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

pub fn save_channels(c: &[Channel]) -> Result<()> {
    save_json(&path("bridge_channels.json"), c)
}

/// A Lua array as the launcher uploads it (an object with keys "1", "2", ...) in order; any other value: empty.
pub fn lua_list(v: Option<&Value>) -> Vec<&Value> {
    let Some(Value::Object(m)) = v else { return Vec::new() };
    let mut out: Vec<(usize, &Value)> = m.iter().filter_map(|(k, x)| Some((k.parse().ok()?, x))).collect();
    out.sort_by_key(|(i, _)| *i);
    out.into_iter().map(|(_, x)| x).collect()
}

// ------------------------------------------------------------------------------------------------------------------
// The queue
// ------------------------------------------------------------------------------------------------------------------

pub fn load_queue_at(p: &Path) -> Vec<Record> {
    fs::read(p).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

pub fn load_queue() -> Vec<Record> {
    load_queue_at(&path("bridge_queue.json"))
}

/// Sign a record and queue it for the game. Returns the records now waiting.
pub fn push(mut r: Record) -> Result<Vec<Record>> {
    let message = r.message().map_err(|e| crate::core::Error::Msg(e.to_string()))?;
    {
        let mut g = SIGNER.lock().unwrap();
        let s = g.as_mut().ok_or_else(|| crate::core::Error::Msg("the bot has no signing key (dz-server keygen)".into()))?;
        r.sig = hex::encode(s.sign(&message).map_err(|e| crate::core::Error::Msg(e.to_string()))?);
    }
    let _g = QUEUE_LOCK.lock().unwrap();
    let p = path("bridge_queue.json");
    let mut q = load_queue_at(&p);
    // (a record nobody could take in two weeks - a guest when no raid leader syncs - is dropped)
    let cut = r.at.saturating_sub(MAX_AGE);
    q.retain(|x| x.at >= cut);
    q.push(r);
    save_json(&p, &q)?;
    Ok(q)
}

/// How long a record waits for a game to take it.
const MAX_AGE: u64 = 14 * 86400;

/// A member's game took these records (DisasterZoneBridgeDB.applied: { [id] = { ok, why } }): they leave the queue.
/// Returns the ones it refused, with why (told to whoever made them).
pub fn take_applied(applied: Option<&Value>) -> Result<Vec<(Record, String)>> {
    let Some(Value::Object(applied)) = applied else { return Ok(Vec::new()) };
    let _g = QUEUE_LOCK.lock().unwrap();
    let p = path("bridge_queue.json");
    let all = load_queue_at(&p);
    let before = all.len();
    let (mut keep, mut failed) = (Vec::new(), Vec::new());
    for r in all {
        match applied.get(&r.id) {
            None => keep.push(r),
            Some(m) => {
                if m.get("ok").and_then(|x| x.as_bool()) != Some(true) {
                    let why = m.get("why").and_then(|x| x.as_str()).unwrap_or("refused").to_string();
                    failed.push((r, why));
                }
            }
        }
    }
    if keep.len() != before {
        save_json(&p, &keep)?;
    }
    Ok(failed)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::json;

    /// A data folder of its own and a small signing key, for tests that touch the bot's files (one at a time: the
    /// data folder is global).
    pub fn scratch() -> (tempfile::TempDir, std::sync::MutexGuard<'static, ()>) {
        static ONE: Mutex<()> = Mutex::new(());
        let g = ONE.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        crate::set_data_dir(dir.path().to_path_buf());
        set_signer(Signer::create(&dir.path().join("bridge_key.json"), 3, &[5u8; 48]).unwrap());
        (dir, g)
    }

    fn rec(id: &str) -> Record {
        Record { id: id.into(), kind: "test".into(), at: 1, by: "Tsumi".into(), body: json!({ "text": "x" }), discord: "42".into(), sig: String::new() }
    }

    #[test]
    fn records_are_signed_and_leave_when_taken() {
        let (_d, _g) = scratch();
        push(rec("dc_1")).unwrap();
        let q = push(rec("dc_2")).unwrap();
        assert_eq!(q.len(), 2);
        let pk = SIGNER.lock().unwrap().as_ref().unwrap().public();
        for r in &q {
            assert!(dz_proto::wots::verify(&pk, &r.message().unwrap(), &hex::decode(&r.sig).unwrap()));
        }
        let failed = take_applied(Some(&json!({ "dc_1": { "ok": true }, "dc_2": { "ok": false, "why": "over" }, "old": { "ok": true } }))).unwrap();
        assert!(load_queue().is_empty());
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0].1, "over");
        assert_eq!(failed[0].0.discord, "42");
    }

    #[test]
    fn badges_go_out_signed_once_per_change() {
        let (_d, _g) = scratch();
        let mut p = Profiles::new();
        p.insert("1".into(), vec![Char { name: "Lee".into(), class: "WARRIOR".into(), spec: 3, by: "LeeD".into() }]);
        save_profiles(&p).unwrap();
        save_profiles(&p).unwrap(); // (unchanged: no second record)
        let q = load_queue();
        assert_eq!(q.len(), 1);
        assert_eq!(q[0].kind, "links");
        assert_eq!(q[0].body["l"]["Lee"], json!("LeeD"));
        p.get_mut("1").unwrap().push(Char { name: "Ann".into(), class: "MAGE".into(), spec: 1, by: "LeeD".into() });
        save_profiles(&p).unwrap();
        let q = load_queue();
        assert_eq!(q.len(), 1); // (the older list is replaced)
        assert!(q[0].body["l"].get("Ann").is_some());
        assert!(q[0].body["rev"].as_u64().unwrap() > 0);
    }

    #[test]
    fn old_records_expire() {
        let (_d, _g) = scratch();
        push(Record { at: 1000, ..rec("old") }).unwrap();
        let q = push(Record { at: 1000 + MAX_AGE + 1, ..rec("new") }).unwrap();
        assert_eq!(q.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), vec!["new"]);
    }

    #[test]
    fn one_name_one_owner() {
        let mut p = Profiles::new();
        p.insert("1".into(), vec![Char { name: "Lee".into(), class: "WARRIOR".into(), spec: 3, by: String::new() }]);
        assert_eq!(owner_of(&p, "lee").as_deref(), Some("1"));
        assert_eq!(owner_of(&p, "LEE-Thunderstrike").as_deref(), Some("1"));
        assert_eq!(owner_of(&p, "Rita"), None);
        assert_eq!(links(&p)[0].discord, "Discord");
    }

    #[test]
    fn names_are_tidied_as_the_game_writes_them() {
        assert_eq!(tidy_name(" lEE "), "Lee");
        assert_eq!(tidy_name("élise-Thunderstrike"), "Élise-Thunderstrike");
        assert_eq!(tidy_name("bob-"), "Bob");
    }
}
