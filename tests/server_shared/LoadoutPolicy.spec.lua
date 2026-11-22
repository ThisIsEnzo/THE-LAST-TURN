--!strict
local Harness = require("../Harness")
local Catalog = require("../../src/server_shared/Equipment/EquipmentCatalog")
local Policy = require("../../src/server_shared/Equipment/LoadoutPolicy")
local Content = require("../../src/shared/Equipment/EquipmentContent")
local test, eq, yes, no = Harness.test, Harness.expectEqual, Harness.expectTrue, Harness.expectFalse
local plan = Catalog.compile(Content)

local function rejected(items: any, code: string)
    local ok, _, got = Policy.validate(items, plan)
    no(ok); eq(got, code)
end

test("default loadout is valid and canonical", function()
    local items = Policy.getDefaultLoadout(plan)
    yes(items ~= nil)
    eq(table.concat(items, ","), "EMF_READER,UTILITY_FLASHLIGHT")
end)

test("custom loadouts are accepted and sorted lexicographically", function()
    local ok, items = Policy.validate({ "SPIRIT_BOX", "FIELD_CAMERA", "THERMOMETER" }, plan)
    yes(ok)
    eq(table.concat(items, ","), "FIELD_CAMERA,SPIRIT_BOX,THERMOMETER")
end)

test("explicit empty loadout is valid and distinct from malformed input", function()
    local ok, items = Policy.validate({}, plan)
    yes(ok); eq(#items, 0)
    rejected(nil, "invalid_loadout_array")
    rejected("EMF_READER", "invalid_loadout_array")
end)

test("loadout rejects unknown, duplicate, oversized and non-string entries", function()
    rejected({ "NOT_A_TOOL" }, "unknown_item")
    rejected({ "EMF_READER", "EMF_READER" }, "duplicate_item")
    rejected({ "EMF_READER", "THERMOMETER", "FIELD_CAMERA", "SPIRIT_BOX" }, "invalid_loadout_array")
    rejected({ 42 }, "invalid_item_id")
end)

test("loadout rejects sparse arrays, unexpected keys and invalid plans", function()
    rejected({ [2] = "EMF_READER" }, "invalid_loadout_array")
    rejected({ "EMF_READER", extra = true }, "invalid_loadout_array")
    local ok, _, code = Policy.validate({}, {})
    no(ok); eq(code, "invalid_catalog_plan")
end)

test("loadout validation does not mutate input and canonical result is frozen", function()
    local source = { "UTILITY_FLASHLIGHT", "EMF_READER" }
    local ok, result = Policy.validate(source, plan)
    yes(ok)
    eq(source[1], "UTILITY_FLASHLIGHT")
    eq(table.concat(result, ","), "EMF_READER,UTILITY_FLASHLIGHT")
    yes(table.isfrozen(result))
end)
