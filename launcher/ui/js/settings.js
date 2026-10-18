// Settings: the game folder and version, updates, tray mode, Play, the Discord sync (sync.rs), the advanced
// addresses and About. The section list on the left scrolls to a section and follows the scrolling.
"use strict";

function segment(box, items, current, onPick) {
  box.textContent = "";
  for (const [value, label] of items) {
    const b = el("button", value === current ? "on" : null, label);
    b.onclick = () => { if (value !== current) onPick(value); };
    box.append(b);
  }
}

async function saveSettings(patch, recheck) {
  try {
    await api.invoke("set_settings", patch);
  } catch (e) {
    toast(e);
  }
  if (recheck) { check = null; checkErr = null; }   // (another version's list: placeholders until it is read)
  await loadStatus();
  if (recheck) await runCheck();
}

async function setPath(path, flavor) {
  try {
    await api.invoke("set_wow_path", { path, flavor: flavor || null });
  } catch (e) {
    toast(e);
    return;
  }
  check = null;
  checkErr = null;
  await refreshAll();
}

async function pickFolder() {
  const path = await api.pickFolder();
  if (path) await setPath(path);
}

function renderSettings() {
  if (!status) return;
  const s = status.settings;
  $("set-path").textContent = s.wowRoot || "Not set";
  const installs = status.installs || [];
  const here0 = installs.find((w) => s.wowRoot && w.root.toLowerCase() === s.wowRoot.toLowerCase());
  const found = $("set-found");
  found.className = "rd" + (here0 ? " found" : s.wowRoot ? " bad" : "");
  found.textContent = here0 ? "Found, with " + plural(here0.flavors.length, "game version", "game versions") + " inside"
    : s.wowRoot ? "Not found on this computer" : "Pick the folder Battle.net installed World of Warcraft in.";
  $("row-installs").classList.toggle("hidden", installs.length < 2);
  segment($("set-installs"), installs.map((w) => [w.root, w.root]), s.wowRoot, (root) => setPath(root));
  const flavors = here0 ? here0.flavors : [s.flavor];
  segment($("set-flavor"), flavors.map((f) => [f, FLAVOR_NAMES[f] || f]), s.flavor, (f) => setPath(s.wowRoot, f));
  $("set-addons").textContent = status.flavorDir ? status.flavorDir + "\\Interface\\AddOns" : "No game folder yet";
  $("btn-open-addons").disabled = !status.flavorDir;
  for (const b of $("set-channel").children) {
    b.className = b.dataset.v === s.channel ? "on" : "";
    b.onclick = () => { if (b.dataset.v !== s.channel) saveSettings({ channel: b.dataset.v }, true); };
  }
  $("set-check").setAttribute("aria-checked", String(!!s.checkOnStart));
  $("set-tray").setAttribute("aria-checked", String(!!s.tray));
  $("set-auto").setAttribute("aria-checked", String(!!s.autoInstall));
  $("set-autostart").setAttribute("aria-checked", String(!!s.autostart));
  $("set-presence").setAttribute("aria-checked", String(s.showPresence !== false));
  $("row-auto").classList.toggle("off", !s.tray);           // (both need tray mode)
  $("row-autostart").classList.toggle("off", !s.tray);
  for (const [id, key] of [["set-code", "launchCode"], ["set-cmd", "playCommand"], ["set-source", "source"]]) {
    const f = $(id);
    if (document.activeElement !== f) f.value = s[key] || "";
  }
  $("set-source").placeholder = status.source;
  $("keep").textContent = s.keepBackups;
  renderSync();
  renderAbout();
}

// About: the version, and how the newest look for a new launcher went (the window's or the tray's).
function renderAbout() {
  $("about").textContent = "DisasterZone Launcher " + status.launcherVersion + " · releases from " + status.source;
  const c = status.launcherCheck;
  const line = $("about-check");
  line.className = "rd" + (c && c.error ? " bad" : "");
  line.textContent = !c ? ""
    : c.error ? "Launcher update check failed: " + c.error + " · " + ago(c.at)
    : c.found ? "Launcher " + c.found + " is ready · checked " + ago(c.at)
    : "No newer launcher · checked " + ago(c.at);
}

function showSection(id) {
  const sec = $(id);
  if (sec) sec.scrollIntoView({ block: "start" });
}

function wireSettings() {
  $("btn-pick").onclick = pickFolder;
  $("btn-open-addons").onclick = () => api.invoke("open_folder", { kind: "addons" }).catch(toast);
  $("set-check").onclick = () => saveSettings({ checkOnStart: !status.settings.checkOnStart });
  $("set-tray").onclick = () => saveSettings({ tray: !status.settings.tray });
  $("set-presence").onclick = () => saveSettings({ showPresence: status.settings.showPresence === false });
  $("set-auto").onclick = () => { if (status.settings.tray) saveSettings({ autoInstall: !status.settings.autoInstall }); };
  $("set-autostart").onclick = () => { if (status.settings.tray) saveSettings({ autostart: !status.settings.autostart }); };
  const field = (id, key, recheck) => {
    const f = $(id);
    const save = () => { if ((status.settings[key] || "") !== f.value.trim()) saveSettings({ [key]: f.value }, recheck); };
    f.addEventListener("change", save);
    f.addEventListener("keydown", (e) => { if (e.key === "Enter") f.blur(); });
  };
  field("set-code", "launchCode");
  field("set-cmd", "playCommand");
  field("set-source", "source", true);
  // the section list: a click scrolls there, scrolling lights the section in view
  const scroller = $("s-scroll");
  for (const b of $("snav").querySelectorAll("[data-sec]")) b.onclick = () => showSection(b.dataset.sec);
  settingsSpy = () => {
    if (!scroller.clientHeight) return;   // (the page is hidden)
    let cur = null;
    for (const sec of scroller.querySelectorAll(".sc")) if (sec.offsetTop - scroller.scrollTop <= 40) cur = sec.id;
    if (scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 4) cur = "s-about";
    for (const b of $("snav").querySelectorAll("[data-sec]")) b.classList.toggle("on", b.dataset.sec === (cur || "s-game"));
  };
  scroller.addEventListener("scroll", () => settingsSpy());
}
let settingsSpy = () => {};

// ---------------------------------------------------------------------------------------------------------------
// Discord sync (sync.rs): this PC's game syncs with the guild's bot server once linked with a /launcher code
// ---------------------------------------------------------------------------------------------------------------

let sync = { linked: false, user: "", server: "", last: null, waiting: 0, error: null };

function renderSync() {
  const st = $("sync-state");
  $("row-link").classList.toggle("hidden", sync.linked);
  $("sync-linked-btns").classList.toggle("hidden", !sync.linked);
  if (!sync.linked) {
    st.textContent = sync.server ? "Not linked." : "No bot server is set yet.";
    st.className = "rd";
  } else if (sync.error) {
    st.textContent = "Linked as " + sync.user + " · " + sync.error;
    st.className = "rd bad";
  } else {
    const waiting = sync.waiting ? " · " + plural(sync.waiting, "change", "changes") + " from Discord waiting for the game" : "";
    st.textContent = "Linked as " + sync.user + (sync.last ? " · synced " + ago(sync.last) : " · not synced yet") + waiting;
    st.className = "rd good";
  }
  const f = $("set-server");
  if (document.activeElement !== f) f.value = status.settings.syncServer || "";
  f.placeholder = sync.server || "not set";
}

async function syncCall(cmd, args) {
  try {
    sync = await api.invoke(cmd, args);
  } catch (e) {
    toast(e);
    try { sync = await api.invoke("sync_status"); } catch (e2) { /* (shown as it was) */ }
  }
  renderSync();
}

function wireSync() {
  const code = $("set-linkcode");
  const link = () => {
    const v = code.value.trim();
    if (!v) { code.focus(); return; }
    $("btn-link").disabled = true;
    syncCall("sync_link", { code: v }).then(() => { $("btn-link").disabled = false; if (sync.linked) code.value = ""; });
  };
  $("btn-link").onclick = link;
  code.addEventListener("keydown", (e) => { if (e.key === "Enter") link(); });
  $("btn-sync").onclick = () => syncCall("sync_run").then(loadPlayer);
  $("btn-unlink").onclick = () => syncCall("sync_unlink");
  const f = $("set-server");
  f.addEventListener("change", () => {
    if ((status.settings.syncServer || "") !== f.value.trim()) saveSettings({ syncServer: f.value }).then(() => syncCall("sync_status"));
  });
  f.addEventListener("keydown", (e) => { if (e.key === "Enter") f.blur(); });
}
