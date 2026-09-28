"""Every addon message type is registered by exactly one module (Comm:Register replaces an earlier handler, so a
reused type silently breaks one of the two features: the raid log's first sync types collided with the roll's RW).

Run: luaenv\\Scripts\\python.exe tests\\conformance\\test_comm_types.py
"""
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "addon", "CDLoot")
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all  # noqa: E402

REGISTER = re.compile(r'Comm:Register\(\s*"([A-Za-z]+)"')


def registrations():
    out = defaultdict(list)
    for sub in ("Core", "UI"):
        for fn in sorted(os.listdir(os.path.join(ADDON, sub))):
            if fn.endswith(".lua"):
                path = os.path.join(ADDON, sub, fn)
                with open(path, encoding="utf-8") as f:
                    for n, line in enumerate(f, 1):
                        for t in REGISTER.findall(line):
                            out[t].append("%s/%s:%d" % (sub, fn, n))
    return out


@case
def every_message_type_has_one_owner():
    regs = registrations()
    assert len(regs) > 20, regs   # the scan found the registrations
    dup = {t: where for t, where in regs.items() if len(where) > 1}
    assert not dup, dup


if __name__ == "__main__":
    run_all()
