// Demo data (a plain browser, no Tauri): made-up folders, releases, a character and raids, so every page can be
// looked at and clicked through. Nothing is installed or sent.
//
// ?state=
//   (none)    1.5.4 (every game inside DisasterZone) meets 1.5.5, the first release with game packs: the picker opens
//   updated   after that update: 1.5.5 with four games kept, up to date
//   ready     1.5.5 installed and 1.5.6 out: DisasterZone, Azeromon and Hold the Line change
//   updating  the same, and the update starts by itself and holds at 64% (screenshots)
// ?page=library|notes|backups|settings|game&arg=<game id>  opens a page (?tab=games|changelog still works)
// ?launcher=  the launcher's own update:
//   ready      a new launcher (0.5.1) is ready: the bar
//   tray       none at first; 5 s later the tray's check finds 0.5.1 (event "launcher-update")
//   fail       the launcher's check fails (Settings > About says why)
//   gate       the release needs a newer launcher and 0.5.1 is ready: the hero's "Update launcher"
//   gate-none  the release needs a newer launcher, none is found: "Get the launcher" (the releases page)
//   gate-fail  the same, and the launcher's check failed
// ?shot  leaves "demo" out of the rail (README screenshots)
"use strict";

function demoApi() {
  const MB = 1048576;
  const params = new URLSearchParams(location.search);
  const mode = params.get("state") || "";
  const later = mode === "ready" || mode === "updating" || mode === "checking";
  const updated = mode === "updated" || later;
  const NEW = later ? "1.5.6" : "1.5.5";
  const lmode = params.get("launcher") || "";
  const LAUNCHER = "0.5.0", NEW_LAUNCHER = "0.5.1";
  let launcherOut = ["ready", "gate"].includes(lmode);
  let launcherLog = null;
  const handlers = {};
  const emit = (ev, payload) => { for (const fn of handlers[ev] || []) fn({ payload }); };
  if (lmode === "tray") setTimeout(() => { launcherOut = true; emit("launcher-update", { version: NEW_LAUNCHER }); }, 5000);
  const settings = { wowRoot: "C:\\World of Warcraft", flavor: "_anniversary_", channel: "stable", seenSeq: {}, hold: false,
    keepBackups: 3, checkOnStart: true, source: null, launchCode: "", playCommand: "", tray: true, autoInstall: true, autostart: false,
    syncServer: "", syncUser: "", packs: {}, packsPicked: updated };
  // the release (sizes as measured on the dev PC); upd: MB that NEW changes in a copy already there
  const UPD = later ? { core: 6.1, azeromon: 41.7, holdtheline: 11.8 } : { core: 4.0 };
  const release = [
    ["core", "DisasterZone", "core", "DisasterZone", "Loot council, raid plans, guild members and games for <Casual Disaster>.", 48.0, 17.9, 512],
    ["rooms", "DisasterZone_Rooms", "extra", "3D rooms", "", 19.0, 13.6, 64],
    ["azeromon", "DisasterZone_Azeromon", "game", "Azeromon", "Tame and battle the beasts of Elwynn.", 146.0, 19.5, 2210],
    ["holdtheline", "DisasterZone_HoldTheLine", "game", "Hold the Line", "Fifteen minutes. One class. The whole Scourge.", 87.0, 20.4, 980],
    ["illidan", "DisasterZone_Illidan", "game", "The Binding of Illidan", "Five floors of the Black Temple, new every run.", 1.6, 0.4, 40],
    ["bingo", "DisasterZone_Bingo", "game", "Council Bingo", "Squares fill in as the raid happens.", 0.6, 0.1, 9],
    ["chess", "DisasterZone_Chess", "game", "Karazhan Chess", "Play Medivh's echo, or a guildmate.", 0.7, 0.1, 12],
    ["trainer", "DisasterZone_Trainer", "game", "Raid Trainer", "Practise each boss in 3D before the pull.", 0.8, 0.2, 14],
  ].map(([id, folder, kind, title, tagline, mb, gz, files]) => ({ id, folder, kind, title, tagline, required: kind === "core",
    defaultOn: kind !== "game", bytes: Math.round(mb * MB), gz: Math.round(gz * MB), files, upd: Math.round((UPD[id] || 0) * MB) }));
  const OLD_CORE = Math.round(232.5 * MB);  // (1.5.4 carries every game inside DisasterZone)
  // folder -> version on disk
  const kept = ["DisasterZone", "DisasterZone_Rooms", "DisasterZone_Azeromon", "DisasterZone_HoldTheLine", "DisasterZone_Bingo", "DisasterZone_Chess"];
  let disk = {};
  if (updated) for (const f of kept) disk[f] = "1.5.5";
  else disk = { DisasterZone: "1.5.4", DisasterZone_Rooms: "1.5.4" };
  if (updated) for (const p of release) if (p.kind === "game") settings.packs[p.id] = !!disk[p.folder];
  const now = Math.floor(Date.now() / 1000);
  const played = { azeromon: now - 2 * 86400, holdtheline: now - 5 * 3600, illidan: now - 9 * 86400, bingo: now - 86400 - 3600, chess: now - 3 * 3600 };
  const backups = [
    { id: stamp(now - 30 * 3600) + "-1.5.3", version: "1.5.3", build: "f60fe8911a371447", time: "", reason: "update", savedVariables: 3,
      folders: ["DisasterZone", "DisasterZone_Rooms"], added: [], bytes: Math.round(151 * MB), snap: { DisasterZone: "1.5.3", DisasterZone_Rooms: "1.5.3" } }];
  if (updated) {
    backups.unshift({ id: stamp(now - 4 * 3600) + "-1.5.5", version: "1.5.5", build: "2ed8abce9d654194", time: "", reason: "remove", savedVariables: 3,
      folders: ["DisasterZone_Trainer"], added: [], bytes: Math.round(0.8 * MB), snap: { ...disk, DisasterZone_Trainer: "1.5.5" } });
    backups.splice(1, 0, { id: stamp(now - 6 * 3600) + "-1.5.4", version: "1.5.4", build: "4ad16fd378c20fd2", time: "", reason: "update", savedVariables: 3,
      folders: ["DisasterZone", "DisasterZone_Rooms"], added: kept.slice(2), bytes: Math.round(251 * MB), snap: { DisasterZone: "1.5.4", DisasterZone_Rooms: "1.5.4" } });
  }
  // the real changelog of 1.5.5 (Data/Changelog.lua), a made-up 1.5.6 when it's out, and earlier releases from a
  // published manifest (demo-notes.json)
  const notes = { changelog: [NOTES_155], htlWeekly: ["The Hardest Line", "Frost and Fire", "One Spell", "Glass Cannon", "Light's Chosen", "The Hundred Club", "Quarter Rush", "Dance Night"] };
  if (later) notes.changelog.unshift(NOTES_156);
  const notesReady = fetch("demo-notes.json").then((r) => r.json()).then((n) => { notes.changelog.push(...n.changelog); }).catch(() => {});
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  let demoSync = { linked: true, user: "Tsumil", server: "https://bot.example", last: now - 180, waiting: 0, error: null };

  const buildOf = (v) => ({ "1.5.6": "9b1e77c2d4a0f311", "1.5.5": "2ed8abce9d654194" }[v] || "4ad16fd3a1b2c3d4");
  const wanted = (p) => p.required || (settings.packs[p.id] ?? (p.defaultOn || !!disk[p.folder]));
  const action = (p) => (wanted(p)
    ? (!disk[p.folder] ? "install" : disk[p.folder] !== NEW && (p.kind === "core" || p.upd) ? "update" : "same")
    : (disk[p.folder] ? "remove" : ""));
  const diskBytes = (p) => (!disk[p.folder] ? 0 : p.id === "core" && disk[p.folder] === "1.5.4" ? OLD_CORE : p.bytes);
  const download = (p) => ({ install: p.gz, update: p.upd }[action(p)] || 0);
  function stamp(t) {
    const d = new Date(t * 1000), z = (n, w = 2) => String(n).padStart(w, "0");
    return d.getUTCFullYear() + z(d.getUTCMonth() + 1) + z(d.getUTCDate()) + "-" + z(d.getUTCHours()) + z(d.getUTCMinutes()) +
      z(d.getUTCSeconds()) + "." + z(d.getUTCMilliseconds(), 3);
  }
  const backup = (reason, folders, added) => {
    backups.unshift({ id: stamp(Date.now() / 1000) + "-" + disk.DisasterZone, version: disk.DisasterZone, build: buildOf(disk.DisasterZone), time: "", reason,
      savedVariables: 3, folders, added, snap: { ...disk },
      bytes: folders.reduce((n, f) => n + diskBytes(release.find((p) => p.folder === f)), 0) });
    backups.splice(settings.keepBackups + 1);
    return backups[0].id;
  };
  const installedNow = () => ({ present: !!disk.DisasterZone, version: disk.DisasterZone, build: buildOf(disk.DisasterZone), assetPack: 16,
    dev: false, linked: false, rooms: !!disk.DisasterZone_Rooms,
    packs: release.filter((p) => p.kind !== "core" && disk[p.folder]).map((p) => ({ id: p.id, folder: p.folder, kind: p.kind, title: p.title, linked: false })) });

  // the guild's raids: Serpentshrine on the next Thursday at 19:30, Black Temple the Sunday after
  const at = (weekday, hour, min, plusDays) => {
    const d = new Date();
    d.setHours(hour, min, 0, 0);
    d.setDate(d.getDate() + ((weekday - d.getDay() + 7) % 7 || (d.getTime() < Date.now() ? 7 : 0)) + (plusDays || 0));
    return Math.floor(d.getTime() / 1000);
  };
  const su = (key, st, cls, spec, role) => ({ key: key + "-Thunderstrike", st, class: cls, spec, role, at: now - 86400, rev: 1 });
  const ssc = [su("Lee", "accept", "WARRIOR", "Protection", "tank"), su("Bob", "accept", "PALADIN", "Protection", "tank"), su("Gina", "accept", "DRUID", "Feral", "tank"),
    ...["Rita", "Moss", "Cedric", "Ivy", "Hal", "Nell"].map((n) => su(n, "accept", "PRIEST", "Holy", "healer")),
    su("Tsumil", "accept", "PALADIN", "Retribution", "melee"),
    ...["Orin", "Vex", "Kael", "Dusk", "Brin", "Wren", "Pike", "Sable"].map((n, i) => su(n, i === 7 ? "tentative" : "accept", "MAGE", "Fire", "ranged"))];
  const raids = [
    { id: "demo-ssc", t: at(4, 19, 30), name: "Serpentshrine Cavern", inst: "ssc", size: 25, teams: ["main"], need: { tank: 3, heal: 6, dps: 16 }, signups: ssc },
    { id: "demo-bt", t: at(0, 19, 0, 7), name: "Black Temple", inst: "bt", size: 25, teams: ["main"], signups: ssc.slice(0, 9) },
  ];

  return {
    async invoke(cmd, args) {
      await wait(200);
      switch (cmd) {
        case "status": return { settings: { ...settings, packs: { ...settings.packs } }, installs: [{ root: settings.wowRoot, flavors: ["_anniversary_", "_classic_era_", "_retail_"] }],
          installed: installedNow(), flavorDir: settings.wowRoot + "\\" + settings.flavor, wowRunning: false, launcherVersion: LAUNCHER,
          launcherCheck: launcherLog, source: "https://raw.githubusercontent.com/tsumilo/DisasterZone-releases/main/" };
        case "player": return { character: { name: "Tsumil", realm: "Thunderstrike", key: "Tsumil-Thunderstrike", class: "PALADIN", spec: "Retribution", at: now - 3 * 3600 },
          region: "EU", mine: ["Tsumil-Thunderstrike", "Ussyp-Thunderstrike"], raids, snapAt: now - 3 * 3600 };
        case "check": {
          await notesReady;
          if (mode === "loading") await new Promise(() => {});   // (the release list never comes: placeholders)
          if (lmode.startsWith("gate")) throw "this release needs a newer launcher: download the newest launcher";
          const packs = release.map((p) => ({ id: p.id, folder: p.folder, kind: p.kind, title: p.title, tagline: p.tagline, required: p.required,
            defaultOn: p.defaultOn, installed: !!disk[p.folder], wanted: wanted(p), chosen: settings.packs[p.id] ?? null, action: action(p),
            files: p.files, changed: { install: p.files, update: p.id === "core" ? 38 : p.id === "azeromon" ? 212 : 19 }[action(p)] || 0,
            bytes: p.bytes, gz: p.gz, downloadBytes: download(p), diskBytes: diskBytes(p), played: played[p.id] ?? null }));
          const busy = packs.filter((p) => p.action === "install" || p.action === "update");
          return { version: NEW, build: buildOf(NEW), seq: 14, channel: settings.channel, assetPack: 16, published: "2026-10-17T18:00:00Z",
            notes, files: release.reduce((n, p) => n + p.files, 0), changed: busy.reduce((n, p) => n + (p.action === "install" ? p.files : 23), 0),
            removed: 0, downloadBytes: packs.reduce((n, p) => n + p.downloadBytes, 0), upToDate: packs.every((p) => p.action === "same" || p.action === ""),
            older: false, hold: settings.hold, zipUrl: null, packs, needsPick: !settings.packsPicked, keyId: "fc3c952963e8f5bf" };
        }
        case "update": {
          // every folder's share fetched in turns, the speed wandering like a real line
          const parts = release.filter((p) => download(p) > 0).map((p) => ({ folder: p.folder, of: download(p), got: 0 }));
          const total = parts.reduce((n, x) => n + x.of, 0);
          let done = 0, tick = 0;
          emit("progress", { step: "download", done: 0, total, folderDone: 0, folderTotal: 0 });
          for (const x of parts) emit("progress", { step: "download", done: 0, total, folder: x.folder, folderDone: 0, folderTotal: x.of });
          for (;;) {
            const open = parts.filter((x) => x.got < x.of);
            if (!open.length) break;
            const x = open[tick % open.length];
            const rate = (11 + 6 * Math.sin(tick / 3) + 3 * Math.sin(tick * 1.7)) * MB * 0.12;
            x.got = Math.min(x.of, x.got + Math.max(64 * 1024, Math.round(rate)));
            done = parts.reduce((n, y) => n + y.got, 0);
            tick++;
            emit("progress", { step: "download", done, total, folder: x.folder, folderDone: x.got, folderTotal: x.of });
            if (mode === "updating" && done / total >= 0.64) await new Promise(() => {});   // (holds here for screenshots)
            await wait(120);
          }
          const put = release.filter((q) => ["install", "update"].includes(action(q)));
          for (const [k, p] of put.entries()) {
            for (let i = 1; i <= 4; i++) {
              emit("progress", { step: "stage", done: k * 4 + i, total: put.length * 4, folder: p.folder, folderDone: Math.round((p.files * i) / 4), folderTotal: p.files });
              if (mode === "checking" && k === 1 && i === 2) await new Promise(() => {});   // (holds half way through the check)
              await wait(90);
            }
          }
          emit("progress", { step: "backup", done: 0, total: 1, folderDone: 0 });
          await wait(450);
          emit("progress", { step: "swap", done: 0, total: 1, folderDone: 0 });
          await wait(350);
          const moves = release.map((p) => ({ folder: p.folder, action: action(p) })).filter((m) => m.action && m.action !== "same");
          const id = backup("update", moves.filter((m) => m.action !== "install").map((m) => m.folder), moves.filter((m) => m.action === "install").map((m) => m.folder));
          for (const m of moves) { if (m.action === "remove") delete disk[m.folder]; else disk[m.folder] = NEW; }
          settings.hold = false;
          return { version: NEW, downloaded: total, changed: 23, removed: 0, backup: id, folders: moves };
        }
        case "set_packs": Object.assign(settings.packs, args.packs); if (args.picked != null) settings.packsPicked = args.picked; return { ...settings };
        case "remove_pack": {
          const p = release.find((x) => x.id === args.id);
          let id = null;
          if (p && disk[p.folder]) { id = backup("remove", [p.folder], []); delete disk[p.folder]; }
          settings.packs[args.id] = false;
          return id;
        }
        case "backups": return backups.slice();
        case "backup_now": {
          await wait(900);
          const id = backup("manual", Object.keys(disk).sort(), []);
          return id;
        }
        case "restore": {
          const b = backups.find((x) => x.id === args.id);
          backup("restore", Object.keys(disk), Object.keys(b.snap).filter((f) => !disk[f]));
          disk = { ...b.snap };
          for (const p of release) if (p.kind !== "core" && disk[p.folder]) settings.packs[p.id] = true;
          settings.hold = true;
          return null;
        }
        case "set_settings": for (const k in args) if (args[k] != null) settings[k] = args[k]; return { ...settings };
        case "set_wow_path": if (args.flavor) settings.flavor = args.flavor; return { ...settings };
        case "sync_status": return { ...demoSync };
        case "sync_link":
          if (args.code.toUpperCase() !== "DEMO1234") throw "That code is unknown or older than 15 minutes: type /launcher in Discord for a new one. (Demo: DEMO1234)";
          demoSync = { ...demoSync, linked: true, user: "Tsumil", last: Math.floor(Date.now() / 1000), waiting: 2 };
          return { ...demoSync };
        case "sync_run": demoSync.last = Math.floor(Date.now() / 1000); return { ...demoSync };
        case "sync_unlink": demoSync = { ...demoSync, linked: false, user: "", last: null, waiting: 0 }; return { ...demoSync };
        case "play": throw "Demo: Play would start Battle.net here.";
        case "open_folder": throw "Demo: this would open " + (args.folder || args.kind || "the folder") + ".";
        case "open_releases": throw "Demo: this would open https://github.com/tsumilo/DisasterZone-releases/releases/latest.";
        case "launcher_checked":
          launcherLog = { at: Math.floor(Date.now() / 1000), found: args.found, error: args.error && args.error.split("\n")[0].slice(0, 160) };
          return { ...launcherLog };
      }
      throw "unknown command " + cmd;
    },
    async listen(ev, fn) { (handlers[ev] = handlers[ev] || []).push(fn); },
    async launcherCheck() {
      await wait(600);
      if (lmode === "fail" || lmode === "gate-fail") {
        throw "error sending request for url (https://github.com/tsumilo/DisasterZone-releases/releases/download/launcher-latest/latest.json)";
      }
      return launcherOut ? { version: NEW_LAUNCHER } : null;
    },
    async launcherInstall(upd, onEvent) {
      const total = Math.round(9.4 * MB);
      onEvent({ event: "Started", data: { contentLength: total } });
      for (let i = 1; i <= 20; i++) { await wait(120); onEvent({ event: "Progress", data: { chunkLength: total / 20 } }); }
      onEvent({ event: "Finished" });
      toast("Demo: launcher " + upd.version + " would install and restart here.", true);
      await new Promise(() => {});   // (the real window goes away now)
    },
    async pickFolder() { return null; },
    minimize() {},
    maximize() {},
    close() {},
  };
}

// 1.5.5's real changelog (Data/Changelog.lua), as release.py puts it in the notes.
const NOTES_155 = { version: "1.5.5", date: "17 October 2026", title: "Hold the Line, Naxxramas and fixes from the raid", sections: [
  { heading: "Hold the Line", area: "games", kind: "new", lead: "A survivors game: hold the Eastern Plaguelands against the Scourge for 15 minutes.", lines: [
    "Paladin, Mage or Warrior, each with its own spells; blessings and gadgets on level-ups.",
    "Bosses on the clock, coffers with legendary weapons, and the Pale Rider at 15:00.",
    "Talents bought with the gold you bank, achievements and the Argent Dawn's thanks.",
    "A guild board, and a weekly challenge with one seed for everyone. /dz htl opens it."] },
  { heading: "Naxxramas", area: "games", kind: "new", lead: "Win once and the necropolis opens: four quarters and the Frostwyrm Lair.", lines: [
    "Every boss with its own abilities: Heigan's dance, Thaddius's polarity, Frost Breath.",
    "Each quarter has its own floor: webs, plague clouds, rider lanes or slime pools.",
    "Kill the quarter's master to clear it; all four cleared opens the Frostwyrm Lair.",
    "Boss coffers offer a relic for the run; Kel'Thuzad's legendaries after his first fall.",
    "Desecrated tokens make the Tier 3 sets: small bonuses, and the look at nine pieces.",
    "Frozen Runes buy Frost Resistance from Craftsman Wilhelm, against the lair's Chill."] },
  { heading: "Azeromon: battles you can see", area: "games", kind: "changed", lead: "Beasts are pixel art now, battles have a plan, and every move plays its own effect.", lines: [
    "Strong moves rest, setup marks pay off in combos, big casts land next turn: guard them.",
    "Six moves per type and each beast's own signatures; a coach helps until your first badge.",
    "Claws rake, waves roll, sawblades grind: every move and every boss cast has an effect.",
    "Taming is a moment: a sigil, an orb that rocks for every check, and a card for your beast.",
    "Every beast is pixel art made from its own model and sized by strength (or keep 3D).",
    "Guildmates no longer vanish at doors or while they fight in WoW.",
    "Sharper trees, ores and props, with real shadows; Stranglethorn is a deeper green."] },
  { heading: "Every game is its own install", area: "games", kind: "changed", lead: "Each game is an addon folder of its own now: keep only the ones you play.", lines: [
    "The DisasterZone launcher's Games tab installs and removes them one at a time.",
    "Without the launcher: copy the DisasterZone_<Game> folders you want from the zip.",
    "Updating by hand? Delete the old DisasterZone folder first: the game art moved out.",
    "A game you don't have still has a poster saying how to get it. Progress is kept."] },
  { heading: "Errors report themselves", area: "other", kind: "new", lead: "When DisasterZone hits a Lua error, a bug report goes to the developer by itself.", lines: [
    "DisasterZone's errors no longer show in the game's error window or in BugSack.",
    "It carries the error and what was going on: the page open, your group, your last steps.",
    "Somebody already reported the same error? You're added to theirs as a me too.",
    "Add details on the pop-up opens your report, to say what you were doing.",
    "Settings > Alerts > More options: Report errors by themselves turns it off."] },
  { heading: "Nameplates while levelling", area: "look", kind: "changed", lead: "", lines: [
    { text: "A mob someone outside your group tagged first gets a grey bar: no loot for you.", for: "", by: ["Vicnado"] },
    { text: "The level shows in the game's colours: grey, green, yellow, orange or red.", for: "", by: ["Vicnado"] },
    "Halo and Slate show the level now too. Settings > Nameplates turns both off."] },
  { heading: "Recruitment", area: "guild", kind: "new", lead: "", lines: [
    { text: "Keep several recruitment messages and swap between them on Message.", for: "gm officers", by: ["Vicnado"] },
    { text: "Someone who joins through another officer's invite is marked Joined by itself.", for: "gm officers", by: ["Vicnado"] },
    { text: "Joined the guild on a person's ··· menu marks it by hand, with their team.", for: "gm officers" },
    { text: "Move to another character: an alt who came first hands their story to the main.", for: "gm officers" }] },
  { heading: "Mains for everyone", area: "guild", kind: "new", lead: "", lines: [
    { text: "Officers set the main and alts of members who don't run DisasterZone.", for: "", by: ["Vicnado"] },
    "Members who run it still pick their own, and their choice wins once they install it."] },
  { heading: "Meters", area: "raids", kind: "changed", lead: "", lines: [
    { text: "Tanking, you're in your own threat meter: on top while you hold aggro.", for: "", by: ["Vicnado"] },
    { text: "Profiles keep the meters' look and setup too, and each character's meter places.", for: "", by: ["Vicnado"] }] },
  { heading: "Fixes", area: "fixes", kind: "fixed", lead: "", lines: [
    { text: "Fiery Weapon and other procs no longer show the game's placeholder face.", for: "", by: ["Vicnado"] },
    "Falling, drowning, lava and fatigue damage each get their own icon.",
    { text: "The bag sort moves a few items at a time, so no stack stays stuck and greyed.", for: "", by: ["Vicnado"] }] },
] };

// A made-up next release for ?state=ready and ?state=updating.
const NOTES_156 = { version: "1.5.6", date: "24 October 2026", title: "Small fixes from the raid", sections: [
  { heading: "Hold the Line: the Frostwyrm Lair", area: "games", kind: "changed", lead: "Sapphiron's Frost Breath warns a beat earlier, and Chill stacks fade between waves.", lines: [
    "Demo text: this release only exists in the launcher's demo."] },
  { heading: "Azeromon: Blackrock caves", area: "games", kind: "changed", lead: "Cave floors are darker and the lava glows.", lines: ["Demo text."] },
  { heading: "Fixes", area: "fixes", kind: "fixed", lead: "", lines: ["Demo text."] },
] };
