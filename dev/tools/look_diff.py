"""Before/after comparison of ui_audit --look renders (refactor 1.4).

usage: python look_diff.py <baseline dir> <new dir> <out dir> [-k "View|Other view"]

For every PNG in both folders: the share of changed pixels and the mean change. Writes <out>/diff.md (worst first)
and, for every view that changed, <out>/<view>.jpg: baseline | new | changed pixels in red. Views that exist on
one side only are listed too. Open the JPGs to judge whether a change is the intended unification or a regression
(missing text, overlap, empty area, clipped content, wrong colour).
"""
import os
import sys

from PIL import Image, ImageChops


def main():
    args = sys.argv[1:]
    only = None
    if "-k" in args:
        i = args.index("-k")
        only = args[i + 1].split("|")
        del args[i:i + 2]
    base, new, out = args[:3]
    os.makedirs(out, exist_ok=True)
    names = sorted(set(os.listdir(base)) | set(os.listdir(new)))
    names = [n for n in names if n.endswith(".png") and (not only or any(o.replace(" ", "_") in n for o in only))]
    rows, missing = [], []
    for n in names:
        a, b = os.path.join(base, n), os.path.join(new, n)
        if not os.path.exists(a) or not os.path.exists(b):
            missing.append((n, "baseline only" if os.path.exists(a) else "new only"))
            continue
        ia, ib = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
        if ia.size != ib.size:
            w, h = max(ia.size[0], ib.size[0]), max(ia.size[1], ib.size[1])
            pa, pb = Image.new("RGB", (w, h)), Image.new("RGB", (w, h))
            pa.paste(ia, (0, 0)); pb.paste(ib, (0, 0)); ia, ib = pa, pb
        d = ImageChops.difference(ia, ib).convert("L")
        hist = d.histogram()
        total = sum(hist)
        changed = sum(hist[25:]) / total
        mean = sum(i * c for i, c in enumerate(hist)) / total / 2.55
        rows.append((changed, mean, n))
        if changed > 0.0005:
            mask = d.point(lambda v: 255 if v >= 25 else 0)
            red = Image.new("RGB", ia.size, (255, 40, 40))
            heat = Image.composite(red, ib.point(lambda v: v // 3), mask)
            w, h = ia.size
            sheet = Image.new("RGB", (w * 3 + 20, h), (40, 40, 40))
            sheet.paste(ia, (0, 0)); sheet.paste(ib, (w + 10, 0)); sheet.paste(heat, (2 * w + 20, 0))
            sheet.thumbnail((2400, 1200))
            sheet.save(os.path.join(out, n[:-4] + ".jpg"), quality=80)
    rows.sort(reverse=True)
    with open(os.path.join(out, "diff.md"), "w", encoding="utf-8") as f:
        f.write("# Look diff: %s -> %s\n\n| changed px | mean change | view |\n|---|---|---|\n" % (base, new))
        for changed, mean, n in rows:
            f.write("| %.2f%% | %.2f | %s |\n" % (changed * 100, mean, n[:-4]))
        if missing:
            f.write("\n## On one side only\n\n")
            for n, side in missing:
                f.write("- %s (%s)\n" % (n[:-4], side))
    changed_n = sum(1 for r in rows if r[0] > 0.0005)
    print("%d views compared, %d changed, %d on one side only -> %s" % (len(rows), changed_n, len(missing),
                                                                          os.path.join(out, "diff.md")))


if __name__ == "__main__":
    main()
