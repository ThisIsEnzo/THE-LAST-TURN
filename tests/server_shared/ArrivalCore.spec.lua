--!strict
local Harness = require("../Harness")
local ArrivalCore = require("../../src/server_shared/MissionTeleport/ArrivalCore")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual
local States = ArrivalCore.States

local function payload(members: { number }, overrides: { [string]: any }?): { [string]: any }
    local data: { [string]: any } = {
        schemaVersion = 1,
        missionId = "m1",
        partyId = "P1",
        partyLeaderUserId = members[1],
        memberUserIds = members,
        missionType = "DEFAULT",
        createdAt = 100,
    }
    for key, value in pairs(overrides or {}) do
        data[key] = value
    end
    return data
end

local function newCore()
    local now = 0
    local core = ArrivalCore.new({ arrivalTimeoutSeconds = 30 }, function()
        return now
    end)
    return core, function(seconds: number)
        now += seconds
    end
end

test("environment check requires the expected place and a reserved server", function()
    local good = { placeId = 5, expectedPlaceId = 5, privateServerId = "abc", privateServerOwnerId = 0 }
    expectTrue((ArrivalCore.checkEnvironment(good)))
    local function reason(overrides: { [string]: any }): string?
        local env: { [string]: any } = { placeId = 5, expectedPlaceId = 5, privateServerId = "abc", privateServerOwnerId = 0 }
        for key, value in pairs(overrides) do
            env[key] = value
        end
        local _, why = ArrivalCore.checkEnvironment(env :: any)
        return why
    end
    expectEqual(reason({ expectedPlaceId = 0 }), "mission_place_not_configured")
    expectEqual(reason({ placeId = 6 }), "unexpected_place")
    expectEqual(reason({ privateServerId = "" }), "not_reserved_server")
    expectEqual(reason({ privateServerOwnerId = 7 }), "not_reserved_server")
end)

test("no context until a valid arrival", function()
    local core = newCore()
    expectEqual(core:getState(), States.NO_CONTEXT)
    expectEqual(core:getContext(), nil)
end)

test("solo arrival is READY immediately", function()
    local core = newCore()
    local result = core:arrive(1, payload({ 1 }))
    expectTrue(result.ok)
    expectEqual(result.state, States.READY)
    expectEqual(core:getContext().missionId, "m1")
end)

test("party arrives over time: WAITING then READY", function()
    local core = newCore()
    expectEqual(core:arrive(1, payload({ 1, 2, 3 })).state, States.WAITING)
    expectEqual(core:arrive(3, payload({ 1, 2, 3 })).state, States.WAITING)
    local last = core:arrive(2, payload({ 1, 2, 3 }))
    expectEqual(last.state, States.READY)
    local context = core:getContext()
    expectEqual(table.concat(context.arrivedUserIds, ","), "1,3,2")
    expectEqual(#context.missingUserIds, 0)
end)

test("unexpected arriving player is rejected without joining the context", function()
    local core = newCore()
    core:arrive(1, payload({ 1, 2 }))
    local result = core:arrive(9, payload({ 1, 2 }))
    expectFalse(result.ok)
    expectEqual(result.rejection, "not_expected")
    expectEqual(#core:getContext().arrivedUserIds, 1)
    local fresh = newCore()
    expectEqual(fresh:arrive(9, payload({ 1, 2 })).rejection, "not_expected")
    expectEqual(fresh:getState(), States.NO_CONTEXT, "a rejected first arrival must not create a context")
end)

test("inconsistent mission contexts are rejected", function()
    local core = newCore()
    core:arrive(1, payload({ 1, 2, 3 }))
    local cases = {
        payload({ 1, 2, 3 }, { missionId = "other" }),
        payload({ 1, 2, 3 }, { partyId = "P2" }),
        payload({ 1, 2, 3 }, { missionType = "OTHER" }),
        payload({ 2, 1, 3 }), -- different leader
        payload({ 1, 2 }), -- different member list
        payload({ 1, 2, 4 }),
    }
    for index, data in ipairs(cases) do
        local result = core:arrive(2, data)
        expectFalse(result.ok, "case " .. index)
        expectEqual(result.rejection, "context_mismatch")
    end
    expectEqual(#core:getContext().arrivedUserIds, 1, "conflicting players are never added")
end)

test("duplicate arrival is idempotent", function()
    local core = newCore()
    core:arrive(1, payload({ 1, 2 }))
    local again = core:arrive(1, payload({ 1, 2 }))
    expectTrue(again.ok)
    expectFalse(again.changed)
    expectEqual(#core:getContext().arrivedUserIds, 1)
end)

test("arrival timeout marks the context INCOMPLETE and reports who is missing", function()
    local core, advance = newCore()
    core:arrive(1, payload({ 1, 2, 3 }))
    advance(29)
    expectEqual(core:checkTimeout(), States.WAITING)
    advance(1)
    expectEqual(core:checkTimeout(), States.INCOMPLETE)
    local context = core:getContext()
    expectEqual(context.state, States.INCOMPLETE)
    expectEqual(table.concat(context.missingUserIds, ","), "2,3", "missing players are listed, not fabricated")
    expectEqual(#context.arrivedUserIds, 1)
end)

test("timeout does not affect a complete context; late arrival can complete an incomplete one", function()
    local complete, advance = newCore()
    complete:arrive(1, payload({ 1 }))
    advance(100)
    expectEqual(complete:checkTimeout(), States.READY)

    local core, advance2 = newCore()
    core:arrive(1, payload({ 1, 2 }))
    advance2(31)
    expectEqual(core:checkTimeout(), States.INCOMPLETE)
    expectEqual(core:arrive(2, payload({ 1, 2 })).state, States.READY)
end)

test("a player leaving keeps their arrival but stops being present; rejoin works", function()
    local core = newCore()
    core:arrive(1, payload({ 1, 2 }))
    core:arrive(2, payload({ 1, 2 }))
    expectTrue(core:leave(2))
    expectFalse(core:leave(2))
    expectFalse(core:leave(99))
    local context = core:getContext()
    expectEqual(table.concat(context.presentUserIds, ","), "1")
    expectEqual(context.state, States.READY)
    expectTrue(core:arrive(2, payload({ 1, 2 })).changed)
    expectEqual(#core:getContext().presentUserIds, 2)
end)

test("getContext returns copies", function()
    local core = newCore()
    core:arrive(1, payload({ 1, 2 }))
    local context = core:getContext()
    table.insert(context.expectedUserIds, 99)
    context.missionId = "hacked"
    expectEqual(core:getContext().missionId, "m1")
    expectEqual(#core:getContext().expectedUserIds, 2)
end)

test("timeout configuration is validated", function()
    Harness.expectError(function()
        ArrivalCore.new({ arrivalTimeoutSeconds = 0 }, function()
            return 0
        end)
    end)
    Harness.expectError(function()
        ArrivalCore.new({ arrivalTimeoutSeconds = math.huge }, function()
            return 0
        end)
    end)
end)

return {}
