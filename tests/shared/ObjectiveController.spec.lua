--!strict
local Harness = require("../Harness")
local ObjectiveView = require("../../src/shared/Objective/ObjectiveView")
local ObjectiveController = require("../../src/shared/Objective/ObjectiveController")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

-- Fake ports -------------------------------------------------------------------------------------------------------

local function newWorld(): any
    local world: any = {
        events = {}, -- ordered log of port interactions
        connects = 0,
        cancelled = 0,
        handler = nil,
        onReady = nil,
        onFailed = nil,
        requests = 0,
        requestRaises = false,
        timers = {}, -- { at, callback, cancelled }
        clock = 0,
        logs = {},
    }
    world.deps = {
        view = ObjectiveView,
        connect = function(handler: any, onReady: any, onFailed: any): () -> ()
            world.connects = world.connects + 1
            world.handler = handler
            world.onReady = onReady
            world.onFailed = onFailed
            table.insert(world.events, "connect")
            return function()
                world.cancelled = world.cancelled + 1
                table.insert(world.events, "disconnect")
            end
        end,
        requestSnapshot = function()
            world.requests = world.requests + 1
            table.insert(world.events, "request")
            if world.requestRaises then
                error("request boom")
            end
        end,
        schedule = function(delay: number, callback: () -> ()): () -> ()
            local timer = { at = world.clock + delay, callback = callback, cancelled = false }
            table.insert(world.timers, timer)
            return function()
                timer.cancelled = true
            end
        end,
        now = function(): number
            return world.clock
        end,
        log = function(message: string)
            table.insert(world.logs, message)
        end,
    }
    -- advances the fake clock, firing due timers in order
    function world.advance(seconds: number)
        local target = world.clock + seconds
        while true do
            local nextTimer: any = nil
            for _, timer in ipairs(world.timers) do
                if not timer.cancelled and not timer.fired and timer.at <= target and (nextTimer == nil or timer.at < nextTimer.at) then
                    nextTimer = timer
                end
            end
            if nextTimer == nil then
                break
            end
            world.clock = math.max(world.clock, nextTimer.at)
            nextTimer.fired = true
            nextTimer.callback()
        end
        world.clock = target
    end
    function world.pendingTimers(): number
        local count = 0
        for _, timer in ipairs(world.timers) do
            if not timer.cancelled and not timer.fired then
                count = count + 1
            end
        end
        return count
    end
    return world
end

local function entry(id: string, importance: string, state: string, required: number?, filled: number?): any
    local count = required or 1
    local done = filled or 0
    local slots = {}
    for index = 1, count do
        table.insert(slots, { label = "Slot " .. index, filled = index <= done })
    end
    return { id = id, title = "Title " .. id, description = "Description " .. id, importance = importance, state = state, filled = done, required = count, slots = slots }
end

local function snapshot(revision: number, ...: any): any
    return { v = 1, revision = revision, objectives = { ... } }
end

local function sliceSnapshot(revision: number): any
    return snapshot(revision, entry("P", "REQUIRED", "AVAILABLE", 3, 0), entry("W", "REQUIRED", "LOCKED"), entry("O", "OPTIONAL", "AVAILABLE"))
end

local function started(): (any, any)
    local world = newWorld()
    local controller: any = ObjectiveController.new(world.deps)
    controller:start()
    return world, controller
end

local function ready(world: any, controller: any)
    world.onReady()
end

-- construction ------------------------------------------------------------------------------------------------------

test("new requires complete dependencies", function()
    Harness.expectError(function()
        ObjectiveController.new({} :: any)
    end)
    local world = newWorld()
    world.deps.schedule = nil
    Harness.expectError(function()
        ObjectiveController.new(world.deps)
    end)
end)

test("before start the controller is idle, empty and unsynced", function()
    local world = newWorld()
    local controller: any = ObjectiveController.new(world.deps)
    expectFalse(controller:isStarted())
    expectFalse(controller:isSynced())
    expectEqual(controller:getRevision(), -1)
    expectEqual(#controller:getViewModel().entries, 0)
    expectEqual(world.connects, 0)
    expectEqual(world.requests, 0)
end)

-- 1. initial snapshot, 9. initialization race ------------------------------------------------------------------------

test("the listener is connected before any pull, and the pull happens only after the listener is ready", function()
    local world, controller = started()
    expectEqual(world.connects, 1)
    expectEqual(world.requests, 0, "no pull before the port reports the listener ready")
    ready(world, controller)
    expectEqual(world.requests, 1, "exactly one pull once ready")
    expectEqual(world.events[1], "connect")
    expectEqual(world.events[2], "request")
end)

test("the initial snapshot is accepted and announced once", function()
    local world, controller = started()
    local changes = 0
    controller:onChanged(function()
        changes = changes + 1
    end)
    ready(world, controller)
    world.handler(sliceSnapshot(0))
    expectTrue(controller:isSynced())
    expectEqual(controller:getRevision(), 0)
    expectEqual(changes, 1)
    expectEqual(#controller:getViewModel().entries, 3)
end)

test("a lost initial push is recovered by the pull answer", function()
    local world, controller = started()
    -- the server's start-of-mission push happened before the listener existed: nothing is delivered
    ready(world, controller)
    expectFalse(controller:isSynced())
    world.handler(sliceSnapshot(0)) -- the answer to the pull
    expectTrue(controller:isSynced())
end)

test("a push that arrives before the ready signal is applied and the pull answer is a harmless duplicate", function()
    local world, controller = started()
    local changes = 0
    controller:onChanged(function()
        changes = changes + 1
    end)
    world.handler(sliceSnapshot(0)) -- the broadcast wins the race
    expectTrue(controller:isSynced())
    ready(world, controller)
    expectEqual(world.requests, 1, "still pulls once to be safe")
    world.handler(sliceSnapshot(0)) -- the pull answer: same revision
    expectEqual(changes, 1, "the duplicate produces no second update")
    expectEqual(controller:getRevision(), 0)
end)

test("a pull answer carrying a newer revision than an earlier push is applied", function()
    local world, controller = started()
    world.handler(sliceSnapshot(0))
    ready(world, controller)
    world.handler(snapshot(2, entry("P", "REQUIRED", "IN_PROGRESS", 3, 2), entry("W", "REQUIRED", "LOCKED")))
    expectEqual(controller:getRevision(), 2)
end)

test("start is idempotent: no second connection and no second pull", function()
    local world, controller = started()
    controller:start()
    controller:start()
    expectEqual(world.connects, 1)
    ready(world, controller)
    world.onReady() -- a repeated ready signal is ignored too
    expectEqual(world.requests, 1)
end)

-- 2-4. revisions ----------------------------------------------------------------------------------------------------

test("a newer revision replaces the state and a transition is announced", function()
    local world, controller = started()
    ready(world, controller)
    local seen: { string } = {}
    controller:onTransition(function(events: any)
        for _, event in ipairs(events) do
            table.insert(seen, event.kind .. ":" .. event.id)
        end
    end)
    world.handler(sliceSnapshot(0))
    expectEqual(#seen, 0, "the baseline announces nothing")
    world.handler(snapshot(1, entry("P", "REQUIRED", "COMPLETED", 3, 3), entry("W", "REQUIRED", "AVAILABLE"), entry("O", "OPTIONAL", "AVAILABLE")))
    expectEqual(controller:getRevision(), 1)
    expectEqual(table.concat(seen, ","), "COMPLETED:P,UNLOCKED:W")
    expectEqual(controller:getViewModel().entries[1].state, "COMPLETED")
end)

test("a stale revision is ignored without any notification", function()
    local world, controller = started()
    ready(world, controller)
    world.handler(snapshot(5, entry("P", "REQUIRED", "COMPLETED", 3, 3)))
    local changes, transitions = 0, 0
    controller:onChanged(function()
        changes = changes + 1
    end)
    controller:onTransition(function()
        transitions = transitions + 1
    end)
    world.handler(sliceSnapshot(2))
    world.handler(sliceSnapshot(0))
    expectEqual(controller:getRevision(), 5)
    expectEqual(changes, 0)
    expectEqual(transitions, 0)
    expectEqual(controller:getViewModel().entries[1].state, "COMPLETED")
end)

test("a duplicate revision does not cause a redundant update", function()
    local world, controller = started()
    ready(world, controller)
    local changes = 0
    controller:onChanged(function()
        changes = changes + 1
    end)
    world.handler(sliceSnapshot(0))
    world.handler(sliceSnapshot(0))
    world.handler(sliceSnapshot(0))
    expectEqual(changes, 1)
end)

-- 5. malformed ------------------------------------------------------------------------------------------------------

test("malformed snapshots are rejected safely and keep the last valid state", function()
    local world, controller = started()
    ready(world, controller)
    world.handler(sliceSnapshot(0))
    local changes = 0
    controller:onChanged(function()
        changes = changes + 1
    end)
    for _, bad in ipairs({ "x", 5, {}, { v = 1, revision = 3 }, { v = 9, revision = 3, objectives = {} } }) do
        world.handler(bad)
    end
    world.handler(nil)
    expectEqual(changes, 0)
    expectEqual(controller:getRevision(), 0)
    expectEqual(#controller:getViewModel().entries, 3)
    expectTrue(#world.logs >= 1)
end)

test("malformed payloads trigger bounded, throttled refreshes", function()
    local world, controller = started()
    ready(world, controller)
    expectEqual(world.requests, 1)
    world.handler("bad")
    expectEqual(world.requests, 1, "within the minimum interval of the initial pull: throttled")
    world.advance(2.5)
    world.handler("bad")
    expectEqual(world.requests, 2)
    world.handler("bad")
    expectEqual(world.requests, 2, "throttled again")
    world.advance(2.5)
    world.handler("bad")
    expectEqual(world.requests, 3)
    world.advance(2.5)
    world.handler("bad")
    expectEqual(world.requests, 3, "the malformed-refresh budget is spent")
end)

test("a valid snapshot restores the malformed-refresh budget", function()
    local world, controller = started()
    ready(world, controller)
    world.advance(2.5)
    world.handler("bad")
    world.advance(2.5)
    world.handler("bad")
    world.handler(sliceSnapshot(0))
    local before = world.requests
    world.advance(2.5)
    world.handler("bad")
    expectEqual(world.requests, before + 1)
end)

-- unsynced retry ----------------------------------------------------------------------------------------------------

test("while no valid snapshot arrives the controller pulls again, at most three times in total", function()
    local world, controller = started()
    ready(world, controller)
    expectEqual(world.requests, 1)
    world.advance(ObjectiveController.RetrySeconds + 0.1)
    expectEqual(world.requests, 2)
    world.advance(ObjectiveController.RetrySeconds + 0.1)
    expectEqual(world.requests, 3)
    world.advance(60)
    expectEqual(world.requests, 3, "bounded by the server burst; no endless polling")
    expectEqual(world.pendingTimers(), 0)
    expectFalse(controller:isSynced())
end)

test("the retry is cancelled as soon as a valid snapshot is accepted", function()
    local world, controller = started()
    ready(world, controller)
    world.handler(sliceSnapshot(0))
    expectEqual(world.pendingTimers(), 0)
    world.advance(60)
    expectEqual(world.requests, 1)
end)

test("a failing pull request is logged and does not break the controller", function()
    local world, controller = started()
    world.requestRaises = true
    ready(world, controller)
    expectTrue(#world.logs >= 1)
    world.handler(sliceSnapshot(0))
    expectTrue(controller:isSynced())
end)

test("a listener that cannot be connected is logged and leaves the controller unsynced but alive", function()
    local world, controller = started()
    world.onFailed("remote_missing")
    expectTrue(#world.logs >= 1)
    expectEqual(world.requests, 0)
    expectTrue(controller:isStarted())
    expectEqual(#controller:getViewModel().entries, 0)
end)

-- 6-7, 10. representation -------------------------------------------------------------------------------------------

test("hidden objectives are not invented: only what the server sent is exposed", function()
    local world, controller = started()
    ready(world, controller)
    world.handler(snapshot(0, entry("A", "REQUIRED", "AVAILABLE")))
    local model = controller:getViewModel()
    expectEqual(#model.entries, 1)
    expectEqual(model.entries[1].id, "A")
    expectEqual(model.requiredTotal, 1)
end)

test("optional and required objectives are represented distinctly through the controller", function()
    local world, controller = started()
    ready(world, controller)
    world.handler(sliceSnapshot(0))
    local model = controller:getViewModel()
    expectTrue(model.entries[1].isRequired and not model.entries[1].isOptional)
    expectTrue(model.entries[3].isOptional and not model.entries[3].isRequired)
    expectEqual(model.requiredTotal, 2)
end)

test("empty and missing collections do not break the controller", function()
    local world, controller = started()
    ready(world, controller)
    world.handler({ v = 1, revision = 0, objectives = {} })
    expectTrue(controller:isSynced())
    expectEqual(#controller:getViewModel().entries, 0)
    world.handler({ v = 1, revision = 1 })
    expectEqual(controller:getRevision(), 0)
    expectEqual(#controller:getViewModel().entries, 0)
end)

test("the view model handed out is a copy", function()
    local world, controller = started()
    ready(world, controller)
    world.handler(sliceSnapshot(0))
    local model = controller:getViewModel()
    model.entries[1].title = "Tampered"
    table.remove(model.entries)
    local again = controller:getViewModel()
    expectEqual(#again.entries, 3)
    expectEqual(again.entries[1].title, "Title P")
end)

-- listeners ---------------------------------------------------------------------------------------------------------

test("listeners can unsubscribe and a failing listener does not stop the others", function()
    local world, controller = started()
    ready(world, controller)
    local calls = { first = 0, second = 0 }
    local unsubscribe = controller:onChanged(function()
        calls.first = calls.first + 1
    end)
    controller:onChanged(function()
        error("listener boom")
    end)
    controller:onChanged(function()
        calls.second = calls.second + 1
    end)
    world.handler(sliceSnapshot(0))
    expectEqual(calls.first, 1)
    expectEqual(calls.second, 1)
    expectTrue(#world.logs >= 1)
    unsubscribe()
    world.handler(snapshot(1, entry("P", "REQUIRED", "COMPLETED", 3, 3)))
    expectEqual(calls.first, 1)
    expectEqual(calls.second, 2)
end)

-- 8. cleanup ---------------------------------------------------------------------------------------------------------

test("destroy disconnects, cancels the retry, clears listeners and ignores later deliveries", function()
    local world, controller = started()
    ready(world, controller)
    local changes = 0
    controller:onChanged(function()
        changes = changes + 1
    end)
    world.handler(sliceSnapshot(0))
    expectEqual(changes, 1)
    local staleHandler = world.handler
    controller:destroy()
    expectFalse(controller:isStarted())
    expectEqual(world.cancelled, 1, "the subscription was disconnected")
    expectEqual(world.pendingTimers(), 0)
    expectFalse(controller:isSynced())
    expectEqual(#controller:getViewModel().entries, 0)
    expectEqual(controller:getRevision(), -1)
    staleHandler(snapshot(9, entry("P", "REQUIRED", "COMPLETED", 3, 3)))
    expectEqual(changes, 1, "no update after destroy")
    expectEqual(#controller:getViewModel().entries, 0)
    world.advance(60)
    expectEqual(world.requests, 1, "no timer fires after destroy")
end)

test("destroy is idempotent and safe before start or before ready", function()
    local world = newWorld()
    local controller: any = ObjectiveController.new(world.deps)
    controller:destroy()
    controller:destroy()
    local started2, controller2 = started()
    controller2:destroy()
    controller2:destroy()
    expectEqual(started2.cancelled, 1)
    started2.onReady() -- a late ready signal after destroy must not pull
    expectEqual(started2.requests, 0)
end)

test("a controller can be restarted and the old subscription stays dead", function()
    local world, controller = started()
    ready(world, controller)
    local oldHandler = world.handler
    local oldReady = world.onReady
    controller:destroy()
    controller:start()
    expectEqual(world.connects, 2)
    local changes = 0
    controller:onChanged(function()
        changes = changes + 1
    end)
    oldHandler(sliceSnapshot(0))
    oldReady()
    expectEqual(changes, 0, "the first generation cannot reach the new one")
    expectEqual(world.requests, 1, "the stale ready signal did not pull")
    world.onReady()
    expectEqual(world.requests, 2)
    world.handler(sliceSnapshot(0))
    expectEqual(changes, 1)
    expectEqual(controller:getRevision(), 0)
end)

test("a revision-0 snapshot is accepted again after a restart", function()
    local world, controller = started()
    ready(world, controller)
    world.handler(snapshot(7, entry("P", "REQUIRED", "COMPLETED", 3, 3)))
    controller:destroy()
    controller:start()
    world.onReady()
    world.handler(sliceSnapshot(0))
    expectEqual(controller:getRevision(), 0)
    expectEqual(controller:getViewModel().entries[1].state, "AVAILABLE")
end)
