--!strict
-- MISSION launch context (server-only). Validates the teleport payload of every arriving player, coordinates
-- arrivals and exposes a server-owned mission context + readiness state for later gameplay systems.
-- It starts no gameplay. Invalid or conflicting arrivals fail closed: they are never added to a context and, outside
-- Studio, are removed from the server. Teleport data alone is not authorization; the environment is checked too
-- (expected place, reserved server). Real teleport data only exists in a published experience, never in Studio.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local ArrivalCore = require(ServerStorage.ServerShared.MissionTeleport.ArrivalCore)
local MissionPlaces = require(ServerStorage.ServerShared.MissionTeleport.MissionPlaces)
local TeleportPayload = require(ServerStorage.ServerShared.MissionTeleport.TeleportPayload)
local Config = require(script.Parent.MissionContextConfig)

export type StateListener = (state: string) -> ()

local MissionContextService = {}

local initialized = false
local generation = 0
local core: ArrivalCore.Store? = nil
local environmentProblem: string? = nil
local connections: { RBXScriptConnection } = {}
local listeners: { [number]: StateListener } = {}
local nextListenerId = 0
local lastState = ArrivalCore.States.NO_CONTEXT
local timeoutScheduled = false

local function setStateIfChanged()
    local store = core
    if store == nil then
        return
    end
    local state = store:getState()
    if state == lastState then
        return
    end
    lastState = state
    local copy: { StateListener } = {}
    for _, listener in pairs(listeners) do
        table.insert(copy, listener)
    end
    for _, listener in ipairs(copy) do
        local ok, err = pcall(listener, state)
        if not ok then
            warn("[THE LAST TURN][MissionContext] Listener error: " .. tostring(err))
        end
    end
end

local function rejectPlayer(player: Player, code: string)
    -- Never log payload contents or ids; the code is enough for diagnostics.
    warn(string.format("[THE LAST TURN][MissionContext] Rejected arrival of %d: %s", player.UserId, code))
    if not RunService:IsStudio() then
        player:Kick("Invalid mission launch data.")
    end
end

local function scheduleTimeout()
    if timeoutScheduled then
        return
    end
    timeoutScheduled = true
    local scheduledGeneration = generation
    task.delay(Config.arrivalTimeoutSeconds, function()
        local store = core
        if scheduledGeneration ~= generation or store == nil then
            return
        end
        store:checkTimeout()
        setStateIfChanged()
    end)
end

local function processPlayer(player: Player)
    local store = core
    if store == nil then
        return
    end
    if environmentProblem ~= nil then
        rejectPlayer(player, environmentProblem)
        return
    end
    local joinData = player:GetJoinData()
    local ok, payload = TeleportPayload.validate(joinData.TeleportData)
    if not ok then
        rejectPlayer(player, "invalid_payload")
        return
    end
    local result = store:arrive(player.UserId, payload)
    if not result.ok then
        rejectPlayer(player, result.rejection or "rejected")
        return
    end
    scheduleTimeout()
    setStateIfChanged()
end

function MissionContextService.getState(): string
    local store = core
    return if store then store:getState() else ArrivalCore.States.NO_CONTEXT
end

-- Fresh copy, or nil until a valid arrival established the context. Check `state` before relying on members.
function MissionContextService.getContext(): any?
    local store = core
    return store and store:getContext() or nil
end

-- Why arrivals are being refused (nil when the environment is a valid reserved MISSION server).
function MissionContextService.getEnvironmentProblem(): string?
    return environmentProblem
end

function MissionContextService.onStateChanged(listener: StateListener): () -> ()
    nextListenerId += 1
    local id = nextListenerId
    listeners[id] = listener
    return function()
        listeners[id] = nil
    end
end

-- Idempotent. Call in the MISSION bootstrap after NetworkService and PlayerStateService.
function MissionContextService.init()
    if initialized then
        return
    end
    core = ArrivalCore.new({ arrivalTimeoutSeconds = Config.arrivalTimeoutSeconds }, time)
    initialized = true
    generation += 1
    lastState = ArrivalCore.States.NO_CONTEXT
    timeoutScheduled = false

    local ok, problem = ArrivalCore.checkEnvironment({
        placeId = game.PlaceId,
        expectedPlaceId = MissionPlaces.MissionPlaceId,
        privateServerId = game.PrivateServerId,
        privateServerOwnerId = game.PrivateServerOwnerId,
    })
    environmentProblem = if ok then nil else problem
    if environmentProblem ~= nil then
        warn("[THE LAST TURN][MissionContext] Not a valid reserved MISSION server: " .. environmentProblem)
    end

    table.insert(
        connections,
        Players.PlayerAdded:Connect(function(player: Player)
            processPlayer(player)
        end)
    )
    table.insert(
        connections,
        Players.PlayerRemoving:Connect(function(player: Player)
            local store = core
            if store then
                store:leave(player.UserId)
            end
        end)
    )
    for _, player in ipairs(Players:GetPlayers()) do
        processPlayer(player)
    end
end

function MissionContextService.shutdown()
    if not initialized then
        return
    end
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
    generation += 1
    core = nil
    environmentProblem = nil
    table.clear(listeners)
    initialized = false
end

return MissionContextService
