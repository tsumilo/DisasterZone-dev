//! The bot's own emoji (Discord "application emoji"), made once from the exported game art (render::art): the ready
//! check marks on the raid post's buttons, the class and spec icons in its private replies. Uploaded at start when
//! missing; until then the bot uses plain words.

use base64::Engine as _;
use std::collections::HashMap;
use std::sync::Mutex;
use twilight_http::Client;
use twilight_model::channel::message::EmojiReactionType;
use twilight_model::id::marker::{ApplicationMarker, EmojiMarker};
use twilight_model::id::Id;

static EMOJI: Mutex<Option<HashMap<String, Id<EmojiMarker>>>> = Mutex::new(None);

/// (emoji name, art file)
fn wanted() -> Vec<(String, String)> {
    let mut out = vec![
        ("dz_ready".into(), "ui_ready.png".into()),
        ("dz_waiting".into(), "ui_waiting.png".into()),
        ("dz_notready".into(), "ui_notready.png".into()),
        ("dz_hourglass".into(), "ui_hourglass.png".into()),
    ];
    for (class, _, specs) in crate::signup::CLASSES {
        out.push((format!("cls_{}", class.to_lowercase()), format!("class_{class}.png")));
        for i in 1..=specs.len() {
            out.push((format!("spec_{}_{i}", class.to_lowercase()), format!("spec_{class}_{i}.png")));
        }
    }
    out
}

/// Look up the bot's emoji and upload the missing ones (needs the exported art).
pub async fn sync(http: &Client, app: Id<ApplicationMarker>) {
    let mut have: HashMap<String, Id<EmojiMarker>> = HashMap::new();
    if let Ok(resp) = http.get_application_emojis(app).await {
        if let Ok(list) = resp.model().await {
            for e in list.items {
                have.insert(e.name, e.id);
            }
        }
    }
    if let Some(art) = crate::render::art() {
        for (name, file) in wanted() {
            if have.contains_key(&name) {
                continue;
            }
            let Some(png) = art.image(&file).map(|i| {
                // (64 px is plenty for an emoji and stays far under Discord's 256 KB)
                let small = image::imageops::resize(&*i, 64, 64, image::imageops::FilterType::Lanczos3);
                let mut out = std::io::Cursor::new(Vec::new());
                let _ = image::DynamicImage::ImageRgba8(small).write_to(&mut out, image::ImageFormat::Png);
                out.into_inner()
            }) else {
                continue;
            };
            let data = format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(png));
            match http.add_application_emoji(app, &name, &data).await {
                Ok(resp) => {
                    if let Ok(e) = resp.model().await {
                        have.insert(e.name, e.id);
                    }
                }
                Err(e) => eprintln!("emoji {name}: {e}"),
            }
        }
    }
    *EMOJI.lock().unwrap() = Some(have);
}

fn id(name: &str) -> Option<Id<EmojiMarker>> {
    EMOJI.lock().unwrap().as_ref()?.get(name).copied()
}

/// "<:name:id> " for message text, or "" when the bot doesn't have it.
pub fn tag(name: &str) -> String {
    id(name).map(|i| format!("<:{name}:{i}> ")).unwrap_or_default()
}

/// For a button.
pub fn button(name: &str) -> Option<EmojiReactionType> {
    id(name).map(|i| EmojiReactionType::Custom { animated: false, id: i, name: Some(name.to_string()) })
}

pub fn class_tag(class: &str) -> String {
    tag(&format!("cls_{}", class.to_lowercase()))
}
