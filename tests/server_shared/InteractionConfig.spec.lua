--!strict
local Harness = require("../Harness")
local InteractionConfig = require("../../src/mission/server/Interaction/InteractionConfig")
local InteractionCore = require("../../src/server_shared/Interaction/InteractionCore")
local RateLimiter = require("../../src/server_shared/Network/RateLimiter")
local NetworkConfig = require("../../src/server_shared/Network/NetworkConfig")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local Values = InteractionConfig.Values
local Reasons = InteractionCore.Reasons

-- Pure helpers only. InteractionService itself needs the Roblox runtime and is validated manually
-- (docs/TTL-08B-B_INTERACTION_SERVICE.md); these tests cover the configuration, the distance-tolerance helpers and the
-- rate-limit policy exactly as the service wires them (real RateLimiter, real InteractionCore).

local function config(overrides: { [string]: any }?): any
    local value: { [string]: any } = {
        distanceToleranceStuds = 1,
        rateLimit = { action = "Interact", capacity = 5, refillPerSecond = 2 },
        prompt = { actionText = "Interact", objectText = "" },
    }
    for key, item in pairs(overrides or {}) do
        value[key] = item
    end
    return value
end

local function invalid(value: any, label: string)
    local ok, detail = InteractionConfig.validate(value)
    expectFalse(ok, label)
    expectTrue(type(detail) == "string", label .. " detail")
end

-- Configuration -------------------------------------------------------------------------------------------------

test("shipped configuration is valid, frozen and documented", function()
    local ok, detail = InteractionConfig.validate(Values)
    expectTrue(ok, tostring(detail))
    expectTrue(table.isfrozen(Values))
    expectTrue(table.isfrozen(Values.rateLimit))
    expectTrue(table.isfrozen(Values.prompt))
    expectEqual(Values.distanceToleranceStuds, 1, "provisional 1-stud tolerance")
    expectEqual(Values.rateLimit.action, "Interact")
    expectEqual(Values.rateLimit.capacity, 5)
    expectEqual(Values.rateLimit.refillPerSecond, 2)
    expectEqual(Values.prompt.actionText, "Interact")
end)

test("validate accepts boundary values", function()
    expectTrue((InteractionConfig.validate(config({ distanceToleranceStuds = 0 }))))
    expectTrue((InteractionConfig.validate(config({ distanceToleranceStuds = 4 }))))
    expectTrue((InteractionConfig.validate(config({ rateLimit = { action = "A", capacity = 1, refillPerSecond = 0 } }))))
    expectTrue((InteractionConfig.validate(config({ rateLimit = { action = string.rep("a", 32), capacity = 100, refillPerSecond = 100 } }))))
    expectTrue((InteractionConfig.validate(config({ prompt = { actionText = string.rep("x", 40), objectText = string.rep("y", 40) } }))))
end)

test("validate rejects malformed configurations (fail closed)", function()
    invalid(nil, "nil")
    invalid("config", "string")
    invalid({ 1, 2 }, "array")
    local extra = config()
    extra.extra = true
    invalid(extra, "unknown top-level field")
    local missing = config()
    missing.prompt = nil
    invalid(missing, "missing prompt")
    for _, tolerance in ipairs({ -0.001, 4.001, 100 }) do
        invalid(config({ distanceToleranceStuds = tolerance }), "tolerance " .. tostring(tolerance))
    end
    local badNumbers: { any } = { 0 / 0, math.huge, -math.huge, "1", true, {} }
    for _, value in ipairs(badNumbers) do
        invalid(config({ distanceToleranceStuds = value }), "tolerance " .. tostring(value))
    end
end)

test("validate rejects invalid rate-limit policies", function()
    invalid(config({ rateLimit = "x" }), "non-table")
    invalid(config({ rateLimit = { action = "Interact", capacity = 5 } }), "missing refill")
    invalid(config({ rateLimit = { action = "Interact", capacity = 5, refillPerSecond = 2, extra = 1 } }), "unknown field")
    for _, action in ipairs({ "", string.rep("a", 33), "bad action", "dot.action" }) do
        invalid(config({ rateLimit = { action = action, capacity = 5, refillPerSecond = 2 } }), "action " .. action)
    end
    invalid(config({ rateLimit = { action = 5, capacity = 5, refillPerSecond = 2 } }), "numeric action")
    for _, capacity in ipairs({ 0, 0.5, 101, -1 }) do
        invalid(config({ rateLimit = { action = "Interact", capacity = capacity, refillPerSecond = 2 } }), "capacity " .. capacity)
    end
    for _, refill in ipairs({ -1, 101 }) do
        invalid(config({ rateLimit = { action = "Interact", capacity = 5, refillPerSecond = refill } }), "refill " .. refill)
    end
    invalid(config({ rateLimit = { action = "Interact", capacity = 0 / 0, refillPerSecond = 2 } }), "NaN capacity")
    invalid(config({ rateLimit = { action = "Interact", capacity = 5, refillPerSecond = math.huge } }), "infinite refill")
end)

test("validate rejects invalid prompt texts", function()
    invalid(config({ prompt = { actionText = "", objectText = "" } }), "empty action text")
    invalid(config({ prompt = { actionText = string.rep("x", 41), objectText = "" } }), "long action text")
    invalid(config({ prompt = { actionText = "Open\ndoor", objectText = "" } }), "control character")
    invalid(config({ prompt = { actionText = "Interact", objectText = string.rep("y", 41) } }), "long object text")
    invalid(config({ prompt = { actionText = 5, objectText = "" } }), "numeric text")
    invalid(config({ prompt = { actionText = "Interact" } }), "missing object text")
    invalid(config({ prompt = { actionText = "Interact", objectText = "", extra = 1 } }), "unknown prompt field")
end)

-- Distance tolerance ---------------------------------------------------------------------------------------------

test("effectiveRadius is maxDistance plus the tolerance", function()
    expectEqual(InteractionConfig.effectiveRadius(10, 1), 11)
    expectEqual(InteractionConfig.effectiveRadius(2, 0), 2)
    expectEqual(InteractionConfig.effectiveRadius(15, 4), 19)
end)

test("coreDistance subtracts the tolerance and never goes below zero", function()
    expectEqual(InteractionConfig.coreDistance(11, 1), 10)
    expectEqual(InteractionConfig.coreDistance(5, 1), 4)
    expectEqual(InteractionConfig.coreDistance(1, 1), 0)
    expectEqual(InteractionConfig.coreDistance(0.5, 1), 0)
    expectEqual(InteractionConfig.coreDistance(0, 1), 0)
    expectEqual(InteractionConfig.coreDistance(7, 0), 7)
end)

test("coreDistance never turns an invalid raw distance into a valid one", function()
    local nan = InteractionConfig.coreDistance(0 / 0, 1)
    expectTrue(nan ~= nan, "NaN stays NaN")
    expectEqual(InteractionConfig.coreDistance(math.huge, 1), math.huge)
    expectEqual(InteractionConfig.coreDistance(-math.huge, 1), -math.huge)
    expectEqual(InteractionConfig.coreDistance(-0.5, 1), -0.5, "negative stays negative")
    expectEqual(InteractionConfig.coreDistance(-100, 4), -100)
    expectEqual(InteractionConfig.coreDistance("5", 1), "5")
    expectEqual(InteractionConfig.coreDistance(nil, 1), nil)
end)

local function evaluateWithRaw(maxDistance: number, tolerance: number, raw: any): any
    local store = InteractionCore.new()
    local handle = store:register({ id = "Probe", maxDistance = maxDistance }, {})
    return store:evaluate(handle, {
        missionActive = true,
        isParticipant = true,
        playerEligible = true,
        characterAvailable = true,
        targetAvailable = true,
        distance = InteractionConfig.coreDistance(raw, tolerance),
        now = 0,
    })
end

test("the Core accepts exactly the effective radius (prompt radius == server radius)", function()
    for _, maxDistance in ipairs({ 2, 6, 8, 10, 15 }) do
        for _, tolerance in ipairs({ 0, 1, 2, 4 }) do
            local radius = InteractionConfig.effectiveRadius(maxDistance, tolerance)
            expectTrue(evaluateWithRaw(maxDistance, tolerance, radius).ok, "at the radius " .. radius)
            expectTrue(evaluateWithRaw(maxDistance, tolerance, 0).ok, "zero distance")
            local over = evaluateWithRaw(maxDistance, tolerance, radius + 0.001)
            expectFalse(over.ok, "just beyond " .. radius)
            expectEqual(over.reason, Reasons.OUT_OF_RANGE)
        end
    end
end)

test("invalid raw distances are rejected as out of range by the Core", function()
    for _, raw in ipairs({ -1, math.huge, -math.huge, "5", true }) do
        local result = evaluateWithRaw(10, 1, raw)
        expectFalse(result.ok, tostring(raw))
        expectEqual(result.reason, Reasons.OUT_OF_RANGE, tostring(raw))
    end
    local nan = evaluateWithRaw(10, 1, 0 / 0)
    expectEqual(nan.reason, Reasons.OUT_OF_RANGE, "NaN")
end)

-- Rate-limit policy (real RateLimiter + shipped configuration) -----------------------------------------------

local function newLimiter(clock: () -> number): any
    local limits: { [string]: any } = {}
    limits[Values.rateLimit.action] = { capacity = Values.rateLimit.capacity, refillPerSecond = Values.rateLimit.refillPerSecond }
    return RateLimiter.new(limits, clock)
end

local function activationContext(now: number): any
    return {
        missionActive = true,
        isParticipant = true,
        playerEligible = true,
        characterAvailable = true,
        targetAvailable = true,
        distance = 1,
        now = now,
    }
end

test("the shipped limit allows a burst of 5 and refills 2 tokens per second", function()
    local now = 0
    local limiter = newLimiter(function()
        return now
    end)
    local action = Values.rateLimit.action
    for _ = 1, 5 do
        expectTrue(limiter:tryConsume(1, action))
    end
    expectFalse(limiter:tryConsume(1, action), "the sixth request in the same instant")
    now = 0.5
    expectTrue(limiter:tryConsume(1, action), "one token after 0.5 s")
    expectFalse(limiter:tryConsume(1, action))
    now = 100
    for _ = 1, 5 do
        expectTrue(limiter:tryConsume(1, action))
    end
    expectFalse(limiter:tryConsume(1, action), "the bucket never exceeds its capacity")
end)

test("one shared bucket per player covers every registered interaction; players are independent", function()
    local now = 0
    local limiter = newLimiter(function()
        return now
    end)
    local store = InteractionCore.new()
    local doorHandle = store:register({ id = "Door", maxDistance = 5 }, {})
    local switchHandle = store:register({ id = "Switch", maxDistance = 5 }, {})
    local handlerCalls = 0
    local function activate(handle: any, userId: number): any
        return store:activate(handle, activationContext(now), {
            consumeToken = function()
                return limiter:tryConsume(userId, Values.rateLimit.action)
            end,
            handler = function()
                handlerCalls = handlerCalls + 1
                return true
            end,
        })
    end
    -- Player 1 alternates between two interactions: the 5-token budget is shared.
    for index = 1, 5 do
        expectTrue(activate(index % 2 == 0 and doorHandle or switchHandle, 1).ok)
    end
    local limited = activate(doorHandle, 1)
    expectFalse(limited.ok)
    expectEqual(limited.reason, Reasons.RATE_LIMITED)
    local limitedSwitch = activate(switchHandle, 1)
    expectEqual(limitedSwitch.reason, Reasons.RATE_LIMITED, "the other interaction shares the same bucket")
    -- Player 2 has an untouched bucket.
    expectTrue(activate(doorHandle, 2).ok)
    expectTrue(activate(switchHandle, 2).ok)
    expectEqual(handlerCalls, 7)
    -- A rate-limit rejection never leaves an interaction busy or in cooldown.
    expectFalse(store:getState(doorHandle).busy)
    expectFalse(store:getState(switchHandle).busy)
end)

test("player cleanup drops limiter state and a second deferred removal is harmless", function()
    local limiter = newLimiter(function()
        return 0
    end)
    local action = Values.rateLimit.action
    limiter:tryConsume(1, action)
    limiter:tryConsume(2, action)
    expectEqual(limiter:getTrackedPlayerCount(), 2)
    limiter:removePlayer(1) -- immediate removal on PlayerRemoving
    limiter:tryConsume(1, action) -- a queued callback recreates state...
    limiter:removePlayer(1) -- ...so the deferred second removal clears it again
    limiter:removePlayer(1)
    expectEqual(limiter:getTrackedPlayerCount(), 1)
    limiter:removePlayer(999) -- unknown players are safe
    expectEqual(limiter:getTrackedPlayerCount(), 1)
end)

test("a limiter configured for another action rejects 'Interact' (fail closed)", function()
    local limiter = RateLimiter.new({ SomethingElse = { capacity = 5, refillPerSecond = 2 } }, function()
        return 0
    end)
    expectFalse(limiter:tryConsume(1, Values.rateLimit.action))
end)

test("the interaction action is not a NetworkConfig remote rate limit", function()
    -- NetworkService.init() requires every NetworkConfig.RateLimits action to be a declared remote request;
    -- 'Interact' is a native ProximityPrompt action and must stay out of that table.
    expectEqual((NetworkConfig.RateLimits :: any)[Values.rateLimit.action], nil)
end)

-- Per-interaction prompt options (TTL-08C) ---------------------------------------------------------------------------

test("validatePromptOptions accepts valid options", function()
    expectTrue((InteractionConfig.validatePromptOptions({})))
    expectTrue((InteractionConfig.validatePromptOptions({ actionText = "Use" })))
    expectTrue((InteractionConfig.validatePromptOptions({ objectText = "" })))
    expectTrue((InteractionConfig.validatePromptOptions({ actionText = "Use", objectText = "Door" })))
    expectTrue((InteractionConfig.validatePromptOptions({ actionText = string.rep("x", 40), objectText = string.rep("y", 40) })))
end)

test("validatePromptOptions rejects invalid options (fail closed)", function()
    local function bad(options: any, label: string)
        local ok, detail = InteractionConfig.validatePromptOptions(options)
        expectFalse(ok, label)
        expectTrue(type(detail) == "string", label)
    end
    bad(nil, "nil")
    bad("Use", "string")
    bad(setmetatable({ actionText = "Use" }, {}), "metatable")
    bad({ actionText = "" }, "empty action text")
    bad({ actionText = string.rep("x", 41) }, "long action text")
    bad({ actionText = "Open\ndoor" }, "control character")
    bad({ actionText = 5 }, "numeric action text")
    bad({ objectText = string.rep("y", 41) }, "long object text")
    bad({ objectText = true }, "boolean object text")
    bad({ actionText = "Use", extra = 1 }, "unknown field")
    bad({ "Use" }, "array")
end)

