--!strict
local Harness = require("../Harness")
local EvidenceView = require("../../src/shared/Evidence/EvidenceView")
local EvidencePresenter = require("../../src/shared/Evidence/EvidencePresenter")
local ObjectiveController = require("../../src/shared/Objective/ObjectiveController")
local Messages = require("../../src/shared/UI/Messages")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

-- The whole pure client pipeline is real: the shared snapshot controller (ObjectiveController, driven through dependency
-- injection) feeds EvidenceView, EvidencePresenter turns it into render state with the real Messages catalogue. Only the
-- network ports, the clock and the UI are fakes.

local function entry(id: string, state: string?, sources: number?, required: number?): any
    return { id = id, title = "Title " .. id, category = "ENVIRONMENTAL", state = state or "OBSERVED", sources = sources or 1, required = required or 2 }
end

local function snapshot(revision: number, total: any, ...: any): any
    return { v = 1, revision = revision, total = total, evidence = { ... } }
end

local function newWorld(): any
    local world: any = {
        connects = 0,
        cancelled = 0,
        handler = nil,
        onReady = nil,
        requests = 0,
        timers = {},
        clock = 0,
        logs = {},
        ui = { created = 0, destroyed = 0, renders = {}, toasts = {}, live = 0, callbacks = nil },
    }
    world.controllerDeps = {
        view = EvidenceView,
        connect = function(handler: any, onReady: any, onFailed: any): () -> ()
            world.connects = world.connects + 1
            world.handler = handler
            world.onReady = onReady
            return function()
                world.cancelled = world.cancelled + 1
            end
        end,
        requestSnapshot = function()
            world.requests = world.requests + 1
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
    world.uiPort = {
        create = function(callbacks: any): any
            world.ui.created = world.ui.created + 1
            world.ui.live = world.ui.live + 1
            world.ui.callbacks = callbacks
            return { id = world.ui.created }
        end,
        render = function(_handle: any, state: any)
            table.insert(world.ui.renders, state)
        end,
        toast = function(_handle: any, toast: any)
            table.insert(world.ui.toasts, toast)
        end,
        destroy = function(_handle: any)
            world.ui.destroyed = world.ui.destroyed + 1
            world.ui.live = world.ui.live - 1
        end,
    }
    function world.lastState(): any
        return world.ui.renders[#world.ui.renders]
    end
    return world
end

local function started(): (any, any, any)
    local world = newWorld()
    local controller: any = ObjectiveController.new(world.controllerDeps)
    controller:start()
    local presenter: any = EvidencePresenter.new({ controller = controller, ui = world.uiPort, text = Messages, log = world.controllerDeps.log })
    presenter:start()
    return world, controller, presenter
end

local function deliver(world: any, payload: any)
    world.handler(payload)
end

-- initialization and the pull race ----------------------------------------------------------------------------------------

test("before the first snapshot nothing is visible", function()
    local world = started()
    local state = world.lastState()
    expectFalse(state.visible)
    expectFalse(state.journalOpen)
    expectEqual(#state.entries, 0)
end)

test("the HUD initializes from an existing authoritative snapshot (a late joiner pulls the current state)", function()
    local world, controller = started()
    world.onReady() -- the listener is ready: the controller pulls once
    expectEqual(world.requests, 1)
    deliver(world, snapshot(9, 4, entry("COLD_SPOT", "CONFIRMED", 2, 2), entry("MOVED_OBJECT", "OBSERVED", 1, 2)))
    local state = world.lastState()
    expectTrue(state.visible)
    expectEqual(state.counter, "EVIDENCE 2 / 4")
    expectEqual(#state.entries, 2)
    expectEqual(state.entries[1].title, "Title COLD_SPOT")
    expectEqual(state.entries[1].status, "CONFIRMED")
    expectEqual(state.entries[2].status, "OBSERVED")
    expectEqual(#world.ui.toasts, 0, "evidence the team already knew is not announced to a late joiner")
    expectEqual(controller:getRevision(), 9)
end)

test("an initial snapshot that arrives before the ready signal and its duplicate pull answer cause one update", function()
    local world = started()
    local before = #world.ui.renders
    deliver(world, snapshot(0, 4))
    expectEqual(#world.ui.renders, before + 1)
    world.onReady()
    deliver(world, snapshot(0, 4)) -- the pull answer
    expectEqual(#world.ui.renders, before + 1, "the duplicate revision produced no redundant render")
end)

-- counter and journal -----------------------------------------------------------------------------------------------------

test("a new discovery updates the counter and adds exactly one journal entry", function()
    local world = started()
    deliver(world, snapshot(0, 4))
    expectEqual(world.lastState().counter, "EVIDENCE 0 / 4")
    deliver(world, snapshot(1, 4, entry("COLD_SPOT")))
    local state = world.lastState()
    expectEqual(state.counter, "EVIDENCE 1 / 4")
    expectEqual(#state.entries, 1)
    expectEqual(state.entries[1].title, "Title COLD_SPOT")
    expectEqual(state.entries[1].category, "Environmental")
    expectEqual(state.entries[1].progress, "1 of 2 sightings")
end)

test("duplicate and stale updates never create duplicate entries or extra renders", function()
    local world = started()
    deliver(world, snapshot(0, 4))
    deliver(world, snapshot(1, 4, entry("A")))
    local renders = #world.ui.renders
    local toasts = #world.ui.toasts
    deliver(world, snapshot(1, 4, entry("A"), entry("B")))
    deliver(world, snapshot(0, 4))
    deliver(world, snapshot(1, 4, entry("A")))
    expectEqual(#world.ui.renders, renders)
    expectEqual(#world.ui.toasts, toasts)
    expectEqual(#world.lastState().entries, 1)
end)

test("multiple discoveries keep counts consistent and share one notification", function()
    local world = started()
    deliver(world, snapshot(0, 6))
    deliver(world, snapshot(2, 6, entry("A"), entry("B", "CONFIRMED", 1, 1), entry("C")))
    local state = world.lastState()
    expectEqual(state.counter, "EVIDENCE 3 / 6")
    expectEqual(#state.entries, 3)
    expectEqual(#world.ui.toasts, 1, "one toast for one snapshot")
    expectTrue(#world.ui.toasts[1].lines <= EvidencePresenter.MaxToastLines)
    expectEqual(world.ui.toasts[1].lines[1], "New evidence: Title A")
    deliver(world, snapshot(3, 6, entry("A"), entry("B", "CONFIRMED", 1, 1), entry("C"), entry("D")))
    expectEqual(world.lastState().counter, "EVIDENCE 4 / 6")
    expectEqual(#world.lastState().entries, 4)
    expectEqual(#world.ui.toasts, 2)
    expectEqual(world.ui.toasts[2].lines[1], "New evidence: Title D", "only the new discovery is announced")
end)

test("a confirmation is announced once and distinguished from a discovery", function()
    local world = started()
    deliver(world, snapshot(0, 4, entry("A", "OBSERVED", 1, 2)))
    deliver(world, snapshot(1, 4, entry("A", "CONFIRMED", 2, 2)))
    expectEqual(#world.ui.toasts, 1)
    expectEqual(world.ui.toasts[1].kind, "CONFIRMED")
    expectEqual(world.ui.toasts[1].lines[1], "Confirmed: Title A")
    local state = world.lastState()
    expectEqual(state.counter, "EVIDENCE 1 / 4")
    expectEqual(state.entries[1].progress, "", "confirmed evidence shows no pending progress")
    expectTrue(state.entries[1].isConfirmed)
end)

test("progress inside an entry updates the journal without a notification", function()
    local world = started()
    deliver(world, snapshot(0, 4, entry("A", "OBSERVED", 1, 3)))
    deliver(world, snapshot(1, 4, entry("A", "OBSERVED", 2, 3)))
    expectEqual(#world.ui.toasts, 0)
    expectEqual(world.lastState().entries[1].progress, "2 of 3 sightings")
end)

test("the counter shows only the discovered count when the server supplied no total", function()
    local world = started()
    deliver(world, { v = 1, revision = 0, evidence = { entry("A") } })
    expectEqual(world.lastState().counter, "EVIDENCE 1")
end)

-- privacy -----------------------------------------------------------------------------------------------------------------

test("undiscovered evidence is never displayed and a payload containing it is rejected whole", function()
    local world, controller = started()
    deliver(world, snapshot(0, 4, entry("A")))
    local rendersBefore = #world.ui.renders
    deliver(world, snapshot(1, 4, entry("A"), entry("SECRET_THING", "UNKNOWN", 1, 2)))
    expectEqual(#world.ui.renders, rendersBefore, "nothing was rendered")
    expectEqual(controller:getRevision(), 0)
    for _, state in ipairs(world.ui.renders) do
        for _, item in ipairs(state.entries) do
            expectFalse(string.find(item.title, "SECRET", 1, true) ~= nil)
        end
        expectFalse(string.find(state.counter, "SECRET", 1, true) ~= nil)
    end
end)

test("an empty journal shows a single neutral line and no placeholder rows", function()
    local world = started()
    deliver(world, snapshot(0, 4))
    local state = world.lastState()
    expectEqual(#state.entries, 0)
    expectEqual(state.emptyText, "Nothing found yet.")
    deliver(world, snapshot(1, 4, entry("A")))
    expectEqual(world.lastState().emptyText, "")
end)

test("the render state exposes no ids, source names or raw codes", function()
    local world = started()
    local cold = entry("COLD_SPOT", "OBSERVED", 1, 2)
    cold.title = "Cold spot"
    deliver(world, snapshot(0, 4, cold))
    local function scan(value: any)
        if type(value) == "table" then
            for key, inner in pairs(value) do
                expectTrue(key ~= "id" and key ~= "sourceId" and key ~= "sources" and key ~= "required", "key " .. tostring(key))
                scan(inner)
            end
        elseif type(value) == "string" then
            expectFalse(string.find(value, "COLD_SPOT", 1, true) ~= nil, "id leaked: " .. value)
            expectFalse(string.find(value, "ENVIRONMENTAL", 1, true) ~= nil, "raw category leaked: " .. value)
        end
    end
    scan(world.lastState())
end)

-- journal ---------------------------------------------------------------------------------------------------------------

test("the journal opens, closes and toggles, only after the first snapshot", function()
    local world, _, presenter = started()
    presenter:toggleJournal()
    expectFalse(presenter:isJournalOpen(), "nothing to show before the server state is known")
    deliver(world, snapshot(0, 4, entry("A")))
    presenter:toggleJournal()
    expectTrue(presenter:isJournalOpen())
    expectTrue(world.lastState().journalOpen)
    presenter:toggleJournal()
    expectFalse(presenter:isJournalOpen())
    expectFalse(world.lastState().journalOpen)
    presenter:openJournal()
    presenter:openJournal()
    presenter:closeJournal()
    presenter:closeJournal()
    expectFalse(presenter:isJournalOpen())
end)

test("the UI callbacks drive the journal and stay inert after destroy", function()
    local world, _, presenter = started()
    deliver(world, snapshot(0, 4))
    local callbacks = world.ui.callbacks
    callbacks.toggle()
    expectTrue(presenter:isJournalOpen())
    callbacks.close()
    expectFalse(presenter:isJournalOpen())
    presenter:destroy()
    callbacks.toggle()
    callbacks.close()
    expectFalse(presenter:isJournalOpen())
end)

test("updates keep the journal open and do not reset it", function()
    local world, _, presenter = started()
    deliver(world, snapshot(0, 4, entry("A")))
    presenter:openJournal()
    deliver(world, snapshot(1, 4, entry("A"), entry("B")))
    expectTrue(world.lastState().journalOpen)
    expectEqual(#world.lastState().entries, 2)
end)

-- cleanup, mission end, respawn ------------------------------------------------------------------------------------------

test("start is idempotent: a respawn or a second start creates no second UI and no second listener", function()
    local world, controller, presenter = started()
    presenter:start()
    presenter:start() -- e.g. the character was replaced and a bootstrap ran again
    expectEqual(world.ui.created, 1)
    expectEqual(world.ui.live, 1)
    deliver(world, snapshot(0, 4))
    deliver(world, snapshot(1, 4, entry("A")))
    expectEqual(#world.ui.toasts, 1, "exactly one notification: no duplicated listener")
    local rendersPerUpdate = 0
    local before = #world.ui.renders
    deliver(world, snapshot(2, 4, entry("A"), entry("B")))
    rendersPerUpdate = #world.ui.renders - before
    expectEqual(rendersPerUpdate, 1, "exactly one render per accepted snapshot")
    expectEqual(controller:getRevision(), 2)
end)

test("destroy unsubscribes, destroys the UI and ignores later updates", function()
    local world, controller, presenter = started()
    deliver(world, snapshot(0, 4))
    deliver(world, snapshot(1, 4, entry("A")))
    local renders = #world.ui.renders
    local toasts = #world.ui.toasts
    presenter:openJournal()
    presenter:destroy()
    expectFalse(presenter:isStarted())
    expectFalse(presenter:isJournalOpen())
    expectEqual(world.ui.destroyed, 1)
    expectEqual(world.ui.live, 0)
    deliver(world, snapshot(2, 4, entry("A"), entry("B")))
    expectEqual(#world.ui.toasts, toasts)
    expectTrue(#world.ui.renders <= renders + 1, "no render after destroy")
    presenter:destroy()
    expectEqual(world.ui.destroyed, 1, "destroy is idempotent")
    controller:destroy()
end)

test("destroy removes every subscription: repeated start and destroy cycles leak no listeners", function()
    local world = newWorld()
    local real: any = ObjectiveController.new(world.controllerDeps)
    real:start()
    local live = 0
    local spy = {
        getViewModel = function(_self: any): any
            return real:getViewModel()
        end,
        onChanged = function(_self: any, listener: any): () -> ()
            live = live + 1
            local unsubscribe = real:onChanged(listener)
            return function()
                live = live - 1
                unsubscribe()
            end
        end,
        onTransition = function(_self: any, listener: any): () -> ()
            live = live + 1
            local unsubscribe = real:onTransition(listener)
            return function()
                live = live - 1
                unsubscribe()
            end
        end,
    }
    local presenter: any = EvidencePresenter.new({ controller = spy, ui = world.uiPort, text = Messages, log = world.controllerDeps.log })
    for _ = 1, 3 do
        presenter:start()
        presenter:start()
        expectEqual(live, 2, "one change and one transition subscription while running")
        presenter:destroy()
        expectEqual(live, 0, "everything unsubscribed")
    end
    expectEqual(world.ui.created, 3)
    expectEqual(world.ui.live, 0)
end)

test("mission end: destroying the controller and the presenter clears every piece of mission evidence UI", function()
    local world, controller, presenter = started()
    deliver(world, snapshot(0, 4, entry("A")))
    presenter:openJournal()
    controller:destroy() -- the snapshot subscription is cancelled and the mirrored state forgotten
    presenter:destroy()
    expectEqual(world.cancelled, 1)
    expectEqual(world.ui.live, 0)
    expectFalse(controller:isSynced())
    expectEqual(#controller:getViewModel().entries, 0)
    expectEqual(controller:getViewModel().discovered, 0)
    local state = EvidencePresenter.buildState(controller:getViewModel(), true, Messages)
    expectFalse(state.visible, "an unsynced model renders as hidden")
    expectFalse(state.journalOpen)
    world.handler(snapshot(5, 4, entry("LATE")))
    expectEqual(#controller:getViewModel().entries, 0, "a late delivery after mission end changes nothing")
end)

test("a new mission after a teardown starts clean with a single UI", function()
    local world, controller, presenter = started()
    deliver(world, snapshot(3, 4, entry("A")))
    presenter:destroy()
    controller:destroy()
    controller:start()
    presenter:start()
    expectEqual(world.ui.created, 2)
    expectEqual(world.ui.live, 1)
    expectFalse(world.lastState().visible)
    world.onReady()
    deliver(world, snapshot(0, 4)) -- revision 0 of the new mission is accepted again
    expectTrue(world.lastState().visible)
    expectEqual(world.lastState().counter, "EVIDENCE 0 / 4")
    expectEqual(#world.ui.toasts, 0)
end)

test("a UI that cannot be created leaves the presenter stopped and logs the problem", function()
    local world = newWorld()
    world.uiPort.create = function(): any
        error("no PlayerGui")
    end
    local controller: any = ObjectiveController.new(world.controllerDeps)
    controller:start()
    local presenter: any = EvidencePresenter.new({ controller = controller, ui = world.uiPort, text = Messages, log = world.controllerDeps.log })
    presenter:start()
    expectFalse(presenter:isStarted())
    expectTrue(#world.logs >= 1)
    world.handler(snapshot(0, 4, entry("A")))
    expectEqual(#world.ui.renders, 0)
end)

test("a failing UI render or toast never breaks the controller or the presenter", function()
    local world, controller, presenter = started()
    world.uiPort.render = function()
        error("render boom")
    end
    world.uiPort.toast = function()
        error("toast boom")
    end
    deliver(world, snapshot(0, 4, entry("A")))
    deliver(world, snapshot(1, 4, entry("A"), entry("B")))
    expectEqual(controller:getRevision(), 1)
    expectTrue(#world.logs >= 2)
    expectTrue(presenter:isStarted())
end)

-- construction ------------------------------------------------------------------------------------------------------------

test("the presenter requires complete dependencies", function()
    Harness.expectError(function()
        EvidencePresenter.new({} :: any)
    end)
    local world = newWorld()
    local controller: any = ObjectiveController.new(world.controllerDeps)
    Harness.expectError(function()
        EvidencePresenter.new({ controller = controller, ui = {}, text = Messages, log = world.controllerDeps.log } :: any)
    end)
    Harness.expectError(function()
        EvidencePresenter.new({ controller = controller, ui = world.uiPort, text = {}, log = world.controllerDeps.log } :: any)
    end)
end)

test("buildState is pure and handles an empty model", function()
    local model = EvidenceView.new():getViewModel()
    local state = EvidencePresenter.buildState(model, true, Messages)
    expectFalse(state.visible)
    expectFalse(state.journalOpen)
    expectEqual(state.counter, "EVIDENCE 0")
    expectEqual(#state.entries, 0)
end)
