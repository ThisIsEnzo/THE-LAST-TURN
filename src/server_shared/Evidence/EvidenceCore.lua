--!strict
-- Pure evidence runtime store and state machine (TTL-11A, docs/TTL-11A_EVIDENCE_CORE.md).
-- No Roblox services, Instances, Players, remotes, timers, yielding or other side effects: time is injected as `now`
-- (seconds), contributors are plain `UserId` numbers (never Player references) and the Core never calls out. State lives
-- here and nowhere else; callers receive copies only. Construction takes a plan from `EvidenceCatalog.compile` instead of
-- requiring the catalog, because pure modules in this repository are dependency-free and receive collaborators by injection.
--
-- Model: every evidence definition of the mission has one shared, team-owned entry (one mission server = one team = one
-- ledger). An entry moves through three states and no other:
--
--     UNKNOWN --observe--> OBSERVED --confirm--> CONFIRMED          (CONFIRMED is terminal)
--
--   * `observe(evidenceId, sourceId, observerId, context)` records one sighting from one authored source. The first accepted
--     observation makes the entry OBSERVED; later ones from OTHER sources add corroboration. A source counts once per
--     evidence however many players or repeats report it, so duplicates can never inflate progress.
--   * `confirm(evidenceId, confirmerId, context)` is the explicit verification step. It requires state OBSERVED and at
--     least `distinctSources` distinct sources (the definition's confirmation requirement), otherwise it is rejected and
--     nothing changes. A single, possibly false, signal can therefore never confirm evidence alone.
--
-- Eligibility (alive, connected, on the roster, allowed to investigate) is decided by the caller and passed in `context`;
-- attribution (`observerId`, `confirmerId`) is stored for credit and never gates anything. Progress is shared: it depends
-- only on the ledger, never on who contributed. The Core does not know about entities, equipment, objectives, maps or UI.
--
-- Every mutation is atomic: all validation happens first, then plain assignments. A rejected command changes nothing and
-- never advances the revision. The revision rises by exactly one per APPLIED command.

local EvidenceCore = {}

EvidenceCore.States = table.freeze({
    UNKNOWN = "UNKNOWN",
    OBSERVED = "OBSERVED",
    CONFIRMED = "CONFIRMED",
})

-- The complete, explicit transition table: state -> the states reachable from it.
EvidenceCore.Transitions = table.freeze({
    UNKNOWN = table.freeze({ "OBSERVED" }),
    OBSERVED = table.freeze({ "CONFIRMED" }),
    CONFIRMED = table.freeze({}),
})

-- Rejection reasons are for server logs; nothing is ever answered to a client.
EvidenceCore.Reasons = table.freeze({
    INVALID_CONTEXT = "invalid_context", -- context is not a table with a finite `now` and a boolean `eligible`
    INVALID_CONTRIBUTOR = "invalid_contributor", -- observer/confirmer is not an integer UserId in [1, MaxUserId]
    INELIGIBLE_CONTRIBUTOR = "ineligible_contributor", -- the caller reports the contributor may not investigate
    INVALID_EVIDENCE_ID = "invalid_evidence_id", -- not a string
    UNKNOWN_EVIDENCE = "unknown_evidence", -- a string that is not in the catalog
    INVALID_SOURCE_ID = "invalid_source_id", -- not a content-style token
    ALREADY_CONFIRMED = "already_confirmed", -- CONFIRMED is terminal: no further observation or confirmation
    DUPLICATE_OBSERVATION = "duplicate_observation", -- this source already observed this evidence
    SOURCE_LIMIT = "source_limit", -- the entry already tracks the maximum number of sources
    NOT_OBSERVED = "not_observed", -- confirm on UNKNOWN evidence
    INSUFFICIENT_OBSERVATIONS = "insufficient_observations", -- fewer distinct sources than the definition requires
})


EvidenceCore.MaxUserId = 9007199254740991
-- The most distinct sources one entry tracks (twice the largest confirmation requirement a catalog may ask for), so memory
-- and payloads stay bounded however often clues are reported.
EvidenceCore.MaxSourcesPerEvidence = 16

local States = EvidenceCore.States
local Reasons = EvidenceCore.Reasons

export type Change = {
    kind: string, -- "OBSERVATION" | "STATE"
    evidenceId: string,
    sourceId: string?,
    userId: number?, -- the observer, or the confirmer on a STATE change to CONFIRMED
    from: string?,
    to: string?,
}

export type CommandResult = {
    ok: boolean,
    reason: string?, -- rejection reason when `ok` is false
    changed: boolean,
    changes: { Change }, -- ordered: the observation first, then the state change
}

export type Context = { eligible: boolean, now: number }

export type Observation = { sourceId: string, observerId: number, at: number }

export type Entry = {
    id: string,
    category: string,
    state: string,
    required: number, -- distinct sources needed to confirm
    sourceCount: number,
    observations: { Observation }, -- in the order they were accepted
    confirmedBy: number?,
    confirmedAt: number?,
}

export type Progress = {
    total: number,
    unknown: number,
    observed: number,
    confirmed: number,
    confirmedRatio: number, -- confirmed / total
    corroborationRatio: number, -- sum(min(sourceCount, required)) / sum(required): partial credit, capped, duplicate-proof
}

type InstanceData = {
    state: string,
    observations: { Observation },
    sourceSet: { [string]: boolean },
    confirmedBy: number?,
    confirmedAt: number?,
    changedAt: number,
}

type StoreData = {
    _plan: any,
    _entries: { [string]: InstanceData },
    _revision: number,
}

local Store = {}
Store.__index = Store

export type Store = typeof(setmetatable({} :: StoreData, Store))

local function isFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isUserId(value: any): boolean
    return type(value) == "number" and value >= 1 and value <= EvidenceCore.MaxUserId and value % 1 == 0
end

local function isToken(value: any): boolean
    return type(value) == "string" and #value >= 1 and #value <= 32 and string.match(value, "^[A-Z][A-Z0-9_]*$") ~= nil
end

local function isPlan(plan: any): boolean
    return type(plan) == "table"
        and plan.kind == "EvidenceCatalogPlan"
        and type(plan.order) == "table"
        and type(plan.entries) == "table"
        and #plan.order >= 1
end

local function rejected(reason: string): CommandResult
    return { ok = false, reason = reason, changed = false, changes = {} }
end

-- `plan` comes from EvidenceCatalog.compile. Raises on an invalid plan or clock (callers compile first). Every entry
-- starts UNKNOWN; the revision starts at 0.
function EvidenceCore.new(plan: any, now: any): Store
    if not isPlan(plan) then
        error("EvidenceCore.new: a compiled plan (EvidenceCatalog.compile) is required", 2)
    end
    if not isFiniteNumber(now) then
        error("EvidenceCore.new: now must be a finite number", 2)
    end
    local entries: { [string]: InstanceData } = {}
    for _, id in ipairs(plan.order) do
        if plan.entries[id] == nil then
            error("EvidenceCore.new: the plan is inconsistent", 2)
        end
        entries[id] = { state = States.UNKNOWN, observations = {}, sourceSet = {}, confirmedBy = nil, confirmedAt = nil, changedAt = now }
    end
    return setmetatable({ _plan = plan, _entries = entries, _revision = 0 }, Store)
end

-- Validates the part shared by both commands. Returns (instance, rejection reason).
local function checkCommon(self: any, evidenceId: any, contributorId: any, context: any): (InstanceData?, string?)
    if type(context) ~= "table" or type(context.eligible) ~= "boolean" or not isFiniteNumber(context.now) then
        return nil, Reasons.INVALID_CONTEXT
    end
    if not isUserId(contributorId) then
        return nil, Reasons.INVALID_CONTRIBUTOR
    end
    if not context.eligible then
        return nil, Reasons.INELIGIBLE_CONTRIBUTOR
    end
    if type(evidenceId) ~= "string" then
        return nil, Reasons.INVALID_EVIDENCE_ID
    end
    local instance = self._entries[evidenceId]
    if instance == nil then
        return nil, Reasons.UNKNOWN_EVIDENCE
    end
    return instance, nil
end

-- Records one sighting of `evidenceId` from the authored source `sourceId`. `context` is `{ eligible, now }`. Precedence of
-- rejections is fixed: context, contributor, eligibility, evidence id, evidence, source id, confirmed, duplicate, source
-- limit. UNKNOWN -> OBSERVED on the first accepted observation; later ones only add corroboration.
function Store.observe(self: Store, evidenceId: any, sourceId: any, observerId: any, context: any): CommandResult
    local data: any = self
    local instance, reason = checkCommon(data, evidenceId, observerId, context)
    if instance == nil then
        return rejected(reason :: string)
    end
    if not isToken(sourceId) then
        return rejected(Reasons.INVALID_SOURCE_ID)
    end
    if instance.state == States.CONFIRMED then
        return rejected(Reasons.ALREADY_CONFIRMED)
    end
    if instance.sourceSet[sourceId] then
        return rejected(Reasons.DUPLICATE_OBSERVATION)
    end
    if #instance.observations >= EvidenceCore.MaxSourcesPerEvidence then
        return rejected(Reasons.SOURCE_LIMIT)
    end

    local changes: { Change } = { { kind = "OBSERVATION", evidenceId = evidenceId, sourceId = sourceId, userId = observerId } }
    local becomesObserved = instance.state == States.UNKNOWN
    if becomesObserved then
        table.insert(changes, { kind = "STATE", evidenceId = evidenceId, from = States.UNKNOWN, to = States.OBSERVED })
    end

    -- Commit: plain assignments only.
    local now: number = context.now
    table.insert(instance.observations, { sourceId = sourceId, observerId = observerId, at = now })
    instance.sourceSet[sourceId] = true
    if becomesObserved then
        instance.state = States.OBSERVED
    end
    instance.changedAt = now
    data._revision = data._revision + 1
    return { ok = true, reason = nil, changed = true, changes = changes }
end

-- OBSERVED -> CONFIRMED, only when at least `distinctSources` distinct sources observed the evidence.
function Store.confirm(self: Store, evidenceId: any, confirmerId: any, context: any): CommandResult
    local data: any = self
    local instance, reason = checkCommon(data, evidenceId, confirmerId, context)
    if instance == nil then
        return rejected(reason :: string)
    end
    if instance.state == States.CONFIRMED then
        return rejected(Reasons.ALREADY_CONFIRMED)
    end
    if instance.state == States.UNKNOWN then
        return rejected(Reasons.NOT_OBSERVED)
    end
    local required: number = data._plan.entries[evidenceId].distinctSources
    if #instance.observations < required then
        return rejected(Reasons.INSUFFICIENT_OBSERVATIONS)
    end

    local now: number = context.now
    instance.state = States.CONFIRMED
    instance.confirmedBy = confirmerId
    instance.confirmedAt = now
    instance.changedAt = now
    data._revision = data._revision + 1
    return {
        ok = true,
        reason = nil,
        changed = true,
        changes = { { kind = "STATE", evidenceId = evidenceId, from = States.OBSERVED, to = States.CONFIRMED, userId = confirmerId } },
    }
end

function Store.getRevision(self: Store): number
    return (self :: any)._revision
end

-- The state of one evidence, or nil for an unknown id.
function Store.getState(self: Store, evidenceId: any): string?
    local instance = (self :: any)._entries[evidenceId]
    if instance == nil then
        return nil
    end
    return instance.state
end

-- A fresh copy of one entry (including who observed what, for attribution), or nil for an unknown id.
function Store.getEntry(self: Store, evidenceId: any): Entry?
    local data: any = self
    local instance = data._entries[evidenceId]
    if instance == nil then
        return nil
    end
    local definition = data._plan.entries[evidenceId]
    local observations: { Observation } = {}
    for index, observation in ipairs(instance.observations) do
        observations[index] = { sourceId = observation.sourceId, observerId = observation.observerId, at = observation.at }
    end
    return {
        id = evidenceId,
        category = definition.category,
        state = instance.state,
        required = definition.distinctSources,
        sourceCount = #instance.observations,
        observations = observations,
        confirmedBy = instance.confirmedBy,
        confirmedAt = instance.confirmedAt,
    }
end

-- Fresh copies of every entry in catalog order.
function Store.getEntries(self: Store): { Entry }
    local data: any = self
    local list: { Entry } = {}
    for _, id in ipairs(data._plan.order) do
        table.insert(list, (self :: any):getEntry(id))
    end
    return list
end

-- Shared investigation progress. Derived from the ledger only, so it is identical whoever contributed, and duplicate
-- observations (same source) can never raise it: corroboration counts each evidence at most `required` distinct sources.
function Store.getProgress(self: Store): Progress
    local data: any = self
    local total, unknown, observed, confirmed = 0, 0, 0, 0
    local credit, needed = 0, 0
    for _, id in ipairs(data._plan.order) do
        local instance = data._entries[id]
        local required: number = data._plan.entries[id].distinctSources
        total = total + 1
        needed = needed + required
        credit = credit + math.min(#instance.observations, required)
        if instance.state == States.UNKNOWN then
            unknown = unknown + 1
        elseif instance.state == States.OBSERVED then
            observed = observed + 1
        else
            confirmed = confirmed + 1
        end
    end
    return {
        total = total,
        unknown = unknown,
        observed = observed,
        confirmed = confirmed,
        confirmedRatio = confirmed / total,
        corroborationRatio = credit / needed,
    }
end

-- Verifies the invariants of the model. Returns (true, nil) or (false, description). Used by the specs after every command.
function Store.checkInvariants(self: Store): (boolean, string?)
    local data: any = self
    local plan = data._plan
    if type(data._revision) ~= "number" or data._revision < 0 or data._revision % 1 ~= 0 then
        return false, "revision must be a non-negative integer"
    end
    for _, id in ipairs(plan.order) do
        local instance = data._entries[id]
        if instance == nil then
            return false, id .. ": missing entry"
        end
        local seen: { [string]: boolean } = {}
        for _, observation in ipairs(instance.observations) do
            if not isToken(observation.sourceId) or not isUserId(observation.observerId) or not isFiniteNumber(observation.at) then
                return false, id .. ": malformed observation"
            end
            if seen[observation.sourceId] then
                return false, id .. ": the same source is recorded twice"
            end
            seen[observation.sourceId] = true
            if not instance.sourceSet[observation.sourceId] then
                return false, id .. ": source set and observations disagree"
            end
        end
        local count = #instance.observations
        for sourceId in pairs(instance.sourceSet) do
            if not seen[sourceId] then
                return false, id .. ": source set contains an unrecorded source"
            end
        end
        if count > EvidenceCore.MaxSourcesPerEvidence then
            return false, id .. ": too many sources"
        end
        local required: number = plan.entries[id].distinctSources
        if instance.state == States.UNKNOWN then
            if count ~= 0 then
                return false, id .. ": UNKNOWN with observations"
            end
        elseif instance.state == States.OBSERVED then
            if count < 1 then
                return false, id .. ": OBSERVED without an observation"
            end
        elseif instance.state == States.CONFIRMED then
            if count < required then
                return false, id .. ": CONFIRMED without enough distinct sources"
            end
            if not isUserId(instance.confirmedBy) or not isFiniteNumber(instance.confirmedAt) then
                return false, id .. ": CONFIRMED without a confirmer"
            end
        else
            return false, id .. ": unknown state"
        end
        if instance.state ~= States.CONFIRMED and (instance.confirmedBy ~= nil or instance.confirmedAt ~= nil) then
            return false, id .. ": confirmation data on unconfirmed evidence"
        end
    end
    local progress = (self :: any):getProgress()
    if progress.unknown + progress.observed + progress.confirmed ~= progress.total then
        return false, "progress counts do not add up"
    end
    return true, nil
end

return EvidenceCore
