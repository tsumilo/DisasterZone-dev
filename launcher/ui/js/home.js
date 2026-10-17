// Home: the hero (what the launcher can do right now, and the big button that does it), the update's progress,
// the cards of the newest release and the guild's next raid.
"use strict";

// ---------------------------------------------------------------------------------------------------------------
// The hero
// ---------------------------------------------------------------------------------------------------------------

function setChip(text, cls) {
  $("state-chip").className = "chip" + (cls ? " " + cls : "");
  $("state-text").textContent = text;
}

// "<b>1.5.5</b> · Hold the Line, Naxxramas and fixes from the raid"
function setRel(version, title) {
  const r = $("rel-text");
  r.textContent = "";
  if (version) r.append(el("b", null, version));
  if (title) r.append((version ? " · " : "") + title);
}

// The big button: text, what it does; play = the gold Play look with its triangle.
function setMain(text, onClick, opts) {
  opts = opts || {};
  const b = $("btn-main");
  $("btn-main-text").textContent = text;
  b.disabled = !onClick;
  b.onclick = onClick || null;
  b.classList.toggle("notri", !opts.play);
  b.classList.toggle("long", text.length > 9);
  $("main-wrap").classList.toggle("off", !onClick);
}

// The quieter button beside it: Play while the big one updates, or Try again.
function setSecond(text, onClick, playIcon) {
  const b = $("btn-play");
  b.classList.toggle("hidden", !text);
  if (!text) return;
  b.textContent = "";
  if (playIcon) {
    const s = document.createElementNS(SVGNS, "svg");
    s.setAttribute("viewBox", "0 0 24 24");
    s.setAttribute("class", "ico s fill");
    const p = document.createElementNS(SVGNS, "path");
    p.setAttribute("d", "M7 4.8v14.4L19 12z");
    s.append(p);
    b.append(s);
  }
  b.append(text);
  b.onclick = onClick;
}

function setNotice(text, buttonText, onClick) {
  const n = $("notice");
  n.textContent = "";
  if (!text) { n.classList.add("hidden"); return; }
  n.append(text);
  if (buttonText) {
    const b = el("button", "link", buttonText);
    b.onclick = onClick;
    n.append(b);
  }
  n.classList.remove("hidden");
}

// The line under the buttons: the signed-release line (shield), or a plain detail.
function setLine(text, signed) {
  $("trust").classList.toggle("hidden", !text);
  $("trust").classList.toggle("plain", !signed);
  $("trust-text").textContent = text || "";
}

// What Update does, in words: "DisasterZone and Azeromon change · Chess to install".
function describeChanges(list) {
  const named = (action) => list.filter((p) => p.action === action).map((p) => p.title);
  const parts = [];
  const upd = named("update"), add = named("install"), drop = named("remove");
  if (upd.length) parts.push(joinNames(upd) + (upd.length === 1 ? " changes" : " change"));
  if (add.length) parts.push(joinNames(add) + " to install");
  if (drop.length) parts.push(joinNames(drop) + " to remove");
  return parts.join(" · ") || plural(check.changed, "file", "files") + " to change";
}

function signedLine() {
  const n = packs().filter((p) => p.installed).length;
  const what = n > 1 ? "All " + n + " folders match the signed release" : "Every file matches the signed release";
  return what + " · checked " + (Date.now() - checkedAt < 60000 ? "just now" : ago(Math.floor(checkedAt / 1000)));
}

function renderHero() {
  if (!status) return;
  $("page-home").classList.toggle("updating", updating);
  $("h-prog").classList.toggle("hidden", !updating);
  $("speed").classList.toggle("hidden", !updating || !(check && check.keyId));
  $("h-cards").classList.toggle("hidden", updating);
  $("h-upd").classList.toggle("hidden", !updating);
  $("lower-label").textContent = updating ? "In this update" : "In this release";
  $("lower-link").classList.toggle("hidden", updating);
  $("btn-check").disabled = working;
  if (updating) {
    const v = check ? check.version : "";
    const from = status.installed && status.installed.present ? status.installed.version : null;
    const adding = prog ? prog.rows.filter((p) => p.action === "install").map((p) => p.title) : [];
    if (from && from === v && adding.length) {
      setChip("Installing", "gold");
      setRel(v, joinNames(adding));
    } else {
      setChip("Updating", "gold");
      setRel((from && from !== v ? from + " → " : "") + v, releaseTitle(v));
    }
    setMain("PLAY", null, { play: true });
    setSecond(null);
    setNotice(null);
    setLine(null);
    return;
  }
  if (working) {
    setChip("Working", "gold");
    setMain("WORKING…", null);
    setSecond(null);
    return;
  }
  setNotice(null);
  setSecond(null);
  setLine(null);
  const inst = status.installed;
  const have = !!(inst && inst.present);
  const playMain = () => setMain("PLAY", play, { play: true });

  if (!status.flavorDir) {
    setChip("No game folder", "warn");
    setRel(null, "Pick your World of Warcraft folder to install DisasterZone.");
    setMain("CHOOSE FOLDER", pickFolder);
    return;
  }
  if (inst && (inst.dev || inst.linked)) {
    setChip("Development copy", "info");
    setRel(inst.version, null);
    playMain();
    setLine("This is a development copy of the addon: the launcher leaves it alone.");
    return;
  }
  if (checking && !check) {
    setChip("Checking", "gold busy");
    setRel(have ? inst.version : null, have ? releaseTitle(inst.version) : "Looking for the newest release…");
    if (have) playMain(); else setMain("INSTALL", null);
    return;
  }
  if (checkErr && needsNewLauncher()) { renderLauncherGate(inst); return; }
  if (checkErr) {
    setChip("Can't check", "warn");
    setRel(have ? inst.version : null, null);
    setLine(checkErr);
    if (have) { playMain(); setSecond("Try again", checkAgain); } else setMain("TRY AGAIN", checkAgain);
    return;
  }
  if (!check) {
    setChip("Not checked", "");
    setRel(have ? inst.version : null, "Updates are checked when you click the round arrow.");
    if (have) playMain(); else setMain("CHECK", checkAgain);
    return;
  }

  const size = check.downloadBytes ? fmtBytes(check.downloadBytes) + " to download" : "nothing to download";
  const ch = changing();
  if (!have) {
    const files = packs().filter((p) => p.wanted).reduce((n, p) => n + p.files, 0) || check.files;
    setChip("Not installed", "gold");
    setRel(check.version, releaseTitle(check.version));
    setMain("INSTALL", runUpdate);
    setLine(plural(files, "file", "files") + " · " + size);
  } else if (check.upToDate) {
    setChip("Up to date", "ok");
    setRel(inst.version, releaseTitle(inst.version));
    playMain();
    setLine(signedLine(), true);
  } else if (check.hold) {
    setChip("Restored", "warn");
    setRel(inst.version + " → " + check.version, releaseTitle(check.version));
    setMain("UPDATE", runUpdate);
    setSecond("Play", play, true);
    setNotice("You went back to an older version, so updates are paused until you update again.");
    setLine(describeChanges(ch) + " · " + size);
  } else if (inst.version === check.version && inst.build === check.build) {
    if (ch.some((p) => p.action === "update")) {
      setChip("Needs repair", "warn");
      setRel(inst.version, releaseTitle(inst.version));
      setMain("REPAIR", runUpdate);
      setLine(plural(check.changed + check.removed, "file differs", "files differ") + " from the signed release · " + size);
    } else {
      // (only packs coming or going: a game ticked or unticked, the 3D rooms switched)
      setChip("Changes waiting", "gold");
      setRel(inst.version, releaseTitle(inst.version));
      setMain("APPLY", runUpdate);
      setLine(describeChanges(ch) + " · " + size);
    }
    setSecond("Play", play, true);
  } else {
    setChip("Update ready", "gold");
    setRel((inst.version || "?") + " → " + check.version, releaseTitle(check.version));
    setMain("UPDATE", runUpdate);
    setSecond("Play", play, true);
    setLine(describeChanges(ch) + " · " + size);
  }
  if (check.older) setNotice("The release list looks older than one already installed from. Try again in a few minutes.");
  else if (check.needsPick && !check.upToDate) {
    setNotice("This version gives every game its own download.", "Pick your games", () => openPicker({ then: "update" }));
  } else if (status.wowRunning && !check.upToDate) setNotice("World of Warcraft is running. Restart the game after updating so it loads the new files.");
}

// The hero when the release needs a newer launcher: update it from here, or get it from the releases page.
function renderLauncherGate(inst) {
  const v = launcher.version;
  const have = !!(inst && inst.present);
  setChip("New launcher needed", "warn");
  setRel(have ? inst.version : null, "This release of DisasterZone needs a newer launcher.");
  if (have) setSecond("Play", play, true);
  if (launcher.installing) {
    setMain(launcherButtonText().toUpperCase(), null);
    setLine("Installing launcher " + v + ". It restarts by itself.");
  } else if (v) {
    setMain("UPDATE LAUNCHER", installLauncher);
    setLine("Launcher " + v + " is ready: it installs and restarts in a moment.");
  } else if (launcher.looking) {
    setMain("UPDATE LAUNCHER", null);
    setLine("Looking for it…");
  } else {
    const c = status.launcherCheck;
    setMain("GET THE LAUNCHER", () => api.invoke("open_releases").catch(toast));
    setLine("Get it from the releases page: your settings stay.");
    if (c && c.error) setNotice("The launcher couldn't update itself: " + c.error);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The update's progress: the steps, the bar, the speed graph, a row per folder. The Rust side reports
// { step, done, total, folder, folderDone, folderTotal }: download (compressed bytes; its first events give every
// folder's total), stage (files staged and checked against the release), backup (saved variables and the old
// folders), swap, done. A folder's totals come from the update itself, not from the check before it.
// ---------------------------------------------------------------------------------------------------------------

const STEPS = ["download", "stage", "backup", "swap"];
const WEIGHT = { download: [0, 70], stage: [70, 25], backup: [95, 3], swap: [98, 2], done: [100, 0] };
let prog = null;

function startProgress() {
  const list = packs().filter((p) => p.wanted && (p.action === "install" || p.action === "update" || p.required))
    .concat(packs().filter((p) => p.action === "remove"));
  // (rows in the rail's order: DisasterZone, the games, the Extras, then what leaves)
  const rank = (p) => (p.action === "remove" ? 300 : p.kind === "core" ? 0 : p.kind === "game" ? 1 + gameRank(p) : 200);
  prog = { step: "download", pct: 0, dl: {}, dlOf: {}, stage: {}, files: {}, samples: [], speeds: [], lastAt: 0, lastDone: 0, total: 0, done: 0,
    rows: list.filter((p) => p.action !== "same").sort((a, b) => rank(a) - rank(b) || a.title.localeCompare(b.title)) };
  showProgress({ step: "download", done: 0, total: check ? check.downloadBytes : 0 });
}
function endProgress() { prog = null; }

function showProgress(p) {
  if (!prog) return;
  prog.step = p.step;
  if (p.step === "download") {
    prog.total = p.total;
    prog.done = p.done;
    if (p.folder) {
      prog.dl[p.folder] = p.folderDone;
      if (p.folderTotal != null) prog.dlOf[p.folder] = p.folderTotal;
    }
    // speed: bytes over the last moment, sampled at most 4 times a second for the graph
    const t = performance.now();
    prog.samples.push([t, p.done]);
    while (prog.samples.length > 2 && t - prog.samples[0][0] > 1500) prog.samples.shift();
    if (t - prog.lastAt > 250) {
      prog.lastAt = t;
      const a = prog.samples[0], b = prog.samples[prog.samples.length - 1];
      if (b[0] > a[0]) { prog.speed = ((b[1] - a[1]) / (b[0] - a[0])) * 1000; prog.speeds.push(prog.speed); }
      if (prog.speeds.length > 80) prog.speeds.shift();
    }
  } else if (p.step === "stage" && p.folder) {
    prog.stage[p.folder] = p.folderDone;
    if (p.folderTotal) prog.files[p.folder] = p.folderTotal;
  }
  const w = WEIGHT[p.step] || [0, 100];
  const frac = p.total ? Math.min(1, p.done / p.total) : (p.step === "download" ? 0 : 1);
  prog.pct = Math.max(prog.pct, w[0] + w[1] * (p.step === "backup" || p.step === "swap" ? 0.5 : frac));
  renderProgress();
}

function renderProgress() {
  if (!prog) return;
  const pct = Math.floor(prog.pct);
  $("p-pct").textContent = pct;
  $("p-fill").style.width = pct + "%";
  $("p-head").style.left = pct + "%";
  const at = STEPS.indexOf(prog.step);
  for (const li of $("p-steps").children) {
    const i = STEPS.indexOf(li.dataset.step);
    li.className = prog.step === "done" || i < at ? "done" : i === at ? "now" : "";
  }
  const main = $("p-main"), sub = $("p-sub");
  if (prog.step === "download") {
    main.textContent = prog.total ? fmtMB(prog.done) + " of " + fmtMB(prog.total) : "Nothing to download";
    sub.textContent = prog.speed > 0 ? fmtBytes(prog.speed) + "/s · about " + duration((prog.total - prog.done) / prog.speed) + " left" : "Starting…";
  } else if (prog.step === "stage") {
    main.textContent = "Checking every file";
    sub.textContent = "against the signed release";
  } else if (prog.step === "backup") {
    main.textContent = "Backing up";
    sub.textContent = "your saved variables and the folders being replaced";
  } else if (prog.step === "swap") {
    main.textContent = "Swapping in";
    sub.textContent = "the new folders, all at once";
  } else {
    main.textContent = "Done";
    sub.textContent = "";
  }
  renderSpeed();
  renderFolders();
  paintBusy();
}

function renderSpeed() {
  const sp = prog.speeds;
  const now = prog.step === "download" && prog.speed ? prog.speed : sp.length ? sp[sp.length - 1] : 0;
  const peak = sp.length ? Math.max(...sp) : 0;
  const nowEl = $("sp-now");
  nowEl.textContent = (now / 1048576).toFixed(1);
  nowEl.append(el("span", null, "MB/s"));
  $("sp-peak").textContent = peak ? "Peak " + (peak / 1048576).toFixed(1) + " MB/s" : "";
  $("sp-key").textContent = check && check.keyId ? check.keyId.toUpperCase().replace(/(.{4})(?=.)/g, "$1 ") : "";
  const W = 294, H = 92, top = 14;
  const scale = peak > 0 ? (H - top) / peak : 0;
  const n = Math.max(sp.length, 2);
  const pts = sp.map((v, i) => [(i / (n - 1)) * W, H - v * scale]);
  if (pts.length === 1) pts.push([W, pts[0][1]]);
  const line = pts.map((q, i) => (i ? "L" : "M") + q[0].toFixed(1) + " " + q[1].toFixed(1)).join("");
  $("sp-line").setAttribute("d", line);
  $("sp-area").setAttribute("d", pts.length ? line + "L" + pts[pts.length - 1][0].toFixed(1) + " " + H + "L0 " + H + "Z" : "");
  $("sp-peakline").setAttribute("d", peak ? "M0 " + top + "H" + W : "");
}

// One folder of the update, the same in this table and on the rail: [state, bar 0..1, kind, words for the rail].
// The bar runs through both steps that touch the folder: the download fills it to DL, checking the rest.
// kind: "" waiting, "go" under way, "ok" checked or in place.
const DL = 0.7;
function folderState(p) {
  if (p.action === "remove") return prog.step === "done" ? ["Removed", 1, "ok", "Removed"] : ["Leaves", 0, "", "Leaves with this update"];
  if (p.action === "same") return ["No changes", 1, "", "No changes"];
  if (prog.step === "done") { const w = p.installed ? "Updated" : "Installed"; return [w, 1, "ok", w]; }
  const s = STEPS.indexOf(prog.step);
  if (s >= 2) return ["Checked", 1, "ok", "Checked"];
  if (s === 1) {
    const of = prog.files[p.folder] || p.files || 1;
    const n = Math.min(prog.stage[p.folder] || 0, of);
    if (n >= of) return ["Checked", 1, "ok", "Checked"];
    if (!n) return ["Downloaded", DL, "go", "Downloaded"];
    const pc = Math.floor((n / of) * 100);
    return ["Checking " + pc + "%", DL + (1 - DL) * (n / of), "go", "Checking · " + pc + "%"];
  }
  const of = prog.dlOf[p.folder];
  const got = Math.min(prog.dl[p.folder] || 0, of || 0);
  if (of === 0 || (of && got >= of)) return ["Downloaded", DL, "go", "Downloaded"];   // (of 0: it was all in the cache)
  if (!got) return ["Waiting", 0, "", "Waiting"];
  const pc = Math.floor((got / of) * 100);
  return [pc + "%", DL * (got / of), "go", "Downloading · " + pc + "%"];
}

function renderFolders() {
  const box = $("folders");
  box.textContent = "";
  const hd = el("div", "frow hd");
  for (const [t, cls] of [["Folder"], ["Files"], ["Download"], ["Progress"], ["State", "r"]]) {
    const s = el("span", "label", t);
    if (cls) s.style.textAlign = "right";
    hd.append(s);
  }
  box.append(hd);
  for (const p of prog.rows) {
    const [state, frac, cls] = folderState(p);
    const row = el("div", "frow");
    const fn = el("span", "fn");
    fn.append(img(p.kind === "game" ? "games/" + p.id + ".jpg" : "seal.png"));
    const t = el("span");
    t.append(el("b", null, p.title), el("small", null, p.folder));
    fn.append(t);
    const bar = el("span", "bar" + (cls === "ok" ? " okb" : ""));
    const fill = el("i");
    fill.style.width = Math.round(frac * 100) + "%";
    bar.append(fill);
    const files = p.action === "install" ? plural(p.files, "file", "files") : p.changed != null ? p.changed + " changed" : plural(p.files, "file", "files");
    row.append(fn, el("span", "c", p.action === "remove" ? "—" : files),
      el("span", "c", p.action === "remove" ? "—" : fmtBytes(prog.dlOf[p.folder] ?? p.downloadBytes)), bar, el("span", "st " + cls, state));
    box.append(row);
  }
  const still = packs().filter((p) => p.installed && p.action === "same").map((p) => p.title);
  if (still.length) {
    const row = el("div", "frow");
    row.append(el("span", "wide", joinNames(still) + (still.length === 1 ? " has" : " have") + " no changes."), el("span", "st", "Kept"));
    box.append(row);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The newest release's cards
// ---------------------------------------------------------------------------------------------------------------

// Raid art by a word in a heading (patch notes' banners and Home's cards); else one picked from the version.
const RAID_ART = [["naxx", "naxxramas"], ["karazhan", "karazhan"], ["kara", "karazhan"], ["gruul", "gruulslair"], ["magtheridon", "hellfirecitadelraid"],
  ["serpentshrine", "coilfang"], ["vashj", "coilfang"], ["tempest", "tempestkeep"], ["kael", "tempestkeep"], ["hyjal", "hyjal"],
  ["black temple", "blacktemple"], ["illidan", "blacktemple"], ["zul'aman", "zulaman"], ["sunwell", "sunwell"]];
const ART_CYCLE = ["karazhan", "blacktemple", "tempestkeep", "coilfang", "hyjal", "sunwell", "zulaman", "gruulslair", "naxxramas", "hellfirecitadelraid"];
function artFor(text, seed) {
  const low = (text || "").toLowerCase();
  for (const [word, art] of RAID_ART) if (low.includes(word)) return "art/raid-" + art + ".jpg";
  let h = 0;
  for (const c of String(seed || "")) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return "art/raid-" + ART_CYCLE[h % ART_CYCLE.length] + ".jpg";
}
// The game a changelog section is about, by its title in the heading.
function gameOfSection(s) {
  const h = (s.heading || "").toLowerCase();
  return games().find((p) => h.includes(p.title.toLowerCase().replace(/^the /, ""))) || null;
}

function renderNews() {
  const box = $("news");
  box.textContent = "";
  const rel = changelog()[0];
  if (!rel && releaseLoading()) {
    for (const w of ["62%", "48%", "56%"]) {
      const g = el("div", "news panel ghost");
      const bd = el("span", "bd");
      bd.append(skel("g-t", w), skel("g-ln", "94%"), skel("g-ln", "86%"), skel("g-ln", "42%"));
      g.append(skel("g-pic"), bd);
      box.append(g);
    }
    return;
  }
  if (!rel) {
    box.append(el("div", "none", checkErr ? "The newest release's changes show once the release list can be read." : "The newest release's changes show here."));
    return;
  }
  const rank = { new: 0, changed: 1, fixed: 3 };
  const picks = rel.sections.slice().sort((a, b) => (rank[a.kind] ?? 2) - (rank[b.kind] ?? 2)).slice(0, 3);
  picks.forEach((s, i) => {
    const g = gameOfSection(s);
    const card = el("button", "news panel");
    const pic = el("span", "pic");
    pic.append(img(g ? "games/" + g.id + ".jpg" : artFor(s.heading + " " + s.lead, rel.version + i), g && lookOf(g).pix ? "pix" : null));
    if (["new", "changed", "fixed"].includes(s.kind)) pic.append(el("span", "tag " + s.kind, s.kind));
    const bd = el("span", "bd");
    bd.append(el("span", "tt", s.heading), el("span", "ld", s.lead || (s.lines && s.lines[0] ? (typeof s.lines[0] === "string" ? s.lines[0] : s.lines[0].text) : "")));
    card.append(pic, bd);
    card.onclick = () => (g ? go("game", g.id) : go("notes", rel.version));
    box.append(card);
  });
}

// ---------------------------------------------------------------------------------------------------------------
// The guild's next raid (the addon writes the raids at logout: player.rs)
// ---------------------------------------------------------------------------------------------------------------

const INST_ART = { kara: "karazhan", gruul: "gruulslair", mag: "hellfirecitadelraid", ssc: "coilfang", tk: "tempestkeep",
  hyjal: "hyjal", bt: "blacktemple", za: "zulaman", swp: "sunwell" };
const ROLE_OF = { tank: "tank", healer: "heal", heal: "heal", melee: "dps", ranged: "dps", caster: "dps", dps: "dps" };

function nextRaid() {
  const now = nowSec();
  return (player.raids || []).find((r) => r.t + 6 * 3600 >= now) || null;
}

function renderRaid() {
  const box = $("raid");
  const r = nextRaid();
  box.classList.toggle("hidden", !r);
  $("h-cards").classList.toggle("noraid", !r);
  if (!r) return;
  box.textContent = "";
  box.append(img("art/raid-" + (INST_ART[r.inst] || "karazhan") + ".jpg"));
  const now = nowSec();
  const k = el("div", "k");
  k.append(el("span", "label", r.t <= now ? "Raid under way" : "Next raid"));
  if (r.size) k.append(el("span", "chip small", r.size + "-player"));
  box.append(k, el("div", "nm", r.title || r.name || "Raid"));
  box.append(el("div", "when", r.t <= now ? "Started " + clock(r.t) : dayAndTime(r.t)));

  const signups = r.signups || [];
  const count = { tank: 0, heal: 0, dps: 0 };
  for (const s of signups) if (s.st === "accept" && ROLE_OF[s.role]) count[ROLE_OF[s.role]]++;
  const need = r.need || null;
  const roles = el("div", "roles");
  for (const [key, ic, label] of [["tank", "tank", "Tanks"], ["heal", "heal", "Healers"], ["dps", "dps", "Damage"]]) {
    const role = el("div", "role");
    const rr = el("span", "rr");
    const svg = icon(ic, "s");
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", label);
    rr.append(svg, el("b", null, need ? count[key] + "/" + need[key] : String(count[key])));
    role.append(rr);
    const max = need ? need[key] : count[key];
    if (max > 0) {
      const pips = Math.min(max, 8), filled = Math.round((Math.min(count[key], max) / max) * pips);
      const pp = el("span", "pp");
      for (let i = 0; i < pips; i++) pp.append(el("i", i < filled ? "f" : null));
      role.append(pp);
    }
    role.title = label + ": " + count[key] + " signed up" + (need ? " of " + need[key] : "");
    roles.append(role);
  }
  box.append(roles);

  const mine = new Set(player.mine || []);
  const me = signups.find((s) => mine.has(s.key));
  const row = el("div", "me-row");
  const you = el("span", "you");
  if (me && me.st === "accept") { you.className = "you in"; you.append(icon("check", "s"), "You're in" + (me.spec ? " · " + me.spec : "")); }
  else if (me && me.st === "tentative") { you.className = "you maybe"; you.append("Tentative" + (me.spec ? " · " + me.spec : "")); }
  else if (me && me.st === "bench") you.append("On the bench");
  else if (me && me.st === "absent") you.append("You said you can't come");
  else you.append("Not signed up yet");
  row.append(you);
  if (player.snapAt) {
    const asof = el("span", "asof", "as of " + ago(player.snapAt));
    asof.title = "From the game's saved variables, written when you last logged out or reloaded.";
    row.append(asof);
  }
  box.append(row);
}
