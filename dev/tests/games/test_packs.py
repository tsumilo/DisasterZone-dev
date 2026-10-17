"""Game packs (dev/docs/GAME_PACKS.md): every minigame is an addon folder of its own, DisasterZone_<Game>, loaded at
login after DisasterZone when it is installed. These cases cover what the split adds: the packs start (in both load
orders the harness knows), the hub shows a stand-in poster for a game that is not installed / switched off / from
another release, a pack from another release is skipped whole (Core/Boot.lua CheckPack), and an in-game update
reaches a pack's files and adds a file at a pack's end (Core/Boot.lua EndPack).
"""
import os
import shutil
import sys
import tempfile
import atexit

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
DEV = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(DEV, "tools"))

from _common import case, run_all, solo, no_errors  # noqa: E402
from harness import World, Client, ADDON_DIR, packs_for  # noqa: E402
import patchlib  # noqa: E402
import release  # noqa: E402

POSTERS = "ns.GamesUI.__posters"
IDS = ["bingo", "trainer", "azeromon", "chess", "illidan", "holdtheline"]
FOLDERS = {"bingo": "DisasterZone_Bingo", "trainer": "DisasterZone_Trainer", "azeromon": "DisasterZone_Azeromon",
           "chess": "DisasterZone_Chess", "illidan": "DisasterZone_Illidan", "holdtheline": "DisasterZone_HoldTheLine"}
TMP = tempfile.mkdtemp(prefix="dzpacks_")
atexit.register(lambda: shutil.rmtree(TMP, ignore_errors=True))
_N = [0]


def hub(c):
    c.eval("ns.MainFrame:Open('games')")
    c.world.tick(0.5)


def poster(c, gid, field):
    return c.eval("for _, p in ipairs(%s) do if p.id == ... then return p.%s:GetText() end end" % (POSTERS, field), gid)


def stub(c, gid):
    return c.eval("for _, p in ipairs(%s) do if p.id == ... then return p.stub == true end end" % POSTERS, gid)


def states(c):
    return {g: c.eval("return ns.Games:PackState(...)", g) for g in IDS}


def without(*ids):
    """The installed packs but these (harness packs=)."""
    return {n: f for n, f in packs_for(ADDON_DIR).items() if n not in {FOLDERS[i] for i in ids}}


def test_key():
    return patchlib.keygen(4, secret=(b"packs" * 8)[:32], seed=(b"skcap" * 4)[:16])


def tree_copy(mods=None):
    """The addon and its packs (.lua / .toc only, hard links) in a folder of their own, as a development copy with the
    test signing key. mods(root_of_folders) edits it (replace files, never write into them: they are links).
    Returns the copy's DisasterZone folder."""
    _N[0] += 1
    root = os.path.join(TMP, "tree%d" % _N[0])
    folders = {release.ADDON_NAME: ADDON_DIR}
    folders.update(packs_for(ADDON_DIR))
    for name, src in folders.items():
        for rel in release.all_files(src):
            if rel.endswith((".lua", ".toc")):
                dst = os.path.join(root, name, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                os.link(os.path.join(src, rel), dst)
    core = os.path.join(root, release.ADDON_NAME)
    put(core, "Core/PatchKey.lua", release.patch_key_lua(test_key()))
    put(core, "Core/BuildInfo.lua", 'DisasterZoneBuild = {\n    id = "dev",\n    assetPack = 99,\n}\n')
    put(core, "Core/Outbox.lua", patchlib.OUTBOX_STUB)
    if mods:
        mods(root)
    return core


def put(folder, rel, text):
    path = os.path.join(folder, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    release._put(path, text.encode("utf-8"))


def text(folder, rel):
    return release.read(os.path.join(folder, rel)).decode("utf-8")


def released(core):
    """Packages a development copy as a release next to it (stamped packs). -> (release DisasterZone folder, record)"""
    _N[0] += 1
    dst = os.path.join(TMP, "rel%d" % _N[0], release.ADDON_NAME)
    return dst, release.stage_tree(core, dst, lua_only=True, link=True)


def boot(addon_dir, sv=None, **kw):
    w = World(addon_dir=addon_dir)
    c = Client(w, "Alice", addon_dir=addon_dir, **kw)
    if sv is not None:
        c.set_saved_variable("DisasterZonePatchDB", sv)
    c.load_addon()
    w.tick(2)
    c.world = w
    return w, c


@case
def every_pack_loads_and_its_game_registers():
    w, c = solo()
    c.world = w
    assert c.eval_py("local o = {} for _, d in ipairs(ns.Games:GetList()) do o[#o + 1] = d.id end return o") == IDS
    assert states(c) == dict.fromkeys(IDS, "ok")
    assert sorted(c.eval_py("local o = {} for k in pairs(ns.packs) do o[#o + 1] = k end return o")) == \
        sorted(FOLDERS.values())
    assert c.eval("return ns.Notify:GetKind('chessTurn') ~= nil") is True     # (the Chess pack's own)
    no_errors(w)


@case
def in_the_clients_order_the_packs_start_after_the_addon():
    """The client runs a pack after DisasterZone's ADDON_LOADED: its modules start through ns:PackLoaded."""
    w, c = solo(pack_order="real")
    c.world = w
    assert states(c) == dict.fromkeys(IDS, "ok")
    assert c.eval("return ns.Games:Get('azeromon') ~= nil and ns.AzeroUI ~= nil and ns.Chess ~= nil") is True
    # their login stage ran too (Bingo watches the zone from OnLogin, Azeromon's presence from OnInit)
    assert c.eval("return ns.loggedIn") is True
    hub(c)
    assert c.eval("return #%s" % POSTERS) == 6 and not any(stub(c, g) for g in IDS)
    no_errors(w)


@case
def a_game_that_isnt_installed_gets_a_stand_in_poster():
    w, c = solo(packs=without("chess"))
    c.world = w
    assert c.eval("return ns.Chess == nil and ns.Games:Get('chess') == nil") is True
    assert c.eval("return ns.Games:PackState('chess')") == "missing"
    assert c.eval("return ns.Notify:GetKind('chessTurn') == nil") is True      # (not listed without Chess)
    hub(c)
    assert c.eval("return #%s" % POSTERS) == 6
    assert stub(c, "chess") and poster(c, "chess", "kicker") == "NOT INSTALLED"
    assert poster(c, "chess", "cta") == "HOW TO GET IT"
    assert not stub(c, "bingo")
    # in front, a click says how to get it (and gives the address to copy); nothing opens
    c.eval("ns.GamesUI:ShowFront('chess')")
    c.world.tick(0.6)
    c.eval("for _, p in ipairs(%s) do if p.id == 'chess' then p:Click() end end" % POSTERS)
    assert "DISASTERZONE_GAME_PACK" in c.popups()
    assert "isn't installed" in c.popup_text("DISASTERZONE_GAME_PACK")
    assert "DisasterZone_Chess" in c.popup_text("DISASTERZONE_GAME_PACK")
    assert c.eval("return ns.Popup:FindVisible('DISASTERZONE_GAME_PACK').editBox:GetText()") == \
        c.eval("return ns.Games.RELEASES")
    assert c.eval("return ns.GamesUI:GetSelected()") is None
    c.popup_button("DISASTERZONE_GAME_PACK", 1)
    # /dz play chess: the how-to, and the hub on its poster
    assert c.slash("/dz play chess")
    w.tick(0.6)
    assert c.eval("return ns.GamesUI:GetFront()") == "chess"
    no_errors(w)


@case
def no_games_at_all_still_shows_every_poster():
    w, c = solo(packs={})
    c.world = w
    hub(c)
    assert c.eval("return #%s" % POSTERS) == 6 and all(stub(c, g) for g in IDS)
    no_errors(w)


@case
def a_pack_switched_off_says_so():
    w, c = solo(packs_off={"DisasterZone_Bingo"})
    c.world = w
    assert c.eval("return ns.Bingo == nil") is True
    assert c.eval("return ns.Games:PackState('bingo')") == "off"
    hub(c)
    assert poster(c, "bingo", "kicker") == "SWITCHED OFF"
    assert "AddOn list" in c.eval("return ns.Games:HowToGet('bingo')")
    no_errors(w)


@case
def a_release_runs_its_own_packs_and_skips_one_from_another_release():
    core = tree_copy()
    rel, record = released(core)
    assert sorted(record["packs"]) == sorted(FOLDERS.values())
    build = text(rel, "Core/BuildInfo.lua")
    chess_toc = text(os.path.join(os.path.dirname(rel), "DisasterZone_Chess"), "DisasterZone_Chess.toc")
    stamp = [l for l in chess_toc.splitlines() if l.startswith("## X-DZ-Build:")][0].split(":", 1)[1].strip()
    assert stamp != "dev" and ('["DisasterZone_Chess"] = "%s"' % stamp) in build
    w, c = boot(rel)
    assert states(c) == dict.fromkeys(IDS, "ok")
    no_errors(w)
    # the member pasted an older Chess folder next to this release
    put(os.path.join(os.path.dirname(rel), "DisasterZone_Chess"), "DisasterZone_Chess.toc",
        chess_toc.replace(stamp, "0123456789abcdef"))
    w, c = boot(rel)
    assert c.eval("return DisasterZoneBoot.PackState('DisasterZone_Chess')") == "stale"
    assert c.eval("return ns.Chess == nil and ns.ChessUI == nil and ns.ChessRules == nil") is True   # (nothing ran)
    assert c.eval("return ns.Games:PackState('chess')") == "update"
    assert c.eval("return ns.Games:PackState('azeromon')") == "ok"
    hub(c)
    assert poster(c, "chess", "kicker") == "UPDATE NEEDED"
    no_errors(w)


@case
def an_update_reaches_a_packs_files_and_adds_one_at_its_end():
    base_core = tree_copy()
    base, record = released(base_core)

    def mods(root):
        chess = os.path.join(root, "DisasterZone_Chess")
        put(chess, "Chess.lua", text(chess, "Chess.lua") + '\nChess.PATCH_MARK = "p2"\n')
        put(chess, "TestTail.lua", release.guard_for("DisasterZone_Chess/TestTail.lua").decode()
            + "-- test\nlocal folder, ns = ...\n"
            "DisasterZoneTestTail = folder .. ':' .. tostring(ns.ChessUI ~= nil) .. ':' .. tostring(ns.Chess.PATCH_MARK)\n")
        toc = text(chess, "DisasterZone_Chess.toc")
        assert toc.count("\r\nDone.lua\r\n") == 1
        put(chess, "DisasterZone_Chess.toc", toc.replace("\r\nDone.lua\r\n", "\r\nTestTail.lua\r\nDone.lua\r\n"))
    new_core = tree_copy(mods)
    bundle, notes = release.make_patch(record, new_core, test_key(), 1)
    kinds = {i["path"]: (i["kind"], i.get("before") or "") for i in bundle["items"]}
    assert kinds == {"DisasterZone_Chess/Chess.lua": ("F", ""),
                     "DisasterZone_Chess/TestTail.lua": ("N", "")}, kinds    # (N, "": after the pack's last file)
    w, c = boot(base, sv=patchlib.staged_sv(bundle))
    assert c.eval("return DisasterZoneBoot.state") == "applied"
    assert c.eval("return ns.Chess.PATCH_MARK") == "p2"
    # the new file ran at the pack's end (after every Chess file, with the pack's own varargs)
    assert c.eval("return DisasterZoneTestTail") == "DisasterZone_Chess:true:p2"
    assert states(c) == dict.fromkeys(IDS, "ok")
    no_errors(w)


@case
def a_patch_cannot_carry_a_packs_art_or_its_first_and_last_files():
    base_core = tree_copy()
    base, record = released(base_core)

    def mods(root):
        chess = os.path.join(root, "DisasterZone_Chess")
        put(chess, "Load.lua", text(chess, "Load.lua") + "\n-- changed\n")
    new_core = tree_copy(mods)
    try:
        release.make_patch(record, new_core, test_key(), 1)
    except release.ReleaseError as e:
        assert "DisasterZone_Chess/Load.lua changed" in str(e), str(e)
    else:
        raise AssertionError("a patch carried a pack's Load.lua")


if __name__ == "__main__":
    run_all()
