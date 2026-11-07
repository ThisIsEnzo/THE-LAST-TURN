--!strict
-- Pure mission lifecycle rules (no Roblox services, timers or globals). MissionLifecycleService (MISSION) drives it.
--
--   BOOTSTRAPPING -> WAITING_FOR_PLAYERS -> INITIALIZING -> ACTIVE -> ENDING -> RETURNING -> SHUTTING_DOWN -> CLOSED
--
-- Extra edges: WAITING_FOR_PLAYERS and INITIALIZING may go straight to ENDING (abort); ENDING may skip RETURNING
-- only through SHUTTING_DOWN; every non-terminal state may go to SHUTTING_DOWN (server closing). CLOSED is terminal.
-- The first termination (outcome + reason) wins; later calls are idempotent and report the original result.
-- This is mission-level state only; it is unrelated to individual player lifecycle (PlayerStateService).

export type Result = {
    ok: boolean,
    changed: boolean,
    from: string,
    to: string,
    rejection: string?, -- "invalid_transition" | "already_initialized" | "invalid_context" | "invalid_outcome" | "invalid_reason"
    detail: string?, -- specific context-validation code
    outcome: string?, -- the recorded termination outcome, when one exists
    reason: string?,
}

local MissionLifecycleCore = {}

local States = table.freeze({
    BOOTSTRAPPING = "BOOTSTRAPPING",
    WAITING_FOR_PLAYERS = "WAITING_FOR_PLAYERS",
    INITIALIZING = "INITIALIZING",
    ACTIVE = "ACTIVE",
    ENDING = "ENDING",
    RETURNING = "RETURNING",
    SHUTTING_DOWN = "SHUTTING_DOWN",
    CLOSED = "CLOSED",
})
MissionLifecycleCore.States = States

MissionLifecycleCore.Outcomes = table.freeze({
    COMPLETED = "COMPLETED", -- mission succeeded
    FAILED = "FAILED", -- mission lost
    ABORTED = "ABORTED", -- server-side abort (initialization failure, timeout, shutdown)
})

MissionLifecycleCore.MaxMembers = 8

local Transitions: { [string]: { [string]: boolean } } = table.freeze({
    BOOTSTRAPPING = table.freeze({ WAITING_FOR_PLAYERS = true, SHUTTING_DOWN = true }),
    WAITING_FOR_PLAYERS = table.freeze({ INITIALIZING = true, ENDING = true, SHUTTING_DOWN = true }),
    INITIALIZING = table.freeze({ ACTIVE = true, ENDING = true, SHUTTING_DOWN = true }),
    ACTIVE = table.freeze({ ENDING = true, SHUTTING_DOWN = true }),
    ENDING = table.freeze({ RETURNING = true, SHUTTING_DOWN = true }),
    RETURNING = table.freeze({ SHUTTING_DOWN = true }),
    SHUTTING_DOWN = table.freeze({ CLOSED = true }),
    CLOSED = table.freeze({}),
})

function MissionLifecycleCore.canTransition(from: string, to: string): boolean
    local targets = Transitions[from]
    return targets ~= nil and targets[to] == true
end

local MAX_USER_ID = 9007199254740991

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value == value and value % 1 == 0 and value >= min and value <= max
end

local function isToken(value: any, maxLength: number, pattern: string): boolean
    return type(value) == "string" and #value >= 1 and #value <= maxLength and string.match(value, pattern) ~= nil
end

-- Validates the MissionContextService context snapshot. Returns (true, nil) or (false, code).
function MissionLifecycleCore.validateContext(context: any, expectedMissionType: string): (boolean, string?)
    if type(context) ~= "table" then
        return false, "context_missing"
    end
    if context.state ~= "READY" then
        return false, "context_not_ready"
    end
    if not isToken(context.missionId, 64, "^[%w%-]+$") then
        return false, "invalid_mission_id"
    end
    if not isToken(context.partyId, 32, "^[%w_%-]+$") then
        return false, "invalid_party_id"
    end
    if context.missionType ~= expectedMissionType then
        return false, "unexpected_mission_type"
    end

    local expected = context.expectedUserIds
    if type(expected) ~= "table" then
        return false, "invalid_members"
    end
    local expectedSet: { [number]: boolean } = {}
    local count = 0
    for key, userId in pairs(expected) do
        if type(key) ~= "number" or not isInteger(userId, 1, MAX_USER_ID) or expectedSet[userId] then
            return false, "invalid_members"
        end
        expectedSet[userId] = true
        count += 1
    end
    if count < 1 or count > MissionLifecycleCore.MaxMembers or #expected ~= count then
        return false, "invalid_members"
    end
    if not isInteger(context.leaderUserId, 1, MAX_USER_ID) or not expectedSet[context.leaderUserId] then
        return false, "invalid_leader"
    end

    if type(context.missingUserIds) ~= "table" or next(context.missingUserIds) ~= nil then
        return false, "incomplete_arrivals"
    end
    local arrived = context.arrivedUserIds
    if type(arrived) ~= "table" then
        return false, "incomplete_arrivals"
    end
    local arrivedSet: { [number]: boolean } = {}
    local arrivedCount = 0
    for _, userId in pairs(arrived) do
        if not expectedSet[userId] or arrivedSet[userId] then
            return false, "incomplete_arrivals"
        end
        arrivedSet[userId] = true
        arrivedCount += 1
    end
    if arrivedCount ~= count then
        return false, "incomplete_arrivals"
    end
    return true, nil
end

-- Startup/return settings must be present and sane. Returns (true, nil) or (false, reason).
function MissionLifecycleCore.validateConfig(config: any): (boolean, string?)
    if type(config) ~= "table" then
        return false, "config_missing"
    end
    if not isToken(config.expectedMissionType, 32, "^[%w_%-]+$") then
        return false, "invalid expectedMissionType"
    end
    for _, key in ipairs({ "contextWaitTimeoutSeconds", "returnRetryDelaySeconds", "returnTimeoutSeconds" }) do
        local value = config[key]
        if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
            return false, "invalid " .. key
        end
    end
    if not isInteger(config.returnMaxRetriesPerPlayer, 0, 10) then
        return false, "invalid returnMaxRetriesPerPlayer"
    end
    return true, nil
end

local function isValidOutcome(value: any): boolean
    return type(value) == "string" and (MissionLifecycleCore.Outcomes :: { [string]: string })[value] ~= nil
end

type Session = {
    missionId: string,
    partyId: string,
    leader: number,
    missionType: string,
    expected: { number },
    startedAt: number,
}

type StoreData = {
    _state: string,
    _session: Session?,
    _initialized: boolean,
    _outcome: string?,
    _reason: string?,
}

local Store = {}
Store.__index = Store

export type Store = typeof(setmetatable({} :: StoreData, Store))

function MissionLifecycleCore.new(): Store
    return setmetatable({ _state = States.BOOTSTRAPPING, _session = nil, _initialized = false, _outcome = nil, _reason = nil }, Store)
end

local function result(self: Store, ok: boolean, changed: boolean, from: string, rejection: string?, detail: string?): Result
    return {
        ok = ok,
        changed = changed,
        from = from,
        to = self._state,
        rejection = rejection,
        detail = detail,
        outcome = self._outcome,
        reason = self._reason,
    }
end

-- Applies an edge if it is in the graph; same-state is an idempotent no-op.
local function move(self: Store, to: string): Result
    local from = self._state
    if from == to then
        return result(self, true, false, from, nil, nil)
    end
    if not MissionLifecycleCore.canTransition(from, to) then
        return result(self, false, false, from, "invalid_transition", nil)
    end
    self._state = to
    return result(self, true, true, from, nil, nil)
end

function Store.getState(self: Store): string
    return self._state
end

function Store.startWaiting(self: Store): Result
    return move(self, States.WAITING_FOR_PLAYERS)
end

-- Validates the arrival context and, only if valid and not yet initialized, creates the session and enters
-- INITIALIZING. Calling it again (duplicate readiness) never re-initializes.
function Store.submitContext(self: Store, context: any, expectedMissionType: string, startedAt: number): Result
    local from = self._state
    if self._session ~= nil then
        return result(self, false, false, from, "already_initialized", nil)
    end
    if from ~= States.WAITING_FOR_PLAYERS then
        return result(self, false, false, from, "invalid_transition", nil)
    end
    local ok, code = MissionLifecycleCore.validateContext(context, expectedMissionType)
    if not ok then
        return result(self, false, false, from, "invalid_context", code)
    end
    self._session = {
        missionId = context.missionId,
        partyId = context.partyId,
        leader = context.leaderUserId,
        missionType = context.missionType,
        expected = table.clone(context.expectedUserIds),
        startedAt = startedAt,
    }
    return move(self, States.INITIALIZING)
end

-- INITIALIZING -> ACTIVE after the service initialized the session successfully. Impossible without a session.
function Store.markActive(self: Store): Result
    if self._state == States.ACTIVE then
        return result(self, true, false, self._state, nil, nil)
    end
    if self._session == nil or self._state ~= States.INITIALIZING then
        return result(self, false, false, self._state, "invalid_transition", nil)
    end
    self._initialized = true
    return move(self, States.ACTIVE)
end

-- Requests mission termination. The first valid request wins and records outcome + reason; afterwards the call is
-- an idempotent no-op that reports the ORIGINAL outcome. Accepted from WAITING_FOR_PLAYERS, INITIALIZING and ACTIVE.
function Store.requestEnd(self: Store, outcome: any, reason: any): Result
    local from = self._state
    if not isValidOutcome(outcome) then
        return result(self, false, false, from, "invalid_outcome", nil)
    end
    if not isToken(reason, 48, "^[%w_%-]+$") then
        return result(self, false, false, from, "invalid_reason", nil)
    end
    if self._outcome ~= nil then
        return result(self, true, false, from, nil, nil) -- already terminating: keep the original result
    end
    if from == States.BOOTSTRAPPING then
        return result(self, false, false, from, "invalid_transition", nil)
    end
    if not MissionLifecycleCore.canTransition(from, States.ENDING) then
        return result(self, false, false, from, "invalid_transition", nil)
    end
    self._outcome = outcome
    self._reason = reason
    return move(self, States.ENDING)
end

function Store.beginReturning(self: Store): Result
    return move(self, States.RETURNING)
end

-- Server closing: allowed from any non-terminal state. Records ABORTED if no outcome exists yet.
function Store.beginShutdown(self: Store): Result
    if self._outcome == nil and self._state ~= States.CLOSED and self._state ~= States.SHUTTING_DOWN then
        self._outcome = MissionLifecycleCore.Outcomes.ABORTED
        self._reason = "server_shutdown"
    end
    return move(self, States.SHUTTING_DOWN)
end

function Store.close(self: Store): Result
    return move(self, States.CLOSED)
end

-- Read-only copy; nil before a context was accepted. Never exposes internal tables.
function Store.getSession(self: Store): any?
    local session = self._session
    if session == nil then
        return nil
    end
    return {
        state = self._state,
        missionId = session.missionId,
        partyId = session.partyId,
        leaderUserId = session.leader,
        missionType = session.missionType,
        expectedUserIds = table.clone(session.expected),
        startedAt = session.startedAt,
        outcome = self._outcome,
        reason = self._reason,
    }
end

function Store.getOutcome(self: Store): (string?, string?)
    return self._outcome, self._reason
end

-- Consistency check used by tests.
function Store.validateInvariants(self: Store): (boolean, string?)
    local state = self._state
    if States[state] == nil then
        return false, "unknown state"
    end
    local session = self._session
    local early = state == States.BOOTSTRAPPING or state == States.WAITING_FOR_PLAYERS
    if early and session ~= nil then
        return false, "session before initialization"
    end
    if (state == States.INITIALIZING or state == States.ACTIVE) and session == nil then
        return false, "missing session"
    end
    if state == States.ACTIVE and not self._initialized then
        return false, "ACTIVE without initialization"
    end
    if self._initialized and session == nil then
        return false, "initialized without session"
    end
    local terminating = state == States.ENDING or state == States.RETURNING or state == States.SHUTTING_DOWN or state == States.CLOSED
    if terminating and (self._outcome == nil or self._reason == nil) then
        return false, "terminating without outcome"
    end
    if (state == States.ACTIVE or state == States.INITIALIZING or early) and self._outcome ~= nil then
        return false, "outcome while running"
    end
    if session then
        local set: { [number]: boolean } = {}
        for _, userId in ipairs(session.expected) do
            if set[userId] then
                return false, "duplicate expected member"
            end
            set[userId] = true
        end
        if #session.expected < 1 or #session.expected > MissionLifecycleCore.MaxMembers or not set[session.leader] then
            return false, "invalid session members"
        end
    end
    return true, nil
end

return MissionLifecycleCore
