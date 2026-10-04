if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Codec.lua", ...) then return end -- DisasterZone: Core/Codec.lua
-- ns.Codec: the text formats other sites use, for importing and exporting BiS lists (Core/BiSImport.lua,
-- Core/BiSExport.lua): JSON (decode / encode), base64 (standard and the URL-safe alphabet Wowhead links use) and CSV.
-- Every decoder takes untrusted pasted text: sizes and nesting are capped and errors come back as (nil, message).
local addonName, ns = ...

local Codec = {}
ns.Codec = Codec

local type, tostring, tonumber, pairs, ipairs, next = type, tostring, tonumber, pairs, ipairs, next
local strbyte, strchar, strsub, strfind, strformat, strgsub = string.byte, string.char, string.sub, string.find,
    string.format, string.gsub
local tconcat, tsort = table.concat, table.sort
local floor = math.floor

local MAX_TEXT = 4 * 1024 * 1024
local MAX_DEPTH = 40

-- JSON null inside arrays / objects (keeps array positions: [1, null, 3] -> { 1, Codec.NULL, 3 }).
Codec.NULL = setmetatable({}, { __tostring = function() return "null" end })

---------------------------------------------------------------------------
-- JSON
---------------------------------------------------------------------------

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function Utf8(cp)
    if cp < 0x80 then return strchar(cp) end
    if cp < 0x800 then return strchar(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return strchar(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return strchar(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40, 0x80 + floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40)
end

local function Fail(pos, what)
    error({ json = true, msg = strformat("%s at character %d", what, pos) }, 0)
end

local function SkipSpace(s, pos)
    local _, e = strfind(s, "^[ \t\r\n]*", pos)
    return e + 1
end

local ParseValue

local function ParseString(s, pos)
    -- pos is at the opening quote
    local buf, n = {}, 0
    local i = pos + 1
    while true do
        local q = strfind(s, '["\\]', i)
        if not q then Fail(pos, "unfinished text") end
        if q > i then
            n = n + 1
            buf[n] = strsub(s, i, q - 1)
        end
        if strbyte(s, q) == 34 then   -- "
            return tconcat(buf), q + 1
        end
        local c = strsub(s, q + 1, q + 1)
        if c == "u" then
            local hex = strsub(s, q + 2, q + 5)
            if not strfind(hex, "^%x%x%x%x$") then Fail(q, "bad \\u escape") end
            local cp = tonumber(hex, 16)
            local nextAt = q + 6
            if cp >= 0xD800 and cp <= 0xDBFF and strsub(s, nextAt, nextAt + 1) == "\\u" then
                local lo = tonumber(strsub(s, nextAt + 2, nextAt + 5), 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    nextAt = nextAt + 6
                end
            end
            n = n + 1
            buf[n] = Utf8(cp)
            i = nextAt
        else
            local e = ESCAPES[c]
            if not e then Fail(q, "bad escape") end
            n = n + 1
            buf[n] = e
            i = q + 2
        end
    end
end

local function ParseNumber(s, pos)
    local _, e = strfind(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not e then Fail(pos, "unexpected character") end
    local v = tonumber(strsub(s, pos, e))
    if v == nil then Fail(pos, "bad number") end
    return v, e + 1
end

function ParseValue(s, pos, depth)
    if depth > MAX_DEPTH then Fail(pos, "nested too deep") end
    pos = SkipSpace(s, pos)
    local c = strbyte(s, pos)
    if c == 123 then   -- {
        local obj = {}
        pos = SkipSpace(s, pos + 1)
        if strbyte(s, pos) == 125 then return obj, pos + 1 end
        while true do
            if strbyte(s, pos) ~= 34 then Fail(pos, "expected a name") end
            local key
            key, pos = ParseString(s, pos)
            pos = SkipSpace(s, pos)
            if strbyte(s, pos) ~= 58 then Fail(pos, "expected ':'") end
            local v
            v, pos = ParseValue(s, pos + 1, depth + 1)
            obj[key] = v
            pos = SkipSpace(s, pos)
            local d = strbyte(s, pos)
            if d == 125 then return obj, pos + 1 end
            if d ~= 44 then Fail(pos, "expected ',' or '}'") end
            pos = SkipSpace(s, pos + 1)
        end
    elseif c == 91 then   -- [
        local arr, n = {}, 0
        pos = SkipSpace(s, pos + 1)
        if strbyte(s, pos) == 93 then return arr, pos + 1 end
        while true do
            local v
            v, pos = ParseValue(s, pos, depth + 1)
            n = n + 1
            arr[n] = v
            pos = SkipSpace(s, pos)
            local d = strbyte(s, pos)
            if d == 93 then return arr, pos + 1 end
            if d ~= 44 then Fail(pos, "expected ',' or ']'") end
            pos = pos + 1
        end
    elseif c == 34 then
        return ParseString(s, pos)
    elseif c == 116 and strsub(s, pos, pos + 3) == "true" then
        return true, pos + 4
    elseif c == 102 and strsub(s, pos, pos + 4) == "false" then
        return false, pos + 5
    elseif c == 110 and strsub(s, pos, pos + 3) == "null" then
        return Codec.NULL, pos + 4
    elseif c == nil then
        Fail(pos, "unexpected end")
    end
    return ParseNumber(s, pos)
end

-- value or nil, message. JSON null comes back as Codec.NULL.
function Codec.JSONDecode(text)
    if type(text) ~= "string" then return nil, "no text" end
    if #text > MAX_TEXT then return nil, "too long" end
    local ok, v, pos = pcall(ParseValue, text, 1, 0)
    if not ok then
        if type(v) == "table" and v.json then return nil, v.msg end
        return nil, tostring(v)
    end
    pos = SkipSpace(text, pos)
    if pos <= #text then return nil, strformat("unexpected text at character %d", pos) end
    return v
end

-- v itself, or nil for JSON null.
function Codec.Value(v)
    if v == Codec.NULL then return nil end
    return v
end

local function EncodeString(s)
    s = strgsub(s, '[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return strformat("\\u%04x", strbyte(c))
    end)
    return '"' .. s .. '"'
end

local function IsArray(t)
    if rawget(t, 1) ~= nil then return true end
    return next(t) == nil
end

local function Encode(v, out, depth)
    if depth > MAX_DEPTH then error("nested too deep", 0) end
    local tv = type(v)
    if v == nil or v == Codec.NULL then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"
        elseif v == floor(v) and v > -1e15 and v < 1e15 then
            out[#out + 1] = strformat("%d", v)
        else
            out[#out + 1] = strformat("%.14g", v)
        end
    elseif tv == "string" then
        out[#out + 1] = EncodeString(v)
    elseif tv == "table" then
        if IsArray(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                Encode(v[i], out, depth + 1)
            end
            out[#out + 1] = "]"
        else
            -- objects: the names sorted, so the same data always gives the same text
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            tsort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = EncodeString(k)
                out[#out + 1] = ":"
                local value = v[k]
                if value == nil then value = v[tonumber(k)] end
                Encode(value, out, depth + 1)
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "null"
    end
end

-- Lua value -> JSON text. Tables with [1] (or empty ones) are arrays; put Codec.NULL in an array's gaps.
function Codec.JSONEncode(v)
    local out = {}
    Encode(v, out, 0)
    return tconcat(out)
end

---------------------------------------------------------------------------
-- base64 (standard "+/" and URL-safe "-_"; decoding accepts both and ignores padding / white space)
---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_DEC = {}
for i = 1, 64 do B64_DEC[strbyte(B64, i)] = i - 1 end
B64_DEC[strbyte("-")] = 62
B64_DEC[strbyte("_")] = 63

-- bytes: array of numbers 0..255 -> text. urlSafe: "-_" and no padding.
function Codec.Base64Encode(bytes, urlSafe)
    local out, n = {}, #bytes
    for i = 1, n, 3 do
        local a, b, c = bytes[i], bytes[i + 1], bytes[i + 2]
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2 = floor(v / 262144) % 64, floor(v / 4096) % 64
        local c3, c4 = floor(v / 64) % 64, v % 64
        out[#out + 1] = strsub(B64, c1 + 1, c1 + 1)
        out[#out + 1] = strsub(B64, c2 + 1, c2 + 1)
        out[#out + 1] = b and strsub(B64, c3 + 1, c3 + 1) or "="
        out[#out + 1] = c and strsub(B64, c4 + 1, c4 + 1) or "="
    end
    local s = tconcat(out)
    if urlSafe then
        s = strgsub(strgsub(strgsub(s, "%+", "-"), "/", "_"), "=+$", "")
    end
    return s
end

-- text -> array of bytes, or nil, message.
function Codec.Base64Decode(text)
    if type(text) ~= "string" then return nil, "no text" end
    local vals = {}
    for i = 1, #text do
        local c = strbyte(text, i)
        local v = B64_DEC[c]
        if v then
            vals[#vals + 1] = v
        elseif c == 61 or c == 32 or c == 9 or c == 10 or c == 13 then   -- = and white space
        else
            return nil, "not base64"
        end
    end
    local bytes = {}
    for i = 1, #vals, 4 do
        local a, b, c, d = vals[i], vals[i + 1], vals[i + 2], vals[i + 3]
        if not b then break end
        local v = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        bytes[#bytes + 1] = floor(v / 65536) % 256
        if c then bytes[#bytes + 1] = floor(v / 256) % 256 end
        if d then bytes[#bytes + 1] = v % 256 end
    end
    return bytes
end

---------------------------------------------------------------------------
-- CSV (quotes with "" inside, line breaks inside quotes, \r\n or \n rows)
---------------------------------------------------------------------------

-- text -> array of rows (arrays of strings). maxRows caps the work on huge pastes.
function Codec.ParseCSV(text, maxRows)
    local rows, row = {}, {}
    if type(text) ~= "string" then return rows end
    if #text > MAX_TEXT then text = strsub(text, 1, MAX_TEXT) end
    maxRows = maxRows or 200000
    local pos, len = 1, #text
    if strsub(text, 1, 3) == "\239\187\191" then pos = 4 end   -- UTF-8 byte order mark
    while pos <= len do
        local field
        if strbyte(text, pos) == 34 then
            local buf, p = {}, pos + 1
            while true do
                local q = strfind(text, '"', p, true)
                if not q then
                    buf[#buf + 1] = strsub(text, p)
                    pos = len + 1
                    break
                end
                buf[#buf + 1] = strsub(text, p, q - 1)
                if strbyte(text, q + 1) == 34 then
                    buf[#buf + 1] = '"'
                    p = q + 2
                else
                    pos = q + 1
                    break
                end
            end
            field = tconcat(buf)
            -- anything between the closing quote and the next separator is dropped
            pos = strfind(text, "[,\r\n]", pos) or (len + 1)
        else
            local d = strfind(text, "[,\r\n]", pos) or (len + 1)
            field = strsub(text, pos, d - 1)
            pos = d
        end
        row[#row + 1] = field
        local c = strbyte(text, pos)
        if c == 44 then   -- ,
            pos = pos + 1
            if pos > len then row[#row + 1] = "" end
        else
            rows[#rows + 1] = row
            row = {}
            if c == 13 and strbyte(text, pos + 1) == 10 then pos = pos + 2 else pos = pos + 1 end
            if #rows >= maxRows then return rows end
        end
    end
    if #row > 0 then rows[#rows + 1] = row end
    return rows
end
