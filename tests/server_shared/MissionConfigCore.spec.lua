--!strict
local Harness = require("../Harness")
local MissionConfigCore = require("../../src/server_shared/MissionConfig/MissionConfigCore")
local SeededRandom = require("../../src/server_shared/MissionConfig/SeededRandom")
local MissionContent = require("../../src/mission/server/MissionConfig/MissionContent")

local test, expectTrue, expectFalse, expectEqual, expectError = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual, Harness.expectError

-- Selection vectors below (which location a seed picks) were computed with the same independent reference
-- implementation as the SeededRandom golden vectors: ids sorted ascending, then
-- sortedIds[ stream(seed, "config.location"):nextInteger(1, count) ].

local function locationsOf(ids: { string }): { { id: string } }
    local locations: { { id: string } } = {}
    for index, id in ipairs(ids) do
        locations[index] = { id = id }
    end
    return locations
end

local function content(ids: { string }, version: number?): any
    return { version = version or 1, locations = locationsOf(ids) }
end

local function input(overrides: { [string]: any }?): { [string]: any }
    local data: { [string]: any } = {
        seed = 1,
        missionId = "mission-1",
        missionType = "DEFAULT",
        content = content({ "WOODS", "ASYLUM", "MANOR" }),
    }
    for key, value in pairs(overrides or {}) do
        if value == "__nil__" then
            data[key] = nil -- "__nil__" removes the field
        else
            data[key] = value
        end
    end
    return data
end

local function create(data: any): (boolean, any)
    return MissionConfigCore.create(data, SeededRandom)
end

local function deepClone(value: any): any
    if type(value) ~= "table" then
        return value
    end
    local copy: { [any]: any } = {}
    for key, item in pairs(value) do
        copy[key] = deepClone(item)
    end
    return copy
end

local function deepEqual(a: any, b: any): boolean
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not deepEqual(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

local function expectCode(ok: boolean, code: any, expected: string, label: string?)
    expectFalse(ok, (label or "create") .. " should fail")
    expectEqual(code, expected, label)
end

local function selected(seed: number, ids: { string }): string
    local ok, config = create(input({ seed = seed, content = content(ids) }))
    expectTrue(ok, "create seed " .. tostring(seed))
    return config.locationId
end

-- validateContent -------------------------------------------------------------------------------------------------

test("validateContent accepts valid content", function()
    expectTrue((MissionConfigCore.validateContent(content({ "ASYLUM" }))))
    expectTrue((MissionConfigCore.validateContent(content({ "ASYLUM", "MANOR", "WOODS" }, 2147483647))))
    expectTrue((MissionConfigCore.validateContent(content({ "A", "A1_B2", "A" .. string.rep("Z", 31) }))))
end)

test("validateContent accepts 64 locations and rejects 65", function()
    local ids: { string } = {}
    for index = 1, 64 do
        ids[index] = "LOC_" .. tostring(index)
    end
    expectTrue((MissionConfigCore.validateContent(content(ids))))
    ids[65] = "LOC_65"
    local ok, code = MissionConfigCore.validateContent(content(ids))
    expectCode(ok, code, "invalid_locations")
end)

test("validateContent rejects non-plain content tables", function()
    local bad: { any } = { "x", 5, true }
    for _, value in ipairs(bad) do
        local ok, code = MissionConfigCore.validateContent(value)
        expectCode(ok, code, "invalid_content_table", tostring(value))
    end
    local ok, code = MissionConfigCore.validateContent({ 1, 2 })
    expectCode(ok, code, "unexpected_content_field", "array")
    ok, code = MissionConfigCore.validateContent(nil)
    expectCode(ok, code, "invalid_content_table", "nil")
    ok, code = MissionConfigCore.validateContent(setmetatable(content({ "ASYLUM" }), {}))
    expectCode(ok, code, "invalid_content_table", "metatable")
end)

test("validateContent rejects unexpected content fields", function()
    local data = content({ "ASYLUM" })
    data.entities = {}
    local ok, code = MissionConfigCore.validateContent(data)
    expectCode(ok, code, "unexpected_content_field")
end)

test("validateContent rejects invalid versions", function()
    local bad: { any } = { 0, -1, 1.5, "1", 2147483648, 0 / 0, math.huge, true }
    for _, version in ipairs(bad) do
        local ok, code = MissionConfigCore.validateContent({ version = version, locations = locationsOf({ "ASYLUM" }) })
        expectCode(ok, code, "invalid_content_version", tostring(version))
    end
    local ok, code = MissionConfigCore.validateContent({ locations = locationsOf({ "ASYLUM" }) })
    expectCode(ok, code, "invalid_content_version", "missing version")
end)

test("validateContent rejects malformed location lists", function()
    local function check(locations: any, expected: string, label: string)
        local ok, code = MissionConfigCore.validateContent({ version = 1, locations = locations })
        expectCode(ok, code, expected, label)
    end
    check(nil, "invalid_locations", "missing")
    check("ASYLUM", "invalid_locations", "string")
    check({}, "empty_locations", "empty")
    check({ [1] = { id = "ASYLUM" }, [3] = { id = "MANOR" } }, "invalid_locations", "hole")
    check({ ASYLUM = { id = "ASYLUM" } }, "invalid_locations", "dictionary keyed by id")
    check({ { id = "ASYLUM" }, extra = true }, "invalid_locations", "extra key")
    check(setmetatable({ { id = "ASYLUM" } }, {}), "invalid_locations", "metatable")
    check({ [0] = { id = "ASYLUM" } }, "invalid_locations", "zero index")
end)

test("validateContent rejects malformed location entries", function()
    local function check(entry: any, expected: string, label: string)
        local ok, code = MissionConfigCore.validateContent({ version = 1, locations = { entry } })
        expectCode(ok, code, expected, label)
    end
    check("ASYLUM", "invalid_location_entry", "string entry")
    check(5, "invalid_location_entry", "number entry")
    check(setmetatable({ id = "ASYLUM" }, {}), "invalid_location_entry", "metatable")
    check({ id = "ASYLUM", name = "The Asylum" }, "unexpected_location_field", "extra field")
    check({ id = "ASYLUM", [1] = "x" }, "unexpected_location_field", "numeric key")
    check({}, "invalid_location_id", "missing id")
end)

test("validateContent rejects invalid or duplicate ids", function()
    local badIds: { any } = { "asylum", "", string.rep("A", 33), "1ABC", "_ABC", "A-B", "A B", "A.B", 5, true, {} }
    for _, id in ipairs(badIds) do
        local ok, code = MissionConfigCore.validateContent({ version = 1, locations = { { id = id } } })
        expectCode(ok, code, "invalid_location_id", tostring(id))
    end
    local ok, code = MissionConfigCore.validateContent(content({ "ASYLUM", "MANOR", "ASYLUM" }))
    expectCode(ok, code, "duplicate_location_id")
end)

test("validateContent does not modify its input", function()
    local data = content({ "WOODS", "ASYLUM", "MANOR" })
    local before = deepClone(data)
    MissionConfigCore.validateContent(data)
    expectTrue(deepEqual(data, before))
    expectEqual(data.locations[1].id, "WOODS", "order untouched")
end)

-- create: result shape -------------------------------------------------------------------------------------------

test("create returns a frozen configuration with exactly the documented fields", function()
    local ok, config = create(input({ seed = 12345, missionId = "abc-123", missionType = "DEFAULT", content = content({ "ASYLUM" }, 7) }))
    expectTrue(ok)
    expectTrue(table.isfrozen(config), "config is frozen")
    local fields = 0
    for _ in pairs(config) do
        fields += 1
    end
    expectEqual(fields, 6, "field count")
    expectEqual(config.schemaVersion, MissionConfigCore.SchemaVersion)
    expectEqual(config.schemaVersion, 1)
    expectEqual(config.contentVersion, 7)
    expectEqual(config.missionId, "abc-123")
    expectEqual(config.missionType, "DEFAULT")
    expectEqual(config.seed, 12345)
    expectEqual(config.locationId, "ASYLUM")
    expectError(function()
        (config :: any).extra = 1
    end, "a frozen configuration rejects new fields")
end)

test("create is deterministic for identical inputs", function()
    local _, first = create(input({ seed = 424242 }))
    local _, second = create(input({ seed = 424242 }))
    expectTrue(deepEqual(first, second))
    expectTrue(first ~= second, "each call returns its own table")
end)

-- create: golden selection vectors -------------------------------------------------------------------------------

test("golden selections with three locations", function()
    local ids = { "WOODS", "ASYLUM", "MANOR" }
    local expected = {
        { 1, "WOODS" },
        { 2, "WOODS" },
        { 3, "ASYLUM" },
        { 4, "MANOR" },
        { 5, "WOODS" },
        { 6, "ASYLUM" },
        { 7, "WOODS" },
        { 8, "MANOR" },
        { 12345, "MANOR" },
        { 1394820617, "WOODS" },
        { 2147483647, "WOODS" },
    }
    for _, pair in ipairs(expected) do
        expectEqual(selected(pair[1] :: number, ids), pair[2], "seed " .. tostring(pair[1]))
    end
end)

test("golden selections with four locations", function()
    local ids = { "MANOR", "WOODS", "BASEMENT", "ASYLUM" }
    local expected = {
        { 1, "BASEMENT" },
        { 2, "BASEMENT" },
        { 3, "MANOR" },
        { 4, "WOODS" },
        { 5, "BASEMENT" },
        { 12345, "MANOR" },
        { 2147483647, "MANOR" },
    }
    for _, pair in ipairs(expected) do
        expectEqual(selected(pair[1] :: number, ids), pair[2], "seed " .. tostring(pair[1]))
    end
end)

test("selection pins the algorithm: sorted ids indexed by the config.location stream", function()
    local sorted = { "ASYLUM", "MANOR", "WOODS" }
    for _, seed in ipairs({ 1, 2, 3, 99, 31337, 2147483646 }) do
        local stream = SeededRandom.new(seed, "config.location")
        local expected = sorted[stream:nextInteger(1, 3)]
        expectEqual(selected(seed, { "WOODS", "ASYLUM", "MANOR" }), expected, "seed " .. seed)
    end
    expectEqual(MissionConfigCore.Stages.LOCATION, "config.location")
    expectTrue(table.isfrozen(MissionConfigCore.Stages))
end)

test("a single location is always selected", function()
    for _, seed in ipairs({ 1, 2, 3, 12345, 2147483647 }) do
        expectEqual(selected(seed, { "ASYLUM" }), "ASYLUM")
    end
end)

test("all locations are reachable and the spread over seeds 1..200 is pinned", function()
    local counts: { [string]: number } = { ASYLUM = 0, MANOR = 0, WOODS = 0 }
    for seed = 1, 200 do
        local id = selected(seed, { "WOODS", "ASYLUM", "MANOR" })
        counts[id] += 1
    end
    expectEqual(counts.ASYLUM, 77)
    expectEqual(counts.MANOR, 61)
    expectEqual(counts.WOODS, 62)
end)

-- create: determinism contracts ----------------------------------------------------------------------------------

test("selection does not depend on the order of the content table", function()
    local permutations = {
        { "ASYLUM", "MANOR", "WOODS" },
        { "ASYLUM", "WOODS", "MANOR" },
        { "MANOR", "ASYLUM", "WOODS" },
        { "MANOR", "WOODS", "ASYLUM" },
        { "WOODS", "ASYLUM", "MANOR" },
        { "WOODS", "MANOR", "ASYLUM" },
    }
    for seed = 1, 60 do
        local reference = selected(seed, permutations[1])
        for index = 2, #permutations do
            expectEqual(selected(seed, permutations[index]), reference, "seed " .. seed .. " permutation " .. index)
        end
    end
end)

test("other stream labels do not influence the configuration", function()
    local before = selected(77, { "ASYLUM", "MANOR", "WOODS" })
    local entity = SeededRandom.new(77, "config.entity")
    for _ = 1, 25 do
        entity:nextUInt32()
    end
    SeededRandom.new(77, "evidence.placement"):nextInteger(1, 10)
    expectEqual(selected(77, { "ASYLUM", "MANOR", "WOODS" }), before)
end)

test("create does not mutate or retain its input, plain or frozen", function()
    local data = input()
    local before = deepClone(data)
    local ok, config = create(data)
    expectTrue(ok)
    expectTrue(deepEqual(data, before), "input unchanged")
    expectEqual(data.content.locations[1].id, "WOODS", "content order unchanged")
    expectFalse(table.isfrozen(data.content), "plain content is not frozen as a side effect")
    expectFalse(table.isfrozen(data), "input is not frozen as a side effect")
    expectTrue(config ~= data and config ~= data.content)

    local frozenContent = table.freeze({ version = 1, locations = table.freeze({ table.freeze({ id = "ASYLUM" }), table.freeze({ id = "MANOR" }) }) })
    local frozenOk, frozenConfig = create(input({ content = frozenContent }))
    expectTrue(frozenOk, "frozen content is accepted")
    expectTrue(frozenConfig.locationId == "ASYLUM" or frozenConfig.locationId == "MANOR")
end)

-- create: input contract -----------------------------------------------------------------------------------------

test("create rejects malformed inputs", function()
    local ok, code = create(nil)
    expectCode(ok, code, "invalid_input", "nil")
    ok, code = create("input")
    expectCode(ok, code, "invalid_input", "string")
    ok, code = create(setmetatable(input(), {}))
    expectCode(ok, code, "invalid_input", "metatable")
    ok, code = create(input({ locationId = "ASYLUM" }))
    expectCode(ok, code, "unexpected_input_field", "forged locationId")
    ok, code = create(input({ partyId = "P1" }))
    expectCode(ok, code, "unexpected_input_field", "extra field")
    local numeric: any = input()
    numeric[1] = "x"
    ok, code = create(numeric)
    expectCode(ok, code, "unexpected_input_field", "numeric key")
end)

test("create rejects invalid seeds", function()
    local bad: { any } = { 0, -1, 2147483648, 4294967295, 1.5, 0 / 0, math.huge, -math.huge, "1", true, {} }
    for _, seed in ipairs(bad) do
        local ok, code = create(input({ seed = seed }))
        expectCode(ok, code, "invalid_seed", tostring(seed))
    end
    local ok, code = create(input({ seed = "__nil__" }))
    expectCode(ok, code, "invalid_seed", "missing seed")
end)

test("create rejects invalid mission identity", function()
    local badIds: { any } = { "", string.rep("a", 65), "bad id", "under_score", 5, true }
    for _, missionId in ipairs(badIds) do
        local ok, code = create(input({ missionId = missionId }))
        expectCode(ok, code, "invalid_mission_id", tostring(missionId))
    end
    local ok, code = create(input({ missionId = "__nil__" }))
    expectCode(ok, code, "invalid_mission_id", "missing mission id")
    local badTypes: { any } = { "", string.rep("T", 33), "bad type", 5, true }
    for _, missionType in ipairs(badTypes) do
        ok, code = create(input({ missionType = missionType }))
        expectCode(ok, code, "invalid_mission_type", tostring(missionType))
    end
    ok, code = create(input({ missionType = "__nil__" }))
    expectCode(ok, code, "invalid_mission_type", "missing mission type")
    expectTrue((create(input({ missionId = string.rep("a", 64), missionType = string.rep("T", 32) }))))
end)

test("create propagates content validation codes", function()
    local ok, code = create(input({ content = "__nil__" }))
    expectCode(ok, code, "invalid_content_table", "missing content")
    ok, code = create(input({ content = content({}) }))
    expectCode(ok, code, "empty_locations", "empty content")
    ok, code = create(input({ content = content({ "ASYLUM", "ASYLUM" }) }))
    expectCode(ok, code, "duplicate_location_id", "duplicate ids")
    ok, code = create(input({ content = content({ "asylum" }) }))
    expectCode(ok, code, "invalid_location_id", "invalid id")
end)

test("create requires a usable random source", function()
    expectError(function()
        (MissionConfigCore :: any).create(input())
    end, "missing random")
    expectError(function()
        (MissionConfigCore :: any).create(input(), {})
    end, "empty random")
    expectError(function()
        (MissionConfigCore :: any).create(input(), { isValidSeed = SeededRandom.isValidSeed })
    end, "random without new")
end)

test("create uses the injected random source exactly once, after validation", function()
    local newCalls = 0
    local labels: { string } = {}
    local ranges: { { number } } = {}
    local fake = {
        isValidSeed = SeededRandom.isValidSeed,
        new = function(_seed: any, label: any): any
            newCalls = newCalls + 1
            table.insert(labels, label)
            return {
                nextInteger = function(_self: any, min: number, max: number): number
                    table.insert(ranges, { min, max })
                    return max -- always the last (alphabetically greatest) location
                end,
            }
        end,
    }
    local ok, config = MissionConfigCore.create(input(), fake)
    expectTrue(ok)
    expectEqual(newCalls, 1)
    expectEqual(labels[1], "config.location")
    expectEqual(#ranges, 1)
    expectEqual(ranges[1][1], 1)
    expectEqual(ranges[1][2], 3)
    expectEqual(config.locationId, "WOODS")

    newCalls = 0
    local rejected = MissionConfigCore.create(input({ content = content({}) }), fake)
    expectFalse(rejected)
    local badSeed = MissionConfigCore.create(input({ seed = 0 }), fake)
    expectFalse(badSeed)
    expectEqual(newCalls, 0, "no stream is created for invalid input")
end)

-- shipped content ------------------------------------------------------------------------------------------------

test("shipped mission content is valid and deeply frozen", function()
    local ok, code = MissionConfigCore.validateContent(MissionContent)
    expectTrue(ok, "MissionContent invalid: " .. tostring(code))
    expectTrue(table.isfrozen(MissionContent), "outer table")
    expectTrue(table.isfrozen(MissionContent.locations), "locations array")
    for index, location in ipairs(MissionContent.locations) do
        expectTrue(table.isfrozen(location), "location " .. index)
    end
end)

test("shipped mission content provides THE ASYLUM and yields a valid configuration", function()
    local hasAsylum = false
    for _, location in ipairs(MissionContent.locations) do
        if location.id == "ASYLUM" then
            hasAsylum = true
        end
    end
    expectTrue(hasAsylum)
    for seed = 1, 20 do
        local ok, config = create(input({ seed = seed, content = MissionContent }))
        expectTrue(ok)
        expectEqual(config.locationId, "ASYLUM")
        expectEqual(config.contentVersion, MissionContent.version)
    end
end)
