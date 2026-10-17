// Small helpers every page uses: elements, icons, numbers, dates, names.
"use strict";

const $ = (id) => document.getElementById(id);

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

// Line icons (24x24, stroke): the same set as the markup's.
const ICON = {
  check: ["M5 12.5l4.5 4.5L19 7.5"],
  down: ["M12 5v10", "M7.5 10.5 12 15l4.5-4.5", "M6 19h12"],
  wait: ["M12 4a8 8 0 1 0 0 16a8 8 0 1 0 0-16", "M12 8v4l2.5 1.5"],
  folder: ["M3.5 7.5a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v7.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"],
  trash: ["M4.5 7h15", "M9.5 7V4.5h5V7", "M6.5 7l1 12.5h9l1-12.5"],
  chev: ["M9.5 6l6 6-6 6"],
  shield: ["M12 3l7.5 3v6c0 4.4-3.2 8-7.5 9-4.3-1-7.5-4.6-7.5-9V6z", "M8.8 12.2l2.3 2.3 4.2-4.6"],
  tank: ["M12 3l7 3v5c0 4-3 7.5-7 9-4-1.5-7-5-7-9V6z"],
  heal: ["M10 4h4v6h6v4h-6v6h-4v-6H4v-4h6z"],
  dps: ["M14.5 4H20v5.5L10 19.5l-5.5-5.5z", "M4 20l3-3"],
  cube: ["M12 3l8 4.5v9L12 21l-8-4.5v-9z", "M4 7.5l8 4.5 8-4.5M12 12v9"],
  restore: ["M3.5 12a8.5 8.5 0 1 0 2.6-6.1", "M3.5 4v4.5H8"],
  info: ["M12 3.5a8.5 8.5 0 1 0 0 17a8.5 8.5 0 1 0 0-17", "M12 11v5.5M12 7.5v.5"],
};
const SVGNS = "http://www.w3.org/2000/svg";

function icon(name, cls) {
  const s = document.createElementNS(SVGNS, "svg");
  s.setAttribute("viewBox", "0 0 24 24");
  s.setAttribute("class", "ico" + (cls ? " " + cls : ""));
  s.setAttribute("aria-hidden", "true");
  for (const d of ICON[name] || []) {
    const p = document.createElementNS(SVGNS, "path");
    p.setAttribute("d", d);
    s.append(p);
  }
  return s;
}

// A placeholder (a line, a picture's block) with a sheen passing over it, while what goes there is on its way.
function skel(cls, width) {
  const s = el("span", "skel" + (cls ? " " + cls : ""));
  if (width) s.style.width = width;
  s.setAttribute("aria-hidden", "true");
  return s;
}

function img(src, cls, alt) {
  const i = el("img", cls);
  i.src = src;
  i.alt = alt || "";
  i.draggable = false;
  return i;
}

function fmtBytes(n) {
  n = n || 0;
  if (n < 1024) return n + " B";
  if (n < 1024 * 1024) return Math.round(n / 1024) + " KB";
  const mb = n / 1048576;
  return (mb < 10 ? mb.toFixed(1) : Math.round(mb)) + " MB";
}
function fmtMB(n) { return (n / 1048576).toFixed(1) + " MB"; }
function fmtDate(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return isNaN(d) ? iso : d.toLocaleDateString(undefined, { day: "numeric", month: "long", year: "numeric" });
}
function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
function joinNames(a) { return a.length < 2 ? a.join("") : a.slice(0, -1).join(", ") + " and " + a[a.length - 1]; }
function nowSec() { return Math.floor(Date.now() / 1000); }
function ago(t) {
  const s = Math.max(0, nowSec() - t);
  return s < 60 ? "just now" : s < 3600 ? plural(Math.floor(s / 60), "minute", "minutes") + " ago"
    : s < 86400 ? plural(Math.floor(s / 3600), "hour", "hours") + " ago" : plural(Math.floor(s / 86400), "day", "days") + " ago";
}
function duration(s) {
  s = Math.max(0, Math.round(s));
  if (s < 60) return plural(s, "second", "seconds");
  if (s < 3600) return plural(Math.round(s / 60), "minute", "minutes");
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600);
  return d ? d + " d " + h + " h" : h + " h " + Math.floor((s % 3600) / 60) + " min";
}
function clock(t) { return new Date(t * 1000).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }); }
// "Today · 19:30", "Tomorrow · 19:30", "Thursday 22 October · 19:30"
function dayAndTime(t) {
  const d = new Date(t * 1000), today = new Date();
  const days = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - new Date(today.getFullYear(), today.getMonth(), today.getDate())) / 86400000);
  const day = days === 0 ? "Today" : days === 1 ? "Tomorrow"
    : d.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" });
  return day + " · " + clock(t);
}

// Text with every match of `q` marked (search results), as nodes.
function marked(text, q) {
  const frag = document.createDocumentFragment();
  if (!q) { frag.append(text); return frag; }
  const low = text.toLowerCase(), ql = q.toLowerCase();
  let i = 0;
  for (;;) {
    const j = low.indexOf(ql, i);
    if (j < 0) break;
    if (j > i) frag.append(text.slice(i, j));
    frag.append(el("mark", null, text.slice(j, j + q.length)));
    i = j + q.length;
  }
  frag.append(text.slice(i));
  return frag;
}

const FLAVOR_NAMES = { _anniversary_: "Anniversary", _classic_era_: "Classic Era", _classic_: "Classic", _retail_: "Retail" };

// WoW's class colours (TBC: the Shaman is blue)
const CLASSES = {
  WARRIOR: ["Warrior", "199, 156, 110"], PALADIN: ["Paladin", "245, 140, 186"], HUNTER: ["Hunter", "171, 212, 115"],
  ROGUE: ["Rogue", "255, 245, 105"], PRIEST: ["Priest", "235, 235, 235"], SHAMAN: ["Shaman", "0, 112, 222"],
  MAGE: ["Mage", "105, 204, 240"], WARLOCK: ["Warlock", "148, 130, 201"], DRUID: ["Druid", "255, 125, 10"],
};

// Drifting motes in a hero: n of them, colours from `kinds` ("" pale, "au" gold, "em" ember).
function sprinkle(box, n, kinds) {
  box.textContent = "";
  for (let i = 0; i < n; i++) {
    const m = el("i");
    const k = kinds[i % kinds.length];
    m.className = [(i % 2 ? "l" : "r"), ["sm", "", "lg", "sm"][i % 4], k].filter(Boolean).join(" ");
    m.style.left = ((i * 97) % 100 + (i % 3) * 1.3).toFixed(1) + "%";
    const d = 12 + ((i * 7) % 13);
    m.style.animationDuration = d + "s";
    m.style.animationDelay = -((i * 3.7) % d).toFixed(1) + "s";
    box.append(m);
  }
}
