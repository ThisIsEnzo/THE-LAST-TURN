--!strict
local Harness = require("../Harness")
local Core = require("../../src/server_shared/MissionLifecycle/MissionLifecycleCore")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual
local S = Core.States

local ALL_STATES = { "BOOTSTRAPPING", "WAITING_FOR_PLAYERS", "INITIALIZING", "ACTIVE", "ENDING", "RETURNING", "SHUTTING_DOWN", "CLOSED" }

-- Independent restatement of the documented graph.
local ALLOWED: { [string]: { string } } = {
    BOOTSTRAPPING = { "WAITING_FOR_PLAYERS", "SHUTTING_DOWN" },
    WAITING_FOR_PLAYERS = { "INITIALIZING", "ENDING", "SHUTTING_DOWN" },
    INITIALIZING = { "ACTIVE", "ENDING", "SHUTTING_DOWN" },
    ACTIVE = { "ENDING", "SHUTTING_DOWN" },
    ENDING = { "RETURNING", "SHUTTING_DOWN" },
    RETURNING = { "SHUTTING_DOWN" },
    SHUTTING_DOWN = { "CLOSED" },
    CLOSED = {},
}

local function context(overrides: { [string]: any }?): { [string]: any }
    local data: { [string]: any } = {
        state = "READY",
        missionId = "mission-1",
        partyId = "P1",
        leaderUserId = 10,
        missionType = "DEFAULT",
        expectedUserIds = { 10, 11, 12 },
        arrivedUserIds = { 12, 10, 11 }, -- arrival order must not matter
        presentUserIds = { 10, 11, 12 },
        missingUserIds = {},
    }
    for key, value in pairs(overrides or {}) do
        data[key] = if value == "__nil__" then nil else value -- "__nil__" removes the field
    end
    if overrides == nil or overrides.presentUserIds == nil then
        local expectedSet: { [any]: boolean } = {}
        if type(data.expectedUserIds) == "table" then
            for _, userId in pairs(data.expectedUserIds) do
                expectedSet[userId] = true
            end
        end
        local source = if type(data.arrivedUserIds) == "table" then data.arrivedUserIds else data.expectedUserIds
        local present: { any } = {}
        local seen: { [any]: boolean } = {}
        if type(source) == "table" then
            for _, userId in ipairs(source) do
                if expectedSet[userId] and not seen[userId] then
                    seen[userId] = true
                    table.insert(present, userId)
                end
            end
        end
        data.presentUserIds = present
    end
    return data
end

local function check(store: any)
    local ok, reason = store:validateInvariants()
    expectTrue(ok, "invariants: " .. tostring(reason))
end

local function waiting()
    local store = Core.new()
    expectTrue(store:startWaiting().ok)
    return store
end

local function initializing()
    local store = waiting()
    expectTrue(store:submitContext(context(), "DEFAULT", 1000).ok)
    return store
end

local function active()
    local store = initializing()
    expectTrue(store:markActive().ok)
    return store
end

test("initial state is BOOTSTRAPPING with no session or outcome", function()
    local store = Core.new()
    expectEqual(store:getState(), S.BOOTSTRAPPING)
    expectEqual(store:getSession(), nil)
    local outcome, reason = store:getOutcome()
    expectEqual(outcome, nil)
    expectEqual(reason, nil)
    check(store)
end)

test("happy path walks every state in order", function()
    local store = Core.new()
    local steps = {
        function() return store:startWaiting() end,
        function() return store:submitContext(context(), "DEFAULT", 1000) end,
        function() return store:markActive() end,
        function() return store:requestEnd("COMPLETED", "objectives_done") end,
        function() return store:beginReturning() end,
        function() return store:beginShutdown() end,
        function() return store:close() end,
    }
    local expected = { S.WAITING_FOR_PLAYERS, S.INITIALIZING, S.ACTIVE, S.ENDING, S.RETURNING, S.SHUTTING_DOWN, S.CLOSED }
    for index, step in ipairs(steps) do
        local result = step()
        expectTrue(result.ok, "step " .. index)
        expectTrue(result.changed, "step " .. index .. " changed")
        expectEqual(result.to, expected[index])
        expectEqual(store:getState(), expected[index])
        check(store)
    end
end)

test("graph matches the documented transitions exactly", function()
    for _, from in ipairs(ALL_STATES) do
        for _, to in ipairs(ALL_STATES) do
            local expected = table.find(ALLOWED[from], to) ~= nil
            expectEqual(Core.canTransition(from, to), expected, from .. " -> " .. to)
        end
    end
    expectFalse(Core.canTransition("NOPE", "CLOSED"))
    expectFalse(Core.canTransition("CLOSED", "NOPE"))
end)

test("repeated operations are idempotent no-ops", function()
    local store = waiting()
    local again = store:startWaiting()
    expectTrue(again.ok)
    expectFalse(again.changed)
    store = active()
    expectFalse(store:markActive().changed)
    expectTrue(store:markActive().ok)
    store:requestEnd("FAILED", "wiped")
    store:beginReturning()
    local returning = store:beginReturning()
    expectTrue(returning.ok)
    expectFalse(returning.changed)
    store:beginShutdown()
    expectFalse(store:beginShutdown().changed)
    store:close()
    local closed = store:close()
    expectTrue(closed.ok)
    expectFalse(closed.changed)
    expectEqual(store:getState(), S.CLOSED)
    check(store)
end)

test("startup cannot skip required states", function()
    local store = Core.new()
    local early = store:submitContext(context(), "DEFAULT", 1)
    expectFalse(early.ok)
    expectEqual(early.rejection, "invalid_transition")
    expectFalse(store:markActive().ok)
    expectFalse(store:beginReturning().ok)
    expectFalse(store:close().ok)
    expectFalse(store:requestEnd("COMPLETED", "too_early").ok)
    expectEqual(store:getState(), S.BOOTSTRAPPING)
    local w = waiting()
    expectFalse(w:markActive().ok, "WAITING cannot jump to ACTIVE")
    expectFalse(w:beginReturning().ok)
    expectEqual(w:getState(), S.WAITING_FOR_PLAYERS)
    local a = active()
    expectFalse(a:beginReturning().ok, "ACTIVE cannot skip ENDING")
    expectFalse(a:close().ok, "ACTIVE cannot skip SHUTTING_DOWN")
    expectEqual(a:getState(), S.ACTIVE)
    check(a)
end)

test("mission cannot start without a valid READY context", function()
    for _, badState in ipairs({ "NO_CONTEXT", "WAITING", "INCOMPLETE", "", 5 }) do
        local store = waiting()
        local result = store:submitContext(context({ state = badState }), "DEFAULT", 1)
        expectFalse(result.ok, tostring(badState))
        expectEqual(result.rejection, "invalid_context")
        expectEqual(result.detail, "context_not_ready")
        expectEqual(store:getState(), S.WAITING_FOR_PLAYERS)
        expectEqual(store:getSession(), nil)
    end
    local nilContext = waiting():submitContext(nil, "DEFAULT", 1)
    expectEqual(nilContext.detail, "context_missing")
    expectFalse(waiting():markActive().ok)
end)

test("invalid or incomplete contexts are rejected", function()
    local cases: { { any } } = {
        { "invalid_mission_id", { missionId = "" } },
        { "invalid_mission_id", { missionId = "bad id" } },
        { "invalid_mission_id", { missionId = string.rep("a", 65) } },
        { "invalid_party_id", { partyId = "p p" } },
        { "unexpected_mission_type", { missionType = "OTHER" } },
        { "invalid_members", { expectedUserIds = {} } },
        { "invalid_members", { expectedUserIds = { 10, 10, 12 }, arrivedUserIds = { 10, 12 } } },
        { "invalid_members", { expectedUserIds = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }, leaderUserId = 1, arrivedUserIds = { 1, 2, 3, 4, 5, 6, 7, 8, 9 } } },
        { "invalid_members", { expectedUserIds = { 10, 1.5 } } },
        { "invalid_members", { expectedUserIds = { 10, 0 } } },
        { "invalid_members", { expectedUserIds = "10" } },
        { "invalid_members", { expectedUserIds = { [1] = 10, [3] = 12 } } },
        { "invalid_members", { expectedUserIds = { first = 10, second = 11, third = 12 } } },
        { "invalid_members", { expectedUserIds = { [1.5] = 10, [2] = 11, [3] = 12 } } },
        { "invalid_leader", { leaderUserId = 99 } },
        { "invalid_leader", { leaderUserId = "10" } },
        { "incomplete_arrivals", { missingUserIds = { 12 } } },
        { "incomplete_arrivals", { arrivedUserIds = { 10, 11 } } },
        { "incomplete_arrivals", { arrivedUserIds = { 10, 11, 99 } } },
        { "incomplete_arrivals", { arrivedUserIds = { 10, 11, 11 } } },
        { "incomplete_arrivals", { arrivedUserIds = { first = 10, second = 11, third = 12 } } },
        { "incomplete_arrivals", { arrivedUserIds = { [1] = 10, [3] = 11, [4] = 12 } } },
        { "incomplete_arrivals", { arrivedUserIds = { [1.5] = 10, [2] = 11, [3] = 12 } } },
        { "incomplete_arrivals", { arrivedUserIds = "__nil__" } },
        { "incomplete_arrivals", { missingUserIds = "__nil__" } },
    }
    for index, case in ipairs(cases) do
        local store = waiting()
        local result = store:submitContext(context(case[2]), "DEFAULT", 1)
        expectFalse(result.ok, "case " .. index)
        expectEqual(result.rejection, "invalid_context", "case " .. index)
        expectEqual(result.detail, case[1], "case " .. index)
        expectEqual(store:getState(), S.WAITING_FOR_PLAYERS)
        expectEqual(store:getSession(), nil, "no session for invalid context")
        check(store)
    end
    expectEqual(waiting():submitContext(context(), "OTHER", 1).detail, "unexpected_mission_type")
end)

test("arrival order does not affect acceptance; 1 and 8 members are valid", function()
    local store = waiting()
    expectTrue(store:submitContext(context({ arrivedUserIds = { 11, 12, 10 } }), "DEFAULT", 5).ok)
    local solo = waiting()
    expectTrue(solo:submitContext(context({ leaderUserId = 7, expectedUserIds = { 7 }, arrivedUserIds = { 7 }, presentUserIds = { 7 } }), "DEFAULT", 5).ok)
    local eight = waiting()
    local ids = { 1, 2, 3, 4, 5, 6, 7, 8 }
    expectTrue(eight:submitContext(context({ leaderUserId = 1, expectedUserIds = ids, arrivedUserIds = { 8, 7, 6, 5, 4, 3, 2, 1 } }), "DEFAULT", 5).ok)
end)


test("partial READY_PARTIAL context starts with present participants and preserves expected members", function()
    local store = waiting()
    local partial = context({
        state = "READY_PARTIAL",
        arrivedUserIds = { 10, 12 },
        presentUserIds = { 12 },
        missingUserIds = { 11 },
    })
    local result = store:submitContext(partial, "DEFAULT", 2000)
    expectTrue(result.ok)
    expectEqual(result.to, S.INITIALIZING)
    local session = store:getSession()
    expectEqual(table.concat(session.expectedUserIds, ","), "10,11,12")
    expectEqual(table.concat(session.presentUserIds, ","), "12")
    check(store)
end)

test("partial context rejects empty present roster", function()
    local store = waiting()
    local result = store:submitContext(context({
        state = "READY_PARTIAL",
        arrivedUserIds = { 10 },
        presentUserIds = {},
        missingUserIds = { 11, 12 },
    }), "DEFAULT", 2000)
    expectFalse(result.ok)
    expectEqual(result.detail, "nobody_present")
    expectEqual(store:getSession(), nil)
end)

test("partial context rejects a present participant who never arrived", function()
    local store = waiting()
    local result = store:submitContext(context({
        state = "READY_PARTIAL",
        arrivedUserIds = { 10 },
        presentUserIds = { 11 },
        missingUserIds = { 11, 12 },
    }), "DEFAULT", 2000)
    expectFalse(result.ok)
    expectEqual(result.detail, "invalid_present_members")
end)

test("partial context requires exact arrived and missing partition", function()
    local store = waiting()
    local result = store:submitContext(context({
        state = "READY_PARTIAL",
        arrivedUserIds = { 10 },
        presentUserIds = { 10 },
        missingUserIds = { 12 },
    }), "DEFAULT", 2000)
    expectFalse(result.ok)
    expectEqual(result.detail, "incomplete_arrivals")
end)

test("full READY context stores only currently present users in the session snapshot", function()
    local store = waiting()
    local result = store:submitContext(context({
        state = "READY",
        arrivedUserIds = { 10, 11, 12 },
        presentUserIds = { 10, 12 },
        missingUserIds = {},
    }), "DEFAULT", 2000)
    expectTrue(result.ok)
    expectEqual(table.concat(store:getSession().presentUserIds, ","), "10,12")
end)

test("startedAt must be a finite number", function()
    for _, invalid in ipairs({ "1000", math.huge, -math.huge, 0 / 0 }) do
        local store = waiting()
        local result = store:submitContext(context(), "DEFAULT", invalid)
        expectFalse(result.ok, tostring(invalid))
        expectEqual(result.rejection, "invalid_context")
        expectEqual(result.detail, "invalid_started_at")
        expectEqual(store:getState(), S.WAITING_FOR_PLAYERS)
        expectEqual(store:getSession(), nil)
    end
    expectTrue(waiting():submitContext(context(), "DEFAULT", 1000).ok)
end)

test("duplicate initialization is prevented", function()
    local store = waiting()
    local first = store:submitContext(context(), "DEFAULT", 1000)
    expectTrue(first.ok)
    expectTrue(first.changed)
    local again = store:submitContext(context({ missionId = "different" }), "DEFAULT", 2000)
    expectFalse(again.ok)
    expectEqual(again.rejection, "already_initialized")
    expectEqual(store:getSession().missionId, "mission-1", "session unchanged")
    expectEqual(store:getSession().startedAt, 1000)
    store:markActive()
    expectEqual(store:submitContext(context(), "DEFAULT", 3000).rejection, "already_initialized")
    expectEqual(store:getState(), S.ACTIVE)
    check(store)
end)

test("successful termination records COMPLETED and freezes progression", function()
    local store = active()
    local result = store:requestEnd("COMPLETED", "ritual_finished")
    expectTrue(result.ok)
    expectTrue(result.changed)
    expectEqual(result.to, S.ENDING)
    expectEqual(result.outcome, "COMPLETED")
    expectEqual(result.reason, "ritual_finished")
    expectFalse(store:markActive().ok, "cannot go back to ACTIVE")
    local outcome, reason = store:getOutcome()
    expectEqual(outcome, "COMPLETED")
    expectEqual(reason, "ritual_finished")
    check(store)
end)

test("failure termination records FAILED", function()
    local store = active()
    local result = store:requestEnd("FAILED", "party_wiped")
    expectTrue(result.ok)
    expectEqual(result.outcome, "FAILED")
    expectEqual(store:getSession().outcome, "FAILED")
    check(store)
end)

test("abort during initialization and while waiting", function()
    local init = initializing()
    local aborted = init:requestEnd("ABORTED", "initialization_failed")
    expectTrue(aborted.ok)
    expectEqual(aborted.to, S.ENDING)
    expectFalse(init:markActive().ok, "a failed initialization never becomes ACTIVE")
    check(init)
    local wait = waiting()
    expectTrue(wait:requestEnd("ABORTED", "context_timeout").ok)
    expectEqual(wait:getState(), S.ENDING)
    expectEqual(wait:getSession(), nil, "no session existed")
    check(wait)
end)

test("duplicate termination calls preserve the original result in every later state", function()
    local store = active()
    store:requestEnd("COMPLETED", "first_reason")
    local attempts = {
        function() return store:requestEnd("FAILED", "second_reason") end,
        function()
            store:beginReturning()
            return store:requestEnd("ABORTED", "third_reason")
        end,
        function()
            store:beginShutdown()
            return store:requestEnd("FAILED", "fourth_reason")
        end,
        function()
            store:close()
            return store:requestEnd("FAILED", "fifth_reason")
        end,
    }
    for index, attempt in ipairs(attempts) do
        local result = attempt()
        expectTrue(result.ok, "attempt " .. index)
        expectFalse(result.changed, "attempt " .. index)
        expectEqual(result.outcome, "COMPLETED")
        expectEqual(result.reason, "first_reason")
    end
    expectEqual(store:getState(), S.CLOSED)
end)

test("CLOSED is terminal", function()
    local store = active()
    store:requestEnd("FAILED", "x")
    store:beginReturning()
    store:beginShutdown()
    store:close()
    for _, to in ipairs(ALL_STATES) do
        expectFalse(Core.canTransition("CLOSED", to), "CLOSED -> " .. to)
    end
    expectFalse(store:startWaiting().changed)
    expectFalse(store:submitContext(context(), "DEFAULT", 1).ok)
    expectFalse(store:markActive().ok)
    expectFalse(store:beginReturning().ok)
    expectFalse(store:beginShutdown().changed)
    expectEqual(store:getState(), S.CLOSED)
    check(store)
end)

test("session snapshots are copies and hold lifecycle data only", function()
    local store = initializing()
    local session = store:getSession()
    expectEqual(session.missionId, "mission-1")
    expectEqual(session.partyId, "P1")
    expectEqual(session.leaderUserId, 10)
    expectEqual(session.startedAt, 1000)
    expectEqual(session.state, S.INITIALIZING)
    table.insert(session.expectedUserIds, 99)
    session.missionId = "hacked"
    local fresh = store:getSession()
    expectEqual(fresh.missionId, "mission-1")
    expectEqual(#fresh.expectedUserIds, 3)
    expectEqual(#fresh.presentUserIds, 3)
    table.insert(session.presentUserIds, 99)
    expectEqual(#store:getSession().presentUserIds, 3)
    for key in pairs(fresh) do
        expectFalse(string.lower(key):find("reserved") ~= nil or string.lower(key):find("secret") ~= nil, key)
    end
    check(store)
end)

test("invalid termination arguments are rejected", function()
    local store = active()
    for _, outcome in ipairs({ "WIN", "completed", "", 5, true }) do
        local result = store:requestEnd(outcome, "fine_reason")
        expectFalse(result.ok, tostring(outcome))
        expectEqual(result.rejection, "invalid_outcome")
    end
    expectEqual(store:requestEnd(nil, "fine_reason").rejection, "invalid_outcome")
    for _, reason in ipairs({ "", "has space", string.rep("a", 49), 5, true }) do
        local result = store:requestEnd("FAILED", reason)
        expectFalse(result.ok, tostring(reason))
        expectEqual(result.rejection, "invalid_reason")
    end
    expectEqual(store:requestEnd("FAILED", nil).rejection, "invalid_reason")
    expectEqual(store:getState(), S.ACTIVE, "rejected requests change nothing")
    local outcome = store:getOutcome()
    expectEqual(outcome, nil)
    check(store)
end)

test("shutdown from any state records ABORTED/server_shutdown unless a result exists", function()
    local boot = Core.new()
    local result = boot:beginShutdown()
    expectTrue(result.ok)
    expectEqual(result.to, S.SHUTTING_DOWN)
    expectEqual(result.outcome, "ABORTED")
    expectEqual(result.reason, "server_shutdown")
    check(boot)
    local later = boot:requestEnd("COMPLETED", "too_late")
    expectTrue(later.ok)
    expectFalse(later.changed)
    expectEqual(later.reason, "server_shutdown")

    local running = active()
    expectEqual(running:beginShutdown().reason, "server_shutdown")
    check(running)

    local ended = active()
    ended:requestEnd("COMPLETED", "done")
    expectEqual(ended:beginShutdown().outcome, "COMPLETED", "an existing result is preserved")
end)

test("invariants hold across every reachable state", function()
    local stores = { Core.new(), waiting(), initializing(), active() }
    for _, store in ipairs(stores) do
        check(store)
    end
    local ending = active()
    ending:requestEnd("FAILED", "x")
    check(ending)
    ending:beginReturning()
    check(ending)
    ending:beginShutdown()
    check(ending)
    ending:close()
    check(ending)
end)

test("config validation", function()
    local good = {
        expectedMissionType = "DEFAULT",
        contextWaitTimeoutSeconds = 120,
        returnMaxRetriesPerPlayer = 2,
        returnRetryDelaySeconds = 2,
        returnTimeoutSeconds = 30,
    }
    expectTrue((Core.validateConfig(good)))
    local function bad(key: string, value: any): boolean
        local copy = table.clone(good) :: any
        copy[key] = value
        return (Core.validateConfig(copy))
    end
    expectFalse(bad("expectedMissionType", ""))
    expectFalse(bad("expectedMissionType", "has space"))
    expectFalse(bad("contextWaitTimeoutSeconds", 0))
    expectFalse(bad("contextWaitTimeoutSeconds", math.huge))
    expectFalse(bad("returnRetryDelaySeconds", -1))
    expectFalse(bad("returnTimeoutSeconds", 0 / 0))
    expectFalse(bad("returnMaxRetriesPerPlayer", -1))
    expectFalse(bad("returnMaxRetriesPerPlayer", 1.5))
    expectFalse(bad("returnMaxRetriesPerPlayer", 11))
    expectTrue(bad("returnMaxRetriesPerPlayer", 0))
    expectFalse((Core.validateConfig(nil)))
end)

return {}
