#!/usr/bin/env python
"""UI audit: finds text that does not fit, overlaps something or leaves its window, in every DisasterZone view.

It boots the addon in the harness (wowmock) with a guild full of realistic data, opens every view one by one (STATES)
and for each one reads what the mock recorded about every shown region: anchors, sizes, scales, texts, font objects,
word wrap, scroll boxes. The rectangles are worked out the way the client does it (two edges, or one edge / the
centre plus the size), with one addition the mock lacks: a FontString without a width takes the width of its text,
measured with a stand-in font calibrated against in-game screenshots (Segoe UI x K_FRIZ, within ~2% of Friz Quadrata
over the samples in CALIBRATION). Scroll box rows are laid out like the linear view does (extent after extent) and
clipped by their box, scroll children by their scroll frame.

Findings per view (grouped by the line that created the region, worst example first):
  TRUNC     single-line text wider than its box: the game shows "..." (what is cut is listed)
  WRAPCUT   wrapped text that needs more lines than its box has room for
  SPILL     a button label wider than its button
  OUTSIDE   text drawn past the edge of its window
  OVERLAP   two texts drawn on top of each other
  COVERED   text drawn under a button / edit box / dropdown it does not belong to

Usage (from dev):  luaenv\\Scripts\\python.exe tools\\ui_audit.py [out_dir] [-k substring] [--no-png]
Writes <out_dir>/report.md, report.json and one PNG per view (findings outlined in red, numbered as in the report).
Default out_dir: tf_e/ui_audit.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from PIL import Image, ImageDraw, ImageFont  # noqa: E402

# ---------------------------------------------------------------------------------------------------------------
# Fonts
# ---------------------------------------------------------------------------------------------------------------
PROXY = "C:/Windows/Fonts/segoeui.ttf"
PROXY_BOLD = "C:/Windows/Fonts/segoeuib.ttf"
# Friz Quadrata advance width = Segoe UI advance x K_FRIZ, from text measured in an in-game screenshot at UI scale
# 2.24 px per unit (window 800 units wide): (text, size, px).
CALIBRATION = [("Attumen the Huntsman", 12, 306), ("Karazhan", 12, 113), ("Solo tanking", 12, 163),
               ("Rokad the Ravager", 12, 243), ("All raids", 16, 138), ("Upcoming", 12, 134)]
K_FRIZ = 1.0855
K_NARROW = 0.82        # Arial Narrow (number / chat fonts) relative to Friz

FONT_SIZES = {
    "GameFontNormal": 12, "GameFontNormalSmall": 10, "GameFontNormalLarge": 16, "GameFontNormalHuge": 20,
    "GameFontNormalMed1": 13, "GameFontNormalMed2": 14, "GameFontNormalMed3": 15, "GameFontNormalLeft": 12,
    "GameFontNormalCenter": 12, "GameFontNormalOutline": 12, "GameFontNormalShadowOutline22": 22,
    "GameFontHighlight": 12, "GameFontHighlightSmall": 10, "GameFontHighlightLarge": 16, "GameFontHighlightHuge": 20,
    "GameFontHighlightMedium": 14, "GameFontHighlightLeft": 12, "GameFontHighlightCenter": 12,
    "GameFontHighlightRight": 12, "GameFontHighlightOutline": 12, "GameFontHighlightSmallOutline": 10,
    "GameFontHighlightSmallLeft": 10, "GameFontHighlightExtraSmall": 9, "GameFontHighlightMed2": 14,
    "GameFontDisable": 12, "GameFontDisableSmall": 10, "GameFontDisableLarge": 16, "GameFontGreen": 12,
    "GameFontGreenSmall": 10, "GameFontRed": 12, "GameFontRedSmall": 10, "GameFontRedLarge": 16, "GameFontWhite": 12,
    "GameFontWhiteSmall": 10, "GameFontBlack": 12, "GameFontBlackSmall": 10, "GameFontDarkGraySmall": 10,
    "GameFontNormalSmallLeft": 10, "GameFontNormal_NoShadow": 12, "GameTooltipText": 12, "GameTooltipTextSmall": 10,
    "GameTooltipHeaderText": 14, "NumberFontNormal": 14, "NumberFontNormalSmall": 12, "NumberFontNormalLarge": 16,
    "NumberFontNormalHuge": 30, "NumberFont_Outline_Med": 14, "NumberFont_Shadow_Med": 14, "ChatFontNormal": 14,
    "ChatFontSmall": 12, "SystemFont_Small": 10, "SystemFont_Med1": 12, "SystemFont_Med2": 13, "SystemFont_Med3": 14,
    "SystemFont_Large": 16, "SystemFont_Huge1": 20, "SystemFont_Outline_Small": 10, "SystemFont_Shadow_Med1": 12,
    "SystemFont_Shadow_Large": 16, "SystemFont_Tiny": 9, "QuestFont": 13, "QuestTitleFont": 18, "Fancy16Font": 16,
    "Fancy22Font": 22, "GameFontNormalTiny": 9, "GameFontHighlightTiny": 9, "Game11Font": 11, "Game12Font": 12,
    "Game13Font": 13, "Game15Font": 15, "Game18Font": 18, "Game20Font": 20, "Game24Font": 24, "Game30Font": 30,
    "GameFontHighlightShadow": 12, "SubZoneTextFont": 26, "ZoneTextFont": 32,
}
NARROW = ("NumberFont", "ChatFont")

_fonts = {}


def _font(bold=False):
    key = bold
    if key not in _fonts:
        _fonts[key] = ImageFont.truetype(PROXY_BOLD if bold else PROXY, 100)
    return _fonts[key]


ESC = re.compile(r"\|c[0-9a-fA-F]{8}|\|r|\|H[^|]*\|h|\|h|\|n")
ICON = re.compile(r"\|T([^|]*)\|t|\|A([^|]*)\|a")


def plain_text(s):
    """The text as drawn: colour codes and links removed, icons kept as a marker (\x01 + size)."""
    if not s:
        return ""
    s = s.replace("||", "\x02")

    def icon(m):
        spec = (m.group(1) or m.group(2) or "").split(":")
        size = 0
        for part in spec[1:3]:
            try:
                size = max(size, int(float(part)))
            except ValueError:
                pass
        return "\x01%d\x01" % size
    s = ICON.sub(icon, s)
    s = ESC.sub("", s)
    return s.replace("\x02", "|")


# Small sizes render wider than they scale (hinting): measured on size-10 lines of the same screenshot (+6%).
SMALL_FACTOR = {9: 1.08, 10: 1.06, 11: 1.03}


def text_width(s, size, narrow=False):
    """Width in UI units of one line of plain_text()."""
    k = K_FRIZ * (K_NARROW if narrow else 1) * SMALL_FACTOR.get(int(round(size)), 1.0)
    w = 0.0
    for i, part in enumerate(s.split("\x01")):
        if i % 2 == 1:      # an icon: its size (0 = the line height)
            n = int(part or 0)
            w += (n if n > 0 else size) + 1
        elif part:
            w += _font().getlength(part) * size / 100.0 * k
    return w


def line_height(size):
    return size + 2


def wrap_lines(s, size, width, narrow=False):
    """Number of lines word wrap needs for s in width."""
    n = 0
    for para in s.split("\n"):
        words = para.split(" ")
        line = ""
        n += 1
        for wd in words:
            cand = wd if not line else line + " " + wd
            if text_width(cand, size, narrow) <= width + 0.5 or not line:
                line = cand
            else:
                n += 1
                line = wd
    return n


def fit_prefix(s, size, width, narrow=False):
    """What a truncated single line shows (without the "...")."""
    ell = text_width("...", size, narrow)
    lo = 0
    for i in range(1, len(s) + 1):
        if text_width(s[:i], size, narrow) + ell <= width:
            lo = i
        else:
            break
    return s[:lo]


# ---------------------------------------------------------------------------------------------------------------
# Capture (Lua, inside the client)
# ---------------------------------------------------------------------------------------------------------------
PRELOAD = r"""
local M = __MOCK
local orig = M.CreateObject
M.CreateObject = function(kind, name, parent, template)
  local o, st = orig(kind, name, parent, template)
  st = st or M.OBJ[o]
  if st and (kind == "FontString" or kind == "Button" or kind == "EditBox" or kind == "CheckButton"
             or kind == "Frame" or kind == "Texture" or kind == "DropdownButton") then
    for lvl = 3, 14 do
      local info = debug.getinfo(lvl, "Sl")
      if not info then break end
      local src = info.source or ""
      if src:find("AddOns/DisasterZone/", 1, true) and not src:find("/Libs/", 1, true) then
        st.src = src:gsub("^@", ""):gsub("^.*AddOns/DisasterZone/", "") .. ":" .. tostring(info.currentline)
        break
      end
    end
  end
  return o, st
end
"""

CAPTURE = r"""
local M = __MOCK
local OBJ = M.OBJ
local lines = {}
local function seq(o) local st = o and OBJ[o]; return st and st.seq or -1 end
local function clean(s) return (tostring(s):gsub("[\t\r]", " "):gsub("\n", "\\n")) end
local rows = {}
for _, o in ipairs(M.all_objects) do
  local st = OBJ[o]
  if st and st.scrollbox and st.scrollbox.frames then
    local view = st.scrollbox.view
    local y = 0
    for i = 1, st.scrollbox.count or 0 do
      local f = st.scrollbox.frames[i]
      if f then
        local ext = view and view.extent or 20
        if view and view.extentCalc then
          local ok, e = pcall(view.extentCalc, i, f.GetElementData and f:GetElementData())
          if ok and tonumber(e) then ext = tonumber(e) end
        end
        rows[f] = { box = o, y = y, h = ext }
        y = y + ext + ((view and view.spacing) or 0)
      end
    end
  end
end
local scrollOf = {}
for _, o in ipairs(M.all_objects) do
  local st = OBJ[o]
  if st and st.scrollchild then scrollOf[st.scrollchild] = o end
end
for _, o in ipairs(M.all_objects) do
  local st = OBJ[o]
  local kind = st and st.kind
  if st and (kind == "FontString" or st.is_frame or kind == "Texture") then
    local vis = (o.IsVisible and o:IsVisible()) and 1 or 0
    local pts = {}
    for _, p in ipairs(st.points) do
      pts[#pts + 1] = table.concat({ tostring(p[1]), tostring(seq(p[2] or st.parent)), tostring(p[3] or p[1]),
                                     tostring(p[4] or 0), tostring(p[5] or 0) }, ",")
    end
    local text, font, size, wrap, maxl, jh, jv = "", "", 0, "", 0, "", ""
    if kind == "FontString" then
      text = st.text or ""
      local fo = st.fontobj
      font = fo and OBJ[fo] and OBJ[fo].name or (st.template or "")
      if st.font then size = tonumber(st.font[2]) or 0; font = st.font[1] or font end
      wrap = st.wrap == false and "0" or "1"
      maxl = st.maxlines or 0
      jh, jv = st.justifyH or "CENTER", st.justifyV or "MIDDLE"
    elseif kind == "EditBox" then
      text = o:GetText() or ""
    end
    local r = rows[o]
    local c = st.color
    lines[#lines + 1] = table.concat({
      "R", st.seq, kind, seq(st.parent), st.w or "", st.h or "", st.all_points and 1 or 0, st.scale or 1,
      table.concat(pts, ";"), clean(text), font, size, wrap, maxl, jh, jv, st.src or "", st.strata or "",
      st.level or 0, st.clips and 1 or 0, st.scrollbox and 1 or 0, r and seq(r.box) or "", r and r.y or "",
      r and r.h or "", scrollOf[o] and seq(scrollOf[o]) or "", st.name or "", st.template or "",
      c and table.concat({ c[1], c[2], c[3], c[4] or 1 }, ",") or "", st.layer or "",
      (st.fontstring and seq(st.fontstring)) or "", vis,
    }, "\t")
  end
end
lines[#lines + 1] = "U\t" .. seq(UIParent)
return table.concat(lines, "\n")
"""

FIELDS = ["tag", "seq", "kind", "parent", "w", "h", "all", "scale", "points", "text", "font", "size", "wrap", "maxl",
          "jh", "jv", "src", "strata", "level", "clips", "scrollbox", "rowbox", "rowy", "rowh", "scrollof", "name",
          "template", "color", "layer", "btnfs", "vis"]


def metrics_preload():
    """Lua that gives the mock's FontStrings real text metrics (GetStringWidth / Height, GetNumLines, IsTruncated),
    from the same calibrated stand-in font, so the addon's own layout code (rows sized by GetStringHeight, columns by
    GetStringWidth) lays out like in game. Only for the audit: the test suites keep the mock's simple metrics."""
    adv = []
    f = _font()
    for code in range(32, 256):
        try:
            adv.append("[%d]=%.3f" % (code, f.getlength(chr(code)) * K_FRIZ / 100.0))
        except Exception:  # noqa: BLE001
            pass
    sizes = ", ".join('["%s"]=%d' % (k, v) for k, v in FONT_SIZES.items())
    small = ", ".join("[%d]=%.3f" % (k, v) for k, v in SMALL_FACTOR.items())
    return r"""
local M = __MOCK
local ADV = { %s }
local SIZES = { %s }
local SMALL = { %s }
local NARROW = %.3f
local OBJ = M.OBJ
local function font_of(st)
  local size, name = nil, ""
  if st.font then size = tonumber(st.font[2]); name = tostring(st.font[1] or "") end
  local fo = st.fontobj
  local fname = fo and OBJ[fo] and OBJ[fo].name or st.template or ""
  if not size then size = SIZES[fname] or 12 end
  local narrow = fname:find("^NumberFont") or fname:find("^ChatFont") or name:upper():find("ARIALN")
  return size, narrow and NARROW or 1
end
local function plain(s)
  s = tostring(s or ""):gsub("||", "\2")
  s = s:gsub("|T([^|]*)|t", function(spec)
    local _, h = spec:match("^([^:]*):?(%%d*)")
    return "\1" .. (tonumber(h) or 0) .. "\1"
  end)
  s = s:gsub("|c%%x%%x%%x%%x%%x%%x%%x%%x", ""):gsub("|r", ""):gsub("|H[^|]*|h", ""):gsub("|h", "")
  return (s:gsub("\2", "|"))
end
local function line_width(line, size, k)
  local w, i = 0, 1
  while i <= #line do
    local c = line:byte(i)
    if c == 1 then
      local j = line:find("\1", i + 1, true) or #line
      local n = tonumber(line:sub(i + 1, j - 1)) or 0
      w = w + (n > 0 and n or size) + 1
      i = j + 1
    else
      w = w + (ADV[c] or 0.55) * size * k
      i = i + 1
    end
  end
  return w
end
local function widthOf(st)
  if st.w then return st.w end
  local ok, l, b, w = pcall(M.region_rect, st.self)
  return (ok and w and w > 0) and w or nil
end
local function layout(self)
  local st = OBJ[self]
  local size, nk = font_of(st)
  local k = nk * (SMALL[math.floor(size + 0.5)] or 1)
  local t = plain(st.text)
  local nat, lines = 0, 0
  local box = st.wrap ~= false and widthOf(st) or nil
  for para in (t .. "\n"):gmatch("(.-)\n") do
    local pw = line_width(para, size, k)
    if pw > nat then nat = pw end
    if box and pw > box then
      local cur = ""
      lines = lines + 1
      for word in para:gmatch("%%S+") do
        local cand = cur == "" and word or (cur .. " " .. word)
        if line_width(cand, size, k) <= box + 0.5 or cur == "" then cur = cand
        else lines = lines + 1; cur = word end
      end
    else
      lines = lines + 1
    end
  end
  if st.maxlines and st.maxlines > 0 and lines > st.maxlines then lines = st.maxlines end
  return nat, lines, size, box
end
local FS = M.Methods.FontString
FS.GetUnboundedStringWidth = function(self) local nat = layout(self); return nat end
FS.GetStringWidth = function(self)
  local nat, lines, size, box = layout(self)
  local st = OBJ[self]
  local w = st.w or widthOf(st)
  if w and nat > w then return w end
  return nat
end
FS.GetStringHeight = function(self) local _, lines, size = layout(self); return lines * (size + 2) end
FS.GetNumLines = function(self) local _, lines = layout(self); return lines end
FS.GetLineHeight = function(self) local _, _, size = layout(self); return size end
FS.IsTruncated = function(self)
  local nat, lines, size, box = layout(self)
  local st = OBJ[self]
  local w = st.w or widthOf(st)
  return (st.wrap == false and w and nat > w + 0.5) and true or false
end
local origCreate = M.CreateObject
M.CreateObject = function(kind, name, parent, template)
  local o, st = origCreate(kind, name, parent, template)
  st = st or OBJ[o]
  if st then st.self = o end
  return o, st
end
""" % (", ".join(adv), sizes, small, K_NARROW)


def capture(client):
    raw = client.eval(CAPTURE)
    regs, uiparent = {}, None
    for line in raw.split("\n"):
        parts = line.split("\t")
        if parts[0] == "U":
            uiparent = int(parts[1])
            continue
        d = dict(zip(FIELDS, parts))
        r = {
            "seq": int(d["seq"]), "kind": d["kind"], "parent": int(d["parent"]),
            "w": float(d["w"]) if d["w"] else None, "h": float(d["h"]) if d["h"] else None,
            "all": d["all"] == "1", "scale": float(d["scale"] or 1), "points": [],
            "text": d["text"].replace("\\n", "\n"), "font": d["font"], "size": float(d["size"] or 0),
            "wrap": d["wrap"] != "0", "maxl": int(float(d["maxl"] or 0)), "jh": d["jh"], "jv": d["jv"],
            "src": d["src"], "clips": d["clips"] == "1", "scrollbox": d["scrollbox"] == "1",
            "rowbox": int(d["rowbox"]) if d["rowbox"] else None, "rowy": float(d["rowy"]) if d["rowy"] else 0,
            "rowh": float(d["rowh"]) if d["rowh"] else 0, "scrollof": int(d["scrollof"]) if d["scrollof"] else None,
            "name": d["name"], "template": d["template"], "level": d["level"], "strata": d["strata"],
            "color": [float(x) for x in d["color"].split(",")] if d["color"] else None, "layer": d["layer"],
            "btnfs": int(d["btnfs"]) if d["btnfs"] else None, "vis": d.get("vis") == "1",
        }
        for p in d["points"].split(";") if d["points"] else []:
            a = p.split(",")
            r["points"].append((a[0], int(a[1]), a[2], float(a[3]), float(a[4])))
        regs[r["seq"]] = r
    return regs, uiparent


# ---------------------------------------------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------------------------------------------
PX = {"TOPLEFT": 0, "LEFT": 0, "BOTTOMLEFT": 0, "TOP": .5, "CENTER": .5, "BOTTOM": .5, "TOPRIGHT": 1, "RIGHT": 1,
      "BOTTOMRIGHT": 1}
PY = {"BOTTOMLEFT": 0, "BOTTOM": 0, "BOTTOMRIGHT": 0, "LEFT": .5, "CENTER": .5, "RIGHT": .5, "TOPLEFT": 1, "TOP": 1,
      "TOPRIGHT": 1}


def font_of(r):
    name = r["font"] or ""
    size = r["size"] or FONT_SIZES.get(name, 12)
    narrow = name.startswith(NARROW) or "ARIALN" in name.upper()
    return size, narrow


class Layout:
    def __init__(self, regs, uiparent):
        self.regs, self.ui = regs, uiparent
        self.memo = {}
        self.button_labels = {r["btnfs"]: s for s, r in regs.items() if r.get("btnfs")}

    def scale(self, s):
        k = 1.0
        while s in self.regs:
            k *= self.regs[s]["scale"]
            s = self.regs[s]["parent"]
        return k

    def natural(self, r):
        size, narrow = font_of(r)
        t = plain_text(r["text"])
        return max([text_width(ln, size, narrow) for ln in t.split("\n")] or [0]), size, narrow

    def rect(self, s):
        """left, bottom, width, height in UIParent units, or None."""
        if s == self.ui:
            return (0.0, 0.0, 1920.0, 1080.0)
        if s in self.memo:
            return self.memo[s]
        self.memo[s] = None
        r = self.regs.get(s)
        if r is None:
            return None
        k = self.scale(s)
        res = None
        if r["rowbox"] is not None and not r["points"]:
            b = self.rect(r["rowbox"])
            if b:
                res = (b[0], b[1] + b[3] - r["rowy"] - r["rowh"], b[2], r["rowh"])
        elif r["scrollof"] is not None and not r["points"]:
            sf = self.rect(r["scrollof"])
            if sf:
                w = (r["w"] or sf[2]) * k
                h = (r["h"] or sf[3]) * k
                res = (sf[0], sf[1] + sf[3] - h, w, h)
        elif r["all"] and not r["points"]:
            res = self.rect(r["parent"])
        elif not r["points"] and (r["template"] == "InsetFrameTemplate" or r["name"].endswith("Inset")):
            # BasicFrameTemplateWithInset's Inset: TOPLEFT 2, -24 / BOTTOMRIGHT -2, 2 (the template's anchors)
            p = self.rect(r["parent"])
            if p:
                res = (p[0] + 2 * k, p[1] + 2 * k, p[2] - 4 * k, p[3] - 26 * k)
        elif not r["points"] and r["kind"] == "Button" and (r["name"].endswith("CloseButton")
                                                             or r["template"] == "UIPanelCloseButton"):
            p = self.rect(r["parent"])                     # a template's close button: top right, 24 x 24
            if p:
                res = (p[0] + p[2] - 24 * k, p[1] + p[3] - 24 * k, 24 * k, 24 * k)
        elif not r["points"] and r["kind"] in ("Frame", "Texture") and not r["w"] and not r["h"] \
                and r["parent"] in self.regs and r["rowbox"] is None:
            res = self.rect(r["parent"])                   # a template child the mock left unanchored
        elif not r["points"] and r["kind"] == "FontString" and r["seq"] not in self.button_labels \
                and r["parent"] in self.regs:
            # a template's own text the mock left unanchored: a window title at the top, a button / dropdown / edit
            # box label centred in it
            p = self.rect(r["parent"])
            if p:
                nat, size, _ = self.natural(r)
                h = line_height(size) * k
                if r["name"].endswith("TitleText"):
                    res = (p[0] + p[2] / 2 - nat * k / 2, p[1] + p[3] - 4 * k - h, nat * k, h)
                else:
                    res = (p[0] + p[2] / 2 - nat * k / 2, p[1] + p[3] / 2 - h / 2, nat * k, h)
                    self.button_labels.setdefault(r["seq"], r["parent"])
        elif not r["points"] and r["seq"] in self.button_labels:
            b = self.rect(self.button_labels[r["seq"]])
            if b:
                nat, size, _ = self.natural(r)
                res = (b[0] + b[2] / 2 - nat / 2, b[1] + b[3] / 2 - line_height(size) / 2, nat, line_height(size))
        else:
            res = self._anchored(r, k)
        self.memo[s] = res
        return res

    def _anchored(self, r, k):
        l = rr = cx = t = b = cy = None
        for (pt, rel, rpt, x, y) in r["points"]:
            if pt not in PX or rpt not in PX:
                return None
            rel_rect = self.rect(rel)
            if rel_rect is None:
                return None
            ax = rel_rect[0] + PX[rpt] * rel_rect[2] + x * k
            ay = rel_rect[1] + PY[rpt] * rel_rect[3] + y * k
            hx, vy = PX[pt], PY[pt]
            if hx == 0:
                l = ax
            elif hx == 1:
                rr = ax
            else:
                cx = ax
            if vy == 0:
                b = ay
            elif vy == 1:
                t = ay
            else:
                cy = ay
        w = r["w"] * k if r["w"] else None
        h = r["h"] * k if r["h"] else None
        if r["kind"] == "FontString":
            nat, size, narrow = self.natural(r)
            if w is None and not (l is not None and rr is not None):
                w = nat * k
            if h is None and not (t is not None and b is not None):
                width = (rr - l) if (l is not None and rr is not None) else w
                n = 1 if not r["wrap"] else wrap_lines(plain_text(r["text"]), size, width / k if width else 9999, narrow)
                if r["maxl"]:
                    n = min(n, r["maxl"])
                h = n * line_height(size) * k
        if w is None and r["kind"] != "FontString" and not (l is not None and rr is not None):
            w = 0.0
        if h is None and r["kind"] != "FontString" and not (t is not None and b is not None):
            h = 0.0
        if l is not None and rr is not None:
            left, width = l, rr - l
        elif l is not None and w is not None:
            left, width = l, w
        elif rr is not None and w is not None:
            left, width = rr - w, w
        elif cx is not None and w is not None:
            left, width = cx - w / 2, w
        else:
            return None
        if b is not None and t is not None:
            bottom, height = b, t - b
        elif b is not None and h is not None:
            bottom, height = b, h
        elif t is not None and h is not None:
            bottom, height = t - h, h
        elif cy is not None and h is not None:
            bottom, height = cy - h / 2, h
        else:
            return None
        return (left, bottom, width, height)

    def width_constrained(self, r):
        if r["w"]:
            return True
        hs = {PX[p[0]] for p in r["points"] if p[0] in PX}
        return 0 in hs and 1 in hs or r["all"]

    def height_constrained(self, r):
        if r["h"]:
            return True
        vs = {PY[p[0]] for p in r["points"] if p[0] in PY}
        return 0 in vs and 1 in vs or r["all"]

    def ancestors(self, s):
        out = []
        r = self.regs.get(s)
        while r is not None:
            p = r["parent"]
            if p not in self.regs:
                break
            out.append(p)
            r = self.regs[p]
        return out

    def window(self, s):
        """The top-level frame (a direct child of UIParent) a region belongs to."""
        anc = [s] + self.ancestors(s)
        for a in anc:
            if self.regs.get(a, {}).get("parent") == self.ui:
                return a
        return anc[-1]

    def clip(self, s):
        """The rectangle children of scroll frames / scroll boxes / clipping frames are cut to, or None."""
        rect = None
        for a in self.ancestors(s):
            ra = self.regs[a]
            if ra["scrollbox"] or ra["clips"] or ra["kind"] == "ScrollFrame":
                c = self.rect(a)
                if c:
                    rect = c if rect is None else intersect(rect, c) or (c[0], c[1], 0, 0)
        return rect


def intersect(a, b):
    l, bt = max(a[0], b[0]), max(a[1], b[1])
    r, t = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    if r <= l or t <= bt:
        return None
    return (l, bt, r - l, t - bt)


# ---------------------------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------------------------
CONTROL_KINDS = ("Button", "EditBox", "CheckButton", "DropdownButton")


def drawn_text_rect(lay, r, rect):
    """Where the text's ink is: the part of the box the text covers (justified), cut to the box when constrained."""
    nat, size, narrow = lay.natural(r)
    k = lay.scale(r["seq"])
    nat *= k
    w = min(nat, rect[2]) if lay.width_constrained(r) else nat
    if r["jh"] == "LEFT":
        x = rect[0]
    elif r["jh"] == "RIGHT":
        x = rect[0] + rect[2] - w
    else:
        x = rect[0] + rect[2] / 2 - w / 2
    t = plain_text(r["text"])
    if r["wrap"] and lay.width_constrained(r):
        n = wrap_lines(t, size, rect[2] / k, narrow)
    else:
        n = len(t.split("\n"))
    if r["maxl"]:
        n = min(n, r["maxl"])
    h = min(n * line_height(size) * k, rect[3]) if lay.height_constrained(r) else n * line_height(size) * k
    if r["jv"] == "TOP":
        y = rect[1] + rect[3] - h
    elif r["jv"] == "BOTTOM":
        y = rect[1]
    else:
        y = rect[1] + rect[3] / 2 - h / 2
    return (x, y, w, h)


def audit(regs, uiparent):
    lay = Layout(regs, uiparent)
    findings = []
    texts = []
    for s, r in regs.items():
        if r["kind"] != "FontString" or not r["vis"]:
            continue
        t = plain_text(r["text"]).strip()
        if not t or t == "\x01":
            continue
        rect = lay.rect(s)
        if rect is None:
            continue
        owner = lay.button_labels.get(s)
        if owner is not None and (lay.rect(owner) or (0, 0, 0, 0))[2] < 1:
            continue                                   # a tab the game sizes itself (PanelTemplates)
        clip = lay.clip(s)
        if clip is not None and intersect(rect, clip) is None:
            continue                                   # scrolled out of view
        nat, size, narrow = lay.natural(r)
        k = lay.scale(s)
        ink = drawn_text_rect(lay, r, rect)
        texts.append((s, r, rect, ink, clip))
        label = t.replace("\n", " / ")[:90]
        if lay.width_constrained(r) and (not r["wrap"] or r["maxl"] == 1):
            lines = t.split("\n")
            worst = max(lines, key=lambda ln: text_width(ln, size, narrow))
            over = text_width(worst, size, narrow) * k - rect[2]
            if over > 1.0:
                shown = fit_prefix(worst, size, rect[2] / k, narrow)
                findings.append({"kind": "TRUNC", "seq": s, "src": r["src"], "rect": rect, "over": over,
                                 "text": label, "msg": 'shows "%s..." (needs %.0f more)' % (shown, over)})
        elif r["wrap"] and lay.width_constrained(r) and lay.height_constrained(r):
            need = wrap_lines(t, size, rect[2] / k, narrow)
            if r["maxl"]:
                need = min(need, r["maxl"]) if r["maxl"] < need else need
            room = int((rect[3] / k + 1) // line_height(size))
            if need > max(room, 1) and (not r["maxl"] or r["maxl"] > room):
                findings.append({"kind": "WRAPCUT", "seq": s, "src": r["src"], "rect": rect,
                                 "over": (need - room) * line_height(size), "text": label,
                                 "msg": "needs %d lines, room for %d" % (need, room)})
        # a button label wider than its button
        parent = regs.get(r["parent"])
        if owner is None and parent and parent["kind"] in ("Button",) and r["points"] and \
                all(p[0] == "CENTER" for p in r["points"]):
            owner = r["parent"]
        if owner is not None and not lay.width_constrained(r):
            br = lay.rect(owner)
            if br and nat * k > br[2] - 6:
                findings.append({"kind": "SPILL", "seq": s, "src": r["src"] or regs[owner]["src"], "rect": br,
                                 "over": nat * k - br[2] + 6, "text": label,
                                 "msg": "label %.0f wide in a %.0f wide button" % (nat * k, br[2])})
        # past the window's edge
        win = lay.window(s)
        wr = lay.rect(win)
        if wr and win != s:
            vis = ink if clip is None else (intersect(ink, clip) or ink)
            out_r = vis[0] + vis[2] - (wr[0] + wr[2])
            out_l = wr[0] - vis[0]
            out_b = wr[1] - vis[1]
            out_t = vis[1] + vis[3] - (wr[1] + wr[3])
            worst = max(out_r, out_l, out_b, out_t)
            if worst > 2:
                findings.append({"kind": "OUTSIDE", "seq": s, "src": r["src"], "rect": vis, "over": worst,
                                 "text": label, "msg": "%.0f past the edge of %s" % (worst, regs[win]["name"] or
                                                                                   regs[win]["src"])})
    # overlaps between texts of the same window
    by_win = {}
    for item in texts:
        by_win.setdefault(lay.window(item[0]), []).append(item)
    for win, items in by_win.items():
        for i in range(len(items)):
            si, ri, _, ink_i, ci = items[i]
            if ci:
                ink_i = intersect(ink_i, ci)
                if not ink_i:
                    continue
            for j in range(i + 1, len(items)):
                sj, rj, _, ink_j, cj = items[j]
                if cj:
                    ink_j = intersect(ink_j, cj)
                    if not ink_j:
                        continue
                x = intersect(ink_i, ink_j)
                if x and x[2] > 2 and x[3] > 3:
                    findings.append({"kind": "OVERLAP", "seq": si, "src": ri["src"], "rect": x, "over": x[2],
                                     "text": plain_text(ri["text"])[:60] + "  <>  " + plain_text(rj["text"])[:60],
                                     "msg": "drawn over %s (%s)" % (rj["src"], plain_text(rj["text"])[:40])})
    # text under controls it doesn't belong to
    controls = []
    drawn = set()          # buttons that draw something themselves (a label, a coloured texture, a template look)
    for s, r in regs.items():
        if r["vis"] and ((r["kind"] == "FontString" and plain_text(r["text"]).strip()) or
                         (r["kind"] == "Texture" and r["color"])):
            drawn.add(r["parent"])
    for s, r in regs.items():
        if not r["vis"]:
            continue
        if r["kind"] in CONTROL_KINDS or (r["kind"] == "Frame" and "Dropdown" in (r["template"] or "")):
            if r["kind"] == "Button" and s not in drawn and not r["template"]:
                continue           # an invisible click area over its own row's text
            rc = lay.rect(s)
            if rc and rc[2] > 4 and rc[3] > 4:
                controls.append((s, rc, lay.clip(s)))
    for (s, r, rect, ink, clip) in texts:
        anc = set([s] + lay.ancestors(s))
        win = lay.window(s)
        for (cs, crect, cclip) in controls:
            if cs in anc or lay.window(cs) != win or s in set(lay.ancestors(cs)):
                continue
            if r["parent"] in set(lay.ancestors(cs)) and False:
                continue
            a = ink if clip is None else intersect(ink, clip)
            b = crect if cclip is None else intersect(crect, cclip)
            if not a or not b:
                continue
            x = intersect(a, b)
            if x and x[2] > 3 and x[3] > 4:
                findings.append({"kind": "COVERED", "seq": s, "src": r["src"], "rect": x, "over": x[2],
                                 "text": plain_text(r["text"])[:60],
                                 "msg": "under %s %s" % (regs[cs]["kind"], regs[cs]["src"] or regs[cs]["name"])})
    return findings, lay


# ---------------------------------------------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------------------------------------------
PNG_SCALE = 2


def render(regs, lay, findings, path, crop=None):
    shown = [s for s in regs if regs[s]["vis"] and lay.rect(s)]
    wins = {lay.window(s) for s in shown if regs[s]["kind"] != "FontString"}
    boxes = []
    for w in wins:
        r = lay.rect(w)
        if r and regs[w]["name"] not in ("", "UIParent") and r[2] > 20 and r[3] > 20 and r[2] < 1900:
            boxes.append(r)
    if crop is None:
        if not boxes:
            return
        l = min(b[0] for b in boxes)
        bt = min(b[1] for b in boxes)
        r_ = max(b[0] + b[2] for b in boxes)
        t = max(b[1] + b[3] for b in boxes)
        crop = (max(0, l - 10), max(0, bt - 10), min(1920, r_ + 10), min(1080, t + 10))
    cl, cb, cr, ct = crop
    W, H = int((cr - cl) * PNG_SCALE), int((ct - cb) * PNG_SCALE)
    if W <= 0 or H <= 0 or W > 5000 or H > 4000:
        return
    img = Image.new("RGB", (W, H), (24, 24, 26))
    dr = ImageDraw.Draw(img, "RGBA")

    def box(rc):
        return ((rc[0] - cl) * PNG_SCALE, (ct - rc[1] - rc[3]) * PNG_SCALE,
                (rc[0] + rc[2] - cl) * PNG_SCALE, (ct - rc[1]) * PNG_SCALE)
    order = sorted(shown, key=lambda s: (str(regs[s]["strata"]), float(regs[s]["level"] or 0), s))
    for s in order:
        r = regs[s]
        rc = lay.rect(s)
        clip = lay.clip(s)
        if clip is not None:
            rc2 = intersect(rc, clip)
            if not rc2:
                continue
        else:
            rc2 = rc
        if r["kind"] == "Texture" and r["color"]:
            c = r["color"]
            dr.rectangle(box(rc2), fill=(int(c[0] * 255), int(c[1] * 255), int(c[2] * 255), int(c[3] * 255)))
        elif r["kind"] in CONTROL_KINDS:
            dr.rectangle(box(rc2), outline=(90, 90, 100, 255))
        elif r["kind"] == "Frame" and r["parent"] == lay.ui:
            dr.rectangle(box(rc2), fill=(16, 16, 18, 255), outline=(120, 100, 40, 255))
    for s in order:
        r = regs[s]
        if r["kind"] != "FontString":
            continue
        t = plain_text(r["text"])
        if not t.strip():
            continue
        rc = lay.rect(s)
        ink = drawn_text_rect(lay, r, rc)
        clip = lay.clip(s)
        if clip is not None and not intersect(ink, clip):
            continue
        size, narrow = font_of(r)
        k = lay.scale(s)
        fnt = ImageFont.truetype(PROXY, max(6, int(size * k * PNG_SCALE * K_FRIZ * (K_NARROW if narrow else 1))))
        col = (235, 235, 235)
        m = re.search(r"\|c[0-9a-fA-F]{2}([0-9a-fA-F]{6})", r["text"])
        if m:
            h = m.group(1)
            col = (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
        elif "Normal" in r["font"]:
            col = (255, 209, 0)
        elif "Disable" in r["font"]:
            col = (128, 128, 128)
        lines = t.replace("\x01", "#").split("\n")
        if r["wrap"] and lay.width_constrained(r):
            wrapped = []
            for para in lines:
                cur = ""
                for wd in para.split(" "):
                    cand = wd if not cur else cur + " " + wd
                    if text_width(cand, size, narrow) * k <= rc[2] + 0.5 or not cur:
                        cur = cand
                    else:
                        wrapped.append(cur)
                        cur = wd
                wrapped.append(cur)
            lines = wrapped
        x0, y0, x1, y1 = box(ink)
        lh = line_height(size) * k * PNG_SCALE
        room = max(1, int(round((y1 - y0) / lh))) if lay.height_constrained(r) else len(lines)
        for i, ln in enumerate(lines[:room]):
            if lay.width_constrained(r) and text_width(ln, size, narrow) * k > rc[2] + 1:
                ln = fit_prefix(ln, size, rc[2] / k, narrow) + "..."
            dr.text((x0, y0 + i * lh), ln, font=fnt, fill=col)
    for i, f in enumerate(findings, 1):
        x0, y0, x1, y1 = box(f["rect"])
        dr.rectangle((x0 - 1, y0 - 1, x1 + 1, y1 + 1), outline=(255, 40, 40, 255), width=2)
        dr.text((x0, max(0, y0 - 14)), str(i), font=ImageFont.truetype(PROXY_BOLD, 13), fill=(255, 80, 80))
    img.save(path)


# ---------------------------------------------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------------------------------------------
def group(findings):
    """One entry per (kind, creation site), the worst example first."""
    out = {}
    for f in findings:
        key = (f["kind"], f["src"] or f["text"][:30])
        g = out.get(key)
        if g is None or f["over"] > g["over"]:
            n = (g["count"] if g else 0) + 1
            out[key] = dict(f, count=n)
        else:
            g["count"] += 1
    return sorted(out.values(), key=lambda f: (-f["over"]))


def main():
    import harness
    harness.LOAD_ROOMS = True                  # (the Teron 3D view needs its room)
    from ui_audit_states import STATES, build_world
    args = sys.argv[1:]
    only = None
    png = True
    out_dir = os.path.join(DEV, "tf_e", "ui_audit")
    while args:
        a = args.pop(0)
        if a == "-k":
            only = args.pop(0)
        elif a == "--no-png":
            png = False
        else:
            out_dir = a
    os.makedirs(out_dir, exist_ok=True)
    w, c = build_world(PRELOAD + metrics_preload())
    report, total = [], 0
    md = ["# DisasterZone UI audit", ""]
    for name, fn in STATES:
        if only and only not in name:
            continue
        try:
            viewer = fn(w, c)
        except Exception as e:  # noqa: BLE001
            md.append("## %s\n\nCould not open: %s\n" % (name, e))
            continue
        w.tick(0.6)
        regs, ui = capture(viewer)
        found, lay = audit(regs, ui)
        grouped = group(found)
        total += len(grouped)
        vis_texts = [x for x, r in regs.items()
                     if r["kind"] == "FontString" and r["vis"] and plain_text(r["text"]).strip()]
        unres = [x for x in vis_texts if lay.rect(x) is None]
        unres_src = sorted({regs[x]["src"] for x in unres})
        report.append({"state": name, "findings": grouped, "texts": len(vis_texts), "unresolved": len(unres),
                       "unresolved_src": unres_src[:20]})
        md.append("## %s (%d)\n" % (name, len(grouped)))
        md.append("_%d visible texts, %d not placed%s_\n" % (len(vis_texts), len(unres),
                                                            (": " + ", ".join(unres_src[:8])) if unres else ""))
        for i, f in enumerate(grouped, 1):
            md.append("%d. **%s** `%s` x%d: %s  \n   _%s_" % (i, f["kind"], f["src"], f["count"], f["msg"], f["text"]))
        md.append("")
        if png:
            render(regs, lay, grouped, os.path.join(out_dir, re.sub(r"[^A-Za-z0-9_-]+", "_", name) + ".png"))
    # one list over all views: each (kind, creation site) once, with the views it shows in
    uniq = {}
    for rep in report:
        for f in rep["findings"]:
            key = (f["kind"], f["src"] or f["text"][:30])
            u = uniq.setdefault(key, dict(f, views=[]))
            u["views"].append(rep["state"])
            if f["over"] > u["over"]:
                u.update({k: f[k] for k in ("over", "msg", "text")})
    summary = ["# Summary: %d distinct finding(s)" % len(uniq), ""]
    for i, u in enumerate(sorted(uniq.values(), key=lambda u: (u["src"], u["kind"])), 1):
        views = u["views"]
        summary.append("%d. **%s** `%s`: %s  \n   _%s_  \n   in: %s" % (
            i, u["kind"], u["src"], u["msg"], u["text"],
            ", ".join(views[:4]) + (" (+%d)" % (len(views) - 4) if len(views) > 4 else "")))
    md = summary + [""] + md
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md))
    with open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=1, default=str)
    print("%d finding group(s) in %d view(s); %s" % (total, len(report), os.path.join(out_dir, "report.md")))
    errs = w.errors()
    if errs:
        print("%d Lua error(s) while opening the views (first: %s)" % (len(errs), str(errs[0])[:300]))


if __name__ == "__main__":
    main()
