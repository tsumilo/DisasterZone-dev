//! Item icons the exported art lacks (crafted, reputation, badge and other non-raid items): looked up on Wowhead
//! (its tooltip data names the icon, its image server has it) and kept in the art folder, so each is fetched once.

use std::collections::HashSet;
use std::sync::Mutex;

/// Items tried this session (found or not): never asked twice.
static TRIED: Mutex<Option<HashSet<u32>>> = Mutex::new(None);

async fn fetch_one(client: &reqwest::Client, id: u32) -> Option<Vec<u8>> {
    let tip: serde_json::Value = client
        .get(format!("https://nether.wowhead.com/tbc/tooltip/item/{id}"))
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;
    let icon = tip.get("icon")?.as_str()?.to_lowercase();
    let jpg = client.get(format!("https://wow.zamimg.com/images/wow/icons/large/{icon}.jpg")).send().await.ok()?.bytes().await.ok()?;
    let im = image::load_from_memory(&jpg).ok()?.to_rgba8();
    let im = image::imageops::resize(&im, 64, 64, image::imageops::FilterType::Lanczos3);
    let mut out = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(im).write_to(&mut out, image::ImageFormat::Png).ok()?;
    Some(out.into_inner())
}

/// Make sure these items have an icon in the art folder (missing ones are fetched, a few at a time).
pub async fn ensure_items(ids: impl IntoIterator<Item = u32>) {
    let Some(art) = super::art() else { return };
    let want: Vec<u32> = {
        let mut tried = TRIED.lock().unwrap();
        let tried = tried.get_or_insert_with(HashSet::new);
        ids.into_iter()
            .filter(|id| *id > 0 && !art.dir().join(format!("item_{id}.png")).exists() && tried.insert(*id))
            .collect()
    };
    if want.is_empty() {
        return;
    }
    let client = match reqwest::Client::builder().user_agent("DisasterZoneLauncher").timeout(std::time::Duration::from_secs(15)).build() {
        Ok(c) => c,
        Err(_) => return,
    };
    for chunk in want.chunks(6) {
        let got = futures::future::join_all(chunk.iter().map(|id| fetch_one(&client, *id))).await;
        for (id, png) in chunk.iter().zip(got) {
            if let Some(png) = png {
                let name = format!("item_{id}.png");
                if std::fs::write(art.dir().join(&name), png).is_ok() {
                    art.forget(&name);
                }
            }
        }
    }
}

/// Every item a snapshot names (its item table: the lists' picks and the loot).
pub fn snapshot_items(snap: &serde_json::Value) -> Vec<u32> {
    snap.get("items")
        .and_then(|i| i.as_object())
        .map(|m| m.keys().filter_map(|k| k.parse().ok()).collect())
        .unwrap_or_default()
}
