--!strict
-- Server-only tunables for InteractionService, plus the small pure helpers derived from them. Plain data and
-- pure functions only (no Roblox APIs), so Lune tests can load and validate exactly what ships.
--
-- The interaction rate limit is deliberately NOT part of NetworkConfig.RateLimits: NetworkService.init()
-- requires every configured action there to be a declared remote request, and "Interact" is a native
-- ProximityPrompt activation, not a RemoteEvent request. InteractionService owns a dedicated RateLimiter.

export type RateLimit = {
    action: string, -- the single shared bucket name used for every interaction
    capacity: number, -- burst size
    refillPerSecond: number, -- sustained rate
}

export type PromptDefaults = {
    actionText: string, -- generic default; per-interaction texts belong to later milestones
    objectText: string,
}

export type Config = {
    distanceToleranceStuds: number,
    rateLimit: RateLimit,
    prompt: PromptDefaults,
}

local InteractionConfig = {}

InteractionConfig.MaxToleranceStuds = 4
InteractionConfig.MaxTextBytes = 40

InteractionConfig.Values = table.freeze({
    -- PROVISIONAL (to be measured and tuned in Studio). The prompt is shown within maxDistance + tolerance and the
    -- server accepts the same effective radius. It absorbs the difference between the engine's prompt distance
    -- reference and the server's HumanoidRootPart-to-target measurement. It is a UX/engine-parity allowance,
    -- not a security bypass: the server still recomputes the distance for every activation.
    distanceToleranceStuds = 1,

    -- One shared bucket per player across ALL registered interactions.
    rateLimit = table.freeze({
        action = "Interact",
        capacity = 5,
        refillPerSecond = 2,
    }),

    prompt = table.freeze({
        actionText = "Interact",
        objectText = "",
    }),
})

local function isFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isPromptText(value: any, minBytes: number): boolean
    return type(value) == "string"
        and #value >= minBytes
        and #value <= InteractionConfig.MaxTextBytes
        and string.find(value, "%c") == nil
end

local function hasOnlyFields(value: any, allowed: { [string]: boolean }): boolean
    if type(value) ~= "table" then
        return false
    end
    for key in pairs(value) do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
    end
    return true
end

-- Returns (true, nil) or (false, detail). Fail closed: unknown fields, wrong types and out-of-range values.
function InteractionConfig.validate(config: any): (boolean, string?)
    if not hasOnlyFields(config, { distanceToleranceStuds = true, rateLimit = true, prompt = true }) then
        return false, "config must be a table with distanceToleranceStuds, rateLimit and prompt only"
    end
    local tolerance = config.distanceToleranceStuds
    if not isFiniteNumber(tolerance) or tolerance < 0 or tolerance > InteractionConfig.MaxToleranceStuds then
        return false, "distanceToleranceStuds must be a finite number in [0, " .. InteractionConfig.MaxToleranceStuds .. "]"
    end

    local rateLimit = config.rateLimit
    if not hasOnlyFields(rateLimit, { action = true, capacity = true, refillPerSecond = true }) then
        return false, "rateLimit must contain action, capacity and refillPerSecond only"
    end
    local action = rateLimit.action
    if type(action) ~= "string" or #action < 1 or #action > 32 or string.match(action, "^[%w_%-]+$") == nil then
        return false, "rateLimit.action must be a 1-32 character token"
    end
    if not isFiniteNumber(rateLimit.capacity) or rateLimit.capacity < 1 or rateLimit.capacity > 100 then
        return false, "rateLimit.capacity must be a finite number in [1, 100]"
    end
    if not isFiniteNumber(rateLimit.refillPerSecond) or rateLimit.refillPerSecond < 0 or rateLimit.refillPerSecond > 100 then
        return false, "rateLimit.refillPerSecond must be a finite number in [0, 100]"
    end

    local prompt = config.prompt
    if not hasOnlyFields(prompt, { actionText = true, objectText = true }) then
        return false, "prompt must contain actionText and objectText only"
    end
    if not isPromptText(prompt.actionText, 1) then
        return false, "prompt.actionText must be 1-40 bytes without control characters"
    end
    if not isPromptText(prompt.objectText, 0) then
        return false, "prompt.objectText must be 0-40 bytes without control characters"
    end
    return true, nil
end

-- Optional per-interaction prompt texts accepted by InteractionService.register (TTL-08C). Returns (true, nil) or
-- (false, detail): a plain table with only actionText / objectText, each nil or a valid text.
function InteractionConfig.validatePromptOptions(options: any): (boolean, string?)
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        return false, "options must be a plain table"
    end
    if not hasOnlyFields(options, { actionText = true, objectText = true }) then
        return false, "options may contain actionText and objectText only"
    end
    if options.actionText ~= nil and not isPromptText(options.actionText, 1) then
        return false, "actionText must be 1-40 bytes without control characters"
    end
    if options.objectText ~= nil and not isPromptText(options.objectText, 0) then
        return false, "objectText must be 0-40 bytes without control characters"
    end
    return true, nil
end

-- The radius shown by the prompt (MaxActivationDistance) and accepted by the server: maxDistance + tolerance.
function InteractionConfig.effectiveRadius(maxDistance: number, toleranceStuds: number): number
    return maxDistance + toleranceStuds
end

-- Converts a raw, server-measured distance into the distance fact handed to InteractionCore, whose own rule is
-- `distance <= maxDistance`. Subtracting the tolerance makes the accepted radius maxDistance + tolerance without
-- changing the Core's semantics. A raw distance that is not a finite number >= 0 is passed through UNCHANGED so
-- the Core rejects it as out of range; it is never turned into a valid one.
function InteractionConfig.coreDistance(rawDistance: any, toleranceStuds: number): any
    if not isFiniteNumber(rawDistance) or rawDistance < 0 then
        return rawDistance
    end
    local adjusted = rawDistance - toleranceStuds
    if adjusted < 0 then
        return 0
    end
    return adjusted
end

return InteractionConfig
