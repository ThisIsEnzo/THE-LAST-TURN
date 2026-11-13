--!strict
-- HUB client controller for the party UI (TTL-HUB-02). It only MIRRORS the server's party state (through the pure
-- PartyView) and forwards the player's clicks to the EXISTING TTL-04 requests. It never decides who the leader is, who
-- may kick or invite, or what a party contains: every request is re-validated by PartyService on the server, and the
-- UI only re-renders from the notifications the server sends. No remote is created here (ClientNetwork only waits for
-- the server-created ones), and no polling is used: a single delayed refresh is scheduled while a countdown is visible.
--
-- start() is idempotent (no duplicate subscriptions) and destroy() disconnects everything.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClientNetwork = require(Shared:WaitForChild("Network"):WaitForChild("ClientNetwork"))
local NetworkContract = require(Shared:WaitForChild("Network"):WaitForChild("NetworkContract"))
local Constants = require(Shared:WaitForChild("Config"):WaitForChild("Constants"))
local PartyView = require(Shared:WaitForChild("Party"):WaitForChild("PartyView"))
local Messages = require(Shared:WaitForChild("UI"):WaitForChild("Messages"))

local LOG_PREFIX = "[THE LAST TURN][Party]"

export type ViewModel = PartyView.ViewModel
export type Candidate = PartyView.Candidate
export type Notice = { tone: string, text: string }

local PartyController = {}

local localPlayer = Players.LocalPlayer
local started = false
local view: any = nil
local requests: { [string]: RemoteEvent } = {}
local connections: { RBXScriptConnection } = {}
local changeListeners: { [number]: () -> () } = {}
local noticeListeners: { [number]: (Notice) -> () } = {}
local nextListenerId = 0
local refreshToken = 0
local nextActionRequestId = 0
local pendingActions: { [number]: { action: string, subjectUserId: number } } = {}

local function now(): number
    return time()
end

local function safeCall(callback: any, ...: any)
    local ok, err = pcall(callback, ...)
    if not ok then
        warn(string.format("%s listener failed: %s", LOG_PREFIX, tostring(err)))
    end
end

local function emitChanged()
    for _, listener in pairs(changeListeners) do
        safeCall(listener)
    end
end

local function emitNotice(tone: string, text: string)
    local notice: Notice = { tone = tone, text = text }
    for _, listener in pairs(noticeListeners) do
        safeCall(listener, notice)
    end
end

local function nameOf(userId: number?, fallback: string?): string
    if userId ~= nil then
        local player = Players:GetPlayerByUserId(userId)
        if player ~= nil then
            return player.DisplayName
        end
    end
    if fallback ~= nil and #fallback > 0 then
        return fallback
    end
    return "A player"
end

-- One delayed refresh at most: re-renders when an invitation countdown or a UI lock changes by itself.
local function scheduleRefresh()
    refreshToken += 1
    local token = refreshToken
    local current = view
    if not started or current == nil then
        return
    end
    local delay = current:nextRefreshIn(now())
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

local function noticeForPartyEvent(event: any)
    local template = Messages.partyEvent(event.type, event.isLocal)
    local tone = "info"
    if event.type == "left_party" then
        tone = "warning"
    end
    emitNotice(tone, Messages.fill(template, nameOf(event.userId, event.displayName)))
end

local function noticeForInviteEnded(event: any)
    local template = Messages.inviteEnded(event.reason, event.role)
    local tone = "info"
    if event.reason == "declined" or event.reason == "expired" or event.reason == "cancelled" then
        tone = "warning"
    end
    emitNotice(tone, Messages.fill(template, nameOf(event.userId, event.displayName)))
end

local function onSnapshot(payload: any)
    local current = view
    if current == nil then
        return
    end
    local accepted, events = current:applySnapshot(payload, now())
    if not accepted then
        warn(string.format("%s Ignored a malformed party snapshot.", LOG_PREFIX))
        return
    end
    for _, event in ipairs(events) do
        noticeForPartyEvent(event)
    end
    changed()
end

local function onInviteReceived(payload: any)
    local current = view
    if current ~= nil and current:applyInviteReceived(payload, now()) then
        changed()
    end
end

local function onPartyActionResult(payload: any)
    if type(payload) ~= "table" or type(payload.requestId) ~= "number" or type(payload.action) ~= "string" or type(payload.ok) ~= "boolean" then
        return
    end
    local pending = pendingActions[payload.requestId]
    if pending == nil or pending.action ~= payload.action then
        return -- stale, duplicate or unsolicited acknowledgement
    end
    pendingActions[payload.requestId] = nil
    local current = view
    if current == nil then
        return
    end

    if pending.action == "invite" and payload.targetUserId == pending.subjectUserId then
        if payload.ok then
            emitNotice("info", Messages.fill("Invitation sent to {name}.", nameOf(pending.subjectUserId, nil)))
        else
            current:clearOutgoingInvite(pending.subjectUserId)
            emitNotice("warning", Messages.partyActionFailure(payload.reason))
        end
    elseif pending.action == "respond" and payload.inviterUserId == pending.subjectUserId then
        if not payload.ok then
            current:resetResponding(pending.subjectUserId)
            emitNotice("warning", Messages.partyActionFailure(payload.reason))
        end
    else
        return
    end
    changed()
end

local function makeRequestId(): number
    nextActionRequestId += 1
    if nextActionRequestId > 9007199254740991 then
        nextActionRequestId = 1
    end
    return nextActionRequestId
end

local function onInviteEnded(payload: any)
    local current = view
    if current == nil then
        return
    end
    local accepted, events = current:applyInviteEnded(payload, now())
    if not accepted then
        return
    end
    for _, event in ipairs(events) do
        noticeForInviteEnded(event)
    end
    changed()
end

local function fire(name: string, payload: any?): boolean
    local remote = requests[name]
    if remote == nil then
        return false
    end
    if payload == nil then
        remote:FireServer()
    else
        remote:FireServer(payload)
    end
    return true
end

-- Public API -------------------------------------------------------------------------------------------------------

-- Subscribes to the party notifications, then asks the server for the current snapshot. Safe to call twice.
function PartyController.start()
    if started then
        return
    end
    started = true
    view = PartyView.new(localPlayer.UserId, Constants.Experience.MaxPartySize)

    table.insert(connections, Players.PlayerAdded:Connect(changed))
    table.insert(connections, Players.PlayerRemoving:Connect(function()
        task.defer(changed) -- after the player is gone from Players:GetPlayers()
    end))

    task.spawn(function()
        local Notifications = NetworkContract.Notifications
        local handlers: { [string]: (any) -> () } = {
            [Notifications.PartySnapshot] = onSnapshot,
            [Notifications.PartyInviteReceived] = onInviteReceived,
            [Notifications.PartyInviteEnded] = onInviteEnded,
            [Notifications.PartyActionResult] = onPartyActionResult,
        }
        for name, handler in pairs(handlers) do
            local remote = ClientNetwork.waitForNotification(name)
            if remote ~= nil and started then
                table.insert(connections, remote.OnClientEvent:Connect(handler))
            end
        end
        for _, name in ipairs({
            NetworkContract.Requests.PartyInvite,
            NetworkContract.Requests.PartyRespondInvite,
            NetworkContract.Requests.PartyLeave,
            NetworkContract.Requests.PartyKick,
            NetworkContract.Requests.PartyRequestSnapshot,
        }) do
            local remote = ClientNetwork.waitForRequest(name)
            if remote ~= nil then
                requests[name] = remote
            end
        end
        if started then
            fire(NetworkContract.Requests.PartyRequestSnapshot) -- the listeners are connected: pull the current state once
        end
    end)
end

function PartyController.destroy()
    started = false
    refreshToken += 1
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
    table.clear(requests)
    table.clear(pendingActions)
    table.clear(changeListeners)
    table.clear(noticeListeners)
    view = nil
end

function PartyController.getViewModel(): ViewModel?
    local current = view
    if current == nil then
        return nil
    end
    return current:getViewModel(now())
end

-- Other players currently in this HUB server with their invite state (a UI list; the server validates every invite).
function PartyController.getCandidates(): { Candidate }
    local current = view
    if current == nil then
        return {}
    end
    local players: { PartyView.Member } = {}
    for _, player in ipairs(Players:GetPlayers()) do
        table.insert(players, { userId = player.UserId, displayName = player.DisplayName })
    end
    return current:getCandidates(players, now())
end

function PartyController.isLeader(): boolean
    local current = view
    return current ~= nil and current:isLeader()
end

function PartyController.getPartyId(): string?
    local current = view
    if current == nil then
        return nil
    end
    return current:getPartyId()
end

-- Returns a function that removes the listener.
function PartyController.onChanged(listener: () -> ()): () -> ()
    nextListenerId += 1
    local id = nextListenerId
    changeListeners[id] = listener
    return function()
        changeListeners[id] = nil
    end
end

function PartyController.onNotice(listener: (Notice) -> ()): () -> ()
    nextListenerId += 1
    local id = nextListenerId
    noticeListeners[id] = listener
    return function()
        noticeListeners[id] = nil
    end
end

-- Actions: each returns (sent, reason?). The pure view blocks impossible or duplicate actions BEFORE anything is sent;
-- the server remains the authority and silently ignores anything that is not allowed.

function PartyController.invite(targetUserId: number): (boolean, string?)
    local current = view
    if current == nil or requests[NetworkContract.Requests.PartyInvite] == nil then
        return false, "not_ready"
    end
    local allowed, reason = current:canInvite(targetUserId, now())
    if not allowed then
        emitNotice("warning", Messages.inviteBlocked(reason))
        return false, reason
    end
    local requestId = makeRequestId()
    if not current:markInviteSent(targetUserId, now()) then
        return false, "busy"
    end
    if not fire(NetworkContract.Requests.PartyInvite, { targetUserId = targetUserId, requestId = requestId }) then
        current:clearOutgoingInvite(targetUserId)
        return false, "not_ready"
    end
    pendingActions[requestId] = { action = "invite", subjectUserId = targetUserId }
    changed()
    return true, nil
end

function PartyController.respond(inviterUserId: number, accept: boolean): (boolean, string?)
    local current = view
    if current == nil or requests[NetworkContract.Requests.PartyRespondInvite] == nil then
        return false, "not_ready"
    end
    if not current:markResponding(inviterUserId, now()) then
        return false, "busy"
    end
    local requestId = makeRequestId()
    if not fire(NetworkContract.Requests.PartyRespondInvite, { inviterUserId = inviterUserId, accept = accept, requestId = requestId }) then
        current:resetResponding(inviterUserId)
        return false, "not_ready"
    end
    pendingActions[requestId] = { action = "respond", subjectUserId = inviterUserId }
    changed()
    return true, nil
end

function PartyController.kick(targetUserId: number): (boolean, string?)
    local current = view
    if current == nil or requests[NetworkContract.Requests.PartyKick] == nil then
        return false, "not_ready"
    end
    if not current:markKickSent(targetUserId, now()) then
        return false, "not_allowed"
    end
    fire(NetworkContract.Requests.PartyKick, { targetUserId = targetUserId })
    changed()
    return true, nil
end

function PartyController.leave(): (boolean, string?)
    local current = view
    if current == nil or requests[NetworkContract.Requests.PartyLeave] == nil then
        return false, "not_ready"
    end
    if not current:markLeaveSent(now()) then
        return false, "not_allowed"
    end
    fire(NetworkContract.Requests.PartyLeave)
    changed()
    return true, nil
end

return PartyController
