--!strict
local Harness = require("../Harness")
local ObjectiveGraph = require("../../src/server_shared/Objective/ObjectiveGraph")
local ObjectiveCore = require("../../src/server_shared/Objective/ObjectiveCore")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local REQ, OPT = "REQUIRED", "OPTIONAL"

-- Builds one objective with a single slot whose anchor id is derived from the objective id.
local function objective(id: string, importance: string, requires: any?): any
    return {
        id = id,
        importance = importance,
        requires = requires,
        title = "Title " .. id,
        description = "Description of " .. id,
        completion = { kind = "SLOTS", slots = { { id = "SLOT", pointId = "POINT_" .. id, label = "Use " .. id } } },
    }
end

local function content(...: any): any
    return { version = 1, objectives = { ... } }
end

local function expectInvalid(c: any, code: string, subject: string?, label: string?)
    local ok, gotCode, gotSubject = ObjectiveGraph.validate(c)
    expectFalse(ok, label)
    expectEqual(gotCode, code, label)
    if subject ~= nil then
        expectEqual(gotSubject, subject, label)
    end
end

local function expectValid(c: any, label: string?)
    local ok, code, subject = ObjectiveGraph.validate(c)
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

-- All permutations of a list (small lists only).
local function permutations(list: { any }): { { any } }
    local results: { { any } } = {}
    local function recurse(current: { any }, remaining: { any })
        if #remaining == 0 then
            table.insert(results, current)
            return
        end
        for index = 1, #remaining do
            local nextCurrent = table.clone(current)
            table.insert(nextCurrent, remaining[index])
            local nextRemaining = table.clone(remaining)
            table.remove(nextRemaining, index)
            recurse(nextCurrent, nextRemaining)
        end
    end
    recurse({}, list)
    return results
end

-- constants ---------------------------------------------------------------------------------------------------------

test("states constants match between the graph and the core", function()
    for key, value in pairs(ObjectiveGraph.States) do
        expectEqual(ObjectiveCore.States[key], value, key)
    end
    for key, value in pairs(ObjectiveCore.States) do
        expectEqual(ObjectiveGraph.States[key], value, key)
    end
    expectTrue(table.isfrozen(ObjectiveGraph.States))
    expectTrue(table.isfrozen(ObjectiveGraph.Limits))
end)

-- structure ---------------------------------------------------------------------------------------------------------

test("a minimal valid content table passes", function()
    expectValid(content(objective("A", REQ)))
end)

test("content must be a plain table with only known fields", function()
    expectInvalid("x", "invalid_content_table")
    expectInvalid(setmetatable({ version = 1, objectives = { objective("A", REQ) } }, {}), "invalid_content_table")
    expectInvalid({ version = 1, objectives = { objective("A", REQ) }, extra = true }, "unexpected_content_field")
    expectInvalid({ version = 0, objectives = { objective("A", REQ) } }, "invalid_content_version")
    expectInvalid({ version = 1.5, objectives = { objective("A", REQ) } }, "invalid_content_version")
    expectInvalid({ version = "1", objectives = { objective("A", REQ) } }, "invalid_content_version")
end)

test("objectives must be a dense array within limits", function()
    expectInvalid({ version = 1, objectives = "x" }, "invalid_objectives")
    expectInvalid({ version = 1, objectives = { [2] = objective("A", REQ) } }, "invalid_objectives")
    expectInvalid({ version = 1, objectives = { objective("A", REQ), name = 1 } }, "invalid_objectives")
    expectInvalid({ version = 1, objectives = {} }, "empty_objectives")
end)

test("objective count limit is inclusive", function()
    local objectives = { objective("O0", REQ) }
    for index = 1, 31 do
        table.insert(objectives, objective("O" .. index, OPT))
    end
    expectValid({ version = 1, objectives = objectives }, "32 objectives")
    table.insert(objectives, objective("O32", OPT))
    expectInvalid({ version = 1, objectives = objectives }, "invalid_objectives")
end)

test("objective entries are validated field by field", function()
    expectInvalid(content("x"), "invalid_objective_entry")
    local extra = objective("A", REQ)
    extra.surprise = true
    expectInvalid(content(extra), "unexpected_objective_field", "A")
    local badId = objective("a", REQ)
    expectInvalid(content(badId), "invalid_objective_id")
    local longId = objective(string.rep("A", 33), REQ)
    expectInvalid(content(longId), "invalid_objective_id")
    local maxId = objective(string.rep("A", 32), REQ)
    maxId.completion.slots[1].pointId = "ANCHOR"
    expectValid(content(maxId), "32 character id")
    local badImportance = objective("A", "MAYBE")
    expectInvalid(content(badImportance), "invalid_importance", "A")
    local noImportance = objective("A", REQ)
    noImportance.importance = nil
    expectInvalid(content(noImportance), "invalid_importance", "A")
end)

test("ALTERNATIVE is reserved: rejected with its own code and never treated as OPTIONAL", function()
    local alternative = objective("ALT", "ALTERNATIVE")
    expectInvalid(content(objective("A", REQ), alternative), "alternative_not_supported", "ALT")
    local ok1, code1 = ObjectiveGraph.validate(content(objective("A", REQ), alternative))
    local ok2, code2 = ObjectiveGraph.validate(content(objective("A", REQ), objective("ALT", OPT)))
    expectFalse(ok1)
    expectTrue(ok2)
    expectEqual(code1, "alternative_not_supported")
    expectEqual(code2, nil)
    expectEqual(ObjectiveGraph.Importance.ALTERNATIVE, nil)
end)

test("text fields are bounded, non-empty, valid UTF-8 and free of control characters", function()
    local function withTitle(text: any): any
        local o = objective("A", REQ)
        o.title = text
        return content(o)
    end
    expectValid(withTitle(string.rep("x", 48)), "48 byte title")
    expectInvalid(withTitle(string.rep("x", 49)), "invalid_title")
    expectInvalid(withTitle(""), "invalid_title")
    expectInvalid(withTitle(5), "invalid_title")
    expectInvalid(withTitle("line\nbreak"), "invalid_title")
    expectInvalid(withTitle("tab\there"), "invalid_title")
    expectInvalid(withTitle("bad \255 utf8"), "invalid_title")
    expectInvalid(withTitle("bad\194\133text"), "invalid_title", nil, "Unicode NEL (U+0085) is a control character")
    expectInvalid(withTitle("bad\194\159text"), "invalid_title", nil, "Unicode U+009F is a control character")
    local function withDescription(text: any): any
        local o = objective("A", REQ)
        o.description = text
        return content(o)
    end
    expectValid(withDescription(string.rep("x", 140)), "140 byte description")
    expectInvalid(withDescription(string.rep("x", 141)), "invalid_description")
    expectInvalid(withDescription(""), "invalid_description")
    expectInvalid(withDescription("description\194\133continued"), "invalid_description", nil, "C1 controls are rejected in descriptions")
    local badLabel = objective("A", REQ)
    badLabel.completion.slots[1].label = "label\194\133continued"
    expectInvalid(content(badLabel), "invalid_slot_label", "A", "C1 controls are rejected in slot labels")
    local hidden = objective("A", REQ)
    hidden.hiddenUntilAvailable = "yes"
    expectInvalid(content(hidden), "invalid_hidden_flag", "A")
    hidden.hiddenUntilAvailable = true
    expectValid(content(hidden))
end)

test("requires is validated: shape, fields, emptiness, list density, list size and id syntax", function()
    local function withRequires(requires: any): any
        return content(objective("B", REQ), objective("A", REQ, requires))
    end
    expectInvalid(withRequires("B"), "invalid_requires", "A")
    expectInvalid(withRequires({}), "empty_requires", "A")
    expectInvalid(withRequires({ allOf = { "B" }, noneOf = { "B" } }), "unexpected_requires_field", "A")
    expectInvalid(withRequires({ allOf = "B" }), "invalid_dependency_list", "A")
    expectInvalid(withRequires({ allOf = { [2] = "B" } }), "invalid_dependency_list", "A")
    expectInvalid(withRequires({ anyOf = { "B", extra = "B" } }), "invalid_dependency_list", "A")
    expectInvalid(withRequires({ allOf = { 5 } }), "invalid_dependency_id", "A")
    expectInvalid(withRequires({ allOf = { "b" } }), "invalid_dependency_id", "A")
    expectValid(withRequires({ allOf = { "B" } }))
    expectValid(withRequires({ anyOf = { "B" } }))
    expectValid(withRequires({ allOf = { "B" }, anyOf = { "B" } }), "both clauses may name the same objective")
end)

test("dependency list size limit is inclusive", function()
    local objectives = {}
    local ids = {}
    for index = 1, 9 do
        local id = "D" .. index
        table.insert(objectives, objective(id, REQ))
        table.insert(ids, id)
    end
    local eight = table.clone(ids)
    table.remove(eight)
    local top8 = objective("TOP", REQ, { allOf = eight })
    local top9 = objective("TOP", REQ, { allOf = ids })
    local base8 = table.clone(objectives)
    table.insert(base8, top8)
    local base9 = table.clone(objectives)
    table.insert(base9, top9)
    expectValid({ version = 1, objectives = base8 }, "8 dependencies")
    expectInvalid({ version = 1, objectives = base9 }, "invalid_dependency_list", "TOP")
end)

test("completion is validated: shape, kind, slots", function()
    local function withCompletion(completion: any): any
        local o = objective("A", REQ)
        o.completion = completion
        return content(o)
    end
    expectInvalid(withCompletion("x"), "invalid_completion", "A")
    expectInvalid(withCompletion({ kind = "SLOTS", slots = { { id = "S", pointId = "P", label = "L" } }, extra = 1 }), "unexpected_completion_field", "A")
    expectInvalid(withCompletion({ kind = "SIGNAL" }), "unsupported_completion_kind", "A")
    expectInvalid(withCompletion({ kind = "WHATEVER", slots = {} }), "invalid_completion_kind", "A")
    expectInvalid(withCompletion({ kind = "SLOTS", slots = "x" }), "invalid_slots", "A")
    expectInvalid(withCompletion({ kind = "SLOTS", slots = {} }), "empty_slots", "A")
    expectInvalid(withCompletion({ kind = "SLOTS", slots = { { id = "S", pointId = "P", label = "L" }, "x" } }), "invalid_slot_entry", "A")
    expectInvalid(withCompletion({ kind = "SLOTS", slots = { { id = "S", pointId = "P", label = "L", extra = 1 } } }), "unexpected_slot_field", "A")
    expectInvalid(withCompletion({ kind = "SLOTS", slots = { { id = "s", pointId = "P", label = "L" } } }), "invalid_slot_id", "A")
    expectInvalid(withCompletion({ kind = "SLOTS", slots = { { id = "S", pointId = "p", label = "L" } } }), "invalid_point_id", "A")
    expectInvalid(withCompletion({ kind = "SLOTS", slots = { { id = "S", pointId = "P", label = string.rep("x", 41) } } }), "invalid_slot_label", "A")
    expectValid(withCompletion({ kind = "SLOTS", slots = { { id = "S", pointId = "P", label = string.rep("x", 40) } } }), "40 byte label")
end)

test("slot count limit is inclusive", function()
    local function withSlots(count: number): any
        local slots = {}
        for index = 1, count do
            table.insert(slots, { id = "S" .. index, pointId = "P" .. index, label = "Slot " .. index })
        end
        local o = objective("A", REQ)
        o.completion = { kind = "SLOTS", slots = slots }
        return content(o)
    end
    expectValid(withSlots(8), "8 slots")
    expectInvalid(withSlots(9), "invalid_slots", "A")
end)

-- identity ----------------------------------------------------------------------------------------------------------

test("identity rules: duplicate objective ids, slot ids and anchor ids", function()
    expectInvalid(content(objective("A", REQ), objective("A", OPT)), "duplicate_objective_id", "A")
    local twoSlots = objective("A", REQ)
    twoSlots.completion = { kind = "SLOTS", slots = { { id = "S", pointId = "P1", label = "L" }, { id = "S", pointId = "P2", label = "L" } } }
    expectInvalid(content(twoSlots), "duplicate_slot_id", "A")
    local first = objective("A", REQ)
    local second = objective("B", REQ)
    second.completion.slots[1].pointId = first.completion.slots[1].pointId
    expectInvalid(content(first, second), "duplicate_point_id", "B")
    local sameSlotIdsElsewhere = content(objective("A", REQ), objective("B", REQ))
    expectValid(sameSlotIdsElsewhere, "slot ids only need to be unique inside their objective")
end)

-- references --------------------------------------------------------------------------------------------------------

test("reference rules: unknown, self, duplicate and empty lists", function()
    expectInvalid(content(objective("A", REQ), objective("B", REQ, { allOf = { "NOPE" } })), "unknown_dependency", "B")
    expectInvalid(content(objective("A", REQ, { allOf = { "A" } })), "self_dependency", "A")
    expectInvalid(content(objective("A", REQ), objective("B", REQ, { anyOf = { "A", "A" } })), "duplicate_dependency", "B")
    expectInvalid(content(objective("A", REQ), objective("B", REQ, { allOf = {} })), "empty_dependency_list", "B")
    expectInvalid(content(objective("A", REQ), objective("B", REQ, { anyOf = {} })), "empty_dependency_list", "B")
end)

-- cycles ------------------------------------------------------------------------------------------------------------

test("cycles are always rejected, whatever the importance of their members", function()
    expectInvalid(content(objective("A", REQ, { allOf = { "B" } }), objective("B", REQ, { allOf = { "A" } })), "dependency_cycle")
    expectInvalid(
        content(objective("A", OPT, { allOf = { "B" } }), objective("B", OPT, { allOf = { "A" } }), objective("C", REQ)),
        "dependency_cycle",
        nil,
        "optional-only cycle"
    )
    expectInvalid(
        content(
            objective("A", REQ, { allOf = { "D" } }),
            objective("B", REQ, { allOf = { "A" } }),
            objective("C", REQ, { allOf = { "B" } }),
            objective("D", REQ, { anyOf = { "C" } })
        ),
        "dependency_cycle",
        nil,
        "long cycle through allOf and anyOf"
    )
end)

test("a diamond is not a cycle", function()
    expectValid(content(
        objective("TOP", REQ),
        objective("LEFT", REQ, { allOf = { "TOP" } }),
        objective("RIGHT", REQ, { allOf = { "TOP" } }),
        objective("BOTTOM", REQ, { allOf = { "LEFT", "RIGHT" } })
    ))
end)

test("cycle detection reports a member of the cycle deterministically", function()
    local c = content(objective("A", REQ), objective("B", REQ, { allOf = { "C" } }), objective("C", REQ, { allOf = { "B" } }))
    local _, code1, subject1 = ObjectiveGraph.validate(c)
    local _, code2, subject2 = ObjectiveGraph.validate(c)
    expectEqual(code1, "dependency_cycle")
    expectEqual(code1, code2)
    expectEqual(subject1, subject2)
    expectTrue(subject1 == "B" or subject1 == "C")
end)

-- required objective -----------------------------------------------------------------------------------------------

test("at least one REQUIRED objective is needed", function()
    expectInvalid(content(objective("A", OPT)), "no_required_objective")
    expectInvalid(content(objective("A", OPT), objective("B", OPT, { allOf = { "A" } })), "no_required_objective")
end)

-- mandatory progression rule: the nine examples of design section 6.4 ---------------------------------------------

test("progression example 1: a REQUIRED objective depending only on an OPTIONAL one is invalid", function()
    local c = content(
        objective("FIND_BACKUP_GENERATOR", OPT),
        objective("RESTORE_POWER", REQ, { anyOf = { "FIND_BACKUP_GENERATOR" } }),
        objective("OPEN_WING", REQ, { allOf = { "RESTORE_POWER" } })
    )
    expectInvalid(c, "required_not_guaranteed", "RESTORE_POWER")
    local guaranteed = ObjectiveGraph.computeGuaranteed(c)
    expectFalse(guaranteed.RESTORE_POWER == true)
    expectFalse(guaranteed.OPEN_WING == true, "transitively not guaranteed")
    -- the same through allOf
    expectInvalid(
        content(objective("FIND_BACKUP_GENERATOR", OPT), objective("RESTORE_POWER", REQ, { allOf = { "FIND_BACKUP_GENERATOR" } })),
        "required_not_guaranteed",
        "RESTORE_POWER"
    )
end)

test("progression example 2: a required anyOf with optional and required alternatives is valid", function()
    local c = content(
        objective("FIND_BACKUP_GENERATOR", OPT),
        objective("REPAIR_MAIN_BREAKER", REQ),
        objective("RESTORE_POWER", REQ, { anyOf = { "FIND_BACKUP_GENERATOR", "REPAIR_MAIN_BREAKER" } }),
        objective("OPEN_WING", REQ, { allOf = { "RESTORE_POWER" } })
    )
    expectValid(c)
    local guaranteed = ObjectiveGraph.computeGuaranteed(c)
    expectTrue(guaranteed.RESTORE_POWER)
    expectTrue(guaranteed.OPEN_WING)
    expectEqual(guaranteed.FIND_BACKUP_GENERATOR, nil, "OPTIONAL is never in G")
end)

test("progression example 3: a chain of optional objectives never guarantees a required one", function()
    expectInvalid(
        content(
            objective("OPT_A", OPT),
            objective("OPT_B", OPT, { allOf = { "OPT_A" } }),
            objective("OPT_C", OPT, { allOf = { "OPT_B" } }),
            objective("RESTORE_POWER", REQ, { anyOf = { "OPT_C" } })
        ),
        "required_not_guaranteed",
        "RESTORE_POWER"
    )
end)

test("progression example 4: optional chains hanging off required progress are valid", function()
    local c = content(
        objective("REQ_X", REQ),
        objective("OPT_1", OPT, { allOf = { "REQ_X" } }),
        objective("OPT_2", OPT, { allOf = { "OPT_1" } })
    )
    expectValid(c)
    local guaranteed = ObjectiveGraph.computeGuaranteed(c)
    expectTrue(guaranteed.REQ_X)
    expectEqual(guaranteed.OPT_1, nil)
    expectEqual(guaranteed.OPT_2, nil)
end)

test("progression example 5: an optional member in a required allOf is invalid", function()
    expectInvalid(
        content(objective("REQ_X", REQ), objective("OPT_1", OPT, { allOf = { "REQ_X" } }), objective("REQ_Y", REQ, { allOf = { "REQ_X", "OPT_1" } })),
        "required_not_guaranteed",
        "REQ_Y"
    )
end)

test("progression example 6: an independent optional objective that nothing depends on is valid", function()
    expectValid(content(objective("FIND_RECORDS", OPT), objective("REQ_X", REQ)))
end)

test("progression example 7: cycles are reported as cycles before the progression rule", function()
    expectInvalid(content(objective("A", REQ, { allOf = { "B" } }), objective("B", REQ, { allOf = { "A" } })), "dependency_cycle")
    expectInvalid(content(objective("A", OPT, { allOf = { "B" } }), objective("B", OPT, { allOf = { "A" } }), objective("C", REQ)), "dependency_cycle")
end)

test("progression example 8: missing ids, self references and empty lists are impossible dependencies", function()
    expectInvalid(content(objective("A", REQ, { allOf = { "MISSING" } })), "unknown_dependency", "A")
    expectInvalid(content(objective("A", REQ, { anyOf = { "A" } })), "self_dependency", "A")
    expectInvalid(content(objective("A", REQ), objective("B", REQ, { anyOf = {} })), "empty_dependency_list", "B")
end)

test("progression example 9: a required anyOf of one required and one optional member is valid", function()
    expectValid(content(objective("C", REQ), objective("E", OPT), objective("D", REQ, { anyOf = { "C", "E" } })))
end)

test("transitive invalidity is reported at the first offender in definition order", function()
    local function build(order: { string }): any
        local definitions: { [string]: any } = {
            OPT = objective("OPT", OPT),
            POWER = objective("POWER", REQ, { anyOf = { "OPT" } }),
            WING = objective("WING", REQ, { allOf = { "POWER" } }),
        }
        local list = {}
        for _, id in ipairs(order) do
            table.insert(list, definitions[id])
        end
        return { version = 1, objectives = list }
    end
    expectInvalid(build({ "OPT", "POWER", "WING" }), "required_not_guaranteed", "POWER")
    expectInvalid(build({ "WING", "OPT", "POWER" }), "required_not_guaranteed", "WING")
end)

test("a required objective with both clauses must satisfy both", function()
    -- allOf is guaranteed but anyOf only has an optional member
    expectInvalid(
        content(objective("R", REQ), objective("O", OPT), objective("X", REQ, { allOf = { "R" }, anyOf = { "O" } })),
        "required_not_guaranteed",
        "X"
    )
    expectValid(content(objective("R", REQ), objective("R2", REQ), objective("O", OPT), objective("X", REQ, { allOf = { "R" }, anyOf = { "O", "R2" } })))
end)

test("fixpoint and verdict are independent of definition order", function()
    local definitions = {
        objective("R1", REQ),
        objective("OPT", OPT),
        objective("R2", REQ, { anyOf = { "OPT", "R1" } }),
        objective("R3", REQ, { allOf = { "R2" } }),
    }
    local invalidDefinitions = {
        objective("R1", REQ),
        objective("OPT", OPT, { allOf = { "R1" } }),
        objective("R2", REQ, { anyOf = { "OPT" } }),
        objective("R3", REQ, { allOf = { "R2" } }),
    }
    for _, order in ipairs(permutations(definitions)) do
        local c = { version = 1, objectives = order }
        expectValid(c, "valid in every order")
        local guaranteed = ObjectiveGraph.computeGuaranteed(c)
        expectTrue(guaranteed.R1 and guaranteed.R2 and guaranteed.R3)
        expectEqual(guaranteed.OPT, nil)
    end
    for _, order in ipairs(permutations(invalidDefinitions)) do
        local c = { version = 1, objectives = order }
        local ok, code = ObjectiveGraph.validate(c)
        expectFalse(ok)
        expectEqual(code, "required_not_guaranteed")
        local guaranteed = ObjectiveGraph.computeGuaranteed(c)
        expectTrue(guaranteed.R1)
        expectEqual(guaranteed.R2, nil)
        expectEqual(guaranteed.R3, nil)
    end
end)

-- deterministic error ordering -------------------------------------------------------------------------------------

test("validation steps run in the documented order", function()
    -- structure beats everything after it
    local broken = objective("Z", REQ)
    broken.title = ""
    expectInvalid(content(objective("A", REQ, { allOf = { "B" } }), objective("B", REQ, { allOf = { "A" } }), broken), "invalid_title")
    -- identity beats references
    expectInvalid(content(objective("A", REQ, { allOf = { "NOPE" } }), objective("A", REQ)), "duplicate_objective_id")
    -- references beat cycles
    expectInvalid(content(objective("A", REQ, { allOf = { "B" } }), objective("B", REQ, { allOf = { "A", "NOPE" } })), "unknown_dependency")
    -- cycles beat the required-objective count and the progression rule
    expectInvalid(content(objective("A", OPT, { allOf = { "B" } }), objective("B", OPT, { allOf = { "A" } })), "dependency_cycle")
    -- required-objective count beats the progression rule (trivially, but pin it)
    expectInvalid(content(objective("A", OPT)), "no_required_objective")
end)

test("the first offender in definition order is the one reported within a step", function()
    expectInvalid(
        content(objective("A", REQ), objective("B", REQ, { allOf = { "X1" } }), objective("C", REQ, { allOf = { "X2" } })),
        "unknown_dependency",
        "B"
    )
    local firstBad = objective("B", REQ)
    firstBad.title = ""
    local secondBad = objective("C", REQ)
    secondBad.description = ""
    expectInvalid(content(objective("A", REQ), firstBad, secondBad), "invalid_title", "B")
end)

test("validation is deterministic and repeatable", function()
    local c = content(objective("A", OPT), objective("B", REQ, { anyOf = { "A" } }))
    local ok1, code1, subject1 = ObjectiveGraph.validate(c)
    for _ = 1, 20 do
        local ok, code, subject = ObjectiveGraph.validate(c)
        expectEqual(ok, ok1)
        expectEqual(code, code1)
        expectEqual(subject, subject1)
    end
end)

-- input ownership --------------------------------------------------------------------------------------------------

test("validate neither mutates nor freezes the caller's table", function()
    local c = content(objective("A", REQ), objective("B", REQ, { allOf = { "A" } }))
    local before = deepCopy(c)
    expectValid(c)
    expectTrue(deepEqual(c, before), "content unchanged")
    expectFalse(table.isfrozen(c))
    expectFalse(table.isfrozen(c.objectives))
    expectFalse(table.isfrozen(c.objectives[1]))
    local invalid = content(objective("A", OPT))
    local invalidBefore = deepCopy(invalid)
    ObjectiveGraph.validate(invalid)
    expectTrue(deepEqual(invalid, invalidBefore))
    expectFalse(table.isfrozen(invalid))
end)

test("validate accepts an already frozen table", function()
    local frozenContent = table.freeze({
        version = 1,
        objectives = table.freeze({
            table.freeze({
                id = "A",
                importance = "REQUIRED",
                title = "T",
                description = "D",
                completion = table.freeze({ kind = "SLOTS", slots = table.freeze({ table.freeze({ id = "S", pointId = "P", label = "L" }) }) }),
            }),
        }),
    })
    expectValid(frozenContent)
end)

-- compile ----------------------------------------------------------------------------------------------------------

test("compile returns a frozen plan copied from the content", function()
    local c = content(objective("A", REQ), objective("B", OPT, { allOf = { "A" } }))
    local plan, code = ObjectiveGraph.compile(c)
    expectEqual(code, nil)
    expectTrue(plan ~= nil)
    local p: any = plan
    expectEqual(p.kind, ObjectiveGraph.PlanKind)
    expectEqual(p.version, 1)
    expectEqual(#p.order, 2)
    expectEqual(p.order[1], "A")
    expectEqual(p.order[2], "B")
    expectTrue(table.isfrozen(p))
    expectTrue(table.isfrozen(p.order))
    expectTrue(table.isfrozen(p.objectives))
    expectTrue(table.isfrozen(p.objectives.A))
    expectTrue(table.isfrozen(p.objectives.A.slots))
    expectTrue(table.isfrozen(p.objectives.B.requires))
    expectTrue(table.isfrozen(p.objectives.B.requires.allOf))
    expectFalse(table.isfrozen(c), "the caller's table stays untouched")
    -- mutating the original afterwards cannot reach the plan
    c.objectives[1].title = "Changed"
    c.objectives[2].requires.allOf[1] = "ZZZ"
    expectEqual(p.objectives.A.title, "Title A")
    expectEqual(p.objectives.B.requires.allOf[1], "A")
    expectFalse(p.objectives.A.hiddenUntilAvailable)
end)

test("compile reports the same codes as validate and never returns a plan for invalid content", function()
    local c = content(objective("A", OPT), objective("B", REQ, { anyOf = { "A" } }))
    local plan, code, subject = ObjectiveGraph.compile(c)
    expectEqual(plan, nil)
    expectEqual(code, "required_not_guaranteed")
    expectEqual(subject, "B")
    local none, badCode = ObjectiveGraph.compile("x")
    expectEqual(none, nil)
    expectEqual(badCode, "invalid_content_table")
end)

test("plan.evaluate delegates to the dependency evaluation and treats unknown ids as impossible", function()
    local plan: any = ObjectiveGraph.compile(content(objective("A", REQ), objective("B", REQ, { allOf = { "A" } })))
    local states: { [string]: string } = { A = "AVAILABLE" }
    local function stateOf(id: string): string?
        return states[id]
    end
    expectEqual(plan.evaluate("A", stateOf), "SATISFIED", "no requires")
    expectEqual(plan.evaluate("B", stateOf), "PENDING")
    states.A = "COMPLETED"
    expectEqual(plan.evaluate("B", stateOf), "SATISFIED")
    expectEqual(plan.evaluate("NOPE", stateOf), "IMPOSSIBLE")
end)

-- runtime dependency evaluation -----------------------------------------------------------------------------------

local function evaluate(requires: any, states: { [string]: string }): string
    return ObjectiveGraph.evaluateDependency(requires, function(id: string): string?
        return states[id]
    end)
end

test("evaluateDependency: no requirement is satisfied", function()
    expectEqual(evaluate(nil, {}), "SATISFIED")
end)

test("evaluateDependency: allOf", function()
    local spec = { allOf = { "A", "B" } }
    expectEqual(evaluate(spec, { A = "COMPLETED", B = "COMPLETED" }), "SATISFIED")
    expectEqual(evaluate(spec, { A = "COMPLETED", B = "IN_PROGRESS" }), "PENDING")
    expectEqual(evaluate(spec, { A = "COMPLETED" }), "PENDING", "unknown member is pending")
    expectEqual(evaluate(spec, { A = "COMPLETED", B = "FAILED" }), "IMPOSSIBLE")
    expectEqual(evaluate(spec, { A = "CANCELLED", B = "AVAILABLE" }), "IMPOSSIBLE", "any dead member")
    expectEqual(evaluate(spec, { A = "LOCKED", B = "LOCKED" }), "PENDING")
end)

test("evaluateDependency: anyOf", function()
    local spec = { anyOf = { "A", "B" } }
    expectEqual(evaluate(spec, { A = "COMPLETED", B = "LOCKED" }), "SATISFIED")
    expectEqual(evaluate(spec, { A = "FAILED", B = "COMPLETED" }), "SATISFIED")
    expectEqual(evaluate(spec, { A = "FAILED", B = "AVAILABLE" }), "PENDING")
    expectEqual(evaluate(spec, { A = "FAILED", B = "CANCELLED" }), "IMPOSSIBLE", "all dead")
    expectEqual(evaluate(spec, { A = "IN_PROGRESS", B = "LOCKED" }), "PENDING")
end)

test("evaluateDependency: both clauses combine and an optional anyOf member still satisfies at runtime", function()
    local spec = { allOf = { "R" }, anyOf = { "O", "R2" } }
    expectEqual(evaluate(spec, { R = "COMPLETED", O = "COMPLETED", R2 = "AVAILABLE" }), "SATISFIED")
    expectEqual(evaluate(spec, { R = "AVAILABLE", O = "COMPLETED", R2 = "AVAILABLE" }), "PENDING")
    expectEqual(evaluate(spec, { R = "FAILED", O = "COMPLETED", R2 = "COMPLETED" }), "IMPOSSIBLE", "an impossible clause wins")
    expectEqual(evaluate(spec, { R = "COMPLETED", O = "CANCELLED", R2 = "FAILED" }), "IMPOSSIBLE")
end)