"""Azeromon's pixel beasts (DisasterZone_Azeromon/Sprites.lua + the generated BeastArt.lua / DisasterZone_Azeromon/Media/Beasts).

Covers: every species (and every shiny skin) has art for both views with every clip, every frame inside its texture;
the textures on disk are palette BLP2s laid out exactly like the client's own (the format the client really draws);
a battle draws both beasts as pixel art at the backdrop's 3x, yours from behind, and plays attack / special / hit /
faint; the next foe starts idle; an older art set or `/dz azeromon look 3d` falls back to the 3D models.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_sprites.py [-k name]
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402

from _azero_bot import BOT  # noqa: E402

ADDON = os.environ.get("DISASTERZONE_ADDON_DIR") or os.path.join(os.path.dirname(os.path.dirname(TESTS)), "addon", "DisasterZone")
CLIPS = ("idle", "attack", "special", "hit", "faint")


def game(seed=7):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    return w, c


def into_world(w, c):
    """title screen -> the overworld (a new game), like test_azeromon's death-pose case"""
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    for _ in range(40):
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil"):
            break


@case
def every_beast_has_art_for_both_views():
    w, c = game()
    bad = c.eval_py(r"""
      local D, S, art = ns.AzeroData, ns.AzeroSprites, ns.AzeroBeastArt
      local out = {}
      local function check(key)
        local b = art.beasts[key]
        if not b then out[#out + 1] = "no art " .. key return end
        local d = S._Beast(key)
        for _, v in ipairs({ "f", "a" }) do
          for _, clip in ipairs({ "idle", "attack", "special", "hit", "faint" }) do
            local c = d[v][clip]
            if not c or #c.frames == 0 then out[#out + 1] = key .. " " .. v .. " " .. clip end
            for _, f in ipairs(c and c.frames or {}) do
              if f[1] < 0 or f[2] < 0 or f[1] + f[3] > b.w or f[2] + f[4] > b.h or f[3] < 1 or f[4] < 1 then
                out[#out + 1] = key .. " frame outside its texture"
              end
            end
          end
        end
      end
      for id in pairs(D.species) do check(id) end
      for id in pairs(D.shinyDisplay) do check(id .. "_s") end
      return out""")
    assert bad == [], bad[:20]
    no_errors(w)


@case
def the_textures_are_palette_blps_like_the_clients_own():
    """The client draws a palette BLP only when it is laid out like its own (2026-10-14 a mip-less one came out as
    the missing-texture square): BLP2, palette, 1-bit alpha, alpha type 8, a full mip chain, palette alpha 0."""
    w, c = game()
    idx = c.eval_py("""local out = {}
      for k, b in pairs(ns.AzeroBeastArt.beasts) do out[#out + 1] = { k, b.tex, b.w, b.h } end
      return out""")
    assert len(idx) >= c.eval("local n = 0 for _ in pairs(ns.AzeroData.species) do n = n + 1 end return n")
    folder = os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Media", "Beasts")
    for key, tex, tw, th in idx:
        path = os.path.join(folder, tex + ".blp")
        assert os.path.exists(path), path
        d = open(path, "rb").read()
        assert d[:4] == b"BLP2" and struct.unpack_from("<I", d, 4)[0] == 1, key
        assert tuple(d[8:12]) == (1, 1, 8, 1), (key, tuple(d[8:12]))
        bw, bh = struct.unpack_from("<II", d, 12)
        assert (bw, bh) == (tw, th) and bw & (bw - 1) == 0 and bh & (bh - 1) == 0, (key, bw, bh, tw, th)
        offs = struct.unpack_from("<16I", d, 20)
        sizes = struct.unpack_from("<16I", d, 84)
        mips = [(o, s) for o, s in zip(offs, sizes) if o]
        assert len(mips) == max(bw, bh).bit_length(), (key, len(mips))           # down to 1 x 1
        mw, mh = bw, bh
        for o, s in mips:
            assert s == mw * mh + (mw * mh + 7) // 8, (key, mw, mh, s)
            mw, mh = max(1, mw // 2), max(1, mh // 2)
        assert all(d[148 + i * 4 + 3] == 0 for i in range(256)), key
        assert mips[-1][0] + mips[-1][1] == len(d), key
    no_errors(w)


@case
def a_battle_draws_both_beasts_as_pixel_art():
    w, c = game()
    into_world(w, c)
    c.eval("ns.Azero.save.party[1] = ns.AzeroMon.New('murkling', 12, ns.Azero.rng)")
    c.eval("ns.Azero:Run(function(g) g:WildBattle('kobling', 4) end)")
    w.tick(2)
    foe = c.eval_py("return ns.AzeroUI._Sprite('foe')")
    ally = c.eval_py("return ns.AzeroUI._Sprite('ally')")
    assert foe["key"] == "kobling" and foe["view"] == "f" and foe["scale"] == 3 and foe["shown"], foe
    lead = c.eval("return ns.Azero.save.party[1].sp")
    assert ally["key"] in (lead, lead + "_s") and ally["view"] == "a" and ally["scale"] == 3 and ally["shown"], ally
    assert c.eval("return ns.AzeroUI._Scene('foe') == nil")             # no 3D model was made
    no_errors(w)


@case
def attacks_hits_and_faints_play_their_clips():
    w, c = game(seed=4)
    into_world(w, c)
    c.eval("local M = ns.AzeroMon; local mon = M.New('murkling', 10, ns.Azero.rng); "
           "mon.moves = { { id = 'waterjet', pp = 25 }, { id = 'bite', pp = 25 } }; ns.Azero.save.party[1] = mon")
    seen = {"foe": set(), "ally": set()}
    for species in ("wolfpup", "kobling"):
        c.eval("ns.Azero:Run(function(g) g:WildBattle(%r, 9) end)" % species)
        for _ in range(300):
            w.tick(0.1)
            c.eval("ns.AzeroUI._HandleKey('A')")
            for side in seen:
                st = c.eval_py("return ns.AzeroUI._Sprite(%r)" % side)
                if st and st.get("clip"):
                    seen[side].add(st["clip"])
            if not c.eval("return ns.Azero.pending ~= nil or ns.AzeroUI._State().battle"):
                break
    assert "hit" in seen["foe"] | seen["ally"], seen                         # a hit that did not knock out
    assert "faint" in seen["foe"] | seen["ally"], seen
    assert seen["ally"] & {"attack", "attack2", "special"}, seen
    assert c.eval_py("return ns.AzeroUI._Sprite('foe').clip") in ("idle", "faint"), "the next foe never starts dead"
    no_errors(w)


@case
def the_next_foe_starts_idle_after_a_faint():
    """A faint holds its last frame; the next creature in the same frame starts on its idle's first frame."""
    w, c = game()
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._ShowFoe('wolfpup')")
    c.eval("ns.AzeroUI._SpriteAnim('foe', 1)")
    w.tick(2)
    st = c.eval_py("return ns.AzeroUI._Sprite('foe')")
    last = c.eval("return #ns.AzeroSprites._Beast('wolfpup').f.faint.frames")
    assert st["clip"] == "faint" and st["frame"] == last, (st, last)      # still lying on its last frame
    c.eval("ns.AzeroUI._ShowFoe('kobling')")
    st = c.eval_py("return ns.AzeroUI._Sprite('foe')")
    assert st["key"] == "kobling" and st["clip"] == "idle" and st["frame"] == 1, st
    no_errors(w)


@case
def an_older_art_set_shows_the_3d_models():
    """An in-game update can bring this code to a member whose art set is older than the index: 3D models then."""
    w, c = game()
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.assetPack = ns.AzeroBeastArt.asset - 1")
    c.eval("ns.AzeroUI._ShowFoe('kobling')")
    w.tick(0.2)
    assert c.eval_py("return ns.AzeroUI._Sprite('foe').shown") is False
    assert c.eval("return ns.AzeroUI._Scene('foe') ~= nil and ns.AzeroUI._Scene('foe'):IsShown()")
    no_errors(w)


@case
def the_look_command_switches_between_pixel_art_and_models():
    w, c = game()
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.slash("/dz azeromon look 3d")
    c.eval("ns.AzeroUI._ShowFoe('kobling')")
    assert c.eval_py("return ns.AzeroUI._Sprite('foe').shown") is False
    assert c.eval("return ns.Azero:Data().models3d") is True
    c.slash("/dz azeromon look pixel")
    c.eval("ns.AzeroUI._ShowFoe('kobling')")
    st = c.eval_py("return ns.AzeroUI._Sprite('foe')")
    assert st["shown"] and st["key"] == "kobling", st
    no_errors(w)


@case
def shinies_use_their_own_skin_or_glow():
    w, c = game()
    c.slash("/dz play azeromon")
    w.tick(0.3)
    skin = c.eval("for id in pairs(ns.AzeroData.shinyDisplay) do return id end")
    c.eval("ns.AzeroUI._ShowFoeShiny(%r)" % skin)
    st = c.eval_py("return ns.AzeroUI._Sprite('foe')")
    assert st["key"] == skin + "_s" and st["glow"] is False, st
    plain = c.eval("for id in pairs(ns.AzeroData.species) do if not ns.AzeroData.shinyDisplay[id] then return id end end")
    c.eval("ns.AzeroUI._ShowFoeShiny(%r)" % plain)
    st = c.eval_py("return ns.AzeroUI._Sprite('foe')")
    assert st["key"] == plain and st["glow"] is True, st
    no_errors(w)


if __name__ == "__main__":
    run_all(globals())
