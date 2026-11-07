--!strict
-- Deterministic, isolated pseudo-random streams for the MISSION server. Pure Luau: no Roblox services, no
-- `Random`, no `math.random`. Every stream depends only on its own (seed, label) pair, never on unrelated calls.
-- This is NOT cryptographic. The seed is a server-only value and must never be sent to clients.
--
-- FROZEN ALGORITHM. Every constant and step below determines every mission's configuration. Changing any of
-- them silently changes the outcome for existing seeds, so the golden vectors in
-- tests/server_shared/SeededRandom.spec.lua (computed with an independent reference implementation) must be
-- regenerated and the change reviewed. All arithmetic is exact: intermediate values stay below 2^53 (Luau numbers
-- are doubles) and shifts use `bit32` (32-bit, logical).
--
--   hash32(text)   FNV-1a 32 bit: h = 0x811C9DC5; for each byte: h = h XOR byte; h = h * 0x01000193 (mod 2^32)
--   fmix32(h)      MurmurHash3 finalizer: h ^= h >> 16; h *= 0x85EBCA6B; h ^= h >> 13;
--                  h *= 0xC2B2AE35; h ^= h >> 16 (multiplications mod 2^32)
--   initial state  s = fmix32(hash32(label) XOR fmix32(seed)); if s == 0 then s = 1
--                  (xorshift32 must never hold state 0)
--   step           x ^= x << 13; x ^= x >> 17; x ^= x << 5 (all mod 2^32). The output is the new state.
--
-- xorshift32 (13, 17, 5) visits every non-zero 32-bit value exactly once per period: the output domain is
-- 1 .. 2^32 - 1 (4294967295 values; 0 is never produced) and the period is 2^32 - 1.
--
-- nextInteger(min, max) uses rejection sampling over that actual domain, so every value of a range is exactly
-- equally likely. Supported range size: 1 .. 4294967295 (2^32 - 1). A range of 2^32 values is NOT supported
-- because the generator cannot produce 2^32 distinct outputs. Each call consumes at least one output
-- (a range of one value consumes one output and returns `min`).

local SeededRandom = {}

SeededRandom.MinSeed = 1
SeededRandom.MaxSeed = 2147483647 -- 2^31 - 1
SeededRandom.MaxLabelLength = 64
SeededRandom.MaxRangeSize = 4294967295 -- 2^32 - 1: the number of distinct xorshift32 outputs

local TWO_POW_32 = 4294967296
local OUTPUT_DOMAIN_SIZE = 4294967295
local MAX_SAFE_INTEGER = 9007199254740991 -- 2^53 - 1
local FNV_OFFSET_BASIS = 2166136261 -- 0x811C9DC5
local FNV_PRIME = 16777619 -- 0x01000193
local FMIX_MULTIPLIER_1 = 2246822507 -- 0x85EBCA6B
local FMIX_MULTIPLIER_2 = 3266489909 -- 0xC2B2AE35

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value >= min and value <= max and value % 1 == 0
end

function SeededRandom.isValidSeed(value: any): boolean
    return isInteger(value, SeededRandom.MinSeed, SeededRandom.MaxSeed)
end

function SeededRandom.isValidLabel(value: any): boolean
    return type(value) == "string"
        and #value >= 1
        and #value <= SeededRandom.MaxLabelLength
        and string.match(value, "^[%w_%.%-]+$") ~= nil
end

-- (a * b) mod 2^32 for a, b in [0, 2^32). Splitting b into 16-bit halves keeps every product below 2^48.
local function mul32(a: number, b: number): number
    local low = b % 65536
    local high = math.floor(b / 65536)
    return (a * low + bit32.lshift((a * high) % 65536, 16)) % TWO_POW_32
end

-- Exposed for the known-answer tests; not part of the gameplay API.
function SeededRandom.hash32(text: string): number
    local hash = FNV_OFFSET_BASIS
    for index = 1, #text do
        hash = bit32.bxor(hash, string.byte(text, index))
        hash = mul32(hash, FNV_PRIME)
    end
    return hash
end

-- Exposed for the known-answer tests; not part of the gameplay API.
function SeededRandom.fmix32(value: number): number
    local hash = bit32.bxor(value, bit32.rshift(value, 16))
    hash = mul32(hash, FMIX_MULTIPLIER_1)
    hash = bit32.bxor(hash, bit32.rshift(hash, 13))
    hash = mul32(hash, FMIX_MULTIPLIER_2)
    return bit32.bxor(hash, bit32.rshift(hash, 16))
end

type StreamData = { _state: number }

local Stream = {}
Stream.__index = Stream

export type Stream = typeof(setmetatable({} :: StreamData, Stream))

-- Creates an independent stream. Errors on an invalid seed or label (callers validate first). Use a unique,
-- namespaced label per consumer (for example "config.location") so streams never share a sequence by accident.
function SeededRandom.new(seed: any, label: any): Stream
    if not SeededRandom.isValidSeed(seed) then
        error("SeededRandom.new: seed must be an integer in [1, 2147483647]", 2)
    end
    if not SeededRandom.isValidLabel(label) then
        error("SeededRandom.new: label must be 1-64 characters of [A-Za-z0-9_.-]", 2)
    end
    local state = SeededRandom.fmix32(bit32.bxor(SeededRandom.hash32(label), SeededRandom.fmix32(seed)))
    if state == 0 then
        state = 1
    end
    return setmetatable({ _state = state }, Stream)
end

-- Raw xorshift32 output in [1, 2^32 - 1]; never 0.
function Stream.nextUInt32(self: Stream): number
    local x = self._state
    x = bit32.bxor(x, bit32.lshift(x, 13))
    x = bit32.bxor(x, bit32.rshift(x, 17))
    x = bit32.bxor(x, bit32.lshift(x, 5))
    self._state = x
    return x
end

-- Uniform integer in [min, max] (inclusive). Rejection sampling over the real output domain: outputs
-- 1 .. 2^32 - 1 map to v = output - 1 in [0, 2^32 - 2]; v is accepted only below the largest multiple of the
-- range size, so there is no modulo bias. Termination: every draw is accepted with probability above 1/2 and
-- the generator cycles through all outputs, so an accepted value always appears within one period.
function Stream.nextInteger(self: Stream, min: any, max: any): number
    if not isInteger(min, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER) or not isInteger(max, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER) then
        error("SeededRandom.nextInteger: min and max must be integers", 2)
    end
    if min > max then
        error("SeededRandom.nextInteger: min must not exceed max", 2)
    end
    local rangeSize = max - min + 1
    if rangeSize > SeededRandom.MaxRangeSize then
        error("SeededRandom.nextInteger: range size must not exceed 4294967295", 2)
    end
    local limit = OUTPUT_DOMAIN_SIZE - OUTPUT_DOMAIN_SIZE % rangeSize
    while true do
        local value = self:nextUInt32() - 1
        if value < limit then
            return min + value % rangeSize
        end
    end
end

return SeededRandom
