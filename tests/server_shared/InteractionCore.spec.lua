--!strict
local Harness = require("../Harness")
local InteractionCore = require("../../src/server_shared/Interaction/InteractionCore")

local test, expectTrue, expectFalse, expectEqual, expectError = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual, Harness.expectError

local Reasons = InteractionCore.Reasons

-- Helpers ---------------------------------------------------------------------------------------------------------

local function newStore(): any
    return InteractionCore.new()
end

local function makeSpec(overrides: { [string]: any }?): any
    local spec: { [string]: any } = { id = "GeneratorFuseSlot", maxDistance = 10, holdDuration = 0, cooldown = 1, enabled = true }
    for key, value in pairs(overrides or {}) do
        if value == "__nil__" then
            spec[key] = nil -- "__nil__" removes the field
        else
            spec[key] = value
        end
    end
    return spec
end

local function makeTarget(): any
    return {} -- a distinct table is a distinct target
end

local function makeContext(overrides: { [string]: any }?): any
    local context: { [string]: any } = {
        missionActive = true,
        isParticipant = true,
        playerEligible = true,
        characterAvailable = true,
        targetAvailable = true,
        distance = 5,
        now = 100,
    }
    for key, value in pairs(overrides or {}) do
        if value == "__nil__" then
            context[key] = nil
        else
            context[key] = value
        end
    end
    return context
end

local function register(store: any, overrides: { [string]: any }?, target: any?): any
    local handle, reason = store:register(makeSpec(overrides), target or makeTarget())
    if handle == nil then
        error("register failed: " .. tostring(reason))
    end
    return handle
end

local function okHooks(): any
    return {
        consumeToken = function()
            return true
        end,
        handler = function()
            return true
        end,
    }
end

local function expectRejected(result: any, reason: string, label: string?)
    expectFalse(result.ok, (label or "result") .. " ok")
    expectEqual(result.reason, reason, label)
end

-- A. Registration and validation -------------------------------------------------------------------------------------

test("register accepts a valid registration and returns a frozen handle", function()
    local store = newStore()
    local handle, reason, detail = store:register(makeSpec(), makeTarget())
    expectTrue(handle ~= nil)
    expectEqual(reason, nil)
    expectEqual(detail, nil)
    expectEqual(handle.id, "GeneratorFuseSlot")
    expectEqual(handle.serial, 1)
    expectTrue(table.isfrozen(handle))
    expectEqual(store:count(), 1)
    expectTrue(store:isRegistered(handle))
end)

test("register applies documented defaults for optional fields only", function()
    local store = newStore()
    local handle = store:register({ id = "A", maxDistance = 6 }, makeTarget())
    local state = store:getState(handle)
    expectEqual(state.holdDuration, 0)
    expectEqual(state.cooldown, 0)
    expectEqual(state.enabled, true)
    expectEqual(state.maxDistance, 6)
end)

test("register rejects missing required fields", function()
    local store = newStore()
    for _, field in ipairs({ "id", "maxDistance" }) do
        local handle, reason = store:register(makeSpec({ [field] = "__nil__" }), makeTarget())
        expectEqual(handle, nil, field)
        expectEqual(reason, Reasons.INVALID_SPEC, field)
    end
    expectEqual(store:count(), 0)
end)

test("register rejects invalid identifiers", function()
    local store = newStore()
    local bad: { any } = { "", string.rep("a", 65), "has space", "slash/id", "dot.id", "ünï", 5, true, {} }
    for _, id in ipairs(bad) do
        local handle, reason = store:register(makeSpec({ id = id }), makeTarget())
        expectEqual(handle, nil, "id " .. tostring(id))
        expectEqual(reason, Reasons.INVALID_SPEC, "id " .. tostring(id))
    end
    expectTrue((store:register(makeSpec({ id = string.rep("a", 64) }), makeTarget())) ~= nil, "64 characters is allowed")
    expectTrue((store:register(makeSpec({ id = "A_b-9" }), makeTarget())) ~= nil, "token characters are allowed")
end)

test("register enforces the approved numeric limits inclusively", function()
    local store = newStore()
    local function accepts(field: string, value: number): boolean
        local overrides: { [string]: any } = { id = "X" .. tostring(math.random(1, 1000000000)) }
        overrides[field] = value
        local handle = store:register(makeSpec(overrides), makeTarget())
        return handle ~= nil
    end
    local function rejects(field: string, value: any)
        local overrides: { [string]: any } = {}
        overrides[field] = value
        local handle, reason = store:register(makeSpec(overrides), makeTarget())
        expectEqual(handle, nil, field .. "=" .. tostring(value))
        expectEqual(reason, Reasons.INVALID_SPEC, field .. "=" .. tostring(value))
    end
    expectTrue(accepts("maxDistance", 2))
    expectTrue(accepts("maxDistance", 15))
    expectTrue(accepts("holdDuration", 0))
    expectTrue(accepts("holdDuration", 3))
    expectTrue(accepts("cooldown", 0))
    expectTrue(accepts("cooldown", 60))
    for _, value in ipairs({ 1.999, 15.001, -1, 0, 100 }) do
        rejects("maxDistance", value)
    end
    for _, value in ipairs({ -0.001, 3.001, 10 }) do
        rejects("holdDuration", value)
    end
    for _, value in ipairs({ -0.001, 60.001, 1000 }) do
        rejects("cooldown", value)
    end
end)

test("register rejects NaN, infinities and non-numbers without coercion", function()
    local store = newStore()
    for _, field in ipairs({ "maxDistance", "holdDuration", "cooldown" }) do
        local bad: { any } = { 0 / 0, math.huge, -math.huge, "5", true, {} }
        for _, value in ipairs(bad) do
            local overrides: { [string]: any } = {}
            overrides[field] = value
            local handle, reason = store:register(makeSpec(overrides), makeTarget())
            expectEqual(handle, nil, field .. "=" .. tostring(value))
            expectEqual(reason, Reasons.INVALID_SPEC, field .. "=" .. tostring(value))
        end
    end
    expectEqual(store:count(), 0)
end)

test("register rejects an invalid enabled value", function()
    local store = newStore()
    for _, value in ipairs({ "true", 1, 0 }) do
        local handle, reason = store:register(makeSpec({ enabled = value }), makeTarget())
        expectEqual(handle, nil)
        expectEqual(reason, Reasons.INVALID_SPEC)
    end
    local handle = store:register(makeSpec({ enabled = false }), makeTarget())
    expectEqual(store:getState(handle).enabled, false)
end)

test("register rejects non-plain specs and unknown fields (strict schema)", function()
    local store = newStore()
    local cases: { any } = { "spec", 5, true, setmetatable(makeSpec(), {}) }
    for _, value in ipairs(cases) do
        local handle, reason = store:register(value, makeTarget())
        expectEqual(handle, nil)
        expectEqual(reason, Reasons.INVALID_SPEC)
    end
    local handle, reason = store:register(nil, makeTarget())
    expectEqual(handle, nil)
    expectEqual(reason, Reasons.INVALID_SPEC)
    handle, reason = store:register(makeSpec({ extra = 1 }), makeTarget())
    expectEqual(reason, Reasons.INVALID_SPEC, "unknown field")
    handle, reason = store:register(makeSpec({ targetKey = makeTarget() }), makeTarget())
    expectEqual(reason, Reasons.INVALID_SPEC, "targetKey belongs to the second argument, not the spec")
    local numeric = makeSpec()
    numeric[1] = "x"
    handle, reason = store:register(numeric, makeTarget())
    expectEqual(reason, Reasons.INVALID_SPEC, "numeric key")
end)

test("validateSpec reports the offending field and does not modify the spec", function()
    local spec = makeSpec({ cooldown = 61 })
    local ok, detail = InteractionCore.validateSpec(spec)
    expectFalse(ok)
    expectEqual(detail, "invalid cooldown")
    expectEqual(spec.cooldown, 61)
    expectTrue((InteractionCore.validateSpec(makeSpec())))
end)

test("register rejects invalid target keys", function()
    local store = newStore()
    local bad: { any } = { "part", 5, true, 0 / 0 }
    for _, key in ipairs(bad) do
        local handle, reason = store:register(makeSpec(), key)
        expectEqual(handle, nil, tostring(key))
        expectEqual(reason, Reasons.INVALID_TARGET_KEY, tostring(key))
    end
    local handle, reason = store:register(makeSpec(), nil)
    expectEqual(handle, nil)
    expectEqual(reason, Reasons.INVALID_TARGET_KEY)
    expectEqual(store:count(), 0)
end)

test("register rejects a duplicate id and reports it before a target conflict", function()
    local store = newStore()
    local target = makeTarget()
    register(store, { id = "One" }, target)
    local handle, reason = store:register(makeSpec({ id = "One" }), makeTarget())
    expectEqual(handle, nil)
    expectEqual(reason, Reasons.DUPLICATE_ID)
    handle, reason = store:register(makeSpec({ id = "One" }), target)
    expectEqual(reason, Reasons.DUPLICATE_ID, "both duplicate: the id is reported first")
    expectEqual(store:count(), 1)
end)

test("register rejects a target already used by another interaction (identity, not name)", function()
    local store = newStore()
    local target = makeTarget()
    register(store, { id = "One" }, target)
    local handle, reason = store:register(makeSpec({ id = "Two" }), target)
    expectEqual(handle, nil)
    expectEqual(reason, Reasons.TARGET_IN_USE)
    -- A different table that merely looks the same is a different target.
    local lookalike = makeTarget()
    expectTrue((store:register(makeSpec({ id = "Three" }), lookalike)) ~= nil)
    expectEqual(store:count(), 2)
end)

test("a failed registration leaves no partial state and consumes no serial", function()
    local store = newStore()
    local first = register(store, { id = "One" })
    local reservedTarget = makeTarget()
    -- Fails on the duplicate id; the target must NOT stay reserved.
    local failed, reason = store:register(makeSpec({ id = "One" }), reservedTarget)
    expectEqual(failed, nil)
    expectEqual(reason, Reasons.DUPLICATE_ID)
    -- Fails on the spec; nothing is created.
    store:register(makeSpec({ id = "Bad", maxDistance = 99 }), reservedTarget)
    expectEqual(store:count(), 1)
    local second = store:register(makeSpec({ id = "Two" }), reservedTarget)
    expectTrue(second ~= nil, "the target is free after failed registrations")
    expectEqual(second.serial, first.serial + 1, "failed registrations consumed no serial")
end)

-- B. Handles -----------------------------------------------------------------------------------------------------------

test("a valid handle is accepted everywhere", function()
    local store = newStore()
    local handle = register(store)
    expectTrue(store:isRegistered(handle))
    expectTrue(store:getState(handle) ~= nil)
    expectTrue(store:evaluate(handle, makeContext()).ok)
    expectTrue((store:setEnabled(handle, true)))
end)

test("a forged handle with identical visible fields is rejected", function()
    local store = newStore()
    local handle = register(store)
    local forgedFrozen = table.freeze({ id = handle.id, serial = handle.serial })
    local forgedPlain = { id = handle.id, serial = handle.serial }
    for _, forged in ipairs({ forgedFrozen, forgedPlain }) do
        expectFalse(store:isRegistered(forged))
        expectEqual(store:getState(forged), nil)
        expectRejected(store:evaluate(forged, makeContext()), Reasons.INVALID_HANDLE)
        expectRejected(store:activate(forged, makeContext(), okHooks()), Reasons.INVALID_HANDLE)
        local ok, reason = store:setEnabled(forged, false)
        expectFalse(ok)
        expectEqual(reason, Reasons.INVALID_HANDLE)
        ok, reason = store:unregister(forged)
        expectFalse(ok)
        expectEqual(reason, Reasons.INVALID_HANDLE)
    end
    expectTrue(store:isRegistered(handle), "the real registration is untouched")
    expectEqual(store:getState(handle).enabled, true)
end)

test("a copied handle is rejected", function()
    local store = newStore()
    local handle = register(store)
    local copy = table.clone(handle)
    expectFalse(store:isRegistered(copy))
    local ok, reason = store:unregister(copy)
    expectFalse(ok)
    expectEqual(reason, Reasons.INVALID_HANDLE)
    expectTrue(store:isRegistered(handle))
end)

test("a handle from another Store is rejected", function()
    local storeA = newStore()
    local storeB = newStore()
    local handleA = register(storeA)
    local handleB = register(storeB)
    expectEqual(handleA.serial, handleB.serial, "both Stores start at serial 1, so only identity can tell them apart")
    expectFalse(storeB:isRegistered(handleA))
    expectRejected(storeB:evaluate(handleA, makeContext()), Reasons.INVALID_HANDLE)
    local ok, reason = storeB:unregister(handleA)
    expectFalse(ok)
    expectEqual(reason, Reasons.INVALID_HANDLE)
    expectTrue(storeA:isRegistered(handleA))
    expectTrue(storeB:isRegistered(handleB))
end)

test("non-table handles are rejected", function()
    local store = newStore()
    register(store)
    for _, bad in ipairs({ "GeneratorFuseSlot", 1, true }) do
        expectFalse(store:isRegistered(bad))
        expectRejected(store:evaluate(bad, makeContext()), Reasons.INVALID_HANDLE)
    end
    expectFalse(store:isRegistered(nil))
    expectRejected(store:evaluate(nil, makeContext()), Reasons.INVALID_HANDLE)
    expectRejected(store:evaluate(0 / 0, makeContext()), Reasons.INVALID_HANDLE)
    local ok, reason = store:unregister(nil)
    expectFalse(ok)
    expectEqual(reason, Reasons.INVALID_HANDLE)
end)

test("a handle is stale after unregister, and unregister is not idempotent", function()
    local store = newStore()
    local handle = register(store)
    local ok, reason = store:unregister(handle)
    expectTrue(ok)
    expectEqual(reason, nil)
    expectFalse(store:isRegistered(handle))
    expectEqual(store:getState(handle), nil)
    expectRejected(store:evaluate(handle, makeContext()), Reasons.NOT_REGISTERED)
    expectRejected(store:activate(handle, makeContext(), okHooks()), Reasons.NOT_REGISTERED)
    ok, reason = store:unregister(handle)
    expectFalse(ok)
    expectEqual(reason, Reasons.NOT_REGISTERED)
    ok, reason = store:setEnabled(handle, false)
    expectFalse(ok)
    expectEqual(reason, Reasons.NOT_REGISTERED)
    expectEqual(store:count(), 0)
end)

test("a handle is stale after clear", function()
    local store = newStore()
    local handle = register(store)
    store:clear()
    expectFalse(store:isRegistered(handle))
    expectRejected(store:evaluate(handle, makeContext()), Reasons.NOT_REGISTERED)
end)

test("handles are immutable", function()
    local store = newStore()
    local handle = register(store)
    expectTrue(table.isfrozen(handle))
    expectError(function()
        (handle :: any).extra = 1
    end, "new field")
    expectError(function()
        (handle :: any).serial = 99
    end, "existing field")
    expectError(function()
        (handle :: any).id = "Other"
    end, "existing field id")
    expectEqual(handle.serial, 1)
    expectEqual(handle.id, "GeneratorFuseSlot")
end)

test("serials are unique and never reused after unregister or clear", function()
    local store = newStore()
    local seen: { [number]: boolean } = {}
    local last = 0
    local function take(id: string)
        local handle = register(store, { id = id })
        expectFalse(seen[handle.serial] == true, "serial reused")
        seen[handle.serial] = true
        expectTrue(handle.serial > last, "serials strictly increase")
        last = handle.serial
        return handle
    end
    local a = take("A")
    local b = take("B")
    store:unregister(a)
    take("A") -- the same id gets a NEW serial
    store:clear()
    take("A")
    take("C")
    expectEqual(last, 5)
    store:unregister(b) -- stale after clear: harmless
    expectEqual(store:count(), 2)
end)

test("getState returns a copy, never the internal record", function()
    local store = newStore()
    local handle = register(store)
    local state = store:getState(handle)
    state.busy = true
    state.enabled = false
    state.cooldownEndsAt = 999
    local fresh = store:getState(handle)
    expectEqual(fresh.busy, false)
    expectEqual(fresh.enabled, true)
    expectEqual(fresh.cooldownEndsAt, nil)
end)

test("a registration does not retain or alias the caller's spec", function()
    local store = newStore()
    local spec = makeSpec()
    local handle = store:register(spec, makeTarget())
    spec.maxDistance = 3
    spec.cooldown = 50
    spec.enabled = false
    local state = store:getState(handle)
    expectEqual(state.maxDistance, 10)
    expectEqual(state.cooldown, 1)
    expectEqual(state.enabled, true)
end)

test("setEnabled toggles the registration and validates its argument", function()
    local store = newStore()
    local handle = register(store)
    expectTrue((store:setEnabled(handle, false)))
    expectRejected(store:evaluate(handle, makeContext()), Reasons.DISABLED)
    expectTrue((store:setEnabled(handle, true)))
    expectTrue(store:evaluate(handle, makeContext()).ok)
    local ok, reason = store:setEnabled(handle, "yes")
    expectFalse(ok)
    expectEqual(reason, Reasons.INVALID_ENABLED)
    expectEqual(store:getState(handle).enabled, true, "an invalid value changes nothing")
end)

-- C. Eligibility ---------------------------------------------------------------------------------------------------------

test("evaluate accepts a fully eligible request", function()
    local store = newStore()
    local result = store:evaluate(register(store), makeContext())
    expectTrue(result.ok)
    expectEqual(result.reason, nil)
end)

test("evaluate reports every rejection reason", function()
    local store = newStore()
    local handle = register(store)
    expectRejected(store:evaluate(handle, makeContext({ targetAvailable = false })), Reasons.TARGET_UNAVAILABLE)
    expectRejected(store:evaluate(handle, makeContext({ missionActive = false })), Reasons.MISSION_INACTIVE)
    expectRejected(store:evaluate(handle, makeContext({ isParticipant = false })), Reasons.NOT_PARTICIPANT)
    expectRejected(store:evaluate(handle, makeContext({ playerEligible = false })), Reasons.PLAYER_NOT_ELIGIBLE)
    expectRejected(store:evaluate(handle, makeContext({ characterAvailable = false })), Reasons.CHARACTER_UNAVAILABLE)
    store:setEnabled(handle, false)
    expectRejected(store:evaluate(handle, makeContext()), Reasons.DISABLED)
    store:setEnabled(handle, true)
    expectRejected(store:evaluate(handle, makeContext({ distance = 10.001 })), Reasons.OUT_OF_RANGE)
    -- busy and cooldown are covered by the activation tests below
end)

test("evaluate applies the approved rejection precedence", function()
    local store = newStore()
    local handle = register(store, { cooldown = 5 })
    -- Make busy and cooldown reachable.
    store:activate(handle, makeContext({ now = 100 }), okHooks()) -- success: cooldown until 105
    store:setEnabled(handle, false)
    local order = {
        { "targetAvailable", false, Reasons.TARGET_UNAVAILABLE },
        { "missionActive", false, Reasons.MISSION_INACTIVE },
        { "isParticipant", false, Reasons.NOT_PARTICIPANT },
        { "playerEligible", false, Reasons.PLAYER_NOT_ELIGIBLE },
        { "characterAvailable", false, Reasons.CHARACTER_UNAVAILABLE },
    }
    -- Everything wrong at once: the first reason in the order wins; fixing it reveals the next one.
    local overrides: { [string]: any } = { distance = 99, now = 101 }
    for _, field in ipairs(order) do
        overrides[field[1] :: string] = false
    end
    for _, step in ipairs(order) do
        expectRejected(store:evaluate(handle, makeContext(overrides)), step[3] :: string, "precedence at " .. (step[1] :: string))
        overrides[step[1] :: string] = true
    end
    expectRejected(store:evaluate(handle, makeContext(overrides)), Reasons.DISABLED)
    store:setEnabled(handle, true)
    expectRejected(store:evaluate(handle, makeContext(overrides)), Reasons.COOLDOWN, "cooldown before range")
    overrides.now = 105
    expectRejected(store:evaluate(handle, makeContext(overrides)), Reasons.OUT_OF_RANGE)
    -- busy outranks cooldown and range
    local busyStore = newStore()
    local busyHandle = register(busyStore, { cooldown = 5 })
    local seen: any = nil
    busyStore:activate(busyHandle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function()
            seen = busyStore:evaluate(busyHandle, makeContext({ distance = 99 }))
            return true
        end,
    })
    expectRejected(seen, Reasons.BUSY, "busy outranks out_of_range")
    -- disabled outranks busy (a handler can disable its own registration while it is reserved)
    local both = newStore()
    local bothHandle = register(both)
    local bothSeen: any = nil
    both:activate(bothHandle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function()
            both:setEnabled(bothHandle, false)
            bothSeen = both:evaluate(bothHandle, makeContext())
            return true
        end,
    })
    expectRejected(bothSeen, Reasons.DISABLED, "disabled outranks busy")
    expectEqual(#InteractionCore.EvaluationOrder, 9)
    expectEqual(InteractionCore.EvaluationOrder[7], "busy")
end)

test("evaluate treats the exact distance boundary as in range", function()
    local store = newStore()
    local handle = register(store, { maxDistance = 10 })
    expectTrue(store:evaluate(handle, makeContext({ distance = 10 })).ok)
    expectTrue(store:evaluate(handle, makeContext({ distance = 0 })).ok)
    expectRejected(store:evaluate(handle, makeContext({ distance = 10.0001 })), Reasons.OUT_OF_RANGE)
end)

test("an invalid distance is never in range", function()
    local store = newStore()
    local handle = register(store)
    local bad: { any } = { -1, -0.001, 0 / 0, math.huge, -math.huge, "5", true, {} }
    for _, distance in ipairs(bad) do
        expectRejected(store:evaluate(handle, makeContext({ distance = distance })), Reasons.OUT_OF_RANGE, "distance " .. tostring(distance))
    end
    expectRejected(store:evaluate(handle, makeContext({ distance = "__nil__" })), Reasons.OUT_OF_RANGE, "missing distance")
end)

test("a malformed context fails closed", function()
    local store = newStore()
    local handle = register(store)
    expectRejected(store:evaluate(handle, nil), Reasons.INVALID_CONTEXT)
    expectRejected(store:evaluate(handle, "context"), Reasons.INVALID_CONTEXT)
    for _, field in ipairs({ "missionActive", "isParticipant", "playerEligible", "characterAvailable", "targetAvailable" }) do
        expectRejected(store:evaluate(handle, makeContext({ [field] = "__nil__" })), Reasons.INVALID_CONTEXT, field .. " missing")
        expectRejected(store:evaluate(handle, makeContext({ [field] = 1 })), Reasons.INVALID_CONTEXT, field .. " truthy non-boolean")
        expectRejected(store:evaluate(handle, makeContext({ [field] = "true" })), Reasons.INVALID_CONTEXT, field .. " string")
    end
end)

test("evaluate does not mutate any state", function()
    local store = newStore()
    local target = makeTarget()
    local handle = register(store, { cooldown = 5 }, target)
    store:activate(handle, makeContext({ now = 100 }), okHooks()) -- cooldown until 105
    local before = store:getState(handle)
    local countBefore = store:count()
    for _, overrides in ipairs({ {}, { distance = 99 }, { now = 200 }, { missionActive = false }, { now = 0 / 0 } }) do
        store:evaluate(handle, makeContext(overrides))
    end
    local after = store:getState(handle)
    expectEqual(after.busy, before.busy)
    expectEqual(after.cooldownEndsAt, before.cooldownEndsAt)
    expectEqual(after.enabled, before.enabled)
    expectEqual(after.serial, before.serial)
    expectEqual(store:count(), countBefore)
    local again, reason = store:register(makeSpec({ id = "Other" }), target)
    expectEqual(again, nil)
    expectEqual(reason, Reasons.TARGET_IN_USE, "target ownership untouched by evaluate")
end)

-- D. Activation pipeline -------------------------------------------------------------------------------------------------

test("activate runs the full pipeline for an eligible request", function()
    local store = newStore()
    local handle = register(store, { cooldown = 2 })
    local result = store:activate(handle, makeContext({ now = 100 }), okHooks())
    expectTrue(result.ok)
    expectEqual(result.reason, nil)
    expectTrue(result.executed)
    expectFalse(result.stale)
    expectEqual(result.cooldownEndsAt, 102)
    local state = store:getState(handle)
    expectFalse(state.busy)
    expectEqual(state.cooldownEndsAt, 102)
end)

test("an initial eligibility failure consumes no token and runs no handler", function()
    local store = newStore()
    local handle = register(store)
    local tokens, handlers = 0, 0
    local result = store:activate(handle, makeContext({ playerEligible = false }), {
        consumeToken = function()
            tokens = tokens + 1
            return true
        end,
        handler = function()
            handlers = handlers + 1
            return true
        end,
    })
    expectRejected(result, Reasons.PLAYER_NOT_ELIGIBLE)
    expectFalse(result.executed)
    expectEqual(tokens, 0)
    expectEqual(handlers, 0)
end)

test("a token rejection never leaves the registration busy and never runs the handler", function()
    local store = newStore()
    local handle = register(store)
    local handlers = 0
    local busyDuringToken: any = nil
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            busyDuringToken = store:getState(handle).busy
            return false
        end,
        handler = function()
            handlers = handlers + 1
            return true
        end,
    })
    expectRejected(result, Reasons.RATE_LIMITED)
    expectFalse(result.executed)
    expectEqual(busyDuringToken, false, "nothing is reserved while the token is consumed")
    expectEqual(handlers, 0)
    expectFalse(store:getState(handle).busy, "not busy after the rejection")
    expectEqual(store:getState(handle).cooldownEndsAt, nil)
    -- The registration is immediately usable again.
    expectTrue(store:activate(handle, makeContext(), okHooks()).ok)
end)

test("only a literal true from consumeToken allows the activation", function()
    local store = newStore()
    local handle = register(store, { cooldown = 0 })
    for _, value in ipairs({ false, 1, "yes" }) do
        local result = store:activate(handle, makeContext(), {
            consumeToken = function()
                return value
            end,
            handler = function()
                return true
            end,
        })
        expectRejected(result, Reasons.RATE_LIMITED, tostring(value))
        expectFalse(store:getState(handle).busy)
    end
    local nilResult = store:activate(handle, makeContext(), {
        consumeToken = function() end,
        handler = function()
            return true
        end,
    })
    expectRejected(nilResult, Reasons.RATE_LIMITED, "nil")
end)

test("a throwing consumeToken hook fails closed without reserving", function()
    local store = newStore()
    local handle = register(store)
    local handlers = 0
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            error("limiter exploded")
        end,
        handler = function()
            handlers = handlers + 1
            return true
        end,
    })
    expectRejected(result, Reasons.HOOK_ERROR)
    expectEqual(handlers, 0)
    expectFalse(store:getState(handle).busy)
end)

test("the second evaluation can reject and then the handler never runs (token is not refunded)", function()
    local store = newStore()
    local handle = register(store)
    local tokens, handlers = 0, 0
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            tokens = tokens + 1
            store:setEnabled(handle, false) -- state changes while the token is being consumed
            return true
        end,
        handler = function()
            handlers = handlers + 1
            return true
        end,
    })
    expectRejected(result, Reasons.DISABLED)
    expectFalse(result.executed)
    expectEqual(tokens, 1, "the token was consumed and is not refunded")
    expectEqual(handlers, 0)
    expectFalse(store:getState(handle).busy)
end)

test("the registration is reserved only after the second evaluation and before the handler", function()
    local store = newStore()
    local handle = register(store, { cooldown = 3 })
    local busyInToken: any = nil
    local busyInHandler: any = nil
    local cooldownInHandler: any = "unset"
    local reentrant: any = nil
    local result = store:activate(handle, makeContext({ now = 50 }), {
        consumeToken = function()
            busyInToken = store:getState(handle).busy
            return true
        end,
        handler = function()
            local state = store:getState(handle)
            busyInHandler = state.busy
            cooldownInHandler = state.cooldownEndsAt
            reentrant = store:activate(handle, makeContext({ now = 50 }), okHooks())
            return true
        end,
    })
    expectTrue(result.ok)
    expectEqual(busyInToken, false)
    expectEqual(busyInHandler, true)
    expectEqual(cooldownInHandler, nil, "no cooldown before the handler completed")
    expectRejected(reentrant, Reasons.BUSY, "a reentrant activation is rejected as busy")
    expectFalse(store:getState(handle).busy)
end)

test("a successful handler applies the cooldown from the injected time", function()
    local store = newStore()
    local handle = register(store, { cooldown = 4.5 })
    local result = store:activate(handle, makeContext({ now = 1000 }), okHooks())
    expectTrue(result.ok)
    expectEqual(result.cooldownEndsAt, 1004.5)
    expectRejected(store:evaluate(handle, makeContext({ now = 1004.4 })), Reasons.COOLDOWN)
    expectTrue(store:evaluate(handle, makeContext({ now = 1004.5 })).ok, "the exact end is eligible")
end)

test("a handler returning false releases busy and applies no cooldown", function()
    local store = newStore()
    local handle = register(store, { cooldown = 10 })
    local calls = 0
    local result = store:activate(handle, makeContext({ now = 100 }), {
        consumeToken = function()
            return true
        end,
        handler = function()
            calls = calls + 1
            return false
        end,
    })
    expectRejected(result, Reasons.HANDLER_FAILED)
    expectTrue(result.executed)
    expectEqual(result.cooldownEndsAt, nil)
    expectEqual(calls, 1)
    local state = store:getState(handle)
    expectFalse(state.busy)
    expectEqual(state.cooldownEndsAt, nil)
    expectTrue(store:activate(handle, makeContext({ now = 100 }), okHooks()).ok, "usable again immediately")
end)

test("a handler returning anything but true is a failure", function()
    local store = newStore()
    local handle = register(store, { cooldown = 10 })
    for _, value in ipairs({ 1, "true" }) do
        local result = store:activate(handle, makeContext(), {
            consumeToken = function()
                return true
            end,
            handler = function()
                return value
            end,
        })
        expectRejected(result, Reasons.HANDLER_FAILED, tostring(value))
        expectEqual(store:getState(handle).cooldownEndsAt, nil)
    end
    local nilResult = store:activate(handle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function() end,
    })
    expectRejected(nilResult, Reasons.HANDLER_FAILED, "nil")
    expectFalse(store:getState(handle).busy)
end)

test("a throwing handler releases busy, applies no cooldown and reports the error", function()
    local reported: { string } = {}
    local store = InteractionCore.new({
        onHandlerError = function(id: string, serial: number, message: string)
            table.insert(reported, id .. ":" .. tostring(serial) .. ":" .. message)
        end,
    })
    local handle = register(store, { cooldown = 10 })
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function()
            error("boom")
        end,
    })
    expectRejected(result, Reasons.HANDLER_FAILED)
    expectTrue(result.executed)
    expectFalse(result.stale)
    expectEqual(result.cooldownEndsAt, nil)
    expectTrue(result.handlerError ~= nil and string.find(result.handlerError, "boom", 1, true) ~= nil, "the error is preserved")
    local state = store:getState(handle)
    expectFalse(state.busy)
    expectEqual(state.cooldownEndsAt, nil)
    expectEqual(#reported, 1)
    expectTrue(string.find(reported[1], "GeneratorFuseSlot:1:", 1, true) == 1)
    expectTrue(store:activate(handle, makeContext(), okHooks()).ok, "usable again")
end)

test("a failing error sink cannot break cleanup", function()
    local store = InteractionCore.new({
        onHandlerError = function()
            error("sink exploded")
        end,
    })
    local handle = register(store)
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function()
            error("boom")
        end,
    })
    expectRejected(result, Reasons.HANDLER_FAILED)
    expectFalse(store:getState(handle).busy)
end)

test("a handler that throws a non-string error is still contained", function()
    local store = newStore()
    local handle = register(store)
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function()
            error({ code = 1 })
        end,
    })
    expectRejected(result, Reasons.HANDLER_FAILED)
    expectEqual(type(result.handlerError), "string")
    expectFalse(store:getState(handle).busy)
end)

test("the handler runs exactly once per activation", function()
    local store = newStore()
    local handle = register(store, { cooldown = 0 })
    local calls = 0
    for _ = 1, 3 do
        local result = store:activate(handle, makeContext(), {
            consumeToken = function()
                return true
            end,
            handler = function()
                calls = calls + 1
                return true
            end,
        })
        expectTrue(result.ok)
    end
    expectEqual(calls, 3)
end)

test("activate validates its hooks before doing anything", function()
    local store = newStore()
    local handle = register(store)
    local tokens = 0
    local bad: { any } = {
        "hooks",
        {},
        { consumeToken = function()
            tokens = tokens + 1
            return true
        end },
        { handler = function()
            return true
        end },
        { consumeToken = true, handler = true },
    }
    for _, hooks in ipairs(bad) do
        expectRejected(store:activate(handle, makeContext(), hooks), Reasons.INVALID_HOOKS)
    end
    expectRejected(store:activate(handle, makeContext(), nil), Reasons.INVALID_HOOKS)
    expectEqual(tokens, 0)
    expectFalse(store:getState(handle).busy)
end)

test("activate rejects a cooling-down registration without consuming a token", function()
    local store = newStore()
    local handle = register(store, { cooldown = 5 })
    expectTrue(store:activate(handle, makeContext({ now = 10 }), okHooks()).ok)
    local tokens = 0
    local hooks = {
        consumeToken = function()
            tokens = tokens + 1
            return true
        end,
        handler = function()
            return true
        end,
    }
    expectRejected(store:activate(handle, makeContext({ now = 12 }), hooks), Reasons.COOLDOWN)
    expectEqual(tokens, 0, "a cooldown rejection consumes no token")
    expectTrue(store:activate(handle, makeContext({ now = 15 }), hooks).ok)
    expectEqual(tokens, 1)
end)

test("two players activating sequentially: the second is rejected while the first is in cooldown", function()
    local store = newStore()
    local handle = register(store, { cooldown = 2 })
    local first = store:activate(handle, makeContext({ now = 100, distance = 3 }), okHooks())
    local second = store:activate(handle, makeContext({ now = 100, distance = 4 }), okHooks())
    expectTrue(first.ok)
    expectRejected(second, Reasons.COOLDOWN)
end)

-- E. Reentrancy and lifecycle safety ---------------------------------------------------------------------------------------

test("a handler that unregisters its own registration completes nothing", function()
    local store = newStore()
    local handle = register(store, { cooldown = 10 })
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function()
            store:unregister(handle)
            return true
        end,
    })
    expectTrue(result.ok, "the effect itself succeeded")
    expectTrue(result.stale)
    expectEqual(result.cooldownEndsAt, nil)
    expectFalse(store:isRegistered(handle))
    expectEqual(store:count(), 0)
end)

test("a handler that disables its own registration keeps it disabled and still completes", function()
    local store = newStore()
    local handle = register(store, { cooldown = 3 })
    local result = store:activate(handle, makeContext({ now = 20 }), {
        consumeToken = function()
            return true
        end,
        handler = function()
            store:setEnabled(handle, false)
            return true
        end,
    })
    expectTrue(result.ok)
    expectFalse(result.stale)
    local state = store:getState(handle)
    expectEqual(state.enabled, false)
    expectFalse(state.busy)
    expectEqual(state.cooldownEndsAt, 23)
end)

test("a handler that clears the Store (mission termination) completes nothing and resurrects nothing", function()
    local store = newStore()
    local handle = register(store, { cooldown = 10 })
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function()
            store:clear()
            return true
        end,
    })
    expectTrue(result.stale)
    expectEqual(result.cooldownEndsAt, nil)
    expectEqual(store:count(), 0)
    expectFalse(store:isRegistered(handle))
    local fresh = register(store) -- same id again after clear
    local state = store:getState(fresh)
    expectFalse(state.busy, "busy is not resurrected")
    expectEqual(state.cooldownEndsAt, nil)
end)

test("a handler that throws after unregistering is contained and stale", function()
    local store = newStore()
    local handle = register(store)
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function()
            store:unregister(handle)
            error("late failure")
        end,
    })
    expectRejected(result, Reasons.HANDLER_FAILED)
    expectTrue(result.stale)
    expectEqual(store:count(), 0)
end)

test("an old activation can never mutate a newer registration that reused the id and the target", function()
    local store = newStore()
    local target = makeTarget()
    local oldHandle = register(store, { cooldown = 30 }, target)
    local newHandle: any = nil
    local result = store:activate(oldHandle, makeContext({ now = 500 }), {
        consumeToken = function()
            return true
        end,
        handler = function()
            store:unregister(oldHandle)
            newHandle = register(store, { cooldown = 30 }, target) -- same id, same target
            return true
        end,
    })
    expectTrue(result.stale)
    expectEqual(result.cooldownEndsAt, nil)
    expectTrue(newHandle ~= nil)
    expectTrue(newHandle.serial > oldHandle.serial)
    local state = store:getState(newHandle)
    expectFalse(state.busy, "the new registration was not released or reserved by the old activation")
    expectEqual(state.cooldownEndsAt, nil, "no cooldown was applied to the new registration")
    expectTrue(store:activate(newHandle, makeContext({ now = 500 }), okHooks()).ok, "the new registration is fully usable")
end)

test("a stale handle cannot affect a newer registration with the same id", function()
    local store = newStore()
    local target = makeTarget()
    local oldHandle = register(store, nil, target)
    store:unregister(oldHandle)
    local newHandle = register(store, nil, target)
    local ok, reason = store:setEnabled(oldHandle, false)
    expectFalse(ok)
    expectEqual(reason, Reasons.NOT_REGISTERED)
    ok, reason = store:unregister(oldHandle)
    expectFalse(ok)
    expectEqual(reason, Reasons.NOT_REGISTERED)
    expectRejected(store:activate(oldHandle, makeContext(), okHooks()), Reasons.NOT_REGISTERED)
    expectRejected(store:evaluate(oldHandle, makeContext()), Reasons.NOT_REGISTERED)
    local state = store:getState(newHandle)
    expectEqual(state.enabled, true)
    expectTrue(store:isRegistered(newHandle))
    expectEqual(store:count(), 1)
end)

test("a token hook that unregisters the registration stops the activation before the handler", function()
    local store = newStore()
    local handle = register(store)
    local handlers = 0
    local result = store:activate(handle, makeContext(), {
        consumeToken = function()
            store:unregister(handle)
            return true
        end,
        handler = function()
            handlers = handlers + 1
            return true
        end,
    })
    expectRejected(result, Reasons.NOT_REGISTERED)
    expectEqual(handlers, 0)
end)

test("completion happens at most once per activation", function()
    local store = newStore()
    local handle = register(store, { cooldown = 3 })
    local inner: any = nil
    local outer = store:activate(handle, makeContext({ now = 10 }), {
        consumeToken = function()
            return true
        end,
        handler = function()
            inner = store:activate(handle, makeContext({ now = 10 }), okHooks())
            return true
        end,
    })
    expectRejected(inner, Reasons.BUSY)
    expectTrue(outer.ok)
    expectEqual(store:getState(handle).cooldownEndsAt, 13, "exactly one cooldown, from the outer activation")
    expectFalse(store:getState(handle).busy)
end)

-- F. Cleanup -------------------------------------------------------------------------------------------------------------------

test("unregister releases the target and the id", function()
    local store = newStore()
    local target = makeTarget()
    local handle = register(store, { id = "One" }, target)
    expectTrue((store:unregister(handle)))
    expectEqual(store:count(), 0)
    local again = store:register(makeSpec({ id = "Two" }), target)
    expectTrue(again ~= nil, "the released target can be registered again")
    local sameId = store:register(makeSpec({ id = "One" }), makeTarget())
    expectTrue(sameId ~= nil, "the released id can be registered again")
end)

test("unregistering while busy releases everything and prevents further activation", function()
    local store = newStore()
    local handle = register(store)
    local nested: any = nil
    store:activate(handle, makeContext(), {
        consumeToken = function()
            return true
        end,
        handler = function()
            store:unregister(handle)
            nested = store:activate(handle, makeContext(), okHooks())
            return true
        end,
    })
    expectRejected(nested, Reasons.NOT_REGISTERED)
end)

test("clear invalidates every handle, releases every target and drops busy/cooldown state", function()
    local store = newStore()
    local targetA, targetB = makeTarget(), makeTarget()
    local a = register(store, { id = "A", cooldown = 10 }, targetA)
    local b = register(store, { id = "B" }, targetB)
    store:activate(a, makeContext({ now = 1 }), okHooks())
    store:clear()
    expectEqual(store:count(), 0)
    expectFalse(store:isRegistered(a))
    expectFalse(store:isRegistered(b))
    expectRejected(store:evaluate(a, makeContext()), Reasons.NOT_REGISTERED)
    local a2 = store:register(makeSpec({ id = "A" }), targetA)
    local b2 = store:register(makeSpec({ id = "B" }), targetB)
    expectTrue(a2 ~= nil and b2 ~= nil, "ids and targets are free again")
    expectEqual(store:getState(a2).cooldownEndsAt, nil)
    expectFalse(store:getState(a2).busy)
    expectTrue(a2.serial > b.serial, "the serial counter was not reset")
end)

test("a cleared Store is fully reusable", function()
    local store = newStore()
    for round = 1, 3 do
        local handle = register(store, { cooldown = 1 })
        expectTrue(store:activate(handle, makeContext({ now = round * 10 }), okHooks()).ok)
        store:clear()
        expectEqual(store:count(), 0)
    end
    expectEqual(register(store).serial, 4)
end)

test("the Store keeps no player-specific state", function()
    local store = newStore()
    local handle = register(store)
    for userId = 1, 20 do
        store:activate(handle, makeContext({ now = userId * 100, distance = userId % 5 }), okHooks())
    end
    local state = store:getState(handle)
    local keys = 0
    for _ in pairs(state) do
        keys = keys + 1
    end
    expectEqual(keys, 8, "the state exposes only registration fields")
    expectEqual(store:count(), 1)
end)

-- G. Clock ---------------------------------------------------------------------------------------------------------------------------

test("cooldown progresses with the injected clock and is global per registration", function()
    local store = newStore()
    local handle = register(store, { cooldown = 10 })
    expectTrue(store:activate(handle, makeContext({ now = 0 }), okHooks()).ok)
    expectRejected(store:evaluate(handle, makeContext({ now = 0 })), Reasons.COOLDOWN, "same timestamp")
    expectRejected(store:evaluate(handle, makeContext({ now = 9.999 })), Reasons.COOLDOWN)
    expectTrue(store:evaluate(handle, makeContext({ now = 10 })).ok, "the exact boundary")
    expectTrue(store:evaluate(handle, makeContext({ now = 10.001 })).ok)
    expectTrue(store:evaluate(handle, makeContext({ now = 1e9 })).ok)
end)

test("a backward clock can only extend an active cooldown, never shorten it", function()
    local store = newStore()
    local handle = register(store, { cooldown = 10 })
    expectTrue(store:activate(handle, makeContext({ now = 100 }), okHooks()).ok) -- until 110
    expectRejected(store:evaluate(handle, makeContext({ now = 50 })), Reasons.COOLDOWN)
    expectRejected(store:evaluate(handle, makeContext({ now = -1000 })), Reasons.COOLDOWN)
    expectRejected(store:evaluate(handle, makeContext({ now = 109.9 })), Reasons.COOLDOWN)
    expectTrue(store:evaluate(handle, makeContext({ now = 110 })).ok)
end)

test("a zero cooldown never blocks, even if the clock moves backwards", function()
    local store = newStore()
    local handle = register(store, { cooldown = 0 })
    local result = store:activate(handle, makeContext({ now = 500 }), okHooks())
    expectTrue(result.ok)
    expectEqual(result.cooldownEndsAt, nil, "no cooldown is recorded when the cooldown is zero")
    expectTrue(store:activate(handle, makeContext({ now = 1 }), okHooks()).ok)
end)

test("an invalid clock value is rejected and can never bypass a cooldown", function()
    local store = newStore()
    local handle = register(store, { cooldown = 10 })
    expectTrue(store:activate(handle, makeContext({ now = 100 }), okHooks()).ok)
    local bad: { any } = { 0 / 0, math.huge, -math.huge, "100", true, {} }
    for _, now in ipairs(bad) do
        expectRejected(store:evaluate(handle, makeContext({ now = now })), Reasons.INVALID_CONTEXT, "now " .. tostring(now))
        local tokens = 0
        local result = store:activate(handle, makeContext({ now = now }), {
            consumeToken = function()
                tokens = tokens + 1
                return true
            end,
            handler = function()
                return true
            end,
        })
        expectRejected(result, Reasons.INVALID_CONTEXT, "activate now " .. tostring(now))
        expectEqual(tokens, 0)
    end
    expectRejected(store:evaluate(handle, makeContext({ now = "__nil__" })), Reasons.INVALID_CONTEXT, "missing now")
    expectEqual(store:getState(handle).cooldownEndsAt, 110, "the cooldown was not disturbed")
    expectRejected(store:evaluate(handle, makeContext({ now = 105 })), Reasons.COOLDOWN)
end)

test("a failed activation leaves an existing cooldown unchanged", function()
    local store = newStore()
    local handle = register(store, { cooldown = 10 })
    store:activate(handle, makeContext({ now = 100 }), okHooks()) -- until 110
    local result = store:activate(handle, makeContext({ now = 111 }), {
        consumeToken = function()
            return true
        end,
        handler = function()
            return false
        end,
    })
    expectRejected(result, Reasons.HANDLER_FAILED)
    expectEqual(store:getState(handle).cooldownEndsAt, 110, "a failure neither extends nor clears the old cooldown")
end)

-- API / configuration ----------------------------------------------------------------------------------------------------------------

test("new validates its dependencies", function()
    expectTrue(InteractionCore.new() ~= nil)
    expectTrue(InteractionCore.new({}) ~= nil)
    expectError(function()
        InteractionCore.new({ onHandlerError = "nope" } :: any)
    end, "non-function sink")
    expectError(function()
        InteractionCore.new({ clock = function() end } :: any)
    end, "unknown dependency")
    expectError(function()
        InteractionCore.new("deps" :: any)
    end, "non-table dependencies")
end)

test("limits, defaults and reasons are frozen and match the approved values", function()
    expectTrue(table.isfrozen(InteractionCore.Limits))
    expectTrue(table.isfrozen(InteractionCore.Defaults))
    expectTrue(table.isfrozen(InteractionCore.Reasons))
    expectTrue(table.isfrozen(InteractionCore.EvaluationOrder))
    expectEqual(InteractionCore.Limits.MinDistance, 2)
    expectEqual(InteractionCore.Limits.MaxDistance, 15)
    expectEqual(InteractionCore.Limits.MaxHoldDuration, 3)
    expectEqual(InteractionCore.Limits.MaxCooldown, 60)
    local required = {
        "not_registered", "target_unavailable", "mission_inactive", "not_participant", "player_not_eligible",
        "character_unavailable", "disabled", "busy", "cooldown", "out_of_range", "rate_limited", "handler_failed",
        "invalid_handle", "target_in_use", "duplicate_id", "invalid_spec",
    }
    local values: { [string]: boolean } = {}
    for _, value in pairs(InteractionCore.Reasons) do
        values[value] = true
    end
    for _, reason in ipairs(required) do
        expectTrue(values[reason], "missing reason " .. reason)
    end
end)

test("identical inputs give identical outputs on independent Stores (no hidden environment state)", function()
    local storeA, storeB = newStore(), newStore()
    local a = register(storeA, { cooldown = 5 })
    local b = register(storeB, { cooldown = 5 })
    local resultA = storeA:activate(a, makeContext({ now = 7 }), okHooks())
    local resultB = storeB:activate(b, makeContext({ now = 7 }), okHooks())
    expectEqual(resultA.cooldownEndsAt, resultB.cooldownEndsAt)
    expectEqual(resultA.cooldownEndsAt, 12)
end)
