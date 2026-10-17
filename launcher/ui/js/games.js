// Games: the rail's list, the Library (a card per game pack, the 3D rooms under Extras), a page per game, the
// one-time picker, and what Get / Remove / the 3D rooms switch do. Sizes, taglines and what's installed come from
// the release list (check.packs); before it is read the rail lists the installed games.
"use strict";

let libFilter = "all";    // all | installed | available
let picker = null;        // { pick: {id: keep}, then: "update" | undefined } while the picker is open

// ---------------------------------------------------------------------------------------------------------------
// Rail
// ---------------------------------------------------------------------------------------------------------------

// What a game is doing now, for the rail and the cards: [text, kind] (kind: busy | wait | get | ok | "")
function stateOf(p) {
  if (busyPack(p)) {
    const got = prog && prog.step === "download" && p.downloadBytes ? Math.floor(((prog.dl[p.folder] || 0) / p.downloadBytes) * 100) : null;
    return [got != null && got >= 100 ? "Downloaded" : (p.installed ? "Updating" : "Installing") + (got != null ? " · " + got + "%" : "…"), "busy", got];
  }
  if (p.action === "remove") return ["Leaves with the next update", "wait"];
  if (!p.installed && p.wanted) return ["Installs with the next update", "wait"];
  if (!p.installed) return ["Get · " + fmtBytes(p.gz), "get"];
  if (p.action === "update") return ["Changes in " + check.version, "wait"];
  return [p.diskBytes || p.bytes ? fmtBytes(diskOf(p)) : "Installed", "ok"];
}

function renderRail() {
  const box = $("rail-games");
  box.textContent = "";
  const list = check ? games() : installedGames();
  const cur = here();
  $("rail-count").textContent = check ? list.filter((p) => p.installed).length + " of " + list.length : list.length ? String(list.length) : "";
  for (const p of list) {
    const look = lookOf(p);
    const [text, kind, pct] = stateOf(p);
    const b = el("button", (p.installed || p.wanted ? "" : "off") + (cur.page === "game" && cur.arg === p.id ? " on" : ""));
    b.style.setProperty("--acc", look.accent);
    const th = el("span", "th");
    if (!look.generic) th.append(img("games/" + p.id + ".jpg"));
    const tx = el("span", "tx");
    tx.append(el("span", "t", p.title), el("span", "s" + (kind === "busy" ? " busy" : ""), text));
    if (kind === "busy") {
      const mini = el("span", "mini");
      const f = el("i");
      f.style.width = (pct || 0) + "%";
      mini.append(f);
      tx.append(mini);
    }
    b.append(th, tx);
    if (kind !== "busy") {
      const st = el("span", "st " + kind);
      if (kind === "ok") st.append(icon("check", "s"));
      else if (kind === "get") st.append(icon("down", "s"));
      else if (kind === "wait") st.append(icon("wait", "s"));
      st.setAttribute("aria-label", text);
      b.append(st);
    }
    b.title = p.title + " · " + text;
    b.onclick = () => go("game", p.id);
    box.append(b);
  }
  if (!list.length) box.append(el("div", "empty", !status || !status.flavorDir ? "Pick your game folder first." : checking ? "Reading the release list…" : "No games yet."));
  const total = fillSegs($("rail-segs"), diskParts());
  $("rail-disk").textContent = check ? fmtBytes(total) : "—";
}

// ---------------------------------------------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------------------------------------------

function renderLibrary() {
  if (!status) return;
  const parts = diskParts();
  const total = fillSegs($("lib-segs"), parts);
  $("lib-disk").textContent = check ? fmtBytes(total) : "—";
  const legend = $("lib-legend");
  legend.textContent = "";
  for (const x of parts) {
    const s = el("span");
    const sw = el("i");
    sw.style.background = "rgb(" + x.c + ")";
    s.append(sw, x.p.title + " " + fmtBytes(x.v));
    legend.append(s);
  }

  // the strip: an update waiting (or running) for these folders
  const strip = $("lib-strip");
  strip.textContent = "";
  const show = updating || (check && !check.upToDate && !devCopy());
  strip.classList.toggle("hidden", !show);
  if (updating) {
    strip.append(el("span", "tx", "Updating to " + check.version + "…"));
    const bar = el("span", "bar");
    const f = el("i");
    f.style.width = (prog ? Math.floor(prog.pct) : 0) + "%";
    bar.append(f);
    strip.append(bar);
  } else if (show) {
    const names = changing().map((p) => p.title);
    const size = check.downloadBytes ? " · " + fmtBytes(check.downloadBytes) : "";
    const b = el("button", "btn sm gold");
    if (check.needsPick) {
      strip.append(el("span", "tx", check.version + " is ready · pick your games first"));
      b.textContent = "Pick games";
      b.onclick = () => openPicker({ then: "update" });
    } else {
      const inst = status.installed;
      const newer = inst && inst.present && inst.version !== check.version;
      strip.append(el("span", "tx", (newer ? check.version + " is ready for " : "Waiting: ") + joinNames(names) + size));
      b.textContent = check.hold ? "Update to " + check.version : newer ? "Update" : "Apply";
      b.onclick = runUpdate;
    }
    b.disabled = working;
    strip.append(b);
  }

  const list = games();
  const tabs = $("lib-tabs");
  tabs.textContent = "";
  const counts = { all: list.length, installed: list.filter((p) => p.installed).length, available: list.filter((p) => !p.installed).length };
  for (const [key, label] of [["all", "All"], ["installed", "Installed"], ["available", "Not installed"]]) {
    const b = el("button", key === libFilter ? "on" : null, label);
    b.append(el("span", null, String(counts[key])));
    b.onclick = () => { libFilter = key; renderLibrary(); };
    tabs.append(b);
  }
  tabs.classList.toggle("hidden", !list.length);

  const grid = $("lib-grid");
  grid.textContent = "";
  const shown = list.filter((p) => libFilter === "all" || (libFilter === "installed") === !!p.installed);
  for (const p of shown) grid.append(gameCard(p));
  if (!list.length) {
    const why = !status.flavorDir ? "Pick your World of Warcraft folder in Settings first."
      : checkErr ? "The games show once the release list can be read: " + checkErr
      : !check ? "Looking for the newest release…"
      : "In this version every game is still part of DisasterZone. Once games come as downloads of their own, you pick yours here.";
    grid.append(el("div", "none", why));
  } else if (!shown.length) grid.append(el("div", "none", libFilter === "installed" ? "No games installed yet." : "Every game is installed."));

  const extras = $("lib-extras");
  extras.textContent = "";
  for (const p of packs().filter((x) => x.kind === "extra")) extras.append(extraRow(p));
}

function gameCard(p) {
  const look = lookOf(p);
  const card = el("article", "cap" + (p.installed || p.wanted ? "" : " off"));
  card.style.setProperty("--acc", look.accent);
  card.tabIndex = 0;
  card.setAttribute("role", "link");
  card.setAttribute("aria-label", p.title);
  card.onclick = () => go("game", p.id);
  card.onkeydown = (e) => { if (e.key === "Enter") go("game", p.id); };
  const art = el("div", "art");
  if (!look.generic) {
    art.append(img("games/" + p.id + ".jpg", "bg"), img("games/" + p.id + "-logo.png", "lg" + (look.pix ? " px" : ""), p.title));
  } else art.append(el("div", "lt", p.title));
  if (p.installed) {
    const c = el("span", "chip ok small");
    c.append(el("span", "pip"), "Installed");
    art.append(c);
    const quick = el("span", "quick");
    const open = el("button", "ibtn glass");
    open.append(icon("folder", "s"));
    open.title = "Open folder";
    open.setAttribute("aria-label", "Open " + p.title + "'s folder");
    open.onclick = (e) => { e.stopPropagation(); api.invoke("open_folder", { kind: "pack", folder: p.folder }).catch(toast); };
    const rm = el("button", "ibtn glass rm");
    rm.append(icon("trash", "s"));
    rm.title = "Remove · frees " + fmtBytes(diskOf(p));
    rm.setAttribute("aria-label", "Remove " + p.title);
    rm.disabled = working || devCopy();
    rm.onclick = (e) => { e.stopPropagation(); removePack(p); };
    quick.append(open, rm);
    art.append(quick);
  }
  card.append(art);

  const meta = el("div", "meta");
  const tx = el("span", "tx");
  tx.append(el("b", null, p.title));
  const rooms = packs().find((x) => x.id === "rooms");
  const played = playedText(p.played);
  let line = p.tagline || look.tagline, cls = null;
  if (p.action === "remove") { line = "Leaves with the next update"; cls = "warn"; }
  else if (!p.installed && p.wanted) { line = "Installs with the next update"; cls = "go"; }
  else if (p.installed && look.rooms && rooms && !rooms.installed) { line = "Plays flat while 3D rooms are off"; cls = "warn"; }
  else if (p.installed && played) { line = played; cls = "pl"; }
  tx.append(el("small", cls, line));
  meta.append(tx);
  const locked = working || devCopy() || !check;
  if (busyPack(p)) {
    const bar = el("span", "bar");
    const f = el("i");
    f.style.width = (stateOf(p)[2] || 0) + "%";
    bar.append(f);
    meta.append(bar);
  } else if (p.action === "remove") {
    const keep = el("button", "btn sm", "Keep it");
    keep.disabled = locked;
    keep.onclick = (e) => { e.stopPropagation(); choose(p, true); };
    meta.append(keep);
  } else if (!p.installed && !p.wanted) {
    const b = el("button", "btn sm gold");
    b.append(icon("down", "s"), "Get · " + fmtBytes(p.gz));
    b.disabled = locked;
    b.onclick = (e) => { e.stopPropagation(); installPack(p); };
    meta.append(b);
  } else meta.append(el("span", "sz", fmtBytes(diskOf(p))));
  card.append(meta);
  return card;
}

function extraRow(p) {
  const row = el("div", "extra");
  const ic = el("span", "ic");
  ic.append(icon("cube", "l"));
  const tx = el("span", "tx");
  tx.append(el("b", null, p.title), el("small", null, EXTRA_TEXT[p.id] || p.tagline || ""));
  const sp = el("span", "sp", busyPack(p) ? "installing…" : fmtBytes(diskOf(p)));
  const tg = el("button", "tgl");
  tg.setAttribute("role", "switch");
  tg.setAttribute("aria-label", p.title);
  tg.setAttribute("aria-checked", String(p.wanted && p.action !== "remove"));
  tg.disabled = working || devCopy() || !check;
  tg.onclick = () => (p.wanted && p.action !== "remove" ? turnOff(p) : installPack(p));
  sp.append(tg);
  row.append(ic, tx, sp);
  return row;
}

// ---------------------------------------------------------------------------------------------------------------
// A game's page
// ---------------------------------------------------------------------------------------------------------------

let gameShown = null;     // the game whose hero is built (its motes are made once)

function renderGame(id) {
  const p = games().find((x) => x.id === id) || installedGames().find((x) => x.id === id);
  if (!p) { if (check) go("library"); return; }
  const look = lookOf(p);
  const page = $("page-game");
  page.style.setProperty("--tint", look.accent);
  if (gameShown !== id) {
    gameShown = id;
    const art = $("g-art");
    art.src = look.generic ? "art/hero.jpg" : "games/" + p.id + ".jpg";
    art.classList.toggle("px", !!look.pix);
    sprinkle($("g-motes"), 12, look.motes);
    for (const n of page.querySelectorAll(".hero-body > *")) { n.style.animation = "none"; void n.offsetWidth; n.style.animation = ""; }
  }
  const chips = $("g-chips");
  chips.textContent = "";
  chips.append(el("span", "chip", look.kicker));
  const [text, kind] = stateOf(p);
  const c = el("span", "chip small " + (kind === "ok" ? "ok" : kind === "busy" ? "gold busy" : kind === "wait" ? "gold" : ""));
  c.append(el("span", "pip"), kind === "ok" ? "Installed" : kind === "get" ? "Not installed" : text);
  chips.append(c);
  const logo = $("g-logo");
  logo.textContent = "";
  if (look.generic) logo.append(el("div", "lt", p.title));
  else logo.append(img("games/" + p.id + "-logo.png", look.pix ? "px" : null, p.title));
  $("g-lead").textContent = p.tagline || look.tagline;

  const act = $("g-actions");
  act.textContent = "";
  const wrap = el("span", "playwrap");
  const main = el("button", "play");
  const locked = working || devCopy() || !check;
  if (busyPack(p)) {
    main.append(el("span", null, "INSTALLING…"));
    main.disabled = true;
    wrap.classList.add("off");
  } else if (p.action === "remove") {
    main.classList.add("notri");
    main.append(el("span", null, "KEEP IT"));
    main.disabled = locked;
    main.onclick = () => choose(p, true);
  } else if (!p.installed && !p.wanted) {
    main.append(el("span", null, "GET · " + fmtBytes(p.gz)));
    main.classList.add("long");
    main.disabled = locked;
    main.onclick = () => installPack(p);
  } else {
    const tri = document.createElementNS(SVGNS, "svg");
    tri.setAttribute("viewBox", "0 0 24 24");
    tri.setAttribute("class", "tri");
    const path = document.createElementNS(SVGNS, "path");
    path.setAttribute("d", "M7 4.8v14.4L19 12z");
    tri.append(path);
    main.append(tri, el("span", null, "PLAY"));
    main.onclick = play;
  }
  if (main.disabled) wrap.classList.add("off");
  wrap.append(main);
  act.append(wrap);
  if (p.installed && look.cmd) {
    const hint = el("div", "hint");
    hint.append(el("span", null, "Opens World of Warcraft. In game:"), el("span", "kbd", look.cmd));
    act.append(hint);
  } else if (!p.installed && p.wanted && !busyPack(p)) {
    const b = el("button", "btn lg glassy", "Update now");
    b.disabled = working;
    b.onclick = runUpdate;
    act.append(b);
  }
  renderWeekly(p);
  renderGameNotes(p);
  renderGameAbout(p);
}

// The newest releases' sections about this game (its title in the heading).
function renderGameNotes(p) {
  const box = $("g-notes");
  box.textContent = "";
  const name = p.title.toLowerCase().replace(/^the /, "");
  let rel = null, secs = [];
  for (const r of changelog()) {
    secs = r.sections.filter((s) => (s.heading || "").toLowerCase().includes(name));
    if (secs.length) { rel = r; break; }
  }
  const head = el("div", "h-row");
  head.append(el("span", "label", rel ? "New in " + rel.version : "Patch notes"));
  const more = el("button", "link", "Patch notes");
  more.append(icon("chev", "s"));
  more.onclick = () => go("notes", rel ? rel.version : null);
  head.append(more);
  box.append(head);
  if (!rel) { box.append(el("div", "muted", check ? "No changes to " + p.title + " in the recent releases." : "The patch notes show once the release list has been read.")); return; }
  const cols = el("div", "cols");
  for (const s of secs.slice(0, 2)) {
    const col = el("div");
    col.style.display = "flex";
    col.style.flexDirection = "column";
    col.style.gap = "10px";
    const grp = el("div", "grp");
    if (["new", "changed", "fixed"].includes(s.kind)) grp.append(el("span", "tag " + s.kind, s.kind));
    grp.append(s.heading);
    const ul = el("ul", "dl");
    const lines = (s.lines || []).map((l) => (typeof l === "string" ? l : l.text));
    for (const t of (lines.length ? lines : [s.lead]).slice(0, 5)) if (t) ul.append(el("li", null, t));
    col.append(grp, ul);
    cols.append(col);
  }
  box.append(cols);
}

function renderGameAbout(p) {
  const box = $("g-about");
  box.textContent = "";
  box.append(el("span", "label", "About this pack"));
  const kv = el("div", "kv");
  const row = (k, v, code) => { const d = el("div"); d.append(el("span", null, k), el(code ? "code" : "b", null, v)); kv.append(d); };
  row("Folder", p.folder, true);
  if (check) row(p.installed ? "On disk" : "Download", p.installed ? fmtBytes(diskOf(p)) : fmtBytes(p.gz) + " · " + fmtBytes(p.bytes) + " on disk");
  row("Loads", "At login");
  const played = playedText(p.played);
  if (played) row("Played", played.replace(/^Played /, "").replace(/^You've played it$/, "Yes"));
  box.append(kv);
  const look = lookOf(p);
  const rooms = packs().find((x) => x.id === "rooms");
  if (look.rooms && rooms && !rooms.installed) box.append(el("p", null, "Plays flat while 3D rooms are off: switch them on in the Library."));
  box.append(el("p", null, "Your progress lives in DisasterZone's saved variables, so removing the game keeps it."));
  if (p.installed) {
    const r2 = el("div", "row2");
    const open = el("button", "btn sm");
    open.append(icon("folder", "s"), "Open folder");
    open.onclick = () => api.invoke("open_folder", { kind: "pack", folder: p.folder }).catch(toast);
    const rm = el("button", "btn sm danger");
    rm.append(icon("trash", "s"), "Remove");
    rm.disabled = working || devCopy();
    rm.onclick = () => removePack(p);
    r2.append(open, rm);
    box.append(r2);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Hold the Line's weekly challenge, worked out the way the game does (DisasterZone_HoldTheLine/Social.lua:
// S:Week, S:WeekLeft, S:Challenge). The week turns on the region's reset day (Wednesday in Europe, Tuesday
// elsewhere) at local midnight; the game's clock is taken to be this PC's. The challenge names come with the
// release (release.py: notes.htlWeekly), else the list of 1.5.5.
// ---------------------------------------------------------------------------------------------------------------

const HTL_WEEKLY = ["The Hardest Line", "Frost and Fire", "One Spell", "Glass Cannon", "Light's Chosen", "The Hundred Club", "Quarter Rush", "Dance Night"];

function htlWeek(t, region) {
  const reset = region === "EU" ? 3 : 2;
  const back = (((new Date(t * 1000).getDay() - reset) % 7) + 7) % 7;
  const d = new Date((t - back * 86400) * 1000);
  const z = (n) => String(n).padStart(2, "0");
  return d.getFullYear() + "-" + z(d.getMonth() + 1) + "-" + z(d.getDate());
}
function htlWeekLeft(t, region) {
  const reset = region === "EU" ? 3 : 2;
  const d = new Date(t * 1000);
  const back = (((d.getDay() - reset) % 7) + 7) % 7;
  return Math.max(0, 7 * 86400 - (back * 86400 + d.getHours() * 3600 + d.getMinutes() * 60 + d.getSeconds()));
}
function htlChallenge(week, names) {
  const [y, m, d] = week.split("-").map(Number);
  const index = Math.floor(new Date(y, m - 1, d, 12).getTime() / 1000 / 604800);
  let h = 5381;
  for (const ch of "HTL:" + week) h = (h * 33 + ch.charCodeAt(0)) % 2147483647;
  return { name: names[index % names.length], seed: (h % 1999999999) + 1 };
}

function renderWeekly(p) {
  const box = $("g-weekly");
  const on = p.id === "holdtheline";
  box.classList.toggle("hidden", !on);
  if (!on) return;
  const names = (check && check.notes && check.notes.htlWeekly && check.notes.htlWeekly.length) ? check.notes.htlWeekly : HTL_WEEKLY;
  const t = nowSec();
  const region = player.region || "US";
  const c = htlChallenge(htlWeek(t, region), names);
  box.textContent = "";
  box.append(el("span", "label", "Weekly challenge"), el("div", "t", c.name),
    el("p", null, "One run for the whole guild this week, with the same seed for everyone. Compare on the guild board in game."));
  const seed = el("div", "seed");
  seed.append(el("span", null, "Resets in " + duration(htlWeekLeft(t, region))), el("code", null, "SEED " + c.seed));
  box.append(seed);
}

// ---------------------------------------------------------------------------------------------------------------
// Get / Remove / Keep / the 3D rooms switch
// ---------------------------------------------------------------------------------------------------------------

// What a choice does to the cards until the next check: they show progress while the update runs.
function assume(id, on) {
  const p = packs().find((x) => x.id === id);
  if (!p) return;
  p.wanted = on;
  p.chosen = on;
  p.action = on ? (p.installed ? (p.action === "remove" ? "same" : p.action) : "install") : (p.installed ? "remove" : "");
}

async function choose(p, on) {
  try { await api.invoke("set_packs", { packs: { [p.id]: on } }); } catch (e) { toast(e); }
  await refreshAll();
}

// Get on a game (and an Extra switched on): the pack goes in with the rest of the release, so a waiting update
// comes along.
async function installPack(p) {
  if (working) return;
  if (check && check.needsPick && p.kind === "game") { openPicker({ then: "update", tick: p.id }); return; }
  try { await api.invoke("set_packs", { packs: { [p.id]: true } }); } catch (e) { toast(e); return; }
  assume(p.id, true);
  installing = p.id;
  if (check && check.needsPick) { openPicker({ then: "update" }); return; }
  await doUpdate();
}

async function removePack(p) {
  const size = fmtBytes(diskOf(p));
  const ok = await confirmBox("Remove " + p.title + "?", "Frees " + size + ". Your progress stays in DisasterZone's saved " +
    "variables, so installing it again picks up where you left off. Backups can put it back.", "Remove", true);
  if (ok) await takeOut(p, p.title + " removed · " + size + " freed.");
}

async function turnOff(p) {
  if (p.installed) await takeOut(p, p.title + " removed · " + fmtBytes(diskOf(p)) + " freed.");
  else await choose(p, false);
}

async function takeOut(p, done) {
  if (working) return;
  working = true;
  renderAll();
  try {
    await api.invoke("remove_pack", { id: p.id, folder: p.folder });
    toast(done + (status.wowRunning ? " It leaves the game at your next /reload." : ""), true);
  } catch (e) {
    toast(e);
  }
  working = false;
  await refreshAll();
}

// ---------------------------------------------------------------------------------------------------------------
// The one-time picker: a tile per game, the ones played (or installed) on.
// ---------------------------------------------------------------------------------------------------------------

function openPicker(opts) {
  const list = games();
  if (!list.length || working) return;
  const pick = {};
  for (const p of list) pick[p.id] = p.chosen != null ? p.chosen : p.played != null || p.installed;
  if (opts.tick) pick[opts.tick] = true;
  picker = { pick, then: opts.then };
  $("p-ver").textContent = check.version;
  renderPicker();
  $("picker").classList.remove("hidden");
}

function closePicker() {
  picker = null;
  $("picker").classList.add("hidden");
}

function renderPicker() {
  const box = $("p-rows");
  box.textContent = "";
  let keep = 0, free = 0, n = 0;
  for (const p of games()) {
    const on = !!picker.pick[p.id];
    if (on) { keep += p.bytes; n++; } else free += p.bytes;
    const look = lookOf(p);
    const tile = el("button", "tile" + (on ? " on" : ""));
    tile.setAttribute("aria-pressed", String(on));
    tile.setAttribute("aria-label", "Keep " + p.title);
    const pic = el("span", "pic");
    if (look.generic) pic.append(el("span", "lt", p.title));
    else pic.append(img("games/" + p.id + ".jpg", "bg"), img("games/" + p.id + "-logo.png", "lg" + (look.pix ? " px" : ""), p.title));
    const tick = el("span", "tick");
    if (on) tick.append(icon("check", "s"));
    pic.append(tick);
    const meta = el("span", "meta");
    meta.append(el("b", null, p.title));
    if (p.played != null) meta.append(el("span", "played", "PLAYED"));
    meta.append(el("span", "sz", fmtBytes(p.bytes)));
    tile.append(pic, meta);
    tile.onclick = () => { picker.pick[p.id] = !on; renderPicker(); };
    box.append(tile);
  }
  const sum = $("p-sum");
  sum.textContent = "";
  sum.append(el("b", null, plural(n, "game", "games")), " · keeps " + fmtBytes(keep) + (free ? " · frees " + fmtBytes(free) : ""));
}

async function savePicker(all) {
  if (!picker) return;
  const choice = {};
  for (const p of games()) choice[p.id] = all || !!picker.pick[p.id];
  const then = picker.then;
  closePicker();
  try {
    await api.invoke("set_packs", { packs: choice, picked: true });
  } catch (e) {
    toast(e);
    return;
  }
  if (check) check.needsPick = false;
  for (const id in choice) assume(id, choice[id]);
  if (then === "update") await doUpdate();
  else {
    toast(all ? "All games kept. Update installs them." : "Saved. Change it any time in the Library.", true);
    await refreshAll();
  }
}
