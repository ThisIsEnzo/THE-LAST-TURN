--!strict
local Harness = require("../Harness")
local ObjectiveGraph = require("../../src/server_shared/Objective/ObjectiveGraph")
local ObjectiveCore = require("../../src/server_shared/Objective/ObjectiveCore")
local ObjectiveRuntime = require("../../src/server_shared/Objective/ObjectiveRuntime")
local InteractionCore = require("../../src/server_shared/Interaction/InteractionCore")
local ObjectiveContent = require("../../src/mission/server/Objective/ObjectiveContent")
local ObjectiveConfig = require("../../src/mission/server/Objective/ObjectiveConfig")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

-- Fakes ------------------------------------------------------------------------------------------------------------
-- A small in-memory world standing in for InteractionService, the lifecycle, players, the network and the scheduler.
-- The runtime under test is the real one, wired to the real ObjectiveGraph, ObjectiveCore, ObjectiveContent and config.

local function newWorld(options: any?): any
    local opts: any = options or {}
    local world: any = {
        lifecycleActive = opts.lifecycleActive ~= false,
        endCalls = {},
        sent = {}, -- { userId, payload }
        deferred = {},
        handlers = {}, -- interaction id -> handler
        specs = {}, -- interaction id -> spec
        enabled = {}, -- interaction id -> boolean
        registerOrder = {},
        unregistered = {},
        logs = {},
        missingAnchors = opts.missingAnchors or {},
        failRegister = opts.failRegister or {}, -- interaction id -> reason
        failSetEnabled = {}, -- interaction id -> remaining failures
        failSendFor = {}, -- userId -> true
        endMissionRaises = false,
        clock = 0,
        players = {},
    }
    for _, userId in ipairs(opts.userIds or { 1, 2, 3 }) do
        world.players[userId] = { UserId = userId, alive = true, connected = true }
    end

    local interaction = {}
    function interaction.register(spec: any, anchor: any, handler: any, promptOptions: any): (any, string?)
        local ok, detail = InteractionCore.validateSpec(spec)
        if not ok then
            return nil, "invalid_spec:" .. tostring(detail)
        end
        if world.failRegister[spec.id] ~= nil then
            return nil, world.failRegister[spec.id]
        end
        if world.handlers[spec.id] ~= nil then
            return nil, "duplicate_id"
        end
        if type(anchor) ~= "table" or type(promptOptions) ~= "table" or type(promptOptions.actionText) ~= "string" or type(promptOptions.objectText) ~= "string" then
            return nil, "invalid_options"
        end
        local handle = { id = spec.id, alive = true }
        world.handlers[spec.id] = handler
        world.specs[spec.id] = spec
        world.enabled[spec.id] = spec.enabled ~= false
        table.insert(world.registerOrder, spec.id)
        return handle, nil
    end
    function interaction.setEnabled(handle: any, enabled: any): (boolean, string?)
        if type(handle) ~= "table" or not handle.alive then
            return false, "invalid_handle"
        end
        local remaining = world.failSetEnabled[handle.id]
        if remaining ~= nil and remaining > 0 then
            world.failSetEnabled[handle.id] = remaining - 1
            return false, "prompt_failed"
        end
        world.enabled[handle.id] = enabled
        return true, nil
    end
    function interaction.unregister(handle: any): (boolean, string?)
        if type(handle) ~= "table" or not handle.alive then
            return false, "not_registered"
        end
        handle.alive = false
        world.handlers[handle.id] = nil
        world.enabled[handle.id] = nil
        table.insert(world.unregistered, handle.id)
        return true, nil
    end

    local lifecycle = {}
    function lifecycle.isActive(): boolean
        return world.lifecycleActive
    end
    function lifecycle.endMission(outcome: string, reason: string): any
        if world.endMissionRaises then
            error("endMission boom")
        end
        table.insert(world.endCalls, { outcome = outcome, reason = reason })
        world.lifecycleActive = false -- the real lifecycle leaves ACTIVE when the end is accepted
        return { ok = true }
    end

    local players = {}
    function players.getUserId(player: any): number?
        if type(player) ~= "table" then
            return nil
        end
        return player.UserId
    end
    function players.getPlayer(userId: number): any?
        return world.players[userId]
    end
    function players.isConnected(player: any): boolean
        return type(player) == "table" and player.connected == true
    end
    function players.isAlive(player: any): boolean
        return type(player) == "table" and player.alive == true
    end

    world.deps = {
        graph = ObjectiveGraph,
        core = ObjectiveCore,
        content = opts.content or ObjectiveContent,
        config = ObjectiveConfig.Values,
        interaction = interaction,
        resolveAnchor = function(pointId: string): any?
            if world.missingAnchors[pointId] then
                return nil
            end
            return { name = pointId }
        end,
        lifecycle = lifecycle,
        players = players,
        send = function(player: any, payload: any)
            if world.failSendFor[player.UserId] then
                error("send boom")
            end
            table.insert(world.sent, { userId = player.UserId, payload = payload })
        end,
        defer = function(callback: () -> ())
            table.insert(world.deferred, callback)
        end,
        now = function(): number
            world.clock = world.clock + 1
            return world.clock
        end,
        log = function(message: string)
            table.insert(world.logs, message)
        end,
    }

    function world.flush()
        local pending = world.deferred
        world.deferred = {}
        for _, callback in ipairs(pending) do
            callback()
        end
    end
    function world.trigger(objectiveId: string, slotId: string, player: any): boolean?
        local handler = world.handlers[ObjectiveRuntime.interactionId(objectiveId, slotId)]
        if handler == nil then
            return nil
        end
        return handler(player)
    end
    function world.sentTo(userId: number): { any }
        local result = {}
        for _, entry in ipairs(world.sent) do
            if entry.userId == userId then
                table.insert(result, entry.payload)
            end
        end
        return result
    end
    return world
end

local SESSION = { expectedUserIds = { 1, 2, 3 } }

local function startedWorld(options: any?): (any, any)
    local world = newWorld(options)
    local runtime: any = ObjectiveRuntime.new(world.deps)
    runtime:start(options and options.session or SESSION)
    return world, runtime
end

local function player(world: any, userId: number): any
    return world.players[userId]
end

local function id(objectiveId: string, slotId: string): string
    return ObjectiveRuntime.interactionId(objectiveId, slotId)
end

local function fillPower(world: any, userId: number)
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_A", player(world, userId)))
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_B", player(world, userId)))
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_C", player(world, userId)))
end

local function snapshotState(snapshot: any, objectiveId: string): string?
    for _, entry in ipairs(snapshot.objectives) do
        if entry.id == objectiveId then
            return entry.state
        end
    end
    return nil
end

-- 1. initialization -----------------------------------------------------------------------------------------------

test("initialization with the shipped content registers one disabled-then-reconciled prompt per slot", function()
    local world, runtime = startedWorld()
    expectTrue(runtime:isRunning())
    expectEqual(#world.registerOrder, 6)
    expectEqual(world.registerOrder[1], "OBJ_RESTORE_POWER_FUSE_A")
    expectEqual(world.registerOrder[4], "OBJ_OPEN_WING_ACCESS_PANEL")
    expectEqual(world.registerOrder[5], "OBJ_EXTRACT_EXTRACTION_POINT")
    expectEqual(world.registerOrder[6], "OBJ_FIND_RECORDS_RECORDS_CABINET")
    for interactionId, spec in pairs(world.specs) do
        local ok, detail = InteractionCore.validateSpec(spec)
        expectTrue(ok, interactionId .. ": " .. tostring(detail))
        expectTrue(#interactionId <= 64)
        expectEqual(spec.enabled, false, "registered disabled, then reconciled")
    end
    expectEqual(runtime:getObjectiveState("RESTORE_POWER"), "AVAILABLE")
    expectEqual(runtime:getObjectiveState("OPEN_WING"), "LOCKED")
    expectEqual(runtime:getObjectiveState("EXTRACT"), "LOCKED")
    expectEqual(runtime:getObjectiveState("FIND_RECORDS"), "AVAILABLE")
    expectEqual(runtime:getRevision(), 0)
    expectEqual(runtime:getResolution(), nil)
end)

test("the first reconciliation enables exactly the prompts of available objectives", function()
    local world = startedWorld()
    for _, slotId in ipairs({ "FUSE_A", "FUSE_B", "FUSE_C" }) do
        expectTrue(world.enabled[id("RESTORE_POWER", slotId)], slotId)
    end
    expectTrue(world.enabled[id("FIND_RECORDS", "RECORDS_CABINET")])
    expectFalse(world.enabled[id("OPEN_WING", "ACCESS_PANEL")], "locked")
    expectFalse(world.enabled[id("EXTRACT", "EXTRACTION_POINT")], "locked")
end)

test("initialization fails loudly for invalid content and leaves nothing behind", function()
    local invalid = {
        version = 1,
        objectives = {
            { id = "OPT", importance = "OPTIONAL", title = "T", description = "D", completion = { kind = "SLOTS", slots = { { id = "S", pointId = "P1", label = "L" } } } },
            { id = "REQ", importance = "REQUIRED", requires = { anyOf = { "OPT" } }, title = "T", description = "D", completion = { kind = "SLOTS", slots = { { id = "S", pointId = "P2", label = "L" } } } },
        },
    }
    local world = newWorld({ content = invalid })
    local runtime: any = ObjectiveRuntime.new(world.deps)
    local ok, err = pcall(function()
        runtime:start(SESSION)
    end)
    expectFalse(ok)
    expectTrue(string.find(tostring(err), "required_not_guaranteed", 1, true) ~= nil, tostring(err))
    expectFalse(runtime:isRunning())
    expectEqual(#world.registerOrder, 0)
    expectEqual(#world.sent, 0)
    expectEqual(runtime:getRevision(), nil)
    -- a stop after the failed start is harmless
    runtime:stop()
    runtime:stop()
end)

test("initialization rejects a missing, empty or malformed roster", function()
    local function startWith(session: any): boolean
        local world = newWorld()
        local runtime: any = ObjectiveRuntime.new(world.deps)
        local ok = pcall(function()
            runtime:start(session)
        end)
        expectEqual(runtime:isRunning(), ok)
        if not ok then
            expectEqual(#world.registerOrder, 0)
        end
        return ok
    end
    expectFalse(startWith(nil))
    expectFalse(startWith({}))
    expectFalse(startWith({ expectedUserIds = {} }))
    expectFalse(startWith({ expectedUserIds = { 1, 1 } }))
    expectFalse(startWith({ expectedUserIds = { 0 } }))
    expectFalse(startWith({ expectedUserIds = { "1" } }))
    expectFalse(startWith({ expectedUserIds = { 1.5 } }))
    expectTrue(startWith({ expectedUserIds = { 7 } }))
end)

test("the runtime requires complete dependencies and starts only once", function()
    Harness.expectError(function()
        ObjectiveRuntime.new({} :: any)
    end)
    local world = newWorld()
    local deps = world.deps
    deps.now = nil
    Harness.expectError(function()
        ObjectiveRuntime.new(deps)
    end)
    local fresh = newWorld()
    local runtime: any = ObjectiveRuntime.new(fresh.deps)
    runtime:start(SESSION)
    Harness.expectError(function()
        runtime:start(SESSION)
    end, "second start")
    expectTrue(runtime:isRunning())
    expectEqual(#fresh.registerOrder, 6, "the failed second start registered nothing more")
end)

-- 3-4. lifecycle gating --------------------------------------------------------------------------------------------

test("progression is rejected before the mission is ACTIVE", function()
    local world, runtime = startedWorld({ lifecycleActive = false })
    local sentBefore = #world.sent
    expectFalse(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)))
    expectEqual(runtime:getObjectiveState("RESTORE_POWER"), "AVAILABLE")
    expectEqual(runtime:getRevision(), 0)
    expectEqual(#world.sent, sentBefore)
    -- once the lifecycle becomes ACTIVE the very same prompt works
    world.lifecycleActive = true
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)))
    expectEqual(runtime:getRevision(), 1)
end)

test("progression is rejected after the mission left ACTIVE", function()
    local world, runtime = startedWorld()
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)))
    world.lifecycleActive = false -- ENDING / ENDED / failed
    local revision = runtime:getRevision()
    local sent = #world.sent
    expectFalse(world.trigger("RESTORE_POWER", "FUSE_B", player(world, 1)))
    expectEqual(runtime:getRevision(), revision)
    expectEqual(#world.sent, sent)
end)

test("after stop every captured handler is dead, prompts are unregistered and nothing is published", function()
    local world, runtime = startedWorld()
    local handler = world.handlers[id("RESTORE_POWER", "FUSE_A")]
    runtime:stop()
    expectFalse(runtime:isRunning())
    expectEqual(#world.unregistered, 6)
    expectFalse(handler(player(world, 1)))
    expectEqual(runtime:getObjectiveState("RESTORE_POWER"), nil)
    local sent = #world.sent
    runtime:requestSnapshot(player(world, 1))
    expectEqual(#world.sent, sent)
    runtime:stop() -- idempotent
    expectEqual(#world.unregistered, 6)
end)

test("a handler captured before a stop stays dead even when the runtime starts again", function()
    local world, runtime = startedWorld()
    local oldHandler = world.handlers[id("RESTORE_POWER", "FUSE_A")]
    runtime:stop()
    runtime:start(SESSION)
    expectTrue(runtime:isRunning())
    expectFalse(oldHandler(player(world, 1)), "the stale handler must not mutate the new run")
    expectEqual(runtime:getObjectiveState("RESTORE_POWER"), "AVAILABLE")
    expectEqual(runtime:getRevision(), 0)
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)), "the new registration works")
end)

-- 5-6. commands and rejections -------------------------------------------------------------------------------------

test("a valid interaction applies the contribution and reports success to the interaction layer", function()
    local world, runtime = startedWorld()
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_B", player(world, 2)))
    expectEqual(runtime:getObjectiveState("RESTORE_POWER"), "IN_PROGRESS")
    expectEqual(runtime:getRevision(), 1)
    local snapshot = world.sentTo(2)[#world.sentTo(2)]
    expectEqual(snapshot.revision, 1)
    expectEqual(snapshot.objectives[1].filled, 1)
    expectFalse(snapshot.objectives[1].slots[1].filled)
    expectTrue(snapshot.objectives[1].slots[2].filled)
    expectFalse(world.enabled[id("RESTORE_POWER", "FUSE_B")], "the filled slot's prompt is disabled")
    expectTrue(world.enabled[id("RESTORE_POWER", "FUSE_A")])
end)

test("unauthorized or invalid activations never mutate objective state", function()
    local world, runtime = startedWorld({ userIds = { 1, 2, 3, 99 } })
    local sentBefore = #world.sent
    local function expectNoChange(label: string)
        expectEqual(runtime:getRevision(), 0, label)
        expectEqual(runtime:getObjectiveState("RESTORE_POWER"), "AVAILABLE", label)
        expectEqual(#world.sent, sentBefore, label)
    end
    expectFalse(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 99)), "not on the roster")
    expectNoChange("non-roster")
    player(world, 2).alive = false
    expectFalse(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 2)), "dead, ghost or spectating")
    expectNoChange("not alive")
    player(world, 3).connected = false
    expectFalse(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 3)), "disconnected")
    expectNoChange("disconnected")
    expectFalse(world.trigger("RESTORE_POWER", "FUSE_A", nil), "no player")
    expectFalse(world.trigger("RESTORE_POWER", "FUSE_A", "x"), "not a player")
    expectFalse(world.trigger("RESTORE_POWER", "FUSE_A", {}), "no user id")
    expectNoChange("garbage players")
end)

test("a locked objective's interaction cannot progress it even if its handler is invoked directly", function()
    local world, runtime = startedWorld()
    expectFalse(world.trigger("OPEN_WING", "ACCESS_PANEL", player(world, 1)))
    expectFalse(world.trigger("EXTRACT", "EXTRACTION_POINT", player(world, 1)))
    expectEqual(runtime:getObjectiveState("OPEN_WING"), "LOCKED")
    expectEqual(runtime:getRevision(), 0)
end)

test("a duplicate fill returns false (no cooldown) and publishes nothing", function()
    local world, runtime = startedWorld()
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)))
    local sent = #world.sent
    expectFalse(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 2)))
    expectEqual(#world.sent, sent)
    expectEqual(runtime:getRevision(), 1)
end)

-- 7-8. unlocking and prompt reconciliation -------------------------------------------------------------------------

test("completing a prerequisite unlocks the dependent objective and its prompt in one command", function()
    local world, runtime = startedWorld()
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)))
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_B", player(world, 2)))
    expectEqual(runtime:getObjectiveState("OPEN_WING"), "LOCKED")
    expectFalse(world.enabled[id("OPEN_WING", "ACCESS_PANEL")])
    local sentBefore = #world.sent
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_C", player(world, 3)))
    expectEqual(runtime:getObjectiveState("RESTORE_POWER"), "COMPLETED")
    expectEqual(runtime:getObjectiveState("OPEN_WING"), "AVAILABLE")
    expectTrue(world.enabled[id("OPEN_WING", "ACCESS_PANEL")])
    for _, slotId in ipairs({ "FUSE_A", "FUSE_B", "FUSE_C" }) do
        expectFalse(world.enabled[id("RESTORE_POWER", slotId)], slotId)
    end
    expectEqual(#world.sent - sentBefore, 3, "exactly one snapshot per player for the whole cascade")
    for userId = 1, 3 do
        local last = world.sentTo(userId)[#world.sentTo(userId)]
        expectEqual(snapshotState(last, "RESTORE_POWER"), "COMPLETED")
        expectEqual(snapshotState(last, "OPEN_WING"), "AVAILABLE")
        expectEqual(last.revision, 3)
    end
end)

test("prompts follow the authoritative state through the whole mission and are all disabled after resolution", function()
    local world, runtime = startedWorld()
    fillPower(world, 1)
    expectTrue(world.trigger("OPEN_WING", "ACCESS_PANEL", player(world, 2)))
    expectTrue(world.enabled[id("EXTRACT", "EXTRACTION_POINT")])
    expectFalse(world.enabled[id("OPEN_WING", "ACCESS_PANEL")])
    expectTrue(world.enabled[id("FIND_RECORDS", "RECORDS_CABINET")], "the optional objective stays available")
    expectTrue(world.trigger("EXTRACT", "EXTRACTION_POINT", player(world, 3)))
    expectEqual(runtime:getResolution().outcome, "COMPLETED")
    for interactionId, enabled in pairs(world.enabled) do
        expectFalse(enabled, interactionId .. " must be disabled once the mission resolved")
    end
end)

test("a prompt update that fails is retried and healed by the next applied command", function()
    local world, runtime = startedWorld()
    world.failSetEnabled[id("OPEN_WING", "ACCESS_PANEL")] = 1
    fillPower(world, 1)
    expectEqual(runtime:getObjectiveState("OPEN_WING"), "AVAILABLE", "the Core is unaffected by the prompt failure")
    expectFalse(world.enabled[id("OPEN_WING", "ACCESS_PANEL")], "stale prompt until the next reconcile")
    expectTrue(#world.logs >= 1)
    expectTrue(world.trigger("FIND_RECORDS", "RECORDS_CABINET", player(world, 2)))
    expectTrue(world.enabled[id("OPEN_WING", "ACCESS_PANEL")], "healed")
end)

test("completing the optional objective disables only its own prompt", function()
    local world, runtime = startedWorld()
    expectTrue(world.trigger("FIND_RECORDS", "RECORDS_CABINET", player(world, 1)))
    expectFalse(world.enabled[id("FIND_RECORDS", "RECORDS_CABINET")])
    expectTrue(world.enabled[id("RESTORE_POWER", "FUSE_A")])
    expectEqual(runtime:getResolution(), nil)
    world.flush()
    expectEqual(#world.endCalls, 0)
end)

-- 9-10. snapshots and revisions ------------------------------------------------------------------------------------

test("every applied command publishes one snapshot per connected participant with the next revision", function()
    local world, runtime = startedWorld()
    for userId = 1, 3 do
        local initial = world.sentTo(userId)
        expectEqual(#initial, 1, "initial snapshot")
        expectEqual(initial[1].revision, 0)
        expectEqual(initial[1].v, 1)
    end
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)))
    expectTrue(world.trigger("FIND_RECORDS", "RECORDS_CABINET", player(world, 2)))
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_B", player(world, 3)))
    for userId = 1, 3 do
        local received = world.sentTo(userId)
        expectEqual(#received, 4)
        for index = 1, 4 do
            expectEqual(received[index].revision, index - 1, "strictly consecutive revisions")
        end
    end
    expectEqual(runtime:getRevision(), 3)
end)

test("rejected commands do not publish a state update", function()
    local world, runtime = startedWorld()
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)))
    local sent = #world.sent
    local revision = runtime:getRevision()
    world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)) -- duplicate
    world.trigger("OPEN_WING", "ACCESS_PANEL", player(world, 1)) -- locked
    player(world, 2).alive = false
    world.trigger("RESTORE_POWER", "FUSE_B", player(world, 2)) -- dead
    world.lifecycleActive = false
    world.trigger("RESTORE_POWER", "FUSE_B", player(world, 1)) -- lifecycle not active
    expectEqual(#world.sent, sent)
    expectEqual(runtime:getRevision(), revision)
end)

-- 11. initial snapshot and pulls -----------------------------------------------------------------------------------

test("the initial snapshot goes only to connected roster members", function()
    local world = newWorld({ userIds = { 1, 2, 3, 50 } })
    player(world, 3).connected = false
    local runtime: any = ObjectiveRuntime.new(world.deps)
    runtime:start(SESSION)
    expectEqual(#world.sentTo(1), 1)
    expectEqual(#world.sentTo(2), 1)
    expectEqual(#world.sentTo(3), 0, "disconnected at start")
    expectEqual(#world.sentTo(50), 0, "not on the roster")
end)

test("a snapshot pull answers only the requester, only for roster members, with the current revision", function()
    local world, runtime = startedWorld({ userIds = { 1, 2, 3, 50 } })
    world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1))
    local before = #world.sent
    runtime:requestSnapshot(player(world, 2))
    expectEqual(#world.sent, before + 1)
    local last = world.sent[#world.sent]
    expectEqual(last.userId, 2)
    expectEqual(last.payload.revision, 1)
    runtime:requestSnapshot(player(world, 50))
    expectEqual(#world.sent, before + 1, "non-roster players get nothing")
    player(world, 3).connected = false
    runtime:requestSnapshot(player(world, 3))
    expectEqual(#world.sent, before + 1, "disconnected players get nothing")
    runtime:requestSnapshot(nil)
    runtime:requestSnapshot({})
    expectEqual(#world.sent, before + 1)
    expectEqual(runtime:getRevision(), 1, "a pull never changes state")
end)

-- 12. consumer safety ----------------------------------------------------------------------------------------------

-- The rule a client must apply (design 8.2, implemented by TTL-09C): accept only strictly newer revisions, starting
-- from -1. Here it is a test-local reducer that proves the server-side revision contract makes that rule sufficient.
local function accept(last: any, payload: any): any
    if type(payload) ~= "table" or type(payload.revision) ~= "number" then
        return last
    end
    if last ~= nil and payload.revision <= last.revision then
        return last
    end
    return payload
end

test("duplicate and stale deliveries cannot corrupt a consumer that applies the revision rule", function()
    local world, runtime = startedWorld()
    world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1))
    runtime:requestSnapshot(player(world, 1)) -- duplicate of revision 1
    world.trigger("RESTORE_POWER", "FUSE_B", player(world, 1))
    runtime:requestSnapshot(player(world, 1)) -- duplicate of revision 2
    local deliveries = world.sentTo(1)
    local expectedLatest = deliveries[#deliveries]

    -- in order
    local state: any = nil
    for _, payload in ipairs(deliveries) do
        state = accept(state, payload)
    end
    expectEqual(state.revision, 2)

    -- reversed (worst-case stale arrival order)
    local reversed: any = nil
    for index = #deliveries, 1, -1 do
        reversed = accept(reversed, deliveries[index])
    end
    expectEqual(reversed.revision, expectedLatest.revision)

    -- the revisions of applied commands are unique and increasing; only pulls repeat a revision
    local seen: { [number]: number } = {}
    for _, payload in ipairs(deliveries) do
        seen[payload.revision] = (seen[payload.revision] or 0) + 1
    end
    expectEqual(seen[0], 1)
    expectEqual(seen[1], 2, "one broadcast plus one pull")
    expectEqual(seen[2], 2, "one broadcast plus one pull")
end)

-- 13. several players ----------------------------------------------------------------------------------------------

test("all participants receive identical authoritative state and independent copies", function()
    local world, runtime = startedWorld()
    world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1))
    world.trigger("RESTORE_POWER", "FUSE_B", player(world, 2))
    world.trigger("RESTORE_POWER", "FUSE_C", player(world, 3))
    local function serialize(payload: any): string
        local parts = { tostring(payload.revision) }
        for _, entry in ipairs(payload.objectives) do
            table.insert(parts, entry.id .. ":" .. entry.state .. ":" .. entry.filled .. "/" .. entry.required)
        end
        return table.concat(parts, "|")
    end
    local reference = world.sentTo(1)
    expectEqual(#reference, 4)
    for userId = 2, 3 do
        local received = world.sentTo(userId)
        expectEqual(#received, #reference)
        for index = 1, #reference do
            expectEqual(serialize(received[index]), serialize(reference[index]), "player " .. userId .. " revision " .. (index - 1))
        end
    end
    -- the payload tables are independent copies per player
    local first = world.sentTo(1)[4]
    local second = world.sentTo(2)[4]
    expectFalse(rawequal(first, second))
    first.objectives[1].state = "TAMPERED"
    expectEqual(second.objectives[1].state, "COMPLETED")
    expectEqual(runtime:getObjectiveState("RESTORE_POWER"), "COMPLETED")
    -- contributions of different players all counted: three different contributors filled three slots
    expectEqual(runtime:getRevision(), 3)
end)

test("a failing delivery to one player does not stop the others or the command", function()
    local world, runtime = startedWorld()
    world.failSendFor[2] = true
    expectTrue(world.trigger("RESTORE_POWER", "FUSE_A", player(world, 1)))
    expectEqual(#world.sentTo(1), 2)
    expectEqual(#world.sentTo(2), 1, "only the initial snapshot")
    expectEqual(#world.sentTo(3), 2)
    expectEqual(runtime:getRevision(), 1)
    expectTrue(#world.logs >= 1)
    -- the player can recover through a pull once delivery works again
    world.failSendFor[2] = nil
    runtime:requestSnapshot(player(world, 2))
    expectEqual(world.sentTo(2)[2].revision, 1)
end)

-- 14. resolution and lifecycle ownership ---------------------------------------------------------------------------

local function completeAll(world: any)
    fillPower(world, 1)
    expectTrue(world.trigger("OPEN_WING", "ACCESS_PANEL", player(world, 2)))
    expectTrue(world.trigger("EXTRACT", "EXTRACTION_POINT", player(world, 3)))
end

test("a resolution is reported to the lifecycle once, deferred, through its own API", function()
    local world, runtime = startedWorld()
    completeAll(world)
    expectEqual(runtime:getResolution().outcome, "COMPLETED")
    expectEqual(#world.endCalls, 0, "never inside the interaction handler")
    expectEqual(#world.deferred, 1)
    world.flush()
    expectEqual(#world.endCalls, 1)
    expectEqual(world.endCalls[1].outcome, "COMPLETED")
    expectEqual(world.endCalls[1].reason, "objectives_complete")
    world.flush()
    expectEqual(#world.endCalls, 1, "exactly once")
    -- further activations are rejected and never re-report
    expectFalse(world.trigger("FIND_RECORDS", "RECORDS_CABINET", player(world, 1)))
    world.flush()
    expectEqual(#world.endCalls, 1)
end)

test("resolution never overrides a lifecycle that already left ACTIVE", function()
    local world = startedWorld()
    completeAll(world)
    world.lifecycleActive = false -- someone else (shutdown, another system) ended the mission first
    world.flush()
    expectEqual(#world.endCalls, 0)
end)

test("resolution is dropped when the runtime stops before the deferred report runs", function()
    local world, runtime = startedWorld()
    completeAll(world)
    runtime:stop()
    world.flush()
    expectEqual(#world.endCalls, 0)
end)

test("a lifecycle that rejects or raises on endMission does not break the runtime", function()
    local world, runtime = startedWorld()
    world.endMissionRaises = true
    completeAll(world)
    world.flush()
    expectEqual(#world.endCalls, 0)
    expectTrue(#world.logs >= 1)
    expectTrue(runtime:isRunning())
    expectEqual(runtime:getResolution().outcome, "COMPLETED")
end)

test("the runtime only uses isActive and endMission of the lifecycle", function()
    local world = newWorld()
    local touched: { [string]: boolean } = {}
    local real = world.deps.lifecycle
    world.deps.lifecycle = setmetatable({}, {
        __index = function(_, key: any): any
            touched[tostring(key)] = true
            return real[key]
        end,
    })
    local runtime: any = ObjectiveRuntime.new(world.deps)
    runtime:start(SESSION)
    completeAll(world)
    world.flush()
    for key in pairs(touched) do
        expectTrue(key == "isActive" or key == "endMission", "unexpected lifecycle access: " .. key)
    end
    expectTrue(touched.endMission == true)
end)

-- binding failures -------------------------------------------------------------------------------------------------

test("a missing anchor of a REQUIRED objective aborts the start and rolls back every registration", function()
    local world = newWorld({ missingAnchors = { EXTRACTION_POINT = true } })
    local runtime: any = ObjectiveRuntime.new(world.deps)
    local ok, err = pcall(function()
        runtime:start(SESSION)
    end)
    expectFalse(ok)
    expectTrue(string.find(tostring(err), "EXTRACT", 1, true) ~= nil, tostring(err))
    expectFalse(runtime:isRunning())
    expectEqual(#world.unregistered, #world.registerOrder, "everything registered was unregistered")
    expectEqual(next(world.handlers), nil)
    expectEqual(#world.sent, 0)
end)

test("a rejected registration of a REQUIRED slot aborts the start and rolls back", function()
    local world = newWorld({ failRegister = { [id("OPEN_WING", "ACCESS_PANEL")] = "prompt_failed" } })
    local runtime: any = ObjectiveRuntime.new(world.deps)
    expectFalse(pcall(function()
        runtime:start(SESSION)
    end))
    expectFalse(runtime:isRunning())
    expectEqual(next(world.handlers), nil)
    expectEqual(#world.unregistered, 3)
end)

test("a missing anchor of an OPTIONAL available objective cancels it and the mission continues", function()
    local world, runtime = startedWorld({ missingAnchors = { RECORDS_CABINET = true } })
    expectTrue(runtime:isRunning())
    expectEqual(runtime:getObjectiveState("FIND_RECORDS"), "CANCELLED")
    expectEqual(runtime:getRevision(), 1)
    expectEqual(world.handlers[id("FIND_RECORDS", "RECORDS_CABINET")], nil)
    expectTrue(#world.logs >= 1)
    local first = world.sentTo(1)[1]
    expectEqual(first.revision, 1)
    expectEqual(snapshotState(first, "FIND_RECORDS"), "CANCELLED")
    completeAll(world)
    expectEqual(runtime:getResolution().outcome, "COMPLETED")
end)

test("an OPTIONAL objective that cannot be bound while LOCKED cannot be cancelled, so the start aborts", function()
    local content = {
        version = 1,
        objectives = {
            { id = "A", importance = "REQUIRED", title = "T", description = "D", completion = { kind = "SLOTS", slots = { { id = "S", pointId = "PA", label = "L" } } } },
            { id = "B", importance = "OPTIONAL", requires = { allOf = { "A" } }, title = "T", description = "D", completion = { kind = "SLOTS", slots = { { id = "S", pointId = "PB", label = "L" } } } },
        },
    }
    local world = newWorld({ content = content, missingAnchors = { PB = true } })
    local runtime: any = ObjectiveRuntime.new(world.deps)
    expectFalse(pcall(function()
        runtime:start(SESSION)
    end))
    expectFalse(runtime:isRunning())
    expectEqual(next(world.handlers), nil)
end)

-- spec and prompt text generation ----------------------------------------------------------------------------------

test("generated specs and prompt options are valid for every slot of the shipped content", function()
    local seen: { [string]: boolean } = {}
    for _, objective in ipairs(ObjectiveContent.objectives) do
        if objective.completion.kind == "SLOTS" then
            for _, slot in ipairs(objective.completion.slots) do
                local spec = ObjectiveRuntime.buildSpec(ObjectiveConfig.Values, objective.id, slot.id)
            local ok, detail = InteractionCore.validateSpec(spec)
            expectTrue(ok, tostring(detail))
            expectTrue(#spec.id <= InteractionCore.Limits.MaxIdLength)
            expectEqual(seen[spec.id], nil, "unique interaction id " .. spec.id)
            seen[spec.id] = true
            expectEqual(spec.enabled, false)
            local options = ObjectiveRuntime.buildPromptOptions(ObjectiveConfig.Values, slot.label)
            expectEqual(options.actionText, "Use")
                expectEqual(options.objectText, slot.label)
            end
        end
    end
end)
