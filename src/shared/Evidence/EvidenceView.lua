--!strict
-- Client mirror of the server's evidence snapshot (TTL-11C; pure, Lune-tested). The server (EvidenceCore through
-- EvidenceRuntime) is the only authority: this module only validates, orders and describes the last accepted
-- `EvidenceSnapshot`. It never creates, discovers or confirms anything and invents no entry, count or progress: what is not
-- in an accepted snapshot is not shown.
--
-- Snapshot shape (TTL-11B, produced by EvidenceRuntime):
--   { v = 1, revision = integer >= 0, total = integer?, evidence = { { id, title, category, state, sources, required } } }
-- Privacy (enforced by the server and defended here): only DISCOVERED evidence is ever listed, so an entry in state
-- UNKNOWN is malformed and rejects the whole payload. `total` is the number of evidence definitions in the mission and may
-- be absent; the view then reports no total instead of inventing one. `id` is a stable key for diffing only and is never part
-- of what the HUD displays; source ids, contributors and locations are not in the snapshot and any unknown field is dropped.
--
-- Revision rule (same contract as ObjectiveView): `lastRevision` starts at -1; a payload is applied only when its revision is
-- strictly greater. An equal revision is a harmless duplicate (a pull racing a broadcast), a lower one is stale; neither
-- changes anything. A malformed payload is rejected as a whole and the last valid state is kept.
--
-- The interface (new / applySnapshot / reset / getRevision / isSynced / getViewModel and `Status`) is deliberately the same
-- shape as ObjectiveView, so the existing pure ObjectiveController drives it unchanged through dependency injection.
-- Time-free and Roblox-free: no clock, no remote, no Instance.

local EvidenceView = {}

EvidenceView.SnapshotVersion = 1
EvidenceView.InitialRevision = -1

-- Defensive bounds mirroring the server limits (EvidenceCatalog / EvidenceCore) with a little slack; not a second source of
-- truth, only a guard against a corrupt payload reaching the UI.
EvidenceView.Limits = table.freeze({
    MaxEvidence = 32,
    MaxIdLength = 32,
    MaxTitleBytes = 64,
    MaxCategoryLength = 32,
    MaxSources = 16,
    MaxRequired = 8,
})

EvidenceView.Status = table.freeze({
    Applied = "applied",
    Duplicate = "duplicate",
    Stale = "stale",
    Malformed = "malformed",
})
local Status = EvidenceView.Status

EvidenceView.States = table.freeze({
    Observed = "OBSERVED",
    Confirmed = "CONFIRMED",
})

EvidenceView.EventKinds = table.freeze({
    Discovered = "DISCOVERED", -- a new entry appeared
    Confirmed = "CONFIRMED", -- an entry went from OBSERVED to CONFIRMED
})
local EventKinds = EvidenceView.EventKinds

export type Entry = {
    id: string, -- stable key only; never displayed
    title: string,
    category: string, -- a token such as "ENVIRONMENTAL"; presentation formats it
    state: string, -- OBSERVED | CONFIRMED
    sources: number, -- distinct sources that corroborated it so far
    required: number, -- distinct sources needed to confirm
    isConfirmed: boolean,
    hasCorroboration: boolean, -- more than one source is needed, so "sources/required" is meaningful
}

export type Event = { kind: string, id: string, title: string }

export type ViewModel = {
    revision: number,
    synced: boolean, -- at least one valid snapshot was accepted
    discovered: number, -- entries in the journal
    confirmed: number,
    total: number?, -- evidence definitions in the mission, only when the server supplied it
    entries: { Entry }, -- server order
}

local View = {}
View.__index = View

export type View = typeof(setmetatable({} :: { [string]: any }, View))

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value >= min and value <= max and value % 1 == 0
end

local function isPlainTable(value: any): boolean
    return type(value) == "table" and getmetatable(value) == nil
end

-- Non-empty, bounded, valid UTF-8, no control characters (ASCII, DEL and the C1 range).
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

local function isToken(value: any, maxLength: number): boolean
    return type(value) == "string" and #value >= 1 and #value <= maxLength and string.match(value, "^[A-Z][A-Z0-9_]*$") ~= nil
end

local function denseLength(value: any, max: number): number?
    if not isPlainTable(value) then
        return nil
    end
    local count = 0
    for key in pairs(value) do
        if not isInteger(key, 1, max) then
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

local function parseEntry(raw: any): Entry?
    local Limits = EvidenceView.Limits
    if not isPlainTable(raw) then
        return nil
    end
    if not isToken(raw.id, Limits.MaxIdLength) or not isText(raw.title, Limits.MaxTitleBytes) or not isToken(raw.category, Limits.MaxCategoryLength) then
        return nil
    end
    -- UNKNOWN (undiscovered) evidence must never reach the client: it is malformed here, not merely hidden.
    if raw.state ~= EvidenceView.States.Observed and raw.state ~= EvidenceView.States.Confirmed then
        return nil
    end
    if not isInteger(raw.required, 1, Limits.MaxRequired) or not isInteger(raw.sources, 1, Limits.MaxSources) then
        return nil
    end
    local state: string = raw.state
    if state == EvidenceView.States.Confirmed and raw.sources < raw.required then
        return nil -- confirmed without enough corroboration contradicts the server model; do not show it
    end
    return {
        id = raw.id,
        title = raw.title,
        category = raw.category,
        state = state,
        sources = raw.sources,
        required = raw.required,
        isConfirmed = state == EvidenceView.States.Confirmed,
        hasCorroboration = raw.required > 1,
    }
end

-- Validates a whole payload. Returns (revision, total or nil, entries) or nil.
local function parseSnapshot(payload: any): (number?, number?, { Entry }?)
    if not isPlainTable(payload) then
        return nil, nil, nil
    end
    if payload.v ~= EvidenceView.SnapshotVersion then
        return nil, nil, nil
    end
    if not isInteger(payload.revision, 0, 9007199254740991) then
        return nil, nil, nil
    end
    local count = denseLength(payload.evidence, EvidenceView.Limits.MaxEvidence)
    if count == nil then
        return nil, nil, nil
    end
    local total: number? = nil
    if payload.total ~= nil then
        if not isInteger(payload.total, 1, EvidenceView.Limits.MaxEvidence) or payload.total < count then
            return nil, nil, nil
        end
        total = payload.total
    end
    local entries: { Entry } = {}
    local seen: { [string]: boolean } = {}
    for index = 1, count do
        local entry = parseEntry(payload.evidence[index])
        if entry == nil or seen[entry.id] then
            return nil, nil, nil
        end
        seen[entry.id] = true
        entries[index] = entry
    end
    return payload.revision, total, entries
end

-- Transitions worth telling the player about, derived from two accepted snapshots (the first snapshot is a baseline and
-- produces none, so evidence that was already known is never announced again).
local function diff(previous: { Entry }, current: { Entry }): { Event }
    local before: { [string]: Entry } = {}
    for _, entry in ipairs(previous) do
        before[entry.id] = entry
    end
    local events: { Event } = {}
    for _, entry in ipairs(current) do
        local old = before[entry.id]
        if old == nil then
            table.insert(events, { kind = EventKinds.Discovered, id = entry.id, title = entry.title })
        elseif not old.isConfirmed and entry.isConfirmed then
            table.insert(events, { kind = EventKinds.Confirmed, id = entry.id, title = entry.title })
        end
    end
    return events
end

function EvidenceView.new(): View
    return setmetatable({
        _revision = EvidenceView.InitialRevision,
        _entries = {},
        _total = nil,
        _synced = false,
    }, View)
end

-- Applies one server payload. Returns (status, events): `applied` carries the transition events, every other status changes
-- nothing and carries none.
function View.applySnapshot(self: View, payload: any): (string, { Event })
    local data: any = self
    local revision, total, entries = parseSnapshot(payload)
    if revision == nil or entries == nil then
        return Status.Malformed, {}
    end
    if revision == data._revision then
        return Status.Duplicate, {}
    end
    if revision < data._revision then
        return Status.Stale, {}
    end
    local events: { Event } = {}
    if data._synced then
        events = diff(data._entries, entries)
    end
    data._revision = revision
    data._entries = entries
    data._total = total
    data._synced = true
    return Status.Applied, events
end

function View.reset(self: View)
    local data: any = self
    data._revision = EvidenceView.InitialRevision
    data._entries = {}
    data._total = nil
    data._synced = false
end

function View.getRevision(self: View): number
    return (self :: any)._revision
end

function View.isSynced(self: View): boolean
    return (self :: any)._synced
end

-- A fresh copy: callers (UI) can never alter the mirror.
function View.getViewModel(self: View): ViewModel
    local data: any = self
    local entries: { Entry } = {}
    local confirmed = 0
    for index, entry in ipairs(data._entries) do
        entries[index] = table.clone(entry)
        if entry.isConfirmed then
            confirmed = confirmed + 1
        end
    end
    return {
        revision = data._revision,
        synced = data._synced,
        discovered = #entries,
        confirmed = confirmed,
        total = data._total,
        entries = entries,
    }
end

return EvidenceView
