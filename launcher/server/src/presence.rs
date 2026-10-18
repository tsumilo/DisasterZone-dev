//! Who is in game: each linked launcher says at every sync whether World of Warcraft runs on its PC, and as whom
//! (dz_proto::GameNow). A launcher syncs every two minutes while the game runs and once more when it is closed (the
//! game saves), so a report older than STALE means the PC went quiet: no longer in game. Kept per Discord user (one person
//! with two PCs is one row: the PC in game wins) in presence.json, so a restart keeps "last seen".

use crate::bridge::{path, save_json};
use dz_proto::{GameNow, Presence, PresenceDown};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Mutex;

/// No report for this long while in game: the PC went off or lost its connection.
pub const STALE: u64 = 5 * 60;
/// Who hasn't been in game for this long is left out of the list.
const FORGET: u64 = 30 * 24 * 3600;

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
struct Entry {
    name: String,
    #[serde(default)]
    character: Option<String>,
    #[serde(default)]
    class: Option<String>,
    #[serde(default)]
    spec: Option<String>,
    /// in game since (0: not in game at the last report)
    #[serde(default)]
    since: u64,
    /// the last report saying the game runs
    #[serde(default)]
    seen: u64,
    /// the last report at all
    #[serde(default)]
    heard: u64,
}

static STATE: Mutex<Option<BTreeMap<String, Entry>>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut BTreeMap<String, Entry>) -> R) -> R {
    let mut g = STATE.lock().unwrap();
    let all = g.get_or_insert_with(|| {
        std::fs::read(path("presence.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    });
    f(all)
}

/// A launcher's report (`hidden`: its member doesn't share it, they leave the list).
pub fn report(user: &str, name: &str, game: &GameNow, now: u64) {
    with(|all| {
        let before = all.get(user).cloned();
        match game {
            g if g.hidden => {
                all.remove(user);
            }
            g => {
                let e = all.entry(user.to_string()).or_default();
                e.name = name.to_string();
                if g.character.is_some() {
                    e.character = g.character.clone();
                    e.class = g.class.clone();
                    e.spec = g.spec.clone();
                }
                e.heard = now;
                if g.running {
                    if e.since == 0 || now > e.seen + STALE {
                        e.since = now;
                    }
                    e.seen = now;
                } else {
                    e.since = 0;
                }
            }
        }
        // (written when someone comes or goes, and at most every 10 minutes otherwise: not a disk write a minute)
        let after = all.get(user);
        let moved = before.as_ref().map(|b| b.since != 0) != after.map(|a| a.since != 0)
            || before.as_ref().map(|b| b.seen + 600 <= now).unwrap_or(true);
        if moved {
            let _ = save_json(&path("presence.json"), &*all);
        }
    })
}

/// The list for the launchers: in game first (longest first), then by last seen; a month away and they're gone.
pub fn list(now: u64) -> PresenceDown {
    let mut people: Vec<Presence> = with(|all| {
        all.values()
            .filter(|e| e.seen > 0 && now.saturating_sub(e.seen) < FORGET)
            .map(|e| {
                let in_game = e.since > 0 && now.saturating_sub(e.seen) <= STALE;
                Presence {
                    user: e.name.clone(),
                    character: e.character.clone(),
                    class: e.class.clone(),
                    spec: e.spec.clone(),
                    in_game,
                    since: if in_game { e.since } else { 0 },
                    seen: e.seen,
                }
            })
            .collect()
    });
    people.sort_by(|a, b| b.in_game.cmp(&a.in_game).then(a.since.cmp(&b.since)).then(b.seen.cmp(&a.seen)));
    PresenceDown { now, people }
}

#[cfg(test)]
pub(crate) fn reset() {
    *STATE.lock().unwrap() = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn game(running: bool) -> GameNow {
        GameNow {
            running,
            character: Some("Tsumil-Thunderstrike".into()),
            class: Some("PALADIN".into()),
            spec: Some("Retribution".into()),
            hidden: false,
        }
    }

    #[test]
    fn in_game_then_gone_then_quiet() {
        let (_d, _g) = crate::bridge::tests::scratch();
        reset();
        report("42", "Tsumi", &game(true), 1000);
        report("42", "Tsumi", &game(true), 1060);
        report("7", "Gina", &game(true), 1030);
        let l = list(1100);
        assert_eq!(l.people.iter().map(|p| (p.user.as_str(), p.in_game, p.since)).collect::<Vec<_>>(),
            vec![("Tsumi", true, 1000), ("Gina", true, 1030)]);
        assert_eq!(l.people[0].character.as_deref(), Some("Tsumil-Thunderstrike"));
        // the game closed (its save is sent at once): out of game, seen when it last ran
        report("42", "Tsumi", &game(false), 1200);
        // Gina's PC went quiet: no longer in game after STALE
        let l = list(1030 + STALE + 1);
        assert!(l.people.iter().all(|p| !p.in_game));
        assert_eq!(l.people.iter().find(|p| p.user == "Tsumi").unwrap().seen, 1060);
        // back after a while: a new "since"
        report("7", "Gina", &game(true), 5000);
        assert_eq!(list(5001).people[0].since, 5000);
        // kept across a restart
        reset();
        assert_eq!(list(5001).people.len(), 2);
    }

    #[test]
    fn sharing_off_leaves_the_list_and_a_month_away_too() {
        let (_d, _g) = crate::bridge::tests::scratch();
        reset();
        report("42", "Tsumi", &game(true), 1000);
        report("7", "Gina", &game(true), 1000);
        report("42", "Tsumi", &GameNow { hidden: true, ..game(true) }, 1010);
        assert_eq!(list(1020).people.iter().map(|p| p.user.as_str()).collect::<Vec<_>>(), vec!["Gina"]);
        assert!(list(1000 + FORGET + 1).people.is_empty());
        // a launcher that never saw the game running: not listed
        report("9", "Vex", &game(false), 1000);
        assert!(list(1001).people.iter().all(|p| p.user != "Vex"));
    }
}
