//! The web side members' launchers talk to (dz_proto documents the bodies):
//!   GET  /api/health           is the bot up, how old is its guild data, signatures left
//!   POST /api/link  { code }   a /launcher code -> the launcher's member key
//!   POST /api/sync             (Bearer key) the game's last save in, the signed records + channels + links out
//! Behind a TLS proxy (Caddy) on the server; plain HTTP on 127.0.0.1 when testing at home.

use crate::bridge;
use axum::body::Bytes;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::{get, post};
use axum::{Json, Router};
use dz_proto::{LinkDown, LinkUp, SyncDown, SyncUp};
use serde_json::{json, Value};
use std::io::Read;

/// The biggest upload taken (a guild's snapshot is a few hundred KB; gzip'd far less).
const MAX_BODY: usize = 16 * 1024 * 1024;

type Fail = (StatusCode, String);

fn fail(code: StatusCode, text: &str) -> Fail {
    (code, text.to_string())
}

pub fn router() -> Router {
    Router::new()
        .route("/api/health", get(health))
        .route("/api/link", post(link))
        .route("/api/sync", post(sync))
        .layer(axum::extract::DefaultBodyLimit::max(MAX_BODY))
}

async fn health() -> Json<Value> {
    let now = crate::bot::unix_now();
    let age = crate::signup::current_snap().and_then(|s| s.get("at").and_then(|a| a.as_u64())).map(|a| now.saturating_sub(a));
    Json(json!({ "ok": true, "version": env!("CARGO_PKG_VERSION"), "dataAge": age, "signaturesLeft": bridge::signatures_left() }))
}

async fn link(Json(up): Json<LinkUp>) -> Result<Json<LinkDown>, Fail> {
    match crate::members::redeem(&up.code, crate::bot::unix_now()) {
        Some((key, user)) => Ok(Json(LinkDown { key, user })),
        None => Err(fail(StatusCode::NOT_FOUND, "That code is unknown or older than 15 minutes: type /launcher in Discord for a new one.")),
    }
}

fn body_json(headers: &HeaderMap, body: &[u8]) -> Result<SyncUp, Fail> {
    let gz = headers.get("content-encoding").and_then(|v| v.to_str().ok()).is_some_and(|v| v.eq_ignore_ascii_case("gzip"));
    let raw = if gz {
        let mut out = Vec::new();
        flate2::read::GzDecoder::new(body)
            .take(MAX_BODY as u64 * 4)
            .read_to_end(&mut out)
            .map_err(|_| fail(StatusCode::BAD_REQUEST, "the upload is not gzip"))?;
        out
    } else {
        body.to_vec()
    };
    serde_json::from_slice(&raw).map_err(|e| fail(StatusCode::BAD_REQUEST, &format!("bad upload: {e}")))
}

/// (one upload merged at a time)
static MERGING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn sync(headers: HeaderMap, body: Bytes) -> Result<Json<SyncDown>, Fail> {
    let now = crate::bot::unix_now();
    let key = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(|| fail(StatusCode::UNAUTHORIZED, "no member key"))?;
    let member = crate::members::check(key, now)
        .ok_or_else(|| fail(StatusCode::UNAUTHORIZED, "This launcher's key was removed: link it again with /launcher in Discord."))?;
    let up = body_json(&headers, &body)?;
    if let Some(db) = up.bridge.as_ref() {
        // what the game took leaves the queue; refusals go to whoever made them
        match bridge::take_applied(db.get("applied")) {
            Ok(failed) if !failed.is_empty() => {
                if let Some(http) = crate::bot::http() {
                    tokio::spawn(async move { crate::bot::tell(&http, &failed).await });
                }
            }
            Ok(_) => {}
            Err(e) => eprintln!("sync: queue: {e}"),
        }
        if let Some(snap) = db.get("snap").filter(|s| s.is_object() && s.get("error").is_none()) {
            take_snapshot(snap, &member.name).await;
        }
    }
    let mut down = SyncDown {
        now,
        records: bridge::load_queue(),
        channels: bridge::load_channels(),
        links: bridge::links(&bridge::load_profiles()),
        user: member.name,
        hash: String::new(),
        same: false,
    };
    down.hash = answer_hash(&down);
    // (the free server's traffic is capped: an unchanged answer is one line)
    if !up.have.is_empty() && up.have == down.hash {
        down.records.clear();
        down.channels.clear();
        down.links.clear();
        down.same = true;
    }
    Ok(Json(down))
}

fn answer_hash(d: &SyncDown) -> String {
    let text = serde_json::to_vec(&(&d.records, &d.channels, &d.links, &d.user)).unwrap_or_default();
    hex::encode(&<sha2::Sha256 as sha2::Digest>::digest(text)[..12])
}

/// Fold a member's snapshot into the guild's; when it changed, the raid posts follow.
pub async fn take_snapshot(snap: &Value, who: &str) {
    let _g = MERGING.lock().await;
    let cur = crate::signup::current_snap();
    let guild = crate::config().guild.clone().filter(|g| !g.is_empty());
    let merged = match crate::merge::merge(cur.as_ref(), snap, guild.as_deref()) {
        crate::merge::Outcome::Merged(v) => v,
        crate::merge::Outcome::OtherGuild(g) => {
            eprintln!("sync: {who}'s snapshot is for another guild ({g}): ignored");
            return;
        }
    };
    if cur.as_ref() == Some(&merged) {
        return;
    }
    if let Err(e) = bridge::save_json(&bridge::path("merged.json"), &merged) {
        eprintln!("sync: could not save merged.json: {e}");
    }
    crate::signup::set_snap(merged.clone());
    if let Some(http) = crate::bot::http() {
        tokio::spawn(async move {
            // (icons the exported art lacks: fetched once, before the pictures are drawn)
            crate::render::fetch::ensure_items(crate::render::fetch::snapshot_items(&merged)).await;
            crate::posts::update(&http, &merged).await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn uploads_may_be_gzipped() {
        let up = json!({ "launcher": "0.3.0", "bridge": { "applied": {} } });
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        gz.write_all(up.to_string().as_bytes()).unwrap();
        let mut h = HeaderMap::new();
        h.insert("content-encoding", "gzip".parse().unwrap());
        assert_eq!(body_json(&h, &gz.finish().unwrap()).unwrap().launcher, "0.3.0");
        assert_eq!(body_json(&HeaderMap::new(), up.to_string().as_bytes()).unwrap().launcher, "0.3.0");
        assert!(body_json(&h, b"plain").is_err());
    }
}
