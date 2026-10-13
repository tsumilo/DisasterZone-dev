//! Host mode: the guild's Discord bot runs inside this launcher, on the host's PC only (Settings > Host, hidden
//! until Ctrl+Shift+H). The host's SavedVariables are the bot's data (Discord bridge plan, P0: connect + /ping).
//! The bot token lives in the OS credential store, never in settings.json or the repo.

use crate::core::error::msg;
use crate::core::state;
use crate::core::Result;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;
use tauri::async_runtime::JoinHandle;
use tauri::{AppHandle, Emitter, Manager};
use twilight_gateway::{CloseFrame, Event, EventTypeFlags, Intents, Shard, ShardId, StreamExt as _};
use twilight_http::Client;
use twilight_model::application::interaction::{Interaction, InteractionData};
use twilight_model::channel::message::MessageFlags;
use twilight_model::http::interaction::{InteractionResponse, InteractionResponseData, InteractionResponseType};
use twilight_model::id::marker::{ApplicationMarker, GuildMarker};
use twilight_model::id::Id;

const KEY_SERVICE: &str = "DisasterZoneLauncher";
const KEY_USER: &str = "discord-bot-token";

#[derive(Clone, Debug, Default, Serialize, PartialEq)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum BotStatus {
    #[default]
    Off,
    Connecting,
    Online {
        name: String,
    },
    Error {
        message: String,
    },
}

/// The running bot (at most one task) and what the window shows about it.
#[derive(Default)]
pub struct Bot {
    status: Mutex<BotStatus>,
    task: Mutex<Option<JoinHandle<()>>>,
}

fn entry() -> Result<keyring::Entry> {
    keyring::Entry::new(KEY_SERVICE, KEY_USER).map_err(|e| crate::core::Error::Msg(format!("credential store: {e}")))
}

pub fn token() -> Option<String> {
    entry().ok()?.get_password().ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty())
}

/// Empty = forget the saved token.
pub fn set_token(t: &str) -> Result<()> {
    let e = entry()?;
    let t = t.trim();
    if t.is_empty() {
        let _ = e.delete_credential();
        Ok(())
    } else {
        e.set_password(t).map_err(|err| crate::core::Error::Msg(format!("could not save the token: {err}")))
    }
}

pub fn status(app: &AppHandle) -> BotStatus {
    app.state::<Bot>().status.lock().unwrap().clone()
}

fn set_status(app: &AppHandle, s: BotStatus) {
    *app.state::<Bot>().status.lock().unwrap() = s.clone();
    let _ = app.emit("bot-status", s);
}

fn parse_ids(app_id: &str, guild_id: &str) -> Result<(Id<ApplicationMarker>, Id<GuildMarker>)> {
    let a = app_id.trim().parse::<u64>().ok().and_then(Id::new_checked);
    let g = guild_id.trim().parse::<u64>().ok().and_then(Id::new_checked);
    match (a, g) {
        (Some(a), Some(g)) => Ok((a, g)),
        (None, _) => msg("the application ID should be a long number (Developer Portal > General Information)"),
        (_, None) => msg("the server ID should be a long number (right-click the server > Copy Server ID)"),
    }
}

/// Stop the bot, then start it again if host mode is set up and turned on (after every settings change).
pub fn restart(app: &AppHandle) {
    if let Some(t) = app.state::<Bot>().task.lock().unwrap().take() {
        t.abort();
    }
    let s = state::load();
    if !s.bot_on {
        set_status(app, BotStatus::Off);
        return;
    }
    let Some(token) = token() else {
        set_status(app, BotStatus::Error { message: "no bot token saved".into() });
        return;
    };
    let (app_id, guild_id) = match parse_ids(&s.bot_app_id, &s.bot_guild_id) {
        Ok(x) => x,
        Err(e) => {
            set_status(app, BotStatus::Error { message: e.to_string() });
            return;
        }
    };
    // the gateway's TLS (rustls) needs a crypto provider; ring builds without extra tools on every OS
    let _ = rustls::crypto::ring::default_provider().install_default();
    set_status(app, BotStatus::Connecting);
    let handle = app.clone();
    let task = tauri::async_runtime::spawn(async move {
        let message = run(&handle, token, app_id, guild_id).await;
        set_status(&handle, BotStatus::Error { message });
    });
    *app.state::<Bot>().task.lock().unwrap() = Some(task);
}

/// Runs until the connection ends for good; returns why.
async fn run(app: &AppHandle, token: String, app_id: Id<ApplicationMarker>, guild_id: Id<GuildMarker>) -> String {
    let http = Client::new(token.clone());
    // guild commands show up at once (global ones can take an hour)
    if let Err(e) = http
        .interaction(app_id)
        .create_guild_command(guild_id)
        .chat_input("ping", "Check that the DisasterZone bot is online")
        .await
    {
        return explain_http(&e.to_string());
    }
    let mut shard = Shard::new(ShardId::ONE, token, Intents::GUILDS);
    let wanted = EventTypeFlags::READY | EventTypeFlags::INTERACTION_CREATE;
    while let Some(item) = shard.next_event(wanted).await {
        match item {
            Ok(Event::Ready(r)) => set_status(app, BotStatus::Online { name: r.user.name.clone() }),
            Ok(Event::InteractionCreate(i)) => {
                if let Err(e) = answer(app, &http, app_id, &i.0).await {
                    eprintln!("bot: answer failed: {e}");
                }
            }
            Ok(Event::GatewayClose(Some(f))) => {
                if let Some(why) = fatal_close(&f) {
                    return why;
                }
                set_status(app, BotStatus::Connecting); // (the shard reconnects by itself)
            }
            Ok(_) => {}
            Err(e) => eprintln!("bot: {e}"),
        }
    }
    "Discord closed the connection".into()
}

fn fatal_close(f: &CloseFrame<'_>) -> Option<String> {
    match f.code {
        4004 => Some("Discord refused the bot token (reset it in the Developer Portal and paste it again)".into()),
        4013 | 4014 => Some("Discord refused the bot's intents".into()),
        _ => None,
    }
}

fn explain_http(e: &str) -> String {
    if e.contains("401") {
        "Discord refused the bot token (reset it in the Developer Portal and paste it again)".into()
    } else if e.contains("403") || e.contains("Missing Access") {
        "the bot is not in that server, or the server ID is wrong (invite it with the OAuth2 URL)".into()
    } else {
        format!("could not reach Discord: {e}")
    }
}

async fn answer(app: &AppHandle, http: &Client, app_id: Id<ApplicationMarker>, i: &Interaction) -> Result<()> {
    let Some(InteractionData::ApplicationCommand(cmd)) = &i.data else { return Ok(()) };
    let text = match cmd.name.as_str() {
        "ping" => ping_text(app),
        _ => "This command is not ready yet.".to_string(),
    };
    let resp = InteractionResponse {
        kind: InteractionResponseType::ChannelMessageWithSource,
        data: Some(InteractionResponseData {
            content: Some(text),
            flags: Some(MessageFlags::EPHEMERAL),
            ..Default::default()
        }),
    };
    http.interaction(app_id)
        .create_response(i.id, &i.token, &resp)
        .await
        .map_err(|e| crate::core::Error::Net(e.to_string()))?;
    Ok(())
}

fn ping_text(_app: &AppHandle) -> String {
    let age = state::load()
        .flavor_dir()
        .and_then(|d| newest_saved_variables(&d))
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .map(|d| fmt_age(d.as_secs()));
    match age {
        Some(a) => format!("Pong. Guild data as of the host's last reload, {a}."),
        None => "Pong. No guild data yet (the host has not logged in with DisasterZone).".into(),
    }
}

/// The newest `WTF/Account/<name>/SavedVariables/DisasterZone.lua` under a game folder (the host may have
/// several accounts; the one played last is the freshest).
pub fn newest_saved_variables(flavor_dir: &Path) -> Option<SystemTime> {
    let accounts = std::fs::read_dir(flavor_dir.join("WTF").join("Account")).ok()?;
    accounts
        .flatten()
        .map(|a| a.path().join("SavedVariables").join("DisasterZone.lua"))
        .filter_map(|p: PathBuf| std::fs::metadata(p).ok()?.modified().ok())
        .max()
}

pub fn fmt_age(secs: u64) -> String {
    match secs {
        0..=59 => "just now".into(),
        60..=3599 => format!("{} min ago", secs / 60),
        3600..=86_399 => format!("{} h ago", secs / 3600),
        _ => format!("{} days ago", secs / 86_400),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ages_read_plainly() {
        assert_eq!(fmt_age(5), "just now");
        assert_eq!(fmt_age(150), "2 min ago");
        assert_eq!(fmt_age(7300), "2 h ago");
        assert_eq!(fmt_age(200_000), "2 days ago");
    }

    #[test]
    fn ids_are_checked() {
        assert!(parse_ids("1559678772113055894", "1512358590235803648").is_ok());
        assert!(parse_ids("abc", "1512358590235803648").is_err());
        assert!(parse_ids("1559678772113055894", "").is_err());
    }

    #[test]
    fn newest_account_file_wins() {
        let dir = tempfile::tempdir().unwrap();
        for acct in ["A", "B"] {
            let sv = dir.path().join("WTF/Account").join(acct).join("SavedVariables");
            std::fs::create_dir_all(&sv).unwrap();
            std::fs::write(sv.join("DisasterZone.lua"), "x").unwrap();
        }
        assert!(newest_saved_variables(dir.path()).is_some());
        assert!(newest_saved_variables(&dir.path().join("nope")).is_none());
    }
}
