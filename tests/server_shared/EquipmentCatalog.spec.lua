--!strict
local Harness = require("../Harness")
local Catalog = require("../../src/server_shared/Equipment/EquipmentCatalog")
local test, eq, yes, no = Harness.test, Harness.expectEqual, Harness.expectTrue, Harness.expectFalse

local function item(id: string?): any
    return { id = id or "EMF_READER", category = "DETECTION", action = "SCAN", title = "Reader", description = "Detect signals." }
end
local function content(...: any): any return { version = 1, items = { ... } } end
local function invalid(value: any, code: string)
    local ok, got = Catalog.validate(value)
    no(ok); eq(got, code)
end

test("valid equipment catalog validates and compiles", function()
    local source = content(item("A"), item("B"))
    yes(Catalog.validate(source))
    local plan = Catalog.compile(source)
    yes(plan ~= nil)
    eq(plan.kind, Catalog.PlanKind)
    eq(plan.order[1], "A")
end)

test("catalog rejects malformed root, version and unknown fields", function()
    invalid("x", "invalid_content_table")
    invalid({ version = 1, items = { item("A") }, extra = true }, "unexpected_content_field")
    invalid({ version = 0, items = { item("A") } }, "invalid_content_version")
    invalid({ version = 1.5, items = { item("A") } }, "invalid_content_version")
end)

test("catalog requires a bounded dense non-empty item array", function()
    invalid({ version = 1 }, "invalid_items_list")
    invalid({ version = 1, items = {} }, "empty_catalog")
    invalid({ version = 1, items = { [2] = item("A") } }, "invalid_items_list")
    invalid({ version = 1, items = { item("A"), extra = true } }, "invalid_items_list")
    local oversized = {}
    for i = 1, 17 do oversized[i] = item("I" .. i) end
    invalid({ version = 1, items = oversized }, "invalid_items_list")
end)

test("catalog rejects duplicate IDs, unexpected fields and invalid vocabulary", function()
    invalid(content(item("A"), item("A")), "duplicate_item_id")
    local extra = item("A"); extra.extra = true
    invalid(content(extra), "unexpected_item_field")
    local bad = item("A"); bad.category = "UNKNOWN"
    invalid(content(bad), "invalid_category")
    bad = item("A"); bad.action = "UNLOCK"
    invalid(content(bad), "invalid_action")
    bad = item("bad-id")
    invalid(content(bad), "invalid_item_id")
end)

test("catalog validates bounded UTF-8 text and compilation deep-copies/freezes", function()
    local bad = item("A"); bad.title = string.rep("x", 49)
    invalid(content(bad), "invalid_title")
    bad = item("A"); bad.description = "bad\ntext"
    invalid(content(bad), "invalid_description")
    local source = content(item("A"))
    local plan = Catalog.compile(source)
    source.items[1].title = "Changed"
    eq(plan.entries.A.title, "Reader")
    yes(table.isfrozen(plan) and table.isfrozen(plan.order) and table.isfrozen(plan.entries.A))
end)

test("validation does not mutate caller input and reports deterministic errors", function()
    local source = content(item("A"), item("A"))
    for _ = 1, 10 do
        local ok, code = Catalog.validate(source)
        no(ok); eq(code, "duplicate_item_id")
    end
    no(table.isfrozen(source))
end)
