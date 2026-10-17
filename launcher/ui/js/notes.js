// Patch notes: the releases on a timeline, one release at a time (banner, area filters, its sections), and a search
// over every release the list carries (release.py puts the newest entries of Data/Changelog.lua in the notes).
"use strict";

const AREA_NAMES = { games: "Games", raids: "Raids", guild: "Guild", gear: "Gear", loot: "Loot", look: "Look", class: "Class tools", other: "Other", fixes: "Fixes" };
let notesSel = null;       // the release shown
let notesArea = "all";
let notesQuery = "";

function installedVersion() { return status && status.installed && status.installed.present ? status.installed.version : null; }

// The rail's dot: a release whose notes weren't opened yet.
function renderNotesDot() {
  const top = changelog()[0];
  let seen = null;
  try { seen = localStorage.getItem("dz.notesSeen"); } catch (e) { /* (the dot shows) */ }
  $("notes-dot").classList.toggle("hidden", !top || seen === top.version);
}

function openNotes(version) {
  if (version) { notesSel = version; notesArea = "all"; }
  const top = changelog()[0];
  if (top) { try { localStorage.setItem("dz.notesSeen", top.version); } catch (e) { /* (no memory) */ } }
  renderNotesDot();
  renderNotes();
}

function renderNotes() {
  const list = changelog();
  const tl = $("n-list");
  tl.textContent = "";
  const doc = $("n-doc");
  if (!list.length && releaseLoading()) {
    doc.textContent = "";
    for (const w of ["70%", "54%", "62%", "48%", "66%"]) {
      const g = el("li", "ghost");
      const tx = el("span");
      tx.append(skel("g-v"), skel("g-t", w), skel("g-s"));
      g.append(el("span", "node"), tx);
      tl.append(g);
    }
    const body = el("div", "dbody2");
    for (const w of ["30%", "96%", "88%", "92%", "60%"]) body.append(skel(w === "30%" ? "g-h" : "g-ln", w));
    doc.append(skel("g-ban"), body);
    return;
  }
  if (!list.length) {
    doc.textContent = "";
    doc.append(el("div", "muted pad", checkErr ? "The patch notes show once the release list can be read: " + checkErr : "The patch notes show once the release list has been read."));
    return;
  }
  if (!notesSel || !list.find((r) => r.version === notesSel)) notesSel = list[0].version;
  const have = installedVersion();
  const haveAt = list.findIndex((r) => r.version === have);
  list.forEach((r, i) => {
    const li = el("li");
    const b = el("button", r.version === notesSel && !notesQuery ? "on" : null);
    const tx = el("span");
    const d = el("span", "d", r.date);
    if (r.version === have) d.append(" · ", el("em", null, "installed"));
    else if (haveAt > 0 && i < haveAt) d.append(" · ", el("em", "nw", "new"));
    tx.append(el("span", "v", r.version), el("span", "t", r.title || "DisasterZone " + r.version), d);
    b.append(el("span", "node"), tx);
    b.onclick = () => { notesSel = r.version; notesArea = "all"; notesQuery = ""; $("n-search").value = ""; renderNotes(); doc.scrollTop = 0; };
    li.append(b);
    tl.append(li);
  });
  doc.textContent = "";
  if (notesQuery.length >= 2) renderHits(doc, list);
  else renderRelease(doc, list.find((r) => r.version === notesSel));
}

function lineOf(l) { return typeof l === "string" ? { text: l } : l || { text: "" }; }

// One section: its kind, heading, lead and lines (who asked for a line, and who a line is for).
function sectionCard(s, q, feat) {
  const card = el("div", "sec" + (feat ? " feat" : ""));
  const hd = el("div", "hd");
  if (["new", "changed", "fixed"].includes(s.kind)) hd.append(el("span", "tag " + s.kind, s.kind));
  const h = el("b");
  h.append(marked(s.heading || "", q));
  hd.append(h);
  card.append(hd);
  if (s.lead) { const ld = el("div", "ld"); ld.append(marked(s.lead, q)); card.append(ld); }
  const lines = (s.lines || []).map(lineOf).filter((l) => !q || l.text.toLowerCase().includes(q.toLowerCase())
    || (s.heading || "").toLowerCase().includes(q.toLowerCase()));
  if (lines.length) {
    const ul = el("ul", "dl");
    for (const l of lines) {
      const li = el("li");
      li.append(marked(l.text, q));
      if (l.for) li.append(el("span", "for", l.for.split(" ").join(", ")));
      if (l.by && l.by.length) li.append(el("span", "who", "asked by " + joinNames(l.by)));
      ul.append(li);
    }
    card.append(ul);
  }
  return card;
}

function renderRelease(doc, r) {
  const ban = el("div", "ban");
  const g = r.sections.map(gameOfSection).find(Boolean);
  ban.append(img(artFor(r.sections.map((s) => s.heading).join(" "), r.version)));
  const inn = el("div", "in");
  const ver = el("div", "ver");
  ver.append(el("b", null, "RELEASE " + r.version));
  const have = installedVersion();
  if (r.version === have) { const c = el("span", "chip ok small"); c.append(el("span", "pip"), "Installed"); ver.append(c); }
  else if (check && r.version === check.version && !check.upToDate) { const c = el("span", "chip gold small"); c.append(el("span", "pip"), "Ready to install"); ver.append(c); }
  const h2 = el("h2", null, r.title || "DisasterZone " + r.version);
  inn.append(ver, h2, el("div", "dt", r.date + " · " + plural(r.sections.length, "section", "sections")));
  ban.append(inn);
  doc.append(ban);

  const body = el("div", "dbody2");
  const areas = {};
  for (const s of r.sections) if (s.area) areas[s.area] = (areas[s.area] || 0) + 1;
  const keys = Object.keys(areas);
  if (keys.length > 1) {
    const f = el("div", "filters");
    const chip = (key, label, n) => {
      const b = el("button", notesArea === key ? "on" : null, label);
      b.append(el("span", null, String(n)));
      b.onclick = () => { notesArea = key; renderNotes(); };
      f.append(b);
    };
    chip("all", "All", r.sections.length);
    for (const k of keys) chip(k, AREA_NAMES[k] || k, areas[k]);
    body.append(f);
  } else notesArea = "all";
  const secs = r.sections.filter((s) => notesArea === "all" || s.area === notesArea);
  const grid = el("div", "secs");
  doc.style.setProperty("--tint", g ? lookOf(g).accent : "226, 184, 74");
  secs.forEach((s, i) => grid.append(sectionCard(s, "", i === 0 && notesArea === "all" && secs.length > 2)));
  body.append(grid);
  doc.append(body);
}

function renderHits(doc, list) {
  const q = notesQuery;
  const box = el("div", "hits");
  let n = 0;
  for (const r of list) {
    const hit = r.sections.filter((s) => [s.heading, s.lead, ...(s.lines || []).map((l) => lineOf(l).text)].some((t) => (t || "").toLowerCase().includes(q.toLowerCase())));
    if (!hit.length) continue;
    n += hit.length;
    const head = el("div", "h-row");
    head.append(el("span", "rv", r.version + " · " + (r.title || "")), el("span", "muted", r.date));
    box.append(head);
    const grid = el("div", "secs");
    for (const s of hit) grid.append(sectionCard(s, q, false));
    box.append(grid);
  }
  if (!n) box.append(el("div", "muted", "Nothing in the patch notes says “" + q + "”."));
  doc.append(box);
}

function wireNotes() {
  const f = $("n-search");
  f.addEventListener("input", () => { notesQuery = f.value.trim(); renderNotes(); $("n-doc").scrollTop = 0; });
  f.addEventListener("keydown", (e) => { if (e.key === "Escape") { f.value = ""; notesQuery = ""; renderNotes(); } });
}
