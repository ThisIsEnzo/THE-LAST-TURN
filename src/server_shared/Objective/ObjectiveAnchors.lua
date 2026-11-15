--!strict
-- Pure indexing of authored objective anchors (TTL-10, design decision D5). The Roblox side (ObjectiveService) collects the
-- parts tagged `ObjectivePoint` that live in the Workspace and reads their `PointId` attribute; this module turns that list
-- into a lookup table and reports problems deterministically. It knows nothing about Instances: an "anchor" is any opaque
-- value the caller wants back, so Lune specs drive it with plain tables.
--
-- Rules (fail-closed): a PointId must be a content-style id (`^[A-Z][A-Z0-9_]*$`, at most 32 characters); an id that two
-- anchors claim is ambiguous and therefore resolves to NOTHING (and is listed in `duplicates`); an entry without a valid id
-- or without an anchor is counted in `invalid`. Which ids are required is decided by the objective content and by
-- ObjectiveRuntime (a missing REQUIRED anchor aborts the mission start; a missing OPTIONAL one cancels that objective).

local ObjectiveAnchors = {}

ObjectiveAnchors.Tag = "ObjectivePoint"
ObjectiveAnchors.Attribute = "PointId"
ObjectiveAnchors.MaxIdLength = 32

export type Index = {
    anchors: { [string]: any }, -- PointId -> anchor, only unambiguous ids
    duplicates: { string }, -- ids claimed by more than one anchor, sorted
    invalid: number, -- entries without a valid PointId or without an anchor
}

local function isPointId(value: any): boolean
    return type(value) == "string" and #value >= 1 and #value <= ObjectiveAnchors.MaxIdLength and string.match(value, "^[A-Z][A-Z0-9_]*$") ~= nil
end

-- `candidates` is an array of `{ pointId = any, anchor = any }`. The result does not depend on the order of the array.
function ObjectiveAnchors.index(candidates: any): Index
    local anchors: { [string]: any } = {}
    local counts: { [string]: number } = {}
    local invalid = 0
    if type(candidates) == "table" then
        for _, candidate in ipairs(candidates) do
            if type(candidate) ~= "table" or not isPointId(candidate.pointId) or candidate.anchor == nil then
                invalid = invalid + 1
            else
                local id: string = candidate.pointId
                counts[id] = (counts[id] or 0) + 1
                anchors[id] = candidate.anchor
            end
        end
    end
    local duplicates: { string } = {}
    for id, count in pairs(counts) do
        if count > 1 then
            anchors[id] = nil
            table.insert(duplicates, id)
        end
    end
    table.sort(duplicates)
    return { anchors = anchors, duplicates = duplicates, invalid = invalid }
end

-- The ids from `pointIds` (kept in their given order) that have no usable anchor.
function ObjectiveAnchors.missing(pointIds: { string }, index: Index): { string }
    local missing: { string } = {}
    for _, id in ipairs(pointIds) do
        if index.anchors[id] == nil then
            table.insert(missing, id)
        end
    end
    return missing
end

return ObjectiveAnchors
