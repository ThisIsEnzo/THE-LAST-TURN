--!strict
-- Pure HUB launch state machine. All Roblox side effects (party lookup, connectivity, TeleportAsync, notifications,
-- timers, id generation) are injected through `Deps`, so the rules are deterministic and unit tested.
--
-- Lifecycle of a launch (one per party, keyed by party id; removed when finished, so the lock cannot leak):
--   PREPARING   snapshot taken, ids generated, membership revalidated
--   TELEPORTING TeleportAsync called; waiting for every member to leave (success) or fail/time out
--   then finished as COMPLETED (nobody failed), PARTIAL_FAILURE (some failed, some left) or FAILED (all failed).
--
-- Group teleports are NOT atomic: members can succeed or fail independently. Failures are retried to the SAME
-- destination (the TeleportOptions supplied by TeleportInitFailed), bounded per player. A player who leaves the
-- server during TELEPORTING is considered resolved; Roblox gives no way to tell a successful transfer from a
-- disconnect, and neither is retried.

export type PartySnapshot = { id: string, leader: number, members: { number } }

export type Config = {
    missionPlaceId: number,
    maxPartySize: number,
    missionType: string,
    maxRetriesPerPlayer: number,
    retryDelaySeconds: number,
    launchTimeoutSeconds: number,
}

export type LaunchInfo = {
    missionId: string,
    reservedServerId: string, -- server-only: never logged, replicated or put in the payload
    payload: any,
    memberUserIds: { number },
}

export type Deps = {
    getPartyForUser: (userId: number) -> PartySnapshot?,
    isConnected: (userId: number) -> boolean,
    getLifecycleState: (userId: number) -> string?,
    newGuid: () -> string,
    now: () -> number, -- epoch seconds
    buildPayload: (fields: any) -> any,
    teleport: (launch: LaunchInfo) -> (boolean, string?),
    retry: (userId: number, options: any, launch: LaunchInfo) -> (boolean, string?),
    notify: (userIds: { number }, status: string, extra: { [string]: any }?) -> (),
    schedule: (delaySeconds: number, callback: () -> ()) -> (() -> ()), -- returns a cancel function
}

export type RequestResult = { ok: boolean, status: string, code: string? }

export type LaunchSummary = {
    partyId: string,
    missionId: string,
    state: string,
    failedUserIds: { number },
    leftUserIds: { number },
}

type Launch = {
    partyId: string,
    leader: number,
    members: { number },
    state: string,
    info: LaunchInfo,
    pending: { [number]: boolean },
    attempts: { [number]: number },
    retryScheduled: { [number]: boolean },
    failed: { [number]: string },
    left: { [number]: boolean },
    cancels: { () -> () },
}

local LaunchCoordinator = {}

LaunchCoordinator.States = table.freeze({
    PREPARING = "PREPARING",
    TELEPORTING = "TELEPORTING",
    COMPLETED = "COMPLETED",
    PARTIAL_FAILURE = "PARTIAL_FAILURE",
    FAILED = "FAILED",
})
local States = LaunchCoordinator.States

-- Client-facing statuses (stable contract for the future UI).
LaunchCoordinator.Status = table.freeze({
    ACCEPTED = "accepted",
    ALREADY_IN_PROGRESS = "already_in_progress",
    NOT_LEADER = "not_leader",
    INVALID_PARTY = "invalid_party",
    PREPARATION_FAILED = "preparation_failed",
    TELEPORT_FAILED = "teleport_failed",
    RETRYING = "retrying",
    LAUNCH_INITIATED = "launch_initiated",
    PARTIAL_FAILURE = "partial_failure",
})
local Status = LaunchCoordinator.Status

local STATUS_FOR_CODE: { [string]: string } = {
    mission_not_configured = Status.PREPARATION_FAILED,
    unknown_player = Status.INVALID_PARTY,
    invalid_party = Status.INVALID_PARTY,
    inconsistent_party = Status.INVALID_PARTY,
    member_disconnected = Status.INVALID_PARTY,
    not_leader = Status.NOT_LEADER,
    already_in_progress = Status.ALREADY_IN_PROGRESS,
    invalid_lifecycle = Status.PREPARATION_FAILED,
    member_in_launch = Status.PREPARATION_FAILED,
    party_changed = Status.PREPARATION_FAILED,
    teleport_call_failed = Status.TELEPORT_FAILED,
}

function LaunchCoordinator.isValidPlaceId(value: any): boolean
    return type(value) == "number" and value == value and value > 0 and value % 1 == 0 and value ~= math.huge
end

type CoordinatorData = {
    _config: Config,
    _deps: Deps,
    _launches: { [string]: Launch },
    _launchByUser: { [number]: string },
    _listeners: { [number]: (summary: LaunchSummary) -> () },
    _nextListenerId: number,
}

local Coordinator = {}
Coordinator.__index = Coordinator

export type Coordinator = typeof(setmetatable({} :: CoordinatorData, Coordinator))

function LaunchCoordinator.new(config: Config, deps: Deps): Coordinator
    if type(config.maxRetriesPerPlayer) ~= "number" or config.maxRetriesPerPlayer < 0 or config.maxRetriesPerPlayer % 1 ~= 0 then
        error("LaunchCoordinator: maxRetriesPerPlayer must be an integer >= 0", 2)
    end
    for _, key in ipairs({ "retryDelaySeconds", "launchTimeoutSeconds" }) do
        local value = (config :: any)[key]
        if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
            error("LaunchCoordinator: " .. key .. " must be a finite number > 0", 2)
        end
    end
    return setmetatable({
        _config = config,
        _deps = deps,
        _launches = {},
        _launchByUser = {},
        _listeners = {},
        _nextListenerId = 0,
    }, Coordinator)
end

local function sortedKeys(map: { [number]: any }): { number }
    local list: { number } = {}
    for key in pairs(map) do
        table.insert(list, key)
    end
    table.sort(list)
    return list
end

local function reject(self: Coordinator, requesterId: number, code: string): RequestResult
    local status = STATUS_FOR_CODE[code] or Status.PREPARATION_FAILED
    self._deps.notify({ requesterId }, status, { code = code })
    return { ok = false, status = status, code = code }
end

local function releaseLaunch(self: Coordinator, launch: Launch)
    for _, cancel in ipairs(launch.cancels) do
        cancel()
    end
    table.clear(launch.cancels)
    if self._launches[launch.partyId] == launch then
        self._launches[launch.partyId] = nil
    end
    for _, userId in ipairs(launch.members) do
        if self._launchByUser[userId] == launch.partyId then
            self._launchByUser[userId] = nil
        end
    end
end

local function finalize(self: Coordinator, launch: Launch)
    if self._launches[launch.partyId] ~= launch then
        return
    end
    local failedCount, leftCount = 0, 0
    for _ in pairs(launch.failed) do
        failedCount += 1
    end
    for _ in pairs(launch.left) do
        leftCount += 1
    end
    local state = States.COMPLETED
    if failedCount > 0 then
        state = if leftCount > 0 then States.PARTIAL_FAILURE else States.FAILED
    end
    launch.state = state
    releaseLaunch(self, launch)
    local summary: LaunchSummary = {
        partyId = launch.partyId,
        missionId = launch.info.missionId,
        state = state,
        failedUserIds = sortedKeys(launch.failed),
        leftUserIds = sortedKeys(launch.left),
    }
    local listeners: { (LaunchSummary) -> () } = {}
    for _, listener in pairs(self._listeners) do
        table.insert(listeners, listener)
    end
    for _, listener in ipairs(listeners) do
        listener(summary)
    end
end

local function checkComplete(self: Coordinator, launch: Launch)
    if next(launch.pending) == nil then
        finalize(self, launch)
    end
end

local function markFailed(self: Coordinator, launch: Launch, userId: number, code: string)
    if not launch.pending[userId] then
        return
    end
    launch.pending[userId] = nil
    launch.failed[userId] = code
    self._deps.notify({ userId }, Status.TELEPORT_FAILED, { code = code })
    local others: { number } = {}
    for memberId in pairs(launch.pending) do
        table.insert(others, memberId)
    end
    if #others > 0 then
        table.sort(others)
        self._deps.notify(others, Status.PARTIAL_FAILURE, { failedUserId = userId })
    end
    checkComplete(self, launch)
end

local handleFailure: (Coordinator, Launch, number, any, string) -> ()

local function runRetry(self: Coordinator, launch: Launch, userId: number, options: any)
    launch.retryScheduled[userId] = nil
    if self._launches[launch.partyId] ~= launch or not launch.pending[userId] then
        return -- launch finished, or player already resolved
    end
    if not self._deps.isConnected(userId) then
        return -- disconnect is reported through onPlayerRemoved
    end
    local ok = self._deps.retry(userId, options, launch.info)
    if not ok then
        handleFailure(self, launch, userId, options, "retry_call_failed")
    end
end

-- Counts one failed attempt and either schedules a bounded retry (same destination) or fails the player.
handleFailure = function(self: Coordinator, launch: Launch, userId: number, options: any, code: string)
    if launch.retryScheduled[userId] then
        return -- a retry is already pending; ignore duplicate failure events
    end
    local attempts = (launch.attempts[userId] or 0) + 1
    launch.attempts[userId] = attempts
    if options ~= nil and attempts <= self._config.maxRetriesPerPlayer and self._deps.isConnected(userId) then
        launch.retryScheduled[userId] = true
        self._deps.notify({ userId }, Status.RETRYING, { attempt = attempts, maxAttempts = self._config.maxRetriesPerPlayer })
        table.insert(
            launch.cancels,
            self._deps.schedule(self._config.retryDelaySeconds, function()
                runRetry(self, launch, userId, options)
            end)
        )
        return
    end
    markFailed(self, launch, userId, if options == nil then "no_retry_options" else code)
end

local function validateMembers(self: Coordinator, requesterId: number, party: PartySnapshot): string?
    local count = #party.members
    if count < 1 or count > self._config.maxPartySize then
        return "invalid_party"
    end
    local seen: { [number]: boolean } = {}
    for _, userId in ipairs(party.members) do
        if seen[userId] then
            return "inconsistent_party"
        end
        seen[userId] = true
    end
    if not seen[party.leader] or not seen[requesterId] then
        return "inconsistent_party"
    end
    for _, userId in ipairs(party.members) do
        if not self._deps.isConnected(userId) then
            return "member_disconnected"
        end
        if self._deps.getLifecycleState(userId) ~= "ALIVE" then
            return "invalid_lifecycle"
        end
        if self._launchByUser[userId] ~= nil then
            return "member_in_launch"
        end
    end
    return nil
end

local function sameParty(a: PartySnapshot, b: PartySnapshot): boolean
    if a.id ~= b.id or a.leader ~= b.leader or #a.members ~= #b.members then
        return false
    end
    for index, userId in ipairs(a.members) do
        if b.members[index] ~= userId then
            return false
        end
    end
    return true
end

-- Requests a launch for the requester's party. The requester must lead it. Always returns a RequestResult and
-- always tells the requester (or the whole party) what happened through `notify`.
function Coordinator.requestLaunch(self: Coordinator, requesterId: number): RequestResult
    local deps = self._deps
    if not LaunchCoordinator.isValidPlaceId(self._config.missionPlaceId) then
        return reject(self, requesterId, "mission_not_configured")
    end
    if not deps.isConnected(requesterId) then
        return reject(self, requesterId, "unknown_player")
    end
    local party = deps.getPartyForUser(requesterId)
    if party == nil then
        return reject(self, requesterId, "invalid_party")
    end
    if party.leader ~= requesterId then
        return reject(self, requesterId, "not_leader")
    end
    if self._launches[party.id] ~= nil then
        return reject(self, requesterId, "already_in_progress")
    end
    local problem = validateMembers(self, requesterId, party)
    if problem then
        return reject(self, requesterId, problem)
    end

    -- Stable snapshot; the lock is taken before anything else can interleave.
    local members = table.clone(party.members)
    local launch: Launch = {
        partyId = party.id,
        leader = party.leader,
        members = members,
        state = States.PREPARING,
        info = { missionId = "", reservedServerId = "", payload = nil, memberUserIds = members },
        pending = {},
        attempts = {},
        retryScheduled = {},
        failed = {},
        left = {},
        cancels = {},
    }
    self._launches[party.id] = launch
    for _, userId in ipairs(members) do
        self._launchByUser[userId] = party.id
    end

    local missionId = deps.newGuid()
    local reservedServerId = deps.newGuid() -- generated exactly once per launch; retries reuse it
    launch.info = {
        missionId = missionId,
        reservedServerId = reservedServerId,
        payload = deps.buildPayload({
            missionId = missionId,
            partyId = party.id,
            leaderUserId = party.leader,
            memberUserIds = members,
            missionType = self._config.missionType,
            createdAt = math.floor(deps.now()),
        }),
        memberUserIds = members,
    }

    -- Revalidate immediately before teleporting: never send an outdated member list.
    local current = deps.getPartyForUser(requesterId)
    local stale = current == nil or not sameParty(party, current)
    if not stale then
        for _, userId in ipairs(members) do
            if not deps.isConnected(userId) or deps.getLifecycleState(userId) ~= "ALIVE" then
                stale = true
                break
            end
        end
    end
    if stale then
        releaseLaunch(self, launch)
        return reject(self, requesterId, "party_changed")
    end

    launch.state = States.TELEPORTING
    for _, userId in ipairs(members) do
        launch.pending[userId] = true
    end
    table.insert(
        launch.cancels,
        deps.schedule(self._config.launchTimeoutSeconds, function()
            if self._launches[launch.partyId] ~= launch then
                return
            end
            for _, userId in ipairs(sortedKeys(launch.pending)) do
                markFailed(self, launch, userId, "timeout")
            end
            finalize(self, launch) -- no-op if markFailed already finished it
        end)
    )
    deps.notify(members, Status.ACCEPTED, nil)

    local ok = deps.teleport(launch.info)
    if self._launches[launch.partyId] ~= launch then
        -- Resolved while TeleportAsync was yielding (events can arrive before it returns).
        return { ok = true, status = Status.LAUNCH_INITIATED, code = nil }
    end
    if not ok then
        for _, userId in ipairs(sortedKeys(launch.pending)) do
            launch.pending[userId] = nil
            launch.failed[userId] = "teleport_call_failed"
        end
        deps.notify(members, Status.TELEPORT_FAILED, { code = "teleport_call_failed" })
        finalize(self, launch)
        return { ok = false, status = Status.TELEPORT_FAILED, code = "teleport_call_failed" }
    end
    local stillPending = sortedKeys(launch.pending)
    if #stillPending > 0 then
        deps.notify(stillPending, Status.LAUNCH_INITIATED, nil)
    end
    return { ok = true, status = Status.LAUNCH_INITIATED, code = nil }
end

-- Feed TeleportService.TeleportInitFailed here. `reservedServerId` and `options` come from the event's
-- TeleportOptions. Failures that do not belong to the player's active launch destination are ignored.
function Coordinator.onTeleportInitFailed(self: Coordinator, userId: number, info: { reservedServerId: string?, options: any, code: string? }): boolean
    local partyId = self._launchByUser[userId]
    local launch = partyId and self._launches[partyId]
    if launch == nil or launch.state ~= States.TELEPORTING or not launch.pending[userId] then
        return false
    end
    if info.reservedServerId ~= launch.info.reservedServerId then
        return false -- different destination: not ours, never retry it
    end
    handleFailure(self, launch, userId, info.options, info.code or "teleport_init_failed")
    return true
end

-- Feed PlayerRemoving here: leaving during TELEPORTING resolves the player (transferred or disconnected).
function Coordinator.onPlayerRemoved(self: Coordinator, userId: number)
    local partyId = self._launchByUser[userId]
    local launch = partyId and self._launches[partyId]
    if launch == nil then
        return
    end
    self._launchByUser[userId] = nil
    if launch.pending[userId] then
        launch.pending[userId] = nil
        launch.left[userId] = true
        checkComplete(self, launch)
    end
end

function Coordinator.getLaunchState(self: Coordinator, partyId: string): string?
    local launch = self._launches[partyId]
    return launch and launch.state or nil
end

function Coordinator.getActiveLaunchCount(self: Coordinator): number
    local n = 0
    for _ in pairs(self._launches) do
        n += 1
    end
    return n
end

function Coordinator.onLaunchFinished(self: Coordinator, listener: (summary: LaunchSummary) -> ()): () -> ()
    self._nextListenerId += 1
    local id = self._nextListenerId
    self._listeners[id] = listener
    return function()
        self._listeners[id] = nil
    end
end

-- Cancels timers and drops all launch state (service shutdown).
function Coordinator.shutdown(self: Coordinator)
    for _, launch in pairs(table.clone(self._launches)) do
        releaseLaunch(self, launch)
    end
    table.clear(self._listeners)
end

return LaunchCoordinator
