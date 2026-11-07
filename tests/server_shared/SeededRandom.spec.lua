--!strict
local Harness = require("../Harness")
local SeededRandom = require("../../src/server_shared/MissionConfig/SeededRandom")

local test, expectTrue, expectFalse, expectEqual, expectError = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual, Harness.expectError

-- GOLDEN VECTORS. Every expected number below was computed with an independent reference implementation
-- (Python, exact 64-bit integer arithmetic with masks; it does not use the decomposed multiplication of the Luau
-- module). If one of these tests fails, the deterministic algorithm changed: do not just update the numbers,
-- review the change (every mission configuration derived from an existing seed would change).

local function rawDraws(seed: number, label: string, count: number): { number }
    local stream = SeededRandom.new(seed, label)
    local values: { number } = {}
    for index = 1, count do
        values[index] = stream:nextUInt32()
    end
    return values
end

local function expectSequence(actual: { number }, expected: { number }, name: string)
    expectEqual(#actual, #expected, name .. " length")
    for index = 1, #expected do
        expectEqual(actual[index], expected[index], name .. " #" .. tostring(index))
    end
end

local function integerDraws(seed: number, label: string, min: number, max: number, count: number): { number }
    local stream = SeededRandom.new(seed, label)
    local values: { number } = {}
    for index = 1, count do
        values[index] = stream:nextInteger(min, max)
    end
    return values
end

test("constants document the supported domain", function()
    expectEqual(SeededRandom.MinSeed, 1)
    expectEqual(SeededRandom.MaxSeed, 2147483647)
    expectEqual(SeededRandom.MaxLabelLength, 64)
    expectEqual(SeededRandom.MaxRangeSize, 4294967295, "xorshift32 has 2^32 - 1 distinct outputs, not 2^32")
end)

test("hash32 matches the published FNV-1a 32-bit vectors", function()
    expectEqual(SeededRandom.hash32(""), 0x811C9DC5)
    expectEqual(SeededRandom.hash32("a"), 0xE40C292C)
    expectEqual(SeededRandom.hash32("foobar"), 0xBF9CF968)
end)

test("hash32 of the production stage label", function()
    expectEqual(SeededRandom.hash32("config.location"), 0xD61F958C)
end)

test("fmix32 matches reference vectors", function()
    expectEqual(SeededRandom.fmix32(0), 0)
    expectEqual(SeededRandom.fmix32(1), 0x514E28B7)
    expectEqual(SeededRandom.fmix32(0x12345678), 0xE37CD1BC)
    expectEqual(SeededRandom.fmix32(0xFFFFFFFF), 0x81F16F39)
    expectEqual(SeededRandom.fmix32(2147483647), 0xF9CC0EA8)
end)

test("golden raw outputs: seed 1, config.location", function()
    expectSequence(
        rawDraws(1, "config.location", 8),
        { 1046320254, 378556663, 2371446960, 2846370423, 808787076, 3877601174, 358270944, 4185573203 },
        "stream"
    )
end)

test("golden raw outputs: seed 2, config.location", function()
    expectSequence(
        rawDraws(2, "config.location", 8),
        { 4060144314, 615344049, 2201710620, 1244157568, 1610000764, 3522489872, 3404712299, 1268031946 },
        "stream"
    )
end)

test("golden raw outputs: seed 1, evidence.placement (same seed, other label)", function()
    expectSequence(
        rawDraws(1, "evidence.placement", 8),
        { 2630103405, 1205477177, 2207947207, 3303023446, 3520782707, 862729897, 43041493, 1132960176 },
        "stream"
    )
end)

test("golden raw outputs: seed 12345, label a", function()
    expectSequence(
        rawDraws(12345, "a", 8),
        { 4159568416, 1569853684, 3995040114, 655754410, 400939531, 943286137, 2384457554, 222774184 },
        "stream"
    )
end)

test("golden raw outputs: seed 1394820617, config.location", function()
    expectSequence(
        rawDraws(1394820617, "config.location", 8),
        { 977818404, 901098866, 2205024927, 612737825, 2363007345, 2251254858, 526723769, 4235764640 },
        "stream"
    )
end)

test("golden raw outputs: maximum seed, event.schedule", function()
    expectSequence(
        rawDraws(2147483647, "event.schedule", 8),
        { 2164049506, 505529658, 4132723033, 3533159206, 2610844223, 1793769651, 1835761773, 2980312350 },
        "stream"
    )
end)

test("a zero initial state is replaced by 1 (xorshift32 must never hold 0)", function()
    -- fmix32(hash32(label) XOR fmix32(seed)) == 0 for this pair, found by inverting fmix32 in the reference.
    -- Classic xorshift32 from state 1 starts 270369, 67634689.
    expectSequence(rawDraws(428258971, "config.location", 4), { 270369, 67634689, 2647435461, 307599695 }, "stream")
end)

test("golden nextInteger: 1..3", function()
    expectSequence(integerDraws(1, "config.location", 1, 3, 10), { 3, 1, 3, 3, 3, 2, 3, 2, 1, 3 }, "draws")
end)

test("golden nextInteger: 1..1000 with the maximum seed", function()
    expectSequence(integerDraws(2147483647, "config.location", 1, 1000, 10), { 679, 88, 799, 936, 836, 972, 171, 121, 239, 653 }, "draws")
end)

test("golden nextInteger: negative ranges", function()
    expectSequence(integerDraws(12345, "a", -5, 5, 10), { -3, -3, 4, -3, -3, -4, 0, 0, -4, 1 }, "draws")
end)

test("a range of one value returns min and consumes one output", function()
    expectSequence(integerDraws(1, "config.location", 1, 1, 5), { 1, 1, 1, 1, 1 }, "draws")
    local stream = SeededRandom.new(1, "config.location")
    expectEqual(stream:nextInteger(7, 7), 7)
    expectEqual(stream:nextUInt32(), 378556663, "second raw output of the stream")
end)

test("the largest supported range (2^32 - 1 values) never rejects and maps output to output", function()
    expectSequence(
        integerDraws(1, "config.location", 1, 4294967295, 4),
        { 1046320254, 378556663, 2371446960, 2846370423 },
        "draws"
    )
end)

test("rejection sampling: range above half of the domain (2147483649 values)", function()
    expectSequence(
        integerDraws(2, "config.location", 1, 2147483649, 6),
        { 615344049, 1244157568, 1610000764, 1268031946, 706497948, 837254053 },
        "draws"
    )
    -- The first raw output (4060144314) lies above the accepted limit and is skipped: the first result consumed
    -- two outputs, so the next raw output is the third one of the stream.
    local stream = SeededRandom.new(2, "config.location")
    expectEqual(stream:nextInteger(1, 2147483649), 615344049)
    expectEqual(stream:nextUInt32(), 2201710620)
end)

test("rejection sampling: range of 3000000000 values", function()
    expectSequence(
        integerDraws(2, "config.location", 1, 3000000000, 6),
        { 615344049, 2201710620, 1244157568, 1610000764, 1268031946, 706497948 },
        "draws"
    )
end)

test("range of 2^32 values is rejected: the generator cannot produce 2^32 distinct outputs", function()
    local stream = SeededRandom.new(1, "config.location")
    expectError(function()
        stream:nextInteger(1, 4294967296)
    end, "2^32 values")
    expectError(function()
        stream:nextInteger(0, 4294967295)
    end, "0 .. 2^32 - 1 is 2^32 values")
    expectError(function()
        stream:nextInteger(-9007199254740991, 9007199254740991)
    end, "huge range")
    expectEqual(stream:nextInteger(0, 4294967294), 1046320253, "2^32 - 1 values starting at 0 is allowed")
end)

test("nextInteger rejects invalid bounds", function()
    local stream = SeededRandom.new(1, "config.location")
    expectError(function()
        stream:nextInteger(5, 4)
    end, "min > max")
    local invalid: { any } = { 1.5, 0 / 0, math.huge, -math.huge, "1", true, 9007199254740992 }
    for _, value in ipairs(invalid) do
        expectError(function()
            stream:nextInteger(value, 10)
        end, "invalid min " .. tostring(value))
        expectError(function()
            stream:nextInteger(1, value)
        end, "invalid max " .. tostring(value))
    end
    expectError(function()
        (stream :: any):nextInteger(nil, 3)
    end, "nil min")
    expectError(function()
        (stream :: any):nextInteger(1)
    end, "missing max")
end)

test("nextInteger stays within bounds across ranges", function()
    local ranges = { { 1, 1 }, { 1, 2 }, { 1, 3 }, { -5, 5 }, { 0, 1 }, { 1, 1000 }, { -1000000, 1000000 }, { 1, 2147483649 } }
    for _, range in ipairs(ranges) do
        local stream = SeededRandom.new(97, "config.location")
        for _ = 1, 5000 do
            local value = stream:nextInteger(range[1], range[2])
            if value < range[1] or value > range[2] or value % 1 ~= 0 then
                error(string.format("value %s outside [%d, %d]", tostring(value), range[1], range[2]))
            end
        end
    end
end)

test("raw outputs are never zero and stay below 2^32", function()
    local streams = { SeededRandom.new(1, "a"), SeededRandom.new(2147483647, "config.location"), SeededRandom.new(428258971, "config.location") }
    for _, stream in ipairs(streams) do
        for _ = 1, 20000 do
            local value = stream:nextUInt32()
            if value < 1 or value > 4294967295 or value % 1 ~= 0 then
                error("raw output out of domain: " .. tostring(value))
            end
        end
    end
end)

test("the same seed and label always reproduce the same sequence", function()
    local first = rawDraws(77, "config.location", 100)
    local second = rawDraws(77, "config.location", 100)
    expectSequence(second, first, "repeat")
end)

test("streams are isolated: interleaving or consuming one does not affect another", function()
    local aAlone = rawDraws(5, "config.location", 20)
    local bAlone = rawDraws(5, "evidence.placement", 20)
    local a = SeededRandom.new(5, "config.location")
    local b = SeededRandom.new(5, "evidence.placement")
    local aValues: { number } = {}
    local bValues: { number } = {}
    for index = 1, 20 do
        aValues[index] = a:nextUInt32()
        if index % 2 == 0 then
            bValues[#bValues + 1] = b:nextUInt32()
        end
    end
    while #bValues < 20 do
        bValues[#bValues + 1] = b:nextUInt32()
    end
    expectSequence(aValues, aAlone, "stream a")
    expectSequence(bValues, bAlone, "stream b")
    -- Creating many other streams in between changes nothing either.
    for index = 1, 50 do
        SeededRandom.new(index, "noise.stream"):nextUInt32()
    end
    expectSequence(rawDraws(5, "config.location", 20), aAlone, "after unrelated streams")
end)

test("the global random generator has no influence", function()
    math.randomseed(1)
    local first = rawDraws(123, "config.location", 10)
    math.randomseed(999)
    for _ = 1, 100 do
        math.random()
    end
    expectSequence(rawDraws(123, "config.location", 10), first, "after global RNG use")
end)

test("known vectors differ across seeds and labels", function()
    -- Specific, listed tuples only: this is not a claim that no two inputs can ever collide.
    local a = rawDraws(1, "config.location", 1)[1]
    local b = rawDraws(2, "config.location", 1)[1]
    local c = rawDraws(1, "evidence.placement", 1)[1]
    expectTrue(a ~= b and a ~= c and b ~= c)
end)

test("distribution sanity on fixed inputs (deterministic, not flaky)", function()
    local stream = SeededRandom.new(1, "config.location")
    local counts = { 0, 0, 0, 0, 0, 0 }
    for _ = 1, 6000 do
        local value = stream:nextInteger(1, 6)
        counts[value] += 1
    end
    for face = 1, 6 do
        expectTrue(counts[face] >= 850 and counts[face] <= 1150, "face " .. face .. " count " .. counts[face])
    end

    -- A range above half the domain exercises the rejection loop heavily; the halves must stay balanced.
    local wide = SeededRandom.new(1, "config.location")
    local lower = 0
    for _ = 1, 4000 do
        if wide:nextInteger(1, 2147483649) <= 1073741825 then
            lower += 1
        end
    end
    expectTrue(lower >= 1800 and lower <= 2200, "lower half count " .. lower)
end)

test("new validates seed and label", function()
    local badSeeds: { any } = { 0, -1, 2147483648, 4294967295, 1.5, 0 / 0, math.huge, -math.huge, "1", true, {} }
    for _, seed in ipairs(badSeeds) do
        expectError(function()
            SeededRandom.new(seed, "config.location")
        end, "seed " .. tostring(seed))
    end
    expectError(function()
        (SeededRandom :: any).new(nil, "config.location")
    end, "nil seed")
    local badLabels: { any } = { "", string.rep("a", 65), "has space", "slash/label", "ünï", 1, true, {} }
    for _, label in ipairs(badLabels) do
        expectError(function()
            SeededRandom.new(1, label)
        end, "label " .. tostring(label))
    end
    expectError(function()
        (SeededRandom :: any).new(1, nil)
    end, "nil label")
end)

test("isValidSeed and isValidLabel", function()
    for _, seed in ipairs({ 1, 2, 12345, 2147483647 }) do
        expectTrue(SeededRandom.isValidSeed(seed), "seed " .. seed)
    end
    local badSeeds: { any } = { 0, -1, 2147483648, 1.5, 0 / 0, math.huge, "1", true }
    for _, seed in ipairs(badSeeds) do
        expectFalse(SeededRandom.isValidSeed(seed), "seed " .. tostring(seed))
    end
    expectFalse(SeededRandom.isValidSeed(nil))
    for _, label in ipairs({ "a", "config.location", "A_b-c.1", string.rep("x", 64) }) do
        expectTrue(SeededRandom.isValidLabel(label), "label " .. label)
    end
    expectFalse(SeededRandom.isValidLabel(""))
    expectFalse(SeededRandom.isValidLabel(string.rep("x", 65)))
    expectFalse(SeededRandom.isValidLabel("a b"))
    expectFalse(SeededRandom.isValidLabel(nil))
    expectFalse(SeededRandom.isValidLabel(5))
end)
