"""Textures for Edit layout (UI/EditMode.lua): the dashed outline of a frame that isn't picked.
  Media/Edit/dash_h.tga   8 x 8, white: columns 0-3 solid, 4-7 clear; tiles left to right (REPEAT) along a top or
                          bottom edge, its tex coords scaled to the edge's length
  Media/Edit/dash_v.tga   the same turned: rows 0-3 solid, 4-7 clear; tiles top to bottom along a side
White everywhere (the clear texels too), so the edge takes its colour from SetVertexColor and filtering never darkens
a dash's ends.
Run (from dev): luaenv\\Scripts\\python.exe generators\\gen_edit_media.py"""
from pathlib import Path

from PIL import Image

ADDON = Path(__file__).resolve().parents[2] / "addon" / "DisasterZone"
OUT = ADDON / "Media" / "Edit"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    h = Image.new("RGBA", (8, 8), (255, 255, 255, 0))
    for x in range(4):
        for y in range(8):
            h.putpixel((x, y), (255, 255, 255, 255))
    h.save(OUT / "dash_h.tga")
    h.transpose(Image.Transpose.TRANSPOSE).save(OUT / "dash_v.tga")
    print("wrote", OUT / "dash_h.tga", OUT / "dash_v.tga")


if __name__ == "__main__":
    main()
