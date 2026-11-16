--!strict
local Harness = require("../Harness")
local EvidenceCatalog = require("../../src/server_shared/Evidence/EvidenceCatalog")
local EvidenceCore = require("../../src/server_shared/Evidence/EvidenceCore")
local EvidenceContent = require("../../src/mission/server/Evidence/EvidenceContent")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local content: any = EvidenceContent

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

test("the shipped catalog passes EvidenceCatalog validation and compiles", function()
    local ok, code, subject = EvidenceCatalog.validate(content)
    expectTrue(ok, "shipped content invalid: " .. tostring(code) .. " " .. tostring(subject))
    expectTrue(EvidenceCatalog.compile(content) ~= nil)
end)

test("the shipped catalog is deeply frozen plain data", function()
    expectTrue(deepFrozen(content))
    expectEqual(content.version, 1)
    expectEqual(getmetatable(content), nil)
end)

test("the example catalog has the documented evidence", function()
    local ids = {}
    local required: { [string]: number } = {}
    for _, definition in ipairs(content.evidence) do
        table.insert(ids, definition.id)
        required[definition.id] = definition.confirmation.distinctSources
    end
    expectEqual(table.concat(ids, ","), "COLD_SPOT,STATIC_INTERFERENCE,MOVED_OBJECT,VOICE_ECHO")
    expectEqual(required.COLD_SPOT, 2)
    expectEqual(required.STATIC_INTERFERENCE, 2)
    expectEqual(required.MOVED_OBJECT, 1)
    expectEqual(required.VOICE_ECHO, 3)
end)

test("the catalog offers variety: several categories and different confirmation requirements", function()
    local categories: { [string]: boolean } = {}
    local requirements: { [number]: boolean } = {}
    for _, definition in ipairs(content.evidence) do
        categories[definition.category] = true
        requirements[definition.confirmation.distinctSources] = true
    end
    local categoryCount, requirementCount = 0, 0
    for _ in pairs(categories) do
        categoryCount = categoryCount + 1
    end
    for _ in pairs(requirements) do
        requirementCount = requirementCount + 1
    end
    expectTrue(categoryCount >= 3)
    expectTrue(requirementCount >= 2)
end)

test("the shipped catalog is solo-viable: one player can observe and confirm everything", function()
    local plan: any = EvidenceCatalog.compile(content)
    local core: any = EvidenceCore.new(plan, 0)
    local now = 0
    for _, id in ipairs(plan.order) do
        for index = 1, plan.entries[id].distinctSources do
            now = now + 1
            expectTrue(core:observe(id, "SITE_" .. index, 1, { eligible = true, now = now }).ok)
        end
        now = now + 1
        expectTrue(core:confirm(id, 1, { eligible = true, now = now }).ok, id)
        expectTrue((core:checkInvariants()))
    end
    local progress = core:getProgress()
    expectEqual(progress.confirmed, progress.total)
    expectEqual(progress.confirmedRatio, 1)
end)

test("no source of a single report can confirm multi-source evidence alone", function()
    local plan: any = EvidenceCatalog.compile(content)
    local core: any = EvidenceCore.new(plan, 0)
    expectTrue(core:observe("VOICE_ECHO", "SITE_ONE", 1, { eligible = true, now = 1 }).ok)
    expectFalse(core:confirm("VOICE_ECHO", 1, { eligible = true, now = 2 }).ok)
    expectEqual(core:getState("VOICE_ECHO"), "OBSERVED")
end)
