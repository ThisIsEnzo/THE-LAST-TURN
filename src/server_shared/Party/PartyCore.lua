--!strict
-- Pure party rules and state (no Roblox services; unit tested with Lune). Players are plain UserId numbers.
-- PartyService (HUB) wraps this with Roblox events, networking and timers.
--
-- Model: every registered player is in exactly one party (solo party by default), max `maxPartySize`.
-- Members are kept in join order, so leadership transfer ("earliest joined remaining member") is deterministic.
-- Invitations are pending (inviter -> target) records owned by the inviter's party; they never imply membership
-- and are re-validated on acceptance.
--
-- Every mutating call returns a fresh Result. `affected` lists users whose party snapshot changed and
-- `endedInvites` lists invitations that ended (for notifications). Rejections may still carry endedInvites
-- (e.g. a lazily expired invitation).

export type Config = {
    maxPartySize: number,
    inviteTtlSeconds: number,
    maxPendingInvitesPerTarget: number,
    maxPendingInvitesPerInviter: number,
}

export type Invite = { id: number, inviter: number, target: number, partyId: string, expiresAt: number }
export type EndedInvite = { inviter: number, target: number, reason: string }
export type PartySnapshot = { id: string, leader: number, members: { number } }

export type Result = {
    ok: boolean,
    changed: boolean,
    rejection: string?,
    partyId: string?,
    invite: Invite?,
    affected: { number },
    endedInvites: { EndedInvite },
}

type Party = { id: string, leader: number, members: { number } }

type StoreData = {
    _config: Config,
    _clock: () -> number,
    _parties: { [string]: Party },
    _memberOf: { [number]: string },
    _invitesById: { [number]: Invite },
    _invitesByTarget: { [number]: { [number]: Invite } }, -- target -> inviter -> invite
    _invitesByInviter: { [number]: { [number]: Invite } }, -- inviter -> target -> invite
    _nextPartyNumber: number,
    _nextInviteId: number,
}

local PartyCore = {}

local Store = {}
Store.__index = Store

export type Store = typeof(setmetatable({} :: StoreData, Store))

local function isPositiveFinite(value: any): boolean
    return type(value) == "number" and value == value and value > 0 and value ~= math.huge
end

local function isPositiveInteger(value: any): boolean
    return isPositiveFinite(value) and (value :: number) % 1 == 0
end

function PartyCore.new(config: Config, clock: () -> number): Store
    if not isPositiveInteger(config.maxPartySize) then
        error("PartyCore: maxPartySize must be a positive integer", 2)
    end
    if not isPositiveFinite(config.inviteTtlSeconds) then
        error("PartyCore: inviteTtlSeconds must be a finite number > 0", 2)
    end
    if not isPositiveInteger(config.maxPendingInvitesPerTarget) then
        error("PartyCore: maxPendingInvitesPerTarget must be a positive integer", 2)
    end
    if not isPositiveInteger(config.maxPendingInvitesPerInviter) then
        error("PartyCore: maxPendingInvitesPerInviter must be a positive integer", 2)
    end
    if type(clock) ~= "function" then
        error("PartyCore: clock function is required", 2)
    end
    return setmetatable({
        _config = {
            maxPartySize = config.maxPartySize,
            inviteTtlSeconds = config.inviteTtlSeconds,
            maxPendingInvitesPerTarget = config.maxPendingInvitesPerTarget,
            maxPendingInvitesPerInviter = config.maxPendingInvitesPerInviter,
        },
        _clock = clock,
        _parties = {},
        _memberOf = {},
        _invitesById = {},
        _invitesByTarget = {},
        _invitesByInviter = {},
        _nextPartyNumber = 0,
        _nextInviteId = 0,
    }, Store)
end

local function newResult(): Result
    return { ok = true, changed = false, rejection = nil, partyId = nil, invite = nil, affected = {}, endedInvites = {} }
end

local function rejected(result: Result, reason: string): Result
    result.ok = false
    result.changed = false
    result.rejection = reason
    return result
end

local function touch(result: Result, userId: number)
    if not table.find(result.affected, userId) then
        table.insert(result.affected, userId)
    end
end

local function copyInvite(invite: Invite): Invite
    return {
        id = invite.id,
        inviter = invite.inviter,
        target = invite.target,
        partyId = invite.partyId,
        expiresAt = invite.expiresAt,
    }
end

local function removeInvite(self: Store, invite: Invite, reason: string, result: Result)
    self._invitesById[invite.id] = nil
    local byTarget = self._invitesByTarget[invite.target]
    if byTarget then
        byTarget[invite.inviter] = nil
        if next(byTarget) == nil then
            self._invitesByTarget[invite.target] = nil
        end
    end
    local byInviter = self._invitesByInviter[invite.inviter]
    if byInviter then
        byInviter[invite.target] = nil
        if next(byInviter) == nil then
            self._invitesByInviter[invite.inviter] = nil
        end
    end
    table.insert(result.endedInvites, { inviter = invite.inviter, target = invite.target, reason = reason })
end

local function cancelInvitesFrom(self: Store, inviterId: number, reason: string, result: Result)
    local byInviter = self._invitesByInviter[inviterId]
    if byInviter then
        local list: { Invite } = {}
        for _, invite in pairs(byInviter) do
            table.insert(list, invite)
        end
        for _, invite in ipairs(list) do
            removeInvite(self, invite, reason, result)
        end
    end
end

local function cancelInvitesTo(self: Store, targetId: number, reason: string, result: Result)
    local byTarget = self._invitesByTarget[targetId]
    if byTarget then
        local list: { Invite } = {}
        for _, invite in pairs(byTarget) do
            table.insert(list, invite)
        end
        for _, invite in ipairs(list) do
            removeInvite(self, invite, reason, result)
        end
    end
end

local function purgeExpired(self: Store, invites: { [number]: Invite }?, result: Result)
    if invites == nil then
        return
    end
    local now = self._clock()
    local expired: { Invite } = {}
    for _, invite in pairs(invites) do
        if now >= invite.expiresAt then
            table.insert(expired, invite)
        end
    end
    for _, invite in ipairs(expired) do
        removeInvite(self, invite, "expired", result)
    end
end

local function createSoloParty(self: Store, userId: number): Party
    self._nextPartyNumber += 1
    local party: Party = { id = "P" .. self._nextPartyNumber, leader = userId, members = { userId } }
    self._parties[party.id] = party
    self._memberOf[userId] = party.id
    return party
end

-- Removes a user from their party: transfers leadership to the earliest-joined remaining member, destroys an
-- empty party, cancels invitations the user issued, and marks remaining members as affected.
local function detachFromParty(self: Store, userId: number, result: Result)
    local partyId = self._memberOf[userId]
    if partyId == nil then
        return
    end
    local party = self._parties[partyId]
    self._memberOf[userId] = nil
    cancelInvitesFrom(self, userId, "cancelled", result)
    if party == nil then
        return
    end
    local index = table.find(party.members, userId)
    if index then
        table.remove(party.members, index)
    end
    if #party.members == 0 then
        self._parties[partyId] = nil
        return
    end
    if party.leader == userId then
        party.leader = party.members[1]
    end
    for _, memberId in ipairs(party.members) do
        touch(result, memberId)
    end
end

function Store.isRegistered(self: Store, userId: number): boolean
    return self._memberOf[userId] ~= nil
end

-- Registers a connected player into a new solo party.
function Store.addPlayer(self: Store, userId: number): Result
    local result = newResult()
    if self._memberOf[userId] ~= nil then
        return rejected(result, "already_registered")
    end
    local party = createSoloParty(self, userId)
    result.changed = true
    result.partyId = party.id
    touch(result, userId)
    return result
end

-- Disconnect cleanup. Idempotent: unknown users yield ok with changed = false.
function Store.removePlayer(self: Store, userId: number): Result
    local result = newResult()
    if self._memberOf[userId] == nil then
        return result
    end
    detachFromParty(self, userId, result)
    cancelInvitesTo(self, userId, "cancelled", result)
    result.changed = true
    return result
end

function Store.invite(self: Store, inviterId: number, targetId: number): Result
    local result = newResult()
    if self._memberOf[inviterId] == nil then
        return rejected(result, "unknown_player")
    end
    if self._memberOf[targetId] == nil then
        return rejected(result, "unknown_target")
    end
    if inviterId == targetId then
        return rejected(result, "cannot_invite_self")
    end
    local party = self._parties[self._memberOf[inviterId]]
    if party.leader ~= inviterId then
        return rejected(result, "not_leader")
    end
    if self._memberOf[targetId] == party.id then
        return rejected(result, "already_in_party")
    end
    if #party.members >= self._config.maxPartySize then
        return rejected(result, "party_full")
    end

    -- Drop expired records first so they neither block duplicates nor count toward the caps.
    purgeExpired(self, self._invitesByInviter[inviterId], result)
    purgeExpired(self, self._invitesByTarget[targetId], result)

    local existing = self._invitesByInviter[inviterId] and self._invitesByInviter[inviterId][targetId]
    if existing then
        return rejected(result, "already_invited")
    end
    local function count(map: { [number]: Invite }?): number
        local n = 0
        if map then
            for _ in pairs(map) do
                n += 1
            end
        end
        return n
    end
    if
        count(self._invitesByTarget[targetId]) >= self._config.maxPendingInvitesPerTarget
        or count(self._invitesByInviter[inviterId]) >= self._config.maxPendingInvitesPerInviter
    then
        return rejected(result, "too_many_invites")
    end

    self._nextInviteId += 1
    local invite: Invite = {
        id = self._nextInviteId,
        inviter = inviterId,
        target = targetId,
        partyId = party.id,
        expiresAt = self._clock() + self._config.inviteTtlSeconds,
    }
    self._invitesById[invite.id] = invite
    local byTarget = self._invitesByTarget[targetId]
    if byTarget == nil then
        byTarget = {}
        self._invitesByTarget[targetId] = byTarget
    end
    byTarget[inviterId] = invite
    local byInviter = self._invitesByInviter[inviterId]
    if byInviter == nil then
        byInviter = {}
        self._invitesByInviter[inviterId] = byInviter
    end
    byInviter[targetId] = invite

    result.changed = true
    result.partyId = party.id
    result.invite = copyInvite(invite)
    return result
end

function Store.respondToInvite(self: Store, targetId: number, inviterId: number, accept: boolean): Result
    local result = newResult()
    if self._memberOf[targetId] == nil then
        return rejected(result, "unknown_player")
    end
    local byTarget = self._invitesByTarget[targetId]
    local invite = byTarget and byTarget[inviterId]
    if invite == nil then
        return rejected(result, "no_invite")
    end

    if self._clock() >= invite.expiresAt then
        removeInvite(self, invite, "expired", result)
        return rejected(result, "invite_expired")
    end

    -- An invitation is never proof of membership: the inviter must still lead the inviting party.
    local inviterPartyId = self._memberOf[inviterId]
    local party = inviterPartyId and self._parties[inviterPartyId]
    if party == nil or party.id ~= invite.partyId or party.leader ~= inviterId then
        removeInvite(self, invite, "cancelled", result)
        return rejected(result, "invite_invalid")
    end

    if not accept then
        removeInvite(self, invite, "declined", result)
        result.changed = true
        return result
    end

    local currentParty = self._parties[self._memberOf[targetId]]
    if #currentParty.members > 1 then
        return rejected(result, "target_in_party") -- would silently move a multi-member party member
    end
    if #party.members >= self._config.maxPartySize then
        return rejected(result, "party_full") -- capacity re-validated at acceptance time
    end

    detachFromParty(self, targetId, result) -- destroys the target's solo party, cancels their own invites
    removeInvite(self, invite, "accepted", result)
    cancelInvitesTo(self, targetId, "superseded", result)
    table.insert(party.members, targetId)
    self._memberOf[targetId] = party.id
    for _, memberId in ipairs(party.members) do
        touch(result, memberId)
    end
    result.changed = true
    result.partyId = party.id
    return result
end

-- Leaves the current party and becomes leader of a new solo party. Solo players: ok, changed = false.
function Store.leave(self: Store, userId: number): Result
    local result = newResult()
    local partyId = self._memberOf[userId]
    if partyId == nil then
        return rejected(result, "unknown_player")
    end
    if #self._parties[partyId].members <= 1 then
        result.partyId = partyId
        return result
    end
    detachFromParty(self, userId, result)
    local solo = createSoloParty(self, userId)
    touch(result, userId)
    result.changed = true
    result.partyId = solo.id
    return result
end

function Store.kick(self: Store, leaderId: number, targetId: number): Result
    local result = newResult()
    if self._memberOf[leaderId] == nil then
        return rejected(result, "unknown_player")
    end
    if self._memberOf[targetId] == nil then
        return rejected(result, "unknown_target")
    end
    if leaderId == targetId then
        return rejected(result, "cannot_kick_self")
    end
    local party = self._parties[self._memberOf[leaderId]]
    if party.leader ~= leaderId then
        return rejected(result, "not_leader")
    end
    if self._memberOf[targetId] ~= party.id then
        return rejected(result, "not_in_same_party")
    end
    detachFromParty(self, targetId, result)
    local solo = createSoloParty(self, targetId)
    touch(result, targetId)
    result.changed = true
    result.partyId = solo.id
    return result
end

-- Expires one invitation if its time has come (timer callback). Returns a Result with endedInvites.
function Store.expireInvite(self: Store, inviteId: number): Result
    local result = newResult()
    local invite = self._invitesById[inviteId]
    if invite == nil then
        return result
    end
    if self._clock() < invite.expiresAt then
        return rejected(result, "not_expired")
    end
    removeInvite(self, invite, "expired", result)
    result.changed = true
    return result
end

local function snapshotOf(party: Party): PartySnapshot
    return { id = party.id, leader = party.leader, members = table.clone(party.members) }
end

function Store.getPartyOf(self: Store, userId: number): PartySnapshot?
    local partyId = self._memberOf[userId]
    local party = partyId and self._parties[partyId]
    return party and snapshotOf(party) or nil
end

function Store.getPartyById(self: Store, partyId: string): PartySnapshot?
    local party = self._parties[partyId]
    return party and snapshotOf(party) or nil
end

-- Pending (unexpired) invitations addressed to a user, as copies.
function Store.getInvitesFor(self: Store, userId: number): { Invite }
    local list: { Invite } = {}
    local now = self._clock()
    for _, invite in pairs(self._invitesByTarget[userId] or {}) do
        if now < invite.expiresAt then
            table.insert(list, copyInvite(invite))
        end
    end
    table.sort(list, function(a: Invite, b: Invite)
        return a.id < b.id
    end)
    return list
end

local function countKeys(map: { [any]: any }): number
    local n = 0
    for _ in pairs(map) do
        n += 1
    end
    return n
end

function Store.getPartyCount(self: Store): number
    return countKeys(self._parties)
end

function Store.getPlayerCount(self: Store): number
    return countKeys(self._memberOf)
end

function Store.getInviteCount(self: Store): number
    return countKeys(self._invitesById)
end

-- Consistency check used by tests: no orphaned parties, memberships or invitations.
function Store.validateInvariants(self: Store): (boolean, string?)
    local memberships = 0
    for partyId, party in pairs(self._parties) do
        if party.id ~= partyId then
            return false, "party id mismatch " .. partyId
        end
        if #party.members < 1 or #party.members > self._config.maxPartySize then
            return false, "party size out of range " .. partyId
        end
        if not table.find(party.members, party.leader) then
            return false, "leader is not a member " .. partyId
        end
        local seen: { [number]: boolean } = {}
        for _, memberId in ipairs(party.members) do
            if seen[memberId] then
                return false, "duplicate member in " .. partyId
            end
            seen[memberId] = true
            if self._memberOf[memberId] ~= partyId then
                return false, "member points elsewhere " .. tostring(memberId)
            end
            memberships += 1
        end
    end
    for userId, partyId in pairs(self._memberOf) do
        local party = self._parties[partyId]
        if party == nil or not table.find(party.members, userId) then
            return false, "orphaned membership " .. tostring(userId)
        end
    end
    if memberships ~= countKeys(self._memberOf) then
        return false, "membership count mismatch"
    end
    local targetEntries, inviterEntries = 0, 0
    for _, byInviter in pairs(self._invitesByTarget) do
        targetEntries += countKeys(byInviter)
    end
    for _, byTarget in pairs(self._invitesByInviter) do
        inviterEntries += countKeys(byTarget)
    end
    local total = countKeys(self._invitesById)
    if targetEntries ~= total or inviterEntries ~= total then
        return false, "invite index mismatch"
    end
    for _, invite in pairs(self._invitesById) do
        if self._memberOf[invite.inviter] == nil or self._memberOf[invite.target] == nil then
            return false, "invite references unknown player"
        end
        local byTarget = self._invitesByTarget[invite.target]
        local byInviter = self._invitesByInviter[invite.inviter]
        if not (byTarget and byTarget[invite.inviter] == invite and byInviter and byInviter[invite.target] == invite) then
            return false, "invite index inconsistent"
        end
        if self._parties[invite.partyId] == nil then
            return false, "invite references missing party"
        end
    end
    return true, nil
end

return PartyCore
