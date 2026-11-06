--!strict
-- Server-only networking foundation, shared by HUB and MISSION (mapped to ServerStorage.ServerShared).
--
-- Responsibilities:
--   * Creates the remotes declared in NetworkContract (idempotent; reuses existing instances).
--   * Registers purpose-specific request handlers (one connection per request name).
--   * Pipeline for every client request: player still in game -> rate limit -> validate -> handler.
--   * Cleans up per-player state on PlayerRemoving.
-- Identity always comes from the Player supplied by Roblox's OnServerEvent; payloads never carry it.
-- This is NOT a generic RPC system: handlers are registered by server code for contract names only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkContract = require(ReplicatedStorage.Shared.Network.NetworkContract)
local NetworkConfig = require(script.Parent.NetworkConfig)
local RateLimiter = require(script.Parent.RateLimiter)
local Validator = require(script.Parent.Validator)

export type RequestDefinition = {
    -- Specs for the arguments after the Player (usually a single object spec).
    args: { Validator.Spec },
    -- Called only after rate limiting and validation. Receives the sanitized arguments.
    handler: (player: Player, ...any) -> (),
}

local NetworkService = {}

local initialized = false
local requestsFolder: Folder? = nil
local notificationsFolder: Folder? = nil
local limiter: RateLimiter.RateLimiter? = nil
local requestConnections: { [string]: RBXScriptConnection } = {}
local playerRemovingConnection: RBXScriptConnection? = nil

local function getOrCreateFolder(parent: Instance, name: string): Folder
    local existing = parent:FindFirstChild(name)
    if existing ~= nil then
        if existing:IsA("Folder") then
            return existing
        end
        error(string.format("NetworkService: '%s' exists but is not a Folder", name))
    end
    local folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = parent
    return folder
end

local function getOrCreateRemote(parent: Folder, name: string): RemoteEvent
    local existing = parent:FindFirstChild(name)
    if existing ~= nil then
        if existing:IsA("RemoteEvent") then
            return existing
        end
        error(string.format("NetworkService: '%s' exists but is not a RemoteEvent", name))
    end
    local remote = Instance.new("RemoteEvent")
    remote.Name = name
    remote.Parent = parent
    return remote
end

-- Idempotent. Must be called by the server bootstrap before any dependent system starts.
function NetworkService.init()
    if initialized then
        return
    end

    -- Every contract request needs a rate limit, and every limit needs a contract request.
    local contractRequests = NetworkContract.Requests :: { [string]: string }
    local limits = NetworkConfig.RateLimits :: { [string]: RateLimiter.Limit }
    for name in pairs(contractRequests) do
        assert(limits[name] ~= nil, "NetworkService: missing rate limit for request " .. name)
    end
    for name in pairs(limits) do
        assert(contractRequests[name] ~= nil, "NetworkService: rate limit for unknown request " .. name)
    end

    local root = getOrCreateFolder(ReplicatedStorage, NetworkContract.RootFolderName)
    local requests = getOrCreateFolder(root, NetworkContract.RequestsFolderName)
    local notifications = getOrCreateFolder(root, NetworkContract.NotificationsFolderName)
    for name in pairs(contractRequests) do
        getOrCreateRemote(requests, name)
    end
    for name in pairs(NetworkContract.Notifications :: { [string]: string }) do
        getOrCreateRemote(notifications, name)
    end

    requestsFolder = requests
    notificationsFolder = notifications
    limiter = RateLimiter.new(limits, time)

    local activeLimiter = limiter :: RateLimiter.RateLimiter
    playerRemovingConnection = Players.PlayerRemoving:Connect(function(player: Player)
        local userId = player.UserId
        activeLimiter:removePlayer(userId)
        -- A request already queued for this player could recreate state; clear again after it ran.
        task.defer(function()
            activeLimiter:removePlayer(userId)
        end)
    end)

    initialized = true
end

-- Registers the handler for one request declared in NetworkContract.Requests. Server code only.
function NetworkService.registerRequest(name: string, definition: RequestDefinition)
    assert(initialized, "NetworkService.init() must run before registerRequest")
    assert((NetworkContract.Requests :: { [string]: string })[name] == name, "Unknown request: " .. tostring(name))
    assert(requestConnections[name] == nil, "Request handler already registered: " .. name)

    local remote = (requestsFolder :: Folder):FindFirstChild(name)
    assert(remote ~= nil and remote:IsA("RemoteEvent"), "Request remote missing: " .. name)
    local activeLimiter = limiter :: RateLimiter.RateLimiter
    local argCount = #definition.args

    requestConnections[name] = remote.OnServerEvent:Connect(function(player: Player, ...: any)
        -- 1. Identity is the Player Roblox gave us; ignore players that are already leaving.
        if player.Parent ~= Players then
            return
        end
        -- 2. Rate limit before doing any other work. Rejected requests never reach the handler.
        if not activeLimiter:tryConsume(player.UserId, name) then
            return
        end
        -- 3. Validate arguments (fail closed). Reasons are logged, never sent to the client.
        local ok, result = Validator.validateArguments(definition.args, ...)
        if not ok then
            warn(string.format("[THE LAST TURN][Network] Rejected %s from %d: %s", name, player.UserId, tostring(result)))
            return
        end
        -- 4. Handler runs protected so one failure cannot break the connection.
        local success, err = pcall(definition.handler, player, table.unpack(result :: { any }, 1, argCount))
        if not success then
            warn(string.format("[THE LAST TURN][Network] Handler error in %s: %s", name, tostring(err)))
        end
    end)
end

-- Disconnects one request handler so its owner can shut down and register again. Idempotent.
function NetworkService.unregisterRequest(name: string): boolean
    local connection = requestConnections[name]
    if connection == nil then
        return false
    end
    connection:Disconnect()
    requestConnections[name] = nil
    return true
end

-- Server -> client notification. Name must be declared in NetworkContract.Notifications.
function NetworkService.fireNotification(name: string, player: Player, payload: any)
    assert(initialized, "NetworkService.init() must run before fireNotification")
    assert(
        (NetworkContract.Notifications :: { [string]: string })[name] == name,
        "Unknown notification: " .. tostring(name)
    )
    local remote = (notificationsFolder :: Folder):FindFirstChild(name)
    assert(remote ~= nil and remote:IsA("RemoteEvent"), "Notification remote missing: " .. name)
    remote:FireClient(player, payload)
end

-- Disconnects everything and forgets all player state. Intended for shutdown/tests; init() may run again.
function NetworkService.shutdown()
    for name, connection in pairs(requestConnections) do
        connection:Disconnect()
        requestConnections[name] = nil
    end
    if playerRemovingConnection then
        playerRemovingConnection:Disconnect()
        playerRemovingConnection = nil
    end
    limiter = nil
    requestsFolder = nil
    notificationsFolder = nil
    initialized = false
end

return NetworkService
