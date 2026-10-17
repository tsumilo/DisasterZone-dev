// DisasterZone Launcher window: the data, the pages' navigation, updates and the launcher's own update. Talks to the
// Rust side (src-tauri/src/lib.rs) through Tauri commands. Opened outside Tauri (a plain browser), it runs on made-up
// demo data (demo.js) so the pages can be previewed: nothing is installed or sent.
"use strict";

const T = window.__TAURI__;
const DEMO = !T;
const api = DEMO ? demoApi() : {
  invoke: (cmd, args) => T.core.invoke(cmd, args),
  listen: (ev, fn) => T.event.listen(ev, fn),
  pickFolder: () => T.dialog.open({ directory: true, title: "Your World of Warcraft folder" }),
  minimize: () => T.window.getCurrentWindow().minimize(),
  maximize: () => T.window.getCurrentWindow().toggleMaximize(),
  close: () => T.window.getCurrentWindow().close(),
  // the launcher's own update (tauri-plugin-updater): an Update or null
  launcherCheck: () => (T.updater ? T.updater.check() : Promise.reject("the updater isn't loaded in this window")),
  launcherInstall: async (upd, onEvent) => { await upd.downloadAndInstall(onEvent); await T.process.relaunch(); },
};

const RECHECK_MS = 30 * 60 * 1000;

let status = null;     // status command
let check = null;      // check command (newest release vs installed)
let checkErr = null;
let checkedAt = 0;     // (ms) when the last check came back
let checking = false;
let working = false;
let updating = false;  // (working on an update: Home shows its progress)
let player = { character: null, region: null, mine: [], raids: [], snapAt: null };

// ---------------------------------------------------------------------------------------------------------------
// Toast + confirm
// ---------------------------------------------------------------------------------------------------------------

let toastTimer = null;
function toast(text, good) {
  const t = $("toast");
  t.textContent = String(text);
  t.className = "toast" + (good ? " good" : "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add("hidden"), good ? 4000 : 8000);
}
function confirmBox(title, body, okText, danger) {
  return new Promise((resolve) => {
    $("m-title").textContent = title;
    $("m-body").textContent = body;
    const ok = $("m-ok");
    ok.textContent = okText;
    ok.className = "btn lg " + (danger ? "danger" : "gold");
    $("modal").classList.remove("hidden");
    const done = (v) => { $("modal").classList.add("hidden"); ok.onclick = null; $("m-cancel").onclick = null; resolve(v); };
    ok.onclick = () => done(true);
    $("m-cancel").onclick = () => done(false);
  });
}

// ---------------------------------------------------------------------------------------------------------------
// Pages: home, library, game (arg: pack id), notes (arg: version), backups, settings (arg: section). Back and
// forward walk the pages seen, like a browser.
// ---------------------------------------------------------------------------------------------------------------

const navHist = { stack: [{ page: "home", arg: null }], at: 0 };
function here() { return navHist.stack[navHist.at]; }

function go(page, arg) {
  const cur = here();
  if (cur.page === page && (cur.arg || null) === (arg || null)) { showPage(page, arg); return; }
  navHist.stack = navHist.stack.slice(0, navHist.at + 1);
  navHist.stack.push({ page, arg: arg || null });
  if (navHist.stack.length > 60) navHist.stack.shift();
  navHist.at = navHist.stack.length - 1;
  showPage(page, arg);
}
function goBack() { if (navHist.at > 0) { navHist.at--; showPage(here().page, here().arg); } }
function goForward() { if (navHist.at < navHist.stack.length - 1) { navHist.at++; showPage(here().page, here().arg); } }

function showPage(page, arg) {
  for (const p of document.querySelectorAll(".page")) p.classList.toggle("active", p.id === "page-" + page);
  for (const b of document.querySelectorAll(".nav [data-go]")) b.classList.toggle("on", b.dataset.go === page);
  for (const b of document.querySelectorAll(".foot [data-go]")) b.classList.toggle("on", b.dataset.go === page);
  $("nav-back").disabled = navHist.at === 0;
  $("nav-fwd").disabled = navHist.at >= navHist.stack.length - 1;
  renderRail();
  if (page === "library") {
    renderLibrary();
    $("games-new").classList.add("hidden");
    try { localStorage.setItem("dz.gamesSeen", "1"); } catch (e) { /* (the badge just shows again) */ }
  }
  if (page === "game") renderGame(arg);
  if (page === "notes") openNotes(arg);
  if (page === "backups") renderBackups();
  if (page === "settings") { renderSettings(); if (arg) showSection(arg); settingsSpy(); }
}

// ---------------------------------------------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------------------------------------------

async function loadStatus() {
  status = await api.invoke("status");
  renderChrome();
  renderSettings();
  renderAll();
}

// The character played last, the region, the guild's next raids (the game's own files; nothing found is fine).
async function loadPlayer() {
  try { player = await api.invoke("player"); } catch (e) { /* (no game folder yet) */ }
  renderMe();
  renderRaid();
  if (here().page === "game") renderGame(here().arg);
}

async function runCheck() {
  if (!status || !status.flavorDir || working) { renderHero(); return; }
  checking = true;
  $("btn-check").classList.add("spin");
  renderHero();
  try {
    check = await api.invoke("check");
    checkErr = null;
    checkedAt = Date.now();
  } catch (e) {
    check = null;
    checkErr = String(e);
    if (needsNewLauncher()) checkLauncherUpdate();   // (the hero's button then updates the launcher)
  }
  checking = false;
  $("btn-check").classList.remove("spin");
  renderAll();
  // the first release with game packs: ask once per start which games to keep (Update asks again if dismissed)
  if (check && check.needsPick && !check.upToDate && !pickerAsked && !working && !devCopy()) {
    pickerAsked = true;
    openPicker({});
  }
}

async function refreshAll() {
  await loadStatus();
  await runCheck();
  if (here().page === "backups") renderBackups();
  loadPlayer();
}

// Everything that shows the release or what is installed.
function renderAll() {
  renderHero();
  renderNews();
  renderRail();
  renderNotesDot();
  const p = here();
  if (p.page === "library") renderLibrary();
  if (p.page === "game") renderGame(p.arg);
  if (p.page === "notes") renderNotes();
}

function renderChrome() {
  const s = status.settings;
  const parts = [FLAVOR_NAMES[s.flavor] || s.flavor || "Launcher"];
  if (s.channel !== "stable") parts.push(s.channel);
  if (DEMO && !location.search.includes("shot")) parts.push("demo");   // (?shot: README screenshots)
  $("kicker").textContent = parts.join(" · ");
  $("flavor-name").textContent = (FLAVOR_NAMES[s.flavor] || s.flavor || "—") + (s.channel !== "stable" ? " · " + s.channel : "");
  $("foot-ver").textContent = "Launcher " + status.launcherVersion;
  renderLauncher();
}

function renderMe() {
  const c = player && player.character;
  $("me").classList.toggle("hidden", !c);
  if (!c) return;
  const cls = CLASSES[c.class] || null;
  $("me").style.setProperty("--cls", cls ? cls[1] : "160, 160, 170");
  $("me-av").textContent = c.name.slice(0, 1).toUpperCase();
  $("me-name").textContent = c.name;
  $("me-spec").textContent = [c.spec, cls && cls[0]].filter(Boolean).join(" ") || c.realm;
  $("me").title = c.name + " · " + c.realm + " (the character you played last)";
}

// ---------------------------------------------------------------------------------------------------------------
// The release's folders: the core, the Extras (3D rooms) and a game per pack. A game's look (art in games/) is keyed
// by the id it registers with the Games hub; one this launcher doesn't know yet gets the generic look.
// ---------------------------------------------------------------------------------------------------------------

const GAME_LOOK = {
  azeromon: { kicker: "Adventure", accent: "134, 216, 107", pix: true, cmd: "/dz azeromon", motes: ["au", "", "au"], tagline: "Tame and battle the beasts of Elwynn." },
  holdtheline: { kicker: "Survivors", accent: "240, 112, 52", cmd: "/dz htl", motes: ["em", "au", "em"], tagline: "Fifteen minutes. One class. The whole Scourge." },
  illidan: { kicker: "Roguelike", accent: "120, 214, 90", cmd: "/dz illidan", motes: ["", "au"], tagline: "Five floors of the Black Temple, new every run." },
  bingo: { kicker: "Raid nights", accent: "242, 196, 64", cmd: "/dz bingo", motes: ["au", "au", ""], tagline: "Squares fill in as the raid happens." },
  chess: { kicker: "The Gamesman's Hall", accent: "150, 170, 240", rooms: true, cmd: "/dz chess", motes: ["", "", "au"], tagline: "Play Medivh's echo, or a guildmate." },
  trainer: { kicker: "Practice", accent: "79, 211, 224", rooms: true, cmd: "/dz trainer", motes: ["", "au"], tagline: "Practise each boss in 3D before the pull." },
};
const GAME_ORDER = Object.keys(GAME_LOOK);
const GENERIC_LOOK = { kicker: "Game", accent: "201, 163, 38", generic: true, motes: ["au", ""], tagline: "" };
const EXTRA_TEXT = {
  rooms: "Strategy boards in 3D, the chess hall and Raid Trainer's arenas. Without it, boards and chess fall back to 2D and the trainer's arenas stay flat.",
};
const ROOMS_COLOR = "122, 168, 240";

let pickerAsked = false;  // the picker opened by itself once this start
let installing = null;    // pack id an Install click is installing

function packs() { return (check && check.packs) || []; }
function games() {
  const rank = (p) => { const i = GAME_ORDER.indexOf(p.id); return i < 0 ? 99 : i; };
  return packs().filter((p) => p.kind === "game").sort((a, b) => rank(a) - rank(b) || a.title.localeCompare(b.title));
}
// Before the release list is read: the games installed (from the folders' TOCs).
function installedGames() {
  return ((status && status.installed && status.installed.packs) || []).filter((p) => p.kind === "game")
    .map((p) => ({ ...p, installed: true, wanted: true, action: "same", bytes: 0, gz: 0, diskBytes: 0 }));
}
function changing() { return packs().filter((p) => p.action === "install" || p.action === "update" || p.action === "remove"); }
function lookOf(p) { return GAME_LOOK[p.id] || GENERIC_LOOK; }
function colorOf(p) { return p.kind === "game" ? lookOf(p).accent : p.kind === "extra" ? ROOMS_COLOR : "226, 184, 74"; }
function titleOf(folder) {
  const p = packs().find((x) => x.folder === folder);
  if (p) return p.title;
  if (folder === "DisasterZone_Rooms") return "3D rooms";
  return folder === "DisasterZone" ? folder : folder.replace(/^DisasterZone_/, "");
}
function packOfFolder(folder) { return packs().find((x) => x.folder === folder) || null; }
function diskOf(p) { return p.installed ? p.diskBytes || p.bytes : p.bytes; }
function devCopy() { return !!(status && status.installed && (status.installed.dev || status.installed.linked)); }
function busyPack(p) { return updating && (installing === p.id || (p.wanted && (p.action === "install" || p.action === "update"))); }
function playedText(t) {
  if (t == null) return null;
  if (!t) return "You've played it";
  const days = Math.floor((Date.now() / 1000 - t) / 86400);
  return days < 1 ? "Played today" : days < 2 ? "Played yesterday" : days < 14 ? "Played " + days + " days ago"
    : "Last played " + new Date(t * 1000).toLocaleDateString(undefined, { day: "numeric", month: "short" });
}
function changelog() { return (check && check.notes && check.notes.changelog) || []; }
function releaseTitle(v) { const e = changelog().find((x) => x.version === v); return e ? e.title : ""; }

// The disk meter (rail and Library): what the installed folders take, each in its colour.
function diskParts() {
  const parts = [];
  for (const p of packs()) if (p.installed) parts.push({ p, v: diskOf(p), c: colorOf(p) });
  return parts;
}
function fillSegs(box, parts) {
  box.textContent = "";
  const total = parts.reduce((n, x) => n + x.v, 0);
  for (const x of parts) {
    const i = el("i");
    i.style.width = (total ? (x.v / total) * 100 : 0) + "%";
    i.style.background = "rgb(" + x.c + ")";
    i.title = x.p.title + " · " + fmtBytes(x.v);
    box.append(i);
  }
  return total;
}

// ---------------------------------------------------------------------------------------------------------------
// Update / restore / play
// ---------------------------------------------------------------------------------------------------------------

// Update (Home, the Library strip, Get on a game): the core and every kept pack move to the release together.
// The first release with games asks which to keep first.
async function runUpdate() {
  if (working) return;
  if (check && check.needsPick && !check.upToDate) { openPicker({ then: "update" }); return; }
  await doUpdate();
}

async function doUpdate() {
  if (working) return;
  working = updating = true;
  startProgress();
  renderAll();
  try {
    const out = await api.invoke("update");
    showProgress({ step: "done", done: 1, total: 1 });
    const added = (out.folders || []).filter((f) => f.action === "install" && f.folder !== "DisasterZone").map((f) => titleOf(f.folder));
    const what = added.length ? "DisasterZone " + out.version + " and " + joinNames(added) + " are installed."
      : "DisasterZone " + out.version + " is installed.";
    toast(what + (status.wowRunning ? " Restart World of Warcraft to load it." : ""), true);
  } catch (e) {
    toast(e);
  }
  await new Promise((r) => setTimeout(r, 900));   // (the finished bar stays a moment)
  working = updating = false;
  installing = null;
  endProgress();
  await refreshAll();
}

// Play (play.rs): the game already running comes to the front; else the chosen folder's version through Battle.net,
// or the Play command from Settings.
async function play() {
  try {
    const what = await api.invoke("play");
    const name = "World of Warcraft " + (FLAVOR_NAMES[status && status.settings.flavor] || "");
    toast({
      focused: name + " is already running: here it is.",
      running: name + " is already running.",
      command: "Starting your Play command…",
      launched: "Starting " + name + " through Battle.net…",
      opened: "Opening Battle.net…",
    }[what] || "Starting " + name + "…", true);
  } catch (e) {
    toast(e);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The launcher's own update (tauri-plugin-updater; the feed is the release "launcher-latest"). The window looks at
// start, on the re-check timer, when it comes back from the tray, on Check again / Try again and when a release
// needs a newer launcher; the tray's check tells it too (event "launcher-update"). One bar, whoever found it.
// ---------------------------------------------------------------------------------------------------------------

const SHOWN_GAP_MS = 60 * 1000;   // (back from the tray twice in a minute: one look)

// upd: the plugin's Update for version (none when the tray told it); looking: the check under way
const launcher = { upd: null, version: null, looking: null, at: 0, installing: false, pct: null };

// A release this launcher can't read (a newer manifest format, or a new release key): the way on is a new launcher.
function needsNewLauncher() { return !!checkErr && /newe(r|st) launcher/.test(checkErr); }

function checkLauncherUpdate() {
  if (launcher.installing) return Promise.resolve();
  if (!launcher.looking) {
    launcher.looking = lookForLauncher().finally(() => { launcher.looking = null; renderLauncher(); });
    renderLauncher();
  }
  return launcher.looking;
}

async function lookForLauncher() {
  let found = null, error = null;
  try {
    const upd = await api.launcherCheck();
    found = upd ? upd.version : null;
    if (!launcher.installing) {       // (Install was clicked meanwhile: it has its own)
      launcher.upd = upd || null;
      launcher.version = found;
    }
  } catch (e) {
    error = String(e);              // (a version the tray told of stays: Install looks again)
  }
  launcher.at = Date.now();
  try {
    const c = await api.invoke("launcher_checked", { found, error });
    if (status) status.launcherCheck = c;
  } catch (e) { /* (About shows the one before) */ }
}

function launcherButtonText() {
  return launcher.pct == null ? "Downloading…" : launcher.pct >= 100 ? "Restarting…" : "Downloading… " + launcher.pct + "%";
}

// The bar in the title bar, the rail's version line, the hero while a release needs a newer launcher, and About.
function renderLauncher() {
  const v = launcher.version;
  $("lbar").classList.toggle("hidden", !v);
  if (v) {
    $("lbar-text").textContent = "Launcher " + v + " is ready";
    const b = $("lbar-btn");
    b.disabled = launcher.installing;
    b.textContent = launcher.installing ? launcherButtonText() : "Install and restart";
    b.onclick = installLauncher;
  }
  const sub = $("foot-sub");
  sub.className = v ? "ready" : "";
  sub.textContent = v ? v + " is ready" : launcher.looking ? "Checking…" : "Up to date";
  if (status) renderAbout();
  if (needsNewLauncher()) renderHero();
}

async function installLauncher() {
  if (launcher.installing) return;
  if (working) { toast("Wait for the addon update to finish first."); return; }
  launcher.installing = true;
  launcher.pct = null;
  renderLauncher();
  try {
    // (told by the tray: this window has no Update of its own yet)
    const upd = launcher.upd || await api.launcherCheck();
    if (!upd) throw "No new launcher was found after all. Try again in a few minutes.";
    launcher.version = upd.version;
    let total = 0, got = 0;
    await api.launcherInstall(upd, (ev) => {
      if (ev.event === "Started") total = (ev.data && ev.data.contentLength) || 0;
      else if (ev.event === "Progress") got += ev.data.chunkLength;
      const pct = ev.event === "Finished" ? 100 : total ? Math.min(99, Math.floor((got * 100) / total)) : null;
      if (pct !== launcher.pct) { launcher.pct = pct; renderLauncher(); }
    });
    // (the new launcher starts in this one's place: on Windows the installer has already taken over)
  } catch (e) {
    toast(e);
    launcher.installing = false;
    try {
      const c = await api.invoke("launcher_checked", { found: launcher.version, error: "installing failed: " + e });
      status.launcherCheck = c;
    } catch (e2) { /* (the toast said it) */ }
    renderLauncher();
  }
}

// Check again (the round arrow) and Try again: the addon's release and the launcher's own update.
function checkAgain() {
  checkLauncherUpdate();
  loadPlayer();
  return runCheck();
}
