--!strict
-- Pure loadout validation and canonical ordering. Input is untrusted and is never mutated.
local LoadoutPolicy = {}
LoadoutPolicy.MaxSlots = 3
LoadoutPolicy.DefaultItems = table.freeze({ "UTILITY_FLASHLIGHT", "EMF_READER" })

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
        and value >= min and value <= max and value % 1 == 0
end
local function isPlainTable(value: any): boolean
    return type(value) == "table" and getmetatable(value) == nil
end
local function denseArrayLength(value: any): number?
    if not isPlainTable(value) then return nil end
    local count = 0
    for key in pairs(value) do
        if not isInteger(key, 1, LoadoutPolicy.MaxSlots) then return nil end
        count += 1
    end
    for index = 1, count do
        if value[index] == nil then return nil end
    end
    return count
end
local function isPlan(plan: any): boolean
    return isPlainTable(plan) and plan.kind == "EquipmentCatalogPlan"
        and isPlainTable(plan.entries) and isPlainTable(plan.order)
end

-- Returns (true, canonicalItems, nil) or (false, nil, stableErrorCode).
-- An explicit empty array is valid and means the player selected no equipment.
function LoadoutPolicy.validate(items: any, plan: any): (boolean, { string }?, string?)
    if not isPlan(plan) then return false, nil, "invalid_catalog_plan" end
    local count = denseArrayLength(items)
    if count == nil then return false, nil, "invalid_loadout_array" end
    local seen: { [string]: boolean } = {}
    local result: { string } = {}
    for index = 1, count do
        local id = items[index]
        if type(id) ~= "string" then return false, nil, "invalid_item_id" end
        if seen[id] then return false, nil, "duplicate_item" end
        if plan.entries[id] == nil then return false, nil, "unknown_item" end
        seen[id] = true
        result[index] = id
    end
    table.sort(result)
    return true, table.freeze(result), nil
end

function LoadoutPolicy.getDefaultLoadout(plan: any): ({ string }?, string?)
    local ok, items, code = LoadoutPolicy.validate(LoadoutPolicy.DefaultItems, plan)
    if not ok then return nil, code end
    return items, nil
end

return LoadoutPolicy
