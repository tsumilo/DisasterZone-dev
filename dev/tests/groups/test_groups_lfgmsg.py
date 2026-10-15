"""Groups: the LFG message builder (feedback #8: Core/GroupsLFG.lua, UI/GroupsMessage.lua).

Covers: a raid group's message from its blocks (LFM, name, count, what it needs, when, loot, /w me); the damage places
split into melee / ranged and the specs wanted show in it; blocks switch off, move and "Your words" adds text; the
length is counted against 255; Post sends to the LookingForGroup channel (asks to join it first, says so in demo
mode); the repeat is ready at once, waits after a post, is ready again when due, shows the poster, and stops when the
group goes; the leader page's LFG message tab shows the chips and the exact text; the key binding's function posts.

Run: luaenv\\Scripts\\python.exe tests\\groups\\test_groups_lfgmsg.py [-k name]   (from dev)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50


def guild(names, tick=HELLO):
    w = World()
    c = {}
    for i, (name, cls) in enumerate(names):
        c[name] = Client(w, name, class_file=cls, guild_rank=0 if i == 0 else 3)
    for x in c.values():
        x.load_addon()
    w.tick(tick)
    return w, c


def list_group(cl, **opts):
    rid = cl.eval_py("""
      local o = ...
      local t = {}
      for k, v in pairs(o) do t[k] = v end
      local r, why = ns.DungeonRuns:List(t)
      return r and r.id or why""", opts)
    assert isinstance(rid, str) and ":" in rid, rid
    return rid


def strip_codes(s):
    s = re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", s or "")
    return re.sub(r"\|T[^|]*\|t", "", s)


CHANNEL = """
  GetChannelName = function(name) if name == 'LookingForGroup' then return 4, name end return 0 end
  __sent = {}
  SendChatMessage = function(m, t, l, id) __sent[#__sent + 1] = { m, t, id } end
"""


def compose(cl):
    return cl.eval_py("return (ns.GroupsLFG:Compose())")


# ------------------------------------------------------------------------------------------------------------------
@case
def a_raid_groups_message_from_its_blocks():
    w, c = guild([("Gina", "PALADIN")])
    g = c["Gina"]
    list_group(g, k="raid", a=["GruulsLair", "MagtheridonsLair"], role="healer", lo="sr", lr=1)
    w.tick(1)
    assert compose(g) == "LFM Gruul + Mag · 1/25 · need 3 tanks, 5 healers, 16 DPS · now · SR 1 · /w Gina", compose(g)
    # the damage places split: 9 ranged, 7 melee; two resto shamans wanted
    for _ in range(7):
        assert g.eval_py("return ns.GroupsLFG:StepSplit('melee', 1)") is True
    for _ in range(9):
        assert g.eval_py("return ns.GroupsLFG:StepSplit('ranged', 1)") is True
    assert g.eval_py("return ns.GroupsLFG:StepSplit('ranged', 1)") is False   # (no damage place left)
    g.eval("ns.GroupsLFG:SetSpec('SHAMAN', 3, 2)")
    assert compose(g) == ("LFM Gruul + Mag · 1/25 · need 3 tanks, 5 healers, 7 melee, 9 ranged · Resto Shaman x2 · now"
                          " · SR 1 · /w Gina"), compose(g)
    # off, moved, your words
    g.eval("ns.GroupsLFG:SetBlockOn('count', false)")
    g.eval("ns.GroupsLFG:MoveBlock('time', 2)")
    g.eval("ns.GroupsLFG:SetBlockOn('custom', true); ns.GroupsLFG:SetCustom('exp only')")
    assert compose(g) == ("LFM now · Gruul + Mag · need 3 tanks, 5 healers, 7 melee, 9 ranged · Resto Shaman x2 · SR 1"
                          " · exp only · /w Gina"), compose(g)
    n = g.eval_py("local _, n, long = ns.GroupsLFG:Compose(); return { n, long }")
    assert n == [len(compose(g).encode("utf-8")), False], n   # (bytes: what the 255 limit counts)
    g.eval("ns.GroupsLFG:Reset()")
    assert compose(g).startswith("LFM Gruul + Mag · 1/25"), compose(g)
    w.assert_no_errors()


@case
def post_sends_to_the_lfg_channel():
    w, c = guild([("Gina", "PALADIN")])
    g = c["Gina"]
    list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(1)
    ok = g.eval_py("return { ns.GroupsLFG:Post() }")
    assert ok == [False, "Join the LookingForGroup channel first: /join LookingForGroup"], ok
    g.eval(CHANNEL)
    assert g.eval_py("return (ns.GroupsLFG:Post())") is True
    sent = g.eval_py("return __sent[1]")
    assert sent == [compose(g), "CHANNEL", 4], sent
    w.assert_no_errors()


@case
def the_repeat_is_ready_every_time_and_stops_with_the_group():
    w, c = guild([("Gina", "PALADIN")])
    g = c["Gina"]
    g.eval(CHANNEL)
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(1)
    assert g.eval_py("return (ns.GroupsLFG:SetRepeat(true))") is True
    assert g.eval_py("return ns.GroupsLFG:IsReady()") is True
    w.tick(1)
    p = g.eval_py("local p = ns.GroupsMessage:GetPoster(); return p and p:IsShown() and p.btn:GetText()")
    assert p == "Post", p
    # the poster's button posts; then it waits 30 s
    g.eval("ns.GroupsMessage:GetPoster().btn:Click()")
    assert g.eval_py("return #__sent") == 1
    assert g.eval_py("return ns.GroupsLFG:IsReady()") is False
    assert 25 <= g.eval_py("return ns.GroupsLFG:GetWait()") <= 30
    g.eval("ns.GroupsLFG:_Due()")
    assert g.eval_py("return ns.GroupsLFG:IsReady()") is True
    # the key binding posts too
    g.eval("DisasterZone_PostLFG()")
    assert g.eval_py("return #__sent") == 2
    # the group goes: the repeat stops, the poster hides
    g.eval("ns.DungeonRuns:Unlist()")
    w.tick(2)
    assert g.eval_py("return ns.GroupsLFG:IsRepeating()") is False
    assert g.eval_py("local p = ns.GroupsMessage:GetPoster(); return p:IsShown()") is False
    assert rid
    w.assert_no_errors()


@case
def the_leader_pages_lfg_message_tab():
    w, c = guild([("Gina", "PALADIN")])
    g = c["Gina"]
    g.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(1)
    g.eval("ns.GroupsLead:Open(nil, 'message')")
    preview = g.eval_py("""for _, f in ipairs({ ns.GroupsLead:Get().body:GetChildren() }) do
        if f.preview then return f.preview.text:GetText() end end""")
    assert strip_codes(preview) == compose(g), (preview, compose(g))
    labels = g.eval_py("""for _, f in ipairs({ ns.GroupsLead:Get().body:GetChildren() }) do
        if f.chips then
          local out = {}
          for _, ch in ipairs(f.chips) do if ch:IsShown() then out[#out + 1] = ch.blockKey end end
          return out
        end end""")
    assert len(labels) == 13 and labels[0] == "lfm", labels
    # a click on "/w me" leaves it out
    g.eval("""for _, f in ipairs({ ns.GroupsLead:Get().body:GetChildren() }) do
        if f.chips then for _, ch in ipairs(f.chips) do if ch.blockKey == 'whisper' then ch:Click() end end end end""")
    assert "/w" not in compose(g), compose(g)
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
