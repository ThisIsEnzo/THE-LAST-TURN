--!strict
-- HUB party service (server-authoritative). Owns Roblox integration only: player lifecycle, networking,
-- invitation timers and notifications. All rules and state live in the pure PartyCore.
--
-- Every connected player is always in exactly one party (a solo party on join). Membership is local to this
-- HUB server. Clients can only *request* actions through purpose-specific remotes; identity always comes from
-- the Player supplied by Roblox, and everything else is validated by PartyCore.
-- TTL-05 (Mission Teleport) consumes getParty / getMembers / getLeader / onPartyChanged.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local NetworkContract = require(ReplicatedStorage.Shared.Network.NetworkContract)
local NetworkService = require(ServerStorage.ServerShared.Network.NetworkService)
local Validator = require(ServerStorage.ServerShared.Network.Validator)
local PartyCore = require(ServerStorage.ServerShared.Party.PartyCore)
local PartyConfig = require(script.Parent.PartyConfig)

export type PartySnapshot = PartyCore.PartySnapshot
export type PartyResult = PartyCore.Result
-- Called after membership/leadership changes with a snapshot of each affected (still existing) party.
export type PartyChangedListener = (snapshot: PartySnapshot) -> ()

local MAX_USER_ID = 9007199254740991 -- 2^53 - 1

local PartyService = {}

local initialized = false
local generation = 0 -- invalidates delayed invite-expiry callbacks across shutdown/init
local core: PartyCore.Store? = nil
local serviceConnections: { RBXScriptConnection } = {}
local registeredRequests: { string } = {}
local listeners: { [number]: PartyChangedListener } = {}
local nextListenerId = 0

local function failure(reason: string): PartyResult
    return { ok = false, changed = false, rejection = reason, partyId = nil, invite = nil, affected = {}, endedInvites = {} }
end

local function send(userId: number, name: string, payload: any)
    local store = core
    if store == nil or not store:isRegistered(userId) then
        return
    end
    local player = Players:GetPlayerByUserId(userId)
    if player == nil then
        return
    end
    local ok, err = pcall(NetworkService.fireNotification, name, player, payload)
    if not ok then
        warn("[THE LAST TURN][Party] Notification failed: " .. tostring(err))
    end
end

local function snapshotPayload(snapshot: PartySnapshot): any
    local members = {}
    for _, userId in ipairs(snapshot.members) do
        local member = Players:GetPlayerByUserId(userId)
        table.insert(members, { userId = userId, displayName = if member then member.DisplayName else "" })
    end
    return { partyId = snapshot.id, leaderUserId = snapshot.leader, members = members }
end

local function sendSnapshot(userId: number)
    local store = core
    if store == nil then
        return
    end
    local snapshot = store:getPartyOf(userId)
    if snapshot then
        local payload = snapshotPayload(snapshot)
        -- Invitations are recipient-private and must survive a missed push (e.g. listener setup race).
        -- Include them only in this player's snapshot response, never in party-wide broadcasts.
        payload.pendingInvites = {}
        for _, invite in ipairs(store:getInvitesFor(userId)) do
            local inviter = Players:GetPlayerByUserId(invite.inviter)
            table.insert(payload.pendingInvites, {
                inviterUserId = invite.inviter,
                inviterDisplayName = if inviter then inviter.DisplayName else "",
                expiresAt = invite.expiresAt,
            })
        end
        send(userId, NetworkContract.Notifications.PartySnapshot, payload)
    end
end

-- Pushes notifications and listener callbacks for the outcome of any core operation.
local function applyResult(result: PartyResult)
    local store = core
    if store == nil then
        return
    end
    for _, ended in ipairs(result.endedInvites) do
        local payload = { inviterUserId = ended.inviter, targetUserId = ended.target, reason = ended.reason }
        send(ended.target, NetworkContract.Notifications.PartyInviteEnded, payload)
        send(ended.inviter, NetworkContract.Notifications.PartyInviteEnded, payload)
    end

    local changedParties: { [string]: PartySnapshot } = {}
    for _, userId in ipairs(result.affected) do
        sendSnapshot(userId)
        local snapshot = store:getPartyOf(userId)
        if snapshot then
            changedParties[snapshot.id] = snapshot
        end
    end
    for _, snapshot in pairs(changedParties) do
        local copy: { PartyChangedListener } = {}
        for _, listener in pairs(listeners) do
            table.insert(copy, listener)
        end
        for _, listener in ipairs(copy) do
            local ok, err = pcall(listener, snapshot)
            if not ok then
                warn("[THE LAST TURN][Party] Listener error: " .. tostring(err))
            end
        end
    end
end

local function scheduleExpiry(inviteId: number)
    local scheduledGeneration = generation
    -- Event-driven (no polling); a small margin covers clock/scheduler drift. Acceptance and later invites
    -- also expire records lazily, so a missed timer cannot leave a usable stale invitation.
    task.delay(PartyConfig.inviteTtlSeconds + 0.25, function()
        local store = core
        if scheduledGeneration ~= generation or store == nil then
            return
        end
        applyResult(store:expireInvite(inviteId))
    end)
end

-- Server-side queries --------------------------------------------------------------------------------------------

function PartyService.getParty(player: Player): PartySnapshot?
    local store = core
    return store and store:getPartyOf(player.UserId)
end

function PartyService.getPartyById(partyId: string): PartySnapshot?
    local store = core
    return store and store:getPartyById(partyId)
end

-- Connected members in join order.
function PartyService.getMembers(player: Player): { Player }
    local members: { Player } = {}
    local snapshot = PartyService.getParty(player)
    if snapshot then
        for _, userId in ipairs(snapshot.members) do
            local member = Players:GetPlayerByUserId(userId)
            if member then
                table.insert(members, member)
            end
        end
    end
    return members
end

function PartyService.getLeader(player: Player): Player?
    local snapshot = PartyService.getParty(player)
    return snapshot and Players:GetPlayerByUserId(snapshot.leader) or nil
end

-- Server-side mutations (also used by the remote handlers) --------------------------------------------------------

function PartyService.invite(inviter: Player, target: Player): PartyResult
    local store = core
    if not initialized or store == nil then
        return failure("not_initialized")
    end
    local result = store:invite(inviter.UserId, target.UserId)
    applyResult(result)
    local invite = result.invite
    if result.ok and invite then
        send(target.UserId, NetworkContract.Notifications.PartyInviteReceived, {
            inviterUserId = inviter.UserId,
            inviterDisplayName = inviter.DisplayName,
            expiresInSeconds = PartyConfig.inviteTtlSeconds,
        })
        scheduleExpiry(invite.id)
    end
    return result
end

function PartyService.respondToInvite(target: Player, inviter: Player, accept: boolean): PartyResult
    local store = core
    if not initialized or store == nil then
        return failure("not_initialized")
    end
    local result = store:respondToInvite(target.UserId, inviter.UserId, accept)
    applyResult(result)
    return result
end

function PartyService.leave(player: Player): PartyResult
    local store = core
    if not initialized or store == nil then
        return failure("not_initialized")
    end
    local result = store:leave(player.UserId)
    applyResult(result)
    return result
end

function PartyService.kick(leader: Player, target: Player): PartyResult
    local store = core
    if not initialized or store == nil then
        return failure("not_initialized")
    end
    local result = store:kick(leader.UserId, target.UserId)
    applyResult(result)
    return result
end

function PartyService.onPartyChanged(listener: PartyChangedListener): () -> ()
    nextListenerId += 1
    local id = nextListenerId
    listeners[id] = listener
    return function()
        listeners[id] = nil
    end
end

-- Player lifecycle -----------------------------------------------------------------------------------------------

local function registerPlayer(player: Player)
    local store = core
    if store == nil or player.Parent ~= Players then
        return
    end
    applyResult(store:addPlayer(player.UserId)) -- also sends the initial snapshot
end

local function unregisterPlayer(player: Player)
    local store = core
    if store == nil then
        return
    end
    applyResult(store:removePlayer(player.UserId)) -- idempotent
end

local function registerRequests()
    local requests = NetworkContract.Requests
    local userId = Validator.integer({ min = 1, max = MAX_USER_ID })
    local requestId = Validator.integer({ min = 1, max = MAX_USER_ID })

    local function sendActionResult(player: Player, action: string, id: number, result: PartyResult, subjectUserId: number?)
        local payload = { action = action, requestId = id, ok = result.ok, reason = result.rejection }
        if action == "invite" then
            payload.targetUserId = subjectUserId
        else
            payload.inviterUserId = subjectUserId
        end
        send(player.UserId, NetworkContract.Notifications.PartyActionResult, payload)
    end

    local function register(name: string, definition: NetworkService.RequestDefinition)
        NetworkService.registerRequest(name, definition)
        table.insert(registeredRequests, name)
    end

    -- Handlers only translate requests into service calls; the service/core validate state. Requests naming a
    -- player who is not connected are dropped (nothing to act on, nothing to report to the client yet).
    register(requests.PartyInvite, {
        args = { Validator.object({ targetUserId = userId, requestId = requestId }) },
        handler = function(player: Player, payload: any)
            local target = Players:GetPlayerByUserId(payload.targetUserId)
            local result = if target then PartyService.invite(player, target) else failure("unknown_player")
            sendActionResult(player, "invite", payload.requestId, result, payload.targetUserId)
        end,
    })
    register(requests.PartyRespondInvite, {
        args = { Validator.object({ inviterUserId = userId, accept = Validator.boolean(), requestId = requestId }) },
        handler = function(player: Player, payload: any)
            local inviter = Players:GetPlayerByUserId(payload.inviterUserId)
            local result = if inviter then PartyService.respondToInvite(player, inviter, payload.accept) else failure("unknown_inviter")
            sendActionResult(player, "respond", payload.requestId, result, payload.inviterUserId)
        end,
    })
    register(requests.PartyLeave, {
        args = {},
        handler = function(player: Player)
            PartyService.leave(player)
        end,
    })
    register(requests.PartyKick, {
        args = { Validator.object({ targetUserId = userId }) },
        handler = function(player: Player, payload: any)
            local target = Players:GetPlayerByUserId(payload.targetUserId)
            if target then
                PartyService.kick(player, target)
            end
        end,
    })
    register(requests.PartyRequestSnapshot, {
        args = {},
        handler = function(player: Player)
            sendSnapshot(player.UserId)
        end,
    })
end

-- Idempotent. Call in the HUB bootstrap after NetworkService.init() and PlayerStateService.init().
function PartyService.init()
    if initialized then
        return
    end
    core = PartyCore.new(PartyConfig, time)
    initialized = true
    generation += 1

    registerRequests()

    table.insert(
        serviceConnections,
        Players.PlayerAdded:Connect(function(player: Player)
            registerPlayer(player)
        end)
    )
    table.insert(
        serviceConnections,
        Players.PlayerRemoving:Connect(function(player: Player)
            unregisterPlayer(player)
        end)
    )
    for _, player in ipairs(Players:GetPlayers()) do
        registerPlayer(player)
    end
end

-- Disconnects handlers and connections and clears all party state. init() may run again. Idempotent.
function PartyService.shutdown()
    if not initialized then
        return
    end
    for _, connection in ipairs(serviceConnections) do
        connection:Disconnect()
    end
    table.clear(serviceConnections)
    for _, name in ipairs(registeredRequests) do
        NetworkService.unregisterRequest(name)
    end
    table.clear(registeredRequests)
    generation += 1
    core = nil
    table.clear(listeners)
    initialized = false
end

return PartyService
