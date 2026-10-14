"""Shared setup for the loot reserve tests (1.4.3, Core/Reserves.lua and friends). Not a test file itself:
    from rv_common import *
Builds on the loot-roll scenario raid (tests/loot-roll/lr_common.py): Alice is the GM, raid leader and master looter
(she hosts the reserves), Bob council, Carol .. Gina raiders with the addon; Zed a guildie and Yuri a pug, both without
the addon. Pug() adds pugs with the addon (no guild)."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "loot-roll"))

from lr_common import *  # noqa: E402,F401,F403
from lr_common import Raid, key, strip_codes, msgs_of_type, panel_blocks, rollframe_state, active_session  # noqa: E402,F401
from harness import Client, make_guid  # noqa: E402,F401

THERE = os.path.abspath(os.path.join(HERE, "..", "..", "thirdparty", "LootReserve"))


def reserve_raid(features=True, **kw):
    """A Raid() whose session runs reserves (features=True) and whose reserves Alice opened (1 each unless n)."""
    r = Raid(**kw)
    if features:
        set_reserve_features(r)
    return r


def set_reserve_features(r, on=True, by="Alice", tick=3):
    res = r[by].eval_py("local ok, e = ns.GroupRules:SetSessionFeatures(...); return { ok = ok, e = e }",
                        {"loot": True, "rolls": True, "lock": False, "reserve": on})
    assert res.get("ok") is True, res
    r.w.tick(tick)


def open_reserves(r, n=1, held=None, rk="Karazhan", by="Alice", tick=2):
    res = r[by].eval_py("local ok, e = ns.Reserves:Open(...); return { ok = ok, e = e }",
                        {"n": n, "hr": held or [], "rk": rk})
    assert res.get("ok") is True, res
    r.w.tick(tick)


def reserves_of(c, name):
    return c.eval_py("return ns.Reserves:Of(...)", key(name) if "-" not in name else name) or []


def reservers(c, item):
    return c.eval_py("return ns.Reserves:Reservers(...)", item) or []


def whisper(r, sender, text, to="Alice", guid=None):
    """sender (a name; a pug without a client too) whispers `to`: CHAT_MSG_WHISPER on the receiver."""
    full = key(sender)
    r[to].fire("CHAT_MSG_WHISPER", text, full, "", "", sender, "", 0, 0, "", 0, 1,
               guid or make_guid(sender, REALM), 0, False, False, False, False)
    r.w.tick(0.5)


def whispers_to(r, name, since=0, frm="Alice"):
    return [strip_codes(e["text"]) for e in r.w.chat_log[since:]
            if e["chat_type"] == "WHISPER" and e["sender"] == key(frm) and (e.get("target") or "").split("-")[0] == name]


def raid_lines(r, since=0):
    return [(e["chat_type"], strip_codes(e["text"])) for e in r.w.chat_log[since:]
            if e["chat_type"] in ("RAID", "RAID_WARNING")]


def decide(c, item):
    return c.eval_py("local k, keys = ns.Reserves:Decide(...); return { k = k, keys = keys }", item) or {}


def start_roll(r, item, copy=1, by="Alice"):
    r[by].eval("ns.DropPanel:StartRoll(...)", item, copy)
    r.w.tick(1)
    return active_session(r[by])


def roll_kind(c, sid):
    return c.eval_py("local k, keys = ns.Roll:ReserveKind(...); return { k = k, keys = keys }", sid) or {}


def results_rv(c, sid):
    return c.eval_py(r"""
        local out = {}
        for i, r in ipairs(ns.Roll:GetResults(...)) do
          out[i] = { key = r.key, roll = r.roll, suggested = r.suggested, by = r.suggestedBy, unres = r.unres,
                     reserved = r.reserved, notGuild = r.notGuild, response = r.response }
        end
        return out""", sid) or []
