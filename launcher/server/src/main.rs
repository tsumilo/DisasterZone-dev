//! dz-server: the guild's Discord bot, on a server that is always on. Members' launchers sync the game with it
//! (api.rs); it answers Discord (bot.rs) from the guild picture their uploads make (merge.rs).
//!
//!   dz-server keygen [height]   make the signing key (2^height records; 16 by default) and print the addon's
//!                               Core/BridgeKey.lua (also written to <data>/BridgeKey.lua)
//!   dz-server [run]             run the bot and the web side
//!
//! Data folder: $DZ_DATA (default ./data). It holds server.json { appId, guildId, listen, guild }, the bot token
//! (discord_token.txt, or $DISCORD_TOKEN), the signing key, the bot's files (bridge.rs, posts, reminders, members),
//! bot_art/ (dev/tools/bot_art.py) and Items.lua (the addon's Data/Items.lua, for /bis set). DZ_NO_BOT=1 runs the
//! web side only (testing while another copy of the bot is online).
//! The bot's pictures use the machine's clock for days and times: set TZ to the realm's time zone.

mod api;
mod bis;
mod bot;
pub mod bridge;
mod core;
mod emoji;
mod items;
mod members;
mod merge;
mod posts;
mod presence;
mod remind;
mod render;
mod signup;

use serde::Deserialize;
use std::path::PathBuf;
use std::sync::{OnceLock, RwLock};

static DATA: RwLock<Option<PathBuf>> = RwLock::new(None);

pub fn data_dir() -> PathBuf {
    DATA.read().unwrap().clone().unwrap_or_else(|| {
        std::env::var_os("DZ_DATA").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("data"))
    })
}

pub fn set_data_dir(p: PathBuf) {
    *DATA.write().unwrap() = Some(p);
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Config {
    /// Developer Portal > General Information > Application ID
    pub app_id: String,
    /// the Discord server (right-click > Copy Server ID)
    pub guild_id: String,
    /// where the web side listens (default 127.0.0.1:8787: a TLS proxy in front of it)
    pub listen: String,
    /// the WoW guild this bot serves ("Guild Name-Realm" as the addon writes it); empty = the first one that syncs
    pub guild: Option<String>,
}

static CONFIG: OnceLock<Config> = OnceLock::new();

pub fn config() -> &'static Config {
    CONFIG.get_or_init(|| {
        let p = data_dir().join("server.json");
        match std::fs::read(&p) {
            Ok(d) => serde_json::from_slice(&d).unwrap_or_else(|e| {
                eprintln!("{} is not valid: {e}", p.display());
                std::process::exit(2)
            }),
            Err(_) => Config::default(),
        }
    })
}

fn token() -> Option<String> {
    std::env::var("DISCORD_TOKEN")
        .ok()
        .or_else(|| std::fs::read_to_string(data_dir().join("discord_token.txt")).ok())
        .or_else(launcher_token)
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

/// Testing at home on Windows: the token the launcher's old host mode saved in the credential store.
#[cfg(windows)]
fn launcher_token() -> Option<String> {
    keyring::Entry::new("DisasterZoneLauncher", "discord-bot-token").ok()?.get_password().ok()
}

#[cfg(not(windows))]
fn launcher_token() -> Option<String> {
    None
}

fn keygen(height: u8) {
    let p = data_dir().join("bridge_key.json");
    if p.exists() {
        eprintln!("{} exists already: a new key needs an addon release with it. Move the old one away first.", p.display());
        std::process::exit(2);
    }
    let mut e = [0u8; 48];
    getrandom::fill(&mut e).expect("no random numbers");
    eprintln!("making a key for {} records...", 1u64 << height);
    let s = dz_proto::wots::Signer::create(&p, height, &e).unwrap_or_else(|e| {
        eprintln!("could not make the key: {e}");
        std::process::exit(2)
    });
    let lua = format!(
        "if DisasterZoneBoot and DisasterZoneBoot.Run(\"Core/BridgeKey.lua\", ...) then return end -- DisasterZone: public key Discord bridge records are verified with (written by dz-server keygen).\n\
         -- The private half lives only on the bot's server. Core/Bridge.lua explains the scheme.\n\
         local addonName, ns = ...\n\n{}",
        s.public().lua()
    );
    let _ = std::fs::write(data_dir().join("BridgeKey.lua"), &lua);
    print!("{lua}");
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("keygen") => return keygen(args.get(1).and_then(|h| h.parse().ok()).unwrap_or(16).clamp(4, 20)),
        None | Some("run") => {}
        Some(other) => {
            eprintln!("unknown command {other}: dz-server [run | keygen [height]]");
            std::process::exit(2);
        }
    }
    let cfg = config();
    match dz_proto::wots::Signer::open(&data_dir().join("bridge_key.json")) {
        Ok(s) => {
            eprintln!("signing key: {} records left", s.left());
            bridge::set_signer(s);
        }
        Err(e) => eprintln!("no signing key ({e}): Discord changes can't reach the game. Run dz-server keygen."),
    }
    if let Some(v) = std::fs::read(bridge::path("merged.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()) {
        signup::set_snap(v);
    }
    // (the game's Discord badges: a signed list, sent again if it changed while the bot was off)
    let profiles = bridge::load_profiles();
    if !profiles.is_empty() {
        if let Err(e) = bridge::push_links(&profiles) {
            eprintln!("could not queue the badges: {e}");
        }
    }
    let listen = if cfg.listen.is_empty() { "127.0.0.1:8787" } else { cfg.listen.as_str() };
    let socket = tokio::net::TcpListener::bind(listen).await.unwrap_or_else(|e| {
        eprintln!("can't listen on {listen}: {e}");
        std::process::exit(2)
    });
    eprintln!("web side on http://{listen}");
    tokio::spawn(async move {
        if let Err(e) = axum::serve(socket, api::router()).await {
            eprintln!("web side stopped: {e}");
            std::process::exit(1);
        }
    });
    if std::env::var_os("DZ_NO_BOT").is_some() {
        eprintln!("DZ_NO_BOT: only the web side runs");
        let _ = tokio::signal::ctrl_c().await;
        return;
    }
    let Some(token) = token() else {
        eprintln!("no bot token (DISCORD_TOKEN or {}): only the web side runs", data_dir().join("discord_token.txt").display());
        let _ = tokio::signal::ctrl_c().await;
        return;
    };
    tokio::select! {
        _ = bot::run_forever(token, cfg.app_id.clone(), cfg.guild_id.clone()) => {}
        _ = tokio::signal::ctrl_c() => eprintln!("stopping"),
    }
}
