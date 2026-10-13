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
use crate::core::bridge;
use twilight_model::application::command::CommandType;
use twilight_model::application::interaction::application_command::CommandOptionValue;
use twilight_model::application::interaction::{Interaction, InteractionData};
use twilight_util::builder::command::{CommandBuilder, StringBuilder};
use twilight_model::channel::message::MessageFlags;
use twilight_model::channel::ChannelType;
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
    // guild commands show up at once (global ones can take an hour); setting the whole list drops old ones
    let commands = [
        CommandBuilder::new("ping", "Check that the DisasterZone bot is online", CommandType::ChatInput).build(),
        CommandBuilder::new("character", "Your characters for raid sign-ups: add, see or remove them", CommandType::ChatInput)
            .build(),
        CommandBuilder::new("bridgetest", "Send a test line to the game (it shows at the host's next /reload)", CommandType::ChatInput)
            .option(StringBuilder::new("text", "What the game should print").required(true).max_length(200))
            .build(),
    ];
    if let Err(e) = http.interaction(app_id).set_guild_commands(guild_id, &commands).await {
        return explain_http(&e.to_string());
    }
    let mut shard = Shard::new(ShardId::ONE, token, Intents::GUILDS);
    let wanted = EventTypeFlags::READY | EventTypeFlags::INTERACTION_CREATE;
    // the game's answer (SavedVariables) is looked at every few seconds; a new save clears what it took
    let mut watch = tokio::time::interval(std::time::Duration::from_secs(5));
    let mut seen: Option<SystemTime> = None;
    loop {
        let item = tokio::select! {
            item = shard.next_event(wanted) => match item { Some(x) => x, None => break },
            _ = watch.tick() => {
                if let Some(dir) = state::load().flavor_dir() {
                    let now = newest_saved_variables(&dir);
                    if now != seen {
                        seen = now;
                        match bridge::sync(&dir, unix_now()) {
                            Ok(out) => tell(&http, &out).await,
                            Err(e) => eprintln!("bot: bridge sync: {e}"),
                        }
                        // the host's addon wrote a new snapshot: post new raids, edit changed ones
                        if let Some(snap) = bridge::read_bridge_db(&dir).and_then(|v| v.get("snap").cloned()) {
                            crate::posts::update(&http, &snap).await;
                            crate::signup::set_snap(snap);
                        }
                    }
                }
                continue;
            }
        };
        match item {
            Ok(Event::Ready(r)) => {
                set_status(app, BotStatus::Online { name: r.user.name.clone() });
                refresh_channels(&http, guild_id).await;
                seen = None; // (post what changed while the bot was offline)
            }
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

/// DMs after a sync: a sign-up the game refused (with why) and a link the game confirmed.
async fn tell(http: &Client, out: &bridge::Synced) {
    for (r, why) in &out.failed {
        if !r.discord.is_empty() {
            dm(http, &r.discord, &format!("Your Discord sign-up didn't go through: {why}")).await;
        }
    }
}

async fn dm(http: &Client, user: &str, text: &str) {
    let Some(uid) = user.parse::<u64>().ok().and_then(Id::new_checked) else { return };
    let Ok(resp) = http.create_private_channel(uid).await else { return };
    let Ok(ch) = resp.model().await else { return };
    if let Err(e) = http.create_message(ch.id).content(text).await {
        eprintln!("bot: dm: {e}");
    }
}

/// The server's text channels go into the inbox, for the addon's Settings > Discord dropdowns: "category > #channel",
/// in Discord's own order, without the emoji WoW's fonts can't draw.
async fn refresh_channels(http: &Client, guild_id: Id<GuildMarker>) {
    let Ok(resp) = http.guild_channels(guild_id).await else { return };
    let Ok(list) = resp.model().await else { return };
    let cats: std::collections::HashMap<_, _> = list
        .iter()
        .filter(|c| c.kind == ChannelType::GuildCategory)
        .map(|c| (c.id, (c.position.unwrap_or(0), plain_name(c.name.as_deref().unwrap_or("")))))
        .collect();
    let mut out: Vec<((i32, i32), bridge::Channel)> = list
        .iter()
        .filter(|c| c.kind == ChannelType::GuildText)
        .map(|c| {
            let cat = c.parent_id.and_then(|p| cats.get(&p));
            let name = plain_name(c.name.as_deref().unwrap_or(""));
            let label = match cat {
                Some((_, cn)) if !cn.is_empty() => format!("{cn} > #{name}"),
                _ => format!("#{name}"),
            };
            // (channels outside a category come first, as in Discord)
            let key = (cat.map_or(-1, |(p, _)| *p as i32), c.position.unwrap_or(0) as i32);
            (key, bridge::Channel { id: c.id.get().to_string(), name: label })
        })
        .collect();
    out.sort_by_key(|(k, _)| *k);
    let list: Vec<bridge::Channel> = out.into_iter().map(|(_, c)| c).collect();
    if list != bridge::load_channels() {
        let _ = bridge::save_channels(&list);
        if let Some(dir) = state::load().flavor_dir() {
            let _ = bridge::sync(&dir, unix_now());
        }
    }
}

/// A Discord name as WoW can draw it: letters (any language), digits, - _ . ' and spaces; emoji and symbols dropped.
pub fn plain_name(n: &str) -> String {
    let kept: String = n.chars().filter(|c| c.is_alphanumeric() || "-_.' ".contains(*c)).collect();
    kept.trim_matches(|c: char| c == '-' || c == ' ' || c == '_').to_string()
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
    let user = i.author_id().map(|u| u.get().to_string()).unwrap_or_default();
    let name = i.author().map(|u| u.global_name.clone().unwrap_or_else(|| u.name.clone())).unwrap_or_default();
    let now = unix_now();
    match &i.data {
        Some(InteractionData::MessageComponent(c)) => {
            let a = if c.values.is_empty() {
                crate::signup::button(&user, &name, &c.custom_id, now)
            } else {
                crate::signup::select(&user, &name, &c.custom_id, &c.values, now)
            };
            return respond(http, app_id, i, a).await;
        }
        Some(InteractionData::ModalSubmit(m)) => return respond(http, app_id, i, crate::signup::form_sent(&user, m)).await,
        Some(InteractionData::ApplicationCommand(cmd)) if cmd.name == "character" => {
            return respond(http, app_id, i, crate::signup::characters(&user)).await;
        }
        _ => {}
    }
    let Some(InteractionData::ApplicationCommand(cmd)) = &i.data else { return Ok(()) };
    let text = match cmd.name.as_str() {
        "ping" => ping_text(app),
        "bridgetest" => {
            let text = cmd
                .options
                .iter()
                .find_map(|o| match (&o.name[..], &o.value) {
                    ("text", CommandOptionValue::String(t)) => Some(t.clone()),
                    _ => None,
                })
                .unwrap_or_default();
            let who = i.author().map(|u| u.global_name.clone().unwrap_or_else(|| u.name.clone())).unwrap_or_default();
            bridge_test(app, &who, &text, i.id.get())
        }
        _ => "This command is not ready yet.".to_string(),
    };
    reply(http, app_id, i, text).await
}

async fn respond(http: &Client, app_id: Id<ApplicationMarker>, i: &Interaction, a: crate::signup::Answer) -> Result<()> {
    use crate::signup::Answer;
    let (kind, data) = match a {
        Answer::Text(t, c) => return reply_with(http, app_id, i, t, c).await,
        Answer::Update(t, c) => (
            InteractionResponseType::UpdateMessage,
            InteractionResponseData { content: Some(t), components: Some(c), ..Default::default() },
        ),
        Answer::Modal { custom_id, title, components } => (
            InteractionResponseType::Modal,
            InteractionResponseData { custom_id: Some(custom_id), title: Some(title), components: Some(components), ..Default::default() },
        ),
    };
    let resp = InteractionResponse { kind, data: Some(data) };
    http.interaction(app_id)
        .create_response(i.id, &i.token, &resp)
        .await
        .map_err(|e| crate::core::Error::Net(e.to_string()))?;
    Ok(())
}

async fn reply(http: &Client, app_id: Id<ApplicationMarker>, i: &Interaction, text: String) -> Result<()> {
    reply_with(http, app_id, i, text, Vec::new()).await
}

async fn reply_with(
    http: &Client,
    app_id: Id<ApplicationMarker>,
    i: &Interaction,
    text: String,
    components: Vec<twilight_model::channel::message::Component>,
) -> Result<()> {
    let resp = InteractionResponse {
        kind: InteractionResponseType::ChannelMessageWithSource,
        data: Some(InteractionResponseData {
            content: Some(text),
            components: if components.is_empty() { None } else { Some(components) },
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

fn unix_now() -> u64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn bridge_test(app: &AppHandle, who: &str, text: &str, nonce: u64) -> String {
    let Some(dir) = state::load().flavor_dir() else { return "The host has no game folder set.".into() };
    let now = unix_now();
    let r = bridge::Record {
        id: format!("dc_{now}_{nonce}"),
        kind: "test".into(),
        at: now,
        by: who.to_string(),
        body: serde_json::json!({ "text": text }),
        discord: String::new(),
    };
    match bridge::push(&dir, r, now) {
        Ok(q) => {
            if crate::core::wow::running() {
                crate::background::notify(app, "Discord update waiting", &format!("{} waiting: /reload in game to load them.", q.len()));
            }
            format!("Queued for the game ({} waiting). It shows up at the host's next /reload.", q.len())
        }
        Err(e) => format!("Could not queue it: {e}"),
    }
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
    fn channel_names_lose_their_emoji() {
        assert_eq!(plain_name("\u{1F525}the-spark"), "the-spark");
        assert_eq!(plain_name("\u{1F4CB}\u{FE0F}casual-protocol"), "casual-protocol");
        assert_eq!(plain_name("Räd-kanal"), "Räd-kanal");
        assert_eq!(plain_name("THE SPARK \u{2728}"), "THE SPARK");
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
