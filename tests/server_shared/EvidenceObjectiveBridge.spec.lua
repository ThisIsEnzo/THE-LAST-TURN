--!strict
local Harness = require("../Harness")
local Bridge = require("../../src/server_shared/Evidence/EvidenceObjectiveBridge")
local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local CONTENT = { version = 1, mappings = {
    { evidenceId = "COLD_SPOT", objectiveId = "DOCUMENT_COLD_SPOT", sourceToken = "cold_spot_secret" },
    { evidenceId = "VOICE_ECHO", objectiveId = "DOCUMENT_VOICE", sourceToken = "voice_secret" },
} }

local function makeBridge()
    local listeners, completions, logs = {}, {}, {}
    local function subscribe(callback)
        table.insert(listeners, callback)
        local active = true
        return function()
            if not active then return end
            active = false
            for i, current in ipairs(listeners) do
                if current == callback then table.remove(listeners, i); break end
            end
        end
    end
    local mapping = Bridge.compileMapping(CONTENT)
    local instance = Bridge.new({
        subscribe = subscribe,
        completeBySignal = function(id, token)
            table.insert(completions, { id = id, token = token })
            return { ok = true, changed = true }
        end,
        mapping = mapping,
        log = function(message) table.insert(logs, message) end,
    })
    local function emit(id)
        local copy = table.clone(listeners)
        for _, callback in ipairs(copy) do callback(id, {}) end
    end
    return instance, emit, listeners, completions, logs
end

test("mapping validation rejects invalid and duplicate mappings", function()
    expectTrue(Bridge.validateMapping(CONTENT))
    local ok, code = Bridge.validateMapping({ version = 1, mappings = { { evidenceId = "cold", objectiveId = "DOC", sourceToken = "x" } } })
    expectFalse(ok)
    expectEqual(code, "invalid_evidence_id")
    ok, code = Bridge.validateMapping({ version = 1, mappings = {
        { evidenceId = "COLD_SPOT", objectiveId = "DOC_A", sourceToken = "a" },
        { evidenceId = "COLD_SPOT", objectiveId = "DOC_B", sourceToken = "b" },
    } })
    expectFalse(ok)
    expectEqual(code, "duplicate_evidence_mapping")
end)

test("only mapped confirmations are forwarded and each mapping is idempotent", function()
    local bridge, emit, _, completions = makeBridge()
    bridge:start({})
    emit("UNKNOWN")
    emit("COLD_SPOT")
    emit("COLD_SPOT")
    emit("VOICE_ECHO")
    expectEqual(#completions, 2)
    expectEqual(completions[1].id, "DOCUMENT_COLD_SPOT")
    expectEqual(completions[1].token, "cold_spot_secret")
    expectEqual(completions[2].id, "DOCUMENT_VOICE")
    bridge:stop()
end)

test("rejected signal is retried instead of being permanently deduplicated", function()
    local callbacks, attempts = {}, 0
    local bridge = Bridge.new({
        subscribe = function(callback) table.insert(callbacks, callback); return function() end end,
        completeBySignal = function()
            attempts += 1
            return { ok = attempts > 1, reason = "not_available" }
        end,
        mapping = Bridge.compileMapping({ version = 1, mappings = { CONTENT.mappings[1] } }),
        log = function() end,
    })
    bridge:start({})
    callbacks[1]("COLD_SPOT", {})
    callbacks[1]("COLD_SPOT", {})
    expectEqual(attempts, 2)
    bridge:stop()
end)

test("stop unsubscribes and stale callbacks cannot affect a restarted generation", function()
    local bridge, emit, listeners, completions = makeBridge()
    bridge:start({})
    local stale = listeners[1]
    bridge:stop()
    stale("COLD_SPOT", {})
    expectEqual(#completions, 0)
    bridge:start({})
    stale("COLD_SPOT", {})
    emit("COLD_SPOT")
    expectEqual(#completions, 1)
    expectTrue(bridge:isRunning())
    bridge:stop()
    expectFalse(bridge:isRunning())
    expectEqual(#listeners, 0)
end)
