#!/usr/bin/env python3
"""
One-off generator for CDLoot's embedded TBC raid-loot database.

Reads (read-only) from the installed WoW AddOns folder:
  * AtlasLootClassic_DungeonsAndRaids/data-tbc.lua   -> raids, bosses, loot rows
  * AtlasLootClassic/Data/Token.lua                   -> tier token -> tier pieces (TOKEN_DATA.BCC)
  * AtlasLootClassic_Data/source-tbc.lua              -> reverse map (item -> source/token) for cross-checks
  * LoonBestInSlot/DB/ItemSources.lua                 -> item names + independent source attribution (cross-check)
  * DBM-Raids-BC/*, DBM-Outlands/*                    -> creature IDs / encounter IDs per boss

Writes ONLY to the scratchpad:
  * CDLoot_Data_generated.lua
  * gen_report.json  (machine-readable summary of what was skipped / verified)

Usage:  python gen_cdloot_data.py
"""
import json
import os
import re
import sys
from collections import OrderedDict, defaultdict

ADDONS = r"C:\World of Warcraft\_anniversary_\Interface\AddOns"
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_LUA = os.path.join(OUT_DIR, "CDLoot_Data_generated.lua")
OUT_REPORT = os.path.join(OUT_DIR, "gen_report.json")

P_ATLAS_RAIDS = os.path.join(ADDONS, "AtlasLootClassic_DungeonsAndRaids", "data-tbc.lua")
P_ATLAS_TOKEN = os.path.join(ADDONS, "AtlasLootClassic", "Data", "Token.lua")
P_ATLAS_SOURCE = os.path.join(ADDONS, "AtlasLootClassic_Data", "source-tbc.lua")
P_LOON_SOURCES = os.path.join(ADDONS, "LoonBestInSlot", "DB", "ItemSources.lua")
P_DBM_BC = os.path.join(ADDONS, "DBM-Raids-BC")
P_DBM_OUTLANDS = os.path.join(ADDONS, "DBM-Outlands")


# --------------------------------------------------------------------------------------
# Minimal Lua tokenizer + table-constructor/expression parser (enough for AtlasLoot data)
# --------------------------------------------------------------------------------------
TOKEN_RE = re.compile(r"""
    (?P<ws>[ \t\r\f]+)
  | (?P<nl>\n)
  | (?P<lcomment>--\[(?P<eq>=*)\[.*?\](?P=eq)\])
  | (?P<comment>--[^\n]*)
  | (?P<lstr>\[(?P<eq2>=*)\[.*?\](?P=eq2)\])
  | (?P<str>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')
  | (?P<num>0[xX][0-9a-fA-F]+|\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>\.\.\.|\.\.|==|~=|<=|>=|[{}\[\]=,;():.\#+\-*/<>^%])
""", re.S | re.X)


class Tok:
    __slots__ = ("kind", "val", "line")

    def __init__(self, kind, val, line):
        self.kind, self.val, self.line = kind, val, line

    def __repr__(self):
        return f"Tok({self.kind},{self.val!r},L{self.line})"


def unescape_lua_string(s):
    q = s[0]
    body = s[1:-1]
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            n = body[i + 1]
            out.append({"n": "\n", "t": "\t", "\\": "\\", '"': '"', "'": "'"}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def tokenize(text):
    toks = []
    comments = {}  # line -> first comment text on that line (after stripping "--")
    line = 1
    pos = 0
    n = len(text)
    while pos < n:
        m = TOKEN_RE.match(text, pos)
        if not m:
            raise SyntaxError(f"Unexpected char {text[pos]!r} at line {line}")
        kind = m.lastgroup
        val = m.group(0)
        if kind in ("eq", "eq2"):  # never the outer group, but be safe
            kind = "lcomment" if val.startswith("--") else "lstr"
        if m.group("lcomment") is not None:
            kind = "lcomment"
        elif m.group("lstr") is not None:
            kind = "lstr"
        if kind == "nl":
            line += 1
        elif kind == "ws":
            pass
        elif kind == "comment":
            comments.setdefault(line, val[2:].strip())
        elif kind == "lcomment":
            line += val.count("\n")
        elif kind == "lstr":
            toks.append(Tok("str", re.sub(r"^\[=*\[\n?|\]=*\]$", "", val), line))
            line += val.count("\n")
        elif kind == "str":
            toks.append(Tok("str", unescape_lua_string(val), line))
        elif kind == "num":
            toks.append(Tok("num", int(val, 16) if val[:2].lower() == "0x" else (float(val) if ("." in val or "e" in val.lower()) else int(val)), line))
        elif kind == "name":
            toks.append(Tok("name", val, line))
        else:
            toks.append(Tok("op", val, line))
        pos = m.end()
    return toks, comments


class LuaTable:
    def __init__(self, line_start):
        self.array = []          # positional values (None kept for nil so indexes stay positional)
        self.array_lines = []    # line where each positional element ENDS (for trailing-comment lookup)
        self.hash = OrderedDict()
        self.line_start = line_start
        self.line_end = line_start

    def get(self, key, default=None):
        return self.hash.get(key, default)


class Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.t[j] if j < len(self.t) else None

    def next(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def expect(self, kind, val=None):
        tok = self.next()
        if tok.kind != kind or (val is not None and tok.val != val):
            raise SyntaxError(f"Expected {kind} {val!r}, got {tok!r}")
        return tok

    def is_op(self, val, k=0):
        tok = self.peek(k)
        return tok is not None and tok.kind == "op" and tok.val == val

    def last_line(self):
        return self.t[self.i - 1].line

    # expression := unary ( binop unary )*   (no precedence needed: we never evaluate arithmetic)
    BINOPS = {"..", "<", ">", "<=", ">=", "==", "~=", "+", "-", "*", "/", "%", "^"}

    def parse_expr(self):
        left = self.parse_unary()
        while True:
            tok = self.peek()
            if tok is None:
                return left
            if tok.kind == "op" and tok.val in self.BINOPS:
                op = self.next().val
            elif tok.kind == "name" and tok.val in ("and", "or"):
                op = self.next().val
            else:
                return left
            right = self.parse_unary()
            left = ("concat", left, right) if op == ".." else ("binop", op, left, right)

    def parse_unary(self):
        if self.is_op("-"):
            self.next()
            v = self.parse_unary()
            return -v if isinstance(v, (int, float)) else ("neg", v)
        return self.parse_primary()

    def parse_args(self):
        self.expect("op", "(")
        args = []
        if not self.is_op(")"):
            args.append(self.parse_expr())
            while self.is_op(","):
                self.next()
                args.append(self.parse_expr())
        self.expect("op", ")")
        return args

    def parse_primary(self):
        tok = self.peek()
        if tok.kind == "op" and tok.val == "{":
            return self.parse_table()
        if tok.kind == "op" and tok.val == "(":
            self.next()
            v = self.parse_expr()
            self.expect("op", ")")
            return v
        if tok.kind == "str":
            self.next()
            return ("str", tok.val)
        if tok.kind == "num":
            self.next()
            return tok.val
        if tok.kind == "name":
            self.next()
            if tok.val == "nil":
                return None
            if tok.val == "true":
                return True
            if tok.val == "false":
                return False
            name = tok.val
            node = ("ident", name)
            while True:
                if self.is_op("."):
                    self.next()
                    name = name + "." + self.expect("name").val
                    node = ("ident", name)
                elif self.is_op("["):
                    self.next()
                    key = self.parse_expr()
                    self.expect("op", "]")
                    if node == ("ident", "AL") and isinstance(key, tuple) and key[0] == "str":
                        node = ("AL", key[1])
                    else:
                        node = ("index", node, key)
                elif self.is_op(":"):
                    self.next()
                    meth = self.expect("name").val
                    args = self.parse_args()
                    node = ("call", name + ":" + meth, args)
                elif self.is_op("("):
                    args = self.parse_args()
                    node = ("call", name, args)
                elif self.is_op("{"):  # f{...} call sugar (e.g. LootReserve's Squish{...})
                    node = ("call", name, [self.parse_table()])
                elif self.peek() is not None and self.peek().kind == "str":  # f"..." call sugar
                    node = ("call", name, [("str", self.next().val)])
                else:
                    return node
        raise SyntaxError(f"Unexpected token {tok!r}")

    def parse_table(self):
        start = self.expect("op", "{")
        tbl = LuaTable(start.line)
        while not self.is_op("}"):
            if self.is_op("["):
                self.next()
                key = self.parse_expr()
                self.expect("op", "]")
                self.expect("op", "=")
                val = self.parse_expr()
                tbl.hash[key if not (isinstance(key, tuple) and key[0] == "str") else key[1]] = val
            elif self.peek().kind == "name" and self.is_op("=", 1):
                key = self.next().val
                self.next()
                tbl.hash[key] = self.parse_expr()
            else:
                val = self.parse_expr()
                tbl.array.append(val)
                tbl.array_lines.append(self.last_line())
            if self.is_op(",") or self.is_op(";"):
                self.next()
        end = self.expect("op", "}")
        tbl.line_end = end.line
        return tbl


def read(path):
    with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        return f.read()


def find_assignment(toks, pattern):
    """Find token index just after `<pattern tokens> =` where pattern is a list of (kind,val)."""
    L = len(pattern)
    for i in range(len(toks) - L):
        ok = True
        for k, (kind, val) in enumerate(pattern):
            t = toks[i + k]
            if t.kind != kind or (val is not None and t.val != val):
                ok = False
                break
        if ok:
            return i + L
    return None


def resolve_text(node):
    """Resolve AL["x"], "x", format(AL["%s"], ...), concatenations to plain English text."""
    if node is None:
        return None
    if isinstance(node, (int, float)):
        return str(node)
    if isinstance(node, tuple):
        if node[0] in ("AL", "str"):
            return node[1]
        if node[0] == "call" and node[1] in ("format", "string.format"):
            fmt = resolve_text(node[2][0])
            args = [resolve_text(a) for a in node[2][1:]]
            try:
                return fmt.replace("%d", "%s") % tuple(args)
            except Exception:
                return fmt
        if node[0] == "concat":
            return (resolve_text(node[1]) or "") + (resolve_text(node[2]) or "")
        if node[0] == "ident":
            return node[1]
    return str(node)


# --------------------------------------------------------------------------------------
# Configuration: which raids, in which order, and nicer stable boss keys
# --------------------------------------------------------------------------------------
RAIDS = [
    # (AtlasLoot key, CDLoot key, display name, phase, size)
    ("Karazhan",            "Karazhan",            "Karazhan",             1, 10),
    ("GruulsLair",          "GruulsLair",          "Gruul's Lair",         1, 25),
    ("MagtheridonsLair",    "MagtheridonsLair",    "Magtheridon's Lair",   1, 25),
    ("WorldBossesBC",       "WorldBosses",         "World Bosses",         1, 40),
    ("SerpentshrineCavern", "SerpentshrineCavern", "Serpentshrine Cavern", 2, 25),
    ("TempestKeep",         "TempestKeep",         "Tempest Keep",         2, 25),
    ("HyjalSummit",         "HyjalSummit",         "Mount Hyjal",          3, 25),
    ("BlackTemple",         "BlackTemple",         "Black Temple",         3, 25),
    ("ZulAman",             "ZulAman",             "Zul'Aman",             4, 10),
    ("SunwellPlateau",      "SunwellPlateau",      "Sunwell Plateau",      5, 25),
]

# (raidKey, English boss name from AtlasLoot) -> (CDLoot boss key, optional group, DBM mod file relative path)
BOSS_META = {
    ("Karazhan", "Attumen the Huntsman"):   ("Attumen", None, "DBM-Raids-BC/Karazhan/Attumen.lua"),
    ("Karazhan", "Rokad the Ravager"):      ("Rokad", "Servant Quarters", None),
    ("Karazhan", "Shadikith the Glider"):   ("Shadikith", "Servant Quarters", None),
    ("Karazhan", "Hyakiss the Lurker"):     ("Hyakiss", "Servant Quarters", None),
    ("Karazhan", "Moroes"):                 ("Moroes", None, "DBM-Raids-BC/Karazhan/Moroes.lua"),
    ("Karazhan", "Maiden of Virtue"):       ("Maiden", None, "DBM-Raids-BC/Karazhan/MaidenOfVirtue.lua"),
    ("Karazhan", "The Wizard of Oz"):       ("OperaOz", "Opera Event", "DBM-Raids-BC/Karazhan/WizardOfOz.lua"),
    ("Karazhan", "The Big Bad Wolf"):       ("OperaWolf", "Opera Event", "DBM-Raids-BC/Karazhan/BigBadWolf.lua"),
    ("Karazhan", "Romulo and Julianne"):    ("OperaRomulo", "Opera Event", "DBM-Raids-BC/Karazhan/RomuloAndJulianne.lua"),
    ("Karazhan", "The Curator"):            ("Curator", None, "DBM-Raids-BC/Karazhan/Curator.lua"),
    ("Karazhan", "Terestian Illhoof"):      ("Illhoof", None, "DBM-Raids-BC/Karazhan/TerestianIllhoof.lua"),
    ("Karazhan", "Shade of Aran"):          ("Aran", None, "DBM-Raids-BC/Karazhan/ShadeOfAran.lua"),
    ("Karazhan", "Netherspite"):            ("Netherspite", None, "DBM-Raids-BC/Karazhan/Netherspite.lua"),
    ("Karazhan", "Chess Event"):            ("Chess", None, "DBM-Raids-BC/Karazhan/Chess.lua"),
    ("Karazhan", "Prince Malchezaar"):      ("Prince", None, "DBM-Raids-BC/Karazhan/PrinceMalchezaar.lua"),
    ("Karazhan", "Nightbane"):              ("Nightbane", None, "DBM-Raids-BC/Karazhan/Nightbane.lua"),
    ("Karazhan", "Trash"):                  ("Trash", None, None),
    ("GruulsLair", "High King Maulgar"):    ("Maulgar", None, "DBM-Raids-BC/GruulsLair/Maulgar.lua"),
    ("GruulsLair", "Gruul the Dragonkiller"): ("Gruul", None, "DBM-Raids-BC/GruulsLair/Gruul.lua"),
    ("MagtheridonsLair", "Magtheridon"):    ("Magtheridon", None, "DBM-Raids-BC/MagtheridonsLair/Magtheridon.lua"),
    ("WorldBossesBC", "Doomwalker"):        ("Doomwalker", None, "DBM-Outlands/Doomwalker.lua"),
    ("WorldBossesBC", "Doom Lord Kazzak"):  ("Kazzak", None, "DBM-Outlands/Kazzak.lua"),
    ("SerpentshrineCavern", "Hydross the Unstable"):   ("Hydross", None, "DBM-Raids-BC/Serpentshrine/Hydross.lua"),
    ("SerpentshrineCavern", "The Lurker Below"):       ("Lurker", None, "DBM-Raids-BC/Serpentshrine/TheLurkerBelow.lua"),
    ("SerpentshrineCavern", "Leotheras the Blind"):    ("Leotheras", None, "DBM-Raids-BC/Serpentshrine/Leotheras.lua"),
    ("SerpentshrineCavern", "Fathom-Lord Karathress"): ("Karathress", None, "DBM-Raids-BC/Serpentshrine/Fathomlord.lua"),
    ("SerpentshrineCavern", "Morogrim Tidewalker"):    ("Morogrim", None, "DBM-Raids-BC/Serpentshrine/Tidewalker.lua"),
    ("SerpentshrineCavern", "Lady Vashj"):             ("Vashj", None, "DBM-Raids-BC/Serpentshrine/Vashj.lua"),
    ("SerpentshrineCavern", "Trash"):                  ("Trash", None, None),
    ("TempestKeep", "Al'ar"):                     ("Alar", None, "DBM-Raids-BC/TheEye/Alar.lua"),
    ("TempestKeep", "Void Reaver"):               ("VoidReaver", None, "DBM-Raids-BC/TheEye/VoidReaver.lua"),
    ("TempestKeep", "High Astromancer Solarian"): ("Solarian", None, "DBM-Raids-BC/TheEye/Solarian.lua"),
    ("TempestKeep", "Kael'thas Sunstrider"):      ("Kaelthas", None, "DBM-Raids-BC/TheEye/KaelThas.lua"),
    ("TempestKeep", "Trash"):                     ("Trash", None, None),
    ("HyjalSummit", "Rage Winterchill"): ("Winterchill", None, "DBM-Raids-BC/Hyjal/RageWinterchill.lua"),
    ("HyjalSummit", "Anetheron"):        ("Anetheron", None, "DBM-Raids-BC/Hyjal/Anetheron.lua"),
    ("HyjalSummit", "Kaz'rogal"):        ("Kazrogal", None, "DBM-Raids-BC/Hyjal/Kazrogal.lua"),
    ("HyjalSummit", "Azgalor"):          ("Azgalor", None, "DBM-Raids-BC/Hyjal/Azgalor.lua"),
    ("HyjalSummit", "Archimonde"):       ("Archimonde", None, "DBM-Raids-BC/Hyjal/Archimonde.lua"),
    ("HyjalSummit", "Trash"):            ("Trash", None, None),
    ("BlackTemple", "High Warlord Naj'entus"): ("Najentus", None, "DBM-Raids-BC/BlackTemple/Najentus.lua"),
    ("BlackTemple", "Supremus"):               ("Supremus", None, "DBM-Raids-BC/BlackTemple/Supremus.lua"),
    ("BlackTemple", "Shade of Akama"):         ("ShadeOfAkama", None, "DBM-Raids-BC/BlackTemple/ShadeOfAkama.lua"),
    ("BlackTemple", "Gurtogg Bloodboil"):      ("Bloodboil", None, "DBM-Raids-BC/BlackTemple/Bloodboil.lua"),
    ("BlackTemple", "Reliquary of the Lost"):  ("Reliquary", None, "DBM-Raids-BC/BlackTemple/EssenceOfSouls.lua"),
    ("BlackTemple", "Teron Gorefiend"):        ("Teron", None, "DBM-Raids-BC/BlackTemple/TeronGorefiend.lua"),
    ("BlackTemple", "Mother Shahraz"):         ("Shahraz", None, "DBM-Raids-BC/BlackTemple/Shahraz.lua"),
    ("BlackTemple", "The Illidari Council"):   ("Council", None, "DBM-Raids-BC/BlackTemple/IllidariCouncil.lua"),
    ("BlackTemple", "Illidan Stormrage"):      ("Illidan", None, "DBM-Raids-BC/BlackTemple/Illidan.lua"),
    ("BlackTemple", "Trash"):                  ("Trash", None, None),
    ("BlackTemple", "Patterns"):               ("Patterns", None, None),
    ("ZulAman", "Akil'zon"):           ("Akilzon", None, "DBM-Raids-BC/ZulAmanLegacy/Akilzon.lua"),
    ("ZulAman", "Nalorakk"):           ("Nalorakk", None, "DBM-Raids-BC/ZulAmanLegacy/Nalorakk.lua"),
    ("ZulAman", "Jan'alai"):           ("Janalai", None, "DBM-Raids-BC/ZulAmanLegacy/Janalai.lua"),
    ("ZulAman", "Halazzi"):            ("Halazzi", None, "DBM-Raids-BC/ZulAmanLegacy/Halazzi.lua"),
    ("ZulAman", "Hex Lord Malacrass"): ("Malacrass", None, "DBM-Raids-BC/ZulAmanLegacy/Malacrass.lua"),
    ("ZulAman", "Zul'jin"):            ("Zuljin", None, "DBM-Raids-BC/ZulAmanLegacy/Zuljin.lua"),
    ("ZulAman", "Timed Chest"):        ("TimedChests", None, None),
    ("ZulAman", "Trash"):              ("Trash", None, None),
    ("SunwellPlateau", "Kalecgos"):     ("Kalecgos", None, "DBM-Raids-BC/Sunwell/Kalecgos.lua"),
    ("SunwellPlateau", "Brutallus"):    ("Brutallus", None, "DBM-Raids-BC/Sunwell/Brutallus.lua"),
    ("SunwellPlateau", "Felmyst"):      ("Felmyst", None, "DBM-Raids-BC/Sunwell/Felmyst.lua"),
    ("SunwellPlateau", "Eredar Twins"): ("EredarTwins", None, "DBM-Raids-BC/Sunwell/EredarTwins.lua"),
    ("SunwellPlateau", "M'uru"):        ("Muru", None, "DBM-Raids-BC/Sunwell/M'uru.lua"),
    ("SunwellPlateau", "Kil'jaeden"):   ("Kiljaeden", None, "DBM-Raids-BC/Sunwell/Kil'jaeden.lua"),
    ("SunwellPlateau", "Patterns"):     ("Patterns", None, None),
    ("SunwellPlateau", "Trash"):        ("Trash", None, None),
}

# Display-name overrides (AtlasLoot's pseudo-boss names made clearer)
NAME_OVERRIDE = {
    ("ZulAman", "Timed Chest"): "Timed Reward Chests",
    ("BlackTemple", "Patterns"): "Trash (Patterns)",
    ("SunwellPlateau", "Patterns"): "Trash (Patterns)",
}

# Whole AtlasLoot boss entries we deliberately do not ship (reason recorded in report)
SKIP_BOSSES = {
    ("TempestKeep", "Legendaries"): "Kael'thas fight weapons: temporary, vanish when leaving the instance; not real loot",
}

# Items we deliberately drop from every boss list
SKIP_ITEMS = {
    29434: "Badge of Justice: currency, auto-distributed to every player; never loot-councilled",
}

# Extra npc IDs not present in AtlasLoot/DBM tables (documented reason each)
EXTRA_NPCS = {
    ("Karazhan", "Attumen"): [15550],  # Attumen the Huntsman (unmounted) - listed in DBM Attumen.lua comment "--15550"
}

# Chest-based encounters: AtlasLoot ObjectID -> objectIDs field
# (ZA timed-chest object IDs are NOT in any local file; left empty on purpose)

# Supplemental drops missing from AtlasLoot but attested by other local sources.
# Each entry: (raidKey, bossKey) -> list of (itemID, comment)
SUPPLEMENTS = {
    # Faction variant of Magtheridon's Head (AtlasLoot only lists 32385). Present in
    # LootReserve/Data.lua (Magtheridon loot + faction-gated quest-reward table) and LoonBestInSlot.
    ("MagtheridonsLair", "Magtheridon"): [
        (32386, "Magtheridon's Head (other-faction variant of 32385) [supplement: LootReserve + LoonBestInSlot + Questie]"),
    ],
}
# Whole-list copies: (destination raid/boss, source raid/boss, attesting source)
SUPPLEMENT_COPIES = [
    # LootReserve/Data.lua lists the BT bracer/shoulder crafting patterns under Hyjal Summit trash as well.
    (("HyjalSummit", "Trash"), ("BlackTemple", "Patterns"), "LootReserve"),
]

# Quest items whose rewards equal another quest item's rewards (faction variants)
QUEST_TOKEN_ALIASES = {32386: 32385}

# DISPUTED attributions: positively attested by LoonBestInSlot AND Questie (tbcItemDB npcDrops = {25165,25166}),
# but omitted (not contradicted) by AtlasLoot and LootReserve. Shipped, tagged, so CDLoot can show "(unconfirmed)".
INCLUDE_DISPUTED = True
DISPUTED = {
    # LoonBestInSlot/DB/ItemSources.lua attributes the Sunwell T6 bracer/belt/boots tokens to
    # "Kalecgos & Eredar Twins", "Brutallus & Eredar Twins", "Felmyst & Eredar Twins".
    # Questie/Database/TBC/tbcItemDB.lua lists npcDrops {25165, 25166} (the Twins) for all nine tokens.
    # AtlasLoot AND LootReserve list them only under Kalecgos / Brutallus / Felmyst.
    ("SunwellPlateau", "EredarTwins"): [
        (34848, "Bracers of the Forgotten Conqueror [supplement: LoonBestInSlot + Questie; disputed]"),
        (34851, "Bracers of the Forgotten Protector [supplement: LoonBestInSlot + Questie; disputed]"),
        (34852, "Bracers of the Forgotten Vanquisher [supplement: LoonBestInSlot + Questie; disputed]"),
        (34853, "Belt of the Forgotten Conqueror [supplement: LoonBestInSlot + Questie; disputed]"),
        (34854, "Belt of the Forgotten Protector [supplement: LoonBestInSlot + Questie; disputed]"),
        (34855, "Belt of the Forgotten Vanquisher [supplement: LoonBestInSlot + Questie; disputed]"),
        (34856, "Boots of the Forgotten Conqueror [supplement: LoonBestInSlot + Questie; disputed]"),
        (34857, "Boots of the Forgotten Protector [supplement: LoonBestInSlot + Questie; disputed]"),
        (34858, "Boots of the Forgotten Vanquisher [supplement: LoonBestInSlot + Questie; disputed]"),
    ],
}

# LoonBestInSlot boss-name spellings -> AtlasLoot spellings (lower-case), for the cross-check only
LOON_BOSS_ALIASES = {
    "opera event (oz)": "the wizard of oz",
    "opera event (wolf)": "the big bad wolf",
    "opera event (romeo)": "romulo and julianne",
    "reliquary of souls": "reliquary of the lost",
    "timed event": "timed chest",
    "kil'jaeden": "kil'jaeden",
}

# LootReserve/Data.lua TBC raid tables (third independent source, cross-check only)
P_LOOTRESERVE = os.path.join(ADDONS, "LootReserve", "Data.lua")
LR_RAID_NAMES = {"World Bosses": "WorldBosses", "Karazhan": "Karazhan", "Gruul's Lair": "GruulsLair",
                 "Magtheridon's Lair": "MagtheridonsLair", "Serpentshrine Cavern": "SerpentshrineCavern",
                 "Tempest Keep": "TempestKeep", "The Eye": "TempestKeep", "Hyjal Summit": "HyjalSummit",
                 "Mount Hyjal": "HyjalSummit", "Battle for Mount Hyjal": "HyjalSummit", "Black Temple": "BlackTemple", "Zul'Aman": "ZulAman",
                 "Sunwell Plateau": "SunwellPlateau"}

DUMMY_PREFIXES = ("INV_", "ICON_", "ABILITY_", "ADDON_", "CLASS_", "SLOT_", "SPECIAL_")
STRING_TYPE_PREFIXES = {"ac": "achievement", "f": "faction", "i": "item-string", "l": "link", "prof": "profession", "set": "set"}


# --------------------------------------------------------------------------------------
# DBM creature / encounter IDs
# --------------------------------------------------------------------------------------
def dbm_ids(relpath):
    if not relpath:
        return [], []
    path = os.path.join(ADDONS, relpath.replace("/", os.sep))
    if not os.path.exists(path):
        return [], []
    txt = read(path)
    cids, eids = [], []
    for m in re.finditer(r"^[^-\n]*mod:SetCreatureID\(([^)]*)\)", txt, re.M):
        for x in re.findall(r"\d+", m.group(1)):
            v = int(x)
            if v != 99999 and v not in cids:
                cids.append(v)
    for m in re.finditer(r"^\s*(--)?\s*mod:SetEncounterID\(([^)]*)\)", txt, re.M):
        for x in re.findall(r"\d+", m.group(2)):
            v = int(x)
            if v not in eids:
                eids.append(v)
    return cids, eids


# --------------------------------------------------------------------------------------
# Parse AtlasLoot raids
# --------------------------------------------------------------------------------------
def parse_atlas_raids():
    text = read(P_ATLAS_RAIDS)
    toks, comments = tokenize(text)
    # collect commented-out loot rows:  --{ 2, 34386 }, -- Name
    commented_rows = {}
    for ln, c in comments.items():
        m = re.match(r"^\{\s*\d+\s*,\s*(\d+)\s*\}\s*,?\s*(?:--\s*(.*))?$", c)
        if m:
            commented_rows[ln] = (int(m.group(1)), (m.group(2) or "").strip())
    raids = {}
    for al_key, *_ in RAIDS:
        idx = find_assignment(toks, [("name", "data"), ("op", "["), ("str", al_key), ("op", "]"), ("op", "=")])
        if idx is None:
            raise RuntimeError(f"data[{al_key!r}] not found")
        p = Parser(toks)
        p.i = idx
        raids[al_key] = p.parse_table()
    return raids, comments, commented_rows


P_QUESTIE_ITEMS = os.path.join(ADDONS, "Questie", "Database", "TBC", "tbcItemDB.lua")
P_QUESTIE_OBJECTS = os.path.join(ADDONS, "Questie", "Database", "TBC", "tbcObjectDB.lua")


def load_questie_items():
    """itemID -> (name, npcDrops list, objectDrops list) from Questie's TBC item DB."""
    out = {}
    if not os.path.exists(P_QUESTIE_ITEMS):
        return out
    rx = re.compile(r"^\[(\d+)\] = \{'((?:\\.|[^'\\])*)',(nil|\{[\d,]*\}),(nil|\{[\d,]*\})", re.M)

    def nums(g):
        return [int(x) for x in re.findall(r"\d+", g)] if g != "nil" else []
    for m in rx.finditer(read(P_QUESTIE_ITEMS)):
        out[int(m.group(1))] = (m.group(2).replace("\\'", "'"), nums(m.group(3)), nums(m.group(4)))
    return out


def load_questie_object_names():
    out = {}
    if not os.path.exists(P_QUESTIE_OBJECTS):
        return out
    for m in re.finditer(r'^\[(\d+)\] = \{"((?:\\.|[^"\\])*)"', read(P_QUESTIE_OBJECTS), re.M):
        out[int(m.group(1))] = m.group(2)
    return out


def crosscheck_lootreserve(out_raids):
    """Compare our per-raid item sets with LootReserve's TBC tables (ignores its 'Tier N Pieces' / recipe sub-lists)."""
    if not os.path.exists(P_LOOTRESERVE):
        return {"available": False}
    toks, _ = tokenize(read(P_LOOTRESERVE))
    lr = {}  # raidKey -> {bossName: [items]}
    for i in range(len(toks) - 6):
        t = toks[i]
        if t.kind == "op" and t.val == "[" and toks[i + 1].kind == "num" and 2000 <= toks[i + 1].val < 2100 \
                and toks[i + 2].val == "]" and toks[i + 3].val == "=":
            p = Parser(toks)
            p.i = i + 4
            try:
                node = p.parse_expr()
            except SyntaxError:
                continue
            tables = []

            def collect(n):
                if isinstance(n, LuaTable):
                    tables.append(n)
                elif isinstance(n, tuple) and n[0] == "call":
                    for a in n[2]:
                        collect(a)
            collect(node)
            for tb in tables[:1]:  # first branch of Ternary = the TBC-era variant
                rname = resolve_text(tb.get("Name")) if tb.get("Name") is not None else None
                rkey = LR_RAID_NAMES.get(rname)
                if not rkey or rkey in lr:
                    continue
                bosses = OrderedDict()

                def walk(n):
                    if isinstance(n, tuple) and n[0] == "call":
                        for a in n[2][1:2] if n[1] == "Ternary" else n[2]:
                            walk(a)
                    elif isinstance(n, LuaTable):
                        if isinstance(n.get("Loot"), LuaTable):
                            bn = (resolve_text(n.get("Name")) or "?").strip(" -")
                            bosses[bn] = [x for x in n.get("Loot").array if isinstance(x, int) and x > 0]
                        else:
                            for a in n.array:
                                walk(a)
                walk(tb.get("Children"))
                lr[rkey] = bosses
    res = {"available": True, "raids_found": sorted(lr), "per_raid": {}}
    for raid in out_raids:
        ours = {x[1] for b in raid["bosses"] for x in b["items"] if x[0] == "item"}
        theirs_b = lr.get(raid["key"], {})
        theirs = {x for bn, xs in theirs_b.items() if not re.search(r"Pieces|Season|Sunmote|Quest Rewards", bn) for x in xs}
        res["per_raid"][raid["key"]] = {
            "ours": len(ours), "theirs": len(theirs), "common": len(ours & theirs),
            "only_ours": sorted(ours - theirs), "only_lootreserve": sorted(theirs - ours),
            "lr_bosses": list(theirs_b.keys()),
        }
    return res


def main():
    report = OrderedDict()
    report["skipped"] = []
    report["warnings"] = []

    atlas, comments, commented_rows = parse_atlas_raids()

    # ---- source-tbc (AtlasLoot reverse source map) for cross-checks
    src_text = read(P_ATLAS_SOURCE)
    src_toks, _ = tokenize(src_text)
    si = find_assignment(src_toks, [("name", "local"), ("name", "SOURCE_DATA"), ("op", "=")])
    sp = Parser(src_toks)
    sp.i = si
    source_data = sp.parse_table()
    atlas_ids = [resolve_text(x) for x in source_data.get("AtlasLootIDs").array]
    item_src = source_data.get("ItemData").hash  # itemID -> value

    # ---- Questie TBC item DB: names, npcDrops, objectDrops (names fallback + chest object IDs + loot-holder check)
    questie = load_questie_items()
    qobj_names = load_questie_object_names()

    # ---- Loon names / sources
    loon = {}
    loon_re = re.compile(r'^\s*\[(\d+)\]\s*=\s*\{\s*Name\s*=\s*"((?:\\.|[^"\\])*)"\s*,\s*SourceType\s*=\s*LBIS\.L\["([^"]*)"\]\s*,\s*Source\s*=\s*(.*?)\s*,\s*SourceNumber\s*=\s*"([^"]*)"\s*,\s*SourceLocation\s*=\s*(.*?)\s*,\s*SourceFaction\s*=\s*"([^"]*)"', re.M)
    for m in loon_re.finditer(read(P_LOON_SOURCES)):
        def L(expr):
            return " & ".join(re.findall(r'LBIS\.L\["([^"]*)"\]', expr)) or expr.strip('"')
        loon[int(m.group(1))] = {
            "name": m.group(2).replace('\\"', '"'), "type": m.group(3), "source": L(m.group(4)),
            "number": m.group(5), "location": L(m.group(6)),
        }

    # ---- Build raids
    out_raids = []
    item_count_total = 0
    all_item_sources = defaultdict(list)  # itemID -> [(raidKey, bossKey)]
    for al_key, key, disp, phase, size in RAIDS:
        rt = atlas[al_key]
        instance_id = rt.get("InstanceID")
        entries = rt.get("items")
        bosses = []
        for pos, entry in enumerate(entries.array, start=1):
            if entry is None:
                continue
            if isinstance(entry, tuple):
                if entry[0] == "ident":
                    report["skipped"].append({"raid": key, "entry": entry[1], "reason": "item-set table (SET_ITTYPE, ExtraList, IgnoreAsSource) - rows are set IDs, not items"})
                elif entry[0] == "call":
                    inner = next((a for a in entry[2] if isinstance(a, LuaTable)), None)
                    nm = resolve_text(inner.get("name")) if inner else "?"
                    report["skipped"].append({"raid": key, "entry": nm, "reason": f"wrapped in {entry[1]}(WRATH_VERSION_NUM, ...) - Wrath-only, nil on TBC client"})
                continue
            name_en = resolve_text(entry.get("name"))
            if (al_key, name_en) in SKIP_BOSSES:
                report["skipped"].append({"raid": key, "entry": name_en, "reason": SKIP_BOSSES[(al_key, name_en)]})
                continue
            meta = BOSS_META.get((al_key, name_en))
            if not meta:
                report["warnings"].append(f"No BOSS_META for {al_key}/{name_en}; key derived automatically")
                meta = (re.sub(r"[^A-Za-z0-9]", "", name_en.title()), None, None)
            bkey, group, dbm_rel = meta
            npc = entry.get("npcID")
            npcs = []
            if isinstance(npc, (int, float)):
                npcs = [int(npc)]
            elif isinstance(npc, LuaTable):
                npcs = [int(x) for x in npc.array]
            cids, eids = dbm_ids(dbm_rel)
            if group == "Opera Event":
                eids = [655, 2447]  # DBM: "used by all 3 of them" (Oz/Wolf/R&J share one encounter ID)
            for c in cids + EXTRA_NPCS.get((key, bkey), []):
                if c not in npcs:
                    npcs.append(c)
            obj = entry.get("ObjectID")
            objs = [int(obj)] if isinstance(obj, (int, float)) else ([int(x) for x in obj.array] if isinstance(obj, LuaTable) else [])
            if name_en == "Timed Chest" or objs:
                for row_iid in [int(r.array[1]) for dk in entry.hash if isinstance(dk, tuple) and dk[0] == "ident" and dk[1].endswith("_DIFF")
                                for r in entry.hash[dk].array if isinstance(r, LuaTable) and len(r.array) > 1 and isinstance(r.array[1], (int, float))]:
                    for o in questie.get(row_iid, ("", [], []))[2]:
                        if o not in objs and o in qobj_names and qobj_names[o] and (name_en == "Timed Chest" or o in objs):
                            objs.append(o)
                            report.setdefault("questie_objectIDs", []).append({"raid": key, "boss": name_en, "object": o, "name": qobj_names[o], "via_item": row_iid})
            is_trash = name_en in ("Trash", "Patterns")
            is_chest = bool(objs) or name_en == "Timed Chest"
            # difficulties
            diff_keys = [k for k in entry.hash if isinstance(k, tuple) and k[0] == "ident" and k[1].endswith("_DIFF")]
            if not diff_keys:
                report["warnings"].append(f"{key}/{name_en}: no difficulty tables")
            if any(k[1] != "NORMAL_DIFF" for k in diff_keys):
                report["warnings"].append(f"{key}/{name_en}: non-NORMAL difficulty present: {[k[1] for k in diff_keys]} (merged)")
            items = []  # list of ("item", id, comment) | ("header", text)
            seen = set()
            for dk in diff_keys:
                rows = entry.hash[dk]
                for r_i, row in enumerate(rows.array):
                    if not isinstance(row, LuaTable) or len(row.array) < 2:
                        report["skipped"].append({"raid": key, "boss": name_en, "row": repr(row), "reason": "malformed row"})
                        continue
                    val = row.array[1]
                    cmt = comments.get(rows.array_lines[r_i]) or comments.get(row.line_end) or ""
                    if isinstance(val, tuple) and val[0] == "str":
                        s = val[1]
                        if s.startswith(DUMMY_PREFIXES):
                            header = resolve_text(row.array[3]) if len(row.array) > 3 else s
                            items.append(("header", header))
                            report["skipped"].append({"raid": key, "boss": name_en, "row": s, "text": header, "reason": "icon/header row (Dummy type) - not an item; kept as a Lua comment"})
                        else:
                            m = re.match(r"^([a-z]+)", s)
                            report["skipped"].append({"raid": key, "boss": name_en, "row": s, "reason": f"string row type '{STRING_TYPE_PREFIXES.get(m.group(1) if m else '', 'unknown')}' - not a plain item"})
                        continue
                    if not isinstance(val, (int, float)):
                        report["skipped"].append({"raid": key, "boss": name_en, "row": repr(val), "reason": "non-numeric item value"})
                        continue
                    iid = int(val)
                    ids = [iid]
                    for hk, hv in row.hash.items():
                        if isinstance(hk, tuple) and hk[0] == "ident" and hk[1].startswith("ATLASLOOT_IT_") and isinstance(hv, (int, float)):
                            ids.append(int(hv))  # faction variant
                    for x in ids:
                        if x in SKIP_ITEMS:
                            report["skipped"].append({"raid": key, "boss": name_en, "item": x, "reason": SKIP_ITEMS[x]})
                            continue
                        if x in seen:
                            continue
                        seen.add(x)
                        items.append(("item", x, cmt))
            # commented-out rows inside this boss table (for the report)
            for ln in range(entry.line_start, entry.line_end + 1):
                if ln in commented_rows:
                    iid, nm = commented_rows[ln]
                    report["skipped"].append({"raid": key, "boss": name_en, "item": iid, "name": nm, "reason": "commented out in AtlasLoot (--{ idx, id })"})
            # supplements (+ disputed ones only if enabled)
            supp = list(SUPPLEMENTS.get((key, bkey), []))
            if INCLUDE_DISPUTED:
                supp += DISPUTED.get((key, bkey), [])
            for iid, cmt in DISPUTED.get((key, bkey), []):
                if not INCLUDE_DISPUTED:
                    report["skipped"].append({"raid": key, "boss": bkey, "item": iid, "reason": "DISPUTED attribution (LoonBestInSlot + Questie say yes; AtlasLoot + LootReserve omit) - not shipped: " + cmt})
            for iid, cmt in supp:
                if iid not in seen:
                    seen.add(iid)
                    items.append(("item", iid, cmt))
                    report.setdefault("supplements", []).append({"raid": key, "boss": bkey, "item": iid, "comment": cmt})
            n_items = sum(1 for x in items if x[0] == "item")
            item_count_total += n_items
            for x in items:
                if x[0] == "item":
                    all_item_sources[x[1]].append((key, bkey))
            bosses.append(OrderedDict(
                key=bkey,
                name=NAME_OVERRIDE.get((al_key, name_en), name_en),
                atlasName=name_en, atlasIndex=pos,
                npcIDs=npcs, objectIDs=objs, encounterIDs=eids,
                group=group, isTrash=is_trash, isChest=is_chest,
                items=items, nItems=n_items,
            ))
        out_raids.append(OrderedDict(key=key, alKey=al_key, name=disp, phase=phase, size=size,
                                     instanceID=instance_id, bosses=bosses))

    # ---- Loot-holder check: Questie's Badge of Justice npcDrops/objectDrops = every loot-bearing TBC boss unit/chest
    badge = questie.get(29434)
    if badge:
        bn, bo = set(badge[1]), set(badge[2])
        holders = {}
        for r in out_raids:
            for b in r["bosses"]:
                if b["isTrash"] or r["key"] == "WorldBosses" or b["group"] == "Servant Quarters" or b["key"] == "TimedChests":
                    continue
                h = [x for x in b["npcIDs"] if x in bn] + [o for o in b["objectIDs"] if o in bo]
                holders[f"{r['key']}/{b['key']}"] = h
                if not h:
                    report["warnings"].append(f"{r['key']}/{b['key']}: none of npcIDs/objectIDs is a Questie loot holder")
        report["loot_holders_questie"] = holders

    # ---- Post-pass: copy whole item lists between bosses where another local source attests it
    by_key = {(r["key"], b["key"]): b for r in out_raids for b in r["bosses"]}
    for (dst, src, tag) in SUPPLEMENT_COPIES:
        db, sb = by_key.get(dst), by_key.get(src)
        if not db or not sb:
            report["warnings"].append(f"SUPPLEMENT_COPIES: missing {dst} or {src}")
            continue
        have = {x[1] for x in db["items"] if x[0] == "item"}
        db["items"].append(("header", f"also drops here per {tag} (AtlasLoot lists these under {src[0]} {src[1]})"))
        for x in sb["items"]:
            if x[0] == "item" and x[1] not in have:
                have.add(x[1])
                db["items"].append(("item", x[1], f"{x[2]} [supplement: {tag}]"))
                db["nItems"] += 1
                item_count_total += 1
                all_item_sources[x[1]].append(dst)
                report.setdefault("supplements", []).append({"raid": dst[0], "boss": dst[1], "item": x[1], "comment": x[2] + f" [copied from {src[0]}/{src[1]} per {tag}]"})

    # ---- Cross-check boss attribution against AtlasLoot source-tbc (positional boss index)
    xcheck_src = {"match": 0, "mismatch": [], "missing": []}
    alidx = {name: i + 1 for i, name in enumerate(atlas_ids)}
    for raid in out_raids:
        ri = alidx.get(raid["alKey"])
        for b in raid["bosses"]:
            for x in b["items"]:
                if x[0] != "item":
                    continue
                if "[supplement:" in (x[2] or ""):
                    xcheck_src.setdefault("skipped_supplements", 0)
                    xcheck_src["skipped_supplements"] += 1
                    continue
                iid = x[1]
                v = item_src.get(iid)
                if v is None:
                    xcheck_src["missing"].append((raid["key"], b["key"], iid))
                    continue
                entries = []
                if isinstance(v, LuaTable):
                    if v.array and isinstance(v.array[0], LuaTable):
                        entries = [tuple(e.array[:2]) for e in v.array]
                    elif v.array:
                        entries = [tuple(v.array[:2])]
                if (ri, b["atlasIndex"]) in entries:
                    xcheck_src["match"] += 1
                else:
                    xcheck_src["mismatch"].append((raid["key"], b["key"], iid, repr(v if not isinstance(v, LuaTable) else [getattr(e, 'array', e) for e in v.array] or dict(v.hash))))
    report["crosscheck_atlas_source_tbc"] = {"match": xcheck_src["match"], "mismatch": xcheck_src["mismatch"], "missing": xcheck_src["missing"], "skipped_supplements": xcheck_src.get("skipped_supplements", 0)}

    # ---- Cross-check vs LoonBestInSlot raid attribution
    raid_loc = {"Karazhan": "Karazhan", "GruulsLair": "Gruul's Lair", "MagtheridonsLair": "Magtheridon's Lair",
                "WorldBosses": "World Bosses", "SerpentshrineCavern": "Serpentshrine Cavern", "TempestKeep": "Tempest Keep",
                "HyjalSummit": "Hyjal Summit", "BlackTemple": "Black Temple", "ZulAman": "Zul'Aman", "SunwellPlateau": "Sunwell Plateau"}
    loc_to_raid = {v: k for k, v in raid_loc.items()}
    bossname = {}
    for raid in out_raids:
        for b in raid["bosses"]:
            bossname[(raid["key"], b["key"])] = b["atlasName"]
    loon_x = {"agree": 0, "boss_differs": [], "loon_raid_item_not_in_db": []}
    for iid, e in loon.items():
        if e["type"] not in ("Drop", "Token"):
            continue
        locs = [l for l in e["location"].split(" & ")]
        raids_here = [loc_to_raid[l] for l in locs if l in loc_to_raid]
        if not raids_here:
            continue
        ours = all_item_sources.get(iid)
        if not ours:
            loon_x["loon_raid_item_not_in_db"].append((iid, e["name"], e["source"], e["location"]))
            continue
        our_names = {bossname[s].lower() for s in ours}
        loon_names = {LOON_BOSS_ALIASES.get(s.strip().lower(), s.strip().lower()) for s in e["source"].split(" & ")}
        if (our_names & loon_names or any(n in ("trash", "patterns") for n in our_names)
                or loon_names & {"various bosses"}
                or ("servant quarters" in loon_names and our_names & {"rokad the ravager", "shadikith the glider", "hyakiss the lurker"})):
            loon_x["agree"] += 1
        else:
            loon_x["boss_differs"].append((iid, e["name"], sorted(our_names), sorted(loon_names)))
    report["crosscheck_loon"] = loon_x

    # ---- Cross-check vs LootReserve/Data.lua (per-raid item sets + per-boss by name)
    report["crosscheck_lootreserve"] = crosscheck_lootreserve(out_raids)

    # ---- Tokens from AtlasLoot Token.lua (TOKEN_DATA.BCC)
    tok_text = read(P_ATLAS_TOKEN)
    ttoks, tcomments = tokenize(tok_text)
    ti = find_assignment(ttoks, [("name", "TOKEN_DATA"), ("op", "."), ("name", "BCC"), ("op", "=")])
    tp = Parser(ttoks)
    tp.i = ti
    bcc = tp.parse_table()
    tokens = OrderedDict()     # token -> list of (class, [pieces])
    token_names = {}
    quest_tokens = OrderedDict()
    upgrades = OrderedDict()   # base drop -> sunmote upgraded item
    raid_item_set = set(all_item_sources)
    for k, v in bcc.hash.items():
        if not isinstance(k, int) or not isinstance(v, LuaTable):
            continue
        typ = v.get("type")
        cmt = tcomments.get(v.line_end) or tcomments.get(v.line_start) or ""
        if typ == 6:
            groups = []
            cur = None
            for x in v.array:
                if isinstance(x, tuple) and x[0] == "ident" and x[1].startswith("ICONS."):
                    cur = (x[1].split(".", 1)[1], [])
                    groups.append(cur)
                elif isinstance(x, int) and x != 0:
                    if cur is None:
                        cur = ("?", [])
                        groups.append(cur)
                    cur[1].append(x)
            tokens[k] = groups
            token_names[k] = cmt
        elif typ == 8 and v.array and isinstance(v.array[0], int):
            # [base] = { upgraded, 0, {34664,"1"}, {base,"1"}, type = 8 }  -> base drop upgrades (with Sunmote) into upgraded
            upgrades[k] = (v.array[0], cmt)
        elif typ in (3, None) and k in raid_item_set and all(isinstance(x, int) for x in v.array) and v.array:
            quest_tokens[k] = (list(v.array), cmt)
    # verification of token pieces
    tv = {"pieces": 0, "verified_both": 0, "verified_source_tbc": 0, "verified_loon": 0, "unverified": [], "conflicts": []}
    for tk, groups in tokens.items():
        for cls, pieces in groups:
            for pc in pieces:
                tv["pieces"] += 1
                s = item_src.get(pc)
                ok_src = (s == tk)
                le = loon.get(pc)
                ok_loon = bool(le and le["type"] == "Tier Token" and le["number"] == str(tk))
                if le and le["type"] == "Tier Token" and le["number"] not in ("0", str(tk)):
                    tv["conflicts"].append((tk, pc, "loon says token " + le["number"]))
                if isinstance(s, int) and s != tk:
                    tv["conflicts"].append((tk, pc, "source-tbc says token " + str(s)))
                if ok_src and ok_loon:
                    tv["verified_both"] += 1
                elif ok_src:
                    tv["verified_source_tbc"] += 1
                elif ok_loon:
                    tv["verified_loon"] += 1
                else:
                    tv["unverified"].append((tk, pc))
    # faction-variant quest items share the rewards of their twin
    for alias, twin in QUEST_TOKEN_ALIASES.items():
        if twin in quest_tokens and alias in raid_item_set:
            quest_tokens[alias] = (quest_tokens[twin][0], quest_tokens[twin][1] + " (faction variant of %d)" % twin)
    # Loon raid items that we cover through quest-reward tokens are not "missing"
    covered = {r: t for t, (rw, _) in quest_tokens.items() for r in rw}
    still_missing, via_quest = [], []
    for row in loon_x["loon_raid_item_not_in_db"]:
        (via_quest if row[0] in covered else still_missing).append(row)
    loon_x["loon_raid_item_not_in_db"] = still_missing
    loon_x["covered_via_quest_token"] = via_quest

    # reverse completeness: every piece that source-tbc maps to a type-6 token must be in that token's list
    missing_rev = []
    for pc, s in item_src.items():
        if isinstance(pc, int) and isinstance(s, int) and s in tokens:
            if not any(pc in pieces for _, pieces in tokens[s]):
                missing_rev.append((s, pc))
    tv["pieces_in_source_tbc_missing_from_token_lists"] = missing_rev
    # all type-6 tokens must appear in some boss list
    tv["tokens_not_dropped_by_any_boss"] = [t for t in tokens if t not in raid_item_set]
    # independent check against LootReserve's TokenMap region (Data.lua, "-- Kara" .. "-- Naxx 10")
    lr_tok, lr_pvp, lr_simple = {}, {}, {}
    if os.path.exists(P_LOOTRESERVE):
        lrt = read(P_LOOTRESERVE)
        a = lrt.find("[29757] = ConcatenateIf(")
        b = lrt.find("-- Naxx 10", a)
        if a > 0 and b > a:
            region = lrt[lrt.rfind("-- Kara", 0, a):b]
            for m in re.finditer(r"\[(\d+)\]\s*=\s*ConcatenateIf\(\{([\d,\s]+)\},\s*EXPANSION_PHASE\s*>=\s*([\d.]+),\s*\{([\d,\s]+)\}\)", region):
                lr_tok[int(m.group(1))] = [int(x) for x in re.findall(r"\d+", m.group(2))]
                lr_pvp[int(m.group(1))] = (m.group(3), [int(x) for x in re.findall(r"\d+", m.group(4))])
            for m in re.finditer(r"\[(\d+)\]\s*=\s*\{([\d,\s]+)\}", region):
                lr_simple[int(m.group(1))] = [int(x) for x in re.findall(r"\d+", m.group(2))]
    lrv = {"tokens_checked": 0, "exact_match": 0, "differs": [], "missing_in_lootreserve": []}
    for tk, groups in tokens.items():
        ours = sorted(pc for _, ps in groups for pc in ps)
        theirs = lr_tok.get(tk) or lr_simple.get(tk)
        if theirs is None:
            lrv["missing_in_lootreserve"].append(tk)
            continue
        lrv["tokens_checked"] += 1
        if ours == sorted(theirs):
            lrv["exact_match"] += 1
        else:
            lrv["differs"].append((tk, sorted(set(ours) - set(theirs)), sorted(set(theirs) - set(ours))))
    up_ok = sum(1 for base, (up, _) in upgrades.items() if lr_simple.get(base) == [up])
    lrv["sunmote_upgrades_matching"] = f"{up_ok}/{len(upgrades)}"
    qt_ok = [tk for tk, (rw, _) in quest_tokens.items() if tk in (32385, 32386)]
    lrv["mag_head_in_lootreserve"] = "32385/32386 -> {28791,28790,28793,28792} (faction-gated)" if qt_ok else "n/a"
    lrv["pvp_exchange_tokens"] = len(lr_pvp)
    tv["lootreserve"] = lrv
    report["token_verification"] = tv

    # ---- Emit Lua
    def lstr(s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

    def lnums(xs):
        return "{ " + ", ".join(str(x) for x in xs) + " }" if xs else "{}"

    def cmt_clean(c):
        return c.replace("\n", " ").strip()

    L = []
    w = L.append
    w("-- CDLoot embedded raid-loot database (TBC Anniversary, Interface 20506)")
    w("-- AUTO-GENERATED by gen_cdloot_data.py - do not edit by hand; re-run the generator instead.")
    w("-- Sources (all read locally, GPL-licensed AtlasLootClassic data unless noted):")
    w("--   AtlasLootClassic_DungeonsAndRaids/data-tbc.lua  (raids, bosses, drops, item-name comments)")
    w("--   AtlasLootClassic/Data/Token.lua                 (tier token -> tier pieces, quest rewards, Sunmote upgrades)")
    w("--   DBM-Raids-BC / DBM-Outlands                     (extra creature IDs, encounter IDs)")
    w("--   LoonBestInSlot/DB/ItemSources.lua, LootReserve/Data.lua, AtlasLootClassic_Data/source-tbc.lua")
    w("--                                                   (cross-checks; items tagged [supplement: ...] come from them)")
    w("-- Item lists contain every real item AtlasLoot lists (incl. patterns, mounts, quest items, gems);")
    w("-- filter non-equippables at runtime if needed. Badge of Justice is excluded.")
    w("--")
    w("-- Boss fields: key, name, npcIDs (loot/encounter creature IDs), objectIDs (loot chest GameObject IDs),")
    w("--   encounterID (ENCOUNTER_END id: first arg of DBM SetEncounterID, same ids as TehBoxLootCouncil/RaidHelper_TBC;")
    w("--   the three Opera variants share 655; world bosses have none), group (UI grouping),")
    w("--   isTrash / isChest (pseudo-bosses), unconfirmed (set of disputed itemIDs), items (itemIDs, deduped, AtlasLoot order).")
    w("local _, ns = ...")
    w("ns.Data = ns.Data or {}")
    w("")
    w("ns.Data.Raids = {")
    for raid in out_raids:
        inst = f", instanceID = {raid['instanceID']}" if raid["instanceID"] else ""
        w(f"  {{ key = {lstr(raid['key'])}, name = {lstr(raid['name'])}, phase = {raid['phase']}, size = {raid['size']}{inst}, bosses = {{")
        for b in raid["bosses"]:
            fields = [f"key = {lstr(b['key'])}", f"name = {lstr(b['name'])}", f"npcIDs = {lnums(b['npcIDs'])}"]
            if b["objectIDs"]:
                fields.append(f"objectIDs = {lnums(b['objectIDs'])}")
            if b["encounterIDs"]:
                fields.append(f"encounterID = {b['encounterIDs'][0]}")
            if b["group"]:
                fields.append(f"group = {lstr(b['group'])}")
            if b["isTrash"]:
                fields.append("isTrash = true")
            if b["isChest"]:
                fields.append("isChest = true")
            unc = [x[1] for x in b["items"] if x[0] == "item" and "disputed" in (x[2] or "")]
            if unc:
                fields.append("unconfirmed = { " + ", ".join(f"[{i}] = true" for i in unc) + " }")
            w("    { " + ", ".join(fields) + ", items = {")
            for x in b["items"]:
                if x[0] == "header":
                    w(f"        -- {cmt_clean(x[1])}")
                else:
                    c = cmt_clean(x[2])
                    w(f"        {x[1]},{(' -- ' + c) if c else ''}")
            w("    }},")
        w("  }},")
    w("}")
    w("")
    # Tokens
    w("-- Tier token itemID -> tier piece itemIDs (all classes). From AtlasLoot Token.lua (TOKEN_DATA.BCC, type = 6).")
    w("-- Each piece cross-checked against AtlasLootClassic_Data/source-tbc.lua (piece -> token) and")
    w("-- LoonBestInSlot ItemSources (SourceType \"Tier Token\", SourceNumber = token). See generator report.")
    w("-- Also contains boss-dropped quest items whose quest rewards are gear (e.g. Magtheridon's Head, Verdant Sphere).")
    w("ns.Data.Tokens = {")
    tier_labels = {29753: "T4", 30236: "T5", 31089: "T6", 34848: "T6 (Sunwell)"}
    for tk, groups in tokens.items():
        w(f"  [{tk}] = {{ -- {cmt_clean(token_names.get(tk, ''))}")
        for cls, pieces in groups:
            for pc in pieces:
                nm = loon.get(pc, {}).get("name", "") or questie.get(pc, ("",))[0]
                w(f"    {pc}, -- {cls}{(': ' + nm) if nm else ''}")
        w("  },")
    if quest_tokens:
        w("  -- quest items dropped by bosses -> quest reward choices")
        for tk, (rewards, cmt) in quest_tokens.items():
            w(f"  [{tk}] = {{ -- {cmt_clean(cmt)} (quest reward)")
            for pc in rewards:
                nm = loon.get(pc, {}).get("name", "") or questie.get(pc, ("",))[0]
                w(f"    {pc},{(' -- ' + nm) if nm else ''}")
            w("  },")
    w("}")
    w("")
    w("-- Token itemID -> classes that can use it (for UI badges). Same source as ns.Data.Tokens.")
    w("ns.Data.TokenClasses = {")
    for tk, groups in tokens.items():
        w(f"  [{tk}] = {{ " + ", ".join(lstr(c) for c, _ in groups) + " },")
    w("}")
    w("")
    w("-- Sunwell Sunmote upgrades: dropped base itemID -> upgraded itemID (base + Sunmote 34664 via vendor).")
    w("-- If a BiS list contains the upgraded item, the base item's drop is relevant for that player.")
    w("ns.Data.Upgrades = {")
    for base, (up, cmt) in upgrades.items():
        up_name = loon.get(up, {}).get("name", "")
        w(f"  [{base}] = {up}, -- {cmt_clean(cmt)} -> {up_name}".rstrip(" ->"))
    w("}")
    w("")
    if lr_pvp:
        w("-- Tier token -> Gladiator (arena) pieces the token can ALSO be exchanged for, from LootReserve/Data.lua")
        w("-- (phase-gated there: T4 tokens from patch 2.2 / S1 gear, T5 from 2.3 / S2, T6 from 2.5 / S3).")
        w("-- NOT in AtlasLoot; single-source. Only matters if a BiS list contains an arena piece.")
        w("ns.Data.TokenArenaExchanges = {")
        for tk in tokens:
            if tk in lr_pvp:
                ph, ids = lr_pvp[tk]
                w(f"  [{tk}] = {{ patch = \"{ph}\", items = {{ -- {cmt_clean(token_names.get(tk, ''))}")
                for pc in ids:
                    nm = loon.get(pc, {}).get("name", "") or questie.get(pc, ("",))[0]
                    w(f"    {pc},{(' -- ' + nm) if nm else ''}")
                w("  }},")
        w("}")
        w("")
    with open(OUT_LUA, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L))

    # ---- report / counts
    counts = []
    for raid in out_raids:
        counts.append({
            "raid": raid["key"], "bosses": len(raid["bosses"]),
            "real_bosses": sum(1 for b in raid["bosses"] if not b["isTrash"] and b["key"] != "TimedChests"),
            "items": sum(b["nItems"] for b in raid["bosses"]),
            "unique_items": len({x[1] for b in raid["bosses"] for x in b["items"] if x[0] == "item"}),
            "per_boss": {b["key"]: b["nItems"] for b in raid["bosses"]},
        })
    report["counts"] = counts
    report["total_item_rows"] = item_count_total
    report["unique_items_total"] = len(all_item_sources)
    report["tokens"] = len(tokens)
    report["quest_tokens"] = {k: v[0] for k, v in quest_tokens.items()}
    report["upgrades"] = len(upgrades)
    report["shared_items"] = {str(k): v for k, v in all_item_sources.items() if len(v) > 1}
    with open(OUT_REPORT, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, default=str)

    # console summary
    print(f"Wrote {OUT_LUA}")
    for c in counts:
        print(f"  {c['raid']:22s} bosses={c['bosses']:2d} items={c['items']:4d} unique={c['unique_items']:4d}")
    print(f"  TOTAL item rows={item_count_total} unique items={len(all_item_sources)} tokens={len(tokens)} questTokens={len(quest_tokens)} upgrades={len(upgrades)}")
    print(f"  source-tbc crosscheck: match={xcheck_src['match']} mismatch={len(xcheck_src['mismatch'])} missing={len(xcheck_src['missing'])}")
    print(f"  loon crosscheck: agree={loon_x['agree']} differs={len(loon_x['boss_differs'])} loon-only={len(loon_x['loon_raid_item_not_in_db'])}")
    print(f"  token pieces={tv['pieces']} both={tv['verified_both']} srcOnly={tv['verified_source_tbc']} loonOnly={tv['verified_loon']} unverified={len(tv['unverified'])} conflicts={len(tv['conflicts'])} revMissing={len(missing_rev)} notDropped={tv['tokens_not_dropped_by_any_boss']}")
    lrx = report["crosscheck_lootreserve"]
    if lrx.get("available"):
        for rk, v in lrx["per_raid"].items():
            print(f"  lootreserve {rk:22s} ours={v['ours']:4d} theirs={v['theirs']:4d} common={v['common']:4d} onlyOurs={len(v['only_ours'])} onlyLR={len(v['only_lootreserve'])}")
    print(f"  warnings={report['warnings']}")


if __name__ == "__main__":
    main()
