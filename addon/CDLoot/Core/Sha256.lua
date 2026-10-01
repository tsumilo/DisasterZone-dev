if CDLootBoot and CDLootBoot.Run("Core/Sha256.lua", ...) then return end -- CDLoot: SHA-256 (FIPS 180-4) in plain Lua 5.1 + the client's bit library.
-- Used only by Core/Patch.lua to authenticate in-game updates. Incremental (New / Update / Final) so a long
-- input can be hashed in slices across frames; Sum() is the one-shot form. Digests are 32-byte binary strings.
-- Additions are reduced with "% 2^32" and rotations are done arithmetically, so the code does not depend on
-- whether the bit library returns signed or unsigned results.
local addonName, ns = ...

local Sha = {}
ns.Sha256 = Sha

local band, bxor, bnot, rshift = bit.band, bit.bxor, bit.bnot, bit.rshift
local byte, char, sub, rep, format = string.byte, string.char, string.sub, string.rep, string.format
local floor = math.floor

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local W = {}   -- message schedule, reused between blocks

-- Mixes the 64-byte block of s that starts at pos into the state H (an array of 8 words).
local function Compress(H, s, pos)
    local w = W
    for i = 1, 16 do
        local a, b, c, d = byte(s, pos, pos + 3)
        w[i] = a * 16777216 + b * 65536 + c * 256 + d
        pos = pos + 4
    end
    for i = 17, 64 do
        local x, y = w[i - 15], w[i - 2]
        local s0 = bxor(rshift(x, 7) + (x % 128) * 33554432, rshift(x, 18) + (x % 262144) * 16384, rshift(x, 3))
        local s1 = bxor(rshift(y, 17) + (y % 131072) * 32768, rshift(y, 19) + (y % 524288) * 8192, rshift(y, 10))
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for i = 1, 64 do
        local S1 = bxor(rshift(e, 6) + (e % 64) * 67108864, rshift(e, 11) + (e % 2048) * 2097152,
            rshift(e, 25) + (e % 33554432) * 128)
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = h + S1 + ch + K[i] + w[i]
        local S0 = bxor(rshift(a, 2) + (a % 4) * 1073741824, rshift(a, 13) + (a % 8192) * 524288,
            rshift(a, 22) + (a % 4194304) * 1024)
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        h, g, f = g, f, e
        e = (d + t1) % 4294967296
        d, c, b = c, b, a
        a = (t1 + S0 + maj) % 4294967296
    end
    H[1] = (H[1] + a) % 4294967296
    H[2] = (H[2] + b) % 4294967296
    H[3] = (H[3] + c) % 4294967296
    H[4] = (H[4] + d) % 4294967296
    H[5] = (H[5] + e) % 4294967296
    H[6] = (H[6] + f) % 4294967296
    H[7] = (H[7] + g) % 4294967296
    H[8] = (H[8] + h) % 4294967296
end

function Sha.New()
    return {
        H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
        buf = "",    -- bytes not yet hashed (< 64)
        len = 0,     -- total bytes fed
    }
end

function Sha.Update(st, s)
    local n = #s
    if n == 0 then return end
    st.len = st.len + n
    local pos = 1
    local buf = st.buf
    if buf ~= "" then
        local need = 64 - #buf
        if n < need then
            st.buf = buf .. s
            return
        end
        Compress(st.H, buf .. sub(s, 1, need), 1)
        pos = need + 1
        st.buf = ""
    end
    local H = st.H
    while pos + 63 <= n do
        Compress(H, s, pos)
        pos = pos + 64
    end
    if pos <= n then
        st.buf = sub(s, pos)
    end
end

local function Word(x)
    return char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
end

-- Returns the 32-byte digest. The state must not be used afterwards.
function Sha.Final(st)
    local len = st.len
    local buf = st.buf
    local padLen = 55 - (#buf % 64)
    if padLen < 0 then padLen = padLen + 64 end
    -- message length in bits as a 64-bit big-endian number (inputs here are far below 2^53 bits)
    local bitsHi = floor(len / 536870912)
    local bitsLo = (len % 536870912) * 8
    local tail = buf .. "\128" .. rep("\0", padLen) .. Word(bitsHi) .. Word(bitsLo)
    local H = st.H
    for pos = 1, #tail, 64 do
        Compress(H, tail, pos)
    end
    return Word(H[1]) .. Word(H[2]) .. Word(H[3]) .. Word(H[4]) .. Word(H[5]) .. Word(H[6]) .. Word(H[7]) .. Word(H[8])
end

function Sha.Sum(s)
    local st = Sha.New()
    Sha.Update(st, s)
    return Sha.Final(st)
end

function Sha.Hex(digest)
    return (digest:gsub(".", function(c) return format("%02x", byte(c)) end))
end

-- Inverse of Hex; nil for anything that is not an even number of hex digits.
function Sha.FromHex(hex)
    if type(hex) ~= "string" or #hex % 2 ~= 0 or hex:find("[^0-9a-fA-F]") then return nil end
    return (hex:gsub("..", function(h) return char(tonumber(h, 16)) end))
end
