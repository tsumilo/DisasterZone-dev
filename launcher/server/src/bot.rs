//! The guild's Discord bot. It answers from the guild picture members' launchers upload (api.rs, merge.rs) and queues
//! what people change in Discord as signed records for the game (bridge.rs). The token comes from the server's
//! environment or data folder (main.rs), never from the repo.

use crate::core::bridge;
use crate::core::Result;
use std::sync::{Arc, RwLock};
use std::time::SystemTime;
use twilight_gateway::{CloseFrame, Event, EventTypeFlags, Intents, Shard, ShardId, StreamExt as _};
use twilight_http::Client;
use twilight_model::application::command::CommandType;
use twilight_model::application::interaction::application_command::CommandOptionValue;
use twilight_model::application::interaction::{Interaction, InteractionData};
use twilight_model::application::command::{CommandOptionChoice, CommandOptionChoiceValue};
use twilight_model::application::interaction::InteractionType;
use twilight_util::builder::command::{BooleanBuilder, CommandBuilder, IntegerBuilder, StringBuilder, SubCommandBuilder};
use twilight_model::channel::message::MessageFlags;
use twilight_model::channel::ChannelType;
use twilight_model::http::interaction::{InteractionResponse, InteractionResponseData, InteractionResponseType};
use twilight_model::id::marker::{ApplicationMarker, GuildMarker};
use twilight_model::id::Id;

/// The bot's Discord client while it is connected (the web side DMs and posts with it).
static HTTP: RwLock<Option<Arc<Client>>> = RwLock::new(None);

pub fn http() -> Option<Arc<Client>> {
    HTTP.read().unwrap().clone()
}

fn parse_ids(app_id: &str, guild_id: &str) -> std::result::Result<(Id<ApplicationMarker>, Id<GuildMarker>), String> {
    let a = app_id.trim().parse::<u64>().ok().and_then(Id::new_checked);
    let g = guild_id.trim().parse::<u64>().ok().and_then(Id::new_checked);
    match (a, g) {
        (Some(a), Some(g)) => Ok((a, g)),
        (None, _) => Err("appId in server.json should be a long number (Developer Portal > General Information)".into()),
        (_, None) => Err("guildId in server.json should be a long number (right-click the server > Copy Server ID)".into()),
    }
}

/// Keep the bot connected: a dropped connection comes back after a pause; a refused token or bad ids end it.
pub async fn run_forever(token: String, app_id: String, guild_id: String) {
    let (app_id, guild_id) = match parse_ids(&app_id, &guild_id) {
        Ok(x) => x,
        Err(e) => return eprintln!("bot: {e}"),
    };
    // the gateway's TLS (rustls) needs a crypto provider
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut wait = 5;
    loop {
        eprintln!("bot: connecting");
        let why = run(token.clone(), app_id, guild_id).await;
        *HTTP.write().unwrap() = None;
        eprintln!("bot: {why}");
        if why.starts_with("Discord refused") {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
        wait = (wait * 2).min(300);
    }
}

/// Runs until the connection ends for good; returns why.
async fn run(token: String, app_id: Id<ApplicationMarker>, guild_id: Id<GuildMarker>) -> String {
    // (shared with the tasks below: an answer must never wait for a picture being drawn)
    let http = Arc::new(Client::new(token.clone()));
    *crate::signup::GUILD.lock().unwrap() = guild_id.get().to_string();
    // guild commands show up at once (global ones can take an hour); setting the whole list drops old ones
    let commands = [
        CommandBuilder::new("ping", "Check that the DisasterZone bot is online", CommandType::ChatInput).build(),
        CommandBuilder::new("raids", "The coming raids, their sign-ups and your answer", CommandType::ChatInput).build(),
        CommandBuilder::new("bis", "BiS lists: see one, or change yours", CommandType::ChatInput)
            .option(
                SubCommandBuilder::new("show", "A BiS list for this phase (yours, or someone's)")
                    .option(StringBuilder::new("character", "Whose list (default: your character)").required(false).max_length(40)),
            )
            .option(
                SubCommandBuilder::new("set", "Change a slot of your list")
                    .option(
                        IntegerBuilder::new("slot", "Which slot")
                            .required(true)
                            .choices(crate::signup::SLOTS.iter().enumerate().map(|(i, s)| (*s, i as i64 + 1))),
                    )
                    .option(StringBuilder::new("item", "Start typing the item's name (none = empty the slot)").required(true).autocomplete(true))
                    .option(StringBuilder::new("character", "Which of your characters (default: your first)").required(false).max_length(40))
                    .option(
                        StringBuilder::new("pick", "Main pick (default) or the slot's alternative")
                            .required(false)
                            .choices([("Main", "main"), ("Alternative", "alt")]),
                    )
                    .option(IntegerBuilder::new("phase", "Which phase (0 = Pre-raid; default: the guild's)").required(false).min_value(0).max_value(5)),
            )
            .build(),
        CommandBuilder::new("character", "Your characters for raid sign-ups: add, see or remove them", CommandType::ChatInput)
            .build(),
        CommandBuilder::new("launcher", "Link your DisasterZone launcher, so your game syncs with Discord", CommandType::ChatInput)
            .option(BooleanBuilder::new("forget", "Unlink all your launchers instead (e.g. a PC you no longer use)").required(false))
            .build(),
        CommandBuilder::new("bridgetest", "Send a test line to the game (it shows at the next login or /reload)", CommandType::ChatInput)
            .option(StringBuilder::new("text", "What the game should print").required(true).max_length(200))
            .build(),
    ];
    if let Err(e) = http.interaction(app_id).set_guild_commands(guild_id, &commands).await {
        return explain_http(&e.to_string());
    }
    let mut shard = Shard::new(ShardId::ONE, token, Intents::GUILDS);
    let wanted = EventTypeFlags::READY | EventTypeFlags::INTERACTION_CREATE;
    // reminders are looked at every minute
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(60));
    loop {
        let item = tokio::select! {
            item = shard.next_event(wanted) => match item { Some(x) => x, None => break },
            _ = tick.tick() => {
                if let Some(snap) = crate::signup::current_snap() {
                    let h = http.clone();
                    tokio::spawn(async move { crate::remind::tick(&h, &snap, unix_now() as i64).await; });
                }
                continue;
            }
        };
        match item {
            Ok(Event::Ready(r)) => {
                eprintln!("bot: online as {}", r.user.name);
                *HTTP.write().unwrap() = Some(http.clone());
                refresh_channels(&http, guild_id).await;
                crate::emoji::sync(&http, app_id).await;
                // (post what changed while the bot was offline)
                if let Some(snap) = crate::signup::current_snap() {
                    let h = http.clone();
                    tokio::spawn(async move {
                        crate::render::fetch::ensure_items(crate::render::fetch::snapshot_items(&snap)).await;
                        crate::posts::update(&h, &snap).await;
                    });
                }
            }
            Ok(Event::InteractionCreate(i)) => {
                // (each answer on its own task: Discord waits 3 seconds for it)
                let h = http.clone();
                tokio::spawn(async move {
                    if let Err(e) = answer(&h, app_id, &i.0).await {
                        eprintln!("bot: answer failed: {e}");
                    }
                });
            }
            Ok(Event::GatewayClose(Some(f))) => {
                if let Some(why) = fatal_close(&f) {
                    return why;
                }
                eprintln!("bot: connection closed ({}), reconnecting", f.code); // (the shard reconnects by itself)
            }
            Ok(_) => {}
            Err(e) => eprintln!("bot: {e}"),
        }
    }
    "Discord closed the connection".into()
}

/// DMs after a sync: the changes from Discord the game refused, with why.
pub async fn tell(http: &Client, failed: &[(bridge::Record, String)]) {
    for (r, why) in failed {
        if !r.discord.is_empty() {
            let what = match r.kind.as_str() {
                "bis" => "BiS change",
                "signup" => "sign-up",
                _ => "change",
            };
            dm(http, &r.discord, &format!("Your {what} from Discord didn't go through: {why}")).await;
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

/// The server's text channels go to every launcher's inbox, for the addon's Settings > Discord dropdowns:
/// "category > #channel", in Discord's own order, without the emoji WoW's fonts can't draw.
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
    }
}

/// A Discord name as WoW can draw it: letters (any language), digits, - _ . ' and spaces; emoji and symbols dropped.
pub fn plain_name(n: &str) -> String {
    let kept: String = n.chars().filter(|c| c.is_alphanumeric() || "-_.' ".contains(*c)).collect();
    kept.trim_matches(|c: char| c == '-' || c == ' ' || c == '_').to_string()
}

fn fatal_close(f: &CloseFrame<'_>) -> Option<String> {
    match f.code {
        4004 => Some("Discord refused the bot token (reset it in the Developer Portal and save it again)".into()),
        4013 | 4014 => Some("Discord refused the bot's intents".into()),
        _ => None,
    }
}

fn explain_http(e: &str) -> String {
    if e.contains("401") {
        "Discord refused the bot token (reset it in the Developer Portal and save it again)".into()
    } else if e.contains("403") || e.contains("Missing Access") {
        "the bot is not in that server, or the server ID is wrong (invite it with the OAuth2 URL)".into()
    } else {
        format!("could not reach Discord: {e}")
    }
}

async fn answer(http: &Client, app_id: Id<ApplicationMarker>, i: &Interaction) -> Result<()> {
    let user = i.author_id().map(|u| u.get().to_string()).unwrap_or_default();
    let name = i.author().map(|u| u.global_name.clone().unwrap_or_else(|| u.name.clone())).unwrap_or_default();
    let now = unix_now();
    match &i.data {
        Some(InteractionData::MessageComponent(c)) if ["rl:", "rm:", "rx:"].iter().any(|p| c.custom_id.starts_with(p)) => {
            let (text, embed, comps) = crate::remind::click(http, &user, &name, &c.custom_id, &c.values).await;
            let resp = InteractionResponse {
                kind: InteractionResponseType::UpdateMessage,
                data: Some(InteractionResponseData {
                    content: Some(text),
                    embeds: embed.map(|e| vec![e]),
                    components: Some(comps),
                    ..Default::default()
                }),
            };
            http.interaction(app_id).create_response(i.id, &i.token, &resp).await.map_err(|e| crate::core::Error::Net(e.to_string()))?;
            crate::posts::refresh(http).await;
            return Ok(());
        }
        Some(InteractionData::MessageComponent(c)) if c.custom_id.starts_with('b') && c.custom_id.as_bytes().get(2) == Some(&b':') => {
            let r = if c.values.is_empty() {
                crate::bis::button(&user, &c.custom_id)
            } else {
                crate::bis::select(&user, &name, &c.custom_id, &c.values)
            };
            return respond_bis(http, app_id, i, r).await;
        }
        Some(InteractionData::ModalSubmit(m)) if m.custom_id.starts_with("bm:") => {
            let r = crate::bis::form_sent(&user, &name, m);
            return respond_bis(http, app_id, i, r).await;
        }
        Some(InteractionData::ApplicationCommand(cmd)) if cmd.name == "bis" && matches!(cmd.options.first().map(|o| o.name.as_str()), Some("show") | None) => {
            let who = cmd.options.first().and_then(|o| match &o.value {
                CommandOptionValue::SubCommand(v) => v.iter().find_map(|x| match &x.value {
                    CommandOptionValue::String(t) if x.name == "character" => Some(t.clone()),
                    _ => None,
                }),
                _ => None,
            });
            return respond_bis(http, app_id, i, crate::bis::show(&user, who.as_deref())).await;
        }
        Some(InteractionData::MessageComponent(c)) => {
            let a = if c.values.is_empty() {
                crate::signup::button(&user, &name, &c.custom_id, now)
            } else {
                crate::signup::select(&user, &name, &c.custom_id, &c.values, now)
            };
            let r = respond(http, app_id, i, a).await;
            crate::posts::refresh(http).await; // (after the answer: a new sign-up shows on its post, pending)
            return r;
        }
        Some(InteractionData::ModalSubmit(m)) => {
            let r = respond(http, app_id, i, crate::signup::form_sent(&user, m)).await;
            crate::posts::refresh(http).await;
            return r;
        }
        Some(InteractionData::ApplicationCommand(cmd)) if i.kind == InteractionType::ApplicationCommandAutocomplete => {
            return item_choices(http, app_id, i, cmd).await;
        }
        Some(InteractionData::ApplicationCommand(cmd)) if cmd.name == "raids" => {
            return respond(http, app_id, i, crate::signup::my_raids(&user, None)).await;
        }
        Some(InteractionData::ApplicationCommand(cmd)) if cmd.name == "character" => {
            return respond(http, app_id, i, crate::signup::characters(&user)).await;
        }
        _ => {}
    }
    let Some(InteractionData::ApplicationCommand(cmd)) = &i.data else { return Ok(()) };
    let text = match cmd.name.as_str() {
        "ping" => ping_text(),
        "launcher" => {
            let forget = cmd.options.iter().any(|o| o.name == "forget" && matches!(o.value, CommandOptionValue::Boolean(true)));
            if forget {
                match crate::members::forget(&user) {
                    0 => "You have no linked launchers.".to_string(),
                    n => format!("Unlinked {n} launcher{}. Link again with /launcher.", if n == 1 { "" } else { "s" }),
                }
            } else {
                launcher_text(&user, &name)
            }
        }
        "bis" => {
            let (sub, opts) = match cmd.options.first() {
                Some(o) => match &o.value {
                    CommandOptionValue::SubCommand(v) => (o.name.as_str(), v.as_slice()),
                    _ => ("show", cmd.options.as_slice()),
                },
                None => ("show", &[][..]),
            };
            let s = |n: &str| {
                opts.iter().find_map(|o| match &o.value {
                    CommandOptionValue::String(t) if o.name == n => Some(t.clone()),
                    _ => None,
                })
            };
            let int = |n: &str| {
                opts.iter().find_map(|o| match &o.value {
                    CommandOptionValue::Integer(v) if o.name == n => Some(*v),
                    _ => None,
                })
            };
            let alt = s("pick").as_deref() == Some("alt");
            if sub == "set" {
                crate::signup::bis_set(
                    &user,
                    &name,
                    int("slot").unwrap_or(0),
                    &s("item").unwrap_or_default(),
                    s("character").as_deref(),
                    alt,
                    int("phase"),
                    unix_now(),
                )
            } else {
                crate::signup::bis_text(&user, s("character").as_deref(), unix_now())
            }
        }
        "raids" => crate::signup::raids_text(&user, &i.guild_id.map(|g| g.get().to_string()).unwrap_or_default(), unix_now()),
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
            bridge_test(&who, &text, i.id.get())
        }
        _ => "This command is not ready yet.".to_string(),
    };
    reply(http, app_id, i, text).await
}

async fn respond(http: &Client, app_id: Id<ApplicationMarker>, i: &Interaction, a: crate::signup::Answer) -> Result<()> {
    use crate::signup::Answer;
    let (kind, data) = match a {
        Answer::Text(t, c) => return reply_with(http, app_id, i, t, c).await,
        Answer::Sheet(e, c, f, b) => (
            InteractionResponseType::ChannelMessageWithSource,
            InteractionResponseData {
                embeds: Some(vec![e]),
                components: Some(c),
                attachments: Some(vec![twilight_model::http::attachment::Attachment::from_bytes(f, b, 1)]),
                flags: Some(MessageFlags::EPHEMERAL),
                ..Default::default()
            },
        ),
        Answer::UpdateCard(e, c) => (
            InteractionResponseType::UpdateMessage,
            InteractionResponseData { content: Some(String::new()), embeds: Some(vec![e]), components: Some(c), ..Default::default() },
        ),
        Answer::Card(e, c) => (
            InteractionResponseType::ChannelMessageWithSource,
            InteractionResponseData {
                embeds: Some(vec![e]),
                components: Some(c),
                flags: Some(MessageFlags::EPHEMERAL),
                ..Default::default()
            },
        ),
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

/// /bis set's item: the items whose name holds what was typed so far.
async fn item_choices(
    http: &Client,
    app_id: Id<ApplicationMarker>,
    i: &Interaction,
    cmd: &twilight_model::application::interaction::application_command::CommandData,
) -> Result<()> {
    fn focused(opts: &[twilight_model::application::interaction::application_command::CommandDataOption]) -> Option<String> {
        opts.iter().find_map(|o| match &o.value {
            CommandOptionValue::Focused(v, _) => Some(v.clone()),
            CommandOptionValue::SubCommand(v) => focused(v),
            _ => None,
        })
    }
    let typed = focused(&cmd.options).unwrap_or_default();
    let mut choices: Vec<CommandOptionChoice> = crate::items::search(&typed)
        .into_iter()
        .map(|(id, n)| CommandOptionChoice { name: n, name_localizations: None, value: CommandOptionChoiceValue::String(id.to_string()) })
        .collect();
    if "none".starts_with(&typed.to_lowercase()) {
        choices.truncate(24);
        choices.push(CommandOptionChoice {
            name: "(empty the slot)".into(),
            name_localizations: None,
            value: CommandOptionChoiceValue::String("none".into()),
        });
    }
    let resp = InteractionResponse {
        kind: InteractionResponseType::ApplicationCommandAutocompleteResult,
        data: Some(InteractionResponseData { choices: Some(choices), ..Default::default() }),
    };
    http.interaction(app_id)
        .create_response(i.id, &i.token, &resp)
        .await
        .map_err(|e| crate::core::Error::Net(e.to_string()))?;
    Ok(())
}

async fn respond_bis(http: &Client, app_id: Id<ApplicationMarker>, i: &Interaction, r: crate::bis::Reply) -> Result<()> {
    use crate::bis::Reply;
    let resp = match r {
        Reply::Modal { custom_id, title, components } => InteractionResponse {
            kind: InteractionResponseType::Modal,
            data: Some(InteractionResponseData { custom_id: Some(custom_id), title: Some(title), components: Some(components), ..Default::default() }),
        },
        Reply::Pic { update, private, text, embed, comps, file } => InteractionResponse {
            kind: if update { InteractionResponseType::UpdateMessage } else { InteractionResponseType::ChannelMessageWithSource },
            data: Some(InteractionResponseData {
                content: text.or(if update { Some(String::new()) } else { None }),
                embeds: Some(embed.into_iter().collect()),
                components: Some(comps),
                attachments: file.map(|(f, b)| vec![twilight_model::http::attachment::Attachment::from_bytes(f, b, 1)]),
                flags: if private && !update { Some(MessageFlags::EPHEMERAL) } else { None },
                ..Default::default()
            }),
        },
    };
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
    // (a message holds 2000 characters, an embed's text 4096: a long answer, e.g. a BiS list with its links, goes
    // in an embed; anything longer is cut)
    let (content, embeds) = if text.chars().count() <= 1900 {
        (Some(text), None)
    } else {
        let mut t: String = text.chars().take(4000).collect();
        if t.len() < text.len() {
            t.push('…');
        }
        (None, Some(vec![twilight_util::builder::embed::EmbedBuilder::new().description(t).color(0xFF8000).build()]))
    };
    let resp = InteractionResponse {
        kind: InteractionResponseType::ChannelMessageWithSource,
        data: Some(InteractionResponseData {
            content,
            embeds,
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

pub fn unix_now() -> u64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn bridge_test(who: &str, text: &str, nonce: u64) -> String {
    let now = unix_now();
    let r = bridge::Record {
        id: format!("dc_{now}_{nonce}"),
        kind: "test".into(),
        at: now,
        by: who.to_string(),
        body: serde_json::json!({ "text": text }),
        discord: String::new(),
        sig: String::new(),
    };
    match bridge::push(r) {
        Ok(q) => format!(
            "Queued for the game ({} waiting). It shows up when someone with the launcher next logs in or does /reload.",
            q.len()
        ),
        Err(e) => format!("Could not queue it: {e}"),
    }
}

/// /launcher: a one-time code for the launcher's Settings > Discord.
fn launcher_text(user: &str, name: &str) -> String {
    let code = crate::members::new_code(user, name, unix_now());
    format!(
        "Your launcher code: **`{code}`**\nOpen the DisasterZone launcher > Settings > Discord, paste it and press Link. \
         It works once, for 15 minutes. After that your game syncs with Discord by itself (keep the launcher in the tray)."
    )
}

fn ping_text() -> String {
    let age = crate::signup::current_snap()
        .and_then(|s| s.get("at").and_then(|a| a.as_u64()))
        .map(|a| fmt_age(unix_now().saturating_sub(a)));
    match age {
        Some(a) => format!("Pong. Guild data as of the last game save that synced, {a}."),
        None => "Pong. No guild data yet (nobody's launcher has synced a game save).".into(),
    }
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
    fn launcher_codes_are_handed_out() {
        let (_d, _g) = crate::bridge::tests::scratch();
        assert!(launcher_text("42", "Tsumi").contains("**`"));
    }
}
