--!strict
-- Pure objective runtime store and state machine (TTL-09A, docs/TTL-09_OBJECTIVE_SYSTEM.md sections 4-7).
-- No Roblox services, Instances, Players, remotes, timers, yielding or other side effects: time is injected as `now`
-- (seconds), contributors are plain `UserId` numbers (never Player references) and the Core never calls out. State
-- lives here and nowhere else; collaborators receive copies only.
--
-- Construction takes a compiled plan (`ObjectiveGraph.compile`) rather than requiring the graph module, because pure
-- modules in this repository are dependency-free and receive collaborators by injection.
--
-- Every mutation is atomic: all validation happens first, the whole outcome (slot fill, state change, dependency
-- cascade, resolution) is computed on scratch maps, and only then committed with plain assignments. A rejected or
-- failing command therefore never leaves a partial change and never advances the revision.
--
-- Objective completion is not mission completion. The mission resolves at most once, after the cascade reached its
-- fixpoint: FAILED if a REQUIRED objective failed, COMPLETED when every REQUIRED objective is COMPLETED. Resolution is
-- sticky; once it exists every further mutation is rejected.

local ObjectiveCore = {}

-- Kept in sync with ObjectiveGraph.States (asserted by the specs); duplicated only because pure modules do not
-- require each other.
ObjectiveCore.States = table.freeze({
    LOCKED = "LOCKED",
    AVAILABLE = "AVAILABLE",
    IN_PROGRESS = "IN_PROGRESS",
    COMPLETED = "COMPLETED",
    FAILED = "FAILED",
    CANCELLED = "CANCELLED",
})

ObjectiveCore.Outcomes = table.freeze({
    COMPLETED = "COMPLETED",
    FAILED = "FAILED",
})

-- Reason tokens satisfy the lifecycle token rule ([A-Za-z0-9_-], 1-48 characters).
ObjectiveCore.ResolutionReasons = table.freeze({
    OBJECTIVES_COMPLETE = "objectives_complete",
    OBJECTIVE_FAILED = "objective_failed",
    OBJECTIVE_UNREACHABLE = "objective_unreachable",
})

ObjectiveCore.TerminalReasons = table.freeze({
    DEPENDENCY_UNREACHABLE = "dependency_unreachable",
})

-- Rejection reasons are for server logs; nothing is ever answered to a client.
ObjectiveCore.Reasons = table.freeze({
    INVALID_CONTEXT = "invalid_context", -- context is not a table with a finite `now` and a boolean `eligible`
    INVALID_CONTRIBUTOR = "invalid_contributor", -- userId is not an integer in [1, MaxUserId]
    INELIGIBLE_CONTRIBUTOR = "ineligible_contributor", -- the caller reports the contributor is not eligible
    MISSION_RESOLVED = "mission_resolved", -- the mission already resolved (sticky)
    INVALID_OBJECTIVE_ID = "invalid_objective_id",
    UNKNOWN_OBJECTIVE = "unknown_objective",
    INVALID_SLOT_ID = "invalid_slot_id",
    UNKNOWN_SLOT = "unknown_slot",
    NOT_AVAILABLE = "not_available", -- LOCKED
    OBJECTIVE_TERMINAL = "objective_terminal", -- COMPLETED / FAILED / CANCELLED
    ALREADY_FILLED = "already_filled",
    INVALID_TIME = "invalid_time",
    INVALID_REASON = "invalid_reason",
    REQUIRED_CANNOT_CANCEL = "required_cannot_cancel",
    INVALID_TRANSITION = "invalid_transition",
})

ObjectiveCore.SnapshotVersion = 1
ObjectiveCore.MaxUserId = 9007199254740991
ObjectiveCore.MaxReasonLength = 48

local States = ObjectiveCore.States
local Outcomes = ObjectiveCore.Outcomes
local ResolutionReasons = ObjectiveCore.ResolutionReasons
local TerminalReasons = ObjectiveCore.TerminalReasons
local Reasons = ObjectiveCore.Reasons

export type Change = {
    kind: string, -- "SLOT" | "STATE"
    objectiveId: string,
    slotId: string?,
    userId: number?,
    from: string?,
    to: string?,
    reason: string?,
}

export type Resolution = { outcome: string, reason: string }

export type CommandResult = {
    ok: boolean,
    reason: string?, -- rejection reason when `ok` is false
    changed: boolean,
    changes: { Change }, -- ordered: the slot fill first, then state changes in cascade order
    resolution: Resolution?, -- present only on the command that resolved the mission
}

export type Context = { eligible: boolean, now: number }

type SlotInstance = { filled: boolean, filledBy: number?, filledAt: number? }

type Instance = {
    id: string,
    state: string,
    reason: string?,
    revealed: boolean, -- has left LOCKED at least once (hidden objectives are never replicated before this)
    filledCount: number,
    slotCount: number,
    slots: { [string]: SlotInstance },
    changedAt: number,
}

type StoreData = {
    _plan: any,
    _instances: { [string]: Instance },
    _revision: number,
    _resolution: Resolution?,
}

local Store = {}
Store.__index = Store

export type Store = typeof(setmetatable({} :: StoreData, Store))

local function isFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isUserId(value: any): boolean
    return type(value) == "number" and value >= 1 and value <= ObjectiveCore.MaxUserId and value % 1 == 0
end

local function isReasonToken(value: any): boolean
    return type(value) == "string"
        and #value >= 1
        and #value <= ObjectiveCore.MaxReasonLength
        and string.match(value, "^[A-Za-z0-9_%-]+$") ~= nil
end

local function isTerminal(state: string): boolean
    return state == States.COMPLETED or state == States.FAILED or state == States.CANCELLED
end

local function isPlan(plan: any): boolean
    return type(plan) == "table"
        and plan.kind == "ObjectiveGraphPlan"
        and type(plan.order) == "table"
        and type(plan.objectives) == "table"
        and type(plan.evaluate) == "function"
        and #plan.order >= 1
end

local function rejected(reason: string): CommandResult
    return { ok = false, reason = reason, changed = false, changes = {}, resolution = nil }
end

-- Scratch view of the world used while computing a command: states and reasons only (slot fills are applied from the
-- change list at commit time).
type Scratch = { state: { [string]: string }, reason: { [string]: string? } }

local function newScratch(self: any): Scratch
    local scratch: Scratch = { state = {}, reason = {} }
    for id, instance in pairs(self._instances) do
        scratch.state[id] = instance.state
        scratch.reason[id] = instance.reason
    end
    return scratch
end

-- Dependency cascade (design 5.4): re-evaluate every LOCKED objective in definition order until a full pass changes
-- nothing. SATISFIED unlocks; IMPOSSIBLE cancels an OPTIONAL objective and fails a REQUIRED one (both with reason
-- `dependency_unreachable`). Deterministic: fixed order, acyclic graph, bounded passes.
local function cascade(plan: any, scratch: Scratch, changes: { Change })
    local order = plan.order
    local function stateOf(id: string): string?
        return scratch.state[id]
    end
    local changed = true
    local passes = 0
    while changed and passes <= #order + 1 do
        changed = false
        passes = passes + 1
        for index = 1, #order do
            local id = order[index]
            if scratch.state[id] == States.LOCKED then
                local evaluation = plan.evaluate(id, stateOf)
                if evaluation == "SATISFIED" then
                    scratch.state[id] = States.AVAILABLE
                    table.insert(changes, { kind = "STATE", objectiveId = id, from = States.LOCKED, to = States.AVAILABLE })
                    changed = true
                elseif evaluation == "IMPOSSIBLE" then
                    local target = States.CANCELLED
                    if plan.objectives[id].importance == "REQUIRED" then
                        target = States.FAILED
                    end
                    scratch.state[id] = target
                    scratch.reason[id] = TerminalReasons.DEPENDENCY_UNREACHABLE
                    table.insert(changes, {
                        kind = "STATE",
                        objectiveId = id,
                        from = States.LOCKED,
                        to = target,
                        reason = TerminalReasons.DEPENDENCY_UNREACHABLE,
                    })
                    changed = true
                end
            end
        end
    end
end

-- Mission resolution, evaluated once after the cascade (design 5.4 / 11.3). FAILED wins over COMPLETED, but they
-- cannot both hold: a failed REQUIRED objective is not completed. An explicitly failed REQUIRED objective
-- (`objective_failed`) takes precedence over one that failed only because its dependencies became unreachable
-- (`objective_unreachable`), so the reason names the root cause regardless of definition order.
local function evaluateResolution(plan: any, scratch: Scratch): Resolution?
    local order = plan.order
    local unreachable = false
    for index = 1, #order do
        local id = order[index]
        if plan.objectives[id].importance == "REQUIRED" and scratch.state[id] == States.FAILED then
            if scratch.reason[id] == TerminalReasons.DEPENDENCY_UNREACHABLE then
                unreachable = true
            else
                return { outcome = Outcomes.FAILED, reason = ResolutionReasons.OBJECTIVE_FAILED }
            end
        end
    end
    if unreachable then
        return { outcome = Outcomes.FAILED, reason = ResolutionReasons.OBJECTIVE_UNREACHABLE }
    end
    for index = 1, #order do
        local id = order[index]
        if plan.objectives[id].importance == "REQUIRED" and scratch.state[id] ~= States.COMPLETED then
            return nil
        end
    end
    return { outcome = Outcomes.COMPLETED, reason = ResolutionReasons.OBJECTIVES_COMPLETE }
end

-- Commit: plain assignments only, no failure points. Bumps the revision once per applied command.
local function commit(self: any, changes: { Change }, resolution: Resolution?, now: number)
    for _, change in ipairs(changes) do
        local instance = self._instances[change.objectiveId]
        if change.kind == "SLOT" then
            local slot = instance.slots[change.slotId]
            slot.filled = true
            slot.filledBy = change.userId
            slot.filledAt = now
            instance.filledCount = instance.filledCount + 1
        else
            instance.state = change.to
            instance.reason = change.reason
            instance.changedAt = now
            if change.from == States.LOCKED and change.to == States.AVAILABLE then
                instance.revealed = true
            end
        end
    end
    if resolution ~= nil then
        self._resolution = table.freeze({ outcome = resolution.outcome, reason = resolution.reason })
    end
    self._revision = self._revision + 1
end

local function copyResolution(resolution: Resolution?): Resolution?
    if resolution == nil then
        return nil
    end
    return { outcome = resolution.outcome, reason = resolution.reason }
end

-- `plan` comes from ObjectiveGraph.compile. Raises on an invalid plan or clock (callers compile first). Initialization
-- is deterministic: every objective starts LOCKED, then the cascade unlocks the roots. Initialization is not a change:
-- the revision starts at 0 and nothing is resolved (validation guarantees at least one REQUIRED objective).
function ObjectiveCore.new(plan: any, now: any): Store
    if not isPlan(plan) then
        error("ObjectiveCore.new: a compiled plan (ObjectiveGraph.compile) is required", 2)
    end
    if not isFiniteNumber(now) then
        error("ObjectiveCore.new: now must be a finite number", 2)
    end
    local instances: { [string]: Instance } = {}
    for _, id in ipairs(plan.order) do
        local definition = plan.objectives[id]
        local slots: { [string]: SlotInstance } = {}
        for _, slot in ipairs(definition.slots) do
            slots[slot.id] = { filled = false, filledBy = nil, filledAt = nil }
        end
        instances[id] = {
            id = id,
            state = States.LOCKED,
            reason = nil,
            revealed = false,
            filledCount = 0,
            slotCount = #definition.slots,
            slots = slots,
            changedAt = now,
        }
    end
    local self = setmetatable({
        _plan = plan,
        _instances = instances,
        _revision = 0,
        _resolution = nil,
    }, Store)

    local scratch = newScratch(self)
    local changes: { Change } = {}
    cascade(plan, scratch, changes)
    commit(self, changes, nil, now)
    self._revision = 0
    return self
end

-- Records one slot fill. `context` is `{ eligible = boolean, now = number }`; the caller (service) decides eligibility
-- (living, connected roster member); the Core only refuses when told the contributor is not eligible. Precedence of
-- rejections is fixed: context, contributor, eligibility, resolved, objective id, objective, slot id, slot, state,
-- already filled. Returns a CommandResult; a rejection changes nothing.
function Store.contribute(self: Store, objectiveId: any, slotId: any, userId: any, context: any): CommandResult
    local data: any = self
    if type(context) ~= "table" or type(context.eligible) ~= "boolean" or not isFiniteNumber(context.now) then
        return rejected(Reasons.INVALID_CONTEXT)
    end
    local now: number = context.now
    local eligible: boolean = context.eligible
    if not isUserId(userId) then
        return rejected(Reasons.INVALID_CONTRIBUTOR)
    end
    if not eligible then
        return rejected(Reasons.INELIGIBLE_CONTRIBUTOR)
    end
    if data._resolution ~= nil then
        return rejected(Reasons.MISSION_RESOLVED)
    end
    if type(objectiveId) ~= "string" then
        return rejected(Reasons.INVALID_OBJECTIVE_ID)
    end
    local instance = data._instances[objectiveId]
    if instance == nil then
        return rejected(Reasons.UNKNOWN_OBJECTIVE)
    end
    if type(slotId) ~= "string" then
        return rejected(Reasons.INVALID_SLOT_ID)
    end
    local slot = instance.slots[slotId]
    if slot == nil then
        return rejected(Reasons.UNKNOWN_SLOT)
    end
    if instance.state == States.LOCKED then
        return rejected(Reasons.NOT_AVAILABLE)
    end
    if isTerminal(instance.state) then
        return rejected(Reasons.OBJECTIVE_TERMINAL)
    end
    if slot.filled then
        return rejected(Reasons.ALREADY_FILLED)
    end

    -- Compute the whole outcome on scratch state.
    local plan = data._plan
    local scratch = newScratch(data)
    local changes: { Change } = {}
    table.insert(changes, { kind = "SLOT", objectiveId = objectiveId, slotId = slotId, userId = userId })
    local newCount = instance.filledCount + 1
    local newState = instance.state
    if newCount == instance.slotCount then
        newState = States.COMPLETED
    elseif instance.state == States.AVAILABLE then
        newState = States.IN_PROGRESS
    end
    if newState ~= instance.state then
        scratch.state[objectiveId] = newState
        table.insert(changes, { kind = "STATE", objectiveId = objectiveId, from = instance.state, to = newState })
    end
    cascade(plan, scratch, changes)
    local resolution = evaluateResolution(plan, scratch)

    commit(data, changes, resolution, now)
    return { ok = true, reason = nil, changed = true, changes = changes, resolution = copyResolution(resolution) }
end

-- Shared by `fail` and `cancel`: only AVAILABLE and IN_PROGRESS objectives can be ended explicitly (design 5.2). LOCKED
-- objectives end only through the cascade.
local function endObjective(self: any, objectiveId: any, reason: any, now: any, target: string): CommandResult
    if not isFiniteNumber(now) then
        return rejected(Reasons.INVALID_TIME)
    end
    if not isReasonToken(reason) then
        return rejected(Reasons.INVALID_REASON)
    end
    if type(objectiveId) ~= "string" then
        return rejected(Reasons.INVALID_OBJECTIVE_ID)
    end
    local instance = self._instances[objectiveId]
    if instance == nil then
        return rejected(Reasons.UNKNOWN_OBJECTIVE)
    end
    local plan = self._plan
    if target == States.CANCELLED and plan.objectives[objectiveId].importance == "REQUIRED" then
        return rejected(Reasons.REQUIRED_CANNOT_CANCEL)
    end
    if instance.state == target then
        -- Idempotent: repeating the current terminal state is a no-op, not an error.
        return { ok = true, reason = nil, changed = false, changes = {}, resolution = nil }
    end
    if self._resolution ~= nil then
        return rejected(Reasons.MISSION_RESOLVED)
    end
    if instance.state ~= States.AVAILABLE and instance.state ~= States.IN_PROGRESS then
        if instance.state == States.LOCKED then
            return rejected(Reasons.NOT_AVAILABLE)
        end
        return rejected(Reasons.INVALID_TRANSITION)
    end

    local scratch = newScratch(self)
    local changes: { Change } = {}
    scratch.state[objectiveId] = target
    scratch.reason[objectiveId] = reason
    table.insert(changes, { kind = "STATE", objectiveId = objectiveId, from = instance.state, to = target, reason = reason })
    cascade(plan, scratch, changes)
    local resolution = evaluateResolution(plan, scratch)

    commit(self, changes, resolution, now)
    return { ok = true, reason = nil, changed = true, changes = changes, resolution = copyResolution(resolution) }
end

-- AVAILABLE / IN_PROGRESS -> FAILED. A REQUIRED objective failing resolves the mission as failed.
function Store.fail(self: Store, objectiveId: any, reason: any, now: any): CommandResult
    return endObjective(self, objectiveId, reason, now, States.FAILED)
end

-- AVAILABLE / IN_PROGRESS -> CANCELLED. Rejected for REQUIRED objectives (`required_cannot_cancel`).
function Store.cancel(self: Store, objectiveId: any, reason: any, now: any): CommandResult
    return endObjective(self, objectiveId, reason, now, States.CANCELLED)
end

function Store.getRevision(self: Store): number
    return (self :: any)._revision
end

-- A copy of the resolution, or nil while the mission is unresolved.
function Store.getResolution(self: Store): Resolution?
    return copyResolution((self :: any)._resolution)
end

function Store.isResolved(self: Store): boolean
    return (self :: any)._resolution ~= nil
end

function Store.getState(self: Store, objectiveId: any): string?
    local instance = (self :: any)._instances[objectiveId]
    if instance == nil then
        return nil
    end
    return instance.state
end

-- Number of filled slots of an objective, or nil for an unknown objective.
function Store.getFilledCount(self: Store, objectiveId: any): number?
    local instance = (self :: any)._instances[objectiveId]
    if instance == nil then
        return nil
    end
    return instance.filledCount
end

-- Attribution only (never gates anything and is not replicated): the UserId that filled a slot, or nil.
function Store.getContributor(self: Store, objectiveId: any, slotId: any): number?
    local instance = (self :: any)._instances[objectiveId]
    if instance == nil then
        return nil
    end
    local slot = instance.slots[slotId]
    if slot == nil then
        return nil
    end
    return slot.filledBy
end

-- Replicable projection (design 8.3): a fresh copy on every call (mutating it never affects the Core). Objectives with
-- `hiddenUntilAvailable` are omitted until they have left LOCKED. Never included: seed, content version, point ids,
-- UserIds, reasons, timestamps, resolution.
function Store.getSnapshot(self: Store): any
    local data: any = self
    local plan = data._plan
    local objectives = {}
    for _, id in ipairs(plan.order) do
        local definition = plan.objectives[id]
        local instance = data._instances[id]
        if not (definition.hiddenUntilAvailable and not instance.revealed) then
            local slots = {}
            for _, slot in ipairs(definition.slots) do
                table.insert(slots, { label = slot.label, filled = instance.slots[slot.id].filled })
            end
            table.insert(objectives, {
                id = id,
                title = definition.title,
                description = definition.description,
                importance = definition.importance,
                state = instance.state,
                filled = instance.filledCount,
                required = instance.slotCount,
                slots = slots,
            })
        end
    end
    return { v = ObjectiveCore.SnapshotVersion, revision = data._revision, objectives = objectives }
end

-- Verifies the invariants of design sections 5-7. Returns (true, nil) or (false, description). Used by the specs after
-- every command; cheap enough to call anywhere.
function Store.checkInvariants(self: Store): (boolean, string?)
    local data: any = self
    local plan = data._plan
    if type(data._revision) ~= "number" or data._revision < 0 or data._revision % 1 ~= 0 then
        return false, "revision must be a non-negative integer"
    end
    local scratchStates: { [string]: string } = {}
    for id, instance in pairs(data._instances) do
        scratchStates[id] = instance.state
    end
    local function stateOf(id: string): string?
        return scratchStates[id]
    end
    for _, id in ipairs(plan.order) do
        local instance = data._instances[id]
        if instance == nil then
            return false, id .. ": missing instance"
        end
        local counted = 0
        for _, slot in pairs(instance.slots) do
            if slot.filled then
                counted = counted + 1
                if not isUserId(slot.filledBy) then
                    return false, id .. ": filled slot without a valid contributor"
                end
            elseif slot.filledBy ~= nil then
                return false, id .. ": unfilled slot with a contributor"
            end
        end
        if counted ~= instance.filledCount then
            return false, id .. ": filledCount does not match the slots"
        end
        local state = instance.state
        if state == States.LOCKED or state == States.AVAILABLE then
            if instance.filledCount ~= 0 then
                return false, id .. ": " .. state .. " with contributions"
            end
        elseif state == States.IN_PROGRESS then
            if instance.filledCount < 1 or instance.filledCount >= instance.slotCount then
                return false, id .. ": IN_PROGRESS with an impossible fill count"
            end
        elseif state == States.COMPLETED then
            if instance.filledCount ~= instance.slotCount then
                return false, id .. ": COMPLETED with unfilled slots"
            end
        elseif state == States.FAILED or state == States.CANCELLED then
            if not isReasonToken(instance.reason) then
                return false, id .. ": terminal failure without a reason token"
            end
            if state == States.CANCELLED and plan.objectives[id].importance == "REQUIRED" then
                return false, id .. ": REQUIRED objective cancelled"
            end
        else
            return false, id .. ": unknown state"
        end
        if state ~= States.LOCKED and not instance.revealed and plan.objectives[id].hiddenUntilAvailable then
            -- A hidden objective that left LOCKED must have been revealed, unless it ended directly from LOCKED.
            if state ~= States.CANCELLED and state ~= States.FAILED then
                return false, id .. ": hidden objective left LOCKED without being revealed"
            end
        end
        if state == States.LOCKED then
            -- The cascade is at its fixpoint after every command: a LOCKED objective is neither satisfied nor impossible.
            if plan.evaluate(id, stateOf) ~= "PENDING" then
                return false, id .. ": LOCKED but its dependencies are not pending"
            end
        elseif state == States.AVAILABLE or state == States.IN_PROGRESS or state == States.COMPLETED then
            if plan.evaluate(id, stateOf) == "PENDING" then
                return false, id .. ": started without satisfied dependencies"
            end
        end
    end
    -- Resolution consistency.
    local anyRequiredFailed = false
    local allRequiredCompleted = true
    for _, id in ipairs(plan.order) do
        if plan.objectives[id].importance == "REQUIRED" then
            local state = data._instances[id].state
            if state == States.FAILED then
                anyRequiredFailed = true
            end
            if state ~= States.COMPLETED then
                allRequiredCompleted = false
            end
        end
    end
    local resolution = data._resolution
    if anyRequiredFailed then
        if resolution == nil or resolution.outcome ~= Outcomes.FAILED then
            return false, "a REQUIRED objective failed but the mission is not resolved as failed"
        end
    elseif allRequiredCompleted then
        if resolution == nil or resolution.outcome ~= Outcomes.COMPLETED then
            return false, "every REQUIRED objective completed but the mission is not resolved as completed"
        end
    elseif resolution ~= nil then
        return false, "the mission is resolved although REQUIRED objectives are still open"
    end
    return true, nil
end

return ObjectiveCore