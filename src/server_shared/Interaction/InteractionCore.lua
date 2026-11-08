--!strict
-- Pure interaction domain core (TTL-08B-A). No Roblox services, Instances, timers or globals: every fact about
-- the world (mission state, player eligibility, character, target, distance, time) is supplied by the caller
-- (the future InteractionService adapter) in the `context` of each call, and the rate limiter and the effect are
-- injected as hooks. See docs/TTL-08B-A_INTERACTION_CORE.md.
--
-- The Store owns: registrations, RegistrationHandle validity, target uniqueness, enabled / busy / cooldown state,
-- eligibility evaluation, the activation transaction and registration cleanup.
-- It does NOT own: player or mission lifecycle, character lookup, distance calculation, prompts, feedback, the
-- rate limiter, gameplay effects or any player-specific state.
--
-- HANDLER CONTRACT: the handler passed to `activate` is synchronous, short and NON-YIELDING (no task.wait,
-- WaitForChild, DataStore, teleport or any other yielding call, no asynchronous work). This is a mandatory
-- consumer contract enforced by code review; the Core has no runtime yield detection or cancellation. If a
-- handler yields anyway, the registration simply stays busy until it returns, and every identity guard below
-- still protects newer registrations.

local InteractionCore = {}

InteractionCore.Limits = table.freeze({
    MinDistance = 2,
    MaxDistance = 15, -- studs
    MinHoldDuration = 0,
    MaxHoldDuration = 3, -- seconds (UX only; the Core never enforces it)
    MinCooldown = 0,
    MaxCooldown = 60, -- seconds
    MaxIdLength = 64,
})

-- Applied only when an optional field is absent (an invalid provided value is always rejected, never coerced).
InteractionCore.Defaults = table.freeze({
    holdDuration = 0,
    cooldown = 0,
    enabled = true,
})

-- Stable machine-readable reasons. Never shown to players; the adapter maps them to logs.
InteractionCore.Reasons = table.freeze({
    INVALID_HANDLE = "invalid_handle", -- not issued by this Store (forged, copied, other Store, wrong type)
    NOT_REGISTERED = "not_registered", -- issued by this Store but unregistered or cleared since
    INVALID_CONTEXT = "invalid_context", -- malformed context (non-boolean fact, invalid `now`)
    TARGET_UNAVAILABLE = "target_unavailable",
    MISSION_INACTIVE = "mission_inactive",
    NOT_PARTICIPANT = "not_participant",
    PLAYER_NOT_ELIGIBLE = "player_not_eligible",
    CHARACTER_UNAVAILABLE = "character_unavailable",
    DISABLED = "disabled",
    BUSY = "busy",
    COOLDOWN = "cooldown",
    OUT_OF_RANGE = "out_of_range",
    RATE_LIMITED = "rate_limited",
    HANDLER_FAILED = "handler_failed", -- the handler returned anything but `true`, or threw
    HOOK_ERROR = "hook_error", -- the consumeToken hook threw (nothing was reserved)
    INVALID_HOOKS = "invalid_hooks",
    INVALID_SPEC = "invalid_spec",
    INVALID_TARGET_KEY = "invalid_target_key",
    INVALID_ENABLED = "invalid_enabled",
    DUPLICATE_ID = "duplicate_id",
    TARGET_IN_USE = "target_in_use",
})

-- Eligibility rejection precedence after the handle and the context were accepted (first failing check wins).
InteractionCore.EvaluationOrder = table.freeze({
    "target_unavailable",
    "mission_inactive",
    "not_participant",
    "player_not_eligible",
    "character_unavailable",
    "disabled",
    "busy",
    "cooldown",
    "out_of_range",
})

local Reasons = InteractionCore.Reasons
local Limits = InteractionCore.Limits
local Defaults = InteractionCore.Defaults

-- Types -----------------------------------------------------------------------------------------------------------

-- Issued and frozen by the Store. The fields are informational: authorization is by exact table identity.
export type RegistrationHandle = { id: string, serial: number }

export type Spec = {
    id: string, -- ^[%w_%-]+$, 1..64 characters (the project's token convention)
    maxDistance: number, -- studs, 2..15; accepted distance (the adapter may use the same value for the prompt)
    holdDuration: number?, -- seconds, 0..3 (default 0); UX only
    cooldown: number?, -- seconds, 0..60 (default 0); global per registration
    enabled: boolean?, -- default true
}

-- Facts supplied by the adapter for every evaluate/activate call.
export type Context = {
    missionActive: boolean,
    isParticipant: boolean,
    playerEligible: boolean, -- adapter: the player's lifecycle state is ALIVE
    characterAvailable: boolean,
    targetAvailable: boolean,
    distance: number?, -- studs; must be finite and >= 0, otherwise the request is out of range
    now: number, -- injected clock in seconds; must be finite
}

export type Hooks = {
    consumeToken: () -> boolean, -- the adapter's RateLimiter; only `true` allows the activation
    handler: () -> boolean, -- the consumer effect; only `true` is success
}

export type Dependencies = {
    -- Optional diagnostics sink for handler errors (called inside a protected call; may not break cleanup).
    onHandlerError: ((id: string, serial: number, message: string) -> ())?,
}

export type State = {
    id: string,
    serial: number,
    enabled: boolean,
    busy: boolean,
    cooldownEndsAt: number?,
    maxDistance: number,
    holdDuration: number,
    cooldown: number,
}

export type Result = { ok: boolean, reason: string? }

export type ActivationResult = {
    ok: boolean, -- the handler ran and returned true
    reason: string?, -- set when not ok
    executed: boolean, -- the handler was called
    stale: boolean, -- the registration was unregistered/cleared/replaced while the handler ran (nothing completed)
    cooldownEndsAt: number?, -- set only when a cooldown was applied
    handlerError: string?, -- diagnostics only (includes a traceback); never player-facing
}

type Record = {
    handle: RegistrationHandle,
    id: string,
    targetKey: any,
    maxDistance: number,
    holdDuration: number,
    cooldown: number,
    enabled: boolean,
    busy: boolean,
    cooldownEndsAt: number?,
}

type StoreData = {
    _records: { [any]: Record }, -- active handle -> record (identity)
    _byId: { [string]: Record },
    _byTarget: { [any]: Record }, -- target identity -> record
    _retired: { [any]: boolean }, -- weak-keyed: handles that were issued here and are no longer valid
    _count: number,
    _nextSerial: number, -- never reset, not even by clear()
    _onHandlerError: ((id: string, serial: number, message: string) -> ())?,
}

local Store = {}
Store.__index = Store

export type Store = typeof(setmetatable({} :: StoreData, Store))

-- Validation helpers ------------------------------------------------------------------------------------------------

local function isFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isNumberInRange(value: any, min: number, max: number): boolean
    return isFiniteNumber(value) and value >= min and value <= max
end

local ALLOWED_SPEC_FIELDS: { [string]: boolean } = {
    id = true,
    maxDistance = true,
    holdDuration = true,
    cooldown = true,
    enabled = true,
}

-- Validates a registration spec without modifying it. Returns (true, nil) or (false, detail). The detail names the
-- offending field for diagnostics; callers should rely on the stable reason `invalid_spec`.
function InteractionCore.validateSpec(spec: any): (boolean, string?)
    if type(spec) ~= "table" or getmetatable(spec) ~= nil then
        return false, "spec must be a plain table"
    end
    for key in pairs(spec) do
        if type(key) ~= "string" or not ALLOWED_SPEC_FIELDS[key] then
            return false, "unknown field " .. tostring(key)
        end
    end
    local id = spec.id
    if type(id) ~= "string" or #id < 1 or #id > Limits.MaxIdLength or string.match(id, "^[%w_%-]+$") == nil then
        return false, "invalid id"
    end
    if not isNumberInRange(spec.maxDistance, Limits.MinDistance, Limits.MaxDistance) then
        return false, "invalid maxDistance"
    end
    if spec.holdDuration ~= nil and not isNumberInRange(spec.holdDuration, Limits.MinHoldDuration, Limits.MaxHoldDuration) then
        return false, "invalid holdDuration"
    end
    if spec.cooldown ~= nil and not isNumberInRange(spec.cooldown, Limits.MinCooldown, Limits.MaxCooldown) then
        return false, "invalid cooldown"
    end
    if spec.enabled ~= nil and type(spec.enabled) ~= "boolean" then
        return false, "invalid enabled"
    end
    return true, nil
end

-- Target identity only: tables and userdata (Instances) are compared by reference. Strings and numbers would
-- compare by value, which is name-based identity, so they are rejected.
local function isValidTargetKey(value: any): boolean
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

local function isValidContext(context: any): boolean
    return type(context) == "table"
        and type(context.missionActive) == "boolean"
        and type(context.isParticipant) == "boolean"
        and type(context.playerEligible) == "boolean"
        and type(context.characterAvailable) == "boolean"
        and type(context.targetAvailable) == "boolean"
        and isFiniteNumber(context.now)
end

local function fail(reason: string): Result
    return { ok = false, reason = reason }
end

local function rejected(reason: string): ActivationResult
    return { ok = false, reason = reason, executed = false, stale = false }
end

-- Maps a handle to its active record, or explains why not. Identity only: field values are never compared.
local function resolve(self: any, handle: any): (Record?, string?)
    local record = self._records[handle]
    if record ~= nil then
        return record, nil
    end
    if type(handle) == "table" and self._retired[handle] == true then
        return nil, Reasons.NOT_REGISTERED
    end
    return nil, Reasons.INVALID_HANDLE
end

local function retire(self: any, record: Record)
    self._retired[record.handle] = true
end

-- Construction ------------------------------------------------------------------------------------------------------

function InteractionCore.new(dependencies: Dependencies?): Store
    local onHandlerError: ((string, number, string) -> ())? = nil
    if dependencies ~= nil then
        if type(dependencies) ~= "table" or getmetatable(dependencies) ~= nil then
            error("InteractionCore.new: dependencies must be a plain table", 2)
        end
        for key in pairs(dependencies) do
            if key ~= "onHandlerError" then
                error("InteractionCore.new: unknown dependency " .. tostring(key), 2)
            end
        end
        local callback = (dependencies :: any).onHandlerError
        if callback ~= nil and type(callback) ~= "function" then
            error("InteractionCore.new: onHandlerError must be a function", 2)
        end
        onHandlerError = callback
    end
    return setmetatable({
        _records = {},
        _byId = {},
        _byTarget = {},
        _retired = setmetatable({}, { __mode = "k" }),
        _count = 0,
        _nextSerial = 1,
        _onHandlerError = onHandlerError,
    }, Store)
end

-- Registration ------------------------------------------------------------------------------------------------------

-- Returns (handle, nil) on success or (nil, reason, detail?) on failure. A failed call changes nothing: no record,
-- no target reservation, no serial consumed. `targetKey` is any table or userdata (the adapter passes the target
-- part); uniqueness is by identity, never by name or id. A `targetKey` field inside `spec` is an unknown field.
function Store.register(self: Store, spec: any, targetKey: any): (RegistrationHandle?, string?, string?)
    local specOk, detail = InteractionCore.validateSpec(spec)
    if not specOk then
        return nil, Reasons.INVALID_SPEC, detail
    end
    if not isValidTargetKey(targetKey) then
        return nil, Reasons.INVALID_TARGET_KEY, nil
    end
    local data = self :: any
    if data._byId[spec.id] ~= nil then
        return nil, Reasons.DUPLICATE_ID, nil
    end
    if data._byTarget[targetKey] ~= nil then
        return nil, Reasons.TARGET_IN_USE, nil
    end

    local holdDuration = spec.holdDuration
    if holdDuration == nil then
        holdDuration = Defaults.holdDuration
    end
    local cooldown = spec.cooldown
    if cooldown == nil then
        cooldown = Defaults.cooldown
    end
    local enabled = spec.enabled
    if enabled == nil then
        enabled = Defaults.enabled
    end

    local serial = data._nextSerial
    data._nextSerial = serial + 1
    local handle: RegistrationHandle = table.freeze({ id = spec.id, serial = serial })
    local record: Record = {
        handle = handle,
        id = spec.id,
        targetKey = targetKey,
        maxDistance = spec.maxDistance,
        holdDuration = holdDuration,
        cooldown = cooldown,
        enabled = enabled,
        busy = false,
        cooldownEndsAt = nil,
    }
    data._records[handle] = record
    data._byId[record.id] = record
    data._byTarget[targetKey] = record
    data._count = data._count + 1
    return handle, nil, nil
end

-- Removes the registration, releases its target, invalidates the handle. Not idempotent: a second call with the
-- same handle returns (false, "not_registered"). A handle that this Store never issued returns "invalid_handle".
function Store.unregister(self: Store, handle: any): (boolean, string?)
    local data = self :: any
    local record, reason = resolve(data, handle)
    if record == nil then
        return false, reason
    end
    data._records[record.handle] = nil
    data._byId[record.id] = nil
    data._byTarget[record.targetKey] = nil
    data._count = data._count - 1
    retire(data, record)
    return true, nil
end

function Store.setEnabled(self: Store, handle: any, enabled: any): (boolean, string?)
    local record, reason = resolve(self :: any, handle)
    if record == nil then
        return false, reason
    end
    if type(enabled) ~= "boolean" then
        return false, Reasons.INVALID_ENABLED
    end
    record.enabled = enabled
    return true, nil
end

function Store.isRegistered(self: Store, handle: any): boolean
    local record = resolve(self :: any, handle)
    return record ~= nil
end

-- A copy of the registration state (never the internal record), or nil for an invalid or stale handle.
function Store.getState(self: Store, handle: any): State?
    local record = resolve(self :: any, handle)
    if record == nil then
        return nil
    end
    return {
        id = record.id,
        serial = record.handle.serial,
        enabled = record.enabled,
        busy = record.busy,
        cooldownEndsAt = record.cooldownEndsAt,
        maxDistance = record.maxDistance,
        holdDuration = record.holdDuration,
        cooldown = record.cooldown,
    }
end

function Store.count(self: Store): number
    return (self :: any)._count
end

-- Invalidates every registration and handle, releases every target, drops busy/cooldown state. The Store stays
-- usable and the serial counter keeps increasing (serials are never reused during the Store's lifetime).
function Store.clear(self: Store)
    local data = self :: any
    for _, record in pairs(data._records) do
        retire(data, record)
    end
    data._records = {}
    data._byId = {}
    data._byTarget = {}
    data._count = 0
end

-- Evaluation --------------------------------------------------------------------------------------------------------

-- Deterministic and NON-MUTATING: never reserves busy state, consumes tokens or touches a cooldown.
-- Order: invalid_handle / not_registered, invalid_context, then InteractionCore.EvaluationOrder.
-- Cooldown: rejected while now < cooldownEndsAt. The clock is never clamped: a clock that moves backwards can only
-- make an active cooldown last longer, never shorter, and an invalid `now` is rejected as invalid_context.
-- Distance: accepted when finite, >= 0 and <= maxDistance (the exact boundary is in range); anything else is out
-- of range.
function Store.evaluate(self: Store, handle: any, context: any): Result
    local record, reason = resolve(self :: any, handle)
    if record == nil then
        return fail(reason :: string)
    end
    if not isValidContext(context) then
        return fail(Reasons.INVALID_CONTEXT)
    end
    if not context.targetAvailable then
        return fail(Reasons.TARGET_UNAVAILABLE)
    end
    if not context.missionActive then
        return fail(Reasons.MISSION_INACTIVE)
    end
    if not context.isParticipant then
        return fail(Reasons.NOT_PARTICIPANT)
    end
    if not context.playerEligible then
        return fail(Reasons.PLAYER_NOT_ELIGIBLE)
    end
    if not context.characterAvailable then
        return fail(Reasons.CHARACTER_UNAVAILABLE)
    end
    if not record.enabled then
        return fail(Reasons.DISABLED)
    end
    if record.busy then
        return fail(Reasons.BUSY)
    end
    if record.cooldownEndsAt ~= nil and context.now < record.cooldownEndsAt then
        return fail(Reasons.COOLDOWN)
    end
    local distance = context.distance
    if not isFiniteNumber(distance) or distance < 0 or distance > record.maxDistance then
        return fail(Reasons.OUT_OF_RANGE)
    end
    return { ok = true, reason = nil }
end

-- Activation transaction -----------------------------------------------------------------------------------------

-- Pipeline: validate handle -> evaluate -> consumeToken -> evaluate again -> reserve busy -> handler (protected)
-- -> complete (release busy, apply cooldown on success).
--   * A rejection before the reservation consumes nothing that must be undone; a rate-limit rejection can never
--     leave the registration busy. The token is not refunded if the second evaluation fails.
--   * The reservation is created at exactly one point and released at exactly one point after the handler returns.
--   * Success means the handler returned `true`. `false`, any other value, or an error is a failure: busy is
--     released and no cooldown starts. Errors never escape; they are reported in `handlerError`.
--   * If the registration was unregistered, cleared or replaced while the handler ran, nothing is completed or
--     mutated (`stale = true`). Completion is decided by the identity of the original record, never by the id.
--   * The cooldown starts at `context.now` (the adapter supplies a fresh timestamp per activation) and is applied
--     only when the registration's cooldown is greater than zero.
function Store.activate(self: Store, handle: any, context: any, hooks: any): ActivationResult
    local data = self :: any
    local record, reason = resolve(data, handle)
    if record == nil then
        return rejected(reason :: string)
    end
    if type(hooks) ~= "table" or type(hooks.consumeToken) ~= "function" or type(hooks.handler) ~= "function" then
        return rejected(Reasons.INVALID_HOOKS)
    end

    local first = self:evaluate(handle, context)
    if not first.ok then
        return rejected(first.reason :: string)
    end

    local tokenOk, token = pcall(hooks.consumeToken)
    if not tokenOk then
        return rejected(Reasons.HOOK_ERROR)
    end
    if token ~= true then
        return rejected(Reasons.RATE_LIMITED)
    end

    local second = self:evaluate(handle, context) -- state may have changed while the token was consumed
    if not second.ok then
        return rejected(second.reason :: string)
    end

    record.busy = true -- reservation: nothing runs between the second evaluation and here

    local handlerOk, outcome = xpcall(hooks.handler, debug.traceback)
    local success = handlerOk and outcome == true
    local failureReason: string? = nil
    if not success then
        failureReason = Reasons.HANDLER_FAILED
    end

    local handlerError: string? = nil
    if not handlerOk then
        handlerError = tostring(outcome)
        local sink = data._onHandlerError
        if sink ~= nil then
            pcall(sink, record.id, record.handle.serial, handlerError :: string) -- a failing sink must not break cleanup
        end
    end

    if data._records[handle] ~= record then
        -- Unregistered, cleared or replaced during the handler: the reservation died with the record.
        return {
            ok = success,
            reason = failureReason,
            executed = true,
            stale = true,
            cooldownEndsAt = nil,
            handlerError = handlerError,
        }
    end

    record.busy = false
    local cooldownEndsAt: number? = nil
    if success and record.cooldown > 0 then
        cooldownEndsAt = context.now + record.cooldown
        record.cooldownEndsAt = cooldownEndsAt
    end
    return {
        ok = success,
        reason = failureReason,
        executed = true,
        stale = false,
        cooldownEndsAt = cooldownEndsAt,
        handlerError = handlerError,
    }
end

return InteractionCore
