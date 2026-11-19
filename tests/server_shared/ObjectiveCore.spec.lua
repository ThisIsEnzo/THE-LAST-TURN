--!strict
local Harness = require("../Harness")
local ObjectiveGraph = require("../../src/server_shared/Objective/ObjectiveGraph")
local ObjectiveCore = require("../../src/server_shared/Objective/ObjectiveCore")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual
local Reasons = ObjectiveCore.Reasons

local REQ, OPT = "REQUIRED", "OPTIONAL"

local function signalDef(id: string, importance: string, token: string, requires: any?): any
    return { id = id, importance = importance, requires = requires, title = "Signal " .. id, description = "Signal objective",
        completion = { kind = "SIGNAL", signal = { sourceToken = token } } }
end

local function def(id: string, importance: string, requires: any?, slotCount: number?, hidden: boolean?): any
    local slots = {}
    for index = 1, slotCount or 1 do
        table.insert(slots, { id = "S" .. index, pointId = id .. "_P" .. index, label = id .. " slot " .. index })
    end
    return {
        id = id,
        importance = importance,
        requires = requires,
        title = "Title " .. id,
        description = "Description " .. id,
        hiddenUntilAvailable = hidden,
        completion = { kind = "SLOTS", slots = slots },
    }
end

local function planOf(...: any): any
    local plan, code, subject = ObjectiveGraph.compile({ version = 1, objectives = { ... } })
    if plan == nil then
        error("test graph invalid: " .. tostring(code) .. " " .. tostring(subject))
    end
    return plan
end

-- The first-slice shape: P (3 slots) -> W -> X, plus an independent optional O.
local function slicePlan(): any
    return planOf(
        def("P", REQ, nil, 3),
        def("W", REQ, { allOf = { "P" } }),
        def("X", REQ, { allOf = { "W" } }),
        def("O", OPT)
    )
end

local clock = 100
local function tick(): number
    clock = clock + 1
    return clock
end

local function newCore(plan: any?): any
    return ObjectiveCore.new(plan or slicePlan(), 0)
end

local function check(core: any)
    local ok, detail = core:checkInvariants()
    expectTrue(ok, "invariants: " .. tostring(detail))
end

local function put(core: any, objectiveId: any, slotId: any, userId: any, eligible: boolean?): any
    local result = core:contribute(objectiveId, slotId, userId, { eligible = eligible ~= false, now = tick() })
    check(core)
    return result
end

local function fillAll(core: any, objectiveId: string, slotCount: number, userId: number)
    for index = 1, slotCount do
        local result = put(core, objectiveId, "S" .. index, userId)
        expectTrue(result.ok, "fill " .. objectiveId .. " S" .. index .. ": " .. tostring(result.reason))
    end
end

local function snapshotKey(core: any): string
    local parts = {}
    local snapshot = core:getSnapshot()
    table.insert(parts, "rev=" .. snapshot.revision)
    for _, entry in ipairs(snapshot.objectives) do
        table.insert(parts, entry.id .. ":" .. entry.state .. ":" .. entry.filled .. "/" .. entry.required)
    end
    return table.concat(parts, "|")
end

local function expectRejected(result: any, reason: string, label: string?)
    expectFalse(result.ok, label)
    expectEqual(result.reason, reason, label)
    expectFalse(result.changed, label)
    expectEqual(#result.changes, 0, label)
    expectEqual(result.resolution, nil, label)
end

-- construction -----------------------------------------------------------------------------------------------------

test("new requires a compiled plan and a finite clock", function()
    Harness.expectError(function()
        ObjectiveCore.new({}, 0)
    end, "empty table")
    Harness.expectError(function()
        ObjectiveCore.new(nil, 0)
    end, "nil plan")
    Harness.expectError(function()
        ObjectiveCore.new({ kind = "ObjectiveGraphPlan", order = {}, objectives = {}, evaluate = function() end }, 0)
    end, "empty plan")
    Harness.expectError(function()
        ObjectiveCore.new(slicePlan(), 0 / 0)
    end, "NaN clock")
    Harness.expectError(function()
        ObjectiveCore.new(slicePlan(), math.huge)
    end, "infinite clock")
    Harness.expectError(function()
        ObjectiveCore.new(slicePlan(), "0")
    end, "string clock")
end)

test("constants are stable and frozen", function()
    expectTrue(table.isfrozen(ObjectiveCore.States))
    expectTrue(table.isfrozen(ObjectiveCore.Reasons))
    expectTrue(table.isfrozen(ObjectiveCore.Outcomes))
    expectTrue(table.isfrozen(ObjectiveCore.ResolutionReasons))
    expectEqual(ObjectiveCore.SnapshotVersion, 1)
    expectEqual(ObjectiveCore.ResolutionReasons.OBJECTIVES_COMPLETE, "objectives_complete")
    expectEqual(ObjectiveCore.ResolutionReasons.OBJECTIVE_FAILED, "objective_failed")
    expectEqual(ObjectiveCore.ResolutionReasons.OBJECTIVE_UNREACHABLE, "objective_unreachable")
end)

-- initialization ---------------------------------------------------------------------------------------------------

test("initialization makes root objectives available and leaves the rest locked", function()
    local core = newCore()
    expectEqual(core:getState("P"), "AVAILABLE")
    expectEqual(core:getState("W"), "LOCKED")
    expectEqual(core:getState("X"), "LOCKED")
    expectEqual(core:getState("O"), "AVAILABLE")
    expectEqual(core:getState("NOPE"), nil)
    expectEqual(core:getRevision(), 0, "initialization is not a change")
    expectFalse(core:isResolved())
    expectEqual(core:getResolution(), nil)
    expectEqual(core:getFilledCount("P"), 0)
    expectEqual(core:getFilledCount("NOPE"), nil)
    check(core)
end)

test("initialization is deterministic and independent of the content order of roots", function()
    local a = newCore()
    local b = newCore()
    expectEqual(snapshotKey(a), snapshotKey(b))
    local reordered = newCore(planOf(def("O", OPT), def("X", REQ, { allOf = { "W" } }), def("W", REQ, { allOf = { "P" } }), def("P", REQ, nil, 3)))
    expectEqual(reordered:getState("P"), "AVAILABLE")
    expectEqual(reordered:getState("O"), "AVAILABLE")
    expectEqual(reordered:getState("W"), "LOCKED")
    expectEqual(reordered:getState("X"), "LOCKED")
    check(reordered)
end)

test("initialization resolves anyOf roots through the cascade and never leaves a satisfiable objective locked", function()
    -- A diamond: BOTTOM stays locked until both sides complete; a dependency-free objective listed last is still a root.
    local core = newCore(planOf(
        def("BOTTOM", REQ, { allOf = { "LEFT", "RIGHT" } }),
        def("LEFT", REQ, { allOf = { "TOP" } }),
        def("RIGHT", REQ, { allOf = { "TOP" } }),
        def("TOP", REQ)
    ))
    expectEqual(core:getState("TOP"), "AVAILABLE")
    expectEqual(core:getState("LEFT"), "LOCKED")
    expectEqual(core:getState("RIGHT"), "LOCKED")
    expectEqual(core:getState("BOTTOM"), "LOCKED")
    check(core)
end)

test("the store copies nothing from the caller: a compiled plan cannot be changed afterwards", function()
    local content = { version = 1, objectives = { def("A", REQ) } }
    local plan: any = ObjectiveGraph.compile(content)
    local core = ObjectiveCore.new(plan, 0)
    content.objectives[1].title = "Changed"
    expectEqual(core:getSnapshot().objectives[1].title, "Title A")
end)

-- trusted SIGNAL completion --------------------------------------------------------------------------------------

test("SIGNAL completion validates token, completes once and is idempotent", function()
    local core = newCore(planOf(signalDef("DOC", REQ, "evidence_token")))
    local wrong = core:completeBySignal("DOC", "wrong", tick())
    expectFalse(wrong.ok)
    expectEqual(wrong.reason, Reasons.INVALID_SIGNAL_TOKEN)
    expectEqual(core:getRevision(), 0)
    local applied = core:completeBySignal("DOC", "evidence_token", tick())
    expectTrue(applied.ok)
    expectTrue(applied.changed)
    expectEqual(core:getState("DOC"), "COMPLETED")
    expectEqual(core:getRevision(), 1)
    local duplicate = core:completeBySignal("DOC", "evidence_token", tick())
    expectTrue(duplicate.ok)
    expectFalse(duplicate.changed)
    expectEqual(core:getRevision(), 1)
    check(core)
end)

test("SIGNAL rejects SLOTS and cannot complete while LOCKED", function()
    local slots = newCore()
    expectEqual(slots:completeBySignal("P", "token", tick()).reason, Reasons.NOT_SIGNAL)
    local core = newCore(planOf(signalDef("ROOT", REQ, "root"), signalDef("CHILD", REQ, "child", { allOf = { "ROOT" } })))
    expectEqual(core:completeBySignal("CHILD", "child", tick()).reason, Reasons.NOT_AVAILABLE)
    expectTrue(core:completeBySignal("ROOT", "root", tick()).ok)
    expectEqual(core:getState("CHILD"), "AVAILABLE")
    expectTrue(core:completeBySignal("CHILD", "child", tick()).ok)
    check(core)
end)

test("SIGNAL snapshot is projected as one display-only step", function()
    local core = newCore(planOf(signalDef("DOC", REQ, "token")))
    local before = core:getSnapshot().objectives[1]
    expectEqual(before.required, 1)
    expectEqual(before.filled, 0)
    expectEqual(#before.slots, 1)
    core:completeBySignal("DOC", "token", tick())
    local after = core:getSnapshot().objectives[1]
    expectEqual(after.required, 1)
    expectEqual(after.filled, 1)
    expectTrue(after.slots[1].filled)
end)

-- contribution lifecycle -------------------------------------------------------------------------------------------

test("a multi-slot objective goes AVAILABLE -> IN_PROGRESS -> COMPLETED and unlocks its dependent in the same command", function()
    local core = newCore()
    local first = put(core, "P", "S1", 11)
    expectTrue(first.ok)
    expectTrue(first.changed)
    expectEqual(first.reason, nil)
    expectEqual(first.resolution, nil)
    expectEqual(#first.changes, 2)
    expectEqual(first.changes[1].kind, "SLOT")
    expectEqual(first.changes[1].objectiveId, "P")
    expectEqual(first.changes[1].slotId, "S1")
    expectEqual(first.changes[1].userId, 11)
    expectEqual(first.changes[2].kind, "STATE")
    expectEqual(first.changes[2].from, "AVAILABLE")
    expectEqual(first.changes[2].to, "IN_PROGRESS")
    expectEqual(core:getState("P"), "IN_PROGRESS")
    expectEqual(core:getFilledCount("P"), 1)
    expectEqual(core:getState("W"), "LOCKED")

    local second = put(core, "P", "S2", 12)
    expectTrue(second.ok)
    expectEqual(#second.changes, 1, "no state change while still in progress")
    expectEqual(second.changes[1].kind, "SLOT")
    expectEqual(core:getState("P"), "IN_PROGRESS")

    local third = put(core, "P", "S3", 11)
    expectTrue(third.ok)
    expectEqual(#third.changes, 3)
    expectEqual(third.changes[1].kind, "SLOT")
    expectEqual(third.changes[2].to, "COMPLETED")
    expectEqual(third.changes[3].objectiveId, "W")
    expectEqual(third.changes[3].from, "LOCKED")
    expectEqual(third.changes[3].to, "AVAILABLE")
    expectEqual(core:getState("P"), "COMPLETED")
    expectEqual(core:getState("W"), "AVAILABLE")
    expectEqual(core:getState("X"), "LOCKED")
    expectFalse(core:isResolved(), "objective completion is not mission completion")
end)

test("a single-slot objective completes on its only contribution", function()
    local core = newCore()
    fillAll(core, "P", 3, 1)
    local result = put(core, "W", "S1", 1)
    expectTrue(result.ok)
    expectEqual(result.changes[2].from, "AVAILABLE")
    expectEqual(result.changes[2].to, "COMPLETED")
    expectEqual(result.changes[3].objectiveId, "X")
    expectEqual(core:getState("X"), "AVAILABLE")
end)

test("slots can be filled in any order by any players", function()
    local core = newCore()
    expectTrue(put(core, "P", "S3", 5).ok)
    expectTrue(put(core, "P", "S1", 9).ok)
    expectTrue(put(core, "P", "S2", 5).ok)
    expectEqual(core:getState("P"), "COMPLETED")
    expectEqual(core:getContributor("P", "S3"), 5)
    expectEqual(core:getContributor("P", "S1"), 9)
    expectEqual(core:getContributor("P", "S2"), 5)
end)

test("a solo player can complete the whole required path and resolve the mission", function()
    local core = newCore()
    fillAll(core, "P", 3, 1)
    fillAll(core, "W", 1, 1)
    local last = put(core, "X", "S1", 1)
    expectTrue(last.ok)
    expectTrue(last.resolution ~= nil)
    expectEqual(last.resolution.outcome, "COMPLETED")
    expectEqual(last.resolution.reason, "objectives_complete")
    expectTrue(core:isResolved())
    expectEqual(core:getState("O"), "AVAILABLE", "the optional objective was never touched")
end)

test("parallel objectives progress independently", function()
    local core = newCore()
    expectTrue(put(core, "P", "S1", 1).ok)
    expectTrue(put(core, "O", "S1", 2).ok)
    expectEqual(core:getState("O"), "COMPLETED")
    expectEqual(core:getState("P"), "IN_PROGRESS")
    expectEqual(core:getFilledCount("P"), 1)
    expectFalse(core:isResolved(), "finishing the optional objective alone does not resolve the mission")
end)

test("an optional objective never blocks nor triggers resolution", function()
    local core = newCore()
    fillAll(core, "P", 3, 1)
    fillAll(core, "W", 1, 1)
    expectEqual(core:getState("O"), "AVAILABLE")
    local last = put(core, "X", "S1", 1)
    expectEqual(last.resolution.outcome, "COMPLETED")
    expectEqual(core:getState("O"), "AVAILABLE")
    -- after resolution nothing can be contributed any more, not even to the open optional objective
    expectRejected(put(core, "O", "S1", 1), Reasons.MISSION_RESOLVED)
end)

test("the optional objective completed first does not change resolution later", function()
    local core = newCore()
    expectTrue(put(core, "O", "S1", 3).ok)
    fillAll(core, "P", 3, 1)
    fillAll(core, "W", 1, 1)
    local last = put(core, "X", "S1", 1)
    expectEqual(last.resolution.reason, "objectives_complete")
end)

test("a dependency cascade follows anyOf alternatives (optional shortcut) and allOf joins", function()
    local plan = planOf(
        def("A", REQ),
        def("B", OPT),
        def("C", REQ, { anyOf = { "A", "B" } }),
        def("D", REQ, { allOf = { "A" }, anyOf = { "B", "C" } })
    )
    local viaOptional = newCore(plan)
    expectEqual(viaOptional:getState("C"), "LOCKED")
    local result = put(viaOptional, "B", "S1", 1)
    expectEqual(viaOptional:getState("C"), "AVAILABLE", "the optional member unlocks the anyOf dependent")
    expectEqual(result.changes[3].objectiveId, "C")
    expectEqual(viaOptional:getState("D"), "LOCKED", "allOf A still pending")
    put(viaOptional, "A", "S1", 1)
    expectEqual(viaOptional:getState("D"), "AVAILABLE")

    local viaRequired = newCore(plan)
    put(viaRequired, "A", "S1", 1)
    expectEqual(viaRequired:getState("C"), "AVAILABLE")
    expectEqual(viaRequired:getState("D"), "LOCKED", "an AVAILABLE member does not satisfy anyOf; only COMPLETED does")
    put(viaRequired, "C", "S1", 1)
    expectEqual(viaRequired:getState("D"), "AVAILABLE", "B is not needed: C also satisfies the anyOf")
    expectEqual(viaRequired:getState("B"), "AVAILABLE")
end)

test("a long chain unlocks stepwise, one level per completed objective", function()
    local core = newCore(planOf(def("A", REQ), def("B", REQ, { allOf = { "A" } }), def("C", REQ, { allOf = { "B" } }), def("D", REQ, { allOf = { "C" } })))
    put(core, "A", "S1", 1)
    expectEqual(core:getState("B"), "AVAILABLE")
    expectEqual(core:getState("C"), "LOCKED")
    put(core, "B", "S1", 1)
    expectEqual(core:getState("C"), "AVAILABLE")
    expectEqual(core:getState("D"), "LOCKED")
end)

test("cascade passes handle dependents listed before their dependencies in a single command", function()
    local core = newCore(planOf(def("R", REQ), def("C", OPT, { allOf = { "B" } }), def("B", OPT, { allOf = { "A" } }), def("A", OPT)))
    expectEqual(core:getState("C"), "LOCKED")
    local result = put(core, "A", "S1", 1)
    expectEqual(core:getState("B"), "AVAILABLE")
    expectEqual(core:getState("C"), "LOCKED")
    expectEqual(#result.changes, 3)
end)

-- rejection --------------------------------------------------------------------------------------------------------

test("duplicate contribution attempts are rejected without any change", function()
    local core = newCore()
    expectTrue(put(core, "P", "S1", 1).ok)
    local before = snapshotKey(core)
    expectRejected(put(core, "P", "S1", 1), Reasons.ALREADY_FILLED, "same player")
    expectRejected(put(core, "P", "S1", 2), Reasons.ALREADY_FILLED, "another player")
    expectEqual(snapshotKey(core), before)
    expectEqual(core:getContributor("P", "S1"), 1, "the first contributor keeps the attribution")
    expectEqual(core:getFilledCount("P"), 1)
end)

test("two players racing for the same slot: exactly one fill is accepted", function()
    local core = newCore()
    local first = put(core, "P", "S2", 21)
    local second = put(core, "P", "S2", 22)
    expectTrue(first.ok)
    expectRejected(second, Reasons.ALREADY_FILLED)
    expectEqual(core:getContributor("P", "S2"), 21)
    expectEqual(core:getRevision(), 1)
end)

test("invalid contexts are rejected", function()
    local core = newCore()
    local before = snapshotKey(core)
    expectRejected(core:contribute("P", "S1", 1, nil), Reasons.INVALID_CONTEXT)
    expectRejected(core:contribute("P", "S1", 1, "ctx"), Reasons.INVALID_CONTEXT)
    expectRejected(core:contribute("P", "S1", 1, { now = 1 }), Reasons.INVALID_CONTEXT)
    expectRejected(core:contribute("P", "S1", 1, { eligible = 1, now = 1 }), Reasons.INVALID_CONTEXT)
    expectRejected(core:contribute("P", "S1", 1, { eligible = true }), Reasons.INVALID_CONTEXT)
    expectRejected(core:contribute("P", "S1", 1, { eligible = true, now = "1" }), Reasons.INVALID_CONTEXT)
    expectRejected(core:contribute("P", "S1", 1, { eligible = true, now = 0 / 0 }), Reasons.INVALID_CONTEXT)
    expectRejected(core:contribute("P", "S1", 1, { eligible = true, now = math.huge }), Reasons.INVALID_CONTEXT)
    expectRejected(core:contribute("P", "S1", 1, { eligible = true, now = -math.huge }), Reasons.INVALID_CONTEXT)
    expectEqual(snapshotKey(core), before)
    check(core)
end)

test("invalid contributors are rejected", function()
    local core = newCore()
    local before = snapshotKey(core)
    for _, bad in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, 9007199254740992 }) do
        expectRejected(put(core, "P", "S1", bad), Reasons.INVALID_CONTRIBUTOR, tostring(bad))
    end
    expectRejected(put(core, "P", "S1", "1"), Reasons.INVALID_CONTRIBUTOR, "string")
    expectRejected(put(core, "P", "S1", nil), Reasons.INVALID_CONTRIBUTOR, "nil")
    expectRejected(put(core, "P", "S1", {}), Reasons.INVALID_CONTRIBUTOR, "table")
    expectEqual(snapshotKey(core), before)
    expectTrue(put(core, "P", "S1", 9007199254740991).ok, "the maximum user id is accepted")
end)

test("an ineligible contributor changes nothing and progress stays team-owned", function()
    local core = newCore()
    expectTrue(put(core, "P", "S1", 7).ok)
    -- the contributor later dies or disconnects: the service reports them ineligible; nothing is rolled back
    expectRejected(put(core, "P", "S2", 7, false), Reasons.INELIGIBLE_CONTRIBUTOR)
    expectEqual(core:getFilledCount("P"), 1)
    expectEqual(core:getContributor("P", "S1"), 7)
    expectEqual(core:getState("P"), "IN_PROGRESS")
    -- a teammate carries on and completes the objective
    expectTrue(put(core, "P", "S2", 8).ok)
    expectTrue(put(core, "P", "S3", 8).ok)
    expectEqual(core:getState("P"), "COMPLETED")
    expectEqual(core:getContributor("P", "S1"), 7, "attribution of the earlier contribution survives")
end)

test("unknown and malformed objective and slot ids are rejected", function()
    local core = newCore()
    local before = snapshotKey(core)
    expectRejected(put(core, "NOPE", "S1", 1), Reasons.UNKNOWN_OBJECTIVE)
    expectRejected(put(core, 5, "S1", 1), Reasons.INVALID_OBJECTIVE_ID)
    expectRejected(put(core, nil, "S1", 1), Reasons.INVALID_OBJECTIVE_ID)
    expectRejected(put(core, "P", "NOPE", 1), Reasons.UNKNOWN_SLOT)
    expectRejected(put(core, "P", 1, 1), Reasons.INVALID_SLOT_ID)
    expectRejected(put(core, "P", nil, 1), Reasons.INVALID_SLOT_ID)
    expectRejected(put(core, "W", "S9", 1), Reasons.UNKNOWN_SLOT, "slot checked before state")
    expectEqual(snapshotKey(core), before)
end)

test("rejection precedence is fixed", function()
    local core = newCore()
    -- context beats contributor beats eligibility
    expectRejected(core:contribute("NOPE", "NOPE", 0, nil), Reasons.INVALID_CONTEXT)
    expectRejected(core:contribute("NOPE", "NOPE", 0, { eligible = false, now = 1 }), Reasons.INVALID_CONTRIBUTOR)
    expectRejected(core:contribute("NOPE", "NOPE", 1, { eligible = false, now = 1 }), Reasons.INELIGIBLE_CONTRIBUTOR)
    expectRejected(core:contribute("NOPE", "NOPE", 1, { eligible = true, now = 1 }), Reasons.UNKNOWN_OBJECTIVE)
    expectRejected(core:contribute("W", "S1", 1, { eligible = true, now = 1 }), Reasons.NOT_AVAILABLE)
end)

test("locked objectives cannot receive contributions", function()
    local core = newCore()
    expectRejected(put(core, "W", "S1", 1), Reasons.NOT_AVAILABLE)
    expectRejected(put(core, "X", "S1", 1), Reasons.NOT_AVAILABLE)
    expectEqual(core:getState("W"), "LOCKED")
    expectEqual(core:getFilledCount("W"), 0)
    expectEqual(core:getRevision(), 0)
end)

test("terminal objectives cannot receive contributions", function()
    local core = newCore()
    fillAll(core, "P", 3, 1)
    expectRejected(put(core, "P", "S1", 2), Reasons.OBJECTIVE_TERMINAL, "completed")
    expectTrue(core:cancel("O", "binding_failed", tick()).ok)
    expectRejected(put(core, "O", "S1", 2), Reasons.OBJECTIVE_TERMINAL, "cancelled")
    local plan = planOf(def("A", REQ), def("B", OPT))
    local failing = newCore(plan)
    expectTrue(failing:fail("B", "broken", tick()).ok)
    expectRejected(put(failing, "B", "S1", 1), Reasons.OBJECTIVE_TERMINAL, "failed")
end)

-- fail and cancel --------------------------------------------------------------------------------------------------

test("failing a REQUIRED objective fails its dependents atomically and resolves the mission as failed", function()
    local core = newCore()
    put(core, "P", "S1", 1)
    local revisionBefore = core:getRevision()
    local result = core:fail("P", "pump_exploded", tick())
    check(core)
    expectTrue(result.ok)
    expectTrue(result.changed)
    expectEqual(result.changes[1].objectiveId, "P")
    expectEqual(result.changes[1].from, "IN_PROGRESS")
    expectEqual(result.changes[1].to, "FAILED")
    expectEqual(result.changes[1].reason, "pump_exploded")
    expectEqual(result.changes[2].objectiveId, "W")
    expectEqual(result.changes[2].to, "FAILED")
    expectEqual(result.changes[2].reason, "dependency_unreachable")
    expectEqual(result.changes[3].objectiveId, "X")
    expectEqual(result.changes[3].reason, "dependency_unreachable")
    expectEqual(core:getState("O"), "AVAILABLE")
    expectEqual(result.resolution.outcome, "FAILED")
    expectEqual(result.resolution.reason, "objective_failed")
    expectEqual(core:getRevision(), revisionBefore + 1, "one revision per command, however large the cascade")
end)

test("failing an AVAILABLE objective works and an OPTIONAL failure does not resolve the mission", function()
    local core = newCore()
    local result = core:fail("O", "sabotaged", tick())
    check(core)
    expectTrue(result.ok)
    expectEqual(core:getState("O"), "FAILED")
    expectEqual(result.resolution, nil)
    expectFalse(core:isResolved())
end)

test("fail and cancel are idempotent for the state they produce", function()
    local core = newCore()
    expectTrue(core:fail("O", "broken", tick()).changed)
    local revision = core:getRevision()
    local again = core:fail("O", "other_reason", tick())
    expectTrue(again.ok)
    expectFalse(again.changed)
    expectEqual(#again.changes, 0)
    expectEqual(core:getRevision(), revision)
    local other = newCore()
    expectTrue(other:cancel("O", "gone", tick()).changed)
    local again2 = other:cancel("O", "gone_again", tick())
    expectTrue(again2.ok)
    expectFalse(again2.changed)
end)

test("invalid transitions are rejected", function()
    local core = newCore()
    fillAll(core, "P", 3, 1)
    expectRejected(core:fail("P", "late", tick()), Reasons.INVALID_TRANSITION, "completed cannot fail")
    expectRejected(core:fail("W2", "x", tick()), Reasons.UNKNOWN_OBJECTIVE)
    expectRejected(core:fail("X", "x", tick()), Reasons.NOT_AVAILABLE, "locked objectives end only through the cascade")
    expectRejected(core:cancel("P", "late", tick()), Reasons.REQUIRED_CANNOT_CANCEL)
    local other = newCore()
    expectTrue(other:cancel("O", "gone", tick()).ok)
    expectRejected(other:fail("O", "late", tick()), Reasons.INVALID_TRANSITION, "cancelled cannot fail")
    local third = newCore()
    expectTrue(third:fail("O", "broken", tick()).ok)
    expectRejected(third:cancel("O", "late", tick()), Reasons.INVALID_TRANSITION, "failed cannot be cancelled")
    check(core)
    check(other)
    check(third)
end)

test("fail and cancel validate time, reason and ids", function()
    local core = newCore()
    expectRejected(core:fail("O", "ok_reason", 0 / 0), Reasons.INVALID_TIME)
    expectRejected(core:fail("O", "ok_reason", "1"), Reasons.INVALID_TIME)
    expectRejected(core:fail("O", "", 1), Reasons.INVALID_REASON)
    expectRejected(core:fail("O", "has space", 1), Reasons.INVALID_REASON)
    expectRejected(core:fail("O", string.rep("a", 49), 1), Reasons.INVALID_REASON)
    expectRejected(core:fail("O", 5, 1), Reasons.INVALID_REASON)
    expectRejected(core:fail(5, "reason", 1), Reasons.INVALID_OBJECTIVE_ID)
    expectRejected(core:cancel("O", nil, 1), Reasons.INVALID_REASON)
    expectTrue(core:fail("O", string.rep("a", 48), 1).ok, "48 character reasons are accepted")
    expectEqual(core:getRevision(), 1)
end)

test("REQUIRED objectives cannot be cancelled in any state", function()
    local core = newCore()
    expectRejected(core:cancel("P", "nope", tick()), Reasons.REQUIRED_CANNOT_CANCEL, "available")
    put(core, "P", "S1", 1)
    expectRejected(core:cancel("P", "nope", tick()), Reasons.REQUIRED_CANNOT_CANCEL, "in progress")
    expectRejected(core:cancel("W", "nope", tick()), Reasons.REQUIRED_CANNOT_CANCEL, "locked")
    put(core, "P", "S2", 1)
    put(core, "P", "S3", 1)
    expectRejected(core:cancel("P", "nope", tick()), Reasons.REQUIRED_CANNOT_CANCEL, "completed")
    expectEqual(core:getState("P"), "COMPLETED")
    check(core)
end)

test("cancelling an optional objective cascades to its dependents without resolving the mission", function()
    local core = newCore(planOf(def("R", REQ), def("O1", OPT), def("O2", OPT, { allOf = { "O1" } }), def("O3", OPT, { anyOf = { "O2" } })))
    expectEqual(core:getState("O2"), "LOCKED")
    local result = core:cancel("O1", "area_sealed", tick())
    check(core)
    expectTrue(result.ok)
    expectEqual(core:getState("O1"), "CANCELLED")
    expectEqual(core:getState("O2"), "CANCELLED")
    expectEqual(core:getState("O3"), "CANCELLED")
    expectEqual(result.changes[2].reason, "dependency_unreachable")
    expectEqual(result.resolution, nil)
    expectEqual(core:getState("R"), "AVAILABLE")
    expectTrue(put(core, "R", "S1", 1).resolution ~= nil)
end)

test("a required anyOf survives a cancelled optional alternative while another route is open", function()
    local core = newCore(planOf(def("A", REQ), def("B", OPT), def("C", REQ, { anyOf = { "A", "B" } })))
    expectTrue(core:cancel("B", "gone", tick()).ok)
    expectEqual(core:getState("C"), "LOCKED", "still pending through A")
    expectFalse(core:isResolved())
    put(core, "A", "S1", 1)
    expectEqual(core:getState("C"), "AVAILABLE")
end)

test("defense in depth: a required objective whose dependencies become impossible fails the mission as unreachable", function()
    -- Validated content can never produce this (the progression rule), so the plan is hand-built to exercise the Core.
    local base: any = planOf(def("O", OPT), def("A", REQ))
    local objectives = {
        O = base.objectives.O,
        A = base.objectives.A,
        C = { id = "C", importance = "REQUIRED", requires = { anyOf = { "O" } }, title = "C", description = "C", hiddenUntilAvailable = false, slots = { { id = "S1", pointId = "C_P1", label = "C" } } },
    }
    local plan = {
        kind = "ObjectiveGraphPlan",
        version = 1,
        order = { "O", "A", "C" },
        objectives = objectives,
        evaluate = function(id: string, stateOf: (string) -> string?): string
            return ObjectiveGraph.evaluateDependency(objectives[id].requires, stateOf)
        end,
    }
    local core = ObjectiveCore.new(plan, 0)
    local result = core:cancel("O", "gone", tick())
    check(core)
    expectTrue(result.ok)
    expectEqual(core:getState("C"), "FAILED")
    expectEqual(result.resolution.outcome, "FAILED")
    expectEqual(result.resolution.reason, "objective_unreachable")
end)

test("an explicit failure takes precedence over an unreachable failure in the resolution reason", function()
    local base: any = planOf(def("O", OPT), def("A", REQ))
    local objectives = {
        O = base.objectives.O,
        C = { id = "C", importance = "REQUIRED", requires = { anyOf = { "O" } }, title = "C", description = "C", hiddenUntilAvailable = false, slots = { { id = "S1", pointId = "C_P1", label = "C" } } },
        A = base.objectives.A,
    }
    local plan = {
        kind = "ObjectiveGraphPlan",
        version = 1,
        order = { "O", "C", "A" },
        objectives = objectives,
        evaluate = function(id: string, stateOf: (string) -> string?): string
            return ObjectiveGraph.evaluateDependency(objectives[id].requires, stateOf)
        end,
    }
    local core = ObjectiveCore.new(plan, 0)
    expectTrue(core:cancel("O", "gone", tick()).ok)
    expectEqual(core:getResolution().reason, "objective_unreachable")
    local other = ObjectiveCore.new(plan, 0)
    -- fail A first (explicit), then cancel O: the mission is already resolved, so the later cancel is rejected
    expectEqual(other:fail("A", "boom", tick()).resolution.reason, "objective_failed")
    expectRejected(other:cancel("O", "gone", tick()), Reasons.MISSION_RESOLVED)
end)

-- atomicity --------------------------------------------------------------------------------------------------------

test("rejected commands leave the snapshot and revision untouched", function()
    local core = newCore()
    put(core, "P", "S1", 1)
    local before = snapshotKey(core)
    put(core, "P", "S1", 1)
    put(core, "W", "S1", 1)
    put(core, "NOPE", "S1", 1)
    core:fail("X", "x", tick())
    core:cancel("P", "x", tick())
    expectEqual(snapshotKey(core), before)
    check(core)
end)

test("a context that raises while being read aborts before any mutation", function()
    local core = newCore()
    put(core, "P", "S1", 1)
    local before = snapshotKey(core)
    local hostile = setmetatable({}, {
        __index = function()
            error("boom")
        end,
    })
    expectFalse(pcall(function()
        core:contribute("P", "S2", 2, hostile)
    end))
    expectEqual(snapshotKey(core), before)
    check(core)
    -- the store is still fully usable afterwards
    expectTrue(put(core, "P", "S2", 2).ok)
end)

test("a hostile reason or id that raises while being read aborts before any mutation", function()
    local core = newCore()
    local before = snapshotKey(core)
    local hostile = setmetatable({}, {
        __index = function()
            error("boom")
        end,
        __tostring = function()
            error("boom")
        end,
    })
    local ok = pcall(function()
        core:fail(hostile, "reason", tick())
    end)
    expectTrue(ok, "non-string ids are simply rejected")
    expectEqual(snapshotKey(core), before)
end)

-- revision ---------------------------------------------------------------------------------------------------------

test("the revision rises by exactly one per applied command and never on rejections or no-ops", function()
    local core = newCore()
    local revision = core:getRevision()
    local function expectBump(label: string)
        expectEqual(core:getRevision(), revision + 1, label)
        revision = core:getRevision()
    end
    local function expectSame(label: string)
        expectEqual(core:getRevision(), revision, label)
    end
    put(core, "P", "S1", 1)
    expectBump("first fill")
    put(core, "P", "S1", 1)
    expectSame("duplicate")
    put(core, "P", "S2", 1)
    expectBump("second fill")
    put(core, "P", "S3", 1)
    expectBump("completion with cascade")
    put(core, "P", "S1", 1)
    expectSame("terminal")
    core:cancel("O", "gone", tick())
    expectBump("optional cancel")
    core:cancel("O", "gone", tick())
    expectSame("idempotent cancel")
    core:fail("X", "x", tick())
    expectSame("locked fail")
    core:contribute("W", "S1", 1, { eligible = false, now = 1 })
    expectSame("ineligible")
end)

test("the snapshot revision follows the store revision", function()
    local core = newCore()
    expectEqual(core:getSnapshot().revision, 0)
    put(core, "P", "S1", 1)
    expectEqual(core:getSnapshot().revision, 1)
    put(core, "P", "S2", 1)
    expectEqual(core:getSnapshot().revision, 2)
end)

-- resolution -------------------------------------------------------------------------------------------------------

test("resolution is sticky and reported exactly once", function()
    local core = newCore()
    fillAll(core, "P", 3, 1)
    fillAll(core, "W", 1, 1)
    local last = put(core, "X", "S1", 1)
    expectTrue(last.resolution ~= nil)
    expectEqual(last.resolution.outcome, "COMPLETED")
    local revision = core:getRevision()
    local resolution = core:getResolution()
    expectEqual(resolution.outcome, "COMPLETED")
    -- every further mutation is rejected and reports nothing new
    expectRejected(put(core, "O", "S1", 2), Reasons.MISSION_RESOLVED)
    expectRejected(core:fail("O", "late", tick()), Reasons.MISSION_RESOLVED)
    expectRejected(core:cancel("O", "late", tick()), Reasons.MISSION_RESOLVED)
    expectEqual(core:getRevision(), revision)
    expectEqual(core:getResolution().reason, "objectives_complete")
    -- a resolved mission rejects further commands, even ones that would otherwise be no-ops
    expectRejected(core:fail("X", "late", tick()), Reasons.MISSION_RESOLVED)
    check(core)
end)

test("a resolved failure cannot later become a success", function()
    local core = newCore()
    expectTrue(core:fail("P", "bad", tick()).resolution ~= nil)
    expectRejected(put(core, "O", "S1", 1), Reasons.MISSION_RESOLVED)
    expectEqual(core:getResolution().outcome, "FAILED")
    check(core)
end)

test("the returned resolution is a copy", function()
    local core = newCore()
    fillAll(core, "P", 3, 1)
    fillAll(core, "W", 1, 1)
    local last = put(core, "X", "S1", 1)
    last.resolution.outcome = "FAILED"
    local stored = core:getResolution()
    expectEqual(stored.outcome, "COMPLETED")
    stored.reason = "tampered"
    expectEqual(core:getResolution().reason, "objectives_complete")
end)

-- snapshot ---------------------------------------------------------------------------------------------------------

local ALLOWED_ENTRY_KEYS = { id = true, title = true, description = true, importance = true, state = true, filled = true, required = true, slots = true }

test("the snapshot has the documented shape in definition order", function()
    local core = newCore()
    put(core, "P", "S2", 5)
    local snapshot = core:getSnapshot()
    expectEqual(snapshot.v, 1)
    expectEqual(snapshot.revision, 1)
    expectEqual(#snapshot.objectives, 4)
    local ids = {}
    for _, entry in ipairs(snapshot.objectives) do
        table.insert(ids, entry.id)
        for key in pairs(entry) do
            expectTrue(ALLOWED_ENTRY_KEYS[key] == true, "unexpected entry key " .. tostring(key))
        end
        for _, slot in ipairs(entry.slots) do
            local count = 0
            for key in pairs(slot) do
                count = count + 1
                expectTrue(key == "label" or key == "filled")
            end
            expectEqual(count, 2)
        end
    end
    expectEqual(table.concat(ids, ","), "P,W,X,O")
    local p = snapshot.objectives[1]
    expectEqual(p.title, "Title P")
    expectEqual(p.description, "Description P")
    expectEqual(p.importance, "REQUIRED")
    expectEqual(p.state, "IN_PROGRESS")
    expectEqual(p.filled, 1)
    expectEqual(p.required, 3)
    expectEqual(#p.slots, 3)
    expectFalse(p.slots[1].filled)
    expectTrue(p.slots[2].filled)
    expectEqual(p.slots[2].label, "P slot 2")
    expectEqual(snapshot.objectives[2].state, "LOCKED")
    expectEqual(snapshot.objectives[4].importance, "OPTIONAL")
end)

test("the snapshot never exposes point ids, user ids, reasons, timestamps or the resolution", function()
    local core = newCore()
    put(core, "P", "S1", 424242)
    core:fail("O", "secret_reason_token", tick())
    local function scan(value: any, path: string)
        if type(value) == "table" then
            for key, inner in pairs(value) do
                scan(key, path .. ".key")
                scan(inner, path .. "." .. tostring(key))
            end
        elseif type(value) == "string" then
            expectFalse(string.find(value, "_P1", 1, true) ~= nil and string.find(value, "slot", 1, true) == nil, "point id at " .. path)
            expectFalse(string.find(value, "secret_reason_token", 1, true) ~= nil, "reason at " .. path)
            expectFalse(string.find(value, "dependency_unreachable", 1, true) ~= nil, "reason at " .. path)
        elseif type(value) == "number" then
            expectFalse(value == 424242, "user id at " .. path)
        end
    end
    scan(core:getSnapshot(), "snapshot")
    local snapshot = core:getSnapshot()
    expectEqual(snapshot.resolution, nil)
end)

test("snapshots are fresh copies: mutating one never changes the store or the next snapshot", function()
    local core = newCore()
    put(core, "P", "S1", 1)
    local first = core:getSnapshot()
    first.revision = 999
    first.objectives[1].state = "COMPLETED"
    first.objectives[1].slots[3].filled = true
    first.objectives[1].title = "Tampered"
    table.remove(first.objectives, 2)
    local second = core:getSnapshot()
    expectEqual(second.revision, 1)
    expectEqual(#second.objectives, 4)
    expectEqual(second.objectives[1].state, "IN_PROGRESS")
    expectEqual(second.objectives[1].title, "Title P")
    expectFalse(second.objectives[1].slots[3].filled)
    expectEqual(core:getState("P"), "IN_PROGRESS")
    expectFalse(rawequal(first, second))
    expectFalse(rawequal(first.objectives[1], second.objectives[1]))
    check(core)
end)

test("hidden objectives are omitted until they leave LOCKED and stay visible afterwards", function()
    local core = newCore(planOf(def("A", REQ), def("SECRET", REQ, { allOf = { "A" } }, 1, true)))
    expectEqual(#core:getSnapshot().objectives, 1)
    expectEqual(core:getSnapshot().objectives[1].id, "A")
    put(core, "A", "S1", 1)
    local after = core:getSnapshot()
    expectEqual(#after.objectives, 2)
    expectEqual(after.objectives[2].id, "SECRET")
    expectEqual(after.objectives[2].state, "AVAILABLE")
    put(core, "SECRET", "S1", 1)
    expectEqual(#core:getSnapshot().objectives, 2)
    check(core)
end)

test("a hidden objective that is cancelled while still locked is never revealed", function()
    local core = newCore(planOf(def("R", REQ), def("OPT", OPT), def("SECRET", OPT, { allOf = { "OPT" } }, 1, true)))
    expectEqual(#core:getSnapshot().objectives, 2)
    expectTrue(core:cancel("OPT", "gone", tick()).ok)
    check(core)
    expectEqual(core:getState("SECRET"), "CANCELLED")
    local ids = {}
    for _, entry in ipairs(core:getSnapshot().objectives) do
        table.insert(ids, entry.id)
    end
    expectEqual(table.concat(ids, ","), "R,OPT")
end)

test("a hidden root objective is available at once and therefore visible", function()
    local core = newCore(planOf(def("A", REQ), def("HIDDEN_ROOT", OPT, nil, 1, true)))
    expectEqual(#core:getSnapshot().objectives, 2)
end)

-- attribution and queries ------------------------------------------------------------------------------------------

test("contributor attribution is stored per slot and never exposed through queries of other slots", function()
    local core = newCore()
    put(core, "P", "S1", 31)
    expectEqual(core:getContributor("P", "S1"), 31)
    expectEqual(core:getContributor("P", "S2"), nil)
    expectEqual(core:getContributor("P", "NOPE"), nil)
    expectEqual(core:getContributor("NOPE", "S1"), nil)
end)

-- determinism ------------------------------------------------------------------------------------------------------

test("the same command sequence always produces the same changes and snapshots", function()
    local function run(): { string }
        local core = newCore()
        local log = {}
        local function record(result: any)
            local parts = { tostring(result.ok), tostring(result.reason), tostring(result.changed) }
            for _, change in ipairs(result.changes) do
                table.insert(parts, change.kind .. ":" .. change.objectiveId .. ":" .. tostring(change.slotId) .. ":" .. tostring(change.to))
            end
            table.insert(log, table.concat(parts, ","))
            table.insert(log, snapshotKey(core))
        end
        record(put(core, "P", "S1", 1))
        record(put(core, "O", "S1", 2))
        record(put(core, "W", "S1", 2))
        record(put(core, "P", "S2", 2))
        record(put(core, "P", "S3", 3))
        record(core:cancel("O", "late", tick()))
        record(put(core, "W", "S1", 3))
        record(put(core, "X", "S1", 3))
        return log
    end
    local a, b = run(), run()
    expectEqual(#a, #b)
    for index = 1, #a do
        expectEqual(a[index], b[index])
    end
end)

-- invariants -------------------------------------------------------------------------------------------------------

test("a fresh store and every reachable state satisfy the invariants", function()
    local core = newCore()
    check(core)
    put(core, "P", "S1", 1)
    put(core, "O", "S1", 1)
    put(core, "P", "S2", 1)
    put(core, "P", "S3", 1)
    put(core, "W", "S1", 1)
    put(core, "X", "S1", 1)
    check(core)
end)

test("the invariant check detects corrupted state", function()
    local function corrupted(mutate: (any) -> ()): boolean
        local core: any = newCore()
        put(core, "P", "S1", 1)
        mutate(core)
        local ok = core:checkInvariants()
        return ok
    end
    expectTrue(corrupted(function() end), "baseline is healthy")
    expectFalse(corrupted(function(core: any) core._instances.P.state = "COMPLETED" end), "completed with unfilled slots")
    expectFalse(corrupted(function(core: any) core._instances.P.state = "AVAILABLE" end), "available with contributions")
    expectFalse(corrupted(function(core: any) core._instances.W.filledCount = 1 end), "locked with contributions")
    expectFalse(corrupted(function(core: any) core._instances.P.filledCount = 2 end), "fill count mismatch")
    expectFalse(corrupted(function(core: any) core._instances.P.slots.S1.filledBy = nil end), "filled slot without contributor")
    expectFalse(corrupted(function(core: any) core._instances.P.slots.S2.filledBy = 4 end), "unfilled slot with contributor")
    expectFalse(corrupted(function(core: any) core._instances.O.state = "FAILED" end), "terminal failure without reason")
    expectFalse(corrupted(function(core: any) core._instances.P.state = "CANCELLED"; core._instances.P.reason = "x" end), "required cancelled")
    expectFalse(corrupted(function(core: any) core._instances.W.state = "AVAILABLE" end), "started without satisfied dependencies")
    expectFalse(corrupted(function(core: any) core._instances.O.state = "LOCKED" end), "locked although dependencies are satisfied")
    expectFalse(corrupted(function(core: any) core._revision = -1 end), "negative revision")
    expectFalse(corrupted(function(core: any) core._instances.P.state = "BOGUS" end), "unknown state")
    expectFalse(corrupted(function(core: any) core._resolution = { outcome = "COMPLETED", reason = "objectives_complete" } end), "resolved while required objectives are open")
    expectFalse(corrupted(function(core: any)
        core._instances.P.state = "FAILED"
        core._instances.P.reason = "x"
    end), "failed required objective without a failed resolution")
end)

-- first-slice scenario ---------------------------------------------------------------------------------------------

test("a four-player run: contributions interleave, one player disconnects, the mission completes once", function()
    local core = newCore()
    expectTrue(put(core, "P", "S1", 1).ok)
    expectTrue(put(core, "O", "S1", 2).ok)
    expectTrue(put(core, "P", "S2", 3).ok)
    -- player 1 dies, player 3 disconnects: the service marks them ineligible; their progress stays
    expectRejected(put(core, "P", "S3", 1, false), Reasons.INELIGIBLE_CONTRIBUTOR)
    expectEqual(core:getFilledCount("P"), 2)
    expectTrue(put(core, "P", "S3", 4).ok)
    expectTrue(put(core, "W", "S1", 2).ok)
    local last = put(core, "X", "S1", 4)
    expectEqual(last.resolution.outcome, "COMPLETED")
    expectEqual(core:getRevision(), 6, "six applied commands; the rejected one did not count")
end)