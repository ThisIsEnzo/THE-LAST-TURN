--!strict
local Harness = require("../Harness")
local EvidenceCatalog = require("../../src/server_shared/Evidence/EvidenceCatalog")
local EvidenceCore = require("../../src/server_shared/Evidence/EvidenceCore")
local EvidenceRuntime = require("../../src/server_shared/Evidence/EvidenceRuntime")
local EvidenceContent = require("../../src/mission/server/Evidence/EvidenceContent")
local EvidenceConfig = require("../../src/mission/server/Evidence/EvidenceConfig")
local InteractionCore = require("../../src/server_shared/Interaction/InteractionCore")
local RateLimiter = require("../../src/server_shared/Network/RateLimiter")
local InteractionConfig = require("../../src/mission/server/Interaction/InteractionConfig")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

-- Fakes ------------------------------------------------------------------------------------------------------------------
-- A small in-memory world. The interaction layer is the REAL InteractionCore plus the REAL RateLimiter (so range, dead
-- players, non-participants, disabled prompts, busy/cooldown and throttling are enforced by the production code); the
-- lifecycle, players, anchors and network are fakes. The runtime under test is the real one, wired to the real
-- EvidenceCatalog, EvidenceCore, shipped EvidenceContent and EvidenceConfig.

local function sourceCandidates(): { any }
    -- COLD_SPOT needs 2, STATIC_INTERFERENCE 2, MOVED_OBJECT 1, VOICE_ECHO 3 distinct sources.
    local list = {}
    local function add(evidenceId: string, sourceId: string)
        table.insert(list, { evidenceId = evidenceId, sourceId = sourceId, anchor = { name = evidenceId .. "/" .. sourceId, available = true } })
    end
    add("COLD_SPOT", "CELLAR")
    add("COLD_SPOT", "ATTIC")
    add("STATIC_INTERFERENCE", "RADIO_ROOM")
    add("STATIC_INTERFERENCE", "BOILER")
    add("MOVED_OBJECT", "NURSERY")
    add("VOICE_ECHO", "STAIRS")
    add("VOICE_ECHO", "CORRIDOR")
    add("VOICE_ECHO", "CHAPEL")
    return list
end

local function newWorld(options: any?): any
    local opts: any = options or {}
    local world: any = {
        lifecycleActive = opts.lifecycleActive ~= false,
        sent = {}, -- { userId, payload }
        handlers = {}, -- interaction id -> handler
        handles = {}, -- interaction id -> handle
        enabled = {}, -- interaction id -> boolean
        unregistered = {},
        logs = {},
        failSendFor = {},
        failRegister = opts.failRegister or {}, -- interaction id -> reason
        failSetEnabled = {}, -- interaction id -> remaining failures
        clock = 0,
        players = {},
        candidates = opts.candidates or sourceCandidates(),
        missions = 0,
    }
    for _, userId in ipairs(opts.userIds or { 1, 2, 3 }) do
        world.players[userId] = { UserId = userId, alive = true, connected = true, distance = 3, character = true }
    end
    world.interactionCore = InteractionCore.new()
    local interactLimit = InteractionConfig.Values.rateLimit
    world.limiter = RateLimiter.new({ [interactLimit.action] = { capacity = interactLimit.capacity, refillPerSecond = interactLimit.refillPerSecond } }, function(): number
        return world.clock
    end)
    world.anchorToId = {}
    world.idToAnchor = {}

    local interaction = {}
    function interaction.register(spec: any, anchor: any, handler: any, promptOptions: any): (any, string?)
        if world.failRegister[spec.id] ~= nil then
            return nil, world.failRegister[spec.id]
        end
        if type(promptOptions) ~= "table" or type(promptOptions.actionText) ~= "string" or type(promptOptions.objectText) ~= "string" then
            return nil, "invalid_options"
        end
        local handle, reason = world.interactionCore:register(spec, anchor)
        if handle == nil then
            return nil, reason
        end
        world.handlers[spec.id] = handler
        world.handles[spec.id] = handle
        world.enabled[spec.id] = spec.enabled ~= false
        world.anchorToId[anchor] = spec.id
        world.idToAnchor[spec.id] = anchor
        world.promptOptions = promptOptions
        world.lastSpec = spec
        return handle, nil
    end
    function interaction.setEnabled(handle: any, enabled: any): (boolean, string?)
        local remaining = world.failSetEnabled[handle.id]
        if remaining ~= nil and remaining > 0 then
            world.failSetEnabled[handle.id] = remaining - 1
            return false, "prompt_failed"
        end
        local ok, reason = world.interactionCore:setEnabled(handle, enabled)
        if ok then
            world.enabled[handle.id] = enabled
        end
        return ok, reason
    end
    function interaction.unregister(handle: any): (boolean, string?)
        local ok, reason = world.interactionCore:unregister(handle)
        if ok then
            world.handlers[handle.id] = nil
            world.enabled[handle.id] = nil
            table.insert(world.unregistered, handle.id)
        end
        return ok, reason
    end

    local lifecycle = {}
    function lifecycle.isActive(): boolean
        return world.lifecycleActive
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
        catalog = EvidenceCatalog,
        core = EvidenceCore,
        content = opts.content or EvidenceContent,
        config = opts.config or EvidenceConfig.Values,
        interaction = interaction,
        collectSources = function(): { any }
            return world.candidates
        end,
        isAvailable = function(anchor: any): boolean
            return anchor.available == true
        end,
        lifecycle = lifecycle,
        players = players,
        send = function(player: any, payload: any)
            if world.failSendFor[player.UserId] then
                error("send boom")
            end
            table.insert(world.sent, { userId = player.UserId, payload = payload })
        end,
        now = function(): number
            return world.clock -- advances only through world.advance, so rate limiting and cooldowns are deterministic
        end,
        log = function(message: string)
            table.insert(world.logs, message)
        end,
    }

    -- The activation pipeline of InteractionService, with the production core and rate limiter.
    function world.interact(sourceKey: string, player: any, overrides: any?): any
        local anchor: any = nil
        for _, candidate in ipairs(world.candidates) do
            if candidate.evidenceId .. "/" .. candidate.sourceId == sourceKey then
                anchor = candidate.anchor
            end
        end
        local id = world.anchorToId[anchor]
        if id == nil then
            return { ok = false, reason = "no_prompt" }
        end
        local o: any = overrides or {}
        local isParticipant = world.roster ~= nil and world.roster[player.UserId] == true
        local context = {
            missionActive = world.lifecycleActive,
            isParticipant = isParticipant,
            playerEligible = player.alive == true,
            characterAvailable = player.character == true,
            targetAvailable = anchor.available == true,
            distance = o.distance or player.distance,
            now = world.clock,
        }
        local hooks = {
            consumeToken = function(): boolean
                return world.limiter:tryConsume(player.UserId, InteractionConfig.Values.rateLimit.action)
            end,
            handler = function(): boolean
                return world.handlers[id](player)
            end,
        }
        return world.interactionCore:activate(world.handles[id], context, hooks)
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
    function world.advance(seconds: number)
        world.clock = world.clock + seconds
    end
    return world
end

local SESSION = { expectedUserIds = { 1, 2, 3 } }

local function started(options: any?): (any, any)
    local world = newWorld(options)
    local runtime: any = EvidenceRuntime.new(world.deps)
    local session = (options and options.session) or SESSION
    world.roster = {}
    for _, userId in ipairs(session.expectedUserIds) do
        world.roster[userId] = true
    end
    runtime:start(session)
    return world, runtime
end

local function player(world: any, userId: number): any
    return world.players[userId]
end

-- The interaction id of an authored source ("EVIDENCE/SOURCE"); ids are assigned in sorted key order.
local function idOf(world: any, sourceKey: string): string
    for id, anchor in pairs(world.idToAnchor) do
        if anchor.name == sourceKey then
            return id
        end
    end
    error("no prompt registered for " .. sourceKey)
end

local function expectOk(result: any, label: string?)
    expectTrue(result.ok, (label or "activation") .. ": " .. tostring(result.reason))
end

local function snapshotEntry(snapshot: any, id: string): any
    for _, entry in ipairs(snapshot.evidence) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

local function lastSnapshot(world: any, userId: number): any
    local received = world.sentTo(userId)
    return received[#received]
end

-- initialization -----------------------------------------------------------------------------------------------------------

test("initialization with the shipped content registers one generic prompt per authored source", function()
    local world, runtime = started()
    expectTrue(runtime:isRunning())
    local count = 0
    for _ in pairs(world.handlers) do
        count = count + 1
    end
    expectEqual(count, 8)
    for id, spec in pairs({ EVD_1 = true, EVD_8 = true }) do
        expectTrue(world.handlers[id] ~= nil, id)
    end
    expectEqual(world.promptOptions.actionText, "Examine")
    expectEqual(world.promptOptions.objectText, "Strange sign", "the prompt never names the evidence")
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "UNKNOWN")
    expectEqual(runtime:getRevision(), 0)
    local progress = runtime:getProgress()
    expectEqual(progress.total, 4)
    expectEqual(progress.unknown, 4)
end)

test("interaction ids are deterministic and independent of the order the world reports sources", function()
    local world = newWorld()
    local reversed = {}
    for index = #world.candidates, 1, -1 do
        table.insert(reversed, world.candidates[index])
    end
    local other = newWorld({ candidates = reversed })
    local a: any = EvidenceRuntime.new(world.deps)
    local b: any = EvidenceRuntime.new(other.deps)
    a:start(SESSION)
    b:start(SESSION)
    for position = 1, 8 do
        local id = "EVD_" .. position
        expectEqual(world.idToAnchor[id].name, other.idToAnchor[id].name, id)
    end
end)

test("the first reconciliation enables every available source prompt", function()
    local world = started()
    for id, enabled in pairs(world.enabled) do
        expectTrue(enabled, id)
    end
end)

test("invalid evidence content fails the start loudly and leaves nothing behind", function()
    local invalid = { version = 1, evidence = { { id = "A", category = "C", title = "T", description = "D", confirmation = { distinctSources = 0 } } } }
    local world = newWorld({ content = invalid })
    local runtime: any = EvidenceRuntime.new(world.deps)
    local ok, err = pcall(function()
        runtime:start(SESSION)
    end)
    expectFalse(ok)
    expectTrue(string.find(tostring(err), "invalid_distinct_sources", 1, true) ~= nil, tostring(err))
    expectFalse(runtime:isRunning())
    expectEqual(next(world.handlers), nil)
    expectEqual(#world.sent, 0)
    runtime:stop()
end)

test("a missing, empty or malformed roster fails the start", function()
    for _, session in ipairs({ {}, { expectedUserIds = {} }, { expectedUserIds = { 1, 1 } }, { expectedUserIds = { 0 } }, { expectedUserIds = { "1" } } }) do
        local world = newWorld()
        local runtime: any = EvidenceRuntime.new(world.deps)
        expectFalse(pcall(function()
            runtime:start(session)
        end))
        expectFalse(runtime:isRunning())
        expectEqual(next(world.handlers), nil)
    end
    local world = newWorld()
    local runtime: any = EvidenceRuntime.new(world.deps)
    expectFalse(pcall(function()
        runtime:start(nil)
    end))
end)

test("the runtime requires complete dependencies and starts only once", function()
    Harness.expectError(function()
        EvidenceRuntime.new({} :: any)
    end)
    local world, runtime = started()
    Harness.expectError(function()
        runtime:start(SESSION)
    end, "second start")
    expectTrue(runtime:isRunning())
    local count = 0
    for _ in pairs(world.handlers) do
        count = count + 1
    end
    expectEqual(count, 8, "no duplicate registrations")
end)

-- valid interactions -------------------------------------------------------------------------------------------------------

test("a valid player discovers valid evidence: the authoritative ledger changes and a snapshot is published", function()
    local world, runtime = started()
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "OBSERVED")
    expectEqual(runtime:getRevision(), 1)
    local progress = runtime:getProgress()
    expectEqual(progress.observed, 1)
    expectEqual(progress.unknown, 3)
    local snapshot = lastSnapshot(world, 1)
    expectEqual(snapshot.revision, 1)
    local entry = snapshotEntry(snapshot, "COLD_SPOT")
    expectEqual(entry.state, "OBSERVED")
    expectEqual(entry.sources, 1)
    expectEqual(entry.required, 2)
    expectFalse(world.enabled[idOf(world, "COLD_SPOT/CELLAR")], "the used source's prompt is disabled")
    expectTrue(world.enabled[idOf(world, "COLD_SPOT/ATTIC")], "the other source stays available")
end)

test("a second player receives the updated team state and every participant sees the same ledger", function()
    local world = started()
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    for userId = 1, 3 do
        local snapshot = lastSnapshot(world, userId)
        expectEqual(snapshot.revision, 1, "player " .. userId)
        expectEqual(snapshotEntry(snapshot, "COLD_SPOT").state, "OBSERVED")
    end
    expectOk(world.interact("MOVED_OBJECT/NURSERY", player(world, 2)))
    for userId = 1, 3 do
        local snapshot = lastSnapshot(world, userId)
        expectEqual(#snapshot.evidence, 3 - 1, "two discovered evidence entries")
        expectEqual(snapshotEntry(snapshot, "MOVED_OBJECT").state, "CONFIRMED")
    end
    -- identical content and independent copies per player
    local first, second = lastSnapshot(world, 1), lastSnapshot(world, 2)
    expectFalse(rawequal(first, second))
    first.evidence[1].state = "TAMPERED"
    expectEqual(lastSnapshot(world, 2).evidence[1].state, "OBSERVED")
end)

test("distinct sources corroborate and the evidence is confirmed by policy; the core's rules are not duplicated", function()
    local world, runtime = started()
    expectOk(world.interact("STATIC_INTERFERENCE/RADIO_ROOM", player(world, 1)))
    expectEqual(runtime:getEvidenceState("STATIC_INTERFERENCE"), "OBSERVED", "one of two sources is not enough")
    expectOk(world.interact("STATIC_INTERFERENCE/BOILER", player(world, 2)))
    expectEqual(runtime:getEvidenceState("STATIC_INTERFERENCE"), "CONFIRMED")
    expectEqual(runtime:getRevision(), 3, "observe, observe and confirm are three applied core commands")
    expectEqual(lastSnapshot(world, 3).revision, 3)
    expectEqual(#world.sentTo(3), 3, "initial snapshot plus one snapshot per applied activation, not per core command")
    local entry = snapshotEntry(lastSnapshot(world, 3), "STATIC_INTERFERENCE")
    expectEqual(entry.state, "CONFIRMED")
    expectEqual(entry.sources, 2)
end)

test("three-source evidence needs three distinct sources", function()
    local world, runtime = started()
    expectOk(world.interact("VOICE_ECHO/STAIRS", player(world, 1)))
    expectOk(world.interact("VOICE_ECHO/CORRIDOR", player(world, 2)))
    expectEqual(runtime:getEvidenceState("VOICE_ECHO"), "OBSERVED")
    expectOk(world.interact("VOICE_ECHO/CHAPEL", player(world, 3)))
    expectEqual(runtime:getEvidenceState("VOICE_ECHO"), "CONFIRMED")
end)

test("a confirmed evidence disables all of its remaining prompts", function()
    local world = started()
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    expectOk(world.interact("COLD_SPOT/ATTIC", player(world, 1)))
    for id, anchor in pairs(world.idToAnchor) do
        if string.find(anchor.name, "COLD_SPOT", 1, true) ~= nil then
            expectFalse(world.enabled[id], anchor.name)
        end
    end
    expectTrue(world.enabled["EVD_8"] or world.enabled["EVD_7"], "other evidence stays available")
end)

test("with confirmation by policy switched off, evidence stays OBSERVED however many sources agree", function()
    local config = { interaction = EvidenceConfig.Values.interaction, prompt = EvidenceConfig.Values.prompt, confirmWhenCorroborated = false }
    local world, runtime = started({ config = config })
    expectOk(world.interact("STATIC_INTERFERENCE/RADIO_ROOM", player(world, 1)))
    expectOk(world.interact("STATIC_INTERFERENCE/BOILER", player(world, 2)))
    expectEqual(runtime:getEvidenceState("STATIC_INTERFERENCE"), "OBSERVED")
    expectEqual(runtime:getRevision(), 2)
end)

-- joining players ----------------------------------------------------------------------------------------------------------

test("every connected participant receives the initial snapshot; a player who joins later pulls the current state", function()
    local world = newWorld()
    player(world, 3).connected = false
    local runtime: any = EvidenceRuntime.new(world.deps)
    world.roster = { [1] = true, [2] = true, [3] = true }
    runtime:start(SESSION)
    expectEqual(#world.sentTo(1), 1)
    expectEqual(#world.sentTo(2), 1)
    expectEqual(#world.sentTo(3), 0, "not connected at start")
    expectEqual(lastSnapshot(world, 1).revision, 0)
    expectEqual(#lastSnapshot(world, 1).evidence, 0)

    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    player(world, 3).connected = true -- the player arrives
    runtime:requestSnapshot(player(world, 3))
    local snapshot = lastSnapshot(world, 3)
    expectEqual(snapshot.revision, 1)
    expectEqual(snapshotEntry(snapshot, "COLD_SPOT").state, "OBSERVED")
    expectEqual(#world.sentTo(3), 1, "the pull answered only the requester")
    expectEqual(#world.sentTo(2), 2, "others were not re-sent anything")
end)

test("a snapshot pull is answered only to connected roster members while running", function()
    local world, runtime = started({ userIds = { 1, 2, 3, 50 } })
    local before = #world.sent
    runtime:requestSnapshot(player(world, 50))
    expectEqual(#world.sent, before, "not on the roster")
    player(world, 2).connected = false
    runtime:requestSnapshot(player(world, 2))
    expectEqual(#world.sent, before, "disconnected")
    runtime:requestSnapshot(nil)
    runtime:requestSnapshot({})
    expectEqual(#world.sent, before)
    runtime:requestSnapshot(player(world, 1))
    expectEqual(#world.sent, before + 1)
    expectEqual(runtime:getRevision(), 0, "a pull never changes state")
    runtime:stop()
    runtime:requestSnapshot(player(world, 1))
    expectEqual(#world.sent, before + 1, "nothing after stop")
end)

-- privacy ------------------------------------------------------------------------------------------------------------------

test("the snapshot never leaks undiscovered evidence, sources, contributors or locations", function()
    local world = started()
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 424242 % 3 + 1)))
    local snapshot = lastSnapshot(world, 1)
    expectEqual(#snapshot.evidence, 1)
    expectEqual(snapshot.total, 4, "only the count of evidence in the mission is public")
    local function scan(value: any, path: string)
        if type(value) == "table" then
            for key, inner in pairs(value) do
                expectTrue(key ~= "observations" and key ~= "sourceId" and key ~= "observerId" and key ~= "confirmedBy" and key ~= "anchor", "key " .. tostring(key))
                scan(inner, path .. "." .. tostring(key))
            end
        elseif type(value) == "string" then
            for _, secret in ipairs({ "CELLAR", "ATTIC", "RADIO_ROOM", "BOILER", "NURSERY", "STAIRS", "CORRIDOR", "CHAPEL", "STATIC_INTERFERENCE", "MOVED_OBJECT", "VOICE_ECHO" }) do
                expectFalse(string.find(value, secret, 1, true) ~= nil, secret .. " leaked at " .. path)
            end
        end
    end
    scan(snapshot, "snapshot")
    local allowed: { [string]: boolean } = { id = true, title = true, category = true, state = true, sources = true, required = true }
    for key in pairs(snapshot.evidence[1]) do
        expectTrue(allowed[key] == true, "unexpected entry key " .. tostring(key))
    end
    for key in pairs(snapshot) do
        expectTrue(key == "v" or key == "revision" or key == "total" or key == "evidence", "unexpected snapshot key " .. tostring(key))
    end
end)

test("prompts are generic and identical for every source", function()
    local world = started()
    local seen: { [string]: boolean } = {}
    for _, candidate in ipairs(world.candidates) do
        local id = world.anchorToId[candidate.anchor]
        local spec = world.interactionCore:getState(world.handles[id])
        expectEqual(spec.maxDistance, EvidenceConfig.Values.interaction.maxDistance)
        seen[id] = true
    end
    expectEqual(world.promptOptions.objectText, EvidenceConfig.Values.prompt.objectText)
end)

-- invalid interactions -----------------------------------------------------------------------------------------------------

local function expectNoChange(world: any, runtime: any, revision: number, sent: number, label: string)
    expectEqual(runtime:getRevision(), revision, label)
    expectEqual(#world.sent, sent, label)
end

test("a player outside the interaction range is rejected by the real interaction core", function()
    local world, runtime = started()
    local sent = #world.sent
    local result = world.interact("COLD_SPOT/CELLAR", player(world, 1), { distance = 40 })
    expectFalse(result.ok)
    expectEqual(result.reason, InteractionCore.Reasons.OUT_OF_RANGE)
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "UNKNOWN")
    expectNoChange(world, runtime, 0, sent, "out of range")
    -- the exact boundary is accepted
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1), { distance = EvidenceConfig.Values.interaction.maxDistance }))
end)

test("a dead (not ALIVE) player cannot discover evidence", function()
    local world, runtime = started()
    player(world, 2).alive = false
    local sent = #world.sent
    local result = world.interact("COLD_SPOT/CELLAR", player(world, 2))
    expectFalse(result.ok)
    expectEqual(result.reason, InteractionCore.Reasons.PLAYER_NOT_ELIGIBLE)
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "UNKNOWN")
    expectNoChange(world, runtime, 0, sent, "dead player")
end)

test("a defense in depth: the handler itself refuses a player who is not alive, not on the roster or disconnected", function()
    local world, runtime = started({ userIds = { 1, 2, 3, 99 } })
    local sent = #world.sent
    local handler = world.handlers["EVD_1"]
    player(world, 2).alive = false
    expectFalse(handler(player(world, 2)))
    expectFalse(handler(player(world, 99)), "not on the roster")
    player(world, 3).connected = false
    expectFalse(handler(player(world, 3)), "disconnected")
    expectFalse(handler(nil))
    expectFalse(handler("x"))
    expectFalse(handler({}))
    expectNoChange(world, runtime, 0, sent, "direct handler calls")
end)

test("a player who is not in the active mission is rejected", function()
    local world, runtime = started({ userIds = { 1, 2, 3, 99 } })
    local sent = #world.sent
    local result = world.interact("COLD_SPOT/CELLAR", player(world, 99))
    expectFalse(result.ok)
    expectEqual(result.reason, InteractionCore.Reasons.NOT_PARTICIPANT)
    expectNoChange(world, runtime, 0, sent, "non participant")
end)

test("a mission that is not ACTIVE does not accept evidence interactions", function()
    local world, runtime = started({ lifecycleActive = false })
    local sent = #world.sent
    local result = world.interact("COLD_SPOT/CELLAR", player(world, 1))
    expectFalse(result.ok)
    expectEqual(result.reason, InteractionCore.Reasons.MISSION_INACTIVE)
    expectNoChange(world, runtime, 0, sent, "inactive before start")
    -- even if the interaction layer let it through, the runtime refuses on its own
    expectFalse(world.handlers["EVD_1"](player(world, 1)))
    expectNoChange(world, runtime, 0, sent, "handler while inactive")
    world.lifecycleActive = true
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    world.lifecycleActive = false -- ENDING / ENDED
    local revision = runtime:getRevision()
    local after = #world.sent
    expectFalse(world.interact("COLD_SPOT/ATTIC", player(world, 1)).ok)
    expectFalse(world.handlers["EVD_1"](player(world, 1)))
    expectNoChange(world, runtime, revision, after, "after the mission left ACTIVE")
end)

test("a missing or unavailable world object cannot be used", function()
    local world, runtime = started()
    local sent = #world.sent
    for _, candidate in ipairs(world.candidates) do
        if candidate.sourceId == "CELLAR" then
            candidate.anchor.available = false
        end
    end
    local result = world.interact("COLD_SPOT/CELLAR", player(world, 1))
    expectFalse(result.ok)
    expectEqual(result.reason, InteractionCore.Reasons.TARGET_UNAVAILABLE)
    -- the handler re-checks availability on its own even if the interaction layer was fooled
    expectFalse(world.handlers[idOf(world, "COLD_SPOT/CELLAR")](player(world, 1)))
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "UNKNOWN")
    expectNoChange(world, runtime, 0, sent, "unavailable object")
    expectFalse(world.interact("NOT_A_SOURCE/X", player(world, 1)).ok, "no prompt exists for an unknown source")
end)

test("a prompt that becomes unavailable between commands is healed by the next reconcile", function()
    local world, runtime = started()
    for _, candidate in ipairs(world.candidates) do
        if candidate.sourceId == "ATTIC" then
            candidate.anchor.available = false
        end
    end
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    local atticId: string = ""
    for id, anchor in pairs(world.idToAnchor) do
        if anchor.name == "COLD_SPOT/ATTIC" then
            atticId = id
        end
    end
    expectFalse(world.enabled[atticId], "an unavailable source stays disabled")
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "OBSERVED")
end)

test("malformed evidence ids and source ids never create a prompt (unknown evidence, invalid tokens, duplicates)", function()
    local good = sourceCandidates()
    local extra = {
        { evidenceId = "NOT_IN_CATALOG", sourceId = "SOMEWHERE", anchor = { name = "unknown", available = true } },
        { evidenceId = "cold_spot", sourceId = "LOWER", anchor = { name = "bad evidence token", available = true } },
        { evidenceId = "COLD_SPOT", sourceId = "has space", anchor = { name = "bad source token", available = true } },
        { evidenceId = "COLD_SPOT", sourceId = nil, anchor = { name = "no source", available = true } },
        { evidenceId = 5, sourceId = "X", anchor = { name = "number", available = true } },
        { evidenceId = "COLD_SPOT", sourceId = "NOANCHOR", anchor = nil },
        "not a table",
        { evidenceId = "MOVED_OBJECT", sourceId = "TWIN", anchor = { name = "twin one", available = true } },
        { evidenceId = "MOVED_OBJECT", sourceId = "TWIN", anchor = { name = "twin two", available = true } },
    }
    for _, entry in ipairs(extra) do
        table.insert(good, entry)
    end
    local world, runtime = started({ candidates = good })
    local count = 0
    for _ in pairs(world.handlers) do
        count = count + 1
    end
    expectEqual(count, 8, "only the eight valid authored sources are bound")
    for _, anchor in pairs(world.idToAnchor) do
        expectTrue(string.find(anchor.name, "COLD_SPOT/", 1, true) ~= nil or string.find(anchor.name, "/", 1, true) ~= nil, anchor.name)
        expectTrue(anchor.name ~= "twin one" and anchor.name ~= "twin two" and anchor.name ~= "unknown", "ambiguous or unknown objects are not used")
    end
    expectTrue(#world.logs >= 3, "the problems are logged")
    expectEqual(runtime:getRevision(), 0)
end)

test("indexSources is pure, order independent and fail-closed", function()
    local plan: any = EvidenceCatalog.compile(EvidenceContent)
    local list = {
        { evidenceId = "COLD_SPOT", sourceId = "B", anchor = 2 },
        { evidenceId = "COLD_SPOT", sourceId = "A", anchor = 1 },
        { evidenceId = "COLD_SPOT", sourceId = "A", anchor = 3 },
        { evidenceId = "NOPE", sourceId = "A", anchor = 4 },
        { evidenceId = "bad", sourceId = "A", anchor = 5 },
    }
    local reversed = {}
    for index = #list, 1, -1 do
        table.insert(reversed, list[index])
    end
    local first = EvidenceRuntime.indexSources(list, plan, EvidenceCatalog.isToken)
    local second = EvidenceRuntime.indexSources(reversed, plan, EvidenceCatalog.isToken)
    expectEqual(#first.sources, 1)
    expectEqual(first.sources[1].sourceId, "B")
    expectEqual(table.concat(first.duplicates, ","), "COLD_SPOT/A")
    expectEqual(table.concat(first.unknown, ","), "NOPE")
    expectEqual(first.invalid, 1)
    expectEqual(#second.sources, 1)
    expectEqual(table.concat(second.duplicates, ","), table.concat(first.duplicates, ","))
    expectEqual(second.invalid, first.invalid)
    local empty = EvidenceRuntime.indexSources("garbage", plan, EvidenceCatalog.isToken)
    expectEqual(#empty.sources, 0)
end)

test("a rejected registration is logged and that source is simply unavailable", function()
    local world, runtime = started({ failRegister = { EVD_1 = "prompt_failed" } })
    expectTrue(runtime:isRunning())
    expectEqual(world.handlers["EVD_1"], nil)
    expectTrue(#world.logs >= 1)
    expectEqual(world.handlers["EVD_2"] ~= nil, true)
end)

test("evidence that cannot be confirmed with the bound sources is reported at start", function()
    local few = {
        { evidenceId = "VOICE_ECHO", sourceId = "ONLY_ONE", anchor = { name = "one", available = true } },
    }
    local world = started({ candidates = few })
    local found = false
    for _, message in ipairs(world.logs) do
        if string.find(message, "VOICE_ECHO", 1, true) ~= nil and string.find(message, "needs 3", 1, true) ~= nil then
            found = true
        end
    end
    expectTrue(found)
end)

-- duplicates and throttling ----------------------------------------------------------------------------------------------

test("repeated discovery from the same source cannot inflate progress", function()
    local world, runtime = started()
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    local revision = runtime:getRevision()
    local progress = runtime:getProgress()
    local sent = #world.sent
    for userId = 1, 3 do
        world.advance(5)
        local result = world.interact("COLD_SPOT/CELLAR", player(world, userId))
        expectFalse(result.ok)
        expectEqual(result.reason, InteractionCore.Reasons.DISABLED, "the used source's prompt is disabled")
    end
    -- even a direct call to the handler (the prompt being stale) is a duplicate for the core
    expectFalse(world.handlers[idOf(world, "COLD_SPOT/CELLAR")](player(world, 2)))
    expectEqual(runtime:getRevision(), revision)
    expectEqual(runtime:getProgress().corroborationRatio, progress.corroborationRatio)
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "OBSERVED", "one distinct source never confirms two-source evidence")
    expectEqual(#world.sent, sent, "no snapshot for duplicates")
end)

test("a duplicate that reaches the handler is rejected by EvidenceCore and publishes nothing", function()
    local world, runtime = started()
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    local sent = #world.sent
    local revision = runtime:getRevision()
    local handler = world.handlers[idOf(world, "COLD_SPOT/CELLAR")]
    expectFalse(handler(player(world, 2)))
    expectFalse(handler(player(world, 1)))
    expectEqual(runtime:getRevision(), revision)
    expectEqual(#world.sent, sent)
end)

test("rapid repeated requests are throttled by the real rate limiter and never mutate state twice", function()
    local world, runtime = started()
    local limit = InteractionConfig.Values.rateLimit
    -- hammering ONE prompt: the first activation is applied, every later attempt meets a disabled prompt
    local accepted = 0
    for _ = 1, limit.capacity + 3 do
        if world.interact("MOVED_OBJECT/NURSERY", player(world, 1)).ok then
            accepted = accepted + 1
        end
    end
    expectEqual(accepted, 1)
    expectEqual(runtime:getRevision(), 2, "observe and confirm, once")
    expectEqual(runtime:getEvidenceState("MOVED_OBJECT"), "CONFIRMED")
end)

test("a flood across different prompts runs out of rate-limit tokens and the excess changes nothing", function()
    local world, runtime = started()
    local limit = InteractionConfig.Values.rateLimit
    local keys = { "COLD_SPOT/CELLAR", "COLD_SPOT/ATTIC", "STATIC_INTERFERENCE/RADIO_ROOM", "STATIC_INTERFERENCE/BOILER", "VOICE_ECHO/STAIRS", "VOICE_ECHO/CORRIDOR", "VOICE_ECHO/CHAPEL" }
    local limited = 0
    local applied = 0
    for index, key in ipairs(keys) do
        local result = world.interact(key, player(world, 1))
        if result.ok then
            applied = applied + 1
        elseif result.reason == InteractionCore.Reasons.RATE_LIMITED then
            limited = limited + 1
        end
        if index <= limit.capacity then
            expectOk(result, key)
        end
    end
    expectEqual(applied, limit.capacity, "exactly one burst is allowed")
    expectEqual(limited, #keys - limit.capacity)
    expectEqual(runtime:getEvidenceState("VOICE_ECHO"), "OBSERVED", "only the first VOICE_ECHO source made it through")
    local revision = runtime:getRevision()
    expectEqual(runtime:getProgress().confirmed, 2)
    -- time passes: the bucket refills and the previously throttled source works
    world.advance(10)
    expectOk(world.interact("VOICE_ECHO/CORRIDOR", player(world, 1)))
    expectEqual(runtime:getRevision(), revision + 1)
    expectTrue(applied >= 1)
end)

-- player lifecycle ---------------------------------------------------------------------------------------------------------

test("a player who disconnects keeps the team's progress and stops receiving snapshots", function()
    local world, runtime = started()
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 2)))
    player(world, 2).connected = false
    local before = #world.sentTo(2)
    expectOk(world.interact("COLD_SPOT/ATTIC", player(world, 1)))
    expectEqual(#world.sentTo(2), before, "no snapshot to a disconnected player")
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "CONFIRMED", "the leaver's contribution still counts")
    expectFalse(world.handlers[idOf(world, "STATIC_INTERFERENCE/BOILER")](player(world, 2)), "the leaver cannot contribute")
    -- the player returns and pulls the current state
    player(world, 2).connected = true
    runtime:requestSnapshot(player(world, 2))
    expectEqual(snapshotEntry(lastSnapshot(world, 2), "COLD_SPOT").state, "CONFIRMED")
end)

test("a failing delivery to one player does not stop the others or the command", function()
    local world, runtime = started()
    world.failSendFor[2] = true
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    expectEqual(#world.sentTo(1), 2)
    expectEqual(#world.sentTo(2), 1, "only the initial snapshot")
    expectEqual(#world.sentTo(3), 2)
    expectEqual(runtime:getRevision(), 1)
    expectTrue(#world.logs >= 1)
end)

test("a prompt update that fails is retried and healed by the next applied activation", function()
    local world, runtime = started()
    world.failSetEnabled[idOf(world, "COLD_SPOT/ATTIC")] = 1
    expectOk(world.interact("COLD_SPOT/ATTIC", player(world, 1)))
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "CONFIRMED")
    for id, anchor in pairs(world.idToAnchor) do
        if string.find(anchor.name, "COLD_SPOT", 1, true) ~= nil then
            expectFalse(world.enabled[id], anchor.name .. " must end disabled")
        end
    end
end)

-- mission lifecycle ---------------------------------------------------------------------------------------------------------

test("stop unregisters every prompt, kills stale handlers and is idempotent", function()
    local world, runtime = started()
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    local handler = world.handlers[idOf(world, "COLD_SPOT/CELLAR")]
    runtime:stop()
    expectFalse(runtime:isRunning())
    expectEqual(#world.unregistered, 8)
    expectEqual(next(world.handlers), nil)
    expectEqual(world.interactionCore:count(), 0, "the interaction layer holds no registration")
    expectFalse(handler(player(world, 1)))
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), nil)
    expectEqual(runtime:getRevision(), nil)
    runtime:stop()
    expectEqual(#world.unregistered, 8)
end)

test("a new mission starts clean: no inherited evidence, state, revision or registrations, and old handlers stay dead", function()
    local world, runtime = started()
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    expectOk(world.interact("MOVED_OBJECT/NURSERY", player(world, 1)))
    local oldHandler = world.handlers[idOf(world, "COLD_SPOT/CELLAR")]
    runtime:stop()

    -- the second mission, new candidates (the map is rebuilt), new session
    world.candidates = sourceCandidates()
    world.lifecycleActive = true
    runtime:start(SESSION)
    expectTrue(runtime:isRunning())
    expectEqual(runtime:getEvidenceState("COLD_SPOT"), "UNKNOWN")
    expectEqual(runtime:getEvidenceState("MOVED_OBJECT"), "UNKNOWN")
    expectEqual(runtime:getRevision(), 0)
    expectEqual(runtime:getProgress().unknown, 4)
    expectEqual(world.interactionCore:count(), 8, "exactly one registration per source: no duplicates, no leftovers")
    expectEqual(#lastSnapshot(world, 1).evidence, 0)
    expectEqual(lastSnapshot(world, 1).revision, 0)
    expectFalse(oldHandler(player(world, 1)), "a handler from the first mission cannot touch the second")
    expectEqual(runtime:getRevision(), 0)
    expectOk(world.interact("COLD_SPOT/CELLAR", player(world, 1)))
    expectEqual(runtime:getRevision(), 1)
end)

test("repeated start and stop cycles never accumulate registrations", function()
    local world, runtime = started()
    for _ = 1, 4 do
        runtime:stop()
        world.candidates = sourceCandidates()
        runtime:start(SESSION)
        expectEqual(world.interactionCore:count(), 8)
    end
    runtime:stop()
    expectEqual(world.interactionCore:count(), 0)
end)

test("a failed start leaves no registrations and no running state", function()
    local invalid = { version = 1, evidence = {} }
    local world = newWorld({ content = invalid })
    local runtime: any = EvidenceRuntime.new(world.deps)
    expectFalse(pcall(function()
        runtime:start(SESSION)
    end))
    expectEqual(world.interactionCore:count(), 0)
    expectFalse(runtime:isRunning())
    runtime:stop()
end)

-- generated specs ------------------------------------------------------------------------------------------------------------

test("generated specs and prompt options are valid and unique for every source index", function()
    local seen: { [string]: boolean } = {}
    for position = 1, 40 do
        local spec = EvidenceRuntime.buildSpec(EvidenceConfig.Values, position)
        local ok, detail = InteractionCore.validateSpec(spec)
        expectTrue(ok, tostring(detail))
        expectEqual(seen[spec.id], nil)
        seen[spec.id] = true
        expectEqual(spec.enabled, false)
        expectTrue(#spec.id <= InteractionCore.Limits.MaxIdLength)
    end
end)
