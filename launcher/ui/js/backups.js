// Backups: what every update (and every removed game) saved, newest first. Restore asks right on its card.
"use strict";

let backupsList = [];
let backupOpen = null;      // the backup whose restore is being asked

async function renderBackups() {
  const box = $("backups");
  if (!status) return;
  $("keep").textContent = status.settings.keepBackups;
  try {
    backupsList = status.flavorDir ? await api.invoke("backups") : [];
  } catch (e) {
    box.textContent = "";
    box.append(el("div", "none", String(e)));
    return;
  }
  drawBackups();
}

function backupTime(b) {
  const when = b.id.slice(0, 15).replace(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/, "$1-$2-$3T$4:$5:$6Z");
  const d = new Date(when);
  return isNaN(d) ? null : d;
}

function drawBackups() {
  const box = $("backups");
  box.textContent = "";
  const total = backupsList.reduce((n, b) => n + (b.bytes || 0), 0);
  $("b-kept").textContent = backupsList.length ? backupsList.length + " · " + fmtBytes(total) : "None yet";
  if (!backupsList.length) {
    box.append(el("div", "none", status.flavorDir ? "No backups yet. One is made before every update." : "Pick your World of Warcraft folder in Settings first."));
  }
  backupsList.forEach((b, i) => box.append(backupCard(b, i === 0)));
  const where = el("div", "where");
  where.append(icon("folder", "s"), el("span", null, "Backups live next to your addons, in"),
    el("code", null, (status.flavorDir || "…") + "\\Interface\\DZLauncher\\backups"),
    el("span", null, "· the oldest goes when a new one would make " + (status.settings.keepBackups + 1) + "."));
  box.append(where);
}

function backupCard(b, newest) {
  const folders = (b.folders || []).map(titleOf);
  const first = (b.added || []).includes("DisasterZone");
  const card = el("div", "bk" + (backupOpen === b.id ? " open" : newest ? " first" : ""));
  const d = backupTime(b);
  const when = el("div", "when");
  when.append(el("i"), el("b", null, d ? d.toLocaleDateString(undefined, { day: "numeric", month: "short" }) : "?"),
    el("span", null, d ? d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }) : ""));
  const mid = el("div");
  const title = first ? "Before the first install"
    : b.reason === "manual" ? (folders.length ? "Your backup of " + (b.version || "the addon") : "Your backup of the saved variables")
    : b.reason === "remove" ? "Before removing " + joinNames(folders)
    : b.reason === "restore" ? "Before a restore"
    : "Version " + (b.version || "?") + ", before an update";
  mid.append(el("div", "t", title));
  const fol = el("div", "fol");
  for (const f of b.folders || []) {
    const p = packOfFolder(f);
    const pill = el("span", "pill");
    const sw = el("i");
    sw.style.background = "rgb(" + (p ? colorOf(p) : f === "DisasterZone_Rooms" ? ROOMS_COLOR : "226, 184, 74") + ")";
    pill.append(sw, titleOf(f) + (f === "DisasterZone" && b.version ? " " + b.version : ""));
    fol.append(pill);
  }
  if (b.savedVariables) fol.append(el("span", "pill sv", "Saved variables"));
  mid.append(fol);
  const rt = el("div", "rt");
  if (b.bytes) rt.append(el("span", "sz", fmtBytes(b.bytes)));
  // (a backup from before the first install, or of a linked development folder, holds saved variables only:
  // nothing to put back, Open folder has them)
  if (!first && (b.folders || []).length && backupOpen !== b.id) {
    const btn = el("button", "btn", b.reason === "remove" ? "Put back" : "Restore");
    btn.disabled = working;
    btn.onclick = () => { backupOpen = b.id; drawBackups(); };
    rt.append(btn);
  }
  card.append(when, mid, rt);
  if (backupOpen === b.id) card.append(restoreAsk(b, newest, folders));
  return card;
}

// The restore question, on the card: what goes back, and that what's there now is saved first.
function restoreAsk(b, newest, folders) {
  const box = el("div", "confirm");
  const p = el("p");
  const names = joinNames(folders);
  if (b.reason === "remove") {
    p.append(el("b", null, "Put " + names + " back?"), " " + names + " goes back in as it was when you removed it" +
      (newest ? "" : ", and what changed after that is undone first") + ". What you have now is backed up first, and updates pause until you update again.");
  } else if (b.reason === "manual") {
    p.append(el("b", null, "Go back to your backup?"), " " + names + " go back to how they were when you made it" +
      (b.version ? " (version " + b.version + ")" : "") + ". What you have now is backed up first, and updates pause until you update again. Your saved variables are not touched: they are in the backup's folder if you want them.");
  } else {
    p.append(el("b", null, "Go back to " + (b.version || "this backup") + "?"), " The addon goes back to version " + (b.version || "?") +
      ", with the games as they were then. What you have now is backed up first, and updates pause until you update again. Your saved variables are not touched.");
  }
  const wow = el("span", "ready" + (status.wowRunning ? " warn" : ""));
  wow.append(icon(status.wowRunning ? "info" : "check", "s"), status.wowRunning ? "World of Warcraft is running: close it first, its files are in use" : "World of Warcraft is closed");
  p.append(wow);
  const cancel = el("button", "btn ghost", "Cancel");
  cancel.onclick = () => { backupOpen = null; drawBackups(); };
  const ok = el("button", "btn gold", b.reason === "remove" ? "Put back" : "Restore " + (b.version || ""));
  ok.disabled = working;
  ok.onclick = () => restoreBackup(b);
  box.append(p, cancel, ok);
  return box;
}

async function restoreBackup(b) {
  if (working) return;
  working = true;
  drawBackups();
  const names = joinNames((b.folders || []).map(titleOf));
  try {
    await api.invoke("restore", { id: b.id });
    toast(b.reason === "remove" ? names + ((b.folders || []).length > 1 ? " are" : " is") + " back." : "Restored " + (b.version || "the backup") + ".", true);
  } catch (e) {
    toast(e);
  }
  working = false;
  backupOpen = null;
  await refreshAll();
  renderBackups();
}

// Back up now: copies of the addon's folders and the saved variables, as a backup of its own.
async function backupNow() {
  if (working || !status || !status.flavorDir) return;
  working = true;
  const btn = $("btn-backup-now");
  btn.disabled = true;
  $("backup-now-text").textContent = "Backing up…";
  drawBackups();
  try {
    const id = await api.invoke("backup_now");
    const list = await api.invoke("backups");
    const b = list.find((x) => x.id === id);
    const what = b && b.folders.length ? joinNames(b.folders.map(titleOf)) + (b.savedVariables ? " and your saved variables" : "") : "Your saved variables";
    toast("Backed up: " + what + (b && b.bytes ? " · " + fmtBytes(b.bytes) : "") + ".", true);
  } catch (e) {
    toast(e);
  }
  working = false;
  btn.disabled = false;
  $("backup-now-text").textContent = "Back up now";
  renderBackups();
}

function wireBackups() {
  $("btn-backup-now").onclick = backupNow;
  $("keep-minus").onclick = () => saveSettings({ keepBackups: Math.max(1, status.settings.keepBackups - 1) }).then(renderBackups);
  $("keep-plus").onclick = () => saveSettings({ keepBackups: Math.min(10, status.settings.keepBackups + 1) }).then(renderBackups);
  $("btn-open-backups").onclick = () => api.invoke("open_folder", { kind: "backups" }).catch(toast);
}
