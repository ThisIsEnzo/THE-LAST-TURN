--!strict
local Harness = require("../Harness")
local EvidenceView = require("../../src/shared/Evidence/EvidenceView")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual
local Status = EvidenceView.Status

local function entry(id: string, state: string?, sources: number?, required: number?): any
    return {
        id = id,
        title = "Title " .. id,
        category = "ENVIRONMENTAL",
        state = state or "OBSERVED",
        sources = sources or 1,
        required = required or 2,
    }
end

local function snapshot(revision: number, total: any, ...: any): any
    return { v = 1, revision = revision, total = total, evidence = { ... } }
end

local function ids(model: any): string
    local list = {}
    for _, item in ipairs(model.entries) do
        table.insert(list, item.id)
    end
    return table.concat(list, ",")
end

-- acceptance and revisions ------------------------------------------------------------------------------------------

test("a new view is empty, unsynced and starts at revision -1", function()
    local view = EvidenceView.new()
    expectEqual(view:getRevision(), -1)
    expectEqual(EvidenceView.InitialRevision, -1)
    expectFalse(view:isSynced())
    local model = view:getViewModel()
    expectEqual(#model.entries, 0)
    expectEqual(model.discovered, 0)
    expectEqual(model.total, nil)
    expectFalse(model.synced)
end)

test("the initial snapshot (revision 0, nothing discovered) is accepted as a baseline", function()
    local view = EvidenceView.new()
    local status, events = view:applySnapshot(snapshot(0, 4))
    expectEqual(status, Status.Applied)
    expectEqual(#events, 0)
    expectTrue(view:isSynced())
    local model = view:getViewModel()
    expectEqual(model.discovered, 0)
    expectEqual(model.total, 4)
    expectEqual(#model.entries, 0)
end)

test("a snapshot taken from an existing authoritative state initializes the view without announcing anything", function()
    local view = EvidenceView.new()
    local status, events = view:applySnapshot(snapshot(7, 4, entry("COLD_SPOT", "CONFIRMED", 2, 2), entry("MOVED_OBJECT", "OBSERVED", 1, 2)))
    expectEqual(status, Status.Applied)
    expectEqual(#events, 0, "evidence that was already known is never announced")
    local model = view:getViewModel()
    expectEqual(model.revision, 7)
    expectEqual(model.discovered, 2)
    expectEqual(model.confirmed, 1)
    expectEqual(ids(model), "COLD_SPOT,MOVED_OBJECT")
end)

test("a newer revision replaces the state; stale and duplicate revisions change nothing", function()
    local view = EvidenceView.new()
    view:applySnapshot(snapshot(0, 4))
    expectEqual(view:applySnapshot(snapshot(1, 4, entry("A"))), Status.Applied)
    local stale, staleEvents = view:applySnapshot(snapshot(0, 4))
    expectEqual(stale, Status.Stale)
    expectEqual(#staleEvents, 0)
    local duplicate, duplicateEvents = view:applySnapshot(snapshot(1, 4, entry("A"), entry("B")))
    expectEqual(duplicate, Status.Duplicate, "the same revision is never re-applied, whatever it contains")
    expectEqual(#duplicateEvents, 0)
    expectEqual(ids(view:getViewModel()), "A")
    expectEqual(view:getRevision(), 1)
end)

test("out-of-order delivery converges on the highest revision", function()
    local snapshots = {}
    for revision = 0, 4 do
        table.insert(snapshots, snapshot(revision, 6, entry("A", "OBSERVED", 1, 3)))
    end
    local view = EvidenceView.new()
    for _, index in ipairs({ 2, 0, 4, 1, 3, 4, 0 }) do
        view:applySnapshot(snapshots[index + 1])
    end
    expectEqual(view:getRevision(), 4)
end)

-- discovery counting --------------------------------------------------------------------------------------------------

test("one new discovery adds exactly one entry and one DISCOVERED event", function()
    local view = EvidenceView.new()
    view:applySnapshot(snapshot(0, 4))
    local status, events = view:applySnapshot(snapshot(1, 4, entry("COLD_SPOT")))
    expectEqual(status, Status.Applied)
    expectEqual(#events, 1)
    expectEqual(events[1].kind, "DISCOVERED")
    expectEqual(events[1].id, "COLD_SPOT")
    expectEqual(events[1].title, "Title COLD_SPOT")
    expectEqual(view:getViewModel().discovered, 1)
    expectEqual(#view:getViewModel().entries, 1)
end)

test("confirmation of known evidence is announced once and adds no entry", function()
    local view = EvidenceView.new()
    view:applySnapshot(snapshot(0, 4, entry("A", "OBSERVED", 1, 2)))
    local _, events = view:applySnapshot(snapshot(1, 4, entry("A", "CONFIRMED", 2, 2)))
    expectEqual(#events, 1)
    expectEqual(events[1].kind, "CONFIRMED")
    expectEqual(view:getViewModel().discovered, 1)
    expectEqual(view:getViewModel().confirmed, 1)
    local duplicate = view:applySnapshot(snapshot(1, 4, entry("A", "CONFIRMED", 2, 2)))
    expectEqual(duplicate, Status.Duplicate)
end)

test("corroboration progress inside an unconfirmed entry produces no announcement", function()
    local view = EvidenceView.new()
    view:applySnapshot(snapshot(0, 4, entry("A", "OBSERVED", 1, 3)))
    local _, events = view:applySnapshot(snapshot(1, 4, entry("A", "OBSERVED", 2, 3)))
    expectEqual(#events, 0)
    expectEqual(view:getViewModel().entries[1].sources, 2)
end)

test("several discoveries in one snapshot give consistent counts and events in server order", function()
    local view = EvidenceView.new()
    view:applySnapshot(snapshot(0, 4))
    local _, events = view:applySnapshot(snapshot(2, 4, entry("A"), entry("B", "CONFIRMED", 1, 1), entry("C")))
    expectEqual(#events, 3)
    expectEqual(events[1].id .. events[2].id .. events[3].id, "ABC")
    local model = view:getViewModel()
    expectEqual(model.discovered, 3)
    expectEqual(model.confirmed, 1)
    expectEqual(ids(model), "A,B,C")
    expectTrue(model.total ~= nil and model.discovered <= model.total)
end)

test("the first snapshot after a reset is a baseline again", function()
    local view = EvidenceView.new()
    view:applySnapshot(snapshot(3, 4, entry("A")))
    view:reset()
    expectFalse(view:isSynced())
    expectEqual(view:getRevision(), -1)
    expectEqual(#view:getViewModel().entries, 0)
    local status, events = view:applySnapshot(snapshot(0, 4, entry("A")))
    expectEqual(status, Status.Applied)
    expectEqual(#events, 0)
end)

-- the total ---------------------------------------------------------------------------------------------------------------

test("the total comes only from the server and is never invented", function()
    local view = EvidenceView.new()
    view:applySnapshot({ v = 1, revision = 0, evidence = { entry("A") } })
    local model = view:getViewModel()
    expectEqual(model.total, nil, "no total was supplied")
    expectEqual(model.discovered, 1)
    view:applySnapshot(snapshot(1, 5, entry("A")))
    expectEqual(view:getViewModel().total, 5)
end)

test("an inconsistent total is rejected", function()
    local view = EvidenceView.new()
    expectEqual(view:applySnapshot(snapshot(0, 1, entry("A"), entry("B"))), Status.Malformed, "fewer than discovered")
    expectEqual(view:applySnapshot(snapshot(0, 0)), Status.Malformed)
    expectEqual(view:applySnapshot(snapshot(0, 33)), Status.Malformed)
    expectEqual(view:applySnapshot(snapshot(0, 2.5)), Status.Malformed)
    expectEqual(view:applySnapshot(snapshot(0, "4")), Status.Malformed)
    expectFalse(view:isSynced())
end)

-- privacy -------------------------------------------------------------------------------------------------------------------

test("undiscovered evidence is malformed: an UNKNOWN entry rejects the whole snapshot", function()
    local view = EvidenceView.new()
    view:applySnapshot(snapshot(0, 4, entry("A")))
    local status = view:applySnapshot(snapshot(1, 4, entry("A"), entry("SECRET", "UNKNOWN", 1, 2)))
    expectEqual(status, Status.Malformed)
    expectEqual(ids(view:getViewModel()), "A", "the secret never reaches the model")
    expectEqual(view:getRevision(), 0)
    local lower = view:applySnapshot(snapshot(1, 4, entry("SECRET", "unknown")))
    expectEqual(lower, Status.Malformed)
end)

test("only entries present in the snapshot are exposed; extra server fields never leak through", function()
    local view = EvidenceView.new()
    local withExtras = entry("A")
    withExtras.sourceId = "SECRET_SOURCE"
    withExtras.position = { 1, 2, 3 }
    withExtras.observerId = 424242
    withExtras.description = "do not trust"
    view:applySnapshot(snapshot(0, 4, withExtras))
    local model = view:getViewModel()
    expectEqual(#model.entries, 1)
    local function scan(value: any)
        if type(value) == "table" then
            for key, inner in pairs(value) do
                expectTrue(key ~= "sourceId" and key ~= "position" and key ~= "observerId" and key ~= "description", "key " .. tostring(key))
                scan(inner)
            end
        elseif type(value) == "string" then
            expectFalse(string.find(value, "SECRET_SOURCE", 1, true) ~= nil)
        elseif type(value) == "number" then
            expectFalse(value == 424242)
        end
    end
    scan(model)
end)

test("the client does not fabricate entries or progress", function()
    local view = EvidenceView.new()
    view:applySnapshot(snapshot(0, 4, entry("A", "OBSERVED", 2, 3)))
    local item = view:getViewModel().entries[1]
    expectEqual(item.sources, 2)
    expectEqual(item.required, 3)
    expectTrue(item.hasCorroboration)
    expectFalse(item.isConfirmed)
    local single = EvidenceView.new()
    single:applySnapshot(snapshot(0, 4, entry("B", "OBSERVED", 1, 1)))
    expectFalse(single:getViewModel().entries[1].hasCorroboration)
end)

-- malformed ---------------------------------------------------------------------------------------------------------------

test("malformed payloads are rejected as a whole and keep the last valid state", function()
    local view = EvidenceView.new()
    view:applySnapshot(snapshot(0, 4, entry("A")))
    local function bad(label: string, payload: any)
        local status, events = view:applySnapshot(payload)
        expectEqual(status, Status.Malformed, label)
        expectEqual(#events, 0, label)
        expectEqual(view:getRevision(), 0, label)
        expectEqual(ids(view:getViewModel()), "A", label)
    end
    bad("nil", nil)
    bad("string", "x")
    bad("empty table", {})
    bad("metatable", setmetatable(snapshot(9, 4), {}))
    bad("wrong version", { v = 2, revision = 9, evidence = {} })
    bad("missing version", { revision = 9, evidence = {} })
    bad("negative revision", { v = 1, revision = -1, evidence = {} })
    bad("fractional revision", { v = 1, revision = 1.5, evidence = {} })
    bad("nan revision", { v = 1, revision = 0 / 0, evidence = {} })
    bad("string revision", { v = 1, revision = "9", evidence = {} })
    bad("missing list", { v = 1, revision = 9, total = 4 })
    bad("list not an array", { v = 1, revision = 9, evidence = "x" })
    bad("sparse list", { v = 1, revision = 9, evidence = { [2] = entry("A") } })
    bad("map list", { v = 1, revision = 9, evidence = { a = entry("A") } })
    bad("entry not a table", snapshot(9, 4, "x"))
end)

test("every invalid entry field rejects the snapshot", function()
    local function status(mutate: (any) -> ()): string
        local view = EvidenceView.new()
        local candidate = entry("A", "OBSERVED", 1, 2)
        mutate(candidate)
        local result = view:applySnapshot(snapshot(0, 4, candidate))
        if result ~= Status.Applied then
            expectFalse(view:isSynced())
            expectEqual(#view:getViewModel().entries, 0)
        end
        return result
    end
    expectEqual(status(function() end), Status.Applied)
    expectEqual(status(function(e: any) e.id = "" end), Status.Malformed)
    expectEqual(status(function(e: any) e.id = "lower" end), Status.Malformed)
    expectEqual(status(function(e: any) e.id = 5 end), Status.Malformed)
    expectEqual(status(function(e: any) e.title = "" end), Status.Malformed)
    expectEqual(status(function(e: any) e.title = string.rep("x", 65) end), Status.Malformed)
    expectEqual(status(function(e: any) e.title = "bad\nline" end), Status.Malformed)
    expectEqual(status(function(e: any) e.title = "nel\194\133here" end), Status.Malformed)
    expectEqual(status(function(e: any) e.title = "bad \255 utf8" end), Status.Malformed)
    expectEqual(status(function(e: any) e.category = "lower" end), Status.Malformed)
    expectEqual(status(function(e: any) e.category = nil end), Status.Malformed)
    expectEqual(status(function(e: any) e.state = nil end), Status.Malformed)
    expectEqual(status(function(e: any) e.state = "BOGUS" end), Status.Malformed)
    expectEqual(status(function(e: any) e.sources = 0 end), Status.Malformed)
    expectEqual(status(function(e: any) e.sources = 17 end), Status.Malformed)
    expectEqual(status(function(e: any) e.sources = 1.5 end), Status.Malformed)
    expectEqual(status(function(e: any) e.required = 0 end), Status.Malformed)
    expectEqual(status(function(e: any) e.required = 9 end), Status.Malformed)
    expectEqual(status(function(e: any) e.state = "CONFIRMED"; e.sources = 1 end), Status.Malformed, "confirmed without corroboration")
    expectEqual(status(function(e: any) e.state = "CONFIRMED"; e.sources = 2 end), Status.Applied)
end)

test("duplicate ids and too many entries are rejected", function()
    local view = EvidenceView.new()
    expectEqual(view:applySnapshot(snapshot(0, 4, entry("A"), entry("A"))), Status.Malformed)
    local many = {}
    for index = 1, 33 do
        table.insert(many, entry("E" .. index))
    end
    expectEqual(view:applySnapshot({ v = 1, revision = 0, evidence = many }), Status.Malformed)
    table.remove(many)
    expectEqual(view:applySnapshot({ v = 1, revision = 0, evidence = many }), Status.Applied, "32 entries are accepted")
end)

test("a malformed payload never advances the revision", function()
    local view = EvidenceView.new()
    expectEqual(view:applySnapshot({ v = 1, revision = 7, evidence = "x" }), Status.Malformed)
    expectEqual(view:getRevision(), -1)
    expectEqual(view:applySnapshot(snapshot(7, 4)), Status.Applied)
end)

test("an empty evidence list is valid; a missing one is not", function()
    local view = EvidenceView.new()
    expectEqual(view:applySnapshot({ v = 1, revision = 0, total = 4, evidence = {} }), Status.Applied)
    expectEqual(#view:getViewModel().entries, 0)
    expectEqual(view:applySnapshot({ v = 1, revision = 1, total = 4 }), Status.Malformed)
end)

-- copies ----------------------------------------------------------------------------------------------------------------

test("the view model is a copy and the payload is copied on accept", function()
    local view = EvidenceView.new()
    local payload = snapshot(0, 4, entry("A"), entry("B"))
    view:applySnapshot(payload)
    payload.evidence[1].title = "Tampered"
    payload.evidence[1].state = "CONFIRMED"
    local first = view:getViewModel()
    first.entries[1].title = "Tampered again"
    table.remove(first.entries)
    first.discovered = 99
    local second = view:getViewModel()
    expectEqual(#second.entries, 2)
    expectEqual(second.entries[1].title, "Title A")
    expectEqual(second.entries[1].state, "OBSERVED")
    expectEqual(second.discovered, 2)
end)
