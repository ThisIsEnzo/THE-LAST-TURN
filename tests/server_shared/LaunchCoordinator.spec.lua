--!strict
local Harness = require("../Harness")
local LaunchCoordinator = require("../../src/server_shared/MissionTeleport/LaunchCoordinator")
local TeleportPayload = require("../../src/server_shared/MissionTeleport/TeleportPayload")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual
local Status = LaunchCoordinator.Status
local States = LaunchCoordinator.States

-- Fake world: parties, connectivity, lifecycle, ids, teleport calls, notifications and manual timers.
local function makeEnv(configOverrides: { [string]: any }?)
    local env: any = {
        connected = {} :: { [number]: boolean },
        lifecycle = {} :: { [number]: string },
        partyOf = {} :: { [number]: string },
        parties = {} :: { [string]: { id: string, leader: number, members: { number } } },
        guidCount = 0,
        onGuid = nil :: (() -> ())?,
        teleportResult = true,
        teleportCalls = {} :: { any },
        retryResult = true,
        retryCalls = {} :: { any },
        notifications = {} :: { any },
        timers = {} :: { any },
    }

    function env.addParty(id: string, members: { number })
        env.parties[id] = { id = id, leader = members[1], members = table.clone(members) }
        for _, userId in ipairs(members) do
            env.partyOf[userId] = id
            env.connected[userId] = true
            env.lifecycle[userId] = "ALIVE"
        end
    end

    function env.statuses(userId: number): { string }
        local list: { string } = {}
        for _, note in ipairs(env.notifications) do
            if table.find(note.ids, userId) then
                table.insert(list, note.status)
            end
        end
        return list
    end

    function env.runTimers()
        local pending = table.clone(env.timers)
        for _, timer in ipairs(pending) do
            if not timer.cancelled and not timer.done then
                timer.done = true
                timer.fn()
            end
        end
    end

    function env.runTimersWithDelay(delay: number)
        for _, timer in ipairs(table.clone(env.timers)) do
            if timer.delay == delay and not timer.cancelled and not timer.done then
                timer.done = true
                timer.fn()
            end
        end
    end

    local config = {
        missionPlaceId = 123456,
        maxPartySize = 8,
        missionType = "DEFAULT",
        maxRetriesPerPlayer = 2,
        retryDelaySeconds = 2,
        launchTimeoutSeconds = 60,
    }
    for key, value in pairs(configOverrides or {}) do
        (config :: any)[key] = value
    end

    local deps = {
        getPartyForUser = function(userId: number)
            local id = env.partyOf[userId]
            local party = id and env.parties[id]
            return party and { id = party.id, leader = party.leader, members = table.clone(party.members) } or nil
        end,
        isConnected = function(userId: number)
            return env.connected[userId] == true
        end,
        getLifecycleState = function(userId: number)
            return env.lifecycle[userId]
        end,
        newGuid = function()
            env.guidCount += 1
            if env.onGuid then
                env.onGuid()
            end
            return "guid-" .. env.guidCount
        end,
        now = function()
            return 1700000000
        end,
        buildPayload = TeleportPayload.build,
        teleport = function(launch: any)
            table.insert(env.teleportCalls, launch)
            return env.teleportResult, if env.teleportResult then nil else "boom"
        end,
        retry = function(userId: number, options: any, launch: any)
            table.insert(env.retryCalls, { userId = userId, options = options, launch = launch })
            return env.retryResult, nil
        end,
        notify = function(ids: { number }, status: string, extra: any)
            table.insert(env.notifications, { ids = table.clone(ids), status = status, extra = extra })
        end,
        schedule = function(delay: number, fn: () -> ())
            local timer = { delay = delay, fn = fn, cancelled = false, done = false }
            table.insert(env.timers, timer)
            return function()
                timer.cancelled = true
            end
        end,
    }
    env.coordinator = LaunchCoordinator.new(config, deps)
    env.finished = {} :: { any }
    env.coordinator:onLaunchFinished(function(summary: any)
        table.insert(env.finished, summary)
    end)
    return env
end

local function optionsFor(launch: any): any
    return { ReservedServerId = launch.reservedServerId, marker = "event-options" }
end

test("valid solo launch", function()
    local env = makeEnv()
    env.addParty("P1", { 1 })
    local result = env.coordinator:requestLaunch(1)
    expectTrue(result.ok)
    expectEqual(result.status, Status.LAUNCH_INITIATED)
    expectEqual(#env.teleportCalls, 1)
    expectEqual(#env.teleportCalls[1].memberUserIds, 1)
    expectEqual(env.coordinator:getLaunchState("P1"), States.TELEPORTING)
    expectEqual(env.statuses(1)[1], Status.ACCEPTED)
end)

test("valid party launch sends the server-derived payload for the whole party", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2, 3 })
    expectTrue(env.coordinator:requestLaunch(1).ok)
    local launch = env.teleportCalls[1]
    expectEqual(table.concat(launch.memberUserIds, ","), "1,2,3")
    expectEqual(launch.payload.partyId, "P1")
    expectEqual(launch.payload.partyLeaderUserId, 1)
    expectEqual(launch.payload.missionType, "DEFAULT")
    expectEqual(launch.payload.createdAt, 1700000000)
    expectTrue((TeleportPayload.validate(launch.payload)))
    for userId = 1, 3 do
        expectEqual(env.statuses(userId)[1], Status.ACCEPTED)
    end
end)

test("party capacity boundary: 8 launch, 9 is rejected", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2, 3, 4, 5, 6, 7, 8 })
    expectTrue(env.coordinator:requestLaunch(1).ok)
    local big = makeEnv()
    big.addParty("P1", { 1, 2, 3, 4, 5, 6, 7, 8, 9 })
    local result = big.coordinator:requestLaunch(1)
    expectFalse(result.ok)
    expectEqual(result.status, Status.INVALID_PARTY)
    expectEqual(#big.teleportCalls, 0)
    expectEqual(big.coordinator:getActiveLaunchCount(), 0)
end)

test("non-leader cannot launch", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    local result = env.coordinator:requestLaunch(2)
    expectFalse(result.ok)
    expectEqual(result.status, Status.NOT_LEADER)
    expectEqual(#env.teleportCalls, 0)
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
    expectEqual(env.statuses(2)[1], Status.NOT_LEADER)
end)

test("invalid parties are rejected", function()
    local env = makeEnv()
    env.connected[1] = true
    env.lifecycle[1] = "ALIVE"
    expectEqual(env.coordinator:requestLaunch(1).status, Status.INVALID_PARTY, "no party")
    expectEqual(env.coordinator:requestLaunch(99).status, Status.INVALID_PARTY, "unknown/disconnected requester")

    env.addParty("P2", { 2, 3 })
    env.parties.P2.members = { 2, 3, 3 } -- duplicate member
    expectEqual(env.coordinator:requestLaunch(2).code, "inconsistent_party")
    env.parties.P2.members = { 3, 4 } -- leader not in members
    expectEqual(env.coordinator:requestLaunch(2).code, "inconsistent_party")
    env.parties.P2.members = {}
    expectEqual(env.coordinator:requestLaunch(2).code, "invalid_party")
    expectEqual(#env.teleportCalls, 0)
end)

test("disconnected member and bad lifecycle states are rejected", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2, 3 })
    env.connected[3] = false
    local result = env.coordinator:requestLaunch(1)
    expectFalse(result.ok)
    expectEqual(result.code, "member_disconnected")
    env.connected[3] = true
    for _, state in ipairs({ "DEAD", "GHOST", "SPECTATING", "RETURNING" }) do
        env.lifecycle[2] = state
        local rejected = env.coordinator:requestLaunch(1)
        expectEqual(rejected.code, "invalid_lifecycle", state)
    end
    env.lifecycle[2] = nil
    expectEqual(env.coordinator:requestLaunch(1).code, "invalid_lifecycle", "unregistered lifecycle")
    expectEqual(#env.teleportCalls, 0)
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
end)

test("party membership changing during preparation cancels the launch", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2, 3 })
    env.onGuid = function()
        env.parties.P1.members = { 1, 2 } -- member 3 left between snapshot and revalidation
    end
    local result = env.coordinator:requestLaunch(1)
    expectFalse(result.ok)
    expectEqual(result.code, "party_changed")
    expectEqual(#env.teleportCalls, 0, "outdated member list must never be teleported")
    expectEqual(env.coordinator:getActiveLaunchCount(), 0, "lock released")
    env.onGuid = nil
    expectTrue(env.coordinator:requestLaunch(1).ok, "party can launch again afterwards")
end)

test("a member disconnecting during preparation cancels the launch", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    env.onGuid = function()
        env.connected[2] = false
    end
    expectEqual(env.coordinator:requestLaunch(1).code, "party_changed")
    expectEqual(#env.teleportCalls, 0)
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
end)

test("duplicate launch requests do not create a second destination", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    expectTrue(env.coordinator:requestLaunch(1).ok)
    local again = env.coordinator:requestLaunch(1)
    expectFalse(again.ok)
    expectEqual(again.status, Status.ALREADY_IN_PROGRESS)
    expectEqual(#env.teleportCalls, 1)
    expectEqual(env.guidCount, 2, "two ids for the single launch only")
    expectEqual(env.coordinator:requestLaunch(2).status, Status.NOT_LEADER, "non-leaders still get not_leader")
end)

test("independent parties launch concurrently with unique mission and reserved ids", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    env.addParty("P2", { 3 })
    env.addParty("P3", { 4, 5, 6 })
    for _, leader in ipairs({ 1, 3, 4 }) do
        expectTrue(env.coordinator:requestLaunch(leader).ok)
    end
    expectEqual(env.coordinator:getActiveLaunchCount(), 3)
    local missions: { [string]: boolean } = {}
    local reserved: { [string]: boolean } = {}
    for _, launch in ipairs(env.teleportCalls) do
        expectFalse(missions[launch.missionId] == true, "duplicate mission id")
        expectFalse(reserved[launch.reservedServerId] == true, "duplicate reserved id")
        expectFalse(launch.missionId == launch.reservedServerId)
        missions[launch.missionId] = true
        reserved[launch.reservedServerId] = true
    end
    -- One party finishing does not touch the others.
    env.coordinator:onPlayerRemoved(3)
    expectEqual(env.coordinator:getActiveLaunchCount(), 2)
    expectEqual(env.coordinator:getLaunchState("P1"), States.TELEPORTING)
end)

test("invalid MISSION PlaceId configuration disables launching", function()
    for _, bad in ipairs({ 0, -5, 1.5, 0 / 0, math.huge }) do
        local env = makeEnv({ missionPlaceId = bad })
        env.addParty("P1", { 1 })
        local result = env.coordinator:requestLaunch(1)
        expectFalse(result.ok, tostring(bad))
        expectEqual(result.code, "mission_not_configured")
        expectEqual(result.status, Status.PREPARATION_FAILED)
        expectEqual(#env.teleportCalls, 0)
        expectEqual(env.guidCount, 0)
    end
    expectTrue(LaunchCoordinator.isValidPlaceId(123))
    expectFalse(LaunchCoordinator.isValidPlaceId("123"))
end)

test("payload carries no reserved server id and the id is never in notifications", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    env.coordinator:requestLaunch(1)
    local reservedId = env.teleportCalls[1].reservedServerId
    for key, value in pairs(env.teleportCalls[1].payload) do
        expectFalse(tostring(value) == reservedId, "payload field " .. key)
    end
    for _, note in ipairs(env.notifications) do
        for _, value in pairs(note.extra or {}) do
            expectFalse(value == reservedId, "notification leaks reserved id")
        end
    end
end)

test("synchronous TeleportAsync failure fails the launch, notifies and releases the lock", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    env.teleportResult = false
    local result = env.coordinator:requestLaunch(1)
    expectFalse(result.ok)
    expectEqual(result.status, Status.TELEPORT_FAILED)
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
    expectEqual(#env.retryCalls, 0, "no uncontrolled retries")
    expectEqual(env.finished[1].state, States.FAILED)
    for userId = 1, 2 do
        expectTrue(table.find(env.statuses(userId), Status.TELEPORT_FAILED) ~= nil)
    end
    env.teleportResult = true
    expectTrue(env.coordinator:requestLaunch(1).ok, "party is not permanently locked")
    expectEqual(env.guidCount, 4, "a fresh launch may create a fresh destination; the failed one never retried")
end)

test("TeleportInitFailed retries the same destination with the event's options", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    env.coordinator:requestLaunch(1)
    local launch = env.teleportCalls[1]
    local options = optionsFor(launch)
    local guidsBefore = env.guidCount
    expectTrue(env.coordinator:onTeleportInitFailed(2, { reservedServerId = launch.reservedServerId, options = options }))
    expectEqual(#env.retryCalls, 0, "retry waits for its timer")
    expectTrue(table.find(env.statuses(2), Status.RETRYING) ~= nil)
    env.runTimersWithDelay(2)
    expectEqual(#env.retryCalls, 1)
    expectEqual(env.retryCalls[1].userId, 2)
    expectTrue(env.retryCalls[1].options == options, "must reuse the TeleportOptions from the failure event")
    expectEqual(env.guidCount, guidsBefore, "retry must not generate a new reserved destination")
    expectEqual(#env.teleportCalls, 1)
    expectEqual(env.coordinator:getLaunchState("P1"), States.TELEPORTING, "unresolved attempts keep the lock")
end)

test("duplicate failure events while a retry is pending are ignored", function()
    local env = makeEnv()
    env.addParty("P1", { 1 })
    env.coordinator:requestLaunch(1)
    local launch = env.teleportCalls[1]
    local info = { reservedServerId = launch.reservedServerId, options = optionsFor(launch) }
    env.coordinator:onTeleportInitFailed(1, info)
    env.coordinator:onTeleportInitFailed(1, info)
    env.runTimersWithDelay(2)
    expectEqual(#env.retryCalls, 1)
end)

test("retry limit is enforced and the player is marked failed", function()
    local env = makeEnv({ maxRetriesPerPlayer = 2 })
    env.addParty("P1", { 1, 2 })
    env.coordinator:requestLaunch(1)
    local launch = env.teleportCalls[1]
    local info = { reservedServerId = launch.reservedServerId, options = optionsFor(launch) }
    for attempt = 1, 2 do
        expectTrue(env.coordinator:onTeleportInitFailed(2, info))
        env.runTimersWithDelay(2)
        expectEqual(#env.retryCalls, attempt)
    end
    expectTrue(env.coordinator:onTeleportInitFailed(2, info), "third failure exceeds the limit")
    env.runTimersWithDelay(2)
    expectEqual(#env.retryCalls, 2, "no further retries")
    expectTrue(table.find(env.statuses(2), Status.TELEPORT_FAILED) ~= nil)
    expectTrue(table.find(env.statuses(1), Status.PARTIAL_FAILURE) ~= nil, "remaining members are told")
    expectEqual(env.coordinator:getLaunchState("P1"), States.TELEPORTING, "member 1 still unresolved")
    env.coordinator:onPlayerRemoved(1) -- member 1 transferred
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
    expectEqual(env.finished[1].state, States.PARTIAL_FAILURE)
    expectEqual(table.concat(env.finished[1].failedUserIds, ","), "2")
    expectEqual(table.concat(env.finished[1].leftUserIds, ","), "1")
end)

test("a retry call that fails counts as another attempt and stays bounded", function()
    local env = makeEnv({ maxRetriesPerPlayer = 1 })
    env.addParty("P1", { 1 })
    env.coordinator:requestLaunch(1)
    local launch = env.teleportCalls[1]
    env.retryResult = false
    env.coordinator:onTeleportInitFailed(1, { reservedServerId = launch.reservedServerId, options = optionsFor(launch) })
    env.runTimersWithDelay(2) -- retry call fails -> second attempt exceeds the limit
    expectEqual(#env.retryCalls, 1)
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
    expectEqual(env.finished[1].state, States.FAILED)
end)

test("failures without TeleportOptions cannot be retried", function()
    local env = makeEnv()
    env.addParty("P1", { 1 })
    env.coordinator:requestLaunch(1)
    local launch = env.teleportCalls[1]
    expectTrue(env.coordinator:onTeleportInitFailed(1, { reservedServerId = launch.reservedServerId, options = nil }))
    expectEqual(#env.retryCalls, 0)
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
end)

test("failure events for another destination or an unrelated player are ignored", function()
    local env = makeEnv()
    env.addParty("P1", { 1 })
    env.addParty("P2", { 2 })
    env.coordinator:requestLaunch(1)
    env.coordinator:requestLaunch(2)
    local first, second = env.teleportCalls[1], env.teleportCalls[2]
    expectFalse(env.coordinator:onTeleportInitFailed(1, { reservedServerId = second.reservedServerId, options = optionsFor(second) }))
    expectFalse(env.coordinator:onTeleportInitFailed(1, { reservedServerId = "someone-elses", options = {} }))
    expectFalse(env.coordinator:onTeleportInitFailed(1, { reservedServerId = nil, options = nil }))
    expectFalse(env.coordinator:onTeleportInitFailed(77, { reservedServerId = first.reservedServerId, options = optionsFor(first) }))
    env.runTimers()
    expectEqual(#env.retryCalls, 0)
end)

test("player disconnecting during retry is not retried", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    env.coordinator:requestLaunch(1)
    local launch = env.teleportCalls[1]
    env.coordinator:onTeleportInitFailed(2, { reservedServerId = launch.reservedServerId, options = optionsFor(launch) })
    env.connected[2] = false
    env.coordinator:onPlayerRemoved(2)
    env.runTimersWithDelay(2)
    expectEqual(#env.retryCalls, 0)
    expectEqual(env.coordinator:getLaunchState("P1"), States.TELEPORTING, "member 1 still pending")
    env.coordinator:onPlayerRemoved(1)
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
    expectEqual(env.finished[1].state, States.COMPLETED)
end)

test("disconnected players are not retried and failures do not retry them", function()
    local env = makeEnv()
    env.addParty("P1", { 1 })
    env.coordinator:requestLaunch(1)
    local launch = env.teleportCalls[1]
    env.connected[1] = false
    env.coordinator:onTeleportInitFailed(1, { reservedServerId = launch.reservedServerId, options = optionsFor(launch) })
    expectEqual(#env.retryCalls, 0)
end)

test("successful launch cleans up when every member leaves the HUB", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2, 3 })
    env.coordinator:requestLaunch(1)
    env.coordinator:onPlayerRemoved(2)
    env.coordinator:onPlayerRemoved(1)
    expectEqual(env.coordinator:getActiveLaunchCount(), 1)
    env.coordinator:onPlayerRemoved(3)
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
    expectEqual(env.finished[1].state, States.COMPLETED)
    expectEqual(env.coordinator:getLaunchState("P1"), nil)
    for _, timer in ipairs(env.timers) do
        expectTrue(timer.cancelled or timer.done, "timers are cancelled on cleanup")
    end
end)

test("everyone leaving while TeleportAsync is still yielding is handled", function()
    local coordinator: LaunchCoordinator.Coordinator
    local guids = 0
    coordinator = LaunchCoordinator.new({
        missionPlaceId = 1,
        maxPartySize = 8,
        missionType = "DEFAULT",
        maxRetriesPerPlayer = 1,
        retryDelaySeconds = 1,
        launchTimeoutSeconds = 10,
    }, {
        getPartyForUser = function(_: number)
            return { id = "P1", leader = 1, members = { 1 } }
        end,
        isConnected = function(_: number)
            return true
        end,
        getLifecycleState = function(_: number)
            return "ALIVE"
        end,
        newGuid = function()
            guids += 1
            return "g" .. guids
        end,
        now = function()
            return 5
        end,
        buildPayload = TeleportPayload.build,
        teleport = function(_: any)
            coordinator:onPlayerRemoved(1) -- PlayerRemoving can arrive before TeleportAsync returns
            return true, nil
        end,
        retry = function(_: number, _: any, _: any)
            return true, nil
        end,
        notify = function(_: { number }, _: string, _: any) end,
        schedule = function(_: number, _: () -> ())
            return function() end
        end,
    })
    local result = coordinator:requestLaunch(1)
    expectTrue(result.ok)
    expectEqual(coordinator:getActiveLaunchCount(), 0)
end)

test("launch timeout releases the party lock and reports unresolved players", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    env.coordinator:requestLaunch(1)
    env.coordinator:onPlayerRemoved(1)
    env.runTimersWithDelay(60)
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
    expectEqual(env.finished[1].state, States.PARTIAL_FAILURE)
    expectEqual(table.concat(env.finished[1].failedUserIds, ","), "2")
    expectTrue(table.find(env.statuses(2), Status.TELEPORT_FAILED) ~= nil)
    expectTrue(env.coordinator:requestLaunch(1).ok, "lock released: the party can launch again")
end)

test("no stale locks after any outcome; a failed party can launch again", function()
    local env = makeEnv()
    env.addParty("P1", { 1 })
    env.addParty("P2", { 2 })
    env.addParty("P3", { 3 })
    env.coordinator:requestLaunch(1)
    env.coordinator:requestLaunch(2)
    env.coordinator:requestLaunch(3)
    local second = env.teleportCalls[2]
    env.coordinator:onPlayerRemoved(1) -- success
    env.runTimersWithDelay(60) -- P2 and P3 time out
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
    env.addParty("P2", { 2 })
    expectTrue(env.coordinator:requestLaunch(2).ok)
    expectFalse(env.teleportCalls[4].reservedServerId == second.reservedServerId)
end)

test("a member of an unfinished launch cannot be pulled into a new launch", function()
    local env = makeEnv()
    env.addParty("P1", { 1, 2 })
    env.coordinator:requestLaunch(1)
    local launch = env.teleportCalls[1]
    env.coordinator:onTeleportInitFailed(2, { reservedServerId = launch.reservedServerId, options = optionsFor(launch) })
    -- Player 2 (still pending in launch 1) moves to a new party led by 3 who tries to launch.
    env.addParty("P3", { 3, 2 })
    local result = env.coordinator:requestLaunch(3)
    expectFalse(result.ok)
    expectEqual(result.code, "member_in_launch")
    expectEqual(#env.teleportCalls, 1)
end)

test("shutdown cancels timers and clears launches", function()
    local env = makeEnv()
    env.addParty("P1", { 1 })
    env.coordinator:requestLaunch(1)
    env.coordinator:shutdown()
    expectEqual(env.coordinator:getActiveLaunchCount(), 0)
    for _, timer in ipairs(env.timers) do
        expectTrue(timer.cancelled)
    end
end)

test("configuration is validated", function()
    Harness.expectError(function()
        makeEnv({ maxRetriesPerPlayer = -1 })
    end)
    Harness.expectError(function()
        makeEnv({ retryDelaySeconds = 0 })
    end)
    Harness.expectError(function()
        makeEnv({ launchTimeoutSeconds = math.huge })
    end)
end)

return {}
