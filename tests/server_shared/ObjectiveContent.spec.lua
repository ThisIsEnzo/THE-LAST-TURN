--!strict
local Harness = require("../Harness")
local ObjectiveGraph = require("../../src/server_shared/Objective/ObjectiveGraph")
local ObjectiveCore = require("../../src/server_shared/Objective/ObjectiveCore")
local ObjectiveContent = require("../../src/mission/server/Objective/ObjectiveContent")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local content: any = ObjectiveContent

local function byId(id: string): any
    for _, objective in ipairs(content.objectives) do
        if objective.id == id then
            return objective
        end
    end
    return nil
end

local function deepFrozen(value: any): boolean
    if type(value) ~= "table" then
        return true
    end
    if not table.isfrozen(value) then
        return false
    end
    for _, inner in pairs(value) do
        if not deepFrozen(inner) then
            return false
        end
    end
    return true
end

test("the shipped content passes ObjectiveGraph validation", function()
    local ok, code, subject = ObjectiveGraph.validate(content)
    expectTrue(ok, "shipped content invalid: " .. tostring(code) .. " " .. tostring(subject))
    local plan, compileCode = ObjectiveGraph.compile(content)
    expectTrue(plan ~= nil, tostring(compileCode))
end)

test("the shipped content is deeply frozen plain data", function()
    expectTrue(deepFrozen(content), "every table is frozen")
    expectEqual(content.version, 2)
    expectEqual(getmetatable(content), nil)
end)

test("the first slice has exactly the documented objectives", function()
    expectEqual(#content.objectives, 5)
    local ids = {}
    for _, objective in ipairs(content.objectives) do
        table.insert(ids, objective.id)
    end
    expectEqual(table.concat(ids, ","), "RESTORE_POWER,OPEN_WING,EXTRACT,FIND_RECORDS,DOCUMENT_COLD_SPOT")

    local power = byId("RESTORE_POWER")
    expectEqual(power.importance, "REQUIRED")
    expectEqual(power.requires, nil)
    expectEqual(#power.completion.slots, 3)
    expectEqual(power.completion.slots[1].id, "FUSE_A")
    expectEqual(power.completion.slots[2].id, "FUSE_B")
    expectEqual(power.completion.slots[3].id, "FUSE_C")

    local wing = byId("OPEN_WING")
    expectEqual(wing.importance, "REQUIRED")
    expectEqual(#wing.requires.allOf, 1)
    expectEqual(wing.requires.allOf[1], "RESTORE_POWER")
    expectEqual(wing.requires.anyOf, nil)
    expectEqual(#wing.completion.slots, 1)

    local extract = byId("EXTRACT")
    expectEqual(extract.importance, "REQUIRED")
    expectEqual(#extract.requires.allOf, 1)
    expectEqual(extract.requires.allOf[1], "OPEN_WING")
    expectEqual(#extract.completion.slots, 1)

    local records = byId("FIND_RECORDS")
    expectEqual(records.importance, "OPTIONAL")
    expectEqual(records.requires, nil)
    expectEqual(#records.completion.slots, 1)
end)

test("the slice demonstrates the required capabilities", function()
    local multiSlot, optional, dependencyEdges = 0, 0, 0
    for _, objective in ipairs(content.objectives) do
        if #objective.completion.slots > 1 then
            multiSlot = multiSlot + 1
        end
        if objective.importance == "OPTIONAL" then
            optional = optional + 1
        end
        if objective.requires ~= nil then
            dependencyEdges = dependencyEdges + 1
        end
    end
    expectTrue(#content.objectives >= 3, "at least three objectives")
    expectTrue(multiSlot >= 1, "at least one multi-contribution objective")
    expectTrue(optional >= 1, "at least one optional objective")
    expectTrue(dependencyEdges >= 1, "at least one dependency")
end)

test("the slice satisfies the mandatory progression rule: every required objective is guaranteed", function()
    local guaranteed = ObjectiveGraph.computeGuaranteed(content)
    for _, objective in ipairs(content.objectives) do
        if objective.importance == "REQUIRED" then
            expectTrue(guaranteed[objective.id], objective.id .. " must be guaranteed")
        else
            expectEqual(guaranteed[objective.id], nil, objective.id .. " is OPTIONAL and never guaranteed")
        end
    end
end)

test("nothing required depends on the optional objective", function()
    local optionalIds: { [string]: boolean } = {}
    for _, objective in ipairs(content.objectives) do
        if objective.importance == "OPTIONAL" then
            optionalIds[objective.id] = true
        end
    end
    for _, objective in ipairs(content.objectives) do
        if objective.requires ~= nil then
            for _, listName in ipairs({ "allOf", "anyOf" }) do
                for _, dependencyId in ipairs(objective.requires[listName] or {}) do
                    expectEqual(optionalIds[dependencyId], nil, objective.id .. " must not depend on an optional objective")
                end
            end
        end
    end
end)

test("ALTERNATIVE remains reserved and the optional cold-spot objective uses SIGNAL", function()
    local signals = 0
    for _, objective in ipairs(content.objectives) do
        expectTrue(objective.importance == "REQUIRED" or objective.importance == "OPTIONAL", objective.id)
        if objective.completion.kind == "SIGNAL" then
            signals += 1
            expectEqual(objective.id, "DOCUMENT_COLD_SPOT")
            expectEqual(objective.importance, "OPTIONAL")
            expectEqual(objective.completion.signal.sourceToken, "evidence_cold_spot")
        else
            expectEqual(objective.completion.kind, "SLOTS", objective.id)
        end
    end
    expectEqual(signals, 1)
end)

test("every slot has its own anchor id and ids are unique", function()
    local points: { [string]: boolean } = {}
    local slotIdsPerObjective = 0
    for _, objective in ipairs(content.objectives) do
        local slotIds: { [string]: boolean } = {}
        for _, slot in ipairs(objective.completion.slots) do
            expectEqual(points[slot.pointId], nil, "duplicate anchor " .. slot.pointId)
            points[slot.pointId] = true
            expectEqual(slotIds[slot.id], nil, "duplicate slot " .. slot.id)
            slotIds[slot.id] = true
            slotIdsPerObjective = slotIdsPerObjective + 1
        end
    end
    expectEqual(slotIdsPerObjective, 6)
end)

test("texts respect the documented limits", function()
    for _, objective in ipairs(content.objectives) do
        expectTrue(#objective.title <= ObjectiveGraph.Limits.MaxTitleBytes, objective.id)
        expectTrue(#objective.description <= ObjectiveGraph.Limits.MaxDescriptionBytes, objective.id)
        for _, slot in ipairs(objective.completion.slots) do
            expectTrue(#slot.label <= ObjectiveGraph.Limits.MaxLabelBytes, slot.id)
        end
    end
end)

test("the slice starts with the documented states", function()
    local plan: any = ObjectiveGraph.compile(content)
    local core: any = ObjectiveCore.new(plan, 0)
    expectEqual(core:getState("RESTORE_POWER"), "AVAILABLE")
    expectEqual(core:getState("FIND_RECORDS"), "AVAILABLE", "the optional objective is active in parallel")
    expectEqual(core:getState("OPEN_WING"), "LOCKED")
    expectEqual(core:getState("EXTRACT"), "LOCKED")
    expectTrue(core:checkInvariants())
end)

test("the slice is solo-viable and resolves exactly when the last required objective completes", function()
    local plan: any = ObjectiveGraph.compile(content)
    local core: any = ObjectiveCore.new(plan, 0)
    local now = 0
    local function contribute(objectiveId: string, slotId: string): any
        now = now + 1
        local result = core:contribute(objectiveId, slotId, 1, { eligible = true, now = now })
        expectTrue(result.ok, objectiveId .. "/" .. slotId .. ": " .. tostring(result.reason))
        expectTrue((core:checkInvariants()))
        return result
    end
    contribute("RESTORE_POWER", "FUSE_C")
    contribute("RESTORE_POWER", "FUSE_A")
    expectFalse(core:isResolved())
    local third = contribute("RESTORE_POWER", "FUSE_B")
    expectEqual(core:getState("OPEN_WING"), "AVAILABLE")
    expectEqual(third.resolution, nil)
    contribute("OPEN_WING", "ACCESS_PANEL")
    expectEqual(core:getState("EXTRACT"), "AVAILABLE")
    expectFalse(core:isResolved(), "completing objectives is not completing the mission")
    local last = contribute("EXTRACT", "EXTRACTION_POINT")
    expectEqual(last.resolution.outcome, "COMPLETED")
    expectEqual(last.resolution.reason, "objectives_complete")
    expectEqual(core:getState("FIND_RECORDS"), "AVAILABLE", "the optional objective was never required")
end)

test("the slice resolves the same way with the optional objective completed first", function()
    local plan: any = ObjectiveGraph.compile(content)
    local core: any = ObjectiveCore.new(plan, 0)
    local steps = {
        { "FIND_RECORDS", "RECORDS_CABINET", 2 },
        { "RESTORE_POWER", "FUSE_A", 1 },
        { "RESTORE_POWER", "FUSE_B", 2 },
        { "RESTORE_POWER", "FUSE_C", 3 },
        { "OPEN_WING", "ACCESS_PANEL", 4 },
        { "EXTRACT", "EXTRACTION_POINT", 1 },
    }
    local last: any = nil
    for index, step in ipairs(steps) do
        last = core:contribute(step[1], step[2], step[3], { eligible = true, now = index })
        expectTrue(last.ok, step[1] .. ": " .. tostring(last.reason))
    end
    expectEqual(last.resolution.outcome, "COMPLETED")
    expectEqual(core:getRevision(), 6)
end)