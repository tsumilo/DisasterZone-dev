// The title bar's "online now" (sync.rs presence; the bot's presence.rs): who of the guild is in World of Warcraft,
// as the guild's linked launchers report it. A pill with the faces of who is in game; a card with all of them and
// who was on lately. Hidden while this launcher isn't linked to Discord, or nobody has been seen yet.
"use strict";

let guild = { linked: false, now: 0, people: [], error: null };
const GUILD_MS = 60 * 1000;
const GUILD_RECENT = 7 * 86400;    // (who was on in the last week shows under "Earlier")

async function loadGuild() {
  if (document.hidden) return;
  try {
    guild = await api.invoke("presence");
  } catch (e) {
    guild = { linked: false, now: 0, people: [], error: String(e) };
  }
  renderGuild();
}

function guildName(p) { return p.character ? p.character.split("-")[0] : p.user; }

function guildFace(p) {
  const f = el("span", "av");
  const cls = CLASSES[p.class];
  f.style.setProperty("--cls", cls ? cls[1] : "160, 160, 170");
  f.textContent = guildName(p).slice(0, 1).toUpperCase();
  return f;
}

// "for 1 h 20 min" in game, "3 h ago" otherwise
function guildWhen(p, now) {
  const s = Math.max(0, now - (p.inGame ? p.since : p.seen));
  const m = Math.floor(s / 60), h = Math.floor(m / 60), d = Math.floor(h / 24);
  const span = d ? d + " d" : h ? h + " h" + (m % 60 && h < 10 ? " " + (m % 60) + " min" : "") : Math.max(1, m) + " min";
  return p.inGame ? span : span + " ago";
}

function renderGuild() {
  const now = guild.now || nowSec();
  const people = (guild.people || []).filter((p) => p.inGame || now - p.seen < GUILD_RECENT);
  const show = guild.linked && !guild.error && people.length > 0;
  $("guild").classList.toggle("hidden", !show);
  if (!show) { closeGuild(); return; }
  const on = people.filter((p) => p.inGame);
  const stack = $("guild-stack");
  stack.textContent = "";
  for (const p of on.slice(0, 4)) stack.append(guildFace(p));
  $("guild-text").textContent = on.length ? on.length + " in game" : "No one in game";
  const pill = $("guild-pill");
  pill.classList.toggle("quiet", !on.length);
  pill.title = on.length ? "In game: " + joinNames(on.map(guildName)) : "Nobody from the guild is in game right now";

  $("guild-count").textContent = on.length + " of " + people.length;
  const list = $("guild-list");
  list.textContent = "";
  const section = (title, rows) => {
    if (!rows.length) return;
    list.append(el("div", "gp-sec", title));
    for (const p of rows) {
      const row = el("div", "gp-row" + (p.inGame ? " on" : ""));
      const cls = CLASSES[p.class];
      const who = el("span", "gp-who");
      const nm = el("b", null, guildName(p));
      if (cls) nm.style.color = "rgb(" + cls[1] + ")";
      who.append(nm, el("span", null, [p.spec, cls ? cls[0] : null].filter(Boolean).join(" ") + (p.character ? " · " + p.user : "")));
      row.append(guildFace(p), who, el("span", "gp-t", guildWhen(p, now)));
      list.append(row);
    }
  };
  section("In game", on);
  section("Earlier", people.filter((p) => !p.inGame));
}

function openGuild(open) {
  $("guild-pop").classList.toggle("open", open);
  $("guild-pill").setAttribute("aria-expanded", String(open));
}
function closeGuild() { openGuild(false); }

function wireGuild() {
  $("guild-pill").onclick = (e) => { e.stopPropagation(); openGuild(!$("guild-pop").classList.contains("open")); };
  $("guild-pop").onclick = (e) => e.stopPropagation();
  $("guild-settings").onclick = () => { closeGuild(); go("settings", "s-discord"); };
  document.addEventListener("click", closeGuild);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeGuild(); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) loadGuild(); });
  setInterval(loadGuild, GUILD_MS);
}
