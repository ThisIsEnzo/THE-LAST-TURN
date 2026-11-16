--!strict
-- Evidence definitions: domain types, deterministic validation and compilation (TTL-11A, docs/TTL-11A_EVIDENCE_CORE.md).
-- Pure: no Roblox services, Instances, timers or globals. `validate` never mutates or freezes the caller's table; `compile`
-- returns a frozen deep copy (a "plan") that EvidenceCore consumes. Like every pure module in this repository this one
-- requires no other module, and EvidenceCore receives the plan instead of requiring this file.
--
-- Vocabulary (kept deliberately small):
--   * evidence TYPE / category: a token naming a family of clues (`ELECTRICAL`, `AUDIO`, ...). It is a free token, not a
--     closed enum, so new missions and entities add categories without touching the core.
--   * evidence DEFINITION: what one piece of evidence is and how it is corroborated (this file).
--   * OBSERVATION: one accepted sighting of that evidence from one authored source (EvidenceCore).
--   * CONFIRMATION: the explicit step that verifies it once enough DISTINCT sources agree (EvidenceCore). Requiring
--     distinct sources is the fair verification method: a single (possibly false) signal cannot confirm anything alone.
--
-- Validation order is fixed so the same invalid content always reports the same code:
--   1. structure (types, fields, limits, text)  2. identity (unique ids)
-- Within a step, definitions are inspected in order, so the first offender is reported.

local EvidenceCatalog = {}

EvidenceCatalog.PlanKind = "EvidenceCatalogPlan"

EvidenceCatalog.Limits = table.freeze({
    MaxContentVersion = 2147483647,
    MaxEvidence = 32,
    MaxDistinctSources = 8, -- the most distinct sources a definition may require
    MaxIdLength = 32,
    MaxTitleBytes = 48,
    MaxDescriptionBytes = 140,
})

local Limits = EvidenceCatalog.Limits

export type Confirmation = { distinctSources: number }

export type EvidenceDefinition = {
    id: string, -- ^[A-Z][A-Z0-9_]*$, at most 32 characters, unique
    category: string, -- same token rules; a free classification token, not an enum
    title: string,
    description: string,
    confirmation: Confirmation, -- how many DISTINCT sources must observe it before it can be confirmed
}

export type EvidenceContent = {
    version: number,
    evidence: { EvidenceDefinition }, -- dense array; array order is the stable display / iteration order
}

export type PlanEntry = {
    id: string,
    category: string,
    title: string,
    description: string,
    distinctSources: number,
}

export type Plan = {
    kind: string,
    version: number,
    order: { string },
    entries: { [string]: PlanEntry },
}

local ID_PATTERN = "^[A-Z][A-Z0-9_]*$"
local CONTENT_FIELDS: { [string]: boolean } = { version = true, evidence = true }
local DEFINITION_FIELDS: { [string]: boolean } = { id = true, category = true, title = true, description = true, confirmation = true }
local CONFIRMATION_FIELDS: { [string]: boolean } = { distinctSources = true }

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value >= min and value <= max and value % 1 == 0
end

-- A content-style token. Also used by EvidenceCore for source ids so both agree on one definition.
function EvidenceCatalog.isToken(value: any): boolean
    return type(value) == "string" and #value >= 1 and #value <= Limits.MaxIdLength and string.match(value, ID_PATTERN) ~= nil
end

-- Non-empty, bounded, valid UTF-8, no control characters (ASCII, DEL and the C1 range U+0080..U+009F).
local function isText(value: any, maxBytes: number): boolean
    if type(value) ~= "string" or #value < 1 or #value > maxBytes then
        return false
    end
    if utf8.len(value) == nil then
        return false
    end
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

-- Dense array (keys exactly 1..count, plain table) of at most `maxCount` elements, or nil.
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

-- Returns nil or a code for one definition (step 1).
local function checkDefinition(entry: any): string?
    if not isPlainTable(entry) then
        return "invalid_definition_entry"
    end
    if not hasOnlyFields(entry, DEFINITION_FIELDS) then
        return "unexpected_definition_field"
    end
    if not EvidenceCatalog.isToken(entry.id) then
        return "invalid_evidence_id"
    end
    if not EvidenceCatalog.isToken(entry.category) then
        return "invalid_category"
    end
    if not isText(entry.title, Limits.MaxTitleBytes) then
        return "invalid_title"
    end
    if not isText(entry.description, Limits.MaxDescriptionBytes) then
        return "invalid_description"
    end
    local confirmation = entry.confirmation
    if not isPlainTable(confirmation) then
        return "invalid_confirmation"
    end
    if not hasOnlyFields(confirmation, CONFIRMATION_FIELDS) then
        return "unexpected_confirmation_field"
    end
    if not isInteger(confirmation.distinctSources, 1, Limits.MaxDistinctSources) then
        return "invalid_distinct_sources"
    end
    return nil
end

-- Returns (true, nil, nil) or (false, code, subject). `subject` is the offending evidence id when there is one. Codes are
-- stable, meant for server logs, and are what the specs assert.
function EvidenceCatalog.validate(content: any): (boolean, string?, string?)
    if not isPlainTable(content) then
        return false, "invalid_content_table", nil
    end
    if not hasOnlyFields(content, CONTENT_FIELDS) then
        return false, "unexpected_content_field", nil
    end
    if not isInteger(content.version, 1, Limits.MaxContentVersion) then
        return false, "invalid_content_version", nil
    end
    local count = denseArrayLength(content.evidence, Limits.MaxEvidence)
    if count == nil then
        return false, "invalid_evidence_list", nil
    end
    if count < 1 then
        return false, "empty_catalog", nil
    end
    for index = 1, count do
        local code = checkDefinition(content.evidence[index])
        if code ~= nil then
            local entry = content.evidence[index]
            local subject: string? = nil
            if type(entry) == "table" and EvidenceCatalog.isToken(entry.id) then
                subject = entry.id
            end
            return false, code, subject
        end
    end
    local seen: { [string]: boolean } = {}
    for index = 1, count do
        local id: string = content.evidence[index].id
        if seen[id] then
            return false, "duplicate_evidence_id", id
        end
        seen[id] = true
    end
    return true, nil, nil
end

-- Returns (plan, nil, nil) or (nil, code, subject) exactly like `validate`. The plan is a frozen deep copy: mutating the
-- caller's content afterwards can never reach it, and the caller's table is never frozen or modified.
function EvidenceCatalog.compile(content: any): (Plan?, string?, string?)
    local ok, code, subject = EvidenceCatalog.validate(content)
    if not ok then
        return nil, code, subject
    end
    local order: { string } = {}
    local entries: { [string]: PlanEntry } = {}
    for index = 1, #content.evidence do
        local definition = content.evidence[index]
        order[index] = definition.id
        entries[definition.id] = table.freeze({
            id = definition.id,
            category = definition.category,
            title = definition.title,
            description = definition.description,
            distinctSources = definition.confirmation.distinctSources,
        })
    end
    return table.freeze({
        kind = EvidenceCatalog.PlanKind,
        version = content.version,
        order = table.freeze(order),
        entries = table.freeze(entries),
    }), nil, nil
end

return EvidenceCatalog
