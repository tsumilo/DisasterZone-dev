//! Item search for BiS edits: the names of the addon's raid loot and where they drop, read once from a copy of its
//! data file (<data>/Items.lua = the addon's Data/Items.lua lists each raid, its bosses, and their items as "28477, -- Harbinger Bands").

use std::sync::Mutex;

#[derive(Debug, Clone, PartialEq)]
pub struct Item {
    pub id: u32,
    pub name: String,
    /// "Prince Malchezaar · Karazhan"
    pub source: String,
}

static ITEMS: Mutex<Option<Vec<Item>>> = Mutex::new(None);

fn quoted_after<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let rest = &line[line.find(key)? + key.len()..];
    rest.split('"').next()
}

/// Every item in an Items.lua text with its boss and raid, first mention wins.
pub fn parse(text: &str) -> Vec<Item> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    let (mut raid, mut boss) = (String::new(), String::new());
    for line in text.lines() {
        let t = line.trim();
        if t.contains("bosses = {") {
            raid = quoted_after(t, "name = \"").unwrap_or("").to_string();
            continue;
        }
        if t.starts_with("{ key = ") {
            boss = quoted_after(t, "name = \"").unwrap_or("").to_string();
            continue;
        }
        let Some((num, rest)) = t.split_once(", --") else { continue };
        let Ok(id) = num.trim().parse::<u32>() else { continue };
        // (tags like "[supplement: LBIS]" after the name are dropped)
        let name = rest.split(" [").next().unwrap_or(rest).trim();
        // (token lists write "PALADIN: Crystalforge Shoulderguards": the class goes)
        let name = match name.split_once(": ") {
            Some((cls, n)) if !cls.is_empty() && cls.chars().all(|c| c.is_ascii_uppercase()) => n,
            _ => name,
        };
        if !name.is_empty() && seen.insert(id) {
            let source = [boss.as_str(), raid.as_str()].iter().filter(|s| !s.is_empty()).copied().collect::<Vec<_>>().join(" · ");
            out.push(Item { id, name: name.to_string(), source });
        }
    }
    out
}

fn all() -> Vec<Item> {
    let mut g = ITEMS.lock().unwrap();
    if g.is_none() {
        let list = std::fs::read_to_string(crate::data_dir().join("Items.lua"))
            .ok()
            .map(|t| parse(&t))
            .unwrap_or_default();
        if list.is_empty() {
            return Vec::new();
        }
        *g = Some(list);
    }
    g.clone().unwrap_or_default()
}

/// Up to 25 items whose name holds the query (names that start with it first).
pub fn search_in(list: &[Item], query: &str) -> Vec<(u32, String)> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return Vec::new();
    }
    let mut starts: Vec<_> = list.iter().filter(|i| i.name.to_lowercase().starts_with(&q)).map(|i| (i.id, i.name.clone())).collect();
    let more = list.iter().filter(|i| {
        let l = i.name.to_lowercase();
        !l.starts_with(&q) && l.contains(&q)
    });
    starts.extend(more.map(|i| (i.id, i.name.clone())));
    starts.truncate(25);
    starts
}

pub fn search(query: &str) -> Vec<(u32, String)> {
    search_in(&all(), query)
}

pub fn name_of(id: u32) -> Option<String> {
    all().into_iter().find(|i| i.id == id).map(|i| i.name)
}

/// Where an item drops ("Prince Malchezaar · Karazhan"), for menus.
pub fn source_hint(id: u32) -> Option<String> {
    all().into_iter().find(|i| i.id == id).map(|i| i.source).filter(|s| !s.is_empty())
}

/// What the user typed or picked: an id (a picked choice) or an exact name.
pub fn resolve(value: &str) -> Option<u32> {
    if let Ok(id) = value.trim().parse::<u32>() {
        return Some(id);
    }
    let v = value.trim().to_lowercase();
    all().into_iter().find(|i| i.name.to_lowercase() == v).map(|i| i.id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_addon_item_list() {
        let t = "  { key = \"Karazhan\", name = \"Karazhan\", phase = 1, size = 10, instanceID = 532, bosses = {\n    { key = \"Attumen\", name = \"Attumen the Huntsman\", npcIDs = { 16152 }, items = {\n        28477, -- Harbinger Bands\n        28507, -- Handwraps of Flowing Thought [supplement: LBIS]\n        28477, -- Harbinger Bands\n        30123, -- PALADIN: Crystalforge Shoulderguards\n";
        let l = parse(t);
        assert_eq!(l.len(), 3);
        assert_eq!(l[0], Item { id: 28477, name: "Harbinger Bands".into(), source: "Attumen the Huntsman · Karazhan".into() });
        assert_eq!(l[2].name, "Crystalforge Shoulderguards");
        assert_eq!(search_in(&l, "flow")[0].0, 28507);
        assert_eq!(search_in(&l, "harb").len(), 1);
    }
}
