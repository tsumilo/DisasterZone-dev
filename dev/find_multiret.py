"""List tonumber(<call>) sites in DisasterZone where the argument is an unparenthesised function call.

A Lua function returning multiple values passes its 2nd value as tonumber's `base` argument
(e.g. GetInventoryItemID returns itemID, <number>) -> "bad argument #2 to 'tonumber' (base out of range)".
"""
import glob
import os
import re
import sys

ADDON = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
BS = chr(92)


def scan_arg(src, i):
    depth, j = 1, i
    while j < len(src) and depth:
        c = src[j]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c in "\"'":
            q = c
            j += 1
            while j < len(src) and src[j] != q:
                if src[j] == BS:
                    j += 1
                j += 1
        j += 1
    return src[i:j - 1].strip()


def fully_wrapped(arg):
    if not (arg.startswith("(") and arg.endswith(")")):
        return False
    d = 0
    for k, c in enumerate(arg):
        if c == "(":
            d += 1
        elif c == ")":
            d -= 1
            if d == 0 and k != len(arg) - 1:
                return False
    return True


def has_top_comma(arg):
    d = 0
    for c in arg:
        if c in "([{":
            d += 1
        elif c in ")]}":
            d -= 1
        elif c == "," and d == 0:
            return True
    return False


def main():
    files = sorted(glob.glob(os.path.join(ADDON, "Core", "*.lua")) + glob.glob(os.path.join(ADDON, "UI", "*.lua")))
    out = []
    for f in files:
        src = open(f, encoding="utf-8").read()
        for m in re.finditer(r"\btonumber\s*\(", src):
            arg = scan_arg(src, m.end())
            if has_top_comma(arg) or fully_wrapped(arg) or not arg.endswith(")"):
                continue
            line = src.count("\n", 0, m.start()) + 1
            out.append("%s:%d: tonumber(%s)" % (os.path.relpath(f, ADDON), line, arg[:120].replace("\n", " ")))
    print(len(out), "sites")
    print("\n".join(out))


if __name__ == "__main__":
    sys.exit(main())
