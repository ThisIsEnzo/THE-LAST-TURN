--!strict
-- Pure door state machine (TTL-08C). No Roblox services, Instances, timers or globals: time is injected as
-- `now` (seconds). The door has two logical states, Closed and Open. A toggle switches the logical state at once
-- and starts a transition window of `transitionSeconds` during which further toggles are rejected. The window is
-- time-based (a deadline), not event-based, so a missing animation or tween event can never leave the door
-- permanently stuck: once `now` reaches the deadline the door is toggleable again.
--
-- Two steps keep the Roblox side safe: `planToggle` is non-mutating (the consumer applies the physical movement
-- only if it returns a state) and `commitToggle` applies the transition after the movement succeeded. A failed
-- movement therefore never changes the logical state.

local DoorCore = {}

DoorCore.States = table.freeze({
    Closed = "Closed",
    Open = "Open",
})

DoorCore.Limits = table.freeze({
    MinTransitionSeconds = 0.1,
    MaxTransitionSeconds = 10,
})

DoorCore.Reasons = table.freeze({
    TRANSITIONING = "transitioning", -- a transition is still in progress
    INVALID_TIME = "invalid_time", -- `now` is not a finite number (fail closed)
    INVALID_STATE = "invalid_state", -- not "Closed" or "Open"
    INVALID_TRANSITION = "invalid_transition", -- the requested state is not what a toggle produces
})

local States = DoorCore.States
local Reasons = DoorCore.Reasons
local Limits = DoorCore.Limits

export type State = string -- "Closed" | "Open"

export type Config = {
    initialState: string,
    transitionSeconds: number,
}

type DoorData = {
    _state: string,
    _transitionSeconds: number,
    _transitionEndsAt: number?,
}

local Door = {}
Door.__index = Door

export type Door = typeof(setmetatable({} :: DoorData, Door))

local function isFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isState(value: any): boolean
    return value == States.Closed or value == States.Open
end

-- Returns (true, nil) or (false, detail). Fail closed: unknown fields, wrong types, out-of-range values.
function DoorCore.validateConfig(config: any): (boolean, string?)
    if type(config) ~= "table" or getmetatable(config) ~= nil then
        return false, "config must be a plain table"
    end
    for key in pairs(config) do
        if key ~= "initialState" and key ~= "transitionSeconds" then
            return false, "unknown field " .. tostring(key)
        end
    end
    if not isState(config.initialState) then
        return false, "initialState must be Closed or Open"
    end
    if
        not isFiniteNumber(config.transitionSeconds)
        or config.transitionSeconds < Limits.MinTransitionSeconds
        or config.transitionSeconds > Limits.MaxTransitionSeconds
    then
        return false, "transitionSeconds must be a finite number in [0.1, 10]"
    end
    return true, nil
end

-- Raises on an invalid config (callers validate first with validateConfig).
function DoorCore.new(config: Config): Door
    local ok, detail = DoorCore.validateConfig(config)
    if not ok then
        error("DoorCore.new: " .. tostring(detail), 2)
    end
    return setmetatable({
        _state = config.initialState,
        _transitionSeconds = config.transitionSeconds,
        _transitionEndsAt = nil,
    }, Door)
end

function Door.getState(self: Door): string
    return (self :: any)._state
end

-- The state a toggle would produce (Closed -> Open, Open -> Closed).
function Door.nextState(self: Door): string
    if (self :: any)._state == States.Closed then
        return States.Open
    end
    return States.Closed
end

-- True while a transition is in progress. An invalid `now` counts as transitioning (fail closed). The deadline is
-- never clamped: a clock that moves backwards can only extend the window, never end it early.
function Door.isTransitioning(self: Door, now: any): boolean
    if not isFiniteNumber(now) then
        return true
    end
    local endsAt = (self :: any)._transitionEndsAt
    return endsAt ~= nil and now < endsAt
end

-- Non-mutating. Returns (nextState, nil) or (nil, reason).
function Door.planToggle(self: Door, now: any): (string?, string?)
    if not isFiniteNumber(now) then
        return nil, Reasons.INVALID_TIME
    end
    if self:isTransitioning(now) then
        return nil, Reasons.TRANSITIONING
    end
    return self:nextState(), nil
end

-- Applies the transition. `expected` must be exactly the state a toggle produces now. Returns (true, nil) or
-- (false, reason); a rejection leaves the door unchanged.
function Door.commitToggle(self: Door, expected: any, now: any): (boolean, string?)
    if not isState(expected) then
        return false, Reasons.INVALID_STATE
    end
    if not isFiniteNumber(now) then
        return false, Reasons.INVALID_TIME
    end
    if self:isTransitioning(now) then
        return false, Reasons.TRANSITIONING
    end
    if expected ~= self:nextState() then
        return false, Reasons.INVALID_TRANSITION
    end
    local data = self :: any
    data._state = expected
    data._transitionEndsAt = now + data._transitionSeconds
    return true, nil
end

-- When the current transition window ends, or nil if no transition has happened yet.
function Door.getTransitionEndsAt(self: Door): number?
    return (self :: any)._transitionEndsAt
end

return DoorCore
