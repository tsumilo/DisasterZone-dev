//! Item search for /bis set (host mode): the names of the addon's raid loot, read once from its own data file
//! (Data/Items.lua lists every item as "28477, -- Harbinger Bands").

use std::sync::Mutex;

static ITEMS: Mutex<Option<Vec<(u32, String)>>> = Mutex::new(None);

/// (id, name) of every item in an Items.lua text, first mention wins.
pub fn parse(text: &str) -> Vec<(u32, String)> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for line in text.lines() {
        let Some((num, rest)) = line.trim().split_once(", --") else { continue };
        let Ok(id) = num.trim().parse::<u32>() else { continue };
        // (tags like "[supplement: LBIS]" after the name are dropped)
        let name = rest.split(" [").next().unwrap_or(rest).trim();
        // (token lists write "PALADIN: Crystalforge Shoulderguards": the class goes)
        let name = match name.split_once(": ") {
            Some((cls, n)) if !cls.is_empty() && cls.chars().all(|c| c.is_ascii_uppercase()) => n,
            _ => name,
        };
        if !name.is_empty() && seen.insert(id) {
            out.push((id, name.to_string()));
        }
    }
    out
}

fn all() -> Vec<(u32, String)> {
    let mut g = ITEMS.lock().unwrap();
    if g.is_none() {
        let list = crate::core::state::load()
            .flavor_dir()
            .map(|d| d.join("Interface/AddOns/DisasterZone/Data/Items.lua"))
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|t| parse(&t))
            .unwrap_or_default();
        if !list.is_empty() {
            *g = Some(list);
        } else {
            return Vec::new();
        }
    }
    g.clone().unwrap_or_default()
}

/// Up to 25 items whose name holds the query (names that start with it first).
pub fn search_in(list: &[(u32, String)], query: &str) -> Vec<(u32, String)> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return Vec::new();
    }
    let mut starts: Vec<_> = list.iter().filter(|(_, n)| n.to_lowercase().starts_with(&q)).cloned().collect();
    let more: Vec<_> = list.iter().filter(|(_, n)| { let l = n.to_lowercase(); !l.starts_with(&q) && l.contains(&q) }).cloned().collect();
    starts.extend(more);
    starts.truncate(25);
    starts
}

pub fn search(query: &str) -> Vec<(u32, String)> {
    search_in(&all(), query)
}

pub fn name_of(id: u32) -> Option<String> {
    all().into_iter().find(|(i, _)| *i == id).map(|(_, n)| n)
}

/// What the user typed or picked: an id (a picked choice) or an exact name.
pub fn resolve(value: &str) -> Option<u32> {
    if let Ok(id) = value.trim().parse::<u32>() {
        return Some(id);
    }
    let v = value.trim().to_lowercase();
    all().into_iter().find(|(_, n)| n.to_lowercase() == v).map(|(i, _)| i)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_addon_item_list() {
        let t = "    { key = \"x\", items = {\n        28477, -- Harbinger Bands\n        28507, -- Handwraps of Flowing Thought [supplement: LBIS]\n        28477, -- Harbinger Bands\n";
        let l = parse(t);
        assert_eq!(l, vec![(28477, "Harbinger Bands".into()), (28507, "Handwraps of Flowing Thought".into())]);
        assert_eq!(search_in(&l, "flow")[0].0, 28507);
        assert_eq!(search_in(&l, "h").len(), 2);
        assert_eq!(search_in(&l, "harb")[0].1, "Harbinger Bands");
        assert_eq!(parse("  30123, -- PALADIN: Crystalforge Shoulderguards
")[0].1, "Crystalforge Shoulderguards");
    }
}
