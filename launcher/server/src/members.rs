//! Member keys: what a launcher shows to sync. /launcher in Discord gives a one-time code (15 minutes); the launcher
//! trades it for a key (POST /api/link). The server keeps only each key's SHA-256 (members.json), with the Discord user
//! it belongs to; a user has at most MAX_KEYS (one per PC), the oldest goes when a new one is made.

use crate::bridge::{path, save_json};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::Mutex;

const CODE_LIFE: u64 = 15 * 60;
const MAX_KEYS: usize = 3;
/// (no 0/O, 1/I: read off a screen and typed)
const CODE_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Member {
    /// Discord user id
    pub user: String,
    /// their Discord name when the key was made
    pub name: String,
    pub made: u64,
    #[serde(default)]
    pub seen: u64,
}

struct Code {
    code: String,
    user: String,
    name: String,
    until: u64,
}

static CODES: Mutex<Vec<Code>> = Mutex::new(Vec::new());
static FILE: Mutex<()> = Mutex::new(());

fn random(n: usize) -> Vec<u8> {
    let mut b = vec![0u8; n];
    getrandom::fill(&mut b).expect("the OS has no random numbers");
    b
}

fn digest(key: &str) -> String {
    hex::encode(Sha256::digest(key.trim().as_bytes()))
}

fn load() -> BTreeMap<String, Member> {
    std::fs::read(path("members.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

/// A new one-time code for this Discord user (their older codes stop working).
pub fn new_code(user: &str, name: &str, now: u64) -> String {
    let code: String = random(8).iter().map(|b| CODE_ALPHABET[(*b as usize) % CODE_ALPHABET.len()] as char).collect();
    let mut codes = CODES.lock().unwrap();
    codes.retain(|c| c.user != user && c.until > now);
    codes.push(Code { code: code.clone(), user: user.to_string(), name: name.to_string(), until: now + CODE_LIFE });
    code
}

/// Trade a code for a key: (key, Discord name), or None when the code is unknown or too old.
pub fn redeem(code: &str, now: u64) -> Option<(String, String)> {
    let want: String = code.trim().to_uppercase().chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    let c = {
        let mut codes = CODES.lock().unwrap();
        let i = codes.iter().position(|c| c.code == want && c.until > now)?;
        codes.remove(i)
    };
    let key = hex::encode(random(32));
    let _g = FILE.lock().unwrap();
    let mut all = load();
    let mut theirs: Vec<(String, u64)> = all.iter().filter(|(_, m)| m.user == c.user).map(|(d, m)| (d.clone(), m.made)).collect();
    theirs.sort_by_key(|(_, made)| *made);
    while theirs.len() >= MAX_KEYS {
        all.remove(&theirs.remove(0).0);
    }
    all.insert(digest(&key), Member { user: c.user, name: c.name.clone(), made: now, seen: now });
    save_json(&path("members.json"), &all).ok()?;
    Some((key, c.name))
}

/// Whose key this is (and note when it was last used).
pub fn check(key: &str, now: u64) -> Option<Member> {
    let d = digest(key);
    let _g = FILE.lock().unwrap();
    let mut all = load();
    let m = all.get_mut(&d)?;
    let out = m.clone();
    // (seen is written at most every 10 minutes: one sync a minute per member is not a disk write each)
    if now >= m.seen + 600 {
        m.seen = now;
        let _ = save_json(&path("members.json"), &all);
    }
    Some(out)
}

/// Forget every key of a Discord user (their launchers stop syncing until they link again).
pub fn forget(user: &str) -> usize {
    let _g = FILE.lock().unwrap();
    let mut all = load();
    let before = all.len();
    all.retain(|_, m| m.user != user);
    let n = before - all.len();
    if n > 0 {
        let _ = save_json(&path("members.json"), &all);
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_become_keys_once() {
        let (_d, _g) = crate::bridge::tests::scratch();
        let code = new_code("42", "Tsumi", 100);
        assert_eq!(code.len(), 8);
        assert!(redeem("nope", 101).is_none());
        let (key, name) = redeem(&code.to_lowercase(), 101).unwrap();
        assert_eq!(name, "Tsumi");
        assert!(redeem(&code, 102).is_none()); // (once)
        assert_eq!(check(&key, 103).unwrap().user, "42");
        assert!(check("not-a-key", 103).is_none());
        assert_eq!(forget("42"), 1);
        assert!(check(&key, 104).is_none());
    }

    #[test]
    fn codes_run_out_and_old_keys_go() {
        let (_d, _g) = crate::bridge::tests::scratch();
        let code = new_code("42", "Tsumi", 100);
        assert!(redeem(&code, 100 + CODE_LIFE + 1).is_none());
        let keys: Vec<String> = (0..4).map(|i| redeem(&new_code("42", "Tsumi", 200 + i), 201 + i).unwrap().0).collect();
        assert!(check(&keys[0], 300).is_none()); // (the fourth PC pushed the first out)
        assert!(keys[1..].iter().all(|k| check(k, 300).is_some()));
    }
}
