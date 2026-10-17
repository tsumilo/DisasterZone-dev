//! What the window shows about the player, read from the game's own files under a game folder:
//!   the character played last   WTF/Account/<acct>/<realm>/<char>/ (the newest folder: the game writes it at logout),
//!                               its class and spec from DisasterZoneDB (layouts.seen, chars[key].data)
//!   the region                  WTF/Config.wtf  SET portal "EU"  (Hold the Line's weekly reset day)
//!   the guild's next raids      DisasterZoneBridgeDB.snap.raids (the addon's snapshot at logout, sign-ups resolved)
//! Everything is optional: a missing file or table leaves that part out.

use super::bridge::read_selected;
use serde::Serialize;
use serde_json::{Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// A raid stays on the card this long after it starts (the addon's own "current" window, Dashboard.lua).
pub const RAID_CURRENT_FOR: i64 = 6 * 3600;

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Character {
    pub name: String,
    pub realm: String,
    /// "Name-Realm" as the addon writes it (the realm without spaces)
    pub key: String,
    /// "PALADIN", ...
    pub class: Option<String>,
    /// "Retribution", ... (the spec of the character's BiS list)
    pub spec: Option<String>,
    /// when the game last wrote the character's folder (unix time)
    pub at: i64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Player {
    pub character: Option<Character>,
    /// "EU", "US", "KR", "TW", "CN"
    pub region: Option<String>,
    /// every character of this account the addon has seen, as "Name-Realm" (finding my sign-ups)
    pub mine: Vec<String>,
    /// the snapshot's raids still to come or under way, soonest first, each as the addon wrote it with its lists
    /// (signups, teams) turned into arrays
    pub raids: Vec<Value>,
    /// when the game wrote that snapshot; none when it never did (the addon writes it at logout)
    pub snap_at: Option<i64>,
}

fn unix(t: SystemTime) -> i64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn dirs(p: &Path) -> Vec<PathBuf> {
    fs::read_dir(p).map(|r| r.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect()).unwrap_or_default()
}

/// The newest write inside a character folder (its own entries, one level down).
fn written(dir: &Path) -> Option<SystemTime> {
    let own = fs::metadata(dir).and_then(|m| m.modified()).ok();
    let inner = fs::read_dir(dir)
        .ok()?
        .flatten()
        .filter_map(|e| e.metadata().ok()?.modified().ok())
        .max();
    own.into_iter().chain(inner).max()
}

/// (account folder, realm, character, when) of the character played last.
fn last_played(flavor_dir: &Path) -> Option<(PathBuf, String, String, SystemTime)> {
    let mut best: Option<(PathBuf, String, String, SystemTime)> = None;
    for acct in dirs(&flavor_dir.join("WTF").join("Account")) {
        for realm in dirs(&acct) {
            let realm_name = realm.file_name()?.to_string_lossy().to_string();
            if realm_name == "SavedVariables" {
                continue;
            }
            for ch in dirs(&realm) {
                let Some(t) = written(&ch) else { continue };
                if best.as_ref().map_or(true, |b| t > b.3) {
                    best = Some((acct.clone(), realm_name.clone(), ch.file_name()?.to_string_lossy().to_string(), t));
                }
            }
        }
    }
    best
}

/// Config.wtf's portal: SET portal "EU".
pub fn region(flavor_dir: &Path) -> Option<String> {
    let text = fs::read(flavor_dir.join("WTF").join("Config.wtf")).ok()?;
    let text = String::from_utf8_lossy(&text);
    for line in text.lines() {
        let mut parts = line.trim().splitn(3, ' ');
        if parts.next() == Some("SET") && parts.next().map(|k| k.eq_ignore_ascii_case("portal")) == Some(true) {
            let v = parts.next()?.trim().trim_matches('"').trim();
            return (!v.is_empty()).then(|| v.to_uppercase());
        }
    }
    None
}

/// A Lua array the reader turned into {"1": .., "2": ..}: back into a list, in order.
fn list(v: Option<&Value>) -> Vec<Value> {
    match v {
        Some(Value::Object(m)) => {
            let mut items: Vec<(usize, Value)> =
                m.iter().filter_map(|(k, v)| Some((k.parse::<usize>().ok()?, v.clone()))).collect();
            items.sort_by_key(|(i, _)| *i);
            items.into_iter().map(|(_, v)| v).collect()
        }
        Some(Value::Array(a)) => a.clone(),
        _ => vec![],
    }
}

fn num(v: Option<&Value>) -> Option<i64> {
    v.and_then(|x| x.as_i64().or_else(|| x.as_f64().map(|f| f as i64)))
}

fn text(v: Option<&Value>) -> Option<String> {
    v.and_then(Value::as_str).map(str::to_string).filter(|s| !s.is_empty())
}

/// The snapshot's raids still to come (or started less than RAID_CURRENT_FOR ago), not cancelled, soonest first.
pub fn upcoming_raids(snap: &Value, now: i64) -> Vec<Value> {
    let mut out: Vec<Value> = list(snap.get("raids"))
        .into_iter()
        .filter_map(|r| {
            let mut m: Map<String, Value> = r.as_object()?.clone();
            let t = num(m.get("t"))?;
            if t + RAID_CURRENT_FOR < now || m.get("cancelled").and_then(Value::as_bool) == Some(true) {
                return None;
            }
            let signups = list(m.get("signups"));
            m.insert("signups".into(), Value::Array(signups));
            let teams = list(m.get("teams"));
            m.insert("teams".into(), Value::Array(teams));
            Some(Value::Object(m))
        })
        .collect();
    out.sort_by_key(|r| num(r.get("t")).unwrap_or(0));
    out
}

/// Everything above, for the game folder `flavor_dir` at time `now`.
pub fn read(flavor_dir: &Path, now: i64) -> Player {
    let mut p = Player { region: region(flavor_dir), ..Default::default() };
    let last = last_played(flavor_dir);
    // the SavedVariables of the last character's account (else the newest one)
    let sv_path = last
        .as_ref()
        .map(|(acct, ..)| acct.join("SavedVariables").join("DisasterZone.lua"))
        .filter(|p| p.is_file())
        .or_else(|| super::bridge::newest_saved_variables_path(flavor_dir));
    let sv = sv_path.and_then(|p| fs::read(p).ok()).map(|d| String::from_utf8_lossy(&d).into_owned()).unwrap_or_default();

    let seen = read_selected(&sv, "DisasterZoneDB", &["layouts", "seen", "*", "c"]);
    let seen = seen.as_ref().and_then(|d| d.get("layouts")).and_then(|l| l.get("seen")).and_then(Value::as_object);
    if let Some(seen) = seen {
        p.mine = seen.keys().cloned().collect();
    }
    let snap_me = read_selected(&sv, "DisasterZoneBridgeDB", &["snap", "me"]);
    let snap_me = text(snap_me.as_ref().and_then(|b| b.get("snap")).and_then(|s| s.get("me")));
    if let Some(me) = &snap_me {
        if !p.mine.contains(me) {
            p.mine.push(me.clone());
        }
    }

    if let Some((_, realm, name, t)) = last {
        let key = format!("{}-{}", name, realm.replace(' ', ""));
        let data = read_selected(&sv, "DisasterZoneDB", &["chars", key.as_str(), "data", "*"]);
        let data = data.as_ref().and_then(|d| d.get("chars")).and_then(|c| c.get(&key)).and_then(|c| c.get("data"));
        let class = text(seen.and_then(|s| s.get(&key)).and_then(|c| c.get("c"))).or_else(|| text(data.and_then(|d| d.get("cl"))));
        p.character = Some(Character { spec: text(data.and_then(|d| d.get("sp"))), class, name, realm, key, at: unix(t) });
    }

    // the raids: the addon's record for launchers (every PC) or the Discord snapshot (linked PCs), the newer one
    if let Some((at, raids)) = newest_raids(&sv) {
        p.raids = upcoming_raids(&serde_json::json!({ "raids": raids }), now);
        p.snap_at = Some(at);
    }
    p
}

/// (when, raids) of `global`.`table` = { at, me, raids }.
fn raid_source(sv: &str, global: &str, table: &str) -> Option<(i64, Value)> {
    let get = |key: &str| read_selected(sv, global, &[table, key]).and_then(|v| v.get(table)?.get(key).cloned());
    let at = num(get("at").as_ref())?;
    Some((at, get("raids").unwrap_or(Value::Null)))
}

/// The raids from DisasterZoneDB.launcher (written at every logout, Bridge.lua LauncherHome) or from
/// DisasterZoneBridgeDB.snap (the Discord snapshot, only where a launcher is linked), whichever was written last.
fn newest_raids(sv: &str) -> Option<(i64, Value)> {
    match (raid_source(sv, "DisasterZoneDB", "launcher"), raid_source(sv, "DisasterZoneBridgeDB", "snap")) {
        (Some(h), Some(s)) => Some(if s.0 > h.0 { s } else { h }),
        (h, s) => h.or(s),
    }
}

pub fn now() -> i64 {
    unix(SystemTime::now())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    const NOW: i64 = 1_792_300_000;

    const SV: &str = r#"
DisasterZoneDB = {
	["layouts"] = {
		["seen"] = {
			["Tsumil-LivingFlame"] = {
				["c"] = "PALADIN",
			},
			["Ussyp-LivingFlame"] = {
				["c"] = "ROGUE",
			},
		},
	},
	["chars"] = {
		["Tsumil-LivingFlame"] = {
			["rev"] = 4,
			["data"] = {
				["cl"] = "PALADIN",
				["sp"] = "Retribution",
				["ph"] = { { 1, 2, }, },
			},
		},
	},
}
DisasterZoneBridgeDB = {
	["snap"] = {
		["at"] = 1792290000,
		["me"] = "Tsumil-LivingFlame",
		["raids"] = {
			{
				["id"] = "later",
				["t"] = 1792500000,
				["name"] = "Black Temple",
				["inst"] = "bt",
				["size"] = 25,
			}, -- [1]
			{
				["id"] = "old",
				["t"] = 1792200000,
				["name"] = "Karazhan",
			}, -- [2]
			{
				["id"] = "next",
				["t"] = 1792310000,
				["name"] = "Serpentshrine Cavern",
				["inst"] = "ssc",
				["size"] = 25,
				["teams"] = { "t1", },
				["need"] = { ["tank"] = 3, ["heal"] = 6, ["dps"] = 16, },
				["signups"] = {
					{ ["key"] = "Tsumil-LivingFlame", ["st"] = "accept", ["class"] = "PALADIN", ["spec"] = "Retribution", ["role"] = "melee", },
					{ ["key"] = "Lee-LivingFlame", ["st"] = "tentative", ["class"] = "DRUID", ["role"] = "tank", },
				},
			}, -- [3]
			{
				["id"] = "off",
				["t"] = 1792320000,
				["name"] = "Mount Hyjal",
				["cancelled"] = true,
			}, -- [4]
		},
	},
}
"#;

    fn touch(p: &Path, t: i64) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, "x").unwrap();
        let f = fs::File::options().write(true).open(p).unwrap();
        f.set_modified(UNIX_EPOCH + Duration::from_secs(t as u64)).unwrap();
    }

    fn game(dir: &Path) {
        let wtf = dir.join("WTF");
        fs::create_dir_all(&wtf).unwrap();
        fs::write(wtf.join("Config.wtf"), "SET locale \"enGB\"\nSET portal \"EU\"\nSET gxApi \"D3D11\"\n").unwrap();
        let acct = wtf.join("Account").join("1234#1");
        fs::create_dir_all(acct.join("SavedVariables")).unwrap();
        fs::write(acct.join("SavedVariables").join("DisasterZone.lua"), SV).unwrap();
        touch(&acct.join("Living Flame").join("Ussyp").join("cache.md5"), NOW - 9000);
        touch(&acct.join("Living Flame").join("Tsumil").join("cache.md5"), NOW - 3000);
    }

    #[test]
    fn the_last_character_with_its_class_and_spec() {
        let dir = tempfile::tempdir().unwrap();
        game(dir.path());
        let p = read(dir.path(), NOW);
        let c = p.character.unwrap();
        assert_eq!(c.name, "Tsumil");
        assert_eq!(c.key, "Tsumil-LivingFlame");
        assert_eq!(c.class.as_deref(), Some("PALADIN"));
        assert_eq!(c.spec.as_deref(), Some("Retribution"));
        assert_eq!(p.region.as_deref(), Some("EU"));
        assert!(p.mine.contains(&"Ussyp-LivingFlame".to_string()));
    }

    #[test]
    fn raids_to_come_soonest_first_with_lists() {
        let dir = tempfile::tempdir().unwrap();
        game(dir.path());
        let p = read(dir.path(), NOW);
        let ids: Vec<&str> = p.raids.iter().map(|r| r["id"].as_str().unwrap()).collect();
        // (old started 27 h ago: gone; the cancelled one: gone)
        assert_eq!(ids, ["next", "later"]);
        let next = &p.raids[0];
        assert_eq!(next["signups"].as_array().unwrap().len(), 2);
        assert_eq!(next["signups"][0]["key"], "Tsumil-LivingFlame");
        assert_eq!(next["teams"], serde_json::json!(["t1"]));
        assert_eq!(next["need"]["heal"], 6);
        assert_eq!(p.snap_at, Some(1_792_290_000));
    }

    #[test]
    fn a_raid_under_way_stays_for_six_hours() {
        let snap = serde_json::json!({"raids": {"1": {"id": "now", "t": NOW - 2 * 3600}, "2": {"id": "done", "t": NOW - 7 * 3600}}});
        let ids: Vec<Value> = upcoming_raids(&snap, NOW).iter().map(|r| r["id"].clone()).collect();
        assert_eq!(ids, [serde_json::json!("now")]);
    }

    #[test]
    fn the_launcher_record_or_the_snapshot_whichever_is_newer() {
        let both = |home_at: i64, snap_at: i64| {
            format!(
                "DisasterZoneDB = {{\n[\"launcher\"] = {{ [\"at\"] = {home_at}, [\"raids\"] = {{ {{ [\"id\"] = \"home\", [\"t\"] = 5, }}, }}, }},\n}}\n\
                 DisasterZoneBridgeDB = {{\n[\"snap\"] = {{ [\"at\"] = {snap_at}, [\"raids\"] = {{ {{ [\"id\"] = \"snap\", [\"t\"] = 5, }}, }}, }},\n}}\n"
            )
        };
        let first = |sv: &str| newest_raids(sv).map(|(at, r)| (at, list(Some(&r))[0]["id"].as_str().unwrap().to_string()));
        assert_eq!(first(&both(200, 100)), Some((200, "home".into())));
        assert_eq!(first(&both(100, 200)), Some((200, "snap".into())));
        // (an addon from before the launcher record: the snapshot alone)
        assert_eq!(first(&both(0, 200).replace("[\"launcher\"]", "[\"other\"]")), Some((200, "snap".into())));
        assert_eq!(newest_raids("DisasterZoneDB = {\n}\n"), None);
    }

    /// DZ_GAME=<game folder> cargo test real_game_folder -- --ignored --nocapture: what it reads from a real install.
    #[test]
    #[ignore]
    fn real_game_folder() {
        let dir = std::env::var("DZ_GAME").expect("set DZ_GAME");
        let t = std::time::Instant::now();
        let p = read(Path::new(&dir), now());
        println!("{:?} in {:?}", p.character, t.elapsed());
        println!("region {:?} · mine {:?} · snap at {:?} · {} raids", p.region, p.mine, p.snap_at, p.raids.len());
        for r in &p.raids {
            println!("  {} {} {} signups", r["t"], r["name"], r["signups"].as_array().map_or(0, |a| a.len()));
        }
    }

    #[test]
    fn nothing_there_is_nothing_shown() {
        let dir = tempfile::tempdir().unwrap();
        let p = read(dir.path(), NOW);
        assert!(p.character.is_none() && p.region.is_none() && p.raids.is_empty() && p.snap_at.is_none());
    }
}
