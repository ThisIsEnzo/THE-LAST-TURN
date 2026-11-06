--!strict
local Harness = require("../Harness")
local PartyCore = require("../../src/server_shared/Party/PartyCore")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local function newStore(overrides: { [string]: number }?)
    local now = 0
    local config = {
        maxPartySize = 8,
        inviteTtlSeconds = 60,
        maxPendingInvitesPerTarget = 3,
        maxPendingInvitesPerInviter = 4,
    }
    for key, value in pairs(overrides or {}) do
        (config :: any)[key] = value
    end
    local store = PartyCore.new(config, function()
        return now
    end)
    local function advance(seconds: number)
        now += seconds
    end
    return store, advance
end

local function check(store: any)
    local ok, reason = store:validateInvariants()
    expectTrue(ok, "invariants: " .. tostring(reason))
end

local function join(store: any, ...: number)
    for _, userId in ipairs({ ... }) do
        expectTrue(store:addPlayer(userId).ok, "addPlayer " .. userId)
    end
end

-- Leader invites target and target accepts.
local function addToParty(store: any, leader: number, target: number)
    expectTrue(store:invite(leader, target).ok, "invite " .. leader .. "->" .. target)
    local result = store:respondToInvite(target, leader, true)
    expectTrue(result.ok, "accept " .. target .. " rejection=" .. tostring(result.rejection))
end

local function members(store: any, userId: number): { number }
    local snapshot = store:getPartyOf(userId)
    return snapshot and snapshot.members or {}
end

local function expectList(actual: { number }, expected: { number }, label: string?)
    expectEqual(table.concat(actual, ","), table.concat(expected, ","), label)
end

test("config and clock are validated", function()
    local clock = function()
        return 0
    end
    local good = { maxPartySize = 8, inviteTtlSeconds = 60, maxPendingInvitesPerTarget = 3, maxPendingInvitesPerInviter = 4 }
    PartyCore.new(good, clock)
    Harness.expectError(function()
        PartyCore.new({ maxPartySize = 0, inviteTtlSeconds = 60, maxPendingInvitesPerTarget = 1, maxPendingInvitesPerInviter = 1 }, clock)
    end)
    Harness.expectError(function()
        PartyCore.new({ maxPartySize = 8, inviteTtlSeconds = math.huge, maxPendingInvitesPerTarget = 1, maxPendingInvitesPerInviter = 1 }, clock)
    end)
    Harness.expectError(function()
        PartyCore.new({ maxPartySize = 8, inviteTtlSeconds = 0, maxPendingInvitesPerTarget = 1, maxPendingInvitesPerInviter = 1 }, clock)
    end)
    Harness.expectError(function()
        PartyCore.new(good, nil :: any)
    end)
end)

test("solo party creation: new player leads a party of one", function()
    local store = newStore()
    local result = store:addPlayer(1)
    expectTrue(result.ok)
    expectTrue(result.changed)
    local party = store:getPartyOf(1)
    expectTrue(party ~= nil)
    expectEqual((party :: any).leader, 1)
    expectList((party :: any).members, { 1 })
    expectEqual(result.partyId, (party :: any).id)
    expectList(result.affected, { 1 })
    check(store)
end)

test("parties get unique ids that are never reused", function()
    local store = newStore()
    join(store, 1, 2, 3)
    local ids: { [string]: boolean } = {}
    for _, userId in ipairs({ 1, 2, 3 }) do
        local id = (store:getPartyOf(userId) :: any).id
        expectFalse(ids[id] == true, "duplicate id " .. id)
        ids[id] = true
    end
    store:removePlayer(1)
    store:addPlayer(1)
    expectFalse(ids[(store:getPartyOf(1) :: any).id] == true, "id reused after party destruction")
    check(store)
end)

test("membership lookup by player and by id, in join order", function()
    local store = newStore()
    join(store, 1, 2, 3)
    addToParty(store, 1, 3)
    addToParty(store, 1, 2)
    local party = store:getPartyOf(1) :: any
    expectList(party.members, { 1, 3, 2 })
    expectEqual(store:getPartyById(party.id).leader, 1)
    expectEqual((store:getPartyOf(2) :: any).id, party.id)
    expectEqual(store:getPartyOf(99), nil)
    expectEqual(store:getPartyById("nope"), nil)
    check(store)
end)

test("snapshots are copies: mutating them does not change the party", function()
    local store = newStore()
    join(store, 1, 2)
    addToParty(store, 1, 2)
    local snapshot = store:getPartyOf(1) :: any
    table.insert(snapshot.members, 999)
    snapshot.leader = 999
    expectList(members(store, 1), { 1, 2 })
    expectEqual((store:getPartyOf(1) :: any).leader, 1)
    check(store)
end)

test("party capacity is 8 and a full party rejects invites", function()
    local store = newStore({ maxPendingInvitesPerInviter = 20 })
    join(store, 1, 2, 3, 4, 5, 6, 7, 8, 9)
    for userId = 2, 8 do
        addToParty(store, 1, userId)
    end
    expectEqual(#members(store, 1), 8)
    local result = store:invite(1, 9)
    expectFalse(result.ok)
    expectEqual(result.rejection, "party_full")
    expectEqual(store:getInviteCount(), 0)
    check(store)
end)

test("capacity is re-validated at acceptance time", function()
    local store = newStore({ maxPendingInvitesPerInviter = 20 })
    join(store, 1, 2, 3, 4, 5, 6, 7, 8, 9)
    for userId = 2, 7 do
        addToParty(store, 1, userId)
    end
    expectTrue(store:invite(1, 8).ok) -- size 7: both fit while pending
    expectTrue(store:invite(1, 9).ok)
    expectTrue(store:respondToInvite(8, 1, true).ok)
    local late = store:respondToInvite(9, 1, true)
    expectFalse(late.ok)
    expectEqual(late.rejection, "party_full")
    expectEqual(#members(store, 1), 8)
    expectEqual(#members(store, 9), 1, "rejected player keeps their solo party")
    expectEqual(store:getInviteCount(), 1, "invite kept; player may retry when space frees up")
    store:leave(2)
    expectTrue(store:respondToInvite(9, 1, true).ok)
    check(store)
end)

test("leader can invite; result describes the invitation", function()
    local store = newStore()
    join(store, 1, 2)
    local result = store:invite(1, 2)
    expectTrue(result.ok)
    expectTrue(result.changed)
    local invite = result.invite :: any
    expectEqual(invite.inviter, 1)
    expectEqual(invite.target, 2)
    expectEqual(invite.expiresAt, 60)
    expectEqual(#store:getInvitesFor(2), 1)
    expectEqual(#store:getInvitesFor(1), 0)
    expectList(members(store, 2), { 2 }, "invitation is not membership")
    check(store)
end)

test("non-leader cannot invite; invalid invites are rejected", function()
    local store = newStore()
    join(store, 1, 2, 3)
    addToParty(store, 1, 2)
    expectEqual(store:invite(2, 3).rejection, "not_leader")
    expectEqual(store:invite(1, 1).rejection, "cannot_invite_self")
    expectEqual(store:invite(1, 2).rejection, "already_in_party")
    expectEqual(store:invite(1, 99).rejection, "unknown_target")
    expectEqual(store:invite(99, 1).rejection, "unknown_player")
    expectEqual(store:getInviteCount(), 0)
    check(store)
end)

test("accepting an invitation moves a solo player and destroys their solo party", function()
    local store = newStore()
    join(store, 1, 2)
    local soloId = (store:getPartyOf(2) :: any).id
    expectTrue(store:invite(1, 2).ok)
    local result = store:respondToInvite(2, 1, true)
    expectTrue(result.ok)
    expectTrue(result.changed)
    expectEqual(result.endedInvites[1].reason, "accepted")
    expectList(members(store, 2), { 1, 2 })
    expectEqual(store:getPartyById(soloId), nil)
    expectEqual(store:getPartyCount(), 1)
    expectEqual(store:getInviteCount(), 0)
    expectList(result.affected, { 1, 2 })
    check(store)
end)

test("declining an invitation keeps the target solo and ends the invite", function()
    local store = newStore()
    join(store, 1, 2)
    store:invite(1, 2)
    local result = store:respondToInvite(2, 1, false)
    expectTrue(result.ok)
    expectEqual(result.endedInvites[1].reason, "declined")
    expectList(members(store, 2), { 2 })
    expectEqual(store:getInviteCount(), 0)
    expectEqual(store:respondToInvite(2, 1, true).rejection, "no_invite", "cannot accept after declining")
    check(store)
end)

test("expired invitations cannot be accepted and are removed", function()
    local store, advance = newStore()
    join(store, 1, 2)
    store:invite(1, 2)
    advance(59)
    expectEqual(#store:getInvitesFor(2), 1)
    advance(1)
    expectEqual(#store:getInvitesFor(2), 0, "expired invites are not listed")
    local result = store:respondToInvite(2, 1, true)
    expectFalse(result.ok)
    expectEqual(result.rejection, "invite_expired")
    expectEqual(result.endedInvites[1].reason, "expired")
    expectList(members(store, 2), { 2 })
    expectEqual(store:getInviteCount(), 0)
    check(store)
end)

test("expireInvite only expires when due and is idempotent", function()
    local store, advance = newStore()
    join(store, 1, 2)
    local id = (store:invite(1, 2).invite :: any).id
    expectEqual(store:expireInvite(id).rejection, "not_expired")
    expectEqual(store:getInviteCount(), 1)
    advance(60)
    local first = store:expireInvite(id)
    expectTrue(first.ok)
    expectEqual(first.endedInvites[1].reason, "expired")
    local second = store:expireInvite(id)
    expectTrue(second.ok)
    expectEqual(#second.endedInvites, 0)
    check(store)
end)

test("expired invitations do not block a new invitation or count toward caps", function()
    local store, advance = newStore({ maxPendingInvitesPerTarget = 1 })
    join(store, 1, 2, 3)
    expectTrue(store:invite(1, 2).ok)
    expectEqual(store:invite(1, 2).rejection, "already_invited")
    advance(61)
    local again = store:invite(1, 2)
    expectTrue(again.ok)
    expectEqual(again.endedInvites[1].reason, "expired")
    expectEqual(store:getInviteCount(), 1)
    check(store)
end)

test("duplicate and excessive invitations are rejected", function()
    local store = newStore() -- perTarget = 3, perInviter = 4
    join(store, 1, 2, 3, 4, 5, 20)
    expectTrue(store:invite(1, 20).ok)
    expectEqual(store:invite(1, 20).rejection, "already_invited")
    expectTrue(store:invite(2, 20).ok)
    expectTrue(store:invite(3, 20).ok)
    expectEqual(store:invite(4, 20).rejection, "too_many_invites")
    expectEqual(#store:getInvitesFor(20), 3)
    check(store)

    local store2 = newStore({ maxPendingInvitesPerInviter = 2 })
    join(store2, 1, 2, 3, 4)
    expectTrue(store2:invite(1, 2).ok)
    expectTrue(store2:invite(1, 3).ok)
    expectEqual(store2:invite(1, 4).rejection, "too_many_invites")
    check(store2)
end)

test("a player cannot be in two parties; accepting does not move a multi-member party member", function()
    local store = newStore()
    join(store, 1, 2, 3, 4)
    addToParty(store, 1, 2) -- party A: 1,2
    addToParty(store, 3, 4) -- party B: 3,4
    expectTrue(store:invite(1, 3).ok)
    local result = store:respondToInvite(3, 1, true)
    expectFalse(result.ok)
    expectEqual(result.rejection, "target_in_party")
    expectList(members(store, 3), { 3, 4 }, "party B untouched")
    expectList(members(store, 1), { 1, 2 }, "party A untouched")
    expectEqual(store:getPartyCount(), 2)
    -- After leaving, the same invitation can be accepted.
    store:leave(3)
    expectTrue(store:respondToInvite(3, 1, true).ok)
    expectList(members(store, 1), { 1, 2, 3 })
    expectList(members(store, 4), { 4 })
    for _, userId in ipairs({ 1, 2, 3, 4 }) do
        expectTrue(store:getPartyOf(userId) ~= nil)
    end
    check(store)
end)

test("accepting one of several invitations supersedes the others", function()
    local store = newStore()
    join(store, 1, 2, 3)
    store:invite(1, 3)
    store:invite(2, 3)
    local result = store:respondToInvite(3, 1, true)
    expectTrue(result.ok)
    local reasons: { string } = {}
    for _, ended in ipairs(result.endedInvites) do
        table.insert(reasons, ended.inviter .. ":" .. ended.reason)
    end
    table.sort(reasons)
    expectEqual(table.concat(reasons, ","), "1:accepted,2:superseded")
    expectEqual(store:respondToInvite(3, 2, true).rejection, "no_invite")
    expectEqual(store:getInviteCount(), 0)
    check(store)
end)

test("accepting cancels invitations the new member had issued while solo", function()
    local store = newStore()
    join(store, 1, 2, 3)
    store:invite(2, 3) -- 2 invites 3 (both solo)
    store:invite(1, 2)
    expectTrue(store:respondToInvite(2, 1, true).ok)
    expectEqual(store:getInviteCount(), 0)
    expectEqual(store:respondToInvite(3, 2, true).rejection, "no_invite")
    check(store)
end)

test("unknown players cannot respond; responding is safe when repeated", function()
    local store = newStore()
    join(store, 1, 2)
    expectEqual(store:respondToInvite(99, 1, true).rejection, "unknown_player")
    store:invite(1, 2)
    expectTrue(store:respondToInvite(2, 1, true).ok)
    local again = store:respondToInvite(2, 1, true)
    expectFalse(again.ok)
    expectEqual(again.rejection, "no_invite")
    expectList(members(store, 1), { 1, 2 })
    check(store)
end)

test("non-leader member leaves and gets a new solo party", function()
    local store = newStore()
    join(store, 1, 2, 3)
    addToParty(store, 1, 2)
    addToParty(store, 1, 3)
    local oldId = (store:getPartyOf(1) :: any).id
    local result = store:leave(3)
    expectTrue(result.ok)
    expectTrue(result.changed)
    expectList(members(store, 1), { 1, 2 })
    expectEqual((store:getPartyOf(1) :: any).leader, 1)
    local solo = store:getPartyOf(3) :: any
    expectList(solo.members, { 3 })
    expectEqual(solo.leader, 3)
    expectFalse(solo.id == oldId)
    expectEqual(result.partyId, solo.id)
    expectTrue(table.find(result.affected, 1) ~= nil and table.find(result.affected, 2) ~= nil and table.find(result.affected, 3) ~= nil)
    check(store)
end)

test("leader leaving transfers leadership to the earliest-joined remaining member", function()
    local store = newStore()
    join(store, 1, 2, 3, 4)
    addToParty(store, 1, 3) -- joined first
    addToParty(store, 1, 2)
    addToParty(store, 1, 4)
    local partyId = (store:getPartyOf(1) :: any).id
    expectTrue(store:leave(1).ok)
    local party = store:getPartyById(partyId) :: any
    expectEqual(party.leader, 3, "earliest joined remaining member, not lowest id")
    expectList(party.members, { 3, 2, 4 })
    expectEqual((store:getPartyOf(1) :: any).leader, 1, "old leader leads a new solo party")
    expectEqual(#members(store, 1), 1)
    -- Chain: next leader leaves.
    store:leave(3)
    expectEqual((store:getPartyOf(2) :: any).leader, 2)
    check(store)
end)

test("leader leaving cancels invitations they issued", function()
    local store = newStore()
    join(store, 1, 2, 3)
    addToParty(store, 1, 2)
    store:invite(1, 3)
    local result = store:leave(1)
    expectEqual(#result.endedInvites, 1)
    expectEqual(result.endedInvites[1].reason, "cancelled")
    expectEqual(store:respondToInvite(3, 1, true).rejection, "no_invite")
    check(store)
end)

test("leaving a solo party is a no-op; the last member's departure destroys the party", function()
    local store = newStore()
    join(store, 1)
    local id = (store:getPartyOf(1) :: any).id
    local result = store:leave(1)
    expectTrue(result.ok)
    expectFalse(result.changed)
    expectEqual((store:getPartyOf(1) :: any).id, id, "solo party unchanged")
    expectEqual(store:leave(99).rejection, "unknown_player")
    expectTrue(store:removePlayer(1).ok)
    expectEqual(store:getPartyCount(), 0)
    expectEqual(store:getPlayerCount(), 0)
    check(store)
end)

test("leader can kick a member who then gets a solo party", function()
    local store = newStore()
    join(store, 1, 2, 3)
    addToParty(store, 1, 2)
    addToParty(store, 1, 3)
    local result = store:kick(1, 2)
    expectTrue(result.ok)
    expectTrue(result.changed)
    expectList(members(store, 1), { 1, 3 })
    local solo = store:getPartyOf(2) :: any
    expectList(solo.members, { 2 })
    expectEqual(solo.leader, 2)
    expectFalse(solo.id == (store:getPartyOf(1) :: any).id)
    check(store)
end)

test("unauthorized kicks are rejected without changes", function()
    local store = newStore()
    join(store, 1, 2, 3, 4)
    addToParty(store, 1, 2)
    addToParty(store, 1, 3)
    expectEqual(store:kick(2, 3).rejection, "not_leader")
    expectEqual(store:kick(2, 1).rejection, "not_leader")
    expectEqual(store:kick(1, 1).rejection, "cannot_kick_self")
    expectEqual(store:kick(1, 4).rejection, "not_in_same_party")
    expectEqual(store:kick(4, 1).rejection, "not_in_same_party")
    expectEqual(store:kick(1, 99).rejection, "unknown_target")
    expectEqual(store:kick(99, 1).rejection, "unknown_player")
    expectList(members(store, 1), { 1, 2, 3 })
    check(store)
end)

test("kicking is safe to repeat", function()
    local store = newStore()
    join(store, 1, 2)
    addToParty(store, 1, 2)
    expectTrue(store:kick(1, 2).ok)
    expectEqual(store:kick(1, 2).rejection, "not_in_same_party")
    expectList(members(store, 2), { 2 })
    check(store)
end)

test("disconnect removes the player and transfers leadership deterministically", function()
    local store = newStore()
    join(store, 1, 2, 3)
    addToParty(store, 1, 3)
    addToParty(store, 1, 2)
    local partyId = (store:getPartyOf(1) :: any).id
    local result = store:removePlayer(1)
    expectTrue(result.ok)
    expectTrue(result.changed)
    expectEqual(store:getPartyOf(1), nil)
    local party = store:getPartyById(partyId) :: any
    expectEqual(party.leader, 3)
    expectList(party.members, { 3, 2 })
    expectEqual(store:getPlayerCount(), 2)
    store:removePlayer(3)
    expectEqual((store:getPartyById(partyId) :: any).leader, 2)
    store:removePlayer(2)
    expectEqual(store:getPartyById(partyId), nil)
    expectEqual(store:getPartyCount(), 0)
    check(store)
end)

test("disconnect removes pending invitations from and to the player", function()
    local store = newStore()
    join(store, 1, 2, 3, 4)
    store:invite(1, 2) -- 1 -> 2
    store:invite(3, 1) -- 3 -> 1
    store:invite(3, 4)
    expectEqual(store:getInviteCount(), 3)
    local result = store:removePlayer(1)
    expectEqual(#result.endedInvites, 2)
    expectEqual(store:getInviteCount(), 1, "unrelated invitation 3 -> 4 remains")
    expectEqual(#store:getInvitesFor(2), 0)
    expectEqual(store:respondToInvite(2, 1, true).rejection, "no_invite")
    store:removePlayer(4)
    expectEqual(store:getInviteCount(), 0)
    check(store)
end)

test("repeated operations are idempotent where appropriate", function()
    local store = newStore()
    join(store, 1, 2)
    expectEqual(store:addPlayer(1).rejection, "already_registered")
    expectEqual(store:getPlayerCount(), 2)
    expectTrue(store:removePlayer(2).changed)
    local again = store:removePlayer(2)
    expectTrue(again.ok)
    expectFalse(again.changed)
    expectTrue(store:removePlayer(77).ok)
    expectTrue(store:leave(1).ok)
    expectTrue(store:leave(1).ok)
    expectEqual(store:getPartyCount(), 1)
    -- Re-registering after disconnect starts a fresh solo party.
    expectTrue(store:addPlayer(2).ok)
    expectList(members(store, 2), { 2 })
    check(store)
end)

test("independent parties do not affect one another", function()
    local store = newStore()
    join(store, 1, 2, 3, 4, 5)
    addToParty(store, 1, 2)
    addToParty(store, 3, 4)
    local before = members(store, 3)
    store:kick(1, 2)
    store:leave(1)
    store:removePlayer(2)
    expectList(members(store, 3), before)
    expectEqual((store:getPartyOf(3) :: any).leader, 3)
    expectList(members(store, 4), { 3, 4 })
    expectList(members(store, 5), { 5 })
    check(store)
end)

test("randomized operation sequences never leave orphaned state", function()
    local seed = 12345
    local function random(n: number): number
        seed = (seed * 1103515245 + 12345) % 2147483648
        return (seed % n) + 1
    end

    local store, advance = newStore({ maxPartySize = 4 })
    local connected: { [number]: boolean } = {}
    for step = 1, 3000 do
        local a, b = random(10), random(10)
        local op = random(8)
        if op == 1 then
            local result = store:addPlayer(a)
            if result.ok then
                connected[a] = true
            end
        elseif op == 2 then
            store:removePlayer(a)
            connected[a] = nil
        elseif op == 3 then
            store:invite(a, b)
        elseif op == 4 then
            store:respondToInvite(a, b, random(2) == 1)
        elseif op == 5 then
            store:leave(a)
        elseif op == 6 then
            store:kick(a, b)
        elseif op == 7 then
            advance(random(40))
        else
            store:expireInvite(random(300)) -- timer-style expiry of an arbitrary (maybe unknown/not yet due) id
        end
        local ok, reason = store:validateInvariants()
        expectTrue(ok, "step " .. step .. " op " .. op .. ": " .. tostring(reason))
        for userId = 1, 10 do
            expectEqual(store:isRegistered(userId), connected[userId] == true, "registration of " .. userId)
            expectEqual(store:getPartyOf(userId) ~= nil, connected[userId] == true, "exactly one party for " .. userId)
        end
    end
end)

return {}
