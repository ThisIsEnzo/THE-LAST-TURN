--!strict
local Harness = require("../Harness")
local EvidenceCatalog = require("../../src/server_shared/Evidence/EvidenceCatalog")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local function definition(id: string, distinct: number?): any
    return {
        id = id,
        category = "ENVIRONMENTAL",
        title = "Title " .. id,
        description = "Description of " .. id,
        confirmation = { distinctSources = distinct or 2 },
    }
end

local function content(...: any): any
    return { version = 1, evidence = { ... } }
end

local function expectInvalid(c: any, code: string, subject: string?, label: string?)
    local ok, gotCode, gotSubject = EvidenceCatalog.validate(c)
    expectFalse(ok, label)
    expectEqual(gotCode, code, label)
    if subject ~= nil then
        expectEqual(gotSubject, subject, label)
    end
end

local function expectValid(c: any, label: string?)
    local ok, code, subject = EvidenceCatalog.validate(c)
    expectTrue(ok, (label or "expected valid") .. " (code " .. tostring(code) .. ", subject " .. tostring(subject) .. ")")
end

local function deepCopy(value: any): any
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, inner in pairs(value) do
        copy[key] = deepCopy(inner)
    end
    return copy
end

local function deepEqual(a: any, b: any): boolean
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not deepEqual(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

test("a minimal valid catalog passes", function()
    expectValid(content(definition("COLD_SPOT")))
end)

test("content must be a plain table with only known fields and a valid version", function()
    expectInvalid("x", "invalid_content_table")
    expectInvalid(setmetatable({ version = 1, evidence = { definition("A") } }, {}), "invalid_content_table")
    expectInvalid({ version = 1, evidence = { definition("A") }, extra = true }, "unexpected_content_field")
    expectInvalid({ version = 0, evidence = { definition("A") } }, "invalid_content_version")
    expectInvalid({ version = 1.5, evidence = { definition("A") } }, "invalid_content_version")
    expectInvalid({ version = "1", evidence = { definition("A") } }, "invalid_content_version")
    expectInvalid({ evidence = { definition("A") } }, "invalid_content_version")
end)

test("the evidence list must be a dense non-empty array within limits", function()
    expectInvalid({ version = 1 }, "invalid_evidence_list")
    expectInvalid({ version = 1, evidence = "x" }, "invalid_evidence_list")
    expectInvalid({ version = 1, evidence = { [2] = definition("A") } }, "invalid_evidence_list")
    expectInvalid({ version = 1, evidence = { definition("A"), name = 1 } }, "invalid_evidence_list")
    expectInvalid({ version = 1, evidence = {} }, "empty_catalog")
end)

test("the catalog size limit is inclusive", function()
    local list = {}
    for index = 1, 32 do
        table.insert(list, definition("E" .. index))
    end
    expectValid({ version = 1, evidence = list }, "32 definitions")
    table.insert(list, definition("E33"))
    expectInvalid({ version = 1, evidence = list }, "invalid_evidence_list")
end)

test("definitions are validated field by field", function()
    expectInvalid(content("x"), "invalid_definition_entry")
    local extra = definition("A")
    extra.surprise = true
    expectInvalid(content(extra), "unexpected_definition_field", "A")
    for _, badId in ipairs({ "a", "1A", "HAS SPACE", "", string.rep("A", 33) }) do
        expectInvalid(content(definition(badId)), "invalid_evidence_id", nil, "id " .. badId)
    end
    local nonString = definition("A")
    nonString.id = 5
    expectInvalid(content(nonString), "invalid_evidence_id")
    expectValid(content(definition(string.rep("A", 32))), "32 character id")
    local badCategory = definition("A")
    badCategory.category = "lower"
    expectInvalid(content(badCategory), "invalid_category", "A")
    badCategory.category = nil
    expectInvalid(content(badCategory), "invalid_category", "A")
end)

test("text fields are bounded, valid UTF-8 and free of control characters", function()
    local function withTitle(text: any): any
        local d = definition("A")
        d.title = text
        return content(d)
    end
    expectValid(withTitle(string.rep("x", 48)))
    expectInvalid(withTitle(string.rep("x", 49)), "invalid_title")
    expectInvalid(withTitle(""), "invalid_title")
    expectInvalid(withTitle(5), "invalid_title")
    expectInvalid(withTitle("line\nbreak"), "invalid_title")
    expectInvalid(withTitle("tab\there"), "invalid_title")
    expectInvalid(withTitle("nel\194\133here"), "invalid_title", nil, "C1 control character")
    expectInvalid(withTitle("bad \255 utf8"), "invalid_title")
    local function withDescription(text: any): any
        local d = definition("A")
        d.description = text
        return content(d)
    end
    expectValid(withDescription(string.rep("x", 140)))
    expectInvalid(withDescription(string.rep("x", 141)), "invalid_description")
    expectInvalid(withDescription(""), "invalid_description")
    expectInvalid(withDescription("a\0b"), "invalid_description")
end)

test("the confirmation requirement is validated", function()
    local function withConfirmation(value: any): any
        local d = definition("A")
        d.confirmation = value
        return content(d)
    end
    expectInvalid(withConfirmation(nil), "invalid_confirmation", "A")
    expectInvalid(withConfirmation("2"), "invalid_confirmation", "A")
    expectInvalid(withConfirmation({}), "invalid_distinct_sources", "A")
    expectInvalid(withConfirmation({ distinctSources = 2, extra = 1 }), "unexpected_confirmation_field", "A")
    expectInvalid(withConfirmation({ distinctSources = 0 }), "invalid_distinct_sources", "A")
    expectInvalid(withConfirmation({ distinctSources = -1 }), "invalid_distinct_sources", "A")
    expectInvalid(withConfirmation({ distinctSources = 1.5 }), "invalid_distinct_sources", "A")
    expectInvalid(withConfirmation({ distinctSources = 9 }), "invalid_distinct_sources", "A")
    expectInvalid(withConfirmation({ distinctSources = "2" }), "invalid_distinct_sources", "A")
    expectInvalid(withConfirmation({ distinctSources = 0 / 0 }), "invalid_distinct_sources", "A")
    expectInvalid(withConfirmation({ distinctSources = math.huge }), "invalid_distinct_sources", "A")
    expectValid(withConfirmation({ distinctSources = 1 }))
    expectValid(withConfirmation({ distinctSources = 8 }))
end)

test("duplicate evidence ids are rejected after structure", function()
    expectInvalid(content(definition("A"), definition("B"), definition("A")), "duplicate_evidence_id", "A")
    -- structure errors win over identity errors, wherever they are
    local broken = definition("Z")
    broken.title = ""
    expectInvalid(content(definition("A"), definition("A"), broken), "invalid_title", "Z")
end)

test("the first offender in definition order is reported", function()
    local first, second = definition("B"), definition("C")
    first.title = ""
    second.description = ""
    expectInvalid(content(definition("A"), first, second), "invalid_title", "B")
end)

test("validation is deterministic and repeatable", function()
    local c = content(definition("A"), definition("A"))
    local ok1, code1, subject1 = EvidenceCatalog.validate(c)
    for _ = 1, 20 do
        local ok, code, subject = EvidenceCatalog.validate(c)
        expectEqual(ok, ok1)
        expectEqual(code, code1)
        expectEqual(subject, subject1)
    end
end)

test("validate neither mutates nor freezes the caller's table, and accepts frozen input", function()
    local c = content(definition("A"), definition("B"))
    local before = deepCopy(c)
    expectValid(c)
    expectTrue(deepEqual(c, before))
    expectFalse(table.isfrozen(c))
    expectFalse(table.isfrozen(c.evidence))
    expectFalse(table.isfrozen(c.evidence[1]))
    local frozen = table.freeze({
        version = 1,
        evidence = table.freeze({
            table.freeze({
                id = "A",
                category = "C",
                title = "T",
                description = "D",
                confirmation = table.freeze({ distinctSources = 1 }),
            }),
        }),
    })
    expectValid(frozen)
end)

test("isToken accepts only content-style tokens", function()
    expectTrue(EvidenceCatalog.isToken("A"))
    expectTrue(EvidenceCatalog.isToken("SOURCE_1"))
    expectTrue(EvidenceCatalog.isToken(string.rep("A", 32)))
    for _, bad in ipairs({ "", "a", "1A", "_A", "A B", "A-B", string.rep("A", 33) }) do
        expectFalse(EvidenceCatalog.isToken(bad), bad)
    end
    expectFalse(EvidenceCatalog.isToken(nil))
    expectFalse(EvidenceCatalog.isToken(5))
    expectFalse(EvidenceCatalog.isToken({}))
end)

test("compile returns a frozen plan copied from the content", function()
    local c = content(definition("A", 3), definition("B", 1))
    local plan, code = EvidenceCatalog.compile(c)
    expectEqual(code, nil)
    local p: any = plan
    expectEqual(p.kind, EvidenceCatalog.PlanKind)
    expectEqual(p.version, 1)
    expectEqual(#p.order, 2)
    expectEqual(p.order[1], "A")
    expectEqual(p.order[2], "B")
    expectEqual(p.entries.A.distinctSources, 3)
    expectEqual(p.entries.B.distinctSources, 1)
    expectEqual(p.entries.A.category, "ENVIRONMENTAL")
    expectTrue(table.isfrozen(p) and table.isfrozen(p.order) and table.isfrozen(p.entries) and table.isfrozen(p.entries.A))
    expectFalse(table.isfrozen(c), "the caller's table stays untouched")
    c.evidence[1].title = "Changed"
    c.evidence[1].confirmation.distinctSources = 8
    expectEqual(p.entries.A.title, "Title A")
    expectEqual(p.entries.A.distinctSources, 3)
end)

test("compile reports the same codes as validate and never returns a plan for invalid content", function()
    local plan, code, subject = EvidenceCatalog.compile(content(definition("A"), definition("A")))
    expectEqual(plan, nil)
    expectEqual(code, "duplicate_evidence_id")
    expectEqual(subject, "A")
    local none, badCode = EvidenceCatalog.compile("x")
    expectEqual(none, nil)
    expectEqual(badCode, "invalid_content_table")
end)
