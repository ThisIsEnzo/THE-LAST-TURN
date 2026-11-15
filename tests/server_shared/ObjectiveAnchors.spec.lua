--!strict
local Harness = require("../Harness")
local ObjectiveAnchors = require("../../src/server_shared/Objective/ObjectiveAnchors")
local ObjectiveContent = require("../../src/mission/server/Objective/ObjectiveContent")
local ObjectiveGraph = require("../../src/server_shared/Objective/ObjectiveGraph")
local ObjectiveRuntime = require("../../src/server_shared/Objective/ObjectiveRuntime")
local ObjectiveConfig = require("../../src/mission/server/Objective/ObjectiveConfig")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local function candidate(pointId: any, anchor: any): any
    return { pointId = pointId, anchor = anchor }
end

local function contentPointIds(): { string }
    local ids = {}
    for _, objective in ipairs((ObjectiveContent :: any).objectives) do
        for _, slot in ipairs(objective.completion.slots) do
            table.insert(ids, slot.pointId)
        end
    end
    return ids
end

test("the tag and attribute names are the ones fixed by design decision D5", function()
    expectEqual(ObjectiveAnchors.Tag, "ObjectivePoint")
    expectEqual(ObjectiveAnchors.Attribute, "PointId")
end)

test("unique, valid ids resolve to their anchors", function()
    local a, b = { name = "a" }, { name = "b" }
    local index = ObjectiveAnchors.index({ candidate("POWER_FUSE_A", a), candidate("WING_ACCESS_PANEL", b) })
    expectTrue(index.anchors.POWER_FUSE_A == a)
    expectTrue(index.anchors.WING_ACCESS_PANEL == b)
    expectEqual(#index.duplicates, 0)
    expectEqual(index.invalid, 0)
end)

test("an id claimed twice is ambiguous: it resolves to nothing and is reported", function()
    local index = ObjectiveAnchors.index({ candidate("A", 1), candidate("B", 2), candidate("A", 3), candidate("C", 4), candidate("A", 5), candidate("C", 6) })
    expectEqual(index.anchors.A, nil)
    expectEqual(index.anchors.C, nil)
    expectEqual(index.anchors.B, 2)
    expectEqual(table.concat(index.duplicates, ","), "A,C", "sorted, each id once")
end)

test("entries without a valid id or without an anchor are counted and ignored", function()
    local index = ObjectiveAnchors.index({
        candidate(nil, 1),
        candidate("lowercase", 2),
        candidate("HAS SPACE", 3),
        candidate("", 4),
        candidate(5, 5),
        candidate(string.rep("A", 33), 6),
        candidate("NO_ANCHOR", nil),
        "not a table",
        candidate("GOOD", 7),
        candidate(string.rep("A", 32), 8),
    })
    expectEqual(index.invalid, 8)
    expectEqual(index.anchors.GOOD, 7)
    expectEqual(index.anchors[string.rep("A", 32)], 8)
    expectEqual(index.anchors.NO_ANCHOR, nil)
end)

test("the index does not depend on the order of the candidates", function()
    local list = { candidate("A", 1), candidate("B", 2), candidate("A", 3), candidate("C", 4), candidate("bad", 5) }
    local reversed = {}
    for index = #list, 1, -1 do
        table.insert(reversed, list[index])
    end
    local first, second = ObjectiveAnchors.index(list), ObjectiveAnchors.index(reversed)
    expectEqual(first.invalid, second.invalid)
    expectEqual(table.concat(first.duplicates, ","), table.concat(second.duplicates, ","))
    expectEqual(first.anchors.B, second.anchors.B)
    expectEqual(first.anchors.C, second.anchors.C)
    expectEqual(first.anchors.A, second.anchors.A)
end)

test("garbage input yields an empty index instead of raising", function()
    for _, bad in ipairs({ "x", 5, false }) do
        local index = ObjectiveAnchors.index(bad)
        expectEqual(next(index.anchors), nil)
        expectEqual(#index.duplicates, 0)
        expectEqual(index.invalid, 0)
    end
    expectEqual(next(ObjectiveAnchors.index(nil).anchors), nil)
    expectEqual(next(ObjectiveAnchors.index({}).anchors), nil)
end)

test("missing lists the unresolved ids in the given order", function()
    local index = ObjectiveAnchors.index({ candidate("B", 1) })
    local missing = ObjectiveAnchors.missing({ "C", "B", "A" }, index)
    expectEqual(table.concat(missing, ","), "C,A")
    expectEqual(#ObjectiveAnchors.missing({}, index), 0)
end)

test("every shipped objective pointId is a valid anchor id and unique", function()
    local ids = contentPointIds()
    expectEqual(#ids, 6)
    local seen: { [string]: boolean } = {}
    for _, id in ipairs(ids) do
        local index = ObjectiveAnchors.index({ candidate(id, true) })
        expectTrue(index.anchors[id] == true, id .. " must be a valid PointId")
        expectFalse(seen[id] == true, id .. " is duplicated")
        seen[id] = true
    end
end)

test("a complete authored map resolves every pointId; a missing or ambiguous one is reported", function()
    local ids = contentPointIds()
    local candidates = {}
    for _, id in ipairs(ids) do
        table.insert(candidates, candidate(id, { id = id }))
    end
    local full = ObjectiveAnchors.index(candidates)
    expectEqual(#ObjectiveAnchors.missing(ids, full), 0)

    local withoutFuse = {}
    for _, entry in ipairs(candidates) do
        if entry.pointId ~= "POWER_FUSE_B" then
            table.insert(withoutFuse, entry)
        end
    end
    expectEqual(table.concat(ObjectiveAnchors.missing(ids, ObjectiveAnchors.index(withoutFuse)), ","), "POWER_FUSE_B")

    local ambiguous = table.clone(candidates)
    table.insert(ambiguous, candidate("EXTRACTION_POINT", { id = "twin" }))
    expectEqual(table.concat(ObjectiveAnchors.missing(ids, ObjectiveAnchors.index(ambiguous)), ","), "EXTRACTION_POINT")
end)

-- integration with the runtime's fail-closed behavior --------------------------------------------------------------

local function runtimeWith(index: any): (any, any)
    local registered: { string } = {}
    local deps: any = {
        graph = ObjectiveGraph,
        core = require("../../src/server_shared/Objective/ObjectiveCore"),
        content = ObjectiveContent,
        config = ObjectiveConfig.Values,
        interaction = {
            register = function(spec: any, anchor: any): (any, string?)
                table.insert(registered, spec.id)
                return { id = spec.id, alive = true }, nil
            end,
            setEnabled = function(): (boolean, string?)
                return true, nil
            end,
            unregister = function(): (boolean, string?)
                return true, nil
            end,
        },
        resolveAnchor = function(pointId: string): any?
            return index.anchors[pointId]
        end,
        lifecycle = {
            isActive = function()
                return true
            end,
            endMission = function() end,
        },
        players = {
            getUserId = function(p: any)
                return p.UserId
            end,
            getPlayer = function()
                return nil
            end,
            isConnected = function()
                return true
            end,
            isAlive = function()
                return true
            end,
        },
        send = function() end,
        defer = function(callback: () -> ())
            callback()
        end,
        now = function()
            return 0
        end,
        log = function() end,
    }
    return ObjectiveRuntime.new(deps), registered
end

test("the runtime starts when every authored anchor resolves", function()
    local candidates = {}
    for _, id in ipairs(contentPointIds()) do
        table.insert(candidates, candidate(id, { id = id }))
    end
    local runtime, registered = runtimeWith(ObjectiveAnchors.index(candidates))
    runtime:start({ expectedUserIds = { 1 } })
    expectTrue(runtime:isRunning())
    expectEqual(#registered, 6)
end)

test("a missing REQUIRED anchor makes the start fail closed; a missing OPTIONAL one only cancels that objective", function()
    local function candidatesWithout(skip: string): { any }
        local list = {}
        for _, id in ipairs(contentPointIds()) do
            if id ~= skip then
                table.insert(list, candidate(id, { id = id }))
            end
        end
        return list
    end
    local runtime = runtimeWith(ObjectiveAnchors.index(candidatesWithout("POWER_FUSE_C")))
    expectFalse(pcall(function()
        runtime:start({ expectedUserIds = { 1 } })
    end))
    expectFalse(runtime:isRunning())

    local optional = runtimeWith(ObjectiveAnchors.index(candidatesWithout("RECORDS_CABINET")))
    optional:start({ expectedUserIds = { 1 } })
    expectTrue(optional:isRunning())
    expectEqual(optional:getObjectiveState("FIND_RECORDS"), "CANCELLED")
end)

test("an ambiguous REQUIRED anchor id fails closed too", function()
    local list = {}
    for _, id in ipairs(contentPointIds()) do
        table.insert(list, candidate(id, { id = id }))
    end
    table.insert(list, candidate("WING_ACCESS_PANEL", { id = "twin" }))
    local runtime = runtimeWith(ObjectiveAnchors.index(list))
    expectFalse(pcall(function()
        runtime:start({ expectedUserIds = { 1 } })
    end))
    expectFalse(runtime:isRunning())
end)
