--!strict
-- Client mirror of the server's objective snapshot (TTL-09C; pure, Lune-tested). The server (ObjectiveCore through
-- ObjectiveRuntime) is the only authority: this module only validates, orders and describes the last accepted
-- `ObjectiveSnapshot`. It never creates, completes, fails or changes an objective and invents no state or progress: what
-- is not in an accepted snapshot is not shown.
--
-- Snapshot shape (design 8.3, produced by ObjectiveCore:getSnapshot):
--   { v = 1, revision = integer >= 0, objectives = { { id, title, description, importance, state, filled, required,
--     slots = { { label, filled } } } } }
-- Hidden objectives are omitted by the server until they are revealed; the client renders exactly the entries it is
-- given, in the server's order, and a later snapshot is always authoritative for what is present.
--
-- Revision rule: `lastRevision` starts at -1 (the first server snapshot has revision 0). A payload is applied only when
-- its revision is strictly greater than the last accepted one: an equal revision is a harmless duplicate (e.g. a pull
-- racing a broadcast) and a lower one is stale; neither changes anything. A malformed payload is rejected as a whole and
-- the last valid state is kept (never a half-applied snapshot).
--
-- Time-free and Roblox-free: there is no clock, no remote and no Instance in here.

local ObjectiveView = {}

ObjectiveView.SnapshotVersion = 1
ObjectiveView.InitialRevision = -1

-- Defensive bounds. They mirror the server limits (ObjectiveGraph.Limits) with a little slack and exist only to keep a
-- corrupt payload from reaching the UI; they are not a second source of truth.
ObjectiveView.Limits = table.freeze({
    MaxObjectives = 32,
    MaxSlots = 8,
    MaxIdLength = 32,
    MaxTitleBytes = 64,
    MaxDescriptionBytes = 160,
    MaxLabelBytes = 48,
})

ObjectiveView.Status = table.freeze({
    Applied = "applied",
    Duplicate = "duplicate",
    Stale = "stale",
    Malformed = "malformed",
})
local Status = ObjectiveView.Status

local STATES: { [string]: boolean } = {
    LOCKED = true,
    AVAILABLE = true,
    IN_PROGRESS = true,
    COMPLETED = true,
    FAILED = true,
    CANCELLED = true,
}

ObjectiveView.EventKinds = table.freeze({
    Unlocked = "UNLOCKED", -- became actionable (from LOCKED, or newly present and actionable)
    Completed = "COMPLETED",
    Failed = "FAILED",
    Cancelled = "CANCELLED",
})
local EventKinds = ObjectiveView.EventKinds

export type Slot = { label: string, filled: boolean }

export type Entry = {
    id: string,
    title: string,
    description: string,
    importance: string, -- "REQUIRED" | "OPTIONAL"
    state: string, -- LOCKED | AVAILABLE | IN_PROGRESS | COMPLETED | FAILED | CANCELLED
    filled: number,
    required: number,
    slots: { Slot },
    isRequired: boolean,
    isOptional: boolean,
    isActionable: boolean, -- AVAILABLE or IN_PROGRESS: the team can work on it now
    isLocked: boolean,
    isTerminal: boolean, -- COMPLETED, FAILED or CANCELLED
    hasProgress: boolean, -- more than one contribution is needed, so "filled/required" is meaningful
}

export type Event = { kind: string, id: string, title: string, importance: string }

export type ViewModel = {
    revision: number,
    synced: boolean, -- at least one valid snapshot was accepted
    entries: { Entry }, -- server order
    requiredDone: number,
    requiredTotal: number,
}

local View = {}
View.__index = View

export type View = typeof(setmetatable({} :: { [string]: any }, View))

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value >= min and value <= max and value % 1 == 0
end

-- Non-empty, bounded, valid UTF-8, no control characters. Descriptions may be empty for forward compatibility.
local function isText(value: any, maxBytes: number, allowEmpty: boolean): boolean
    if type(value) ~= "string" or #value > maxBytes or (#value == 0 and not allowEmpty) then
        return false
    end
    if utf8.len(value) == nil then
        return false
    end
    return string.find(value, "%c") == nil
end

local function isPlainTable(value: any): boolean
    return type(value) == "table" and getmetatable(value) == nil
end

-- Dense array of at most `max` elements, or nil.
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
    local Limits = ObjectiveView.Limits
    if not isPlainTable(raw) then
        return nil
    end
    if not isText(raw.id, Limits.MaxIdLength, false) or not isText(raw.title, Limits.MaxTitleBytes, false) then
        return nil
    end
    if not isText(raw.description, Limits.MaxDescriptionBytes, true) then
        return nil
    end
    if raw.importance ~= "REQUIRED" and raw.importance ~= "OPTIONAL" then
        return nil
    end
    if type(raw.state) ~= "string" or not STATES[raw.state] then
        return nil
    end
    if not isInteger(raw.required, 1, Limits.MaxSlots) or not isInteger(raw.filled, 0, raw.required) then
        return nil
    end
    local slotCount = denseLength(raw.slots, Limits.MaxSlots)
    if slotCount == nil or slotCount ~= raw.required then
        return nil
    end
    local slots: { Slot } = {}
    local filledSlots = 0
    for index = 1, slotCount do
        local slot = raw.slots[index]
        if not isPlainTable(slot) or not isText(slot.label, Limits.MaxLabelBytes, false) or type(slot.filled) ~= "boolean" then
            return nil
        end
        if slot.filled then
            filledSlots = filledSlots + 1
        end
        slots[index] = { label = slot.label, filled = slot.filled }
    end
    if filledSlots ~= raw.filled then
        return nil -- progress that disagrees with its own slots is not shown (nothing is fabricated)
    end
    local state: string = raw.state
    return {
        id = raw.id,
        title = raw.title,
        description = raw.description,
        importance = raw.importance,
        state = state,
        filled = raw.filled,
        required = raw.required,
        slots = slots,
        isRequired = raw.importance == "REQUIRED",
        isOptional = raw.importance == "OPTIONAL",
        isActionable = state == "AVAILABLE" or state == "IN_PROGRESS",
        isLocked = state == "LOCKED",
        isTerminal = state == "COMPLETED" or state == "FAILED" or state == "CANCELLED",
        hasProgress = raw.required > 1,
    }
end

-- Validates a whole payload. Returns (revision, entries) or nil.
local function parseSnapshot(payload: any): (number?, { Entry }?)
    if not isPlainTable(payload) then
        return nil, nil
    end
    if payload.v ~= ObjectiveView.SnapshotVersion then
        return nil, nil
    end
    if not isInteger(payload.revision, 0, 9007199254740991) then
        return nil, nil
    end
    local count = denseLength(payload.objectives, ObjectiveView.Limits.MaxObjectives)
    if count == nil then
        return nil, nil
    end
    local entries: { Entry } = {}
    local seen: { [string]: boolean } = {}
    for index = 1, count do
        local entry = parseEntry(payload.objectives[index])
        if entry == nil or seen[entry.id] then
            return nil, nil
        end
        seen[entry.id] = true
        entries[index] = entry
    end
    return payload.revision, entries
end

-- Transitions worth telling the player about, derived from two accepted snapshots (the first snapshot is a baseline and
-- produces none). Entries are compared by id; nothing is derived for entries that did not change.
local function diff(previous: { Entry }, current: { Entry }): { Event }
    local before: { [string]: Entry } = {}
    for _, entry in ipairs(previous) do
        before[entry.id] = entry
    end
    local events: { Event } = {}
    for _, entry in ipairs(current) do
        local old = before[entry.id]
        local kind: string? = nil
        if old == nil then
            if entry.isActionable then
                kind = EventKinds.Unlocked -- a hidden objective was just revealed (or appeared available)
            end
        elseif old.state ~= entry.state then
            if entry.state == "COMPLETED" then
                kind = EventKinds.Completed
            elseif entry.state == "FAILED" then
                kind = EventKinds.Failed
            elseif entry.state == "CANCELLED" then
                kind = EventKinds.Cancelled
            elseif entry.isActionable and old.isLocked then
                kind = EventKinds.Unlocked
            end
        end
        if kind ~= nil then
            table.insert(events, { kind = kind, id = entry.id, title = entry.title, importance = entry.importance })
        end
    end
    return events
end

function ObjectiveView.new(): View
    return setmetatable({
        _revision = ObjectiveView.InitialRevision,
        _entries = {},
        _synced = false,
    }, View)
end

-- Applies one server payload. Returns (status, events): `applied` carries the transition events, every other status
-- changes nothing and carries none.
function View.applySnapshot(self: View, payload: any): (string, { Event })
    local data: any = self
    local revision, entries = parseSnapshot(payload)
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
    data._synced = true
    return Status.Applied, events
end

function View.reset(self: View)
    local data: any = self
    data._revision = ObjectiveView.InitialRevision
    data._entries = {}
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
    local requiredDone, requiredTotal = 0, 0
    for index, entry in ipairs(data._entries) do
        local slots: { Slot } = {}
        for slotIndex, slot in ipairs(entry.slots) do
            slots[slotIndex] = { label = slot.label, filled = slot.filled }
        end
        local copy: any = table.clone(entry)
        copy.slots = slots
        entries[index] = copy
        if entry.isRequired then
            requiredTotal = requiredTotal + 1
            if entry.state == "COMPLETED" then
                requiredDone = requiredDone + 1
            end
        end
    end
    return {
        revision = data._revision,
        synced = data._synced,
        entries = entries,
        requiredDone = requiredDone,
        requiredTotal = requiredTotal,
    }
end

-- Compact tracker selection: the entries the team can work on now, in SERVER order (no client-side re-ranking), at most
-- `maxLines`, plus how many further actionable entries did not fit. Locked and finished entries are not tracked.
function ObjectiveView.tracked(viewModel: ViewModel, maxLines: any): ({ Entry }, number)
    local limit = 1
    if type(maxLines) == "number" and maxLines == maxLines and maxLines >= 1 then
        limit = math.floor(maxLines)
    end
    local shown: { Entry } = {}
    local hidden = 0
    for _, entry in ipairs(viewModel.entries) do
        if entry.isActionable then
            if #shown < limit then
                table.insert(shown, entry)
            else
                hidden = hidden + 1
            end
        end
    end
    return shown, hidden
end

return ObjectiveView
