// Backups: what every update (and every removed game) saved, newest first. Restore asks right on its card.
// In motion, calmly: the rows rise in when the page opens, a new backup lands with a soft gold glow, Back up now and
// Put back show their work on the page (a row being made, the card putting back), a deleted row folds away.
"use strict";

let backupsList = [];
let backupOpen = null;      // the backup whose restore is being asked
let backupBusy = null;      // { kind: "new" } while Back up now copies; { kind: "restore", id, names, done } putting back
let backupsKnown = null;    // the ids drawn last (one not among them is new: it lands with the glow)
let backupsEnter = false;   // the page just opened: the rows rise in
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

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
  if (backupBusy && backupBusy.kind === "new") box.append(pendingCard());
  else if (!backupsList.length) {
    box.append(el("div", "none", status.flavorDir ? "No backups yet. One is made before every update." : "Pick your World of Warcraft folder in Settings first."));
  }
  backupsList.forEach((b, i) => {
    const card = backupCard(b, i === 0);
    if (backupsKnown && !backupsKnown.has(b.id)) card.classList.add("fresh");
    else if (backupsEnter) { card.classList.add("enter"); card.style.setProperty("--i", i); }
    box.append(card);
  });
  backupsKnown = new Set(backupsList.map((b) => b.id));
  backupsEnter = false;
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
  const restoring = backupBusy && backupBusy.kind === "restore" && backupBusy.id === b.id;
  // (a backup from before the first install, or of a linked development folder, holds saved variables only:
  // nothing to put back, Open folder has them)
  if (!first && (b.folders || []).length && backupOpen !== b.id) {
    const btn = el("button", "btn", b.reason === "remove" ? "Put back" : "Restore");
    btn.disabled = working;
    btn.onclick = () => { backupOpen = b.id; drawBackups(); };
    rt.append(btn);
  }
  if (!restoring) {
    const bin = el("button", "ibtn bin");
    bin.append(icon("trash", "s"));
    bin.title = "Delete this backup";
    bin.setAttribute("aria-label", "Delete this backup");
    bin.disabled = working;
    bin.onclick = () => deleteBackup(b, card, title);
    rt.append(bin);
  }
  card.append(when, mid, rt);
  if (restoring) card.append(restoreWork(b));
  else if (backupOpen === b.id) card.append(restoreAsk(b, newest, folders));
  return card;
}

// The row Back up now is making: it slides in at the top while the folders are copied.
function pendingCard() {
  const card = el("div", "bk pending");
  const when = el("div", "when");
  const d = new Date();
  when.append(el("i"), el("b", null, d.toLocaleDateString(undefined, { day: "numeric", month: "short" })),
    el("span", null, d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })));
  const mid = el("div");
  mid.append(el("div", "t", "Backing up…"));
  const fol = el("div", "fol");
  fol.append(skel("g-pill", "92px"), skel("g-pill", "74px"), skel("g-pill", "118px"));
  mid.append(fol);
  const rt = el("div", "rt");
  rt.append(el("span", "sz", "Copying your folders and saved variables"), el("span", "ibar"));
  card.append(when, mid, rt);
  return card;
}

// A card putting its folders back: a moving bar while the files go back, then a moment of "is back".
function restoreWork(b) {
  const box = el("div", "confirm work" + (backupBusy.done ? " done" : ""));
  const p = el("p");
  const names = backupBusy.names;
  if (backupBusy.done) {
    p.append(icon("check", "s"), el("b", null, b.reason === "remove" ? names + (backupBusy.many ? " are" : " is") + " back" : "Back to " + (b.version || "the backup")));
  } else {
    p.append(el("b", null, (b.reason === "remove" ? "Putting " + names + " back" : "Going back to " + (b.version || "the backup")) + "…"),
      " What you have now is saved first.");
  }
  box.append(p, el("span", "ibar"));
  return box;
}

// The trash can: asked first, then the row folds away while the folder goes.
async function deleteBackup(b, card, title) {
  if (working) return;
  const ok = await confirmBox("Delete this backup?", title + (b.bytes ? " · frees " + fmtBytes(b.bytes) : "") +
    ". It is gone for good: it can't be put back afterwards.", "Delete", true);
  if (!ok) return;
  working = true;
  card.style.height = card.offsetHeight + "px";
  void card.offsetHeight;
  card.classList.add("leaving");
  try {
    await Promise.all([api.invoke("delete_backup", { id: b.id }), pause(420)]);
    toast("Backup deleted" + (b.bytes ? " · " + fmtBytes(b.bytes) + " freed" : "") + ".", true);
  } catch (e) {
    toast(e);
  }
  working = false;
  if (backupOpen === b.id) backupOpen = null;
  renderBackups();
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
  const names = joinNames((b.folders || []).map(titleOf));
  backupBusy = { kind: "restore", id: b.id, names, many: (b.folders || []).length > 1, done: false };
  drawBackups();
  try {
    // (putting folders back is quick: the bar gets its moment anyway)
    await Promise.all([api.invoke("restore", { id: b.id }), pause(1000)]);
    backupBusy.done = true;
    drawBackups();
    await pause(1100);
    toast(b.reason === "remove" ? names + (backupBusy.many ? " are" : " is") + " back." : "Restored " + (b.version || "the backup") + ".", true);
  } catch (e) {
    toast(e);
  }
  working = false;
  backupOpen = null;
  backupBusy = null;
  await refreshAll();
  renderBackups();
}

// Back up now: copies of the addon's folders and the saved variables, as a backup of its own.
async function backupNow() {
  if (working || !status || !status.flavorDir) return;
  working = true;
  const btn = $("btn-backup-now");
  btn.disabled = true;
  btn.classList.add("busy");
  $("backup-now-text").textContent = "Backing up…";
  backupBusy = { kind: "new" };
  drawBackups();
  try {
    const [id] = await Promise.all([api.invoke("backup_now"), pause(900)]);
    const list = await api.invoke("backups");
    const b = list.find((x) => x.id === id);
    const what = b && b.folders.length ? joinNames(b.folders.map(titleOf)) + (b.savedVariables ? " and your saved variables" : "") : "Your saved variables";
    toast("Backed up: " + what + (b && b.bytes ? " · " + fmtBytes(b.bytes) : "") + ".", true);
  } catch (e) {
    toast(e);
  }
  working = false;
  backupBusy = null;
  btn.disabled = false;
  btn.classList.remove("busy");
  $("backup-now-text").textContent = "Back up now";
  renderBackups();
}

function wireBackups() {
  $("btn-backup-now").onclick = backupNow;
  $("keep-minus").onclick = () => saveSettings({ keepBackups: Math.max(1, status.settings.keepBackups - 1) }).then(renderBackups);
  $("keep-plus").onclick = () => saveSettings({ keepBackups: Math.min(10, status.settings.keepBackups + 1) }).then(renderBackups);
  $("btn-open-backups").onclick = () => api.invoke("open_folder", { kind: "backups" }).catch(toast);
}
