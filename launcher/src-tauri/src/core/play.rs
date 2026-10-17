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
use std::path::{Path, PathBuf};
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

/// The game folder's program, the one Battle.net starts (Retail's is Wow.exe, the Classic versions' WowClassic.exe).
pub fn game_exe(flavor_dir: &Path, flavor: &str) -> Option<PathBuf> {
    let names = if flavor == "_retail_" { ["Wow.exe", "WowClassic.exe"] } else { ["WowClassic.exe", "Wow.exe"] };
    names.iter().map(|n| flavor_dir.join(n)).find(|p| p.is_file())
}

/// The arguments Battle.net starts a version with, when its logs don't say (the ones it used for Anniversary).
pub fn default_args(flavor: &str) -> Option<Vec<String>> {
    let uid = battlenet_uid(flavor)?;
    let mut args = vec!["-launcherlogin".to_string()];
    if flavor == "_anniversary_" {
        args.push("-initialgamemode=bccfresh".into());
    }
    args.extend(["-uid".to_string(), uid.to_string()]);
    Some(args)
}

/// What Battle.net started this game folder's program with the last time, from its logs (%LOCALAPPDATA%\Battle.net\
/// Logs, newest first): "Launched C:/World of Warcraft/_anniversary_/WoWClassic.exe with args: -launcherlogin
/// -initialgamemode=bccfresh -uid wow_classic_anniversary, pid: 37452". Only plain switches are taken (the sign-in
/// itself never goes on the command line: the game asks the running Battle.net for it).
pub fn last_battlenet_launch(logs_dir: &Path, flavor_dir: &Path) -> Option<(PathBuf, Vec<String>)> {
    let mut logs: Vec<PathBuf> = std::fs::read_dir(logs_dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.file_name().map(|n| n.to_string_lossy().starts_with("battle.net-")).unwrap_or(false))
        .collect();
    logs.sort();
    for log in logs.iter().rev().take(12) {
        let Ok(data) = std::fs::read(log) else { continue };
        let text = String::from_utf8_lossy(&data);
        for line in text.lines().rev() {
            let Some(rest) = line.split("} Launched ").nth(1) else { continue };
            let Some((exe, rest)) = rest.split_once(" with args: ") else { continue };
            let args_text = rest.rsplit_once(", pid:").map(|(a, _)| a).unwrap_or(rest);
            let exe = PathBuf::from(exe.trim());
            if !super::wow::in_folder(&exe, flavor_dir) {
                continue;
            }
            let args: Vec<String> = args_text.split_whitespace().map(str::to_string).collect();
            let plain = |a: &String| a.starts_with('-') && a.chars().all(|c| c.is_ascii_alphanumeric() || "-_=.".contains(c));
            let uid_ok = |a: &String| a.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
            if !args.is_empty() && args.iter().enumerate().all(|(i, a)| plain(a) || (i > 0 && args[i - 1] == "-uid" && uid_ok(a))) {
                return Some((exe, args));
            }
            return None;
        }
    }
    None
}

#[cfg(windows)]
fn battlenet_running() -> bool {
    let sys = sysinfo::System::new_with_specifics(
        sysinfo::RefreshKind::nothing().with_processes(sysinfo::ProcessRefreshKind::nothing()),
    );
    sys.processes().values().any(|p| p.name().to_string_lossy().eq_ignore_ascii_case("battle.net.exe"))
}

/// Play. What it did: "focused" (the game of this folder was running: its window came to the front), "running" (it
/// runs but has no window to show yet), "command" (the Play command from Settings ran), "started" (the game itself,
/// the way Battle.net starts it, while Battle.net runs to sign it in), "launched" (Battle.net was asked to show the
/// game: press its Play) or "opened" (Battle.net opened: no version known).
///
/// Battle.net 2.53 starts no game for another program: --exec="launch WoWC", --exec="launch_uid <uid>" and the game
/// folder's "World of Warcraft Launcher.exe --productcode=" only select it, and battlenet:// links that launch need a
/// token Blizzard signs. What Battle.net does itself on Play is run the game's program with -launcherlogin; the game
/// then signs in through the running Battle.net. Play does the same.
pub fn play(s: &Settings) -> Result<&'static str> {
    if let Some(pid) = s.flavor_dir().and_then(|d| super::wow::game_process(&d)) {
        return Ok(if super::wow::bring_to_front(pid) { "focused" } else { "running" });
    }
    #[cfg(windows)]
    if s.play_command.trim().is_empty() && battlenet_running() {
        if let Some(dir) = s.flavor_dir() {
            let logs = dirs::data_local_dir().map(|d| d.join("Battle.net").join("Logs"));
            let found = logs
                .and_then(|l| last_battlenet_launch(&l, &dir))
                .filter(|(exe, _)| exe.is_file())
                .or_else(|| Some((game_exe(&dir, &s.flavor)?, default_args(&s.flavor)?)));
            if let Some((exe, args)) = found {
                let mut c = Command::new(exe);
                c.args(args).current_dir(&dir);
                return spawn(c).map(|_| "started");
            }
        }
    }
    let custom = s.play_command.trim();
    if !custom.is_empty() {
        #[cfg(windows)]
        {
            let mut c = Command::new("cmd");
            c.args(["/C", custom]);
            return spawn(c).map(|_| "command");
        }
        #[cfg(not(windows))]
        {
            let mut c = Command::new("sh");
            c.args(["-c", custom]);
            return spawn(c).map(|_| "command");
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
        let what = if exec.is_some() { "launched" } else { "opened" };
        if let Some(exec) = exec {
            c.arg(format!("--exec={exec}"));
        }
        return spawn(c).map(|_| what);
    }
    #[cfg(target_os = "macos")]
    {
        let mut c = Command::new("open");
        c.args(["-a", "Battle.net"]);
        let what = if exec.is_some() { "launched" } else { "opened" };
        if let Some(exec) = exec {
            c.args(["--args", &format!("--exec={exec}")]);
        }
        return spawn(c).map(|_| what);
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
    fn the_arguments_battle_net_used_last_come_from_its_logs() {
        let tmp = tempfile::tempdir().unwrap();
        let logs = tmp.path();
        std::fs::write(logs.join("battle.net-20261015T072146.700424.log"),
            "I 2026-10-17 13:19:23.794671 [InstallManager] {Main} Launched C:/World of Warcraft/_anniversary_/WoWClassic.exe with args: -launcherlogin -initialgamemode=bccfresh -uid wow_classic_anniversary, pid: 37452\n\
             I 2026-10-17 14:00:00.000000 [InstallManager] {Main} Launched C:/World of Warcraft/_classic_era_/WowClassic.exe with args: -launcherlogin -uid wow_classic_era, pid: 1\n").unwrap();
        std::fs::write(logs.join("battle.net-20261017T214706.528760.log"), "I [Main] {Main} Command line arguments: {[0]=--exec=launch WoWC}\n").unwrap();
        std::fs::write(logs.join("other.log"), "] Launched C:/World of Warcraft/_anniversary_/WoWClassic.exe with args: -evil, pid: 2\n").unwrap();
        let ann = Path::new("C:/World of Warcraft/_anniversary_");
        let (exe, args) = last_battlenet_launch(logs, ann).unwrap();
        assert_eq!(exe, PathBuf::from("C:/World of Warcraft/_anniversary_/WoWClassic.exe"));
        assert_eq!(args, ["-launcherlogin", "-initialgamemode=bccfresh", "-uid", "wow_classic_anniversary"]);
        let (_, era) = last_battlenet_launch(logs, Path::new("C:\\World of Warcraft\\_classic_era_")).unwrap();
        assert_eq!(era, ["-launcherlogin", "-uid", "wow_classic_era"]);
        assert!(last_battlenet_launch(logs, Path::new("C:/World of Warcraft/_retail_")).is_none());
        // (anything but plain switches: not taken)
        std::fs::write(logs.join("battle.net-20261018T000000.000000.log"),
            "I [InstallManager] {Main} Launched C:/World of Warcraft/_anniversary_/WoWClassic.exe with args: -launcherlogin & calc.exe, pid: 3\n").unwrap();
        assert!(last_battlenet_launch(logs, ann).is_none());
        assert!(last_battlenet_launch(&tmp.path().join("nope"), ann).is_none());
    }

    #[test]
    fn without_logs_the_arguments_of_anniversary() {
        assert_eq!(default_args("_anniversary_").unwrap(), ["-launcherlogin", "-initialgamemode=bccfresh", "-uid", "wow_classic_anniversary"]);
        assert_eq!(default_args("_classic_era_").unwrap(), ["-launcherlogin", "-uid", "wow_classic_era"]);
        assert!(default_args("_unknown_").is_none());
        let tmp = tempfile::tempdir().unwrap();
        assert!(game_exe(tmp.path(), "_anniversary_").is_none());
        std::fs::write(tmp.path().join("WowClassic.exe"), "").unwrap();
        assert_eq!(game_exe(tmp.path(), "_anniversary_"), Some(tmp.path().join("WowClassic.exe")));
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
