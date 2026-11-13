--!strict
-- Client-side MIRROR of the server's party state plus the UI-only bookkeeping around it (pure, Lune-tested).
-- The server (PartyService/PartyCore) stays the only source of truth: this module never decides who the leader is, who
-- may kick or invite, or what a party contains. It stores the latest PartySnapshot / invite notifications, derives a view
-- model for rendering, derives change events for toasts, and guards against duplicate clicks and stale UI. Every
-- `can...` method is a UI hint that hides or disables controls; the server re-validates every request.
--
-- Time is injected (`now`, seconds, any monotonic client clock). Nothing here polls or schedules anything.

local PartyView = {}

-- UX constants (client side only; the server's own TTLs and limits are authoritative).
PartyView.OutgoingInviteFallbackSeconds = 75 -- mirrors the server's 60 s invite TTL plus margin; frees a stuck "Invited" state
PartyView.ResponseTimeoutSeconds = 8 -- an Accept/Decline click without any server reaction becomes clickable again
PartyView.ActionLockSeconds = 2 -- blocks double clicks on invite / kick / leave
PartyView.ExpiredGraceSeconds = 5 -- an invite whose countdown ended waits this long for the server's "expired" notification

export type Member = { userId: number, displayName: string }

export type Event = {
    type: string, -- member_joined | member_left | leader_changed | joined_party | left_party
    userId: number?,
    displayName: string?,
    isLocal: boolean?,
}

export type MemberView = {
    userId: number,
    displayName: string,
    isLocal: boolean,
    isLeader: boolean,
    canKick: boolean,
}

export type IncomingInviteView = {
    inviterUserId: number,
    displayName: string,
    secondsRemaining: number?, -- nil when the server did not tell us how long the invitation lasts
    state: string, -- pending | responding | expired
}

export type ViewModel = {
    hasParty: boolean,
    partyId: string?,
    size: number,
    maxSize: number,
    isSolo: boolean,
    isFull: boolean,
    localIsLeader: boolean,
    leaderUserId: number?,
    members: { MemberView },
    canInvite: boolean,
    canLeave: boolean,
    incomingInvites: { IncomingInviteView },
}

export type Candidate = {
    userId: number,
    displayName: string,
    state: string, -- available | member | invited | blocked_not_leader | blocked_full | busy
}

type Snapshot = {
    partyId: string,
    leaderUserId: number,
    members: { Member },
}

type IncomingRecord = {
    inviterUserId: number,
    displayName: string,
    receivedAt: number,
    expiresInSeconds: number?,
    state: string, -- pending | responding
    respondingSince: number?,
}

type PartyViewData = {
    _localUserId: number,
    _maxPartySize: number,
    _party: Snapshot?,
    _incoming: { [number]: IncomingRecord },
    _outgoing: { [number]: number }, -- targetUserId -> sentAt
    _locks: { [string]: number }, -- action key -> locked until
}

local PartyViewClass = {}
PartyViewClass.__index = PartyViewClass

export type PartyView = typeof(setmetatable({} :: PartyViewData, PartyViewClass))

local function isFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isUserId(value: any): boolean
    return isFiniteNumber(value) and value > 0 and value % 1 == 0
end

local function cleanName(value: any): string
    if type(value) == "string" and #value > 0 then
        return value
    end
    return "Player"
end

function PartyView.new(localUserId: number, maxPartySize: number): PartyView
    if not isUserId(localUserId) then
        error("PartyView.new: localUserId must be a positive integer", 2)
    end
    if not isFiniteNumber(maxPartySize) or maxPartySize < 1 or maxPartySize % 1 ~= 0 then
        error("PartyView.new: maxPartySize must be a positive integer", 2)
    end
    return setmetatable({
        _localUserId = localUserId,
        _maxPartySize = maxPartySize,
        _party = nil,
        _incoming = {},
        _outgoing = {},
        _locks = {},
    }, PartyViewClass)
end

-- Validates a PartySnapshot payload. Returns the cleaned snapshot, or nil if malformed.
local function parseSnapshot(payload: any, localUserId: number): Snapshot?
    if type(payload) ~= "table" or type(payload.partyId) ~= "string" or #payload.partyId < 1 then
        return nil
    end
    if not isUserId(payload.leaderUserId) or type(payload.members) ~= "table" then
        return nil
    end
    local members: { Member } = {}
    local seen: { [number]: boolean } = {}
    local count = 0
    for key in pairs(payload.members) do
        if type(key) ~= "number" then
            return nil
        end
        count += 1
    end
    for index = 1, count do
        local entry = payload.members[index]
        if type(entry) ~= "table" or not isUserId(entry.userId) or seen[entry.userId] then
            return nil
        end
        seen[entry.userId] = true
        members[index] = { userId = entry.userId, displayName = cleanName(entry.displayName) }
    end
    if count < 1 or not seen[payload.leaderUserId] or not seen[localUserId] then
        return nil
    end
    return { partyId = payload.partyId, leaderUserId = payload.leaderUserId, members = members }
end

local function memberMap(snapshot: Snapshot): { [number]: Member }
    local map: { [number]: Member } = {}
    for _, member in ipairs(snapshot.members) do
        map[member.userId] = member
    end
    return map
end

-- Applies a PartySnapshot notification. Returns (accepted, events). A malformed snapshot is ignored (accepted = false).
function PartyViewClass.applySnapshot(self: PartyView, payload: any, now: number): (boolean, { Event })
    local data = self :: any
    local snapshot = parseSnapshot(payload, data._localUserId)
    if snapshot == nil then
        return false, {}
    end

    local events: { Event } = {}
    local previous: Snapshot? = data._party
    if previous ~= nil then
        if previous.partyId ~= snapshot.partyId then
            if #snapshot.members == 1 and #previous.members > 1 then
                table.insert(events, { type = "left_party" })
            else
                table.insert(events, { type = "joined_party" })
            end
        else
            local before, after = memberMap(previous), memberMap(snapshot)
            for _, member in ipairs(previous.members) do
                if after[member.userId] == nil then
                    table.insert(events, { type = "member_left", userId = member.userId, displayName = member.displayName })
                end
            end
            for _, member in ipairs(snapshot.members) do
                if before[member.userId] == nil then
                    table.insert(events, { type = "member_joined", userId = member.userId, displayName = member.displayName })
                end
            end
            if previous.leaderUserId ~= snapshot.leaderUserId then
                local leader = after[snapshot.leaderUserId]
                table.insert(events, {
                    type = "leader_changed",
                    userId = snapshot.leaderUserId,
                    displayName = leader.displayName,
                    isLocal = snapshot.leaderUserId == data._localUserId,
                })
            end
        end
    end
    data._party = snapshot

    -- A snapshot carries the full list of this player's pending invitations: it is authoritative for that list.
    if type(payload.pendingInvites) == "table" then
        local present: { [number]: boolean } = {}
        for _, entry in ipairs(payload.pendingInvites) do
            if type(entry) == "table" and isUserId(entry.inviterUserId) and entry.inviterUserId ~= data._localUserId then
                present[entry.inviterUserId] = true
                if data._incoming[entry.inviterUserId] == nil then
                    data._incoming[entry.inviterUserId] = {
                        inviterUserId = entry.inviterUserId,
                        displayName = cleanName(entry.inviterDisplayName),
                        receivedAt = now,
                        expiresInSeconds = nil,
                        state = "pending",
                        respondingSince = nil,
                    }
                end
            end
        end
        for inviter in pairs(data._incoming) do
            if not present[inviter] then
                data._incoming[inviter] = nil
            end
        end
    end

    -- Membership changed: kick/leave clicks have had their effect (or not); free those locks.
    for key in pairs(data._locks) do
        if key == "leave" or string.sub(key, 1, 5) == "kick:" then
            data._locks[key] = nil
        end
    end
    return true, events
end

-- Applies a PartyInviteReceived notification (the only message that carries the invitation's remaining lifetime).
function PartyViewClass.applyInviteReceived(self: PartyView, payload: any, now: number): boolean
    local data = self :: any
    if type(payload) ~= "table" or not isUserId(payload.inviterUserId) or payload.inviterUserId == data._localUserId then
        return false
    end
    local expires: number? = nil
    if isFiniteNumber(payload.expiresInSeconds) and payload.expiresInSeconds > 0 then
        expires = payload.expiresInSeconds
    end
    data._incoming[payload.inviterUserId] = {
        inviterUserId = payload.inviterUserId,
        displayName = cleanName(payload.inviterDisplayName),
        receivedAt = now,
        expiresInSeconds = expires,
        state = "pending",
        respondingSince = nil,
    }
    return true
end

-- Applies a PartyInviteEnded notification. Returns (accepted, events); the event describes how the invitation ended
-- from this player's point of view: { type = "invite_ended", role = "target" | "inviter", userId = other, reason = ... }.
function PartyViewClass.applyInviteEnded(self: PartyView, payload: any, now: number): (boolean, { { [string]: any } })
    local data = self :: any
    if type(payload) ~= "table" or not isUserId(payload.inviterUserId) or not isUserId(payload.targetUserId) or type(payload.reason) ~= "string" then
        return false, {}
    end
    local events: { { [string]: any } } = {}
    if payload.targetUserId == data._localUserId then
        local record = data._incoming[payload.inviterUserId]
        data._incoming[payload.inviterUserId] = nil
        table.insert(events, {
            type = "invite_ended",
            role = "target",
            userId = payload.inviterUserId,
            displayName = record and record.displayName or nil,
            reason = payload.reason,
        })
    elseif payload.inviterUserId == data._localUserId then
        data._outgoing[payload.targetUserId] = nil
        table.insert(events, { type = "invite_ended", role = "inviter", userId = payload.targetUserId, reason = payload.reason })
    end
    return true, events
end

-- Clears optimistic outgoing state when the server rejects an invite or confirms its outcome.
function PartyViewClass.clearOutgoingInvite(self: PartyView, targetUserId: number)
    local data = self :: any
    data._outgoing[targetUserId] = nil
    data._locks["invite:" .. tostring(targetUserId)] = nil
end

-- A rejected accept/decline returns the invitation row to an actionable state immediately.
function PartyViewClass.resetResponding(self: PartyView, inviterUserId: number): boolean
    local data = self :: any
    local record = data._incoming[inviterUserId]
    if record == nil or record.state ~= "responding" then
        return false
    end
    record.state = "pending"
    record.respondingSince = nil
    return true
end

-- Locks ------------------------------------------------------------------------------------------------------------

local function isLocked(data: any, key: string, now: number): boolean
    local untilTime = data._locks[key]
    return untilTime ~= nil and now < untilTime
end

local function lock(data: any, key: string, now: number)
    data._locks[key] = now + PartyView.ActionLockSeconds
end

-- Queries (UI hints only) ----------------------------------------------------------------------------------------------

local function localIsLeader(data: any): boolean
    local party: Snapshot? = data._party
    return party ~= nil and party.leaderUserId == data._localUserId
end

local function partySize(data: any): number
    local party: Snapshot? = data._party
    if party == nil then
        return 0
    end
    return #party.members
end

local function outgoingPending(data: any, targetUserId: number, now: number): boolean
    local sentAt = data._outgoing[targetUserId]
    return sentAt ~= nil and now - sentAt < PartyView.OutgoingInviteFallbackSeconds
end

-- Returns (true, nil) or (false, reason) with reason one of not_leader, party_full, self, already_in_party, already_invited, busy.
function PartyViewClass.canInvite(self: PartyView, targetUserId: any, now: number): (boolean, string?)
    local data = self :: any
    if not isUserId(targetUserId) or targetUserId == data._localUserId then
        return false, "self"
    end
    if not localIsLeader(data) then
        return false, "not_leader"
    end
    local party: Snapshot = data._party
    for _, member in ipairs(party.members) do
        if member.userId == targetUserId then
            return false, "already_in_party"
        end
    end
    if #party.members >= data._maxPartySize then
        return false, "party_full"
    end
    if outgoingPending(data, targetUserId, now) then
        return false, "already_invited"
    end
    if isLocked(data, "invite:" .. tostring(targetUserId), now) then
        return false, "busy"
    end
    return true, nil
end

-- Records that an invitation request was sent (call right after firing the request). Returns false if it was not allowed.
function PartyViewClass.markInviteSent(self: PartyView, targetUserId: any, now: number): boolean
    local data = self :: any
    local allowed = self:canInvite(targetUserId, now)
    if not allowed then
        return false
    end
    data._outgoing[targetUserId] = now
    lock(data, "invite:" .. tostring(targetUserId), now)
    return true
end

function PartyViewClass.canRespond(self: PartyView, inviterUserId: any, now: number): boolean
    local data = self :: any
    local record = data._incoming[inviterUserId]
    if record == nil then
        return false
    end
    if record.state == "responding" and record.respondingSince ~= nil and now - record.respondingSince < PartyView.ResponseTimeoutSeconds then
        return false
    end
    return true
end

-- Marks an Accept/Decline click as in flight (the invitation row shows "responding" and ignores further clicks).
function PartyViewClass.markResponding(self: PartyView, inviterUserId: any, now: number): boolean
    local data = self :: any
    if not self:canRespond(inviterUserId, now) then
        return false
    end
    local record = data._incoming[inviterUserId]
    record.state = "responding"
    record.respondingSince = now
    return true
end

function PartyViewClass.canKick(self: PartyView, targetUserId: any, now: number): boolean
    local data = self :: any
    local party: Snapshot? = data._party
    if party == nil or not localIsLeader(data) or not isUserId(targetUserId) or targetUserId == data._localUserId then
        return false
    end
    for _, member in ipairs(party.members) do
        if member.userId == targetUserId then
            return not isLocked(data, "kick:" .. tostring(targetUserId), now)
        end
    end
    return false
end

function PartyViewClass.markKickSent(self: PartyView, targetUserId: any, now: number): boolean
    local data = self :: any
    if not self:canKick(targetUserId, now) then
        return false
    end
    lock(data, "kick:" .. tostring(targetUserId), now)
    return true
end

function PartyViewClass.canLeave(self: PartyView, now: number): boolean
    local data = self :: any
    return partySize(data) > 1 and not isLocked(data, "leave", now)
end

function PartyViewClass.markLeaveSent(self: PartyView, now: number): boolean
    local data = self :: any
    if not self:canLeave(now) then
        return false
    end
    lock(data, "leave", now)
    return true
end

function PartyViewClass.isLeader(self: PartyView): boolean
    return localIsLeader(self :: any)
end

function PartyViewClass.getPartyId(self: PartyView): string?
    local party: Snapshot? = (self :: any)._party
    if party == nil then
        return nil
    end
    return party.partyId
end

-- View model ---------------------------------------------------------------------------------------------------------

-- Everything the UI renders, derived from the mirrored state. Expired invitations are dropped after a short grace period
-- even if the server's "expired" notification never arrives, so the UI cannot show a stale invitation forever.
function PartyViewClass.getViewModel(self: PartyView, now: number): ViewModel
    local data = self :: any
    local party: Snapshot? = data._party
    local invites: { IncomingInviteView } = {}
    local ordered: { IncomingRecord } = {}
    for _, record in pairs(data._incoming) do
        table.insert(ordered, record)
    end
    table.sort(ordered, function(a: IncomingRecord, b: IncomingRecord): boolean
        if a.receivedAt ~= b.receivedAt then
            return a.receivedAt < b.receivedAt
        end
        return a.inviterUserId < b.inviterUserId
    end)
    for _, record in ipairs(ordered) do
        local remaining: number? = nil
        local state = record.state
        if record.expiresInSeconds ~= nil then
            remaining = record.expiresInSeconds - (now - record.receivedAt)
        end
        local keep = true
        if remaining ~= nil and remaining <= 0 then
            if remaining <= -PartyView.ExpiredGraceSeconds then
                keep = false
            else
                state = "expired"
                remaining = 0
            end
        elseif state == "responding" and record.respondingSince ~= nil and now - record.respondingSince >= PartyView.ResponseTimeoutSeconds then
            state = "pending" -- no reaction from the server: let the player try again
        end
        if keep then
            table.insert(invites, { inviterUserId = record.inviterUserId, displayName = record.displayName, secondsRemaining = remaining, state = state })
        end
    end

    if party == nil then
        return {
            hasParty = false,
            partyId = nil,
            size = 0,
            maxSize = data._maxPartySize,
            isSolo = false,
            isFull = false,
            localIsLeader = false,
            leaderUserId = nil,
            members = {},
            canInvite = false,
            canLeave = false,
            incomingInvites = invites,
        }
    end

    local leader = localIsLeader(data)
    local members: { MemberView } = {}
    local function add(member: Member)
        table.insert(members, {
            userId = member.userId,
            displayName = member.displayName,
            isLocal = member.userId == data._localUserId,
            isLeader = member.userId == party.leaderUserId,
            canKick = self:canKick(member.userId, now),
        })
    end
    for _, member in ipairs(party.members) do
        if member.userId == party.leaderUserId then
            add(member)
        end
    end
    for _, member in ipairs(party.members) do
        if member.userId ~= party.leaderUserId then
            add(member)
        end
    end
    local size = #party.members
    return {
        hasParty = true,
        partyId = party.partyId,
        size = size,
        maxSize = data._maxPartySize,
        isSolo = size == 1,
        isFull = size >= data._maxPartySize,
        localIsLeader = leader,
        leaderUserId = party.leaderUserId,
        members = members,
        canInvite = leader and size < data._maxPartySize,
        canLeave = self:canLeave(now),
        incomingInvites = invites,
    }
end

-- Other players currently in the HUB (supplied by the UI from the client's Players list) with their invitability.
-- Candidates are only a UI list: the server validates every invitation.
function PartyViewClass.getCandidates(self: PartyView, players: { Member }, now: number): { Candidate }
    local data = self :: any
    local party: Snapshot? = data._party
    local inParty: { [number]: boolean } = {}
    if party ~= nil then
        for _, member in ipairs(party.members) do
            inParty[member.userId] = true
        end
    end
    local result: { Candidate } = {}
    for _, player in ipairs(players) do
        if isUserId(player.userId) and player.userId ~= data._localUserId then
            local state = "available"
            if inParty[player.userId] then
                state = "member"
            elseif outgoingPending(data, player.userId, now) then
                state = "invited"
            elseif not localIsLeader(data) then
                state = "blocked_not_leader"
            elseif partySize(data) >= data._maxPartySize then
                state = "blocked_full"
            elseif isLocked(data, "invite:" .. tostring(player.userId), now) then
                state = "busy"
            end
            table.insert(result, { userId = player.userId, displayName = cleanName(player.displayName), state = state })
        end
    end
    table.sort(result, function(a: Candidate, b: Candidate): boolean
        local nameA, nameB = string.lower(a.displayName), string.lower(b.displayName)
        if nameA ~= nameB then
            return nameA < nameB
        end
        return a.userId < b.userId
    end)
    return result
end

-- Seconds until the view model next changes by itself (an invitation countdown or grace period), or nil if nothing is
-- time dependent. The UI schedules ONE delayed refresh from this instead of polling.
function PartyViewClass.nextRefreshIn(self: PartyView, now: number): number?
    local data = self :: any
    local soonest: number? = nil
    local function consider(delta: number)
        if delta < 0.05 then
            delta = 0.05
        end
        if soonest == nil or delta < soonest then
            soonest = delta
        end
    end
    for _, record in pairs(data._incoming) do
        if record.expiresInSeconds ~= nil then
            local remaining = record.expiresInSeconds - (now - record.receivedAt)
            if remaining > 0 then
                consider(1) -- countdown label: refresh once per second while an invitation is visible
            elseif remaining > -PartyView.ExpiredGraceSeconds then
                consider(remaining + PartyView.ExpiredGraceSeconds) -- when the expired invitation is finally dropped
            end
        end
        if record.state == "responding" and record.respondingSince ~= nil then
            local left = PartyView.ResponseTimeoutSeconds - (now - record.respondingSince)
            if left > 0 then
                consider(left)
            end
        end
    end
    for _, sentAt in pairs(data._outgoing) do
        local left = PartyView.OutgoingInviteFallbackSeconds - (now - sentAt)
        if left > 0 then
            consider(left)
        end
    end
    for _, untilTime in pairs(data._locks) do
        local left = untilTime - now
        if left > 0 then
            consider(left)
        end
    end
    return soonest
end

return PartyView
