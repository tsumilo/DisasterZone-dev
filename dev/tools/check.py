#!/usr/bin/env python
"""DisasterZone static checker: Lua 5.1 syntax + global reads/writes via bytecode analysis.

Usage:
    luaenv\\Scripts\\python.exe tools\\check.py [paths...] [--libs] [--rebuild-known] [--strict]
                                                 [--quiet] [--json] [--no-events]

Default target: every .lua file under the DisasterZone addon folder, excluding Libs/ unless --libs.
Paths may be files or directories (absolute, or relative to the CWD or to the addon folder).

Output lines (grep-friendly):
    <file>:<line>: ERROR syntax: <lua message>
    <file>:<line>: ERROR global write 'name' (SETGLOBAL; missing 'local'?)
    <file>:<line>: WARN _G write 'name' (explicit _G.name = ...; not in allowlist)
    <file>:<line>: WARN UNKNOWN GLOBAL 'name' (verify it exists on 2.5.x)
    <file>:<line>: WARN UNKNOWN FIELD 'C_Foo.Bar' (no reference addon uses it; verify it exists on 2.5.x)
    <file>:<line>: WARN DEPRECATED 'name' (<hint>)
    <file>:<line>: WARN NOT IN WOW 'name' (<hint>)
    <file>:<line>: WARN UNKNOWN EVENT 'NAME' (no reference addon uses it; verify it exists on 2.5.x)
Exit code: 1 if any syntax error or global write (or, with --strict, any warning); else 0.
"""
import argparse
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import luabc  # noqa: E402

LIVE_ADDON_DIR = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
ADDON_DIR = os.environ.get("DISASTERZONE_ADDON_DIR") or LIVE_ADDON_DIR  # (a worktree copy of the addon)
ADDONS_ROOT = os.path.dirname(LIVE_ADDON_DIR)  # the reference addons live next to the real one
KNOWN_PATH = os.path.join(HERE, "known_globals.json")

# Reference addons that target this client; their global READS form the known-globals set.
REFERENCE_ADDONS = [
    "LootReserve", "Leatrix_Plus", "GudaBags", "Auctionator/Source", "WeakAuras", "DBM-Core", "Questie",
    "Details", "RaidHelper_TBC", "LoonBestInSlot", "RXPGuides", "TradeSkillMaster", "AtlasLootClassic",
    "Raidify", "Raidify_Loot", "TehBoxLootCouncil", "ArmoryUtils", "TBCRaidKompass", "PallyPower",
    "NovaConsumesHelper",
]
# Global-name prefixes owned by each reference addon (its own globals do not prove anything about the client).
ADDON_PREFIXES = {
    "LootReserve": ["LootReserve"], "Leatrix_Plus": ["LeaPlus", "Leatrix"], "GudaBags": ["Guda"],
    "Auctionator/Source": ["Auctionator"], "WeakAuras": ["WeakAuras", "WA_"], "DBM-Core": ["DBM", "DBT"],
    "Questie": ["Questie"], "Details": ["Details", "_detalhes", "DetailsFramework"], "RaidHelper_TBC": ["RaidHelper"],
    "LoonBestInSlot": ["LBIS", "LoonBestInSlot"], "RXPGuides": ["RXP"], "TradeSkillMaster": ["TSM"],
    "AtlasLootClassic": ["AtlasLoot"], "Raidify": ["Raidify"], "Raidify_Loot": ["Raidify"],
    "TehBoxLootCouncil": ["TehBox", "TBLC", "TBRT"], "ArmoryUtils": ["ArmoryUtils"], "TBCRaidKompass": ["TBCRaidKompass", "TRK"],
    "PallyPower": ["PallyPower"], "NovaConsumesHelper": ["NovaConsumes", "NCH"],
}
MAX_HARVEST_FILE = 1_500_000  # bytes; bigger files are data dumps (item/quest DBs) with ~no API reads

# Allowed global WRITES (fnmatch-style prefixes/names)
WRITE_ALLOW_EXACT = {"DisasterZone", "DisasterZoneDB"}
WRITE_ALLOW_PREFIX = ("SLASH_DISASTERZONE", "BINDING_", "DisasterZone")

LUA_STDLIB = set("""
assert collectgarbage error _G getfenv getmetatable ipairs load loadstring next pairs pcall print rawequal rawget
rawset select setfenv setmetatable tonumber tostring type unpack _VERSION xpcall newproxy gcinfo coroutine string
table math debug os
""".split())

WOW_EXTENSIONS = set("""
strsplit strjoin strtrim strmatch strfind gsub gmatch format tinsert tremove wipe sort floor ceil abs min max random
date time difftime bit debugstack debuglocals geterrorhandler seterrorhandler securecall securecallfunction issecurevariable
hooksecurefunc strlen strlower strupper strsub strbyte strchar strrep strrev strconcat strsplittable strlenutf8 strcmputf8i
tostringall getn foreach foreachi fastrandom mod sqrt exp log log10 frexp ldexp deg rad sin cos tan asin acos atan atan2
issecure issecretvalue forceinsecure scrub table_insert tContains tInvert CopyTable
""".split())

# Names that exist on the client only behind deprecation fallbacks (or not at all) -> always warned.
DEPRECATED = {
    "GetItemInfo": "deprecation-gated on 2.5.x; use C_Item.GetItemInfo",
    "GetItemInfoInstant": "deprecation-gated on 2.5.x; use C_Item.GetItemInfoInstant",
    "GetContainerNumSlots": "removed; use C_Container.GetContainerNumSlots",
    "GetContainerItemID": "removed; use C_Container.GetContainerItemID",
    "GetContainerItemLink": "removed; use C_Container.GetContainerItemLink",
    "GetContainerItemInfo": "removed; use C_Container.GetContainerItemInfo (returns a table)",
    "GetContainerNumFreeSlots": "removed; use C_Container.GetContainerNumFreeSlots",
    "GetAddOnMetadata": "deprecation-gated; use C_AddOns.GetAddOnMetadata",
    "GuildRoster": "removed; use C_GuildInfo.GuildRoster",
    "GetLootMethod": "replaced by C_PartyInfo.GetLootMethod (returns Enum.LootMethod numbers, not strings)",
    "SendAddonMessage": "removed; use C_ChatInfo.SendAddonMessage",
    "RegisterAddonMessagePrefix": "removed; use C_ChatInfo.RegisterAddonMessagePrefix",
    "InterfaceOptions_AddCategory": "old options API; use Settings.RegisterCanvasLayoutCategory + Settings.RegisterAddOnCategory",
    "InterfaceOptionsFrame_OpenToCategory": "old options API; use Settings.OpenToCategory",
    "InterfaceOptionsFramePanelContainer": "old options API; absent with the modern Settings UI",
    "EasyMenu": "removed in modern clients; use MenuUtil.CreateContextMenu",
    "getglobal": "removed; use _G[name]",
    "setglobal": "removed; use _G[name] = v",
    "this": "WoW 1.x implicit 'this' no longer exists",
    "arg": "Lua 5.0 implicit 'arg' does not exist in WoW",
}
NOT_IN_WOW = {
    "io": "no io library in WoW", "require": "no require in WoW", "dofile": "no dofile in WoW",
    "loadfile": "no loadfile in WoW", "module": "no module() in WoW", "package": "no package library in WoW",
}
# Hand-verified client APIs that no reference addon happens to read (kept deliberately short; each is a
# long-standing API that exists on the modern Classic clients). Everything else must be proven by the harvest.
EXTRA_KNOWN = {
    "GetGuildInfoText", "SetGuildInfoText", "CanEditGuildInfo",          # guild info text API (since 1.x)
    "GuildControlGetNumRanks", "GuildControlGetRankName",                 # guild rank API (since 1.x)
    "CanEditOfficerNote", "CanViewOfficerNote", "CanEditPublicNote",     # guild note permissions (since 1.x)
    "GuildRosterSetPublicNote", "GuildRosterSetOfficerNote",
    "BNSendGameData",                                                    # used by ChatThrottleLib via hooksecurefunc
    "IsFishingLoot",                                                     # classic_anniversary Blizzard LootFrame.lua:319
    "ConvertToRaid",                                                     # party -> raid (since 1.x; Attune.lua:5400 calls it)
    "BaseScrollBoxEvents",                                               # classic_anniversary SharedXML Scroll/ScrollBox.lua:2
    # party invites and the Group Finder (classic_anniversary 2.5.6.69795, checked 2026-10-06):
    "StaticPopup_FindVisible",                                           # Blizzard_StaticPopup/StaticPopup.lua:126
    "WillAcceptInviteRemoveQueues",                                      # Blizzard_UIParent/TBC/UIParent.lua:451
    "LFGParentFrame", "ShowLFGParentFrame", "ToggleLFGParentFrame",      # Blizzard_LFGVanilla_ParentFrame.lua:4,49,61
}
EXTRA_KNOWN_FIELDS = {
    "C_ChatInfo": {"SendAddonMessageLogged", "SendAddonMessage", "RegisterAddonMessagePrefix",
                   "IsAddonMessagePrefixRegistered", "GetRegisteredAddonMessagePrefixes"},
    "C_Timer": {"After", "NewTimer", "NewTicker"},
    # map art tiles (Blizzard_MapCanvas' detail layer; Leatrix_Maps calls GetMapArtLayers on this client)
    "C_Map": {"GetMapArtLayers", "GetMapArtLayerTextures"},
    # classic_anniversary SharedXML Scroll/ScrollBox.lua (ScrollBoxConstants table)
    "ScrollBoxConstants": {"NoScrollInterpolation"},
    # classic_anniversary Blizzard_APIDocumentationGenerated/LFGListInfoDocumentation.lua, Blizzard_LFGVanilla_*.lua
    "C_LFGList": {"GetSearchResultInfo", "GetSearchResultPlayerInfo", "GetSearchResults", "Search", "CreateListing",
                  "UpdateListing", "RemoveListing", "HasActiveEntryInfo", "GetActiveEntryInfo", "GetActivityInfoTable",
                  "GetAvailableActivities", "GetAvailableCategories", "ClearCreationTextFields"},
    "C_LFGInfo": {"CanPlayerUsePremadeGroup"},                       # Blizzard_LFGVanilla_ParentFrame.lua:65
}
# Hand-verified client events no reference addon registers (same rule as EXTRA_KNOWN: source line or doc file).
EXTRA_KNOWN_EVENTS = {
    "PARTY_INVITE_CANCEL",                                           # Blizzard_UIParent/TBC/UIParent.lua:455
    # LFGListInfoDocumentation.lua (classic_anniversary 2.5.6.69795)
    "LFG_LIST_SEARCH_RESULTS_RECEIVED", "LFG_LIST_SEARCH_FAILED", "LFG_LIST_SEARCH_RESULT_UPDATED",
    "LFG_LIST_ACTIVE_ENTRY_UPDATE", "LFG_LIST_ENTRY_EXPIRED_TIMEOUT", "LFG_LIST_ENTRY_CREATION_FAILED",
    "LFG_LIST_AVAILABILITY_UPDATE",
}
# Globals owned by addons in the TOC's OptionalDeps: reported as INFO (must be nil-guarded), not as unknown.
OPTIONAL_DEP_PREFIXES = {"LoonBestInSlot": ("LBIS", "LoonBestInSlot")}

# Fields allowed on Lua standard tables in WoW (incl. WoW additions)
STD_FIELDS = {
    "string": set("byte char dump find format gmatch gsub len lower match rep reverse sub upper gfind join split trim "
                  "rtgsub".split()),
    "table": set("concat insert maxn remove sort getn setn foreach foreachi wipe removemulti count".split()),
    "math": set("abs acos asin atan atan2 ceil cos cosh deg exp floor fmod frexp huge ldexp log log10 max min modf pi "
                "pow rad random randomseed sin sinh sqrt tan tanh".split()),
    "os": set("clock date difftime time".split()),
    "coroutine": set("create resume running status wrap yield isyieldable".split()),
    "bit": set("band bor bxor bnot lshift rshift arshift mod tobit tohex".split()),
}
# Tables whose constant fields are API functions/constants (field checks apply). Others (RAID_CLASS_COLORS,
# SlashCmdList, StaticPopupDialogs, ...) are data tables and are not field-checked.
# (namespace test: luabc.is_namespace_name -> names starting with C_ plus Enum, Settings, MenuUtil, ScrollUtil, ...)

EVENT_RE = re.compile(r"""(?:RegisterEvent|RegisterUnitEvent|RegisterFrameEventAndCallback|RegisterOnceFrameEventAndCallback|UnregisterEvent|IsEventRegistered)\s*\(\s*(?:[A-Za-z_][\w.]*\s*,\s*)?["']([A-Z][A-Z0-9_]+)["']""")
EVENT_CMP_RE = re.compile(r"""event\s*==\s*["']([A-Z][A-Z0-9_]+)["']""")
# Events the mock itself fires / knows (always accepted)
MOCK_EVENTS = set("""
ADDON_LOADED VARIABLES_LOADED PLAYER_LOGIN PLAYER_LOGOUT PLAYER_ENTERING_WORLD PLAYER_LEAVING_WORLD CHAT_MSG_ADDON
CHAT_MSG_ADDON_LOGGED CHAT_MSG_SYSTEM CHAT_MSG_LOOT CHAT_MSG_RAID CHAT_MSG_RAID_LEADER CHAT_MSG_RAID_WARNING
CHAT_MSG_PARTY CHAT_MSG_PARTY_LEADER CHAT_MSG_GUILD CHAT_MSG_OFFICER CHAT_MSG_SAY CHAT_MSG_YELL CHAT_MSG_WHISPER
CHAT_MSG_WHISPER_INFORM CHAT_MSG_EMOTE GUILD_ROSTER_UPDATE PLAYER_GUILD_UPDATE GROUP_ROSTER_UPDATE PARTY_LOOT_METHOD_CHANGED
LOOT_READY LOOT_OPENED LOOT_CLOSED LOOT_SLOT_CLEARED START_LOOT_ROLL CANCEL_LOOT_ROLL GET_ITEM_INFO_RECEIVED ITEM_DATA_LOAD_RESULT
PLAYER_EQUIPMENT_CHANGED UNIT_INVENTORY_CHANGED BAG_UPDATE BAG_UPDATE_DELAYED BANKFRAME_OPENED BANKFRAME_CLOSED
PLAYERBANKSLOTS_CHANGED PLAYER_REGEN_DISABLED PLAYER_REGEN_ENABLED ENCOUNTER_START ENCOUNTER_END BOSS_KILL
ZONE_CHANGED_NEW_AREA COMBAT_LOG_EVENT_UNFILTERED PLAYER_TARGET_CHANGED MODIFIER_STATE_CHANGED UPDATE_INSTANCE_INFO
""".split())


def rel(path):
    ap = os.path.abspath(path)
    try:
        r = os.path.relpath(ap, ADDON_DIR)
    except ValueError:
        return ap.replace("\\", "/")
    if r.startswith(".."):
        return ap.replace("\\", "/")
    return r.replace("\\", "/")


def iter_lua_files(root):
    for dp, dns, fns in os.walk(root):
        dns.sort()
        for fn in sorted(fns):
            if fn.lower().endswith(".lua"):
                yield os.path.join(dp, fn)


# ---------------------------------------------------------------------------------------------------------------
# Known globals harvest
# ---------------------------------------------------------------------------------------------------------------
def _is_stub_file(path, proto):
    if os.path.basename(path).lower() in ("luaserver.lua",):
        return True
    return luabc.count_empty_global_functions(proto) > 100


def harvest_known(verbose=True):
    t0 = time.time()
    globals_count = {}   # name -> number of addons reading it (excluding their own globals)
    fields_count = {}    # ns -> field -> number of addons
    events_count = {}    # EVENT -> number of addons
    meta = {}
    for addon in REFERENCE_ADDONS:
        root = os.path.join(ADDONS_ROOT, addon.replace("/", os.sep))
        info = {"files": 0, "failed": [], "skipped_big": 0, "skipped_stub": [], "missing": not os.path.isdir(root)}
        meta[addon] = info
        if info["missing"]:
            if verbose:
                print("harvest: %s not installed, skipped" % addon, file=sys.stderr)
            continue
        reads, writes, fields, events = set(), set(), {}, set()
        for path in iter_lua_files(root):
            try:
                size = os.path.getsize(path)
                if size > MAX_HARVEST_FILE:
                    info["skipped_big"] += 1
                    continue
                with open(path, "rb") as fh:
                    src = fh.read()
            except OSError:
                continue
            bc, err = luabc.compile_chunk(src, "@" + os.path.relpath(path, ADDONS_ROOT))
            if bc is None:
                info["failed"].append(os.path.relpath(path, ADDONS_ROOT).replace("\\", "/"))
                continue
            proto = luabc.parse_bytecode(bc)
            if _is_stub_file(path, proto):
                info["skipped_stub"].append(os.path.relpath(path, ADDONS_ROOT).replace("\\", "/"))
                continue
            info["files"] += 1
            for a in luabc.analyze(proto):
                if a.kind in ("get", "get_G"):
                    reads.add(a.name)
                    if a.field:
                        fields.setdefault(a.name, set()).add(a.field)
                elif a.kind == "field":
                    fields.setdefault(a.name, set()).add(a.field)
                elif a.kind in ("set", "set_G"):
                    writes.add(a.name)
            text = src.decode("utf-8", "replace")
            events.update(EVENT_RE.findall(text))
            events.update(EVENT_CMP_RE.findall(text))
        prefixes = tuple(p.lower() for p in ADDON_PREFIXES.get(addon, []))
        own = {n for n in reads if n.lower().startswith(prefixes)} if prefixes else set()
        for n in reads - writes - own:
            globals_count[n] = globals_count.get(n, 0) + 1
        for ns, fs in fields.items():
            d = fields_count.setdefault(ns, {})
            for f in fs:
                d[f] = d.get(f, 0) + 1
        for e in events:
            events_count[e] = events_count.get(e, 0) + 1
        if verbose:
            print("harvest: %-20s %4d files, %d failed, %d big skipped, %d stubs skipped" % (
                addon, info["files"], len(info["failed"]), info["skipped_big"], len(info["skipped_stub"])), file=sys.stderr)
    data = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "seconds": round(time.time() - t0, 1),
        "addons": meta,
        "globals": dict(sorted(globals_count.items())),
        "fields": {k: dict(sorted(v.items())) for k, v in sorted(fields_count.items())},
        "events": dict(sorted(events_count.items())),
    }
    with open(KNOWN_PATH, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=False)
    if verbose:
        print("harvest: %d globals, %d namespaces, %d events in %.1fs -> %s" % (
            len(globals_count), len(fields_count), len(events_count), time.time() - t0, KNOWN_PATH), file=sys.stderr)
    return data


def load_known(rebuild=False):
    if rebuild or not os.path.exists(KNOWN_PATH):
        return harvest_known()
    with open(KNOWN_PATH, encoding="utf-8") as fh:
        return json.load(fh)


# ---------------------------------------------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------------------------------------------
def write_allowed(name):
    return name in WRITE_ALLOW_EXACT or name.startswith(WRITE_ALLOW_PREFIX)


def is_api_namespace(name):
    return luabc.is_namespace_name(name) and name not in STD_FIELDS


class Report:
    def __init__(self):
        self.lines = []  # (file, line, severity, text, category, name)
        self._seen = set()

    def add(self, f, line, sev, cat, name, text):
        key = (f, line, cat, name)
        if key in self._seen:
            return
        self._seen.add(key)
        self.lines.append((f, line, sev, cat, name, text))

    def count(self, cat):
        return sum(1 for x in self.lines if x[3] == cat)


def check_files(files, known, report, check_events=True):
    kglobals = known.get("globals", {})
    kfields = known.get("fields", {})
    kevents = known.get("events", {})
    parsed = []
    own_defined = set()
    for path in files:
        r = rel(path)
        try:
            with open(path, "rb") as fh:
                src = fh.read()
        except OSError as e:
            report.add(r, 0, "ERROR", "io", "", "ERROR cannot read: %s" % e)
            continue
        bc, err = luabc.compile_chunk(src, "@" + r)
        if bc is None:
            m = re.match(r"^(.*?):(\d+): (.*)$", err, re.S)
            line = int(m.group(2)) if m else 0
            msg = m.group(3) if m else err
            report.add(r, line, "ERROR", "syntax", "", "ERROR syntax: %s" % msg.strip())
            continue
        acc = luabc.analyze(luabc.parse_bytecode(bc))
        parsed.append((r, src, acc))
        for a in acc:
            if a.kind in ("set", "set_G"):
                own_defined.add(a.name)

    def field_known(ns, fld):
        if ns in STD_FIELDS:
            return fld in STD_FIELDS[ns]
        return kfields.get(ns, {}).get(fld, 0) >= 1 or fld in EXTRA_KNOWN_FIELDS.get(ns, ())

    optdep = tuple(p for ps in OPTIONAL_DEP_PREFIXES.values() for p in ps)
    for r, src, acc in parsed:
        for a in sorted(acc, key=lambda x: (x.line, x.name)):
            if a.kind == "field":
                if (a.name in STD_FIELDS or is_api_namespace(a.name)) and not field_known(a.name, a.field):
                    report.add(r, a.line, "WARN", "field", "%s.%s" % (a.name, a.field),
                               "WARN UNKNOWN FIELD '%s.%s' (via local alias; %s)" % (
                                   a.name, a.field, "not in WoW's Lua library" if a.name in STD_FIELDS
                                   else "no reference addon uses it; verify it exists on 2.5.x"))
                continue
            if a.kind == "set":
                if not write_allowed(a.name):
                    report.add(r, a.line, "ERROR", "write", a.name,
                               "ERROR global write '%s' (SETGLOBAL; missing 'local'?)" % a.name)
                continue
            if a.kind == "set_G":
                if not write_allowed(a.name):
                    report.add(r, a.line, "WARN", "gwrite", a.name,
                               "WARN _G write '%s' (explicit _G.%s = ...; not in allowlist)" % (a.name, a.name))
                continue
            name = a.name
            if name in NOT_IN_WOW:
                report.add(r, a.line, "WARN", "notwow", name, "WARN NOT IN WOW '%s' (%s)" % (name, NOT_IN_WOW[name]))
                continue
            if name in DEPRECATED:
                report.add(r, a.line, "WARN", "deprecated", name, "WARN DEPRECATED '%s' (%s)" % (name, DEPRECATED[name]))
                continue
            if name in STD_FIELDS and a.field is not None:
                if a.field not in STD_FIELDS[name]:
                    report.add(r, a.fline, "WARN", "field", "%s.%s" % (name, a.field),
                               "WARN UNKNOWN FIELD '%s.%s' (not in WoW's Lua library)" % (name, a.field))
                continue
            if name in LUA_STDLIB or name in WOW_EXTENSIONS or write_allowed(name) or name in own_defined:
                continue
            if optdep and name.startswith(optdep):
                report.add(r, a.line, "INFO", "optdep", name,
                           "INFO OPTIONAL-DEP GLOBAL '%s' (owned by an OptionalDeps addon; must be nil-guarded)" % name)
                continue
            if kglobals.get(name, 0) < 1 and name not in EXTRA_KNOWN:
                report.add(r, a.line, "WARN", "unknown", name,
                           "WARN UNKNOWN GLOBAL '%s' (verify it exists on 2.5.x)" % name)
                continue
            if a.field is not None and is_api_namespace(name):
                if not field_known(name, a.field):
                    report.add(r, a.fline, "WARN", "field", "%s.%s" % (name, a.field),
                               "WARN UNKNOWN FIELD '%s.%s' (no reference addon uses it; verify it exists on 2.5.x)"
                               % (name, a.field))
        if check_events:
            text = src.decode("utf-8", "replace")
            for m in EVENT_RE.finditer(text):
                ev = m.group(1)
                if ev in MOCK_EVENTS or ev in EXTRA_KNOWN_EVENTS or kevents.get(ev, 0) >= 1:
                    continue
                line = text.count("\n", 0, m.start()) + 1
                report.add(r, line, "WARN", "event", ev,
                           "WARN UNKNOWN EVENT '%s' (no reference addon uses it; verify it exists on 2.5.x)" % ev)


def collect_targets(paths, include_libs):
    out = []
    if not paths:
        paths = [ADDON_DIR]
    for p in paths:
        cand = p
        if not os.path.exists(cand) and os.path.exists(os.path.join(ADDON_DIR, p)):
            cand = os.path.join(ADDON_DIR, p)
        if os.path.isdir(cand):
            for f in iter_lua_files(cand):
                rp = rel(f)
                if not include_libs and (rp.startswith("Libs/") or "/Libs/" in rp):
                    continue
                out.append(f)
        elif os.path.isfile(cand):
            out.append(cand)
        else:
            print("check: no such file or directory: %s" % p, file=sys.stderr)
    seen, uniq = set(), []
    for f in out:
        k = os.path.normcase(os.path.abspath(f))
        if k not in seen:
            seen.add(k)
            uniq.append(f)
    return uniq


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--libs", action="store_true", help="include Libs/ when scanning directories")
    ap.add_argument("--rebuild-known", action="store_true", help="re-harvest tools/known_globals.json")
    ap.add_argument("--strict", action="store_true", help="non-zero exit on warnings too")
    ap.add_argument("--quiet", "-q", action="store_true", help="only ERROR lines + summary")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--no-events", action="store_true", help="skip the RegisterEvent name check")
    args = ap.parse_args(argv)

    known = load_known(args.rebuild_known)
    files = collect_targets(args.paths, args.libs)
    report = Report()
    check_files(files, known, report, check_events=not args.no_events)
    lines = sorted(report.lines, key=lambda x: (x[0], x[1], x[3], x[4]))
    n_syntax = report.count("syntax") + report.count("io")
    n_write = report.count("write")
    n_warn = sum(1 for x in lines if x[2] == "WARN")
    n_info = sum(1 for x in lines if x[2] == "INFO")
    if args.json:
        print(json.dumps({"files": [rel(f) for f in files],
                          "problems": [{"file": f, "line": ln, "severity": sev, "category": cat, "name": nm, "text": tx}
                                       for f, ln, sev, cat, nm, tx in lines],
                          "syntax_errors": n_syntax, "global_writes": n_write, "warnings": n_warn}, indent=1))
    else:
        for f, ln, sev, cat, nm, tx in lines:
            if args.quiet and sev != "ERROR":
                continue
            print("%s:%d: %s" % (f, ln, tx))
        print("-- checked %d file(s): %d syntax error(s), %d global write(s), %d warning(s), %d info [%s]" % (
            len(files), n_syntax, n_write, n_warn, n_info,
            ", ".join("%s=%d" % (c, report.count(c)) for c in
                      ("unknown", "field", "deprecated", "notwow", "gwrite", "event", "optdep") if report.count(c))))
    bad = n_syntax > 0 or n_write > 0 or (args.strict and n_warn > 0)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
