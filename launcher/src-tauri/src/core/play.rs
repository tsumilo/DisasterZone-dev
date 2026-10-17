//! The Play button: start the game through Battle.net (WoW refuses to start without it), or run the user's own
//! command (Linux: Lutris, Bottles, Steam...).
//!
//! Battle.net takes `--exec="<command>"`: `launch <family>` (WoW, WoWC: the version its menu has picked) or
//! `launch_uid <uid>` (one exact version). Play asks for the game folder's own version by its uid, the ids Battle.net
//! keeps in %APPDATA%\Battle.net\Battle.net.config ("Games"), so Anniversary starts even while the menu shows Classic
//! Era. Battle.net's logs (%LOCALAPPDATA%\Battle.net\Logs) show what it did with a request.

#[allow(unused_imports)]
use super::error::{msg, Error, Result};
use super::state::Settings;
use std::process::Command;

fn spawn(mut cmd: Command) -> Result<()> {
    cmd.spawn().map(|_| ()).map_err(|e| Error::Msg(format!("could not start the game: {e}")))
}

/// Battle.net's id for the game version a folder holds.
pub fn battlenet_uid(flavor: &str) -> Option<&'static str> {
    match flavor {
        "_retail_" => Some("wow"),
        "_classic_" => Some("wow_classic"),
        "_classic_era_" => Some("wow_classic_era"),
        "_anniversary_" => Some("wow_classic_anniversary"),
        "_ptr_" => Some("wow_ptr"),
        "_classic_ptr_" => Some("wow_classic_ptr"),
        "_beta_" => Some("wow_beta"),
        _ => None,
    }
}

/// What Play asks Battle.net to do: the launch code from Settings when there is one (a family such as WoWC, or a
/// whole command such as "launch_uid wow_classic_era"), else the game folder's version by its uid. None: no version
/// known, Battle.net just opens.
pub fn exec_command(launch_code: &str, flavor: &str) -> Option<String> {
    let words: Vec<&str> = launch_code.split_whitespace().collect();
    match words.first().map(|w| w.to_ascii_lowercase()) {
        // ("launch WoWC" typed whole: launcher 0.4 made that "launch launch WoWC", which Battle.net ignores)
        Some(w) if (w == "launch" || w == "launch_uid") && words.len() > 1 => Some(words.join(" ")),
        Some(_) => Some(format!("launch {}", words.join(" "))),
        None => battlenet_uid(flavor).map(|uid| format!("launch_uid {uid}")),
    }
}

pub fn play(s: &Settings) -> Result<()> {
    let custom = s.play_command.trim();
    if !custom.is_empty() {
        #[cfg(windows)]
        {
            let mut c = Command::new("cmd");
            c.args(["/C", custom]);
            return spawn(c);
        }
        #[cfg(not(windows))]
        {
            let mut c = Command::new("sh");
            c.args(["-c", custom]);
            return spawn(c);
        }
    }
    let exec = exec_command(&s.launch_code, &s.flavor);
    #[cfg(windows)]
    {
        let mut found = None;
        for base in [std::env::var("ProgramFiles(x86)").ok(), std::env::var("ProgramFiles").ok()].into_iter().flatten() {
            for exe in ["Battle.net\\Battle.net Launcher.exe", "Battle.net\\Battle.net.exe"] {
                let p = std::path::Path::new(&base).join(exe);
                if p.is_file() && found.is_none() {
                    found = Some(p);
                }
            }
        }
        let Some(exe) = found else {
            return msg("Battle.net was not found: start the game from Battle.net yourself, or set a Play command in Settings");
        };
        let mut c = Command::new(exe);
        if let Some(exec) = exec {
            c.arg(format!("--exec={exec}"));
        }
        return spawn(c);
    }
    #[cfg(target_os = "macos")]
    {
        let mut c = Command::new("open");
        c.args(["-a", "Battle.net"]);
        if let Some(exec) = exec {
            c.args(["--args", &format!("--exec={exec}")]);
        }
        return spawn(c);
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let _ = exec;
        msg("set a Play command in Settings (for example: lutris lutris:rungame/battlenet)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_game_folders_version_by_its_uid() {
        assert_eq!(exec_command("", "_anniversary_").as_deref(), Some("launch_uid wow_classic_anniversary"));
        assert_eq!(exec_command("  ", "_classic_era_").as_deref(), Some("launch_uid wow_classic_era"));
        assert_eq!(exec_command("", "_retail_").as_deref(), Some("launch_uid wow"));
        assert_eq!(exec_command("", "_something_new_"), None);
    }

    #[test]
    fn a_launch_code_from_settings_wins() {
        assert_eq!(exec_command("WoWC", "_anniversary_").as_deref(), Some("launch WoWC"));
        // (typed as a whole command: not doubled)
        assert_eq!(exec_command("launch WoWC", "_anniversary_").as_deref(), Some("launch WoWC"));
        assert_eq!(exec_command("  Launch   WoWC ", "_anniversary_").as_deref(), Some("Launch WoWC"));
        assert_eq!(exec_command("launch_uid wow_classic_era", "_anniversary_").as_deref(), Some("launch_uid wow_classic_era"));
        assert_eq!(exec_command("launch", "_anniversary_").as_deref(), Some("launch launch"));
    }
}
