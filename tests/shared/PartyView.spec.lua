--!strict
local Harness = require("../Harness")
local PartyView = require("../../src/shared/Party/PartyView")

local test, expectTrue, expectFalse, expectEqual, expectError = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual, Harness.expectError

local LOCAL = 100
local MAX = 8

local function newView(): any
    return PartyView.new(LOCAL, MAX)
end

-- The party id stays the same across leader/member changes; pass a different one to simulate switching parties.
local function snapshot(leader: number, ids: { number }, pending: { any }?, partyId: string?): any
    local members: { any } = {}
    for _, id in ipairs(ids) do
        table.insert(members, { userId = id, displayName = "P" .. tostring(id) })
    end
    return { partyId = partyId or "party-A", leaderUserId = leader, members = members, pendingInvites = pending or {} }
end

local function applied(view: any, payload: any, now: number?): { any }
    local ok, events = view:applySnapshot(payload, now or 0)
    expectTrue(ok, "snapshot accepted")
    return events
end

local function eventTypes(events: { any }): { string }
    local types: { string } = {}
    for _, event in ipairs(events) do
        table.insert(types, event.type)
    end
    return types
end

local function expectTypes(events: { any }, expected: { string })
    expectEqual(table.concat(eventTypes(events), ","), table.concat(expected, ","))
end

-- Construction and validation ------------------------------------------------------------------------------------------

test("new validates its arguments", function()
    expectError(function()
        PartyView.new(0, 8)
    end, "user id 0")
    expectError(function()
        PartyView.new(1.5, 8)
    end, "fractional id")
    expectError(function()
        PartyView.new(1, 0)
    end, "max size 0")
    expectTrue(newView() ~= nil)
end)

test("before any snapshot there is no party and nothing can be done", function()
    local vm = newView():getViewModel(0)
    expectFalse(vm.hasParty)
    expectEqual(vm.size, 0)
    expectFalse(vm.canInvite)
    expectFalse(vm.canLeave)
    expectEqual(#vm.members, 0)
end)

test("malformed snapshots are ignored and change nothing", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL, 2 }))
    local bad: { any } = {
        "snapshot",
        {},
        { partyId = "", leaderUserId = LOCAL, members = { { userId = LOCAL, displayName = "x" } } },
        { partyId = "p", leaderUserId = "x", members = { { userId = LOCAL, displayName = "x" } } },
        { partyId = "p", leaderUserId = LOCAL, members = "none" },
        { partyId = "p", leaderUserId = LOCAL, members = {} },
        { partyId = "p", leaderUserId = 7, members = { { userId = LOCAL, displayName = "x" } } }, -- leader not a member
        { partyId = "p", leaderUserId = 7, members = { { userId = 7, displayName = "x" } } }, -- local not a member
        { partyId = "p", leaderUserId = LOCAL, members = { { userId = LOCAL, displayName = "x" }, { userId = LOCAL, displayName = "y" } } }, -- duplicate
        { partyId = "p", leaderUserId = LOCAL, members = { [2] = { userId = LOCAL, displayName = "x" } } }, -- not an array
        { partyId = "p", leaderUserId = LOCAL, members = { { userId = -1, displayName = "x" } } },
    }
    for index, payload in ipairs(bad) do
        local ok, events = view:applySnapshot(payload, 1)
        expectFalse(ok, "payload " .. index)
        expectEqual(#events, 0)
    end
    local vm = view:getViewModel(2)
    expectEqual(vm.size, 2, "the valid party is still shown")
end)

test("a missing display name falls back to a neutral label", function()
    local view = newView()
    applied(view, { partyId = "p", leaderUserId = LOCAL, members = { { userId = LOCAL, displayName = "" }, { userId = 5 } } })
    local vm = view:getViewModel(0)
    expectEqual(vm.members[1].displayName, "Player")
    expectEqual(vm.members[2].displayName, "Player")
end)

-- Rendering ------------------------------------------------------------------------------------------------------------

test("a solo party: the local player leads, can invite, cannot leave or kick", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    local vm = view:getViewModel(0)
    expectTrue(vm.hasParty)
    expectTrue(vm.isSolo)
    expectFalse(vm.isFull)
    expectEqual(vm.size, 1)
    expectEqual(vm.maxSize, 8)
    expectTrue(vm.localIsLeader)
    expectEqual(vm.leaderUserId, LOCAL)
    expectTrue(vm.canInvite)
    expectFalse(vm.canLeave)
    expectEqual(#vm.members, 1)
    expectTrue(vm.members[1].isLocal)
    expectTrue(vm.members[1].isLeader)
    expectFalse(vm.members[1].canKick)
end)

test("a party with several members: leader first, local and leader flags, kick only for the leader", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { 7, LOCAL, 9 }))
    local vm = view:getViewModel(0)
    expectEqual(vm.size, 3)
    expectFalse(vm.isSolo)
    expectTrue(vm.localIsLeader)
    expectEqual(vm.members[1].userId, LOCAL, "the leader is listed first")
    expectEqual(vm.members[2].userId, 7)
    expectEqual(vm.members[3].userId, 9)
    expectTrue(vm.members[1].isLocal and vm.members[1].isLeader)
    expectFalse(vm.members[2].isLocal)
    expectTrue(vm.members[2].canKick)
    expectTrue(vm.members[3].canKick)
    expectFalse(vm.members[1].canKick, "you cannot kick yourself")
    expectTrue(vm.canLeave)
end)

test("a member (not the leader) sees the leader and gets no leader-only controls", function()
    local view = newView()
    applied(view, snapshot(7, { 7, LOCAL, 9 }))
    local vm = view:getViewModel(0)
    expectFalse(vm.localIsLeader)
    expectEqual(vm.leaderUserId, 7)
    expectEqual(vm.members[1].userId, 7)
    expectTrue(vm.members[1].isLeader)
    expectFalse(vm.canInvite)
    for _, member in ipairs(vm.members) do
        expectFalse(member.canKick, tostring(member.userId))
    end
    expectTrue(vm.canLeave)
end)

test("a full party cannot invite anyone else", function()
    local view = newView()
    local ids: { number } = { LOCAL }
    for id = 1, MAX - 1 do
        table.insert(ids, id)
    end
    applied(view, snapshot(LOCAL, ids))
    local vm = view:getViewModel(0)
    expectTrue(vm.isFull)
    expectFalse(vm.canInvite)
    local ok, reason = view:canInvite(500, 0)
    expectFalse(ok)
    expectEqual(reason, "party_full")
end)

-- Membership changes ----------------------------------------------------------------------------------------------------

test("a member joining and leaving produces events and updates the party", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    expectTypes(applied(view, snapshot(LOCAL, { LOCAL, 7 })), { "member_joined" })
    expectEqual(view:getViewModel(0).size, 2)
    local events = applied(view, snapshot(LOCAL, { LOCAL }))
    expectTypes(events, { "member_left" })
    expectEqual(events[1].userId, 7)
    expectEqual(events[1].displayName, "P7")
    expectEqual(view:getViewModel(0).size, 1)
end)

test("the first snapshot and an identical snapshot produce no events", function()
    local view = newView()
    expectEqual(#applied(view, snapshot(LOCAL, { LOCAL, 7 })), 0)
    expectEqual(#applied(view, snapshot(LOCAL, { LOCAL, 7 })), 0)
end)

test("when the leader leaves, the new leader is shown and a promoted local player gains leader controls", function()
    local view = newView()
    applied(view, { partyId = "p", leaderUserId = 7, members = { { userId = 7, displayName = "P7" }, { userId = LOCAL, displayName = "Me" }, { userId = 9, displayName = "P9" } } })
    expectFalse(view:getViewModel(0).localIsLeader)
    local events = applied(view, { partyId = "p", leaderUserId = LOCAL, members = { { userId = LOCAL, displayName = "Me" }, { userId = 9, displayName = "P9" } } })
    expectTypes(events, { "member_left", "leader_changed" })
    expectTrue(events[2].isLocal)
    local vm = view:getViewModel(0)
    expectTrue(vm.localIsLeader)
    expectTrue(vm.canInvite)
    expectTrue(vm.members[2].canKick)
end)

test("the local player losing leadership loses every leader-only control", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL, 7, 9 }))
    expectTrue(view:getViewModel(0).members[2].canKick)
    local events = applied(view, snapshot(7, { LOCAL, 7, 9 }))
    expectTypes(events, { "leader_changed" })
    expectFalse(events[1].isLocal)
    expectEqual(events[1].userId, 7)
    local vm = view:getViewModel(0)
    expectFalse(vm.localIsLeader)
    expectEqual(vm.leaderUserId, 7)
    expectFalse(vm.canInvite)
    for _, member in ipairs(vm.members) do
        expectFalse(member.canKick)
    end
    local ok, reason = view:canInvite(500, 0)
    expectFalse(ok)
    expectEqual(reason, "not_leader")
    expectFalse(view:canKick(9, 0))
end)

test("changing party: leaving to a solo party and joining another squad", function()
    local view = newView()
    applied(view, snapshot(7, { 7, LOCAL }, nil, "party-B"))
    expectTypes(applied(view, snapshot(LOCAL, { LOCAL }, nil, "party-C")), { "left_party" })
    expectTypes(applied(view, snapshot(9, { 9, LOCAL }, nil, "party-D")), { "joined_party" })
end)

-- Incoming invitations -----------------------------------------------------------------------------------------------------

test("a snapshot's pending invitations appear without a countdown and are authoritative", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }, { { inviterUserId = 7, inviterDisplayName = "Alex", expiresAt = 999 } }), 10)
    local vm = view:getViewModel(11)
    expectEqual(#vm.incomingInvites, 1)
    expectEqual(vm.incomingInvites[1].displayName, "Alex")
    expectEqual(vm.incomingInvites[1].secondsRemaining, nil)
    expectEqual(vm.incomingInvites[1].state, "pending")
    applied(view, snapshot(LOCAL, { LOCAL }, {}), 12) -- the server no longer lists it
    expectEqual(#view:getViewModel(12).incomingInvites, 0)
end)

test("PartyInviteReceived gives a countdown that expires and is dropped after the grace period", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    expectTrue(view:applyInviteReceived({ inviterUserId = 7, inviterDisplayName = "Alex", expiresInSeconds = 60 }, 100))
    local vm = view:getViewModel(110)
    expectEqual(vm.incomingInvites[1].secondsRemaining, 50)
    expectEqual(vm.incomingInvites[1].state, "pending")
    vm = view:getViewModel(160)
    expectEqual(vm.incomingInvites[1].state, "expired")
    expectEqual(vm.incomingInvites[1].secondsRemaining, 0)
    expectEqual(#view:getViewModel(165.1).incomingInvites, 0, "dropped after the grace period even if the server stays silent")
end)

test("a pending invitation survives the snapshot that was sent for another reason", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    view:applyInviteReceived({ inviterUserId = 7, inviterDisplayName = "Alex", expiresInSeconds = 60 }, 100)
    applied(view, snapshot(LOCAL, { LOCAL }, { { inviterUserId = 7, inviterDisplayName = "Alex", expiresAt = 1 } }), 101)
    expectEqual(view:getViewModel(101).incomingInvites[1].secondsRemaining, 59, "the countdown from PartyInviteReceived is kept")
end)

test("invitation received payloads are validated", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    expectFalse(view:applyInviteReceived("x", 0))
    expectFalse(view:applyInviteReceived({ inviterUserId = "7" }, 0))
    expectFalse(view:applyInviteReceived({ inviterUserId = LOCAL, inviterDisplayName = "Me", expiresInSeconds = 60 }, 0), "cannot invite yourself")
    expectTrue(view:applyInviteReceived({ inviterUserId = 7, inviterDisplayName = "Alex", expiresInSeconds = 0 / 0 }, 0))
    expectEqual(view:getViewModel(1).incomingInvites[1].secondsRemaining, nil, "an invalid lifetime is treated as unknown")
end)

test("accepting: the row is marked responding, duplicate clicks are refused, then the invitation ends", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    view:applyInviteReceived({ inviterUserId = 7, inviterDisplayName = "Alex", expiresInSeconds = 60 }, 0)
    expectTrue(view:canRespond(7, 1))
    expectTrue(view:markResponding(7, 1))
    expectFalse(view:canRespond(7, 2), "no second click while the answer is in flight")
    expectFalse(view:markResponding(7, 2))
    expectEqual(view:getViewModel(2).incomingInvites[1].state, "responding")
    local ok, events = view:applyInviteEnded({ inviterUserId = 7, targetUserId = LOCAL, reason = "accepted" }, 3)
    expectTrue(ok)
    expectEqual(events[1].role, "target")
    expectEqual(events[1].reason, "accepted")
    expectEqual(events[1].displayName, "Alex")
    expectEqual(#view:getViewModel(3).incomingInvites, 0)
    expectTypes(applied(view, snapshot(7, { 7, LOCAL }, nil, "party-B"), 3), { "joined_party" })
end)

test("an answer the server never reacts to becomes clickable again", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    view:applyInviteReceived({ inviterUserId = 7, inviterDisplayName = "Alex", expiresInSeconds = 600 }, 0)
    view:markResponding(7, 1)
    expectFalse(view:canRespond(7, 8.9))
    expectTrue(view:canRespond(7, 9.1))
    expectEqual(view:getViewModel(9.1).incomingInvites[1].state, "pending")
end)

test("declined, expired, cancelled and superseded endings remove the invitation", function()
    for _, reason in ipairs({ "declined", "expired", "cancelled", "superseded" }) do
        local view = newView()
        applied(view, snapshot(LOCAL, { LOCAL }))
        view:applyInviteReceived({ inviterUserId = 7, inviterDisplayName = "Alex", expiresInSeconds = 60 }, 0)
        local ok, events = view:applyInviteEnded({ inviterUserId = 7, targetUserId = LOCAL, reason = reason }, 1)
        expectTrue(ok, reason)
        expectEqual(events[1].reason, reason)
        expectEqual(#view:getViewModel(1).incomingInvites, 0, reason)
    end
end)

test("invitation endings that do not involve the local player are ignored", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    local ok, events = view:applyInviteEnded({ inviterUserId = 7, targetUserId = 8, reason = "declined" }, 0)
    expectTrue(ok)
    expectEqual(#events, 0)
    expectFalse((view:applyInviteEnded({ inviterUserId = 7, targetUserId = LOCAL }, 0)))
    expectFalse((view:applyInviteEnded("x", 0)))
end)

test("several invitations are ordered by arrival", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    view:applyInviteReceived({ inviterUserId = 9, inviterDisplayName = "Second", expiresInSeconds = 60 }, 5)
    view:applyInviteReceived({ inviterUserId = 7, inviterDisplayName = "First", expiresInSeconds = 60 }, 1)
    local invites = view:getViewModel(6).incomingInvites
    expectEqual(invites[1].displayName, "First")
    expectEqual(invites[2].displayName, "Second")
end)

-- Outgoing invitations and candidates -----------------------------------------------------------------------------------

test("canInvite reports why an invitation is not possible", function()
    local view = newView()
    local ok, reason = view:canInvite(500, 0)
    expectFalse(ok)
    expectEqual(reason, "not_leader", "no party yet")
    applied(view, snapshot(LOCAL, { LOCAL, 7 }))
    ok, reason = view:canInvite(LOCAL, 0)
    expectEqual(reason, "self")
    ok, reason = view:canInvite("x", 0)
    expectEqual(reason, "self")
    ok, reason = view:canInvite(7, 0)
    expectEqual(reason, "already_in_party")
    ok, reason = view:canInvite(500, 0)
    expectTrue(ok)
    expectEqual(reason, nil)
end)

test("an invitation is tracked, blocks duplicates, and ends with the server's notification", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    expectTrue(view:markInviteSent(500, 0))
    local ok, reason = view:canInvite(500, 0.5)
    expectFalse(ok)
    expectEqual(reason, "already_invited")
    expectFalse(view:markInviteSent(500, 1), "a duplicate click sends nothing")
    local ended, events = view:applyInviteEnded({ inviterUserId = LOCAL, targetUserId = 500, reason = "declined" }, 5)
    expectTrue(ended)
    expectEqual(events[1].role, "inviter")
    expectEqual(events[1].userId, 500)
    expectTrue(view:canInvite(500, 5), "after the ending the player can be invited again")
end)

test("a lost invitation notification does not block inviting forever", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    view:markInviteSent(500, 0)
    expectFalse(view:canInvite(500, 74))
    expectTrue(view:canInvite(500, 75.1))
end)

test("candidates list the other players with their invite state", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL, 7 }))
    view:markInviteSent(9, 0)
    local players: { any } = {
        { userId = LOCAL, displayName = "Me" },
        { userId = 7, displayName = "bravo" },
        { userId = 9, displayName = "Alpha" },
        { userId = 11, displayName = "charlie" },
    }
    local candidates = view:getCandidates(players, 1)
    expectEqual(#candidates, 3, "the local player is not a candidate")
    expectEqual(candidates[1].displayName, "Alpha")
    expectEqual(candidates[1].state, "invited")
    expectEqual(candidates[2].displayName, "bravo")
    expectEqual(candidates[2].state, "member")
    expectEqual(candidates[3].displayName, "charlie")
    expectEqual(candidates[3].state, "available")
    applied(view, snapshot(7, { 7, LOCAL }))
    expectEqual(view:getCandidates(players, 1)[3].state, "blocked_not_leader")
end)

test("candidates of a full party are blocked", function()
    local view = newView()
    local ids: { number } = { LOCAL }
    for id = 1, MAX - 1 do
        table.insert(ids, id)
    end
    applied(view, snapshot(LOCAL, ids))
    local candidates = view:getCandidates({ { userId = 500, displayName = "x" } }, 0)
    expectEqual(candidates[1].state, "blocked_full")
end)

test("server rejection clears an optimistic outgoing invite so it can be retried", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    expectTrue(view:markInviteSent(500, 0))
    expectFalse(view:canInvite(500, 1))
    view:clearOutgoingInvite(500)
    expectTrue(view:canInvite(500, 1))
end)

test("server rejection resets a responding invitation immediately", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    view:applyInviteReceived({ inviterUserId = 7, inviterDisplayName = "Alex", expiresInSeconds = 60 }, 0)
    expectTrue(view:markResponding(7, 1))
    expectEqual(view:getViewModel(2).incomingInvites[1].state, "responding")
    expectTrue(view:resetResponding(7))
    expectEqual(view:getViewModel(2).incomingInvites[1].state, "pending")
    expectFalse(view:resetResponding(7), "reset is idempotent")
end)

-- Kick and leave -------------------------------------------------------------------------------------------------------------

test("kick: leader only, members only, locked after a click and unlocked by the next snapshot", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL, 7 }))
    expectTrue(view:canKick(7, 0))
    expectFalse(view:canKick(LOCAL, 0))
    expectFalse(view:canKick(500, 0), "not a member")
    expectTrue(view:markKickSent(7, 0))
    expectFalse(view:canKick(7, 1), "locked against double clicks")
    expectFalse(view:markKickSent(7, 1))
    applied(view, snapshot(LOCAL, { LOCAL, 7 }), 1)
    expectTrue(view:canKick(7, 1), "a snapshot clears the lock")
    expectTrue(view:canKick(7, 3))
end)

test("leave: needs a squad of two or more, locked after a click", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    expectFalse(view:canLeave(0))
    expectFalse(view:markLeaveSent(0))
    applied(view, snapshot(7, { 7, LOCAL }))
    expectTrue(view:canLeave(0))
    expectTrue(view:markLeaveSent(0))
    expectFalse(view:canLeave(1))
    expectTrue(view:canLeave(2.1), "the lock is short")
end)

-- Refresh scheduling --------------------------------------------------------------------------------------------------------

test("nextRefreshIn is nil when nothing depends on time, and small while a countdown is visible", function()
    local view = newView()
    applied(view, snapshot(LOCAL, { LOCAL }))
    expectEqual(view:nextRefreshIn(0), nil)
    view:applyInviteReceived({ inviterUserId = 7, inviterDisplayName = "Alex", expiresInSeconds = 60 }, 0)
    expectEqual(view:nextRefreshIn(1), 1)
    expectEqual(view:nextRefreshIn(60.5), 4.5, "the expired invitation is dropped after the grace period")
    expectEqual(view:nextRefreshIn(70), nil, "once dropped nothing is scheduled")
end)
