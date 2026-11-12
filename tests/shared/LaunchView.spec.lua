--!strict
local Harness = require("../Harness")
local LaunchView = require("../../src/shared/Mission/LaunchView")
local Messages = require("../../src/shared/UI/Messages")

local test, expectTrue, expectFalse, expectEqual, expectError = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual, Harness.expectError

local function newView(): any
    return LaunchView.new(Messages)
end

local function start(view: any, now: number?): any
    local ok, reason = view:tryBeginRequest(true, "party-1", now or 0)
    expectTrue(ok, tostring(reason))
end

-- The request ---------------------------------------------------------------------------------------------------------

test("the launch request carries no arguments at all", function()
    local args = LaunchView.requestArguments()
    expectEqual(#args, 0)
    expectEqual(select("#", table.unpack(args)), 0, "nothing is sent: no PlaceId, mission type, member ids or server ids")
    expectTrue(table.isfrozen(args))
end)

test("new requires a message catalogue", function()
    expectError(function()
        LaunchView.new(nil :: any)
    end, "nil")
    expectError(function()
        LaunchView.new({} :: any)
    end, "empty")
end)

test("a leader can request a launch; a non-leader cannot", function()
    local view = newView()
    local ok, reason = view:canRequest(true, 0)
    expectTrue(ok)
    expectEqual(reason, nil)
    ok, reason = view:canRequest(false, 0)
    expectFalse(ok)
    expectEqual(reason, "not_leader")
    ok, reason = view:tryBeginRequest(false, "party-1", 0)
    expectFalse(ok)
    expectEqual(reason, "not_leader")
    expectEqual(view:getView(0).phase, "idle", "a refused request changes nothing")
end)

test("duplicate launch requests are refused while one is in flight", function()
    local view = newView()
    start(view, 0)
    expectEqual(view:getView(0).phase, "requesting")
    expectTrue(view:getView(0).busy)
    local ok, reason = view:tryBeginRequest(true, "party-1", 0.2)
    expectFalse(ok)
    expectEqual(reason, "busy")
    ok, reason = view:canRequest(true, 0.2)
    expectEqual(reason, "busy")
end)

test("starting is blocked during the whole launch and re-enabled only after a failure", function()
    local view = newView()
    start(view, 0)
    view:applyStatus({ status = "accepted" }, 1)
    expectFalse((view:canRequest(true, 2)))
    view:applyStatus({ status = "launch_initiated" }, 3)
    expectFalse((view:canRequest(true, 4)))
    view:applyStatus({ status = "teleport_failed", code = "teleport_call_failed" }, 5)
    expectTrue((view:canRequest(true, 7)), "after a failure the leader can retry (debounce passed)")
    expectFalse(view:getView(7).busy)
end)

test("two requests within the debounce window are refused even after a quick failure", function()
    local view = newView()
    start(view, 0)
    view:applyStatus({ status = "not_leader" }, 0.2)
    local ok, reason = view:canRequest(true, 0.5)
    expectFalse(ok)
    expectEqual(reason, "debounce")
    expectTrue((view:canRequest(true, 1.1)))
end)

-- Status handling: every actual LaunchCoordinator status --------------------------------------------------------------

test("accepted and launch_initiated are progress states", function()
    local view = newView()
    start(view, 0)
    expectTrue(view:applyStatus({ status = "accepted" }, 1))
    local shown = view:getView(1)
    expectEqual(shown.phase, "launching")
    expectEqual(shown.tone, "progress")
    expectTrue(shown.busy)
    expectEqual(shown.title, "PREPARING DEPLOYMENT")
    view:applyStatus({ status = "launch_initiated" }, 2)
    expectEqual(view:getView(2).title, "DEPLOYING")
end)

test("a non-leader sees the launch even though they never pressed Start", function()
    local view = newView()
    view:observeParty("party-1", 0)
    expectTrue(view:applyStatus({ status = "accepted" }, 5))
    expectEqual(view:getView(5).phase, "launching")
    expectTrue(view:getView(5).busy)
end)

test("retrying shows the attempt numbers", function()
    local view = newView()
    start(view, 0)
    view:applyStatus({ status = "retrying", attempt = 2, maxAttempts = 3 }, 1)
    local shown = view:getView(1)
    expectEqual(shown.phase, "launching")
    expectEqual(shown.title, "RECONNECTING")
    expectTrue(string.find(shown.text, "2 of 3", 1, true) ~= nil)
    view:applyStatus({ status = "retrying", attempt = "x" }, 2)
    expectTrue(string.find(view:getView(2).text, "Retrying...", 1, true) ~= nil, "invalid attempt numbers fall back to a generic text")
end)

test("partial_failure keeps the launch running and names the member who failed", function()
    local view = newView()
    start(view, 0)
    view:applyStatus({ status = "launch_initiated" }, 1)
    view:applyStatus({ status = "partial_failure", failedUserId = 7 }, 2)
    local shown = view:getView(2)
    expectEqual(shown.phase, "launching")
    expectEqual(shown.tone, "warning")
    expectEqual(shown.subjectUserId, 7)
    expectTrue(shown.busy)
end)

test("teleport_failed maps its codes to understandable messages and allows a retry", function()
    local cases = {
        { "timeout", "DEPLOYMENT TIMED OUT" },
        { "teleport_call_failed", "DEPLOYMENT FAILED" },
        { "retry_call_failed", "TRANSFER FAILED" },
        { "no_retry_options", "TRANSFER FAILED" },
        { "Unauthorized", "TRANSFER FAILED" },
    }
    for _, case in ipairs(cases) do
        local view = newView()
        start(view, 0)
        view:applyStatus({ status = "launch_initiated" }, 1)
        view:applyStatus({ status = "teleport_failed", code = case[1] }, 2)
        local shown = view:getView(2)
        expectEqual(shown.phase, "failed", case[1])
        expectEqual(shown.title, case[2], case[1])
        expectEqual(shown.tone, "error")
        expectFalse(shown.busy, case[1])
        expectTrue((view:canRequest(true, 4)), case[1])
    end
end)

test("rejections map to messages and keep the UI recoverable", function()
    local cases = {
        { { status = "not_leader", code = "not_leader" }, "LEADER ONLY" },
        { { status = "invalid_party", code = "member_disconnected" }, "SQUAD PROBLEM" },
        { { status = "invalid_party", code = "unknown_player" }, "SQUAD PROBLEM" },
        { { status = "preparation_failed", code = "mission_not_configured" }, "MISSION UNAVAILABLE" },
        { { status = "preparation_failed", code = "invalid_lifecycle" }, "SQUAD NOT READY" },
        { { status = "preparation_failed", code = "member_in_launch" }, "SQUAD BUSY" },
        { { status = "preparation_failed", code = "party_changed" }, "SQUAD CHANGED" },
        { { status = "preparation_failed", code = "something_new" }, "PREPARATION FAILED" },
    }
    for _, case in ipairs(cases) do
        local view = newView()
        start(view, 0)
        expectTrue(view:applyStatus(case[1], 1))
        local shown = view:getView(1)
        expectEqual(shown.phase, "rejected", case[2])
        expectEqual(shown.title, case[2])
        expectFalse(shown.busy)
        expectTrue((view:canRequest(true, 3)), case[2])
    end
end)

test("a missing mission configuration marks the mission unavailable", function()
    local view = newView()
    start(view, 0)
    view:applyStatus({ status = "preparation_failed", code = "mission_not_configured" }, 1)
    expectEqual(view:getView(1).mission, "unavailable")
    expectEqual(newView():getView(0).mission, nil)
end)

test("already_in_progress shows a running launch, but never hides one", function()
    local view = newView()
    start(view, 0)
    view:applyStatus({ status = "already_in_progress", code = "already_in_progress" }, 1)
    expectEqual(view:getView(1).phase, "launching")
    expectEqual(view:getView(1).title, "ALREADY DEPLOYING")
    local running = newView()
    start(running, 0)
    running:applyStatus({ status = "launch_initiated" }, 1)
    expectFalse(running:applyStatus({ status = "already_in_progress" }, 2), "ignored while the launch runs")
    expectEqual(running:getView(2).title, "DEPLOYING")
    expectFalse(running:applyStatus({ status = "not_leader" }, 2), "a late rejection must not replace a running launch")
    expectEqual(running:getView(2).phase, "launching")
end)

test("unknown and malformed statuses never crash and never show raw data", function()
    local view = newView()
    expectFalse(view:applyStatus("accepted", 0))
    expectFalse(view:applyStatus({}, 0))
    expectFalse(view:applyStatus({ status = 5 }, 0))
    expectTrue(view:applyStatus({ status = "brand_new_status", code = "internal-token-xyz" }, 1))
    local shown = view:getView(1)
    expectEqual(shown.title, "UNEXPECTED RESPONSE")
    expectTrue(string.find(shown.text, "internal-token-xyz", 1, true) == nil)
end)

-- Recovery -----------------------------------------------------------------------------------------------------------------------

test("a request nobody answers recovers by itself and can be retried", function()
    local view = newView()
    start(view, 0)
    expectEqual(view:getView(7.9).phase, "requesting")
    local shown = view:getView(8)
    expectEqual(shown.phase, "failed")
    expectEqual(shown.title, "NO RESPONSE")
    expectFalse(shown.busy)
    expectTrue((view:canRequest(true, 8)))
    start(view, 9)
    expectEqual(view:getView(9).phase, "requesting")
end)

test("a launch that goes silent recovers after the client timeout; progress keeps it alive", function()
    local view = newView()
    start(view, 0)
    view:applyStatus({ status = "accepted" }, 1)
    view:applyStatus({ status = "launch_initiated" }, 60)
    expectEqual(view:getView(134).phase, "launching", "each progress status restarts the timeout")
    local shown = view:getView(135)
    expectEqual(shown.phase, "failed")
    expectEqual(shown.title, "DEPLOYMENT TIMED OUT")
    expectFalse(shown.busy)
    expectTrue((view:canRequest(true, 135)))
end)

test("failure and rejection messages disappear after a while", function()
    local view = newView()
    start(view, 0)
    view:applyStatus({ status = "teleport_failed", code = "timeout" }, 1)
    expectEqual(view:getView(10.9).phase, "failed")
    expectEqual(view:getView(11).phase, "idle")
    expectEqual(view:getView(11).title, "READY")
end)

test("nextDeadline tells the UI when to look again", function()
    local view = newView()
    expectEqual(view:nextDeadline(0), nil)
    start(view, 0)
    expectEqual(view:nextDeadline(2), 6)
    view:applyStatus({ status = "accepted" }, 3)
    expectEqual(view:nextDeadline(3), 75)
    view:applyStatus({ status = "teleport_failed" }, 10)
    expectEqual(view:nextDeadline(10), 10)
    expectEqual(view:nextDeadline(30), nil, "back to idle after the message")
end)

-- Party changes and late notifications -------------------------------------------------------------------------------------

test("changing party resets the launch UI and ignores late notifications of the old party", function()
    local view = newView()
    view:observeParty("party-1", 0)
    start(view, 1)
    view:applyStatus({ status = "launch_initiated" }, 2)
    view:observeParty("party-2", 10)
    expectEqual(view:getView(10).phase, "idle")
    expectFalse(view:applyStatus({ status = "teleport_failed", code = "timeout" }, 11), "late status of the old party")
    expectEqual(view:getView(11).phase, "idle")
    expectTrue(view:applyStatus({ status = "accepted" }, 12.6), "after the grace period statuses count again")
    expectEqual(view:getView(12.6).phase, "launching")
end)

test("the first party observation and unchanged party ids reset nothing", function()
    local view = newView()
    view:observeParty("party-1", 0)
    expectTrue(view:applyStatus({ status = "accepted" }, 0.5), "no grace period after the initial party")
    view:observeParty("party-1", 1)
    expectEqual(view:getView(1).phase, "launching")
end)

test("a failed state from the old party is cleared when the party changes", function()
    local view = newView()
    view:observeParty("party-1", 0)
    start(view, 1)
    view:applyStatus({ status = "not_leader" }, 2)
    view:observeParty("party-2", 3)
    expectEqual(view:getView(3).phase, "idle")
end)

test("invalid clock values never corrupt the state", function()
    local view = newView()
    start(view, 0)
    local shown = view:getView(0 / 0)
    expectEqual(shown.phase, "requesting")
end)
