--!strict
local Harness = require("../Harness")
local TeleportPayload = require("../../src/server_shared/MissionTeleport/TeleportPayload")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local function valid(): { [string]: any }
    return {
        schemaVersion = 1,
        missionId = "mission-123",
        partyId = "P1",
        partyLeaderUserId = 10,
        memberUserIds = { 10, 11, 12 },
        missionType = "DEFAULT",
        createdAt = 1700000000,
    }
end

local function ok(data: any): boolean
    local result = TeleportPayload.validate(data)
    return result
end

test("valid payload is accepted and returned as a sanitized copy", function()
    local input = valid()
    local accepted, result = TeleportPayload.validate(input)
    expectTrue(accepted)
    expectEqual(result.missionId, "mission-123")
    expectFalse(result == input)
    expectFalse(result.memberUserIds == input.memberUserIds)
    expectEqual(#result.memberUserIds, 3)
end)

test("solo and 8-member payloads are valid; 9 members are not", function()
    local solo = valid()
    solo.partyLeaderUserId = 5
    solo.memberUserIds = { 5 }
    expectTrue(ok(solo))
    local full = valid()
    full.memberUserIds = { 10, 2, 3, 4, 5, 6, 7, 8 }
    expectTrue(ok(full))
    full.memberUserIds = { 10, 2, 3, 4, 5, 6, 7, 8, 9 }
    expectFalse(ok(full))
end)

test("non-table and malformed containers are rejected", function()
    expectFalse(ok(nil))
    expectFalse(ok("x"))
    expectFalse(ok(5))
    expectFalse(ok(setmetatable(valid(), {})))
    local data = valid()
    data.memberUserIds = "10"
    expectFalse(ok(data))
    data.memberUserIds = {}
    expectFalse(ok(data))
end)

test("schema version must match", function()
    for _, bad in ipairs({ 0, 2, "1", true }) do
        local data = valid()
        data.schemaVersion = bad
        expectFalse(ok(data), "schemaVersion " .. tostring(bad))
    end
    local data = valid()
    data.schemaVersion = nil
    expectFalse(ok(data))
end)

test("missing and unexpected fields are rejected", function()
    for key in pairs(valid()) do
        local data = valid()
        data[key] = nil
        expectFalse(ok(data), "missing " .. key)
    end
    local extra = valid()
    extra.reservedServerId = "secret"
    expectFalse(ok(extra))
    local numericKey = valid()
    numericKey[1] = "x"
    expectFalse(ok(numericKey))
end)

test("ids and strings are bounded and pattern checked", function()
    local cases: { { string | number } } = {
        { "missionId", "" },
        { "missionId", string.rep("a", 65) },
        { "missionId", "bad id!" },
        { "missionId", 5 },
        { "partyId", string.rep("a", 33) },
        { "partyId", "a b" },
        { "missionType", "" },
        { "missionType", string.rep("x", 33) },
        { "missionType", "x/y" },
    }
    for _, case in ipairs(cases) do
        local data = valid()
        data[case[1] :: string] = case[2]
        expectFalse(ok(data), tostring(case[1]) .. "=" .. tostring(case[2]))
    end
    local boundary = valid()
    boundary.missionId = string.rep("a", 64)
    boundary.partyId = string.rep("b", 32)
    expectTrue(ok(boundary))
end)

test("user ids and createdAt must be sane integers", function()
    for _, bad in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "10" }) do
        local data = valid()
        data.partyLeaderUserId = bad
        data.memberUserIds = { bad :: any, 11 }
        expectFalse(ok(data), "leader " .. tostring(bad))
    end
    for _, bad in ipairs({ -1, 1.5, 0 / 0, math.huge, 5000000000 }) do
        local data = valid()
        data.createdAt = bad
        expectFalse(ok(data), "createdAt " .. tostring(bad))
    end
end)

test("duplicate member UserIds are rejected", function()
    local data = valid()
    data.memberUserIds = { 10, 11, 11 }
    expectFalse(ok(data))
end)

test("leader must be a member", function()
    local data = valid()
    data.partyLeaderUserId = 99
    expectFalse(ok(data))
end)

test("sparse or non-sequence member arrays are rejected", function()
    local sparse = valid()
    sparse.memberUserIds = { [1] = 10, [3] = 11 }
    expectFalse(ok(sparse))
    local mixed = valid()
    mixed.memberUserIds = { 10, 11, extra = 12 }
    expectFalse(ok(mixed))
end)

test("build produces a valid payload and errors on invalid input", function()
    local payload = TeleportPayload.build({
        missionId = "m1",
        partyId = "P1",
        leaderUserId = 1,
        memberUserIds = { 1, 2 },
        missionType = "DEFAULT",
        createdAt = 100,
    })
    expectEqual(payload.schemaVersion, TeleportPayload.SchemaVersion)
    expectTrue(ok(payload))
    Harness.expectError(function()
        TeleportPayload.build({
            missionId = "m1",
            partyId = "P1",
            leaderUserId = 3,
            memberUserIds = { 1, 2 },
            missionType = "DEFAULT",
            createdAt = 100,
        })
    end)
end)

test("payload never carries a reserved server id field", function()
    local payload = TeleportPayload.build({
        missionId = "m1",
        partyId = "P1",
        leaderUserId = 1,
        memberUserIds = { 1 },
        missionType = "DEFAULT",
        createdAt = 100,
    })
    for key in pairs(payload) do
        expectFalse(string.lower(key):find("reserved") ~= nil, "unexpected field " .. key)
    end
end)

return {}
