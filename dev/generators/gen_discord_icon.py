"""Draws Media/Icons/Discord.tga: the small badge after the name of a player who made their character in Discord
(Core/Bridge.lua, UI:DiscordTag). A blurple rounded square with a white face (two eyes, a smile), 64x64, drawn at 4x
and scaled down for smooth edges. Run: luaenv\\Scripts\\python.exe generators\\gen_discord_icon.py
"""
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Media", "Icons", "Discord.tga")

S = 4                       # supersampling
N = 64 * S
BLURPLE = (88, 101, 242, 255)
WHITE = (255, 255, 255, 255)


def main():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, N - 1, N - 1], radius=16 * S, fill=BLURPLE)
    # the face: a wide rounded body with two short "ears" at the top corners
    d.rounded_rectangle([13 * S, 19 * S, 51 * S, 46 * S], radius=11 * S, fill=WHITE)
    d.polygon([(15 * S, 24 * S), (20 * S, 15 * S), (27 * S, 18 * S)], fill=WHITE)
    d.polygon([(49 * S, 24 * S), (44 * S, 15 * S), (37 * S, 18 * S)], fill=WHITE)
    d.polygon([(14 * S, 40 * S), (12 * S, 49 * S), (22 * S, 44 * S)], fill=WHITE)
    d.polygon([(50 * S, 40 * S), (52 * S, 49 * S), (42 * S, 44 * S)], fill=WHITE)
    # eyes
    d.ellipse([22 * S, 28 * S, 29 * S, 36 * S], fill=BLURPLE)
    d.ellipse([35 * S, 28 * S, 42 * S, 36 * S], fill=BLURPLE)
    out = img.resize((64, 64), Image.LANCZOS)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    out.save(OUT)
    print("wrote", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
