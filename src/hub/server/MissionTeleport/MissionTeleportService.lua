--!strict
-- HUB mission launch (server-authoritative). Wires the pure LaunchCoordinator to Roblox: PartyService and
-- PlayerStateService queries, TeleportService, HttpService GUIDs, notifications and timers.
--
-- Clients only send a payload-less `MissionLaunch` request. Identity is the Player from the remote callback; the
-- party, member list, PlaceId, mission id and reserved server id are all derived on the server. The reserved
-- server id is never logged, sent to clients, or stored in teleport data.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")

local NetworkContract = require(ReplicatedStorage.Shared.Network.NetworkContract)
local NetworkService = require(ServerStorage.ServerShared.Network.NetworkService)
local PlayerStateService = require(ServerStorage.ServerShared.Player.PlayerStateService)
local LaunchCoordinator = require(ServerStorage.ServerShared.MissionTeleport.LaunchCoordinator)
local MissionPlaces = require(ServerStorage.ServerShared.MissionTeleport.MissionPlaces)
local TeleportPayload = require(ServerStorage.ServerShared.MissionTeleport.TeleportPayload)
local PartyService = require(script.Parent.Parent.Party.PartyService)
local Config = require(script.Parent.MissionTeleportConfig)

local MissionTeleportService = {}

local initialized = false
local coordinator: LaunchCoordinator.Coordinator? = nil
local connections: { RBXScriptConnection } = {}
local registeredRequests: { string } = {}

local function playerFor(userId: number): Player?
    local player = Players:GetPlayerByUserId(userId)
    if player ~= nil and player.Parent == Players then
        return player
    end
    return nil
end

local function createDeps(): LaunchCoordinator.Deps
    local placeId = MissionPlaces.MissionPlaceId
    return {
        getPartyForUser = function(userId: number)
            local player = playerFor(userId)
            return player and PartyService.getParty(player) or nil
        end,
        isConnected = function(userId: number)
            return playerFor(userId) ~= nil
        end,
        getLifecycleState = function(userId: number)
            local player = playerFor(userId)
            return player and PlayerStateService.getState(player) or nil
        end,
        newGuid = function()
            return HttpService:GenerateGUID(false)
        end,
        now = function()
            return os.time()
        end,
        buildPayload = TeleportPayload.build,
        teleport = function(launch: LaunchCoordinator.LaunchInfo)
            local targets: { Player } = {}
            for _, userId in ipairs(launch.memberUserIds) do
                local player = playerFor(userId)
                if player then
                    table.insert(targets, player)
                end
            end
            local options = Instance.new("TeleportOptions")
            options.ReservedServerId = launch.reservedServerId
            options:SetTeleportData(launch.payload)
            -- Only the TeleportAsync call is protected; our own logic above stays unprotected so bugs surface.
            local ok, err = pcall(function()
                TeleportService:TeleportAsync(placeId, targets, options)
            end)
            if not ok then
                warn("[THE LAST TURN][MissionTeleport] TeleportAsync failed: " .. tostring(err))
            end
            return ok, if ok then nil else tostring(err)
        end,
        retry = function(userId: number, options: any, _launch: LaunchCoordinator.LaunchInfo)
            local player = playerFor(userId)
            if player == nil then
                return false, "player_left"
            end
            -- `options` is the TeleportOptions from TeleportInitFailed: same destination, no new reserved server.
            local ok, err = pcall(function()
                TeleportService:TeleportAsync(placeId, { player }, options)
            end)
            if not ok then
                warn("[THE LAST TURN][MissionTeleport] Retry failed: " .. tostring(err))
            end
            return ok, if ok then nil else tostring(err)
        end,
        notify = function(userIds: { number }, status: string, extra: { [string]: any }?)
            for _, userId in ipairs(userIds) do
                local player = playerFor(userId)
                if player then
                    local payload: { [string]: any } = { status = status }
                    for key, value in pairs(extra or {}) do
                        payload[key] = value
                    end
                    local ok, err = pcall(NetworkService.fireNotification, NetworkContract.Notifications.MissionLaunchStatus, player, payload)
                    if not ok then
                        warn("[THE LAST TURN][MissionTeleport] Notification failed: " .. tostring(err))
                    end
                end
            end
        end,
        -- Timers are flag-cancelled (never task.cancel) so a callback can safely release its own launch.
        schedule = function(delaySeconds: number, callback: () -> ())
            local cancelled = false
            task.delay(delaySeconds, function()
                if not cancelled then
                    callback()
                end
            end)
            return function()
                cancelled = true
            end
        end,
    }
end

-- Idempotent. Call in the HUB bootstrap after NetworkService, PlayerStateService and PartyService.
function MissionTeleportService.init()
    if initialized then
        return
    end
    local active = LaunchCoordinator.new({
        missionPlaceId = MissionPlaces.MissionPlaceId,
        maxPartySize = require(ReplicatedStorage.Shared.Config.Constants).Experience.MaxPartySize,
        missionType = Config.missionType,
        maxRetriesPerPlayer = Config.maxRetriesPerPlayer,
        retryDelaySeconds = Config.retryDelaySeconds,
        launchTimeoutSeconds = Config.launchTimeoutSeconds,
    }, createDeps())
    coordinator = active
    initialized = true

    if not LaunchCoordinator.isValidPlaceId(MissionPlaces.MissionPlaceId) then
        warn("[THE LAST TURN][MissionTeleport] MissionPlaceId is not configured; mission launches are disabled.")
    end

    local name = NetworkContract.Requests.MissionLaunch
    NetworkService.registerRequest(name, {
        args = {}, -- no client-supplied data at all
        handler = function(player: Player)
            active:requestLaunch(player.UserId)
        end,
    })
    table.insert(registeredRequests, name)

    table.insert(
        connections,
        TeleportService.TeleportInitFailed:Connect(
            function(player: Player, teleportResult: Enum.TeleportResult, errorMessage: string, targetPlaceId: number, teleportOptions: TeleportOptions?)
                if targetPlaceId ~= MissionPlaces.MissionPlaceId then
                    return
                end
                active:onTeleportInitFailed(player.UserId, {
                    reservedServerId = teleportOptions and teleportOptions.ReservedServerId or nil,
                    options = teleportOptions,
                    code = "init_failed_" .. teleportResult.Name,
                })
            end
        )
    )
    table.insert(
        connections,
        Players.PlayerRemoving:Connect(function(player: Player)
            active:onPlayerRemoved(player.UserId)
        end)
    )
end

-- Read-only diagnostics for other HUB systems.
function MissionTeleportService.getActiveLaunchCount(): number
    return if coordinator then coordinator:getActiveLaunchCount() else 0
end

function MissionTeleportService.shutdown()
    if not initialized then
        return
    end
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, name in ipairs(registeredRequests) do
        NetworkService.unregisterRequest(name)
    end
    table.clear(registeredRequests)
    if coordinator then
        coordinator:shutdown()
    end
    coordinator = nil
    initialized = false
end

return MissionTeleportService
