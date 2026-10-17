// Games: the rail's list, the Library (a card per game pack, the 3D rooms under Extras), a page per game, the
// one-time picker, and what Get / Remove / the 3D rooms switch do. Sizes, taglines and what's installed come from
// the release list (check.packs); before it is read the rail lists the installed games.
"use strict";

let libFilter = "all";    // all | installed | available
let picker = null;        // { pick: {id: keep}, then: "update" | undefined } while the picker is open

// ---------------------------------------------------------------------------------------------------------------
// Rail
// ---------------------------------------------------------------------------------------------------------------

// What a game is doing now, for the rail and the cards: [text, kind, bar %, how] (kind: busy | wait | get | ok | "").
// While it updates, the same state as its row in Home's table (folderState: how = "" waiting, "go" or "ok").
function stateOf(p) {
  if (gone(p)) return removing.done ? ["Removed", "busy", 0, "rm"] : ["Removing…", "busy", 100, "rm"];
  if (queued.has(p.id)) return ["Installs after this update", "wait"];
  if (busyPack(p)) {
    if (!prog) return [(p.installed ? "Updating" : "Installing") + "…", "busy", 0, "go"];
    const [, frac, how, words] = folderState(p);
    return [words, "busy", Math.round(frac * 100), how];
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
    const [text, kind, pct, how] = stateOf(p);
    const b = el("button", (p.installed || p.wanted ? "" : "off") + (cur.page === "game" && cur.arg === p.id ? " on" : "") + (how === "rm" ? " rm" + (removing.done ? " out" : "") : ""));
    b.style.setProperty("--acc", look.accent);
    const th = el("span", "th");
    if (!look.generic) th.append(img("games/" + p.id + ".jpg"));
    const tx = el("span", "tx");
    tx.append(el("span", "t", p.title), el("span", "s" + (kind === "busy" ? " busy " + (how || "idle") : ""), text));
    if (kind === "busy") {
      const mini = el("span", "mini" + (how === "ok" ? " ok" : how === "rm" ? " rm" + (removing.done ? " out" : "") : ""));
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
      // (the download icon gets the game right here: the rest of the row opens its page)
      if (kind === "get" && (!working || updating) && !devCopy() && check) {
        st.classList.add("act");
        st.title = "Download and install " + p.title + " · " + fmtBytes(p.gz);
        st.onclick = (e) => { e.stopPropagation(); installPack(p); };
      }
      b.append(st);
    }
    b.title = p.title + " · " + text;
    b.onclick = () => go("game", p.id);
    b.dataset.id = p.id;
    box.append(b);
  }
  const loading = releaseLoading();
  if (!list.length && loading) {
    for (const w of ["66%", "52%", "74%", "58%"]) {
      const g = el("div", "ghost");
      const tx = el("span", "tx");
      tx.append(skel("g-t", w), skel("g-s"));
      g.append(skel("g-th"), tx);
      box.append(g);
    }
  } else if (!list.length) {
    box.append(el("div", "empty", !status || !status.flavorDir ? "Pick your game folder first." : checkErr ? "The release list couldn't be read." : "No games yet."));
  }
  const parts = diskParts();
  const total = fillSegs($("rail-segs"), parts);
  $("rail-segs").classList.toggle("skel", loading);
  sizeText($("rail-disk"), total, loading);
  renderDiskTip(parts, total, loading);
}

// The meter's number: the size, a placeholder while the release list is read, or a dash without one.
function sizeText(b, total, loading) {
  b.textContent = check ? fmtBytes(total) : loading ? "" : "—";
  if (!check && loading) b.append(skel("g-num"));
}

// The disk meter's hover card: what each installed folder takes, biggest first.
function renderDiskTip(parts, total, loading) {
  sizeText($("tip-total"), total, loading);
  fillSegs($("tip-segs"), parts);
  $("tip-segs").classList.toggle("skel", loading);
  const rows = $("tip-rows");
  rows.textContent = "";
  if (loading) {
    for (const w of ["58%", "44%", "66%"]) {
      const li = el("li", "ghost");
      li.append(skel("g-sw"), skel("g-n", w), el("span"), skel("g-b"));
      rows.append(li);
    }
  }
  for (const x of parts.slice().sort((a, b) => b.v - a.v)) {
    const li = el("li");
    const sw = el("i");
    sw.style.background = "rgb(" + x.c + ")";
    const share = total ? (x.v / total) * 100 : 0;
    li.append(sw, el("span", "n", x.p.title), el("span", "pc", share >= 1 ? Math.round(share) + "%" : "<1%"), el("b", null, fmtBytes(x.v)));
    rows.append(li);
  }
  $("tip-foot").textContent = check ? "Click to add or remove games in the Library."
    : loading ? "Reading the release list…" : "The sizes show once the release list can be read.";
}

// ---------------------------------------------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------------------------------------------

function renderLibrary() {
  if (!status) return;

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
  if (!list.length && releaseLoading()) {
    for (const w of ["58%", "44%", "66%", "50%", "62%", "40%"]) {
      const g = el("div", "cap ghost");
      const meta = el("div", "meta");
      const tx = el("span", "tx");
      tx.append(skel("g-t", w), skel("g-s"));
      meta.append(tx);
      g.append(skel("g-art"), meta);
      grid.append(g);
    }
  } else if (!list.length) {
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
  const card = el("article", "cap" + (p.installed || p.wanted ? "" : " off") + (gone(p) ? " rm" + (removing.done ? " out" : "") : ""));
  card.dataset.id = p.id;
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
  if (gone(p)) { line = removing.done ? "Removed · it waits in Backups" : "Removing…"; cls = "rmv"; }
  else if (queued.has(p.id)) { line = "Installs after this update"; cls = "go"; }
  else if (p.action === "remove") { line = "Leaves with the next update"; cls = "warn"; }
  else if (!p.installed && p.wanted) { line = "Installs with the next update"; cls = "go"; }
  else if (p.installed && look.rooms && rooms && !rooms.installed) { line = "Plays flat while 3D rooms are off"; cls = "warn"; }
  else if (p.installed && played) { line = played; cls = "pl"; }
  tx.append(el("small", cls, line));
  meta.append(tx);
  const locked = working || devCopy() || !check;
  const getLocked = (working && !updating) || devCopy() || !check;   // (during an update, Get queues the game)
  if (gone(p)) {
    const bar = el("span", "bar rm" + (removing.done ? " out" : ""));
    bar.append(el("i"));
    meta.append(bar);
  } else if (busyPack(p)) {
    const [, , pct, how] = stateOf(p);
    const bar = el("span", "bar" + (how === "ok" ? " okb" : ""));
    const f = el("i");
    f.style.width = (pct || 0) + "%";
    bar.append(f);
    meta.append(bar);
  } else if (p.action === "remove") {
    const keep = el("button", "btn sm", "Keep it");
    keep.disabled = locked;
    keep.onclick = (e) => { e.stopPropagation(); choose(p, true); };
    meta.append(keep);
  } else if (!p.installed && !p.wanted && !queued.has(p.id)) {
    const b = el("button", "btn sm gold");
    b.append(icon("down", "s"), "Get · " + fmtBytes(p.gz));
    b.disabled = getLocked;
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
  const sp = el("span", "sp", gone(p) ? (removing.done ? "removed" : "removing…") : busyPack(p) ? "installing…" : fmtBytes(diskOf(p)));
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
  const [text, kind, , how] = stateOf(p);
  page.classList.toggle("removing", how === "rm");
  const c = el("span", "chip small " + (how === "rm" ? "rm" : kind === "ok" ? "ok" : kind === "busy" ? "gold busy" : kind === "wait" ? "gold" : ""));
  const ct = el("span", null, kind === "ok" ? "Installed" : kind === "get" ? "Not installed" : text);
  ct.id = "g-state";
  c.append(el("span", "pip"), ct);
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
  if (gone(p)) {
    // (the install's bar run backwards: full, draining away in muted rose, then empty)
    const word = removing.done ? "REMOVED" : "REMOVING";
    main.classList.add("notri", "busyb", "rm");
    if (removing.done) main.classList.add("out");
    const fill = el("span", "pfill");
    fill.append(el("span", "lbl", word));
    main.append(el("span", "lbl", word), fill);
    main.disabled = true;
  } else if (busyPack(p)) {
    // (a bar of its own: the gold fill holds the same label in dark ink; paintGameBusy() moves them)
    main.classList.add("notri", "busyb");
    main.id = "g-busy";
    const fill = el("span", "pfill");
    fill.append(el("span", "lbl"));
    main.append(el("span", "lbl"), fill);
    main.disabled = true;
  } else if (p.action === "remove") {
    main.classList.add("notri");
    main.append(el("span", null, "KEEP IT"));
    main.disabled = locked;
    main.onclick = () => choose(p, true);
  } else if (queued.has(p.id)) {
    main.classList.add("notri", "long");
    main.append(el("span", null, "NEXT UP"));
    main.disabled = true;
  } else if (!p.installed && !p.wanted) {
    main.append(el("span", null, "GET · " + fmtBytes(p.gz)));
    main.classList.add("long");
    main.disabled = (working && !updating) || devCopy() || !check;
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
  if (gone(p)) {
    const line = el("div", "bline");
    line.append(el("b", null, removing.done ? "Removed · " + fmtBytes(removing.bytes) + " freed" : "Moving it to Backups"),
      el("span", null, removing.done ? "Backups can put it back" : "your progress stays in the saved variables"));
    act.append(line);
  } else if (queued.has(p.id)) {
    const line = el("div", "bline");
    line.append(el("b", null, "Installs after this update"), el("span", null, fmtBytes(p.gz) + " to download"));
    act.append(line);
  } else if (busyPack(p)) {
    const line = el("div", "bline");
    line.id = "g-busy-line";
    line.append(el("b"), el("span"));
    act.append(line);
    paintGameBusy();
  } else if (p.installed && look.cmd) {
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

// While an update runs, the rail's rows and the Library's cards move with each progress event in place: building
// them again each time would flicker and lose the hover and the click under the pointer.
function paintBusy() {
  for (const p of games()) {
    if (!busyPack(p)) continue;
    const [text, , pct, how] = stateOf(p);
    const row = document.querySelector('#rail-games [data-id="' + p.id + '"]');
    if (row) {
      const s = row.querySelector(".s");
      if (s) { s.textContent = text; s.className = "s busy " + (how || "idle"); }
      const mini = row.querySelector(".mini");
      if (mini) { mini.className = "mini" + (how === "ok" ? " ok" : ""); mini.firstChild.style.width = (pct || 0) + "%"; }
      row.title = p.title + " · " + text;
    }
    const bar = document.querySelector('#lib-grid [data-id="' + p.id + '"] .bar');
    if (bar) { bar.className = "bar" + (how === "ok" ? " okb" : ""); bar.firstChild.style.width = (pct || 0) + "%"; }
  }
  paintGameBusy();
}

// The game page while its game installs or updates: the button fills like a bar, and the chip and the line beside it
// follow every progress event (renderProgress), without building the page again.
function paintGameBusy() {
  const b = $("g-busy");
  const h = here();
  if (!b || h.page !== "game") return;
  const p = games().find((x) => x.id === h.arg);
  if (!p || !busyPack(p)) return;
  const [words, , pct, how] = stateOf(p);
  for (const l of b.querySelectorAll(".lbl")) l.textContent = words.replace(/…$/, "").toUpperCase();
  b.querySelector(".pfill").style.width = (pct || 0) + "%";
  b.classList.toggle("ok", how === "ok");
  $("g-state").textContent = words;
  const [main, sub] = busyLine(p);
  const line = $("g-busy-line");
  line.children[0].textContent = main;
  line.children[1].textContent = sub;
}

// Beside the button: this game's bytes while it downloads, else what the update is doing.
function busyLine(p) {
  if (!prog) return ["Starting…", ""];
  const all = fmtMB(prog.done) + " of " + fmtMB(prog.total) + " in all";
  if (prog.step === "download") {
    const of = prog.dlOf[p.folder];
    const got = Math.min(prog.dl[p.folder] || 0, of || 0);
    if (of == null) return ["Starting…", ""];
    if (!of || got >= of) return ["Waiting for the rest", all];
    if (!got) return ["Waiting for its turn", all];
    const left = prog.speed > 0 ? " · about " + duration((prog.total - prog.done) / prog.speed) + " left" : "";
    return [fmtMB(got) + " of " + fmtMB(of), (prog.speed > 0 ? fmtBytes(prog.speed) + "/s" : "") + left];
  }
  if (prog.step === "stage") {
    const [state, , how] = folderState(p);
    if (how === "ok") return ["Checked", "against the signed release"];
    return state === "Downloaded" ? ["Checked next", "against the signed release"] : ["Checking every file", "against the signed release"];
  }
  if (prog.step === "backup") return ["Backing up", "your saved variables and the folders being replaced"];
  if (prog.step === "swap") return ["Swapping in", "the new folders, all at once"];
  return ["Done", ""];
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
  if (!rel && releaseLoading()) { box.append(skel("g-h", "34%"), skel("g-ln", "92%"), skel("g-ln", "80%"), skel("g-ln", "56%")); return; }
  if (!rel) { box.append(el("div", "muted", check ? "No changes to " + p.title + " in the recent releases." : "The patch notes show once the release list can be read.")); return; }
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
  if (working && updating && !queued.has(p.id)) { await queueInstall(p); return; }
  if (working) return;
  if (check && check.needsPick && p.kind === "game") { openPicker({ then: "update", tick: p.id }); return; }
  try { await api.invoke("set_packs", { packs: { [p.id]: true } }); } catch (e) { toast(e); return; }
  assume(p.id, true);
  installing = p.id;
  if (check && check.needsPick) { openPicker({ then: "update" }); return; }
  await doUpdate();
}

// Get while an update runs: the game is kept from now on (the running update reads the settings again when it
// ends, so this stays), and a second update installs it straight after.
async function queueInstall(p) {
  try { await api.invoke("set_packs", { packs: { [p.id]: true } }); } catch (e) { toast(e); return; }
  queued.add(p.id);
  toast(p.title + " installs right after this update.", true);
  renderRail();
  if (here().page === "library") renderLibrary();
  if (here().page === "game") renderGame(here().arg);
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

// Taking a game out plays on its rail row, its card and its page: the colour drains from its picture and its bar
// empties, then "Removed" for a moment. Moving a folder into Backups is quick, so the drain gets its own time.
let removing = null;   // { id, bytes, done } while a pack is taken out
function gone(p) { return !!(removing && removing.id === p.id); }

async function takeOut(p, done) {
  if (working) return;
  working = true;
  removing = { id: p.id, bytes: diskOf(p), done: false };
  renderAll();
  let ok = false;
  try {
    await Promise.all([api.invoke("remove_pack", { id: p.id, folder: p.folder }), new Promise((r) => setTimeout(r, 1100))]);
    ok = true;
  } catch (e) {
    toast(e);
  }
  if (ok) {
    removing.done = true;
    renderAll();
    toast(done + (status.wowRunning ? " It leaves the game at your next /reload." : ""), true);
    await new Promise((r) => setTimeout(r, 900));
  }
  removing = null;
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
