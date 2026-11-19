--!strict
-- Pure objective content validation and dependency rules (TTL-09A, docs/TTL-09_OBJECTIVE_SYSTEM.md sections 4 and 6).
-- No Roblox services, Instances, timers or globals. `validate` never mutates or freezes the caller's table.
--
-- Validation order is fixed so the same invalid content always reports the same code (design section 4.3):
--   1. structure (types, fields, limits, text)      2. identity (unique ids, slot ids, anchor ids)
--   3. references (unknown, self, duplicate, empty) 4. cycles
--   5. at least one REQUIRED objective             6. mandatory progression rule (`required_not_guaranteed`)
-- Within a step, objectives are inspected in definition order, so the first offender is reported.

local ObjectiveGraph = {}

ObjectiveGraph.States = table.freeze({
    LOCKED = "LOCKED",
    AVAILABLE = "AVAILABLE",
    IN_PROGRESS = "IN_PROGRESS",
    COMPLETED = "COMPLETED",
    FAILED = "FAILED",
    CANCELLED = "CANCELLED",
})

-- `ALTERNATIVE` is reserved for TTL-09E and is deliberately NOT accepted here (it is rejected with its own code, never
-- treated as OPTIONAL).
ObjectiveGraph.Importance = table.freeze({
    REQUIRED = "REQUIRED",
    OPTIONAL = "OPTIONAL",
})

-- `SIGNAL` is a trusted server-side completion path (TTL-11D). Branching remains reserved for TTL-09E.
ObjectiveGraph.CompletionKinds = table.freeze({
    SLOTS = "SLOTS",
    SIGNAL = "SIGNAL",
})

ObjectiveGraph.Dependency = table.freeze({
    SATISFIED = "SATISFIED",
    PENDING = "PENDING",
    IMPOSSIBLE = "IMPOSSIBLE",
})

ObjectiveGraph.Limits = table.freeze({
    MaxContentVersion = 2147483647,
    MaxObjectives = 32,
    MaxSlotsPerObjective = 8,
    MaxDependenciesPerList = 8,
    MaxTitleBytes = 48,
    MaxDescriptionBytes = 140,
    MaxLabelBytes = 40,
    MaxIdLength = 32,
    MaxSourceTokenLength = 48,
})

local States = ObjectiveGraph.States
local Importance = ObjectiveGraph.Importance
local Dependency = ObjectiveGraph.Dependency
local Limits = ObjectiveGraph.Limits

export type DependencySpec = { allOf: { string }?, anyOf: { string }? }
export type SlotDefinition = { id: string, pointId: string, label: string }
export type CompletionSpec = { kind: string, slots: { SlotDefinition }?, signal: { sourceToken: string }? }
export type ObjectiveDefinition = { id: string, importance: string, requires: DependencySpec?, completion: CompletionSpec, title: string, description: string, hiddenUntilAvailable: boolean? }
export type ObjectiveContent = { version: number, objectives: { ObjectiveDefinition } }

local ID_PATTERN = "^[A-Z][A-Z0-9_]*$"

local CONTENT_FIELDS: { [string]: boolean } = { version = true, objectives = true }
local OBJECTIVE_FIELDS: { [string]: boolean } = {
    id = true,
    importance = true,
    requires = true,
    completion = true,
    title = true,
    description = true,
    hiddenUntilAvailable = true,
}
local REQUIRES_FIELDS: { [string]: boolean } = { allOf = true, anyOf = true }
local COMPLETION_FIELDS: { [string]: boolean } = { kind = true, slots = true, signal = true }
local SLOT_FIELDS: { [string]: boolean } = { id = true, pointId = true, label = true }
local SIGNAL_FIELDS: { [string]: boolean } = { sourceToken = true }

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value >= min and value <= max and value % 1 == 0
end

local function isId(value: any): boolean
    return type(value) == "string" and #value >= 1 and #value <= Limits.MaxIdLength and string.match(value, ID_PATTERN) ~= nil
end

-- Server-authored token; never replicated or accepted from a client.
local function isSourceToken(value: any): boolean
    return type(value) == "string" and #value >= 1 and #value <= Limits.MaxSourceTokenLength
        and string.match(value, "^[A-Za-z0-9_%-]+$") ~= nil
end

-- Non-empty, bounded, valid UTF-8, no control characters (including newlines and tabs).
local function isText(value: any, maxBytes: number): boolean
    if type(value) ~= "string" or #value < 1 or #value > maxBytes then
        return false
    end
    if utf8.len(value) == nil then
        return false
    end
    -- Lua's %c pattern only covers ASCII control bytes. Iterate decoded Unicode code points
    -- so the C1 range (U+0080..U+009F), including NEL, is rejected as well.
    for _, codepoint in utf8.codes(value) do
        if codepoint <= 0x1F or (codepoint >= 0x7F and codepoint <= 0x9F) then
            return false
        end
    end
    return true
end

local function isPlainTable(value: any): boolean
    return type(value) == "table" and getmetatable(value) == nil
end

-- Dense array (keys exactly 1..count, plain table). Returns the count or nil.
local function denseArrayLength(value: any, maxCount: number): number?
    if not isPlainTable(value) then
        return nil
    end
    local count = 0
    for key in pairs(value) do
        if not isInteger(key, 1, maxCount) then
            return nil
        end
        count = count + 1
    end
    for index = 1, count do
        if value[index] == nil then
            return nil
        end
    end
    return count
end

local function hasOnlyFields(value: any, allowed: { [string]: boolean }): boolean
    for key in pairs(value) do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
    end
    return true
end

-- Step 1 for one objective. Returns nil or a code.
local function checkObjectiveStructure(entry: any): string?
    if not isPlainTable(entry) then
        return "invalid_objective_entry"
    end
    if not hasOnlyFields(entry, OBJECTIVE_FIELDS) then
        return "unexpected_objective_field"
    end
    if not isId(entry.id) then
        return "invalid_objective_id"
    end
    if entry.importance == "ALTERNATIVE" then
        return "alternative_not_supported"
    end
    if entry.importance ~= Importance.REQUIRED and entry.importance ~= Importance.OPTIONAL then
        return "invalid_importance"
    end
    if not isText(entry.title, Limits.MaxTitleBytes) then
        return "invalid_title"
    end
    if not isText(entry.description, Limits.MaxDescriptionBytes) then
        return "invalid_description"
    end
    if entry.hiddenUntilAvailable ~= nil and type(entry.hiddenUntilAvailable) ~= "boolean" then
        return "invalid_hidden_flag"
    end

    local requires = entry.requires
    if requires ~= nil then
        if not isPlainTable(requires) then
            return "invalid_requires"
        end
        if not hasOnlyFields(requires, REQUIRES_FIELDS) then
            return "unexpected_requires_field"
        end
        if requires.allOf == nil and requires.anyOf == nil then
            return "empty_requires"
        end
        for _, listName in ipairs({ "allOf", "anyOf" }) do
            local list = requires[listName]
            if list ~= nil then
                local count = denseArrayLength(list, Limits.MaxDependenciesPerList)
                if count == nil then
                    return "invalid_dependency_list"
                end
                for index = 1, count do
                    if not isId(list[index]) then
                        return "invalid_dependency_id"
                    end
                end
            end
        end
    end

    local completion = entry.completion
    if not isPlainTable(completion) then
        return "invalid_completion"
    end
    if not hasOnlyFields(completion, COMPLETION_FIELDS) then
        return "unexpected_completion_field"
    end
    if completion.kind == "SLOTS" then
        if completion.signal ~= nil then
            return "signal_not_allowed"
        end
        local slotCount = denseArrayLength(completion.slots, Limits.MaxSlotsPerObjective)
        if slotCount == nil then
            return "invalid_slots"
        end
        if slotCount < 1 then
            return "empty_slots"
        end
        for index = 1, slotCount do
            local slot = completion.slots[index]
            if not isPlainTable(slot) then
                return "invalid_slot_entry"
            end
            if not hasOnlyFields(slot, SLOT_FIELDS) then
                return "unexpected_slot_field"
            end
            if not isId(slot.id) then
                return "invalid_slot_id"
            end
            if not isId(slot.pointId) then
                return "invalid_point_id"
            end
            if not isText(slot.label, Limits.MaxLabelBytes) then
                return "invalid_slot_label"
            end
        end
        return nil
    end
    if completion.kind == "SIGNAL" then
        if completion.slots ~= nil then
            return "slots_not_allowed"
        end
        if not isPlainTable(completion.signal) then
            return "invalid_signal"
        end
        if not hasOnlyFields(completion.signal, SIGNAL_FIELDS) then
            return "unexpected_signal_field"
        end
        if not isSourceToken(completion.signal.sourceToken) then
            return "invalid_source_token"
        end
        return nil
    end
    return "invalid_completion_kind"
end

-- Returns (true, nil, nil) or (false, code, subject). `subject` is the offending objective id when there is one. Codes are
-- for server logs only; they are stable and are what the specs assert.
function ObjectiveGraph.validate(content: any): (boolean, string?, string?)
    -- 1. Structure.
    if not isPlainTable(content) then
        return false, "invalid_content_table", nil
    end
    if not hasOnlyFields(content, CONTENT_FIELDS) then
        return false, "unexpected_content_field", nil
    end
    if not isInteger(content.version, 1, Limits.MaxContentVersion) then
        return false, "invalid_content_version", nil
    end
    local count = denseArrayLength(content.objectives, Limits.MaxObjectives)
    if count == nil then
        return false, "invalid_objectives", nil
    end
    if count < 1 then
        return false, "empty_objectives", nil
    end
    for index = 1, count do
        local code = checkObjectiveStructure(content.objectives[index])
        if code ~= nil then
            local entry = content.objectives[index]
            local subject = nil
            if type(entry) == "table" and isId(entry.id) then
                subject = entry.id
            end
            return false, code, subject
        end
    end

    -- 2. Identity.
    local byId: { [string]: any } = {}
    local pointIds: { [string]: string } = {}
    for index = 1, count do
        local entry = content.objectives[index]
        if byId[entry.id] ~= nil then
            return false, "duplicate_objective_id", entry.id
        end
        byId[entry.id] = entry
        if entry.completion.kind == "SLOTS" then
            local slotIds: { [string]: boolean } = {}
            for slotIndex = 1, #entry.completion.slots do
                local slot = entry.completion.slots[slotIndex]
                if slotIds[slot.id] then
                    return false, "duplicate_slot_id", entry.id
                end
                slotIds[slot.id] = true
                -- One slot is one interaction registration on one anchor (design 3.4): anchors cannot be shared.
                if pointIds[slot.pointId] ~= nil then
                    return false, "duplicate_point_id", entry.id
                end
                pointIds[slot.pointId] = entry.id
            end
        end
    end

    -- 3. References.
    local adjacency: { [string]: { string } } = {}
    for index = 1, count do
        local entry = content.objectives[index]
        local edges: { string } = {}
        adjacency[entry.id] = edges
        if entry.requires ~= nil then
            for _, listName in ipairs({ "allOf", "anyOf" }) do
                local list = entry.requires[listName]
                if list ~= nil then
                    if #list == 0 then
                        return false, "empty_dependency_list", entry.id
                    end
                    local seen: { [string]: boolean } = {}
                    for listIndex = 1, #list do
                        local dependencyId = list[listIndex]
                        if byId[dependencyId] == nil then
                            return false, "unknown_dependency", entry.id
                        end
                        if dependencyId == entry.id then
                            return false, "self_dependency", entry.id
                        end
                        if seen[dependencyId] then
                            return false, "duplicate_dependency", entry.id
                        end
                        seen[dependencyId] = true
                        table.insert(edges, dependencyId)
                    end
                end
            end
        end
    end

    -- 4. Cycles (iterative DFS in definition order; edges in listed order, allOf before anyOf). A cycle is a content
    -- error whatever the importance of its members.
    local color: { [string]: number } = {}
    local cursor: { [string]: number } = {}
    for index = 1, count do
        local rootId = content.objectives[index].id
        if color[rootId] == nil then
            color[rootId] = 1
            cursor[rootId] = 0
            local stack: { string } = { rootId }
            while #stack > 0 do
                local top = stack[#stack]
                local nextEdge = cursor[top] + 1
                cursor[top] = nextEdge
                local target = adjacency[top][nextEdge]
                if target == nil then
                    color[top] = 2
                    stack[#stack] = nil
                elseif color[target] == 1 then
                    return false, "dependency_cycle", target
                elseif color[target] == nil then
                    color[target] = 1
                    cursor[target] = 0
                    table.insert(stack, target)
                end
            end
        end
    end

    -- 5. At least one REQUIRED objective.
    local hasRequired = false
    for index = 1, count do
        if content.objectives[index].importance == Importance.REQUIRED then
            hasRequired = true
            break
        end
    end
    if not hasRequired then
        return false, "no_required_objective", nil
    end

    -- 6. Mandatory progression rule.
    local guaranteed = ObjectiveGraph.computeGuaranteed(content)
    for index = 1, count do
        local entry = content.objectives[index]
        if entry.importance == Importance.REQUIRED and not guaranteed[entry.id] then
            return false, "required_not_guaranteed", entry.id
        end
    end
    return true, nil, nil
end

-- The guaranteed set G (design 6.4): the least fixpoint of
--   o in G  iff  o is REQUIRED, every allOf member is in G, and (no anyOf or at least one anyOf member is in G).
-- OPTIONAL objectives are never in G. Passes run in definition order until nothing changes (at most N + 1 passes), so
-- the result does not depend on that order. Expects content that passed steps 1-4 of `validate`.
function ObjectiveGraph.computeGuaranteed(content: any): { [string]: boolean }
    local guaranteed: { [string]: boolean } = {}
    local objectives = content.objectives
    local changed = true
    while changed do
        changed = false
        for index = 1, #objectives do
            local entry = objectives[index]
            if entry.importance == Importance.REQUIRED and not guaranteed[entry.id] then
                local holds = true
                local requires = entry.requires
                if requires ~= nil then
                    if requires.allOf ~= nil then
                        for _, dependencyId in ipairs(requires.allOf) do
                            if not guaranteed[dependencyId] then
                                holds = false
                                break
                            end
                        end
                    end
                    if holds and requires.anyOf ~= nil then
                        local any = false
                        for _, dependencyId in ipairs(requires.anyOf) do
                            if guaranteed[dependencyId] then
                                any = true
                                break
                            end
                        end
                        holds = any
                    end
                end
                if holds then
                    guaranteed[entry.id] = true
                    changed = true
                end
            end
        end
    end
    return guaranteed
end

-- A compiled plan is the validated, deep-copied, deeply frozen form of the content that ObjectiveCore consumes. Pure
-- modules in this repository do not require each other, so the Core receives the plan (and its `evaluate` function)
-- instead of requiring this module. Compiling copies the caller's content: later mutation of the original table can
-- never affect a plan, and the original is never frozen or modified.
export type PlanSlot = { id: string, pointId: string, label: string }
export type PlanObjective = {
    id: string,
    importance: string,
    requires: DependencySpec?,
    title: string,
    description: string,
    hiddenUntilAvailable: boolean,
    completionKind: string,
    signal: { sourceToken: string }?,
    slots: { PlanSlot },
}
export type Plan = {
    kind: string,
    version: number,
    order: { string },
    objectives: { [string]: PlanObjective },
    evaluate: (objectiveId: string, stateOf: (string) -> string?) -> string,
}

ObjectiveGraph.PlanKind = "ObjectiveGraphPlan"

local function copyIdList(list: { string }?): { string }?
    if list == nil then
        return nil
    end
    local copy: { string } = {}
    for index = 1, #list do
        copy[index] = list[index]
    end
    return table.freeze(copy)
end

-- Returns (plan, nil, nil) or (nil, code, subject) exactly like `validate`.
function ObjectiveGraph.compile(content: any): (Plan?, string?, string?)
    local ok, code, subject = ObjectiveGraph.validate(content)
    if not ok then
        return nil, code, subject
    end
    local order: { string } = {}
    local objectives: { [string]: PlanObjective } = {}
    for index = 1, #content.objectives do
        local entry = content.objectives[index]
        local requires: DependencySpec? = nil
        if entry.requires ~= nil then
            requires = table.freeze({
                allOf = copyIdList(entry.requires.allOf),
                anyOf = copyIdList(entry.requires.anyOf),
            })
        end
        local slots: { PlanSlot } = {}
        local signal: { sourceToken: string }? = nil
        if entry.completion.kind == "SLOTS" then
            for slotIndex = 1, #entry.completion.slots do
                local slot = entry.completion.slots[slotIndex]
                slots[slotIndex] = table.freeze({ id = slot.id, pointId = slot.pointId, label = slot.label })
            end
        else
            signal = table.freeze({ sourceToken = entry.completion.signal.sourceToken })
        end
        order[index] = entry.id
        objectives[entry.id] = table.freeze({
            id = entry.id,
            importance = entry.importance,
            requires = requires,
            title = entry.title,
            description = entry.description,
            hiddenUntilAvailable = entry.hiddenUntilAvailable == true,
            completionKind = entry.completion.kind,
            signal = signal,
            slots = table.freeze(slots),
        })
    end
    table.freeze(order)
    table.freeze(objectives)
    local function evaluate(objectiveId: string, stateOf: (string) -> string?): string
        local objective = objectives[objectiveId]
        if objective == nil then
            return Dependency.IMPOSSIBLE
        end
        return ObjectiveGraph.evaluateDependency(objective.requires, stateOf)
    end
    return table.freeze({
        kind = ObjectiveGraph.PlanKind,
        version = content.version,
        order = order,
        objectives = objectives,
        evaluate = evaluate,
    }), nil, nil
end

-- Runtime tri-state evaluation (design 6.2). `stateOf` maps an objective id to its current state. COMPLETED is
-- satisfied; FAILED and CANCELLED are dead (can never be satisfied); anything else is pending. Runtime semantics of
-- allOf/anyOf are exactly those of design 6.1; this function is independent of the static guarantee above.
--   allOf: SATISFIED if all satisfied; IMPOSSIBLE if any dead; else PENDING
--   anyOf: SATISFIED if any satisfied; IMPOSSIBLE if all dead; else PENDING
--   result: IMPOSSIBLE if either clause is; SATISFIED if both clauses are satisfied or absent; else PENDING
function ObjectiveGraph.evaluateDependency(requires: any, stateOf: (string) -> string?): string
    if requires == nil then
        return Dependency.SATISFIED
    end
    local impossible = false
    local pending = false

    if requires.allOf ~= nil then
        local allSatisfied = true
        for _, dependencyId in ipairs(requires.allOf) do
            local state = stateOf(dependencyId)
            if state == States.FAILED or state == States.CANCELLED then
                impossible = true
                allSatisfied = false
            elseif state ~= States.COMPLETED then
                allSatisfied = false
            end
        end
        if not allSatisfied then
            pending = true
        end
    end

    if requires.anyOf ~= nil then
        local anySatisfied = false
        local allDead = true
        for _, dependencyId in ipairs(requires.anyOf) do
            local state = stateOf(dependencyId)
            if state == States.COMPLETED then
                anySatisfied = true
            end
            if state ~= States.FAILED and state ~= States.CANCELLED then
                allDead = false
            end
        end
        if allDead and #requires.anyOf > 0 then
            impossible = true
        elseif not anySatisfied then
            pending = true
        end
    end

    if impossible then
        return Dependency.IMPOSSIBLE
    end
    if pending then
        return Dependency.PENDING
    end
    return Dependency.SATISFIED
end

return ObjectiveGraph