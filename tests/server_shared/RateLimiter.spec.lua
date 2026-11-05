--!strict
local Harness = require("../Harness")
local RateLimiter = require("../../src/server_shared/Network/RateLimiter")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local function newLimiter()
    local now = 0
    local limiter = RateLimiter.new({
        Fast = { capacity = 3, refillPerSecond = 1 },
        Slow = { capacity = 1, refillPerSecond = 0.1 },
    }, function()
        return now
    end)
    local function advance(seconds: number)
        now += seconds
    end
    return limiter, advance
end

test("accepts up to capacity then rejects", function()
    local limiter = newLimiter()
    expectTrue(limiter:tryConsume(1, "Fast"))
    expectTrue(limiter:tryConsume(1, "Fast"))
    expectTrue(limiter:tryConsume(1, "Fast"))
    expectFalse(limiter:tryConsume(1, "Fast"))
    expectFalse(limiter:tryConsume(1, "Fast"))
end)

test("tokens refill over time and never exceed capacity", function()
    local limiter, advance = newLimiter()
    for _ = 1, 3 do
        limiter:tryConsume(1, "Fast")
    end
    expectFalse(limiter:tryConsume(1, "Fast"))
    advance(1)
    expectTrue(limiter:tryConsume(1, "Fast"))
    expectFalse(limiter:tryConsume(1, "Fast"))
    advance(1000)
    for _ = 1, 3 do
        expectTrue(limiter:tryConsume(1, "Fast"))
    end
    expectFalse(limiter:tryConsume(1, "Fast"), "refill must be capped at capacity")
end)

test("players are limited independently", function()
    local limiter = newLimiter()
    expectTrue(limiter:tryConsume(1, "Slow"))
    expectFalse(limiter:tryConsume(1, "Slow"))
    expectTrue(limiter:tryConsume(2, "Slow"))
    expectFalse(limiter:tryConsume(2, "Slow"))
end)

test("actions are limited independently", function()
    local limiter = newLimiter()
    expectTrue(limiter:tryConsume(1, "Slow"))
    expectFalse(limiter:tryConsume(1, "Slow"))
    expectTrue(limiter:tryConsume(1, "Fast"))
end)

test("unknown actions are rejected and create no state", function()
    local limiter = newLimiter()
    expectFalse(limiter:tryConsume(1, "Nope"))
    expectEqual(limiter:getTrackedPlayerCount(), 0)
end)

test("removePlayer clears state and resets that player's limits", function()
    local limiter = newLimiter()
    expectTrue(limiter:tryConsume(1, "Slow"))
    expectTrue(limiter:tryConsume(2, "Slow"))
    expectEqual(limiter:getTrackedPlayerCount(), 2)
    limiter:removePlayer(1)
    expectEqual(limiter:getTrackedPlayerCount(), 1)
    expectTrue(limiter:tryConsume(1, "Slow"), "fresh state after removal")
    expectFalse(limiter:tryConsume(2, "Slow"), "other player unaffected")
end)

test("removePlayer is idempotent and safe for unknown players", function()
    local limiter = newLimiter()
    limiter:removePlayer(99)
    limiter:tryConsume(1, "Fast")
    limiter:removePlayer(1)
    limiter:removePlayer(1)
    expectEqual(limiter:getTrackedPlayerCount(), 0)
end)

test("state does not accumulate across many joining and leaving players", function()
    local limiter = newLimiter()
    for userId = 1, 500 do
        limiter:tryConsume(userId, "Fast")
        limiter:removePlayer(userId)
    end
    expectEqual(limiter:getTrackedPlayerCount(), 0)
end)

test("clock moving backwards does not grant tokens", function()
    local now = 10
    local limiter = RateLimiter.new({ A = { capacity = 1, refillPerSecond = 1 } }, function()
        return now
    end)
    expectTrue(limiter:tryConsume(1, "A"))
    now = 5
    expectFalse(limiter:tryConsume(1, "A"))
end)

test("invalid limit configuration is rejected", function()
    Harness.expectError(function()
        RateLimiter.new({ A = { capacity = 0, refillPerSecond = 1 } }, function()
            return 0
        end)
    end)
    Harness.expectError(function()
        RateLimiter.new({ A = { capacity = 1, refillPerSecond = -1 } }, function()
            return 0
        end)
    end)
    Harness.expectError(function()
        RateLimiter.new({ A = { capacity = math.huge, refillPerSecond = 1 } }, function()
            return 0
        end)
    end)
end)

return {}
