--!strict
-- HUB client controller for the mission launch (TTL-HUB-02). It sends the EXISTING payload-less MissionLaunch request
-- and mirrors MissionLaunchStatus notifications through the pure LaunchView. It never sends a PlaceId, mission type,
-- member id or server id, never starts anything itself and never bypasses MissionTeleportService / LaunchCoordinator.
-- It is subscribed for the whole session (independent of any open panel), so a status arriving while the UI is closed
-- is still reflected, and a party change resets its state.
--
-- start() is idempotent and destroy() disconnects everything.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClientNetwork = require(Shared:WaitForChild("Network"):WaitForChild("ClientNetwork"))
local NetworkContract = require(Shared:WaitForChild("Network"):WaitForChild("NetworkContract"))
local LaunchView = require(Shared:WaitForChild("Mission"):WaitForChild("LaunchView"))
local Messages = require(Shared:WaitForChild("UI"):WaitForChild("Messages"))

local LOG_PREFIX = "[THE LAST TURN][MissionLaunch]"

export type View = LaunchView.View

local MissionLaunchController = {}

local started = false
local view: any = nil
local partyController: any = nil
local launchRemote: RemoteEvent? = nil
local connections: { RBXScriptConnection } = {}
local unsubscribers: { () -> () } = {}
local listeners: { [number]: () -> () } = {}
local nextListenerId = 0
local refreshToken = 0

local function now(): number
    return time()
end

local function emitChanged()
    for _, listener in pairs(listeners) do
        local ok, err = pcall(listener)
        if not ok then
            warn(string.format("%s listener failed: %s", LOG_PREFIX, tostring(err)))
        end
    end
end

-- One delayed refresh at most, for the timeouts that end a launch state without any notification.
local function scheduleRefresh()
    refreshToken += 1
    local token = refreshToken
    local current = view
    if not started or current == nil then
        return
    end
    local delay = current:nextDeadline(now())
    if delay ~= nil then
        task.delay(delay, function()
            if started and token == refreshToken then
                emitChanged()
                scheduleRefresh()
            end
        end)
    end
end

local function changed()
    emitChanged()
    scheduleRefresh()
end

local function onStatus(payload: any)
    local current = view
    if current ~= nil and current:applyStatus(payload, now()) then
        changed()
    end
end

local function syncParty()
    local current = view
    if current ~= nil and partyController ~= nil then
        current:observeParty(partyController.getPartyId(), now())
        changed()
    end
end

-- `party` is the PartyController (leader and party id come from the server-mirrored party state).
function MissionLaunchController.start(party: any)
    if started then
        return
    end
    started = true
    partyController = party
    view = LaunchView.new(Messages)

    table.insert(unsubscribers, party.onChanged(syncParty))

    task.spawn(function()
        local status = ClientNetwork.waitForNotification(NetworkContract.Notifications.MissionLaunchStatus)
        if status ~= nil and started then
            table.insert(connections, status.OnClientEvent:Connect(onStatus))
        end
        local request = ClientNetwork.waitForRequest(NetworkContract.Requests.MissionLaunch)
        if started then
            launchRemote = request
        end
    end)
end

function MissionLaunchController.destroy()
    started = false
    refreshToken += 1
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, unsubscribe in ipairs(unsubscribers) do
        unsubscribe()
    end
    table.clear(unsubscribers)
    table.clear(listeners)
    launchRemote = nil
    partyController = nil
    view = nil
end

function MissionLaunchController.getView(): View?
    local current = view
    if current == nil then
        return nil
    end
    return current:getView(now())
end

-- UI hint: may the Start button be pressed right now? (The server re-validates everything.)
function MissionLaunchController.canRequest(): boolean
    local current = view
    if current == nil or partyController == nil or launchRemote == nil then
        return false
    end
    local allowed = current:canRequest(partyController.isLeader(), now())
    return allowed
end

-- Sends the payload-less MissionLaunch request if the pure view allows it. Returns (sent, reason?).
function MissionLaunchController.requestLaunch(): (boolean, string?)
    local current = view
    local remote = launchRemote
    if current == nil or partyController == nil or remote == nil then
        return false, "not_ready"
    end
    local allowed, reason = current:tryBeginRequest(partyController.isLeader(), partyController.getPartyId(), now())
    if not allowed then
        return false, reason
    end
    remote:FireServer(table.unpack(LaunchView.requestArguments())) -- no arguments: the server derives everything
    changed()
    return true, nil
end

function MissionLaunchController.onChanged(listener: () -> ()): () -> ()
    nextListenerId += 1
    local id = nextListenerId
    listeners[id] = listener
    return function()
        listeners[id] = nil
    end
end

return MissionLaunchController
