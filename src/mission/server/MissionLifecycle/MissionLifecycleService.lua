--!strict
-- MISSION lifecycle owner (server-authoritative). Wraps the pure MissionLifecycleCore with Roblox integration:
-- observes MissionContextService, initializes mission-level systems exactly once, handles termination, returns
-- players to the HUB with bounded retries, and cleans up deterministically. It starts no gameplay.
--
-- Clients have no way to influence it: there are no remotes. Other server systems end the mission through
-- `endMission(outcome, reason)`. Every delayed callback checks a generation token, so nothing can touch a closed
-- or restarted lifecycle.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")

local MissionLifecycleCore = require(ServerStorage.ServerShared.MissionLifecycle.MissionLifecycleCore)
local MissionPlaces = require(ServerStorage.ServerShared.MissionTeleport.MissionPlaces)
local PlayerStateService = require(ServerStorage.ServerShared.Player.PlayerStateService)
local MissionContextService = require(script.Parent.Parent.MissionContext.MissionContextService)
local Config = require(script.Parent.MissionLifecycleConfig)

local States = MissionLifecycleCore.States
local Outcomes = MissionLifecycleCore.Outcomes

export type Result = MissionLifecycleCore.Result
export type StateListener = (state: string) -> ()
-- A mission-level system (future TTL tasks). `start` runs during INITIALIZING before the mission becomes ACTIVE;
-- `stop` runs on termination/shutdown for every system whose start callback was entered (including a failed start).
export type MissionSystem = { name: string, start: (session: any) -> (), stop: (() -> ())? }

type ReturnState = {
    pending: { [number]: boolean },
    attempts: { [number]: number },
    retryScheduled: { [number]: boolean },
    attemptTokens: { [number]: string },
    nextAttemptId: number,
    finished: boolean,
}

local MissionLifecycleService = {}

local initialized = false
local generation = 0
local core: MissionLifecycleCore.Store? = nil
local connections: { RBXScriptConnection } = {}
local contextUnsubscribe: (() -> ())? = nil
local listeners: { [number]: StateListener } = {}
local nextListenerId = 0
local systems: { MissionSystem } = {}
local startedSystems: { MissionSystem } = {}
local startingSystem = false
local stopRequested = false
local returnState: ReturnState? = nil
local boundToClose = false

local function isValidPlaceId(value: any): boolean
    return type(value) == "number" and value == value and value > 0 and value % 1 == 0 and value ~= math.huge
end

local function publish(result: Result)
    if not result.changed then
        return
    end
    local copy: { StateListener } = {}
    for _, listener in pairs(listeners) do
        table.insert(copy, listener)
    end
    for _, listener in ipairs(copy) do
        local ok, err = pcall(listener, result.to)
        if not ok then
            warn("[THE LAST TURN][MissionLifecycle] Listener error: " .. tostring(err))
        end
    end
end

-- Connected mission participants: expected members that are still in the server (or, before a session exists,
-- players that already passed arrival validation).
local function connectedParticipants(): { number }
    local active = core
    local candidates: { number } = {}
    local session = active and active:getSession()
    if session then
        candidates = session.expectedUserIds
    else
        local context = MissionContextService.getContext()
        candidates = context and context.presentUserIds or {}
    end
    local list: { number } = {}
    for _, userId in ipairs(candidates) do
        if Players:GetPlayerByUserId(userId) ~= nil then
            table.insert(list, userId)
        end
    end
    return list
end

-- Read-only snapshots ---------------------------------------------------------------------------------------------

function MissionLifecycleService.getState(): string
    local active = core
    return if active then active:getState() else States.BOOTSTRAPPING
end

function MissionLifecycleService.isActive(): boolean
    return MissionLifecycleService.getState() == States.ACTIVE
end

-- Fresh copy (never internal state) or nil before a valid context was accepted.
function MissionLifecycleService.getSession(): any?
    local active = core
    local session = active and active:getSession()
    if session == nil then
        return nil
    end
    session.participantUserIds = connectedParticipants()
    return session
end

function MissionLifecycleService.getOutcome(): (string?, string?)
    local active = core
    if active == nil then
        return nil, nil
    end
    return active:getOutcome()
end

function MissionLifecycleService.onStateChanged(listener: StateListener): () -> ()
    nextListenerId += 1
    local id = nextListenerId
    listeners[id] = listener
    return function()
        listeners[id] = nil
    end
end

-- Registers a mission-level system started during INITIALIZING, before the mission becomes ACTIVE.
-- Only possible before INITIALIZING; returns false otherwise (or for duplicate names).
function MissionLifecycleService.registerSystem(system: MissionSystem): boolean
    if
        type(system) ~= "table"
        or type(system.name) ~= "string"
        or #system.name < 1
        or #system.name > 64
        or string.match(system.name, "^[%w_%-]+$") == nil
        or type(system.start) ~= "function"
        or (system.stop ~= nil and type(system.stop) ~= "function")
    then
        return false
    end
    local state = MissionLifecycleService.getState()
    if state ~= States.BOOTSTRAPPING and state ~= States.WAITING_FOR_PLAYERS then
        return false
    end
    for _, existing in ipairs(systems) do
        if existing.name == system.name then
            return false
        end
    end
    table.insert(systems, system)
    return true
end

-- Cleanup ---------------------------------------------------------------------------------------------------------

local function stopSystems()
    -- endMission() may be called synchronously from system.start(). Do not stop a system
    -- while its start callback is still executing; startSystems() drains the stack first.
    if startingSystem then
        stopRequested = true
        return
    end
    stopRequested = false
    for index = #startedSystems, 1, -1 do
        local system = startedSystems[index]
        startedSystems[index] = nil
        if system.stop then
            local ok, err = pcall(system.stop)
            if not ok then
                warn(string.format("[THE LAST TURN][MissionLifecycle] System '%s' failed to stop: %s", system.name, tostring(err)))
            end
        end
    end
end

-- Idempotent final cleanup: invalidates delayed callbacks, drops connections and subscriptions.
local function cleanup()
    generation += 1
    for index, connection in ipairs(connections) do
        connection:Disconnect()
        connections[index] = nil
    end
    local unsubscribe = contextUnsubscribe
    contextUnsubscribe = nil
    if unsubscribe then
        unsubscribe()
    end
    returnState = nil
    table.clear(systems)
    stopSystems()
    initialized = false
end

local function finishShutdown()
    local active = core
    if active == nil then
        return
    end
    -- Publish the terminal intent before invoking system stop callbacks. A stopping system
    -- must never observe the mission as ACTIVE while the server is shutting down.
    publish(active:beginShutdown())
    stopSystems()
    cleanup()
    publish(active:close())
end

-- Return to HUB ---------------------------------------------------------------------------------------------------

local checkReturnComplete: () -> ()
local handleReturnFailure: (userId: number, options: any) -> ()

local function finishReturn(why: string)
    local state = returnState
    if state == nil or state.finished then
        return
    end
    state.finished = true
    local unresolved = 0
    for _ in pairs(state.pending) do
        unresolved += 1
    end
    if unresolved > 0 then
        warn(string.format("[THE LAST TURN][MissionLifecycle] Return ended (%s) with %d unresolved player(s).", why, unresolved))
    end
    finishShutdown()
end

checkReturnComplete = function()
    local state = returnState
    if state ~= nil and next(state.pending) == nil then
        finishReturn("complete")
    end
end

local function newReturnAttemptOptions(state: ReturnState, userIds: { number }): TeleportOptions
    state.nextAttemptId += 1
    local token = tostring(generation) .. ":" .. tostring(state.nextAttemptId)
    for _, userId in ipairs(userIds) do
        state.attemptTokens[userId] = token
    end
    local options = Instance.new("TeleportOptions")
    options:SetTeleportData({ _ttl06ReturnAttemptId = token })
    return options
end

local function getReturnAttemptToken(options: TeleportOptions?): string?
    if options == nil then
        return nil
    end
    local ok, data = pcall(function()
        return options:GetTeleportData()
    end)
    if not ok or type(data) ~= "table" or type(data._ttl06ReturnAttemptId) ~= "string" then
        return nil
    end
    return data._ttl06ReturnAttemptId
end

local function teleportToHub(players: { Player }, options: TeleportOptions): boolean
    local ok, err = pcall(function()
        TeleportService:TeleportAsync(MissionPlaces.HubPlaceId, players, options)
    end)
    if not ok then
        warn("[THE LAST TURN][MissionLifecycle] Return TeleportAsync failed: " .. tostring(err))
    end
    return ok
end

handleReturnFailure = function(userId: number, options: TeleportOptions?)
    local state = returnState
    if state == nil or state.finished or not state.pending[userId] or state.retryScheduled[userId] then
        return
    end
    -- TeleportInitFailed does not expose a numeric attempt id. Correlate it using the
    -- per-attempt marker echoed in the event's TeleportOptions; ignore late failures.
    local eventToken = getReturnAttemptToken(options)
    if eventToken == nil or eventToken ~= state.attemptTokens[userId] then
        return
    end
    local attempts = (state.attempts[userId] or 0) + 1
    state.attempts[userId] = attempts
    if attempts <= Config.returnMaxRetriesPerPlayer and Players:GetPlayerByUserId(userId) ~= nil then
        state.retryScheduled[userId] = true
        local scheduledGeneration = generation
        task.delay(Config.returnRetryDelaySeconds, function()
            local current = returnState
            if scheduledGeneration ~= generation or current ~= state or state.finished then
                return
            end
            state.retryScheduled[userId] = nil
            local player = Players:GetPlayerByUserId(userId)
            if player == nil or not state.pending[userId] then
                return -- left the server: resolved by PlayerRemoving; never retry disconnected players
            end
            local retryOptions = newReturnAttemptOptions(state, { userId })
            if not teleportToHub({ player }, retryOptions) then
                handleReturnFailure(userId, retryOptions)
            end
        end)
        return
    end
    warn(string.format("[THE LAST TURN][MissionLifecycle] Return to HUB failed permanently for %d after %d attempt(s); player stays in this server.", userId, attempts))
    state.pending[userId] = nil
    checkReturnComplete()
end

local function startReturn(userIds: { number })
    local scheduledGeneration = generation
    local state: ReturnState = {
        pending = {},
        attempts = {},
        retryScheduled = {},
        attemptTokens = {},
        nextAttemptId = 0,
        finished = false,
    }
    returnState = state

    local players: { Player } = {}
    for _, userId in ipairs(userIds) do
        local player = Players:GetPlayerByUserId(userId)
        if player then
            state.pending[userId] = true
            table.insert(players, player)
        end
    end
    if #players == 0 then
        finishReturn("no_participants")
        return
    end
    if not isValidPlaceId(MissionPlaces.HubPlaceId) then
        warn("[THE LAST TURN][MissionLifecycle] HubPlaceId is not configured; players cannot be returned and stay in this server.")
        table.clear(state.pending)
        finishReturn("hub_not_configured")
        return
    end

    table.insert(
        connections,
        TeleportService.TeleportInitFailed:Connect(
            function(player: Player, _result: Enum.TeleportResult, _message: string, targetPlaceId: number, options: TeleportOptions?)
                if scheduledGeneration == generation and targetPlaceId == MissionPlaces.HubPlaceId then
                    handleReturnFailure(player.UserId, options)
                end
            end
        )
    )
    task.delay(Config.returnTimeoutSeconds, function()
        if scheduledGeneration == generation and returnState == state then
            finishReturn("timeout")
        end
    end)

    local initialOptions = newReturnAttemptOptions(state, userIds)
    if not teleportToHub(players, initialOptions) then
        for _, userId in ipairs(userIds) do
            handleReturnFailure(userId, initialOptions) -- counts one attempt per player; bounded retries follow
        end
    end
end

-- Termination -----------------------------------------------------------------------------------------------------

local function beginTermination()
    local active = core
    if active == nil or active:getState() ~= States.ENDING then
        return
    end
    local terminationGeneration = generation
    stopSystems() -- progression is frozen (state is ENDING) before anyone is returned
    if core ~= active or generation ~= terminationGeneration or active:getState() ~= States.ENDING then
        return
    end

    local participants = connectedParticipants()
    local returnableParticipants: { number } = {}
    for _, userId in ipairs(participants) do
        if core ~= active or generation ~= terminationGeneration or active:getState() ~= States.ENDING then
            return -- a synchronous listener may have shut the lifecycle down
        end
        local player = Players:GetPlayerByUserId(userId)
        if player then
            local result = PlayerStateService.transition(player, "RETURNING", "mission_ended")
            if core ~= active or generation ~= terminationGeneration or active:getState() ~= States.ENDING then
                return -- PlayerStateService listeners may synchronously shut the lifecycle down
            end
            if result.ok then
                table.insert(returnableParticipants, userId)
            else
                -- Fail closed: never teleport a player unless the authoritative player state
                -- confirms RETURNING. They remain in this server for diagnosis/recovery.
                warn(string.format("[THE LAST TURN][MissionLifecycle] Keeping %d in this server; RETURNING transition rejected (%s).", userId, tostring(result.rejection)))
            end
        end
    end
    local returning = active:beginReturning()
    publish(returning)
    if
        not returning.ok
        or core ~= active
        or generation ~= terminationGeneration
        or active:getState() ~= States.RETURNING
    then
        return
    end
    startReturn(returnableParticipants)
end

-- Ends the mission. Server systems only. Idempotent: the first valid call wins and later calls report the
-- original outcome/reason without starting a second termination.
function MissionLifecycleService.endMission(outcome: string, reason: string): Result
    local active = core
    if active == nil then
        return {
            ok = false,
            changed = false,
            from = States.BOOTSTRAPPING,
            to = States.BOOTSTRAPPING,
            rejection = "not_initialized",
            detail = nil,
            outcome = nil,
            reason = nil,
        }
    end
    local result = active:requestEnd(outcome, reason)
    if result.ok and result.changed then
        publish(result)
        -- State listeners are synchronous and may shut the service down. Do not continue
        -- into player transitions or teleports after a reentrant shutdown.
        if core == active and active:getState() == States.ENDING then
            beginTermination()
        end
    end
    return result
end

-- Startup ---------------------------------------------------------------------------------------------------------

local function startSystems(session: any): boolean
    local active = core
    for _, system in ipairs(systems) do
        if active == nil or active:getState() ~= States.INITIALIZING then
            stopSystems()
            return false
        end

        -- Register before invoking start(): it may synchronously terminate the mission or throw
        -- after partially allocating resources. stopSystems() is deferred until start() returns.
        table.insert(startedSystems, system)
        startingSystem = true
        local ok, err = pcall(system.start, session)
        startingSystem = false

        if stopRequested or active:getState() ~= States.INITIALIZING then
            stopSystems()
            return false
        end
        if not ok then
            warn(string.format("[THE LAST TURN][MissionLifecycle] System '%s' failed to start: %s", system.name, tostring(err)))
            return false -- the failing system remains registered for best-effort stop during termination
        end
    end
    return true
end

local function evaluateContext()
    local active = core
    if not initialized or active == nil or active:getState() ~= States.WAITING_FOR_PLAYERS then
        return
    end
    if MissionContextService.getState() ~= "READY" then
        return -- NO_CONTEXT / WAITING / INCOMPLETE never start a mission
    end
    local submitted = active:submitContext(MissionContextService.getContext(), Config.expectedMissionType, os.time())
    publish(submitted)
    if active:getState() ~= States.INITIALIZING then
        return -- a synchronous state listener may have aborted or shut down the lifecycle
    end
    if not submitted.ok then
        if submitted.rejection == "invalid_context" then
            warn("[THE LAST TURN][MissionLifecycle] Rejected mission context: " .. tostring(submitted.detail))
            MissionLifecycleService.endMission(Outcomes.ABORTED, "invalid_context")
        end
        return
    end

    local session = MissionLifecycleService.getSession()
    if not startSystems(session) then
        MissionLifecycleService.endMission(Outcomes.ABORTED, "initialization_failed")
        return
    end
    if active:getState() ~= States.INITIALIZING then
        stopSystems() -- the mission ended while systems were starting
        return
    end
    publish(active:markActive())
end

-- Idempotent. Call in the MISSION bootstrap after MissionContextService.init().
function MissionLifecycleService.init()
    if initialized then
        return
    end
    local configOk, configProblem = MissionLifecycleCore.validateConfig(Config)
    if not configOk then
        error("MissionLifecycleService: invalid config: " .. tostring(configProblem))
    end

    local active = MissionLifecycleCore.new()
    core = active
    initialized = true
    generation += 1
    local startGeneration = generation
    table.clear(startedSystems)
    startingSystem = false
    stopRequested = false
    returnState = nil

    if not boundToClose then
        boundToClose = true
        game:BindToClose(function()
            MissionLifecycleService.shutdown()
        end)
    end

    publish(active:startWaiting())
    contextUnsubscribe = MissionContextService.onStateChanged(function(_state: string)
        evaluateContext()
    end)
    table.insert(
        connections,
        Players.PlayerRemoving:Connect(function(player: Player)
            local state = returnState
            if state ~= nil and state.pending[player.UserId] then
                state.pending[player.UserId] = nil -- transferred or disconnected: resolved, never retried
                checkReturnComplete()
            end
        end)
    )
    task.delay(Config.contextWaitTimeoutSeconds, function()
        if startGeneration == generation and active:getState() == States.WAITING_FOR_PLAYERS then
            MissionLifecycleService.endMission(Outcomes.ABORTED, "context_timeout")
        end
    end)

    evaluateContext() -- the context may already be READY (e.g. a solo party processed before we subscribed)
end

-- Server closing (BindToClose) or explicit teardown. Idempotent; records ABORTED/"server_shutdown" if the mission
-- had not been terminated yet.
function MissionLifecycleService.shutdown()
    if core == nil or core:getState() == States.CLOSED then
        return
    end
    finishShutdown()
end

return MissionLifecycleService
