"""Azeromon footsteps (0.47): WoW's own footstep files, mixed per ground and baked into the addon's own Ogg files.

The game can't change a sound's volume or pitch while it plays (PlaySoundFile has neither), so everything the
user picked on the footsteps audition page (dev/art/casc/steps_mockup, 2026-10-18) is baked here:

    body size small · level -18 dB · even out on · pitch spread +-6%
    tall grass: two grass layers · sand: snow crunch · shallows: splash · inn floor: wood, muffled
    rug: soft thud · cave floor: stone + grit

Each ground gets VARIANTS mixes (every source file used in turn, each layer at its own random pitch within the
spread), a wet set for the outdoor grounds in the rain, and the shallows a "stepping in" set with the
enter-water splash. Sources are read from the installed client (casc_local), so this runs on Windows only;
the files and StepsArt.lua it writes are committed.

Writes addon/DisasterZone_Azeromon/Media/Steps/<set>_<n>.ogg and StepsArt.lua.
Run: luaenv\\Scripts\\python.exe generators\\gen_azeromon_steps.py   (needs: pip install soundfile)
"""
import hashlib
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
PACK = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone_Azeromon")
OUT = os.path.join(PACK, "Media", "Steps")
LUA = os.path.join(PACK, "StepsArt.lua")
ASSET = 17
RATE = 22050                      # (every footstep file in the client is 22.05 kHz mono)
VARIANTS = 8                      # mixes per set
FS = "sound/character/footsteps/"

# set -> size -> (path stem, letters). Sizes: small, ml (medium-large; "medium" for the splashes), huge.
SOURCES = {
    "grass": {"small": (FS + "mfootsmallgrass", "abcde"), "ml": (FS + "mfootmediumlargegrass", "abcde")},
    "dirt": {"small": (FS + "mfootsmalldirt", "abcde")},
    "stone": {"small": (FS + "mfootsmallstone", "abcde")},
    "wood": {"small": (FS + "mfootsmallwood", "abcde")},
    "snow": {"small": (FS + "mfootsmallsnow", "abcde")},
    "mud": {"ml": (FS + "footstepsmediumlargemud", "abcde")},
    "water": {"small": (FS + "watersplash/footstepssmallwater", "abcde")},
    "enter": {"small": (FS + "enterwatersplash/enterwatersmall", "a")},
}

# The picks. A layer: (source set, size, dB, low-pass Hz or None, delay s).
LEVEL = -18.0                     # the step level against the world (the page's slider)
TARGET = 0.32                     # the evened-out loudness (the loudest 46 ms, RMS) before LEVEL
CALIBRATE = 0.6 / 0.75            # the page's bed played at 0.75; the game's Ambience channel defaults to 0.6
PITCH = 0.06                      # +-6%
GROUNDS = {
    "grass": [("grass", "small", 0, None, 0)],
    "tall": [("grass", "ml", 0, None, 0), ("grass", "small", -7, None, 0.06)],
    "road": [("dirt", "small", 0, None, 0)],
    "sand": [("snow", "small", -3, 6000, 0)],
    "dock": [("wood", "small", 0, None, 0)],
    "shallows": [("water", "small", 0, None, 0)],
    "floor": [("wood", "small", 0, 2800, 0)],
    "rug": [("dirt", "small", -6, 900, 0)],
    "hall": [("stone", "small", 0, None, 0)],
    "cave": [("stone", "small", 0, None, 0), ("dirt", "small", -9, None, 0.015)],
}
WET = {                           # in the rain, outdoors (sand turns to damp dirt)
    "grass": GROUNDS["grass"] + [("mud", "ml", -8, None, 0)],
    "tall": GROUNDS["tall"] + [("mud", "ml", -9, None, 0)],
    "road": GROUNDS["road"] + [("mud", "ml", -2, None, 0)],
    "sand": [("dirt", "small", 0, None, 0), ("mud", "ml", -8, None, 0)],
    "dock": GROUNDS["dock"] + [("water", "small", -14, None, 0)],
}
SETS = dict(GROUNDS)
SETS.update({k + "_wet": v for k, v in WET.items()})
SETS["shallows_in"] = GROUNDS["shallows"] + [("enter", "small", -3, None, 0)]
COUNT = {"shallows_in": 3}        # (one enter-water file: a few pitches are enough)


def digest():
    h = hashlib.sha1()
    h.update(open(__file__, "rb").read().replace(b"\r\n", b"\n"))
    return h.hexdigest()[:16]


def peak_rms(x):
    """The loudest 1024 samples (46 ms) as RMS, in hops of 256: a step's thump, not its tail (the page's peakRms)."""
    if len(x) < 1024:
        return float(np.sqrt(np.mean(x * x))) or 0.05
    sq = np.concatenate(([0.0], np.cumsum(x.astype(np.float64) ** 2)))
    starts = np.arange(0, len(x) - 1024 + 1, 256)
    return float(np.sqrt(np.max(sq[starts + 1024] - sq[starts]) / 1024)) or 0.05


def lowpass(x, hz, q=0.5):
    """RBJ biquad low-pass (as WebAudio's BiquadFilterNode on the page, Q 0.5)."""
    w0 = 2 * np.pi * hz / RATE
    alpha = np.sin(w0) / (2 * q)
    c = np.cos(w0)
    b0, b1, b2 = (1 - c) / 2, 1 - c, (1 - c) / 2
    a0, a1, a2 = 1 + alpha, -2 * c, 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(x):
        o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, o
        y[i] = o
    return y


def repitch(x, rate):
    """Played back `rate` times as fast (higher and shorter), linear interpolation (as playbackRate)."""
    n = max(1, int(round(len(x) / rate)))
    return np.interp(np.arange(n) * rate, np.arange(len(x)), x).astype(np.float32)


def load_sources():
    import io
    import soundfile as sf
    sys.path.insert(0, HERE)
    import casc_local as C
    out = {}
    for name, sizes in SOURCES.items():
        for size, (stem, letters) in sizes.items():
            files = []
            for l in letters:
                path = stem + l + ".ogg"
                fid = C.fdid_of(path)
                if not fid:
                    raise SystemExit("not in this client: " + path)
                data, rate = sf.read(io.BytesIO(C.read_fid(fid)), dtype="float32")
                assert rate == RATE and data.ndim == 1, (path, rate, data.shape)
                files.append((data, peak_rms(data)))
            out[(name, size)] = files
    return out


def mix(layers, src, rng, turn):
    parts = []
    for li, (name, size, db, lp, delay) in enumerate(layers):
        files = src[(name, size)]
        data, rms = files[(turn + li * 2) % len(files)]          # every file in turn; layers out of step
        x = data.astype(np.float64) * min(6.0, TARGET / rms) * 10 ** ((db + LEVEL) / 20) * CALIBRATE
        x = repitch(x, 1 + rng.uniform(-PITCH, PITCH))
        if lp:
            x = lowpass(x, lp)
        parts.append((int(round(delay * RATE)), x))
    n = max(off + len(x) for off, x in parts)
    out = np.zeros(n)
    for off, x in parts:
        out[off:off + len(x)] += x
    # trim the silent tail (below -60 dB) and fade the last 10 ms
    loud = np.flatnonzero(np.abs(out) > 0.001)
    out = out[:(loud[-1] + 1 if len(loud) else 1)]
    f = min(len(out), int(RATE * 0.01))
    out[len(out) - f:] *= np.linspace(1, 0, f)
    return np.clip(out, -1, 1).astype(np.float32)


def main():
    import soundfile as sf
    src = load_sources()
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".ogg"):
            os.remove(os.path.join(OUT, f))
    counts, total = {}, 0
    for name in sorted(SETS):
        rng = np.random.default_rng(int(hashlib.sha1(name.encode()).hexdigest()[:8], 16))
        n = COUNT.get(name, VARIANTS)
        for i in range(n):
            out = mix(SETS[name], src, rng, i)
            path = os.path.join(OUT, "%s_%d.ogg" % (name, i + 1))
            sf.write(path, out, RATE, format="OGG", subtype="VORBIS")
            total += os.path.getsize(path)
        counts[name] = n
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/StepsArt.lua", ...) then return end '
        '-- DisasterZone_Azeromon/StepsArt.lua  (GENERATED by dev/generators/gen_azeromon_steps.py - do not edit)',
        "-- Footsteps (Steps.lua): set -> how many mixes Media/Steps/<set>_<n>.ogg has. A ground's set, <ground>_wet in",
        "-- the rain outdoors, shallows_in for the first step into the shallows.",
        "local addonName, ns = ...",
        "ns.AzeroStepsArt = {",
        '    asset = %d, src = "%s",' % (ASSET, digest()),
        "    sets = {",
    ]
    for name in sorted(counts):
        lines.append("        %s = %d," % (name, counts[name]))
    lines += ["    },", "}", ""]
    open(LUA, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    print("%d files, %.0f KB -> %s" % (sum(counts.values()), total / 1024, OUT))


if __name__ == "__main__":
    main()
