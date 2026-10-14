//! One picture of the guild from many members' snapshots (DisasterZoneBridgeDB.snap, written by each addon at
//! logout / reload, uploaded by its launcher). Snapshots arrive in any order and may be stale, so:
//!   - sign-ups: per raid and character, the higher `rev` wins (the addon's own sync rule);
//!   - BiS lists: per character, the higher list revision `r` wins;
//!   - everything else (raid times and titles, teams, roster, Discord settings, phase): the newest snapshot of a game
//!     that had been online long enough to sync with the guild (`up` >= FRESH_UP seconds);
//!   - a raid missing from such a snapshot, within the window it covers, was deleted.
//! Snapshots of another guild are refused (a member logging out on an alt elsewhere).
//! The result has the shape of one snapshot, so the bot reads it as before; merged.json keeps it across restarts.

use crate::bridge::lua_list;
use serde_json::{Map, Value};

/// Seconds a game must have been up before its snapshot counts for more than sign-ups and lists.
pub const FRESH_UP: i64 = 120;
/// The window a snapshot covers (addon Core/Bridge.lua SNAP_BACK / SNAP_AHEAD).
const BACK: i64 = 6 * 3600;
const AHEAD: i64 = 14 * 86400;

fn int(v: Option<&Value>) -> i64 {
    v.and_then(|x| x.as_i64().or_else(|| x.as_f64().map(|f| f as i64))).unwrap_or(0)
}

fn as_lua_list(items: Vec<Value>) -> Value {
    Value::Object(items.into_iter().enumerate().map(|(i, v)| ((i + 1).to_string(), v)).collect())
}

fn key_of(s: &Value) -> Option<String> {
    s.get("key").and_then(|k| k.as_str()).map(str::to_string)
}

/// Sign-ups of two versions of a raid: per character, the higher rev (then the later answer) wins.
fn merge_signups(a: Option<&Value>, b: Option<&Value>) -> Value {
    let mut by: Vec<(String, Value)> = Vec::new();
    for s in lua_list(a).into_iter().chain(lua_list(b)) {
        let Some(k) = key_of(s) else { continue };
        match by.iter_mut().find(|(x, _)| *x == k) {
            None => by.push((k, s.clone())),
            Some((_, cur)) => {
                let newer = (int(s.get("rev")), int(s.get("at"))) > (int(cur.get("rev")), int(cur.get("at")));
                if newer {
                    *cur = s.clone();
                }
            }
        }
    }
    let mut list: Vec<Value> = by.into_iter().map(|(_, v)| v).collect();
    list.sort_by_key(|s| int(s.get("at")));
    as_lua_list(list)
}

pub enum Outcome {
    Merged(Value),
    /// another guild's snapshot (the guild it is for)
    OtherGuild(String),
}

/// Fold one uploaded snapshot into the merged one. `guild`: the guild this bot serves (None = the first one seen).
pub fn merge(base: Option<&Value>, new: &Value, guild: Option<&str>) -> Outcome {
    let new_guild = new.get("guild").and_then(|g| g.as_str()).unwrap_or("");
    let want = guild.map(str::to_string).or_else(|| base.and_then(|b| b.get("guild")).and_then(|g| g.as_str()).map(str::to_string));
    if let Some(w) = want.filter(|w| !w.is_empty()) {
        if new_guild != w {
            return Outcome::OtherGuild(new_guild.to_string());
        }
    }
    let Some(base) = base.filter(|b| b.is_object()) else { return Outcome::Merged(stamp_seen(new.clone())) };
    let fresh = int(new.get("up")) >= FRESH_UP || new.get("up").is_none();
    let new_at = int(new.get("at"));
    // (the fields one snapshot owns: from the newest fresh one)
    let lead_at = int(base.get("lead"));
    let new_leads = fresh && new_at >= lead_at;
    let mut out: Map<String, Value> = if new_leads { new.as_object().cloned().unwrap_or_default() } else { base.as_object().cloned().unwrap_or_default() };
    out.insert("lead".into(), Value::from(if new_leads { new_at } else { lead_at }));
    out.insert("at".into(), Value::from(new_at.max(int(base.get("at")))));
    out.remove("up");

    // item names: everything either one knows
    let mut items = base.get("items").and_then(|x| x.as_object()).cloned().unwrap_or_default();
    for (k, v) in new.get("items").and_then(|x| x.as_object()).cloned().unwrap_or_default() {
        items.insert(k, v);
    }
    out.insert("items".into(), Value::Object(items));

    // BiS lists: the higher revision per character
    let mut bis = base.get("bis").and_then(|x| x.as_object()).cloned().unwrap_or_default();
    for (k, v) in new.get("bis").and_then(|x| x.as_object()).cloned().unwrap_or_default() {
        let keep_old = bis.get(&k).is_some_and(|old| int(old.get("r")) > int(v.get("r")) || (int(old.get("r")) == int(v.get("r")) && !new_leads));
        if !keep_old {
            bis.insert(k, v);
        }
    }
    out.insert("bis".into(), Value::Object(bis));

    // raids
    let old_raids = lua_list(base.get("raids"));
    let new_raids = lua_list(new.get("raids"));
    let id = |r: &Value| r.get("id").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let mut raids: Vec<Value> = Vec::new();
    for o in &old_raids {
        let oid = id(o);
        match new_raids.iter().find(|n| id(n) == oid) {
            Some(n) => {
                let seen = int(o.get("seen"));
                let mut r = if fresh && new_at >= seen { (*n).clone() } else { (*o).clone() };
                if fresh && new_at >= seen {
                    r["seen"] = Value::from(new_at);
                }
                r["signups"] = merge_signups(o.get("signups"), n.get("signups"));
                raids.push(r);
            }
            None => {
                let t = int(o.get("t"));
                let covered = t >= new_at - BACK && t <= new_at + AHEAD;
                if !(fresh && covered && new_at >= int(o.get("seen"))) {
                    raids.push((*o).clone());
                }
            }
        }
    }
    for n in &new_raids {
        if !old_raids.iter().any(|o| id(o) == id(n)) {
            let mut r = (*n).clone();
            r["seen"] = Value::from(new_at);
            raids.push(r);
        }
    }
    // (raids long over drop out, as they do from a snapshot)
    let now = new_at.max(int(base.get("at")));
    raids.retain(|r| int(r.get("t")) >= now - BACK);
    raids.sort_by_key(|r| int(r.get("t")));
    out.insert("raids".into(), as_lua_list(raids));
    Outcome::Merged(Value::Object(out))
}

fn stamp_seen(mut v: Value) -> Value {
    let at = int(v.get("at"));
    if let Some(Value::Object(m)) = v.get_mut("raids") {
        for r in m.values_mut() {
            r["seen"] = Value::from(at);
        }
    }
    v["lead"] = Value::from(at);
    if let Some(m) = v.as_object_mut() {
        m.remove("up");
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn snap(at: i64, up: i64, raids: Value) -> Value {
        json!({ "at": at, "up": up, "guild": "CD-Realm", "phase": 2, "raids": raids, "bis": {}, "items": {} })
    }

    fn merged(o: Outcome) -> Value {
        match o {
            Outcome::Merged(v) => v,
            Outcome::OtherGuild(g) => panic!("refused as {g}"),
        }
    }

    #[test]
    fn signups_merge_by_rev_whatever_the_order() {
        let a = snap(1000, 600, json!({ "1": { "id": "r1", "t": 5000, "title": "Kara", "signups": {
            "1": { "key": "Lee-R", "st": "accept", "rev": 5, "at": 10 },
            "2": { "key": "Bob-R", "st": "tentative", "rev": 2, "at": 11 } } } }));
        // an older snapshot (stale for Lee, but it knows Bob's newer answer and Ann)
        let b = snap(900, 600, json!({ "1": { "id": "r1", "t": 5000, "title": "Old title", "signups": {
            "1": { "key": "Lee-R", "st": "absent", "rev": 4, "at": 10 },
            "2": { "key": "Bob-R", "st": "accept", "rev": 3, "at": 11 },
            "3": { "key": "Ann-R", "st": "accept", "rev": 1, "at": 12 } } } }));
        let m = merged(merge(Some(&merged(merge(None, &a, None))), &b, None));
        let r = lua_list(m.get("raids"))[0].clone();
        assert_eq!(r["title"], json!("Kara")); // (the newer snapshot's fields)
        let st: Vec<(String, String)> = lua_list(r.get("signups"))
            .iter()
            .map(|s| (s["key"].as_str().unwrap().into(), s["st"].as_str().unwrap().into()))
            .collect();
        assert_eq!(st, vec![("Lee-R".into(), "accept".into()), ("Bob-R".into(), "accept".into()), ("Ann-R".into(), "accept".into())]);
    }

    #[test]
    fn a_game_just_logged_in_only_adds_signups() {
        let a = snap(1000, 600, json!({ "1": { "id": "r1", "t": 5000, "title": "Kara", "signups": {} } }));
        // logged in a moment ago with week-old data: newer clock, but not fresh
        let b = snap(2000, 30, json!({ "1": { "id": "r1", "t": 5000, "title": "Week-old", "signups": {
            "1": { "key": "Ann-R", "st": "accept", "rev": 1, "at": 12 } } } }));
        let m = merged(merge(Some(&merged(merge(None, &a, None))), &b, None));
        let r = lua_list(m.get("raids"))[0].clone();
        assert_eq!(r["title"], json!("Kara"));
        assert_eq!(lua_list(r.get("signups")).len(), 1);
        assert_eq!(m["at"], json!(2000));
    }

    #[test]
    fn deleted_raids_go_and_new_ones_come() {
        let a = snap(1000, 600, json!({ "1": { "id": "r1", "t": 5000, "signups": {} }, "2": { "id": "far", "t": 9_000_000, "signups": {} } }));
        let b = snap(1100, 600, json!({ "1": { "id": "r2", "t": 6000, "signups": {} } }));
        let m = merged(merge(Some(&merged(merge(None, &a, None))), &b, None));
        let ids: Vec<&str> = lua_list(m.get("raids")).iter().map(|r| r["id"].as_str().unwrap()).collect();
        // r1 was deleted (in b's window, gone); "far" is past b's 14 days, so b says nothing about it
        assert_eq!(ids, vec!["r2", "far"]);
    }

    #[test]
    fn bis_lists_keep_the_higher_revision() {
        let mut a = snap(1000, 600, json!({}));
        a["bis"] = json!({ "Lee-R": { "r": 7, "spec": "Prot" } });
        let mut b = snap(1100, 600, json!({}));
        b["bis"] = json!({ "Lee-R": { "r": 6, "spec": "Arms" }, "Bob-R": { "r": 1 } });
        let m = merged(merge(Some(&merged(merge(None, &a, None))), &b, None));
        assert_eq!(m["bis"]["Lee-R"]["spec"], json!("Prot"));
        assert!(m["bis"].get("Bob-R").is_some());
    }

    #[test]
    fn other_guilds_are_refused() {
        let a = snap(1000, 600, json!({}));
        let mut b = snap(1100, 600, json!({}));
        b["guild"] = json!("Other-Realm");
        assert!(matches!(merge(Some(&merged(merge(None, &a, None))), &b, None), Outcome::OtherGuild(_)));
        assert!(matches!(merge(None, &b, Some("CD-Realm")), Outcome::OtherGuild(_)));
    }
}
