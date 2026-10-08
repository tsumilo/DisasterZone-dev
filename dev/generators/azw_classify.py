"""Azeromon world: what the real ground textures and doodad models become on the tile map.

GROUND: texture FileDataID -> ground class (one char, see CLASSES). A texture can depend on the slope: Elwynn's pale
stone (187138) is the road on flat ground and the cliff face on steep ground. Unknown textures fall back to the
class whose average colour is nearest (printed by the generator so they can be added here).

DOODADS: model name (the M2's own name) -> kind, by the first matching rule. Kinds:
    tree    trunk solid, a crown drawn above the player (size from the model's box)
    stump / log / rock / prop    solid where the model stands (its box, turned)
    fence   a line of fence tiles along the model's long side, solid
    deco    walkable decoration (bushes, plants, flowers)
    skip    effects and small clutter that do not read at this scale
"""
import re

# ground classes: char -> (name, walkable, colour for previews)
CLASSES = {
    ".": ("grass", True, (112, 160, 52)),
    ",": ("darkgrass", True, (78, 124, 40)),
    "*": ("flowers", True, (140, 170, 60)),
    "=": ("road", True, (196, 184, 150)),
    ":": ("dirt", True, (150, 116, 70)),
    "+": ("cobble", True, (150, 150, 150)),
    "%": ("crops", True, (120, 96, 52)),
    "^": ("rocky", True, (128, 120, 104)),
    "#": ("cliff", False, (88, 80, 70)),
    "~": ("shallow", True, (98, 150, 210)),
    "w": ("water", False, (52, 96, 186)),
    "s": ("sand", True, (214, 196, 140)),
    "X": ("void", False, (0, 0, 0)),
}

CLIFF_SLOPE = 50.0          # WoW's walkable limit (degrees)
ROCKY_SLOPE = 30.0          # rock / dirt textures steeper than this read as rocky slopes
DEEP_WATER = 1.6            # yd of water a human can wade (deeper: swimming = blocked without a boat)

# texture -> (flat class, steep class). Elwynn tileset (the 7 textures of Northshire + the rest of Elwynn).
TEXTURES = {
    187127: (".", "^"),      # ElwynnGrass (light) - most of the valley floor
    186770: (",", "^"),      # dark forest grass
    187125: ("*", "^"),      # grass with yellow flowers
    187088: (",", "^"),      # deep green grass
    187086: (",", "^"),
    187138: ("=", "#"),      # pale stone: the roads on flat ground, cliff faces on steep ground
    187115: (":", "^"),      # brown dirt (paths, slopes)
    187100: ("+", "+"),      # cobblestones (abbey courtyard)
    187112: ("%", "%"),      # crop rows (Northshire Vineyards, farms)
    188749: ("%", "%"),
    187082: (",", "^"),      # mossy dark earth
    187094: ("^", "#"),      # grey rock
    187098: ("^", "#"),      # gravel rock
    187074: ("+", "+"),      # big cobbles
    186934: ("^", "#"),      # grey cliff rock
}


def ground_class(tex, slope, fallback):
    """The class char for a tile from its main texture and slope; fallback(tex) for unknown textures."""
    flat, steep = TEXTURES.get(tex) or fallback(tex)
    if slope >= CLIFF_SLOPE:
        return "#"
    if slope >= ROCKY_SLOPE and flat in ("^", "="):
        return steep if steep == "^" else "^"      # bare rock / the pale stone on a slope: rocky ground
    return flat                                    # grass and dirt stay what they are on a slope (the shading shows it)


# (pattern on the lower-cased model name, kind, tile) - first match wins
DOODAD_RULES = [
    (r"butterfl|bird|flies|insect|firefl|smoke|particle|ember|bubble|vent|waterfall|fountain|steam", "skip", None),
    (r"lilypad|lillypad|seaweed", "skip", None),
    (r"stump", "stump", "stump"),
    (r"fallentree|log0", "log", "log"),
    (r"canopyless|tree|pine", "tree", None),
    (r"bush|plant|grass|catail|cattail|reed|fern|mushroom", "deco", "bush"),
    (r"pumpkinpatch|pumpkin", "deco", "pumpkin"),
    (r"melon|cabbage", "deco", "cabbage"),
    (r"vineyard|trellis", "prop", "vines"),
    (r"fencepost|woodpost|fenceend|stonefencepost", "fence", "fence"),
    (r"fence", "fence", "fence"),
    (r"cliffrock|rock|boulder", "rock", "rock"),
    (r"tombstonemonument|tombstone|gravestone|graveframe|woodcross", "prop", "gravestone"),
    (r"lamppost|streetlamp", "prop", "lamppost"),
    (r"torch|brazier|lantern", "prop", "torch"),
    (r"signpost|dangersign", "prop", "sign"),
    (r"haystack|haypile|haywagon", "prop", "hay"),
    (r"barrel|keg", "prop", "barrel"),
    (r"crate|cargobox|box", "prop", "crate"),
    (r"sack|grainsac", "prop", "sack"),
    (r"lumber|firewood|plank", "prop", "lumber"),
    (r"wagon|cart|hearse|wheelbarrow|minecar", "prop", "cart"),
    (r"well$|^well|waterbasin|basin", "prop", "well"),
    (r"anvil|grindstone|sharpening", "prop", "anvil"),
    (r"dummy|archerytarget", "prop", "dummy"),
    (r"weaponrack|toolrack", "prop", "rack"),
    (r"scarecrow", "prop", "scarecrow"),
    (r"tent", "prop", "tent"),
    (r"outhouse|shed|doghouse", "prop", "shed"),
    (r"statue|bust", "prop", "statue"),
    (r"banner|flagpole", "prop", "banner"),
    (r"awning", "prop", "awning"),
    (r"pyre|campfire|bonfire|firepit", "prop", "campfire"),
    (r"plow|harness|churn|bellows", "prop", "tools"),
    (r"jar|jug|bucket|coil|pick$|shovel|bottle|bowl|plate|stein|goblet|candle|book|skull|bone|meat|"
     r"sword|shield|helm|bracer|spear|ladle|pillow|chair|table|bench|stake|skeleton|corpse|body|ash", "skip", None),
]


def doodad_kind(name):
    n = (name or "").lower()
    for pat, kind, tile in DOODAD_RULES:
        if re.search(pat, n):
            return kind, tile
    return None, None
