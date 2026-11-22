--!strict
local Harness = require("../Harness")
local Catalog = require("../../src/server_shared/Equipment/EquipmentCatalog")
local Content = require("../../src/shared/Equipment/EquipmentContent")
local test, eq, yes = Harness.test, Harness.expectEqual, Harness.expectTrue

local function deeplyFrozen(value: any): boolean
    if type(value) ~= "table" then return true end
    if not table.isfrozen(value) then return false end
    for _, child in pairs(value) do if not deeplyFrozen(child) then return false end end
    return true
end

test("shared equipment content is valid and compiles", function()
    yes(Catalog.validate(Content))
    yes(Catalog.compile(Content) ~= nil)
end)

test("content contains exactly the five approved items and no Protection item", function()
    local ids = {}
    for _, entry in ipairs(Content.items) do table.insert(ids, entry.id) end
    eq(table.concat(ids, ","), "EMF_READER,THERMOMETER,FIELD_CAMERA,SPIRIT_BOX,UTILITY_FLASHLIGHT")
    eq(#Content.items, 5)
    yes(deeplyFrozen(Content))
    eq(Content.version, 1)
end)

test("item categories and actions match the approved equipment design", function()
    local expected = {
        EMF_READER = "DETECTION:SCAN",
        THERMOMETER = "DETECTION:SCAN",
        FIELD_CAMERA = "OBSERVATION:CAPTURE",
        SPIRIT_BOX = "COMMUNICATION:SCAN",
        UTILITY_FLASHLIGHT = "UTILITY:TOGGLE_LIGHT",
    }
    for _, entry in ipairs(Content.items) do
        eq(entry.category .. ":" .. entry.action, expected[entry.id])
    end
end)
