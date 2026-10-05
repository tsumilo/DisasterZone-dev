"""The rooms generator's game-file reads (dev/generators/gen_rooms.py on casc_local.py): the installed client first.

Covers: a file comes from the installed client and is cached per build (dev/art/casc/files/<build>/<id>.bin, here in
a temp folder); a map file (WMO root or group, WDT, ADT) the client lacks fails the room instead of taking
wago.tools' copy, which may be of another build (the Karazhan mix-up of 1.3.0), and nothing is downloaded; with
--allow-wago the copy is taken, logged, and listed after the room's line; other files (creature models) still fall
back, logged; run_one reports a failed room (no index entry) and resets the flag per room; a path finds its ID in the
client's own name table, and a path the client lacks is None without a wago.tools search.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_gen_rooms_local.py [-k name]
Needs the installed client (C:\\World of Warcraft, product wow_anniversary); without it every case is skipped.
"""
import contextlib
import io
import os
import shutil
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
for p in (os.path.join(DEV, "generators"), os.path.join(DEV, "tools")):
    if p not in sys.path:
        sys.path.insert(0, p)

import casc_local  # noqa: E402
import gen_rooms as R  # noqa: E402

HELLFIRE_WDT = "world/maps/hellfireraid/hellfireraid.wdt"
HELLFIRE_WDT_ID = 833183        # (Magtheridon's Lair: its WDT holds the room's one global WMO)
_CASES = []
TMP = tempfile.mkdtemp(prefix="dz_rooms_")


def case(fn):
    _CASES.append(fn)
    return fn


@contextlib.contextmanager
def patched(*triples):
    """(object, attribute, value) set for the block, then put back; the generator's per-run state reset round it."""
    old = [(o, a, getattr(o, a)) for o, a, _ in triples]
    state = (list(R._LOCAL), dict(R._FELL_BACK), list(R._ALLOW_WAGO), list(R._WAGO_USED))
    try:
        for o, a, v in triples:
            setattr(o, a, v)
        yield
    finally:
        for o, a, v in old:
            setattr(o, a, v)
        R._LOCAL[:], R._ALLOW_WAGO[:], R._WAGO_USED[:] = state[0], state[2], state[3]
        R._FELL_BACK.clear()
        R._FELL_BACK.update(state[1])


def folder(name):
    path = os.path.join(TMP, name)
    os.makedirs(path, exist_ok=True)
    return path


def no_download(url, path):
    raise AssertionError("downloaded %s" % url)


def missing(fid):
    raise KeyError("not on this disk (test)")


@case
def a_file_comes_from_the_client_cached_per_build():
    cache = folder("local1")
    with patched((R, "LOCAL_CACHE", cache), (R, "_get", no_download)):
        build = R.local_build()
        assert build == casc_local.build_name(), build
        path = R.casc(HELLFIRE_WDT_ID)
        assert os.path.normcase(path) == os.path.normcase(os.path.join(cache, build, "%d.bin" % HELLFIRE_WDT_ID)), path
        with open(path, "rb") as fh:
            assert fh.read() == casc_local.read_fid(HELLFIRE_WDT_ID)
        assert R.map_file(HELLFIRE_WDT_ID) == path                      # (cached: the same file again)
        assert not R._WAGO_USED and HELLFIRE_WDT_ID not in R._FELL_BACK
        # another build's files go to a folder of their own (a patch changes them)
        R._LOCAL[:] = ["0.0.0.test"]
        other = R.local_file(HELLFIRE_WDT_ID)
        assert os.path.normcase(other) == os.path.normcase(os.path.join(cache, "0.0.0.test", "%d.bin" % HELLFIRE_WDT_ID))


@case
def a_map_file_the_client_lacks_fails_the_room():
    cache, wago = folder("local2"), folder("wago2")
    with open(os.path.join(wago, "%d.wmo" % HELLFIRE_WDT_ID), "wb") as fh:
        fh.write(b"REVM another build")
    with patched((R, "LOCAL_CACHE", cache), (R, "WMO_CACHE", wago), (R, "CACHE", wago), (R, "_get", no_download),
                 (casc_local, "read_fid", missing)):
        R.local_build()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            try:
                R.map_file(HELLFIRE_WDT_ID)
            except SystemExit as ex:
                msg = str(ex)
            else:
                raise AssertionError("took a file the client does not have")
        assert "map file %d is not in the installed client" % HELLFIRE_WDT_ID in msg and "--allow-wago" in msg, msg
        assert "not on this disk (test)" in msg, msg                     # (why the client could not give it)
        assert not R._WAGO_USED, R._WAGO_USED
        assert not os.listdir(cache), os.listdir(cache)                  # (nothing cached for the build)


@case
def allow_wago_takes_the_copy_and_logs_it():
    cache, wago = folder("local3"), folder("wago3")
    copy = os.path.join(wago, "%d.wmo" % HELLFIRE_WDT_ID)
    with open(copy, "wb") as fh:
        fh.write(b"REVM another build")
    with patched((R, "LOCAL_CACHE", cache), (R, "WMO_CACHE", wago), (R, "CACHE", wago), (R, "_get", no_download),
                 (casc_local, "read_fid", missing)):
        R.local_build()
        R._ALLOW_WAGO[0] = True
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            path = R.map_file(HELLFIRE_WDT_ID)
        assert path == copy, path
        assert "file %d not in the installed client (not on this disk (test)): wago.tools' copy" % HELLFIRE_WDT_ID \
            in out.getvalue(), out.getvalue()
        assert R._WAGO_USED == [HELLFIRE_WDT_ID], R._WAGO_USED


@case
def other_files_still_fall_back_logged():
    cache, wago = folder("local4"), folder("wago4")
    copy = os.path.join(wago, "123456.bin")
    with open(copy, "wb") as fh:
        fh.write(b"MD21 a creature")
    with patched((R, "LOCAL_CACHE", cache), (R, "WMO_CACHE", wago), (R, "CACHE", wago), (R, "_get", no_download),
                 (casc_local, "read_fid", missing)):
        R.local_build()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            assert R.casc(123456) == copy                                # (no --allow-wago needed: not a map file)
        assert "file 123456 not in the installed client" in out.getvalue(), out.getvalue()
        assert R._WAGO_USED == [123456], R._WAGO_USED


@case
def run_one_reports_a_failed_room_and_the_files_it_took():
    cache, wago = folder("local5"), folder("wago5")
    with open(os.path.join(wago, "%d.wmo" % HELLFIRE_WDT_ID), "wb") as fh:
        fh.write(b"REVM another build")

    def fake_room(ref):
        R.map_file(HELLFIRE_WDT_ID)
        return ref, {"floor": "Test"}, "Test:Room built"
    with patched((R, "LOCAL_CACHE", cache), (R, "WMO_CACHE", wago), (R, "CACHE", wago), (R, "_get", no_download),
                 (casc_local, "read_fid", missing), (R, "_run_one", fake_room)):
        R.local_build()
        with contextlib.redirect_stdout(io.StringIO()):
            ref, e, msg = R.run_one("Test:Room")
            assert e is None and msg.startswith("FAILED: map file %d" % HELLFIRE_WDT_ID), msg
            ref, e, msg = R.run_one("Test:Room", True)
            assert e == {"floor": "Test"}, e
            assert msg == "Test:Room built\n    1 files from wago.tools: %d" % HELLFIRE_WDT_ID, msg
            ref, e, msg = R.run_one("Test:Room")                         # (the flag is the room's own)
            assert e is None and msg.startswith("FAILED"), msg


@case
def a_path_finds_its_id_in_the_clients_names():
    with patched((R, "_get", no_download)):
        R.local_build()
        assert R.fdid_of(HELLFIRE_WDT) == HELLFIRE_WDT_ID, R.fdid_of(HELLFIRE_WDT)
        assert R.fdid_of(HELLFIRE_WDT.upper().replace("/", "\\")) == HELLFIRE_WDT_ID     # (the client's own spelling)
        # a tile the client does not have: None, not another build's ID from the wago.tools search
        assert R.fdid_of("world/maps/hellfireraid/hellfireraid_0_0_obj0.adt") is None


def run_all(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    flt = argv[argv.index("-k") + 1] if "-k" in argv else None
    if not os.path.exists(os.path.join(casc_local.BASE, ".build.info")):
        print("SKIP every case: no installed client at %s" % casc_local.BASE)
        print("-- gen_rooms local reads: 0 case(s), 0 passed, 0 failed (skipped)")
        return 0
    failed, passed, t_all = [], 0, time.time()
    try:
        for fn in _CASES:
            if flt and flt not in fn.__name__:
                continue
            t0 = time.time()
            try:
                fn()
            except Exception as e:  # noqa: BLE001 - report every failure, keep going
                failed.append(fn.__name__)
                print("FAIL %s (%.2fs)" % (fn.__name__, time.time() - t0))
                msg = "".join(traceback.format_exception(type(e), e, e.__traceback__))
                print("    " + msg.replace("\n", "\n    ").rstrip())
            else:
                passed += 1
                print("PASS %s (%.2fs)" % (fn.__name__, time.time() - t0))
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    print("-- gen_rooms local reads: %d case(s), %d passed, %d failed (%.1fs)" % (
        passed + len(failed), passed, len(failed), time.time() - t_all))
    if failed:
        print("-- failed: " + ", ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(run_all())
