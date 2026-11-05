--!strict
-- Per-player, per-action token-bucket rate limiter. Pure Luau (clock is injected) so it can be
-- unit tested. State is bounded: at most (tracked players x configured actions) buckets, and a
-- player's buckets are dropped by removePlayer. Unknown actions are rejected (fail closed).

export type Limit = {
    capacity: number, -- burst size; also the number of requests allowed at once
    refillPerSecond: number, -- sustained rate
}

type Bucket = { tokens: number, last: number }

type RateLimiterData = {
    _limits: { [string]: Limit },
    _clock: () -> number,
    _players: { [number]: { [string]: Bucket } },
    _playerCount: number,
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable({} :: RateLimiterData, RateLimiter))

local function isFinitePositive(value: any, allowZero: boolean): boolean
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and (value > 0 or (allowZero and value == 0))
end

function RateLimiter.new(limits: { [string]: Limit }, clock: () -> number): RateLimiter
    local copy: { [string]: Limit } = {}
    for action, limit in pairs(limits) do
        if not isFinitePositive(limit.capacity, false) or limit.capacity < 1 then
            error("RateLimiter: capacity for '" .. action .. "' must be a finite number >= 1", 2)
        end
        if not isFinitePositive(limit.refillPerSecond, true) then
            error("RateLimiter: refillPerSecond for '" .. action .. "' must be a finite number >= 0", 2)
        end
        copy[action] = { capacity = limit.capacity, refillPerSecond = limit.refillPerSecond }
    end
    return setmetatable({
        _limits = copy,
        _clock = clock,
        _players = {},
        _playerCount = 0,
    }, RateLimiter)
end

-- Returns true and consumes one token if the request is allowed; false otherwise.
function RateLimiter.tryConsume(self: RateLimiter, playerKey: number, action: string): boolean
    local limit = self._limits[action]
    if limit == nil then
        return false
    end

    local now = self._clock()
    local buckets = self._players[playerKey]
    if buckets == nil then
        buckets = {}
        self._players[playerKey] = buckets
        self._playerCount += 1
    end

    local bucket = buckets[action]
    if bucket == nil then
        bucket = { tokens = limit.capacity, last = now }
        buckets[action] = bucket
    end

    local elapsed = math.max(0, now - bucket.last)
    bucket.tokens = math.min(limit.capacity, bucket.tokens + elapsed * limit.refillPerSecond)
    bucket.last = math.max(bucket.last, now) -- never move backwards

    if bucket.tokens >= 1 then
        bucket.tokens -= 1
        return true
    end
    return false
end

-- Drops all state for a player. Safe to call repeatedly or for unknown players.
function RateLimiter.removePlayer(self: RateLimiter, playerKey: number)
    if self._players[playerKey] ~= nil then
        self._players[playerKey] = nil
        self._playerCount -= 1
    end
end

function RateLimiter.getTrackedPlayerCount(self: RateLimiter): number
    return self._playerCount
end

return RateLimiter
