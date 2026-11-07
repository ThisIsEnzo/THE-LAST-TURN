--!strict
-- Pure mission configuration rules (no Roblox services, Instances, timers or globals). Given a validated seed,
-- session identity and a static content table it deterministically builds ONE immutable MissionConfig.
-- MissionConfigService (MISSION) drives it. Same seed + same content + same inputs => the same configuration,
-- regardless of the order of the entries in the content table.
--
-- v1 selects only the location because it is the only content that exists. Entities, objectives, modifiers and
-- clue parameters are added together with their content and consumers (each as a new field plus a new stage
-- label, so earlier selections never change). The configuration lives only in memory on one MISSION server:
-- it is never persisted or sent between places, so adding fields needs no migration.
--
-- The random source is injected (`create(input, random)`, the same convention as LaunchCoordinator's adapters):
-- Roblox and Lune resolve `require` differently, and every pure module of this project is dependency free so
-- that Lune can load it by path. The service passes the real SeededRandom module; tests pass it too.

export type LocationDefinition = { id: string }

export type ContentTable = {
    version: number, -- integer in [1, 2147483647]; bump whenever the content changes
    locations: { LocationDefinition }, -- dense array, 1 .. MaxLocations entries
}

export type MissionConfig = {
    schemaVersion: number,
    contentVersion: number,
    missionId: string,
    missionType: string,
    seed: number, -- server-only; never replicate it (seed + content reveals hidden mission facts)
    locationId: string,
}

export type CreateInput = {
    seed: number,
    missionId: string,
    missionType: string,
    content: ContentTable,
}

local MissionConfigCore = {}

MissionConfigCore.SchemaVersion = 1
MissionConfigCore.MaxLocations = 64
MissionConfigCore.MaxContentVersion = 2147483647

-- Stream labels, one per selection stage. A later stage adds its own label and never reuses an existing one.
-- Other systems derive their own streams from the same seed with their own namespaced labels
-- (for example "evidence.placement").
MissionConfigCore.Stages = table.freeze({
    LOCATION = "config.location",
})

local EXPECTED_CONTENT_FIELDS: { [string]: boolean } = {
    version = true,
    locations = true,
}

local EXPECTED_LOCATION_FIELDS: { [string]: boolean } = {
    id = true,
}

local EXPECTED_INPUT_FIELDS: { [string]: boolean } = {
    seed = true,
    missionId = true,
    missionType = true,
    content = true,
}

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value >= min and value <= max and value % 1 == 0
end

local function isToken(value: any, maxLength: number, pattern: string): boolean
    return type(value) == "string" and #value >= 1 and #value <= maxLength and string.match(value, pattern) ~= nil
end

local function isPlainTable(value: any): boolean
    return type(value) == "table" and getmetatable(value) == nil
end

-- Returns the element count of a dense array (1..count with no holes and no other keys), or nil.
local function denseArrayLength(value: any, maxCount: number): number?
    if not isPlainTable(value) then
        return nil
    end
    local count = 0
    for key in pairs(value) do
        if not isInteger(key, 1, maxCount) then
            return nil
        end
        count += 1
    end
    for index = 1, count do
        if value[index] == nil then
            return nil
        end
    end
    return count
end

-- Validates a static content table without modifying it. Returns (true, nil) or (false, code). Codes are for
-- server logs only: invalid_content_table, unexpected_content_field, invalid_content_version, invalid_locations,
-- empty_locations, invalid_location_entry, unexpected_location_field, invalid_location_id, duplicate_location_id.
function MissionConfigCore.validateContent(content: any): (boolean, string?)
    if not isPlainTable(content) then
        return false, "invalid_content_table"
    end
    for key in pairs(content) do
        if type(key) ~= "string" or not EXPECTED_CONTENT_FIELDS[key] then
            return false, "unexpected_content_field"
        end
    end
    if not isInteger(content.version, 1, MissionConfigCore.MaxContentVersion) then
        return false, "invalid_content_version"
    end
    local count = denseArrayLength(content.locations, MissionConfigCore.MaxLocations)
    if count == nil then
        return false, "invalid_locations"
    end
    if count < 1 then
        return false, "empty_locations"
    end
    local seen: { [string]: boolean } = {}
    for index = 1, count do
        local entry = content.locations[index]
        if not isPlainTable(entry) then
            return false, "invalid_location_entry"
        end
        for key in pairs(entry) do
            if type(key) ~= "string" or not EXPECTED_LOCATION_FIELDS[key] then
                return false, "unexpected_location_field"
            end
        end
        if not isToken(entry.id, 32, "^[A-Z][A-Z0-9_]*$") then
            return false, "invalid_location_id"
        end
        if seen[entry.id] then
            return false, "duplicate_location_id"
        end
        seen[entry.id] = true
    end
    return true, nil
end

-- Builds the mission configuration. `random` is the SeededRandom module (needs `isValidSeed(value)` and
-- `new(seed, label)` returning a stream with `nextInteger(min, max)`); a missing or malformed dependency is a
-- programming error and raises. Returns (true, frozenConfig) or (false, code), where code is one of
-- invalid_input, unexpected_input_field, invalid_seed, invalid_mission_id, invalid_mission_type, or a
-- validateContent code (propagated unchanged). Never mutates or retains the input or the content table.
function MissionConfigCore.create(input: any, random: any): (boolean, any)
    if type(random) ~= "table" or type(random.isValidSeed) ~= "function" or type(random.new) ~= "function" then
        error("MissionConfigCore.create: a random source with isValidSeed and new is required", 2)
    end
    if not isPlainTable(input) then
        return false, "invalid_input"
    end
    for key in pairs(input) do
        if type(key) ~= "string" or not EXPECTED_INPUT_FIELDS[key] then
            return false, "unexpected_input_field"
        end
    end
    if not random.isValidSeed(input.seed) then
        return false, "invalid_seed"
    end
    if not isToken(input.missionId, 64, "^[%w%-]+$") then
        return false, "invalid_mission_id"
    end
    if not isToken(input.missionType, 32, "^[%w_%-]+$") then
        return false, "invalid_mission_type"
    end
    local contentOk, contentCode = MissionConfigCore.validateContent(input.content)
    if not contentOk then
        return false, contentCode
    end

    -- Canonical order: ids sorted ascending, so the result never depends on how the content table is ordered.
    -- Ids are restricted to [A-Z0-9_], which makes the ordering identical in every environment.
    local locations = input.content.locations
    local ids: { string } = {}
    for index = 1, #locations do
        ids[index] = locations[index].id
    end
    table.sort(ids)

    local stream = random.new(input.seed, MissionConfigCore.Stages.LOCATION)
    local locationId = ids[stream:nextInteger(1, #ids)]

    return true,
        table.freeze({
            schemaVersion = MissionConfigCore.SchemaVersion,
            contentVersion = input.content.version,
            missionId = input.missionId,
            missionType = input.missionType,
            seed = input.seed,
            locationId = locationId,
        })
end

return MissionConfigCore
