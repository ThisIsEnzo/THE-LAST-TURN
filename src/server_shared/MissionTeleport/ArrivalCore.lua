--!strict
-- Pure MISSION arrival coordination. Takes payloads that were already validated by TeleportPayload.validate.
-- The first valid arrival establishes the mission context; later arrivals must carry the identical context and be
-- listed members. Nothing here starts gameplay; it only exposes a readiness state.
--
-- States: NO_CONTEXT (nothing accepted yet) -> WAITING (some expected players missing) -> READY (all arrived) or
-- INCOMPLETE (arrival timeout elapsed with players missing). Late valid arrivals are still accepted and can move
-- INCOMPLETE -> READY; consumers must read the state, never assume a full party.

export type Config = { arrivalTimeoutSeconds: number }

local ArrivalCore = {}

ArrivalCore.States = table.freeze({
    NO_CONTEXT = "NO_CONTEXT",
    WAITING = "WAITING",
    READY = "READY",
    READY_PARTIAL = "READY_PARTIAL",
    INCOMPLETE = "INCOMPLETE",
})

-- Only these states may initialize a mission; both require a connected expected participant.
function ArrivalCore.isStartable(state: string): boolean
    return state == ArrivalCore.States.READY or state == ArrivalCore.States.READY_PARTIAL
end

function ArrivalCore.checkJoinSource(sourcePlaceId: number?, sourceGameId: number?, expectedHubPlaceId: number, expectedGameId: number): (boolean, string?)
    if type(expectedHubPlaceId) ~= "number" or expectedHubPlaceId <= 0 or expectedHubPlaceId % 1 ~= 0 then
        return false, "hub_place_not_configured"
    end
    if type(expectedGameId) ~= "number" or expectedGameId <= 0 or expectedGameId % 1 ~= 0 then
        return false, "experience_not_configured"
    end
    if sourcePlaceId ~= expectedHubPlaceId then
        return false, "unexpected_source_place"
    end
    if sourceGameId ~= expectedGameId then
        return false, "unexpected_source_game"
    end
    return true, nil
end

-- env: placeId, expectedPlaceId, privateServerId, privateServerOwnerId (Roblox values passed in by the service).
function ArrivalCore.checkEnvironment(env: {
    placeId: number,
    expectedPlaceId: number,
    privateServerId: string,
    privateServerOwnerId: number,
}): (boolean, string?)
    if type(env.expectedPlaceId) ~= "number" or env.expectedPlaceId <= 0 or env.expectedPlaceId % 1 ~= 0 then
        return false, "mission_place_not_configured"
    end
    if env.placeId ~= env.expectedPlaceId then
        return false, "unexpected_place"
    end
    if type(env.privateServerId) ~= "string" or env.privateServerId == "" or env.privateServerOwnerId ~= 0 then
        return false, "not_reserved_server"
    end
    return true, nil
end

type Context = {
    missionId: string,
    partyId: string,
    leader: number,
    missionType: string,
    expected: { number },
    expectedSet: { [number]: boolean },
    arrivedEver: { [number]: boolean },
    arrivalOrder: { number },
    present: { [number]: boolean },
    startedAt: number,
    timedOut: boolean,
}

type StoreData = { _config: Config, _clock: () -> number, _context: Context? }

local Store = {}
Store.__index = Store

export type Store = typeof(setmetatable({} :: StoreData, Store))

export type ArrivalResult = { ok: boolean, changed: boolean, rejection: string?, state: string }

function ArrivalCore.new(config: Config, clock: () -> number): Store
    if type(config.arrivalTimeoutSeconds) ~= "number" or config.arrivalTimeoutSeconds <= 0 or config.arrivalTimeoutSeconds == math.huge then
        error("ArrivalCore: arrivalTimeoutSeconds must be a finite number > 0", 2)
    end
    return setmetatable({ _config = { arrivalTimeoutSeconds = config.arrivalTimeoutSeconds }, _clock = clock, _context = nil }, Store)
end

local function computeState(context: Context?): string
    if context == nil then
        return ArrivalCore.States.NO_CONTEXT
    end
    local missing = false
    local presentCount = 0
    for _, userId in ipairs(context.expected) do
        if not context.arrivedEver[userId] then
            missing = true
        end
        if context.present[userId] then
            presentCount += 1
        end
    end
    if presentCount == 0 then
        return if context.timedOut then ArrivalCore.States.INCOMPLETE else ArrivalCore.States.WAITING
    end
    if not missing then
        return ArrivalCore.States.READY
    end
    return if context.timedOut then ArrivalCore.States.READY_PARTIAL else ArrivalCore.States.WAITING
end

function Store.getState(self: Store): string
    return computeState(self._context)
end

local function sameMembers(context: Context, members: { number }): boolean
    if #members ~= #context.expected then
        return false
    end
    for _, userId in ipairs(members) do
        if not context.expectedSet[userId] then
            return false
        end
    end
    return true
end

-- `payload` must already be validated. Never adds a player to a context they are not part of.
function Store.arrive(self: Store, userId: number, payload: any): ArrivalResult
    local context = self._context
    if context == nil then
        local isMember = table.find(payload.memberUserIds, userId) ~= nil
        if not isMember then
            return { ok = false, changed = false, rejection = "not_expected", state = computeState(nil) }
        end
        local expectedSet: { [number]: boolean } = {}
        for _, memberId in ipairs(payload.memberUserIds) do
            expectedSet[memberId] = true
        end
        context = {
            missionId = payload.missionId,
            partyId = payload.partyId,
            leader = payload.partyLeaderUserId,
            missionType = payload.missionType,
            expected = table.clone(payload.memberUserIds),
            expectedSet = expectedSet,
            arrivedEver = {},
            arrivalOrder = {},
            present = {},
            startedAt = self._clock(),
            timedOut = false,
        }
        self._context = context
    else
        if
            payload.missionId ~= context.missionId
            or payload.partyId ~= context.partyId
            or payload.partyLeaderUserId ~= context.leader
            or payload.missionType ~= context.missionType
            or not sameMembers(context, payload.memberUserIds)
        then
            return { ok = false, changed = false, rejection = "context_mismatch", state = computeState(context) }
        end
        if not context.expectedSet[userId] then
            return { ok = false, changed = false, rejection = "not_expected", state = computeState(context) }
        end
    end

    local ctx = context :: Context
    if ctx.present[userId] then
        return { ok = true, changed = false, rejection = nil, state = computeState(ctx) } -- duplicate arrival
    end
    ctx.present[userId] = true
    if not ctx.arrivedEver[userId] then
        ctx.arrivedEver[userId] = true
        table.insert(ctx.arrivalOrder, userId)
    end
    return { ok = true, changed = true, rejection = nil, state = computeState(ctx) }
end

-- A disconnect keeps the player counted as having arrived but no longer present.
function Store.leave(self: Store, userId: number): boolean
    local context = self._context
    if context == nil or not context.present[userId] then
        return false
    end
    context.present[userId] = nil
    return true
end

-- Marks the context incomplete when the arrival window has elapsed. Returns the (possibly new) state.
function Store.checkTimeout(self: Store): string
    local context = self._context
    if context ~= nil and not context.timedOut and self._clock() - context.startedAt >= self._config.arrivalTimeoutSeconds then
        context.timedOut = true
    end
    return computeState(context)
end

-- Fresh copy for consumers; nil until a valid arrival established a context.
function Store.getContext(self: Store): any?
    local context = self._context
    if context == nil then
        return nil
    end
    local arrived: { number } = {}
    local present: { number } = {}
    local missing: { number } = {}
    for _, userId in ipairs(context.arrivalOrder) do
        table.insert(arrived, userId)
        if context.present[userId] then
            table.insert(present, userId)
        end
    end
    for _, userId in ipairs(context.expected) do
        if not context.arrivedEver[userId] then
            table.insert(missing, userId)
        end
    end
    return {
        state = computeState(context),
        missionId = context.missionId,
        partyId = context.partyId,
        leaderUserId = context.leader,
        missionType = context.missionType,
        expectedUserIds = table.clone(context.expected),
        arrivedUserIds = arrived,
        presentUserIds = present,
        missingUserIds = missing,
    }
end

return ArrivalCore
