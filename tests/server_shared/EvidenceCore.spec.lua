--!strict
local Harness = require("../Harness")
local EvidenceCatalog = require("../../src/server_shared/Evidence/EvidenceCatalog")
local EvidenceCore = require("../../src/server_shared/Evidence/EvidenceCore")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual
local Reasons = EvidenceCore.Reasons

local function definition(id: string, distinct: number, category: string?): any
    return {
        id = id,
        category = category or "TEST",
        title = "Title " .. id,
        description = "Description " .. id,
        confirmation = { distinctSources = distinct },
    }
end

local function planOf(...: any): any
    local plan, code, subject = EvidenceCatalog.compile({ version = 1, evidence = { ... } })
    if plan == nil then
        error("test catalog invalid: " .. tostring(code) .. " " .. tostring(subject))
    end
    return plan
end

-- A needs 2 distinct sources, B needs 1, C needs 3 (6 in total).
local function standardPlan(): any
    return planOf(definition("A", 2, "ENVIRONMENTAL"), definition("B", 1, "PHYSICAL"), definition("C", 3, "AUDIO"))
end

local clock = 100
local function tick(): number
    clock = clock + 1
    return clock
end

local function newCore(plan: any?): any
    return EvidenceCore.new(plan or standardPlan(), 0)
end

local function check(core: any)
    local ok, detail = core:checkInvariants()
    expectTrue(ok, "invariants: " .. tostring(detail))
end

local function observe(core: any, evidenceId: any, sourceId: any, userId: any, eligible: boolean?): any
    local result = core:observe(evidenceId, sourceId, userId, { eligible = eligible ~= false, now = tick() })
    check(core)
    return result
end

local function confirm(core: any, evidenceId: any, userId: any, eligible: boolean?): any
    local result = core:confirm(evidenceId, userId, { eligible = eligible ~= false, now = tick() })
    check(core)
    return result
end

local function expectRejected(result: any, reason: string, label: string?)
    expectFalse(result.ok, label)
    expectEqual(result.reason, reason, label)
    expectFalse(result.changed, label)
    expectEqual(#result.changes, 0, label)
end

local function ledgerKey(core: any): string
    local parts = { "rev=" .. core:getRevision() }
    for _, entry in ipairs(core:getEntries()) do
        local sources = {}
        for _, observation in ipairs(entry.observations) do
            table.insert(sources, observation.sourceId .. "@" .. observation.observerId)
        end
        table.insert(parts, entry.id .. ":" .. entry.state .. ":" .. table.concat(sources, ",") .. ":" .. tostring(entry.confirmedBy))
    end
    return table.concat(parts, "|")
end

-- construction and initial state -----------------------------------------------------------------------------------

test("new requires a compiled plan and a finite clock", function()
    Harness.expectError(function()
        EvidenceCore.new({}, 0)
    end, "empty table")
    Harness.expectError(function()
        EvidenceCore.new(nil, 0)
    end, "nil")
    Harness.expectError(function()
        EvidenceCore.new({ kind = "EvidenceCatalogPlan", order = {}, entries = {} }, 0)
    end, "empty plan")
    Harness.expectError(function()
        EvidenceCore.new({ kind = "EvidenceCatalogPlan", order = { "A" }, entries = {} }, 0)
    end, "inconsistent plan")
    Harness.expectError(function()
        EvidenceCore.new(standardPlan(), 0 / 0)
    end, "NaN clock")
    Harness.expectError(function()
        EvidenceCore.new(standardPlan(), math.huge)
    end, "infinite clock")
    Harness.expectError(function()
        EvidenceCore.new(standardPlan(), "0")
    end, "string clock")
end)

test("constants are explicit, frozen and describe the whole state machine", function()
    expectTrue(table.isfrozen(EvidenceCore.States))
    expectTrue(table.isfrozen(EvidenceCore.Transitions))
    expectTrue(table.isfrozen(EvidenceCore.Reasons))
    expectEqual(EvidenceCore.States.UNKNOWN, "UNKNOWN")
    expectEqual(EvidenceCore.States.OBSERVED, "OBSERVED")
    expectEqual(EvidenceCore.States.CONFIRMED, "CONFIRMED")
    expectEqual(#EvidenceCore.Transitions.UNKNOWN, 1)
    expectEqual(EvidenceCore.Transitions.UNKNOWN[1], "OBSERVED")
    expectEqual(#EvidenceCore.Transitions.OBSERVED, 1)
    expectEqual(EvidenceCore.Transitions.OBSERVED[1], "CONFIRMED")
    expectEqual(#EvidenceCore.Transitions.CONFIRMED, 0, "CONFIRMED is terminal")
    expectEqual(EvidenceCore.MaxSourcesPerEvidence, 16)
end)

test("initial state: every evidence is UNKNOWN, nothing is recorded, revision 0", function()
    local core = newCore()
    for _, id in ipairs({ "A", "B", "C" }) do
        expectEqual(core:getState(id), "UNKNOWN", id)
        local entry = core:getEntry(id)
        expectEqual(entry.sourceCount, 0)
        expectEqual(#entry.observations, 0)
        expectEqual(entry.confirmedBy, nil)
        expectEqual(entry.confirmedAt, nil)
    end
    expectEqual(core:getState("NOPE"), nil)
    expectEqual(core:getEntry("NOPE"), nil)
    expectEqual(core:getRevision(), 0)
    local progress = core:getProgress()
    expectEqual(progress.total, 3)
    expectEqual(progress.unknown, 3)
    expectEqual(progress.observed, 0)
    expectEqual(progress.confirmed, 0)
    expectEqual(progress.confirmedRatio, 0)
    expectEqual(progress.corroborationRatio, 0)
    check(core)
end)

test("entries keep the catalog order and carry the catalog data", function()
    local entries = newCore():getEntries()
    expectEqual(#entries, 3)
    expectEqual(entries[1].id .. entries[2].id .. entries[3].id, "ABC")
    expectEqual(entries[1].category, "ENVIRONMENTAL")
    expectEqual(entries[1].required, 2)
    expectEqual(entries[2].required, 1)
    expectEqual(entries[3].required, 3)
end)

-- valid transitions -------------------------------------------------------------------------------------------------

test("the first observation moves UNKNOWN to OBSERVED and records who saw what", function()
    local core = newCore()
    local result = observe(core, "A", "KITCHEN", 11)
    expectTrue(result.ok)
    expectTrue(result.changed)
    expectEqual(result.reason, nil)
    expectEqual(#result.changes, 2)
    expectEqual(result.changes[1].kind, "OBSERVATION")
    expectEqual(result.changes[1].evidenceId, "A")
    expectEqual(result.changes[1].sourceId, "KITCHEN")
    expectEqual(result.changes[1].userId, 11)
    expectEqual(result.changes[2].kind, "STATE")
    expectEqual(result.changes[2].from, "UNKNOWN")
    expectEqual(result.changes[2].to, "OBSERVED")
    expectEqual(core:getState("A"), "OBSERVED")
    expectEqual(core:getRevision(), 1)
    local entry = core:getEntry("A")
    expectEqual(entry.sourceCount, 1)
    expectEqual(entry.observations[1].sourceId, "KITCHEN")
    expectEqual(entry.observations[1].observerId, 11)
    expectTrue(type(entry.observations[1].at) == "number")
end)

test("a further distinct source adds corroboration without changing the state", function()
    local core = newCore()
    observe(core, "A", "KITCHEN", 11)
    local result = observe(core, "A", "CELLAR", 12)
    expectTrue(result.ok)
    expectEqual(#result.changes, 1)
    expectEqual(result.changes[1].kind, "OBSERVATION")
    expectEqual(core:getState("A"), "OBSERVED")
    expectEqual(core:getEntry("A").sourceCount, 2)
    expectEqual(core:getRevision(), 2)
end)

test("confirmation succeeds once enough distinct sources agree", function()
    local core = newCore()
    observe(core, "A", "KITCHEN", 11)
    observe(core, "A", "CELLAR", 12)
    local result = confirm(core, "A", 13)
    expectTrue(result.ok)
    expectTrue(result.changed)
    expectEqual(#result.changes, 1)
    expectEqual(result.changes[1].kind, "STATE")
    expectEqual(result.changes[1].from, "OBSERVED")
    expectEqual(result.changes[1].to, "CONFIRMED")
    expectEqual(result.changes[1].userId, 13)
    expectEqual(core:getState("A"), "CONFIRMED")
    local entry = core:getEntry("A")
    expectEqual(entry.confirmedBy, 13)
    expectTrue(type(entry.confirmedAt) == "number")
    expectEqual(core:getRevision(), 3)
end)

test("single-source evidence can be confirmed after one observation", function()
    local core = newCore()
    observe(core, "B", "HALL", 5)
    expectTrue(confirm(core, "B", 5).ok)
    expectEqual(core:getState("B"), "CONFIRMED")
end)

test("a solo player can observe and confirm everything alone", function()
    local core = newCore()
    for _, id in ipairs({ "A", "B", "C" }) do
        local needed = core:getEntry(id).required
        for index = 1, needed do
            expectTrue(observe(core, id, "SRC_" .. index, 1).ok)
        end
        expectTrue(confirm(core, id, 1).ok)
    end
    expectEqual(core:getProgress().confirmed, 3)
end)

-- invalid transitions ------------------------------------------------------------------------------------------------

test("confirming evidence nobody has observed is rejected", function()
    local core = newCore()
    expectRejected(confirm(core, "A", 1), Reasons.NOT_OBSERVED)
    expectEqual(core:getState("A"), "UNKNOWN")
    expectEqual(core:getRevision(), 0)
end)

test("confirming without enough distinct sources is rejected", function()
    local core = newCore()
    observe(core, "A", "KITCHEN", 1)
    expectRejected(confirm(core, "A", 1), Reasons.INSUFFICIENT_OBSERVATIONS)
    expectEqual(core:getState("A"), "OBSERVED")
    observe(core, "C", "S1", 1)
    observe(core, "C", "S2", 1)
    expectRejected(confirm(core, "C", 1), Reasons.INSUFFICIENT_OBSERVATIONS, "2 of 3")
    expectEqual(core:getRevision(), 3, "only the three observations were applied")
end)

test("repeating the same source never satisfies the confirmation requirement", function()
    local core = newCore()
    for userId = 1, 5 do
        observe(core, "A", "KITCHEN", userId)
    end
    expectEqual(core:getEntry("A").sourceCount, 1)
    expectRejected(confirm(core, "A", 1), Reasons.INSUFFICIENT_OBSERVATIONS)
end)

test("CONFIRMED is terminal: no further observation, duplicate source or confirmation changes anything", function()
    local core = newCore()
    observe(core, "B", "HALL", 1)
    confirm(core, "B", 1)
    local before = ledgerKey(core)
    expectRejected(observe(core, "B", "CELLAR", 2), Reasons.ALREADY_CONFIRMED, "new source")
    expectRejected(observe(core, "B", "HALL", 2), Reasons.ALREADY_CONFIRMED, "same source")
    expectRejected(confirm(core, "B", 2), Reasons.ALREADY_CONFIRMED, "duplicate confirmation")
    expectRejected(confirm(core, "B", 1), Reasons.ALREADY_CONFIRMED, "same confirmer")
    expectEqual(ledgerKey(core), before)
    expectEqual(core:getEntry("B").confirmedBy, 1, "the first confirmer keeps the attribution")
end)

test("states only ever follow the explicit transition table and never move backwards", function()
    local rank: { [string]: number } = { UNKNOWN = 1, OBSERVED = 2, CONFIRMED = 3 }
    local allowed: { [string]: { [string]: boolean } } = {}
    for from, targets in pairs(EvidenceCore.Transitions) do
        allowed[from] = {}
        for _, target in ipairs(targets) do
            allowed[from][target] = true
        end
    end
    -- a deterministic pseudo-random command stream (LCG), no clock and no Roblox RNG
    local seed = 12345
    local function nextInt(limit: number): number
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % limit + 1
    end
    local ids = { "A", "B", "C", "NOPE" }
    local sources = { "S1", "S2", "S3", "S4", "bad", "S5" }
    local core = newCore()
    local lastProgress = core:getProgress()
    for _ = 1, 400 do
        local evidenceId = ids[nextInt(#ids)]
        local before = core:getState(evidenceId)
        local result: any = nil
        if nextInt(3) == 1 then
            result = confirm(core, evidenceId, nextInt(4))
        else
            result = observe(core, evidenceId, sources[nextInt(#sources)], nextInt(4), nextInt(5) ~= 1)
        end
        local after = core:getState(evidenceId)
        if before ~= nil and after ~= nil and before ~= after then
            expectTrue(allowed[before][after] == true, before .. " -> " .. after .. " is not in the transition table")
        end
        if before ~= nil and after ~= nil then
            expectTrue(rank[after] >= rank[before], "state moved backwards")
        end
        if not result.ok then
            expectFalse(result.changed)
        end
        local progress = core:getProgress()
        expectTrue(progress.confirmed >= lastProgress.confirmed)
        expectTrue(progress.corroborationRatio >= lastProgress.corroborationRatio - 1e-12, "progress never decreases")
        lastProgress = progress
    end
end)

-- duplicates and progress -------------------------------------------------------------------------------------------

test("duplicate observations are rejected without any change", function()
    local core = newCore()
    observe(core, "A", "KITCHEN", 1)
    local before = ledgerKey(core)
    local progress = core:getProgress()
    expectRejected(observe(core, "A", "KITCHEN", 1), Reasons.DUPLICATE_OBSERVATION, "same player")
    expectRejected(observe(core, "A", "KITCHEN", 2), Reasons.DUPLICATE_OBSERVATION, "another player")
    expectEqual(ledgerKey(core), before)
    expectEqual(core:getEntry("A").observations[1].observerId, 1, "the first observer keeps the attribution")
    expectEqual(core:getProgress().corroborationRatio, progress.corroborationRatio)
end)

test("the same source may corroborate different evidence", function()
    local core = newCore()
    expectTrue(observe(core, "A", "KITCHEN", 1).ok)
    expectTrue(observe(core, "B", "KITCHEN", 1).ok)
    expectEqual(core:getState("A"), "OBSERVED")
    expectEqual(core:getState("B"), "OBSERVED")
end)

test("investigation progress counts states and capped distinct corroboration", function()
    local core = newCore() -- required: A 2, B 1, C 3, total 6
    observe(core, "A", "S1", 1)
    local p = core:getProgress()
    expectEqual(p.unknown, 2)
    expectEqual(p.observed, 1)
    expectEqual(p.confirmed, 0)
    expectEqual(p.confirmedRatio, 0)
    expectEqual(p.corroborationRatio, 1 / 6)

    observe(core, "C", "S1", 2)
    observe(core, "C", "S2", 2)
    p = core:getProgress()
    expectEqual(p.corroborationRatio, 3 / 6, "A 1 of 2 plus C 2 of 3")

    observe(core, "B", "S9", 3)
    confirm(core, "B", 3)
    p = core:getProgress()
    expectEqual(p.confirmed, 1)
    expectEqual(p.confirmedRatio, 1 / 3)
    expectEqual(p.corroborationRatio, 4 / 6)

    -- observations beyond the requirement add nothing to corroboration
    observe(core, "A", "S2", 1)
    local atRequirement = core:getProgress().corroborationRatio
    expectEqual(atRequirement, 5 / 6, "A now has its 2 of 2")
    observe(core, "A", "S3", 1)
    observe(core, "A", "S4", 1)
    p = core:getProgress()
    expectEqual(p.corroborationRatio, atRequirement, "extra sources beyond the requirement do not raise progress")
    observe(core, "C", "S3", 1)
    expectEqual(core:getProgress().corroborationRatio, 1)
    expectEqual(core:getProgress().confirmedRatio, 1 / 3, "corroborated is not confirmed")
    check(core)
end)

test("progress counts always add up and ratios stay within [0, 1]", function()
    local core = newCore()
    local function verify()
        local p = core:getProgress()
        expectEqual(p.unknown + p.observed + p.confirmed, p.total)
        expectTrue(p.confirmedRatio >= 0 and p.confirmedRatio <= 1)
        expectTrue(p.corroborationRatio >= 0 and p.corroborationRatio <= 1)
    end
    verify()
    for _, id in ipairs({ "A", "B", "C" }) do
        for index = 1, 5 do
            observe(core, id, "SRC_" .. index, 1)
            verify()
        end
        confirm(core, id, 1)
        verify()
    end
    expectEqual(core:getProgress().confirmedRatio, 1)
end)

test("progress is shared: it depends on the ledger, never on who contributed", function()
    local function run(userFor: (number) -> number): any
        local core = newCore()
        local step = 0
        local function next(): number
            step = step + 1
            return userFor(step)
        end
        observe(core, "A", "S1", next())
        observe(core, "A", "S2", next())
        observe(core, "C", "S1", next())
        observe(core, "B", "S1", next())
        confirm(core, "A", next())
        return core:getProgress()
    end
    local solo = run(function(): number
        return 1
    end)
    local squad = run(function(step: number): number
        return step
    end)
    expectEqual(solo.confirmed, squad.confirmed)
    expectEqual(solo.observed, squad.observed)
    expectEqual(solo.unknown, squad.unknown)
    expectEqual(solo.corroborationRatio, squad.corroborationRatio)
    expectEqual(solo.confirmedRatio, squad.confirmedRatio)
end)

test("several players contribute different sources to the same evidence", function()
    local core = newCore()
    observe(core, "C", "S1", 21)
    observe(core, "C", "S2", 22)
    observe(core, "C", "S3", 23)
    expectTrue(confirm(core, "C", 24).ok)
    local entry = core:getEntry("C")
    expectEqual(entry.observations[1].observerId, 21)
    expectEqual(entry.observations[2].observerId, 22)
    expectEqual(entry.observations[3].observerId, 23)
    expectEqual(entry.confirmedBy, 24)
end)

test("the number of tracked sources is bounded", function()
    local core = newCore(planOf(definition("BIG", 8)))
    for index = 1, 16 do
        expectTrue(observe(core, "BIG", "SRC_" .. index, 1).ok, "source " .. index)
    end
    expectRejected(observe(core, "BIG", "SRC_17", 1), Reasons.SOURCE_LIMIT)
    expectEqual(core:getEntry("BIG").sourceCount, 16)
    expectTrue(confirm(core, "BIG", 1).ok)
end)

-- invalid input ------------------------------------------------------------------------------------------------------

test("invalid contexts are rejected", function()
    local core = newCore()
    local before = ledgerKey(core)
    for _, bad in ipairs({ "x", 5 }) do
        expectRejected(core:observe("A", "S1", 1, bad), Reasons.INVALID_CONTEXT)
        expectRejected(core:confirm("A", 1, bad), Reasons.INVALID_CONTEXT)
    end
    expectRejected(core:observe("A", "S1", 1, nil), Reasons.INVALID_CONTEXT)
    expectRejected(core:observe("A", "S1", 1, { now = 1 }), Reasons.INVALID_CONTEXT)
    expectRejected(core:observe("A", "S1", 1, { eligible = 1, now = 1 }), Reasons.INVALID_CONTEXT)
    expectRejected(core:observe("A", "S1", 1, { eligible = true }), Reasons.INVALID_CONTEXT)
    expectRejected(core:observe("A", "S1", 1, { eligible = true, now = "1" }), Reasons.INVALID_CONTEXT)
    expectRejected(core:observe("A", "S1", 1, { eligible = true, now = 0 / 0 }), Reasons.INVALID_CONTEXT)
    expectRejected(core:observe("A", "S1", 1, { eligible = true, now = math.huge }), Reasons.INVALID_CONTEXT)
    expectRejected(core:observe("A", "S1", 1, { eligible = true, now = -math.huge }), Reasons.INVALID_CONTEXT)
    expectEqual(ledgerKey(core), before)
end)

test("invalid contributors are rejected for both commands", function()
    local core = newCore()
    local before = ledgerKey(core)
    for _, bad in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, 9007199254740992 }) do
        expectRejected(observe(core, "A", "S1", bad), Reasons.INVALID_CONTRIBUTOR, "observe " .. tostring(bad))
        expectRejected(confirm(core, "A", bad), Reasons.INVALID_CONTRIBUTOR, "confirm " .. tostring(bad))
    end
    expectRejected(observe(core, "A", "S1", "1"), Reasons.INVALID_CONTRIBUTOR)
    expectRejected(observe(core, "A", "S1", nil), Reasons.INVALID_CONTRIBUTOR)
    expectRejected(observe(core, "A", "S1", {}), Reasons.INVALID_CONTRIBUTOR)
    expectEqual(ledgerKey(core), before)
    expectTrue(observe(core, "A", "S1", 9007199254740991).ok, "the maximum user id is accepted")
end)

test("an ineligible contributor changes nothing", function()
    local core = newCore()
    expectRejected(observe(core, "A", "S1", 1, false), Reasons.INELIGIBLE_CONTRIBUTOR)
    expectEqual(core:getState("A"), "UNKNOWN")
    observe(core, "B", "S1", 1)
    expectRejected(confirm(core, "B", 1, false), Reasons.INELIGIBLE_CONTRIBUTOR)
    expectEqual(core:getState("B"), "OBSERVED")
    expectEqual(core:getRevision(), 1)
end)

test("unknown and malformed evidence ids are rejected", function()
    local core = newCore()
    local before = ledgerKey(core)
    expectRejected(observe(core, "NOPE", "S1", 1), Reasons.UNKNOWN_EVIDENCE)
    expectRejected(observe(core, "a", "S1", 1), Reasons.UNKNOWN_EVIDENCE)
    expectRejected(observe(core, 5, "S1", 1), Reasons.INVALID_EVIDENCE_ID)
    expectRejected(observe(core, nil, "S1", 1), Reasons.INVALID_EVIDENCE_ID)
    expectRejected(observe(core, {}, "S1", 1), Reasons.INVALID_EVIDENCE_ID)
    expectRejected(confirm(core, "NOPE", 1), Reasons.UNKNOWN_EVIDENCE)
    expectRejected(confirm(core, 5, 1), Reasons.INVALID_EVIDENCE_ID)
    expectEqual(ledgerKey(core), before)
end)

test("invalid source ids are rejected", function()
    local core = newCore()
    for _, bad in ipairs({ "", "lower", "1ABC", "HAS SPACE", string.rep("A", 33), "A-B" }) do
        expectRejected(observe(core, "A", bad, 1), Reasons.INVALID_SOURCE_ID, bad)
    end
    expectRejected(observe(core, "A", 5, 1), Reasons.INVALID_SOURCE_ID)
    expectRejected(observe(core, "A", nil, 1), Reasons.INVALID_SOURCE_ID)
    expectRejected(observe(core, "A", {}, 1), Reasons.INVALID_SOURCE_ID)
    expectEqual(core:getRevision(), 0)
    expectTrue(observe(core, "A", string.rep("A", 32), 1).ok)
end)

test("rejection precedence is fixed", function()
    local core = newCore()
    expectRejected(core:observe("NOPE", "bad", 0, nil), Reasons.INVALID_CONTEXT)
    expectRejected(core:observe("NOPE", "bad", 0, { eligible = false, now = 1 }), Reasons.INVALID_CONTRIBUTOR)
    expectRejected(core:observe("NOPE", "bad", 1, { eligible = false, now = 1 }), Reasons.INELIGIBLE_CONTRIBUTOR)
    expectRejected(core:observe(5, "bad", 1, { eligible = true, now = 1 }), Reasons.INVALID_EVIDENCE_ID)
    expectRejected(core:observe("NOPE", "bad", 1, { eligible = true, now = 1 }), Reasons.UNKNOWN_EVIDENCE)
    expectRejected(core:observe("A", "bad", 1, { eligible = true, now = 1 }), Reasons.INVALID_SOURCE_ID)
    observe(core, "B", "S1", 1)
    confirm(core, "B", 1)
    expectRejected(core:observe("B", "S1", 1, { eligible = true, now = 1 }), Reasons.ALREADY_CONFIRMED, "confirmed beats duplicate")
end)

-- atomicity, revision, copies ---------------------------------------------------------------------------------------

test("a context that raises while being read aborts before any mutation", function()
    local core = newCore()
    observe(core, "A", "S1", 1)
    local before = ledgerKey(core)
    local hostile = setmetatable({}, {
        __index = function()
            error("boom")
        end,
    })
    expectFalse(pcall(function()
        core:observe("A", "S2", 2, hostile)
    end))
    expectFalse(pcall(function()
        core:confirm("A", 2, hostile)
    end))
    expectEqual(ledgerKey(core), before)
    check(core)
    expectTrue(observe(core, "A", "S2", 2).ok, "the store is still usable")
end)

test("the revision rises by exactly one per applied command and never on rejections", function()
    local core = newCore()
    local revision = core:getRevision()
    local function expectBump(label: string)
        expectEqual(core:getRevision(), revision + 1, label)
        revision = core:getRevision()
    end
    local function expectSame(label: string)
        expectEqual(core:getRevision(), revision, label)
    end
    observe(core, "A", "S1", 1)
    expectBump("first observation (two changes, one revision)")
    observe(core, "A", "S1", 1)
    expectSame("duplicate")
    confirm(core, "A", 1)
    expectSame("insufficient")
    observe(core, "A", "S2", 1)
    expectBump("second source")
    confirm(core, "A", 1)
    expectBump("confirmation")
    confirm(core, "A", 1)
    expectSame("duplicate confirmation")
    observe(core, "A", "S3", 1, false)
    expectSame("ineligible")
end)

test("entries and progress are copies: mutating them never changes the store", function()
    local core = newCore()
    observe(core, "A", "S1", 1)
    local entry = core:getEntry("A")
    entry.state = "CONFIRMED"
    entry.sourceCount = 99
    entry.observations[1].sourceId = "TAMPERED"
    table.remove(entry.observations)
    local list = core:getEntries()
    list[1].state = "CONFIRMED"
    table.remove(list)
    local progress = core:getProgress()
    progress.confirmed = 99
    check(core)
    expectEqual(core:getState("A"), "OBSERVED")
    expectEqual(core:getEntry("A").sourceCount, 1)
    expectEqual(core:getEntry("A").observations[1].sourceId, "S1")
    expectEqual(#core:getEntries(), 3)
    expectEqual(core:getProgress().confirmed, 0)
end)

test("the plan is not shared with the caller's catalog", function()
    local content = { version = 1, evidence = { definition("A", 1) } }
    local plan: any = EvidenceCatalog.compile(content)
    local core: any = EvidenceCore.new(plan, 0)
    content.evidence[1].confirmation.distinctSources = 8
    content.evidence[1].category = "CHANGED"
    expectEqual(core:getEntry("A").required, 1)
    expectEqual(core:getEntry("A").category, "TEST")
end)

-- determinism --------------------------------------------------------------------------------------------------------

test("the same command sequence always produces the same changes and ledger", function()
    local function run(): { string }
        local core = newCore()
        local log = {}
        local function record(result: any)
            local parts = { tostring(result.ok), tostring(result.reason), tostring(result.changed) }
            for _, change in ipairs(result.changes) do
                table.insert(parts, change.kind .. ":" .. change.evidenceId .. ":" .. tostring(change.sourceId) .. ":" .. tostring(change.to))
            end
            table.insert(log, table.concat(parts, ","))
            table.insert(log, ledgerKey(core))
        end
        record(observe(core, "A", "S1", 1))
        record(observe(core, "B", "S1", 2))
        record(observe(core, "A", "S1", 3))
        record(confirm(core, "A", 1))
        record(observe(core, "A", "S2", 3))
        record(confirm(core, "A", 2))
        record(confirm(core, "B", 2))
        record(observe(core, "C", "S3", 1))
        return log
    end
    local a, b = run(), run()
    expectEqual(#a, #b)
    for index = 1, #a do
        expectEqual(a[index], b[index])
    end
end)

test("the core is mission-agnostic: arbitrary ids and categories behave identically", function()
    local core = newCore(planOf(definition("SOMETHING_ELSE", 1, "ANY_CATEGORY"), definition("ANOTHER_ONE", 2, "ANY_CATEGORY")))
    expectTrue(observe(core, "SOMETHING_ELSE", "SITE_ONE", 1).ok)
    expectTrue(confirm(core, "SOMETHING_ELSE", 1).ok)
    expectEqual(core:getProgress().confirmed, 1)
    expectEqual(core:getProgress().total, 2)
end)

-- invariants ---------------------------------------------------------------------------------------------------------

test("the invariant check detects corrupted state", function()
    local function corrupted(mutate: (any) -> ()): boolean
        local core: any = newCore()
        observe(core, "A", "S1", 1)
        observe(core, "A", "S2", 1)
        observe(core, "B", "S1", 1)
        confirm(core, "B", 1)
        mutate(core)
        local ok = core:checkInvariants()
        return ok
    end
    expectTrue(corrupted(function() end), "baseline is healthy")
    expectFalse(corrupted(function(core: any) core._entries.C.state = "OBSERVED" end), "OBSERVED without an observation")
    expectFalse(corrupted(function(core: any) core._entries.A.state = "UNKNOWN" end), "UNKNOWN with observations")
    expectFalse(corrupted(function(core: any) core._entries.A.state = "CONFIRMED" end), "CONFIRMED without a confirmer")
    expectFalse(corrupted(function(core: any)
        core._entries.A.state = "CONFIRMED"
        core._entries.A.confirmedBy = 1
        core._entries.A.confirmedAt = 5
        table.remove(core._entries.A.observations)
        core._entries.A.sourceSet.S2 = nil
    end), "CONFIRMED with too few sources")
    expectFalse(corrupted(function(core: any) core._entries.A.state = "BOGUS" end), "unknown state")
    expectFalse(corrupted(function(core: any) core._entries.A.observations[2].sourceId = "S1" end), "the same source twice")
    expectFalse(corrupted(function(core: any) core._entries.A.sourceSet.S3 = true end), "source set with an unrecorded source")
    expectFalse(corrupted(function(core: any) core._entries.A.observations[1].observerId = 0 end), "malformed observation")
    expectFalse(corrupted(function(core: any) core._entries.A.confirmedBy = 4 end), "confirmation data on unconfirmed evidence")
    expectFalse(corrupted(function(core: any) core._revision = -1 end), "negative revision")
    expectFalse(corrupted(function(core: any) core._entries.B.confirmedBy = nil end), "confirmed without a confirmer")
    expectFalse(corrupted(function(core: any) core._entries.C = nil end), "missing entry")
end)
