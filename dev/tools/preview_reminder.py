"""Renders the encounter reminder panel (UI/StrategyReminder.lua) offline into a PNG, from the addon's own Items()
during a practice run of a starter strategy (approximation: a Windows font instead of WoW's, grey squares for icons).
Usage: luaenv\\Scripts\\python.exe tools\\preview_reminder.py [BossRef] [seconds into the practice] [out.png]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
for sub in ("strategy", "raidplan", "boot-ui", "loot-roll"):
    sys.path.insert(0, os.path.join(DEV, "tests", sub))

from PIL import Image, ImageDraw, ImageFont  # noqa: E402
from _common import World, Client  # noqa: E402

FONT = "C:/Windows/Fonts/segoeui.ttf"
BOLD = "C:/Windows/Fonts/segoeuib.ttf"
W, PAD, ROW, CHIP = 270, 8, 20, 16
S = 2   # render scale


def parse(text):
    """|cffRRGGBB...|r and |T...|t -> [(text, (r,g,b))]"""
    out, color = [], (255, 255, 255)
    pos = 0
    text = re.sub(r"\|T[^|]*ReadyCheck-Ready[^|]*\|t", "\u2714", text or "")
    text = re.sub(r"\|T[^|]*ReadyCheck-NotReady[^|]*\|t", "\u2716", text)
    text = re.sub(r"\|T[^|]*ReadyCheck-Waiting[^|]*\|t", "\u2026", text)
    for m in re.finditer(r"\|c([0-9a-fA-F]{8})|\|r", text):
        if m.start() > pos:
            out.append((text[pos:m.start()], color))
        color = tuple(int(m.group(1)[i:i + 2], 16) for i in (2, 4, 6)) if m.group(1) else (255, 255, 255)
        pos = m.end()
    if pos < len(text):
        out.append((text[pos:], color))
    return out


def draw_text(dr, x, y, text, font, default=(255, 255, 255), right=False):
    parts = parse(text)
    total = sum(dr.textlength(t, font=font) for t, _ in parts)
    if right:
        x -= total
    for t, col in parts:
        dr.text((x, y), t, font=font, fill=col if col != (255, 255, 255) else default)
        x += dr.textlength(t, font=font)
    return total


def main():
    boss = sys.argv[1] if len(sys.argv) > 1 else "BlackTemple:Council"
    at = float(sys.argv[2]) if len(sys.argv) > 2 else 6.2
    out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(DEV, "art", "preview_reminder.png")
    w = World()
    bob = Client(w, "Bob", guild_rank=0, class_file="ROGUE")
    bob.load_addon()
    w.tick(3)
    bob.eval("ns.StrategyBoard:NewFromStarter(...); ns.StrategyBoard:Save(); ns.StrategyBoard:Close()", boss)
    w.tick(1)
    bob.eval("local s = ns.Strategy:GetStrategies(...)[1]; ns.StrategyPractice:Start(s)", boss)
    w.tick(at, step=0.1)
    d = bob.eval_py("return ns.StrategyReminder:Items()")
    items = list(d["items"].values()) if isinstance(d["items"], dict) else d["items"]

    f = ImageFont.truetype(FONT, 12 * S)
    fs = ImageFont.truetype(FONT, 10 * S)
    fb = ImageFont.truetype(BOLD, 12 * S)
    # height
    y = PAD + 32
    for it in items:
        if it["kind"] == "header":
            y += 18
        elif it["kind"] == "rot":
            y += ROW + CHIP + 4 + 2
        elif it.get("sub") or it.get("detail"):
            y += ROW + 8 + 2
        else:
            y += ROW + 2
    H = y + PAD - 2
    img = Image.new("RGBA", ((W + 40) * S, (H + 40) * S), (70, 64, 58, 255))
    dr = ImageDraw.Draw(img, "RGBA")
    ox, oy = 20 * S, 20 * S
    alert = any(it.get("alert") and not it.get("overview") for it in items)
    dr.rounded_rectangle([ox, oy, ox + W * S, oy + H * S], radius=5 * S, fill=(10, 10, 13, 215),
                         outline=(255, 70, 50, 255) if alert else (110, 110, 110, 255), width=2 * S)
    # header
    hx, hy = ox + PAD * S, oy + (PAD - 2) * S
    dr.ellipse([hx - 2 * S, hy + 1 * S, hx + 20 * S, hy + 23 * S], fill=(90, 60, 40), outline=(200, 170, 90), width=S)
    draw_text(dr, hx + 26 * S, hy + 4 * S, d["title"], fb, (255, 209, 0))
    tag = "PRACTICE" if d.get("practice") else d["state"].upper()
    tw = dr.textlength(tag, font=fs) + 10 * S
    tcol = {"PRACTICE": (255, 153, 38), "ENGAGED": (64, 217, 90), "NEXT": (140, 140, 140)}.get(tag, (140, 140, 140))
    dr.rectangle([ox + (W - PAD) * S - tw, hy + 5 * S, ox + (W - PAD) * S, hy + 19 * S], fill=tcol + (90,))
    dr.text((ox + (W - PAD) * S - tw + 5 * S, hy + 5 * S), tag, font=fs, fill=(255, 255, 255))
    dr.line([ox + PAD * S, oy + (PAD + 26) * S, ox + (W - PAD) * S, oy + (PAD + 26) * S], fill=(255, 255, 255, 30), width=S)
    y = oy + (PAD + 32) * S
    x0, x1 = ox + PAD * S, ox + (W - PAD) * S
    for it in items:
        if it["kind"] == "header":
            dr.line([x0, y, x1, y], fill=(255, 255, 255, 25), width=S)
            dr.text((x0, y + 2 * S), it["text"], font=fs, fill=(255, 209, 0))
            y += 18 * S
            continue
        h = ROW
        if it["kind"] == "rot":
            h = ROW + CHIP + 4
        elif it.get("sub") or it.get("detail"):
            h = ROW + 8
        if it.get("alert"):
            dr.rectangle([x0, y, x1, y + h * S], fill=(230, 38, 25, 64))
        elif it.get("myTurn"):
            dr.rectangle([x0, y, x1, y + h * S], fill=(50, 230, 75, 30))
        dr.rectangle([x0, y + 2 * S, x0 + 16 * S, y + 18 * S], fill=(120, 110, 90), outline=(40, 40, 40))
        font = fs if it.get("overview") else f
        ty = y + (0 if (it.get("sub") or it.get("detail")) else 3) * S
        draw_text(dr, x0 + 22 * S, ty, it["text"], font)
        if it.get("status"):
            draw_text(dr, x1 - 2 * S, y + 4 * S, it["status"], fs, right=True)
        if it.get("sub"):
            dr.text((x0 + 22 * S, y + 15 * S), it["sub"], font=fs, fill=(140, 140, 140))
        if it.get("detail"):
            draw_text(dr, x0 + 22 * S, y + 15 * S, it["detail"], fs, (170, 170, 170))
        if it["kind"] == "rot":
            cx = x0 + 22 * S
            chips = list(it["chips"].values()) if isinstance(it["chips"], dict) else it["chips"]
            for ch in chips:
                t = re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", ch["text"])
                wch = dr.textlength(t, font=fs) + 12 * S
                fill = (255, 209, 0, 140 if it.get("alert") else 77) if ch.get("current") else (255, 255, 255, 16)
                dr.rectangle([cx, y + ROW * S, cx + wch, y + (ROW + CHIP) * S], fill=fill)
                draw_text(dr, cx + 6 * S, y + (ROW + 1) * S, ch["text"], fs)
                cx += wch + 4 * S
        y += (h + 2) * S
    img = img.resize(((W + 40) * 2, (H + 40) * 2), Image.LANCZOS)
    img.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
