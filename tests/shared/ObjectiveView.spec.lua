--!strict
local Harness = require("../Harness")
local ObjectiveView = require("../../src/shared/Objective/ObjectiveView")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual
local Status = ObjectiveView.Status

local function slotList(required: number, filled: number): { any }
    local slots = {}
    for index = 1, required do
        table.insert(slots, { label = "Slot " .. index, filled = index <= filled })
    end
    return slots
end

local function entry(id: string, importance: string, state: string, required: number?, filled: number?): any
    local count = required or 1
    local done = filled or 0
    return {
        id = id,
        title = "Title " .. id,
        description = "Description " .. id,
        importance = importance,
        state = state,
        filled = done,
        required = count,
        slots = slotList(count, done),
    }
end

local function snapshot(revision: number, ...: any): any
    return { v = 1, revision = revision, objectives = { ... } }
end

local function sliceSnapshot(revision: number): any
    return snapshot(
        revision,
        entry("P", "REQUIRED", "AVAILABLE", 3, 0),
        entry("W", "REQUIRED", "LOCKED"),
        entry("X", "REQUIRED", "LOCKED"),
        entry("O", "OPTIONAL", "AVAILABLE")
    )
end

local function ids(entries: { any }): string
    local list = {}
    for _, item in ipairs(entries) do
        table.insert(list, item.id)
    end
    return table.concat(list, ",")
end

-- acceptance and revisions ------------------------------------------------------------------------------------------

test("a new view is empty, unsynced and starts at revision -1", function()
    local view = ObjectiveView.new()
    expectEqual(view:getRevision(), -1)
    expectEqual(ObjectiveView.InitialRevision, -1)
    expectFalse(view:isSynced())
    local model = view:getViewModel()
    expectEqual(#model.entries, 0)
    expectFalse(model.synced)
    expectEqual(model.requiredTotal, 0)
end)

test("the initial snapshot (revision 0) is accepted and is a baseline without events", function()
    local view = ObjectiveView.new()
    local status, events = view:applySnapshot(sliceSnapshot(0))
    expectEqual(status, Status.Applied)
    expectEqual(#events, 0)
    expectTrue(view:isSynced())
    expectEqual(view:getRevision(), 0)
    expectEqual(ids(view:getViewModel().entries), "P,W,X,O")
end)

test("a newer revision replaces the previous snapshot", function()
    local view = ObjectiveView.new()
    view:applySnapshot(sliceSnapshot(0))
    local status = view:applySnapshot(snapshot(1, entry("P", "REQUIRED", "IN_PROGRESS", 3, 1), entry("W", "REQUIRED", "LOCKED")))
    expectEqual(status, Status.Applied)
    expectEqual(view:getRevision(), 1)
    local model = view:getViewModel()
    expectEqual(ids(model.entries), "P,W", "the latest snapshot is authoritative for what is present")
    expectEqual(model.entries[1].filled, 1)
    expectEqual(model.entries[1].state, "IN_PROGRESS")
end)

test("a stale revision is ignored", function()
    local view = ObjectiveView.new()
    view:applySnapshot(sliceSnapshot(0))
    view:applySnapshot(snapshot(5, entry("P", "REQUIRED", "COMPLETED", 3, 3)))
    local status, events = view:applySnapshot(sliceSnapshot(3))
    expectEqual(status, Status.Stale)
    expectEqual(#events, 0)
    expectEqual(view:getRevision(), 5)
    expectEqual(view:getViewModel().entries[1].state, "COMPLETED")
end)

test("a duplicate revision changes nothing and reports no events", function()
    local view = ObjectiveView.new()
    view:applySnapshot(sliceSnapshot(0))
    view:applySnapshot(snapshot(1, entry("P", "REQUIRED", "COMPLETED", 3, 3)))
    local before = view:getViewModel()
    local status, events = view:applySnapshot(snapshot(1, entry("P", "REQUIRED", "FAILED", 3, 0)))
    expectEqual(status, Status.Duplicate, "same revision is never re-applied, whatever it contains")
    expectEqual(#events, 0)
    expectEqual(view:getViewModel().entries[1].state, before.entries[1].state)
    expectEqual(view:getRevision(), 1)
end)

test("out-of-order delivery converges on the highest revision", function()
    local snapshots = {}
    for revision = 0, 4 do
        table.insert(snapshots, snapshot(revision, entry("P", "REQUIRED", "IN_PROGRESS", 3, math.min(revision, 2)), entry("O", "OPTIONAL", "AVAILABLE")))
    end
    local order = { 2, 0, 4, 1, 3, 4, 0 }
    local view = ObjectiveView.new()
    for _, index in ipairs(order) do
        view:applySnapshot(snapshots[index + 1])
    end
    expectEqual(view:getRevision(), 4)
end)

-- malformed ---------------------------------------------------------------------------------------------------------

test("malformed payloads are rejected as a whole and keep the last valid state", function()
    local view = ObjectiveView.new()
    view:applySnapshot(sliceSnapshot(0))
    local function bad(label: string, payload: any)
        local status, events = view:applySnapshot(payload)
        expectEqual(status, Status.Malformed, label)
        expectEqual(#events, 0, label)
        expectEqual(view:getRevision(), 0, label)
        expectEqual(ids(view:getViewModel().entries), "P,W,X,O", label)
    end
    bad("nil", nil)
    bad("string", "x")
    bad("number", 5)
    bad("empty table", {})
    bad("metatable", setmetatable(sliceSnapshot(9), {}))
    bad("wrong version", { v = 2, revision = 9, objectives = {} })
    bad("missing version", { revision = 9, objectives = {} })
    bad("missing revision", { v = 1, objectives = {} })
    bad("negative revision", { v = 1, revision = -1, objectives = {} })
    bad("fractional revision", { v = 1, revision = 1.5, objectives = {} })
    bad("nan revision", { v = 1, revision = 0 / 0, objectives = {} })
    bad("infinite revision", { v = 1, revision = math.huge, objectives = {} })
    bad("string revision", { v = 1, revision = "9", objectives = {} })
    bad("missing objectives", { v = 1, revision = 9 })
    bad("objectives not an array", { v = 1, revision = 9, objectives = "x" })
    bad("sparse objectives", { v = 1, revision = 9, objectives = { [2] = entry("A", "REQUIRED", "AVAILABLE") } })
    bad("map objectives", { v = 1, revision = 9, objectives = { a = entry("A", "REQUIRED", "AVAILABLE") } })
    bad("entry not a table", snapshot(9, "x"))
end)

test("entry validation", function()
    local function status(mutate: (any) -> ()): string
        local view = ObjectiveView.new()
        local candidate = entry("A", "REQUIRED", "AVAILABLE", 2, 1)
        mutate(candidate)
        local result = view:applySnapshot(snapshot(0, candidate))
        if result ~= Status.Applied then
            expectFalse(view:isSynced())
            expectEqual(#view:getViewModel().entries, 0)
        end
        return result
    end
    expectEqual(status(function() end), Status.Applied)
    expectEqual(status(function(e: any) e.id = "" end), Status.Malformed)
    expectEqual(status(function(e: any) e.id = 5 end), Status.Malformed)
    expectEqual(status(function(e: any) e.id = string.rep("A", 33) end), Status.Malformed)
    expectEqual(status(function(e: any) e.title = "" end), Status.Malformed)
    expectEqual(status(function(e: any) e.title = string.rep("x", 65) end), Status.Malformed)
    expectEqual(status(function(e: any) e.title = "bad\nline" end), Status.Malformed)
    expectEqual(status(function(e: any) e.title = "bad \255 utf8" end), Status.Malformed)
    expectEqual(status(function(e: any) e.description = 5 end), Status.Malformed)
    expectEqual(status(function(e: any) e.description = string.rep("x", 161) end), Status.Malformed)
    expectEqual(status(function(e: any) e.description = "" end), Status.Applied, "an empty description is allowed")
    expectEqual(status(function(e: any) e.importance = "ALTERNATIVE" end), Status.Malformed)
    expectEqual(status(function(e: any) e.importance = nil end), Status.Malformed)
    expectEqual(status(function(e: any) e.state = "BOGUS" end), Status.Malformed)
    expectEqual(status(function(e: any) e.state = nil end), Status.Malformed)
    expectEqual(status(function(e: any) e.required = 0 end), Status.Malformed)
    expectEqual(status(function(e: any) e.required = 9 end), Status.Malformed)
    expectEqual(status(function(e: any) e.filled = 3 end), Status.Malformed, "filled above required")
    expectEqual(status(function(e: any) e.filled = -1 end), Status.Malformed)
    expectEqual(status(function(e: any) e.filled = 0.5 end), Status.Malformed)
    expectEqual(status(function(e: any) e.filled = 0 end), Status.Malformed, "progress that disagrees with its slots is not shown")
    expectEqual(status(function(e: any) e.slots = nil end), Status.Malformed)
    expectEqual(status(function(e: any) e.slots = { { label = "x", filled = true } } end), Status.Malformed, "slot count differs from required")
    expectEqual(status(function(e: any) e.slots[1].label = "" end), Status.Malformed)
    expectEqual(status(function(e: any) e.slots[1].filled = "yes" end), Status.Malformed)
    expectEqual(status(function(e: any) e.slots[2] = "x" end), Status.Malformed)
end)

test("duplicate objective ids and too many objectives are rejected", function()
    local view = ObjectiveView.new()
    expectEqual(view:applySnapshot(snapshot(0, entry("A", "REQUIRED", "AVAILABLE"), entry("A", "OPTIONAL", "AVAILABLE"))), Status.Malformed)
    local many = {}
    for index = 1, 33 do
        table.insert(many, entry("O" .. index, "OPTIONAL", "AVAILABLE"))
    end
    expectEqual(view:applySnapshot({ v = 1, revision = 0, objectives = many }), Status.Malformed)
    table.remove(many)
    expectEqual(view:applySnapshot({ v = 1, revision = 0, objectives = many }), Status.Applied, "32 objectives are accepted")
end)

test("a malformed payload never advances the revision, so a valid one with that revision still applies", function()
    local view = ObjectiveView.new()
    expectEqual(view:applySnapshot({ v = 1, revision = 7, objectives = "x" }), Status.Malformed)
    expectEqual(view:getRevision(), -1)
    expectEqual(view:applySnapshot(sliceSnapshot(7)), Status.Applied)
end)

-- empty collections -------------------------------------------------------------------------------------------------

test("an empty objective list is valid and renders as an empty model; a missing list is malformed", function()
    local view = ObjectiveView.new()
    local status = view:applySnapshot({ v = 1, revision = 0, objectives = {} })
    expectEqual(status, Status.Applied)
    expectTrue(view:isSynced())
    local model = view:getViewModel()
    expectEqual(#model.entries, 0)
    expectEqual(model.requiredTotal, 0)
    local shown, hidden = ObjectiveView.tracked(model, 3)
    expectEqual(#shown, 0)
    expectEqual(hidden, 0)
    expectEqual(view:applySnapshot({ v = 1, revision = 1 }), Status.Malformed)
    expectEqual(#view:getViewModel().entries, 0)
end)

test("tracked works on an unsynced model", function()
    local shown, hidden = ObjectiveView.tracked(ObjectiveView.new():getViewModel(), 3)
    expectEqual(#shown, 0)
    expectEqual(hidden, 0)
end)

-- visibility ---------------------------------------------------------------------------------------------------------

test("only entries present in the snapshot are exposed; extra server fields never leak through", function()
    local view = ObjectiveView.new()
    local withExtras = entry("A", "REQUIRED", "AVAILABLE")
    withExtras.pointId = "SECRET_POINT"
    withExtras.userId = 424242
    withExtras.reason = "internal_reason"
    withExtras.slots[1].pointId = "SECRET_POINT"
    view:applySnapshot(snapshot(0, withExtras))
    local model = view:getViewModel()
    expectEqual(#model.entries, 1)
    local item: any = model.entries[1]
    expectEqual(item.pointId, nil)
    expectEqual(item.userId, nil)
    expectEqual(item.reason, nil)
    expectEqual(item.slots[1].pointId, nil)
    local function scan(value: any)
        if type(value) == "table" then
            for key, inner in pairs(value) do
                expectTrue(key ~= "pointId" and key ~= "userId" and key ~= "reason")
                scan(inner)
            end
        elseif type(value) == "string" then
            expectFalse(string.find(value, "SECRET", 1, true) ~= nil)
            expectFalse(string.find(value, "internal_reason", 1, true) ~= nil)
        end
    end
    scan(model)
end)

test("a hidden objective stays absent until the server includes it, then appears with a notification event", function()
    local view = ObjectiveView.new()
    view:applySnapshot(snapshot(0, entry("A", "REQUIRED", "AVAILABLE")))
    expectEqual(ids(view:getViewModel().entries), "A", "the client does not know about hidden objectives")
    local status, events = view:applySnapshot(snapshot(1, entry("A", "REQUIRED", "COMPLETED"), entry("SECRET", "REQUIRED", "AVAILABLE")))
    expectEqual(status, Status.Applied)
    expectEqual(ids(view:getViewModel().entries), "A,SECRET")
    local kinds = {}
    for _, event in ipairs(events) do
        table.insert(kinds, event.kind .. ":" .. event.id)
    end
    expectEqual(table.concat(kinds, ","), "COMPLETED:A,UNLOCKED:SECRET")
end)

test("the client never fabricates entries or progress", function()
    local view = ObjectiveView.new()
    view:applySnapshot(snapshot(0, entry("A", "REQUIRED", "AVAILABLE", 3, 1)))
    local item = view:getViewModel().entries[1]
    expectEqual(item.filled, 1)
    expectEqual(item.required, 3)
    expectEqual(#item.slots, 3)
    expectTrue(item.slots[1].filled)
    expectFalse(item.slots[2].filled)
end)

-- required / optional ------------------------------------------------------------------------------------------------

test("required and optional objectives are represented distinctly", function()
    local view = ObjectiveView.new()
    view:applySnapshot(sliceSnapshot(0))
    local model = view:getViewModel()
    local required, optional = model.entries[1], model.entries[4]
    expectTrue(required.isRequired)
    expectFalse(required.isOptional)
    expectTrue(optional.isOptional)
    expectFalse(optional.isRequired)
    expectEqual(required.importance, "REQUIRED")
    expectEqual(optional.importance, "OPTIONAL")
    expectEqual(model.requiredTotal, 3, "optional objectives are not counted as required")
    expectEqual(model.requiredDone, 0)
end)

test("state flags distinguish locked, actionable and finished objectives", function()
    local view = ObjectiveView.new()
    view:applySnapshot(snapshot(
        0,
        entry("L", "REQUIRED", "LOCKED"),
        entry("A", "REQUIRED", "AVAILABLE"),
        entry("I", "REQUIRED", "IN_PROGRESS", 2, 1),
        entry("C", "REQUIRED", "COMPLETED", 1, 1),
        entry("F", "OPTIONAL", "FAILED"),
        entry("X", "OPTIONAL", "CANCELLED")
    ))
    local byId: { [string]: any } = {}
    for _, item in ipairs(view:getViewModel().entries) do
        byId[item.id] = item
    end
    expectTrue(byId.L.isLocked and not byId.L.isActionable and not byId.L.isTerminal)
    expectTrue(byId.A.isActionable and not byId.A.isLocked)
    expectTrue(byId.I.isActionable and byId.I.hasProgress)
    expectFalse(byId.A.hasProgress, "a single contribution has no meaningful progress")
    expectTrue(byId.C.isTerminal and not byId.C.isActionable)
    expectTrue(byId.F.isTerminal and byId.X.isTerminal)
    expectEqual(view:getViewModel().requiredDone, 1)
    expectEqual(view:getViewModel().requiredTotal, 4)
end)

test("server order is preserved", function()
    local view = ObjectiveView.new()
    view:applySnapshot(snapshot(0, entry("Z", "OPTIONAL", "AVAILABLE"), entry("A", "REQUIRED", "AVAILABLE"), entry("M", "REQUIRED", "LOCKED")))
    expectEqual(ids(view:getViewModel().entries), "Z,A,M")
    local shown = ObjectiveView.tracked(view:getViewModel(), 5)
    expectEqual(ids(shown), "Z,A", "the tracker does not re-rank")
end)

-- tracked -----------------------------------------------------------------------------------------------------------

test("the tracker shows actionable entries only, bounded, with the overflow count", function()
    local view = ObjectiveView.new()
    view:applySnapshot(snapshot(
        0,
        entry("A", "REQUIRED", "COMPLETED", 1, 1),
        entry("B", "REQUIRED", "AVAILABLE"),
        entry("C", "REQUIRED", "LOCKED"),
        entry("D", "OPTIONAL", "IN_PROGRESS", 2, 1),
        entry("E", "OPTIONAL", "AVAILABLE"),
        entry("F", "OPTIONAL", "AVAILABLE")
    ))
    local model = view:getViewModel()
    local shown, hidden = ObjectiveView.tracked(model, 2)
    expectEqual(ids(shown), "B,D")
    expectEqual(hidden, 2)
    local all, none = ObjectiveView.tracked(model, 10)
    expectEqual(ids(all), "B,D,E,F")
    expectEqual(none, 0)
    local one = ObjectiveView.tracked(model, 0)
    expectEqual(#one, 1, "a non-positive limit falls back to one line")
    local fallback = ObjectiveView.tracked(model, "x")
    expectEqual(#fallback, 1)
    local fractional = ObjectiveView.tracked(model, 2.9)
    expectEqual(#fractional, 2)
end)

-- events ------------------------------------------------------------------------------------------------------------

local function eventsBetween(first: any, second: any): { any }
    local view = ObjectiveView.new()
    view:applySnapshot(first)
    local _, events = view:applySnapshot(second)
    return events
end

test("transition events are derived from accepted snapshots only", function()
    local unlocked = eventsBetween(snapshot(0, entry("A", "REQUIRED", "LOCKED")), snapshot(1, entry("A", "REQUIRED", "AVAILABLE")))
    expectEqual(#unlocked, 1)
    expectEqual(unlocked[1].kind, "UNLOCKED")
    expectEqual(unlocked[1].id, "A")
    expectEqual(unlocked[1].title, "Title A")
    expectEqual(unlocked[1].importance, "REQUIRED")

    local completed = eventsBetween(snapshot(0, entry("A", "REQUIRED", "IN_PROGRESS", 2, 1)), snapshot(1, entry("A", "REQUIRED", "COMPLETED", 2, 2)))
    expectEqual(completed[1].kind, "COMPLETED")

    local failed = eventsBetween(snapshot(0, entry("A", "REQUIRED", "AVAILABLE")), snapshot(1, entry("A", "REQUIRED", "FAILED")))
    expectEqual(failed[1].kind, "FAILED")

    local cancelled = eventsBetween(snapshot(0, entry("A", "OPTIONAL", "AVAILABLE")), snapshot(1, entry("A", "OPTIONAL", "CANCELLED")))
    expectEqual(cancelled[1].kind, "CANCELLED")
    expectEqual(cancelled[1].importance, "OPTIONAL")

    local optionalDone = eventsBetween(snapshot(0, entry("O", "OPTIONAL", "AVAILABLE")), snapshot(1, entry("O", "OPTIONAL", "COMPLETED")))
    expectEqual(optionalDone[1].kind, "COMPLETED")
    expectEqual(optionalDone[1].importance, "OPTIONAL")
end)

test("progress inside an objective and unchanged entries produce no events", function()
    expectEqual(#eventsBetween(snapshot(0, entry("A", "REQUIRED", "AVAILABLE", 3, 0)), snapshot(1, entry("A", "REQUIRED", "IN_PROGRESS", 3, 1))), 0)
    expectEqual(#eventsBetween(snapshot(0, entry("A", "REQUIRED", "IN_PROGRESS", 3, 1)), snapshot(1, entry("A", "REQUIRED", "IN_PROGRESS", 3, 2))), 0)
    expectEqual(#eventsBetween(snapshot(0, entry("A", "REQUIRED", "LOCKED")), snapshot(1, entry("A", "REQUIRED", "LOCKED"))), 0)
    expectEqual(#eventsBetween(snapshot(0, entry("A", "REQUIRED", "COMPLETED")), snapshot(1, entry("A", "REQUIRED", "COMPLETED"))), 0)
end)

test("a locked entry that newly appears is silent; an actionable one is announced", function()
    expectEqual(#eventsBetween(snapshot(0, entry("A", "REQUIRED", "AVAILABLE")), snapshot(1, entry("A", "REQUIRED", "AVAILABLE"), entry("B", "REQUIRED", "LOCKED"))), 0)
    local events = eventsBetween(snapshot(0, entry("A", "REQUIRED", "AVAILABLE")), snapshot(1, entry("A", "REQUIRED", "AVAILABLE"), entry("B", "OPTIONAL", "AVAILABLE")))
    expectEqual(#events, 1)
    expectEqual(events[1].id, "B")
end)

test("one snapshot can carry several transitions, in server order", function()
    local events = eventsBetween(
        snapshot(0, entry("A", "REQUIRED", "IN_PROGRESS", 3, 2), entry("B", "REQUIRED", "LOCKED"), entry("C", "REQUIRED", "LOCKED")),
        snapshot(1, entry("A", "REQUIRED", "COMPLETED", 3, 3), entry("B", "REQUIRED", "AVAILABLE"), entry("C", "REQUIRED", "LOCKED"))
    )
    expectEqual(#events, 2)
    expectEqual(events[1].kind .. events[1].id, "COMPLETEDA")
    expectEqual(events[2].kind .. events[2].id, "UNLOCKEDB")
end)

test("the first snapshot after a reset is a baseline again", function()
    local view = ObjectiveView.new()
    view:applySnapshot(snapshot(0, entry("A", "REQUIRED", "AVAILABLE")))
    view:reset()
    expectFalse(view:isSynced())
    expectEqual(view:getRevision(), -1)
    local status, events = view:applySnapshot(snapshot(0, entry("A", "REQUIRED", "COMPLETED")))
    expectEqual(status, Status.Applied, "revision 0 is accepted again after a reset")
    expectEqual(#events, 0)
end)

-- copies ------------------------------------------------------------------------------------------------------------

test("the view model is a copy: mutating it cannot change the mirror", function()
    local view = ObjectiveView.new()
    view:applySnapshot(sliceSnapshot(0))
    local first = view:getViewModel()
    first.entries[1].state = "COMPLETED"
    first.entries[1].slots[1].filled = true
    first.entries[1].title = "Tampered"
    table.remove(first.entries)
    local second = view:getViewModel()
    expectEqual(#second.entries, 4)
    expectEqual(second.entries[1].state, "AVAILABLE")
    expectFalse(second.entries[1].slots[1].filled)
    expectEqual(second.entries[1].title, "Title P")
end)

test("the payload table is copied on accept: mutating it afterwards changes nothing", function()
    local view = ObjectiveView.new()
    local payload = sliceSnapshot(0)
    view:applySnapshot(payload)
    payload.objectives[1].state = "FAILED"
    payload.objectives[1].slots[1].filled = true
    payload.objectives[1].title = "Tampered"
    local item = view:getViewModel().entries[1]
    expectEqual(item.state, "AVAILABLE")
    expectEqual(item.title, "Title P")
    expectFalse(item.slots[1].filled)
end)
