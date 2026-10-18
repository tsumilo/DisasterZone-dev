// Start: wire the window, listen to the Rust side, read the status, check for a release.
"use strict";

async function start() {
  for (const b of document.querySelectorAll("[data-go]")) b.addEventListener("click", () => go(b.dataset.go));
  $("nav-back").onclick = goBack;
  $("nav-fwd").onclick = goForward;
  // the mouse's back / forward buttons and Alt+arrows walk the pages too
  document.addEventListener("mouseup", (e) => { if (e.button === 3) goBack(); else if (e.button === 4) goForward(); });
  document.addEventListener("keydown", (e) => {
    if (e.altKey && e.key === "ArrowLeft") goBack();
    else if (e.altKey && e.key === "ArrowRight") goForward();
    else if (e.key === "Escape" && picker) closePicker();
  });
  $("wmin").onclick = () => api.minimize();
  $("wmax").onclick = () => api.maximize();
  $("wclose").onclick = () => api.close();
  $("btn-check").onclick = checkAgain;
  $("btn-flavor").onclick = () => go("settings", "s-game");
  $("p-save").onclick = () => savePicker(false);
  $("p-all").onclick = () => savePicker(true);
  // (dismissed: nothing saved; Update asks again)
  $("picker").addEventListener("click", (e) => { if (e.target === $("picker")) closePicker(); });
  try { if (!localStorage.getItem("dz.gamesSeen")) $("games-new").classList.remove("hidden"); } catch (e) { /* (no badge) */ }
  sprinkle($("h-motes"), 18, ["", "", "au"]);
  // hidden in the tray or minimised: the animations rest
  document.addEventListener("visibilitychange", () => {
    $("win").classList.toggle("paused", document.hidden);
    filmRest(document.hidden || here().page !== "game");
  });
  wireSettings();
  wireSync();
  wireNotes();
  wireBackups();
  wireGuild();
  showPage("home");

  await api.listen("sync-status", (e) => { sync = { ...sync, ...e.payload }; if (status) renderSync(); });
  // ("checked 2 minutes ago", "synced 5 minutes ago", the raid's "as of" move on)
  setInterval(() => { if (status) { renderSync(); renderAbout(); if (!working) renderHero(); renderRaid(); } }, 30000);
  await api.listen("progress", (e) => { if (updating) showProgress(e.payload); });
  // the tray's background check installed something or found a new release
  await api.listen("state-changed", () => { if (!working) refreshAll(); });
  // the tray's check found a new launcher: the bar at once (Install fetches the update itself)
  await api.listen("launcher-update", (e) => {
    const v = e.payload && e.payload.version;
    if (!v || launcher.installing || v === launcher.version) return;
    if (launcher.upd && launcher.upd.version !== v) launcher.upd = null;
    launcher.version = v;
    renderLauncher();
  });
  await api.listen("launcher-check", (e) => { if (status) { status.launcherCheck = e.payload; renderAbout(); } });
  // back from the tray: the window may have sat hidden for days (the game may have been played meanwhile)
  await api.listen("window-shown", () => {
    $("win").classList.remove("paused");
    loadPlayer();
    loadGuild();
    if (Date.now() - launcher.at > SHOWN_GAP_MS) checkLauncherUpdate();
  });
  try {
    sync = await api.invoke("sync_status");
    await loadStatus();
  } catch (e) {
    toast(e);
    return;
  }
  loadPlayer();
  loadGuild();
  if (status.settings.checkOnStart || !status.installed || !status.installed.present) await runCheck();
  else renderHero();
  checkLauncherUpdate();
  if (DEMO) {
    const q = new URLSearchParams(location.search);
    const page = q.get("page") || { games: "library", changelog: "notes" }[q.get("tab")] || q.get("tab");
    if (page) go(page, q.get("arg"));
    if (["updating", "checking"].includes(q.get("state"))) doUpdate();
  }
  setInterval(() => { if (!working && !checking) runCheck(); checkLauncherUpdate(); }, RECHECK_MS);
}

start();
