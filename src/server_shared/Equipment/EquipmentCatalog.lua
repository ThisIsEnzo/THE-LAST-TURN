--!strict
-- Pure equipment definition validation/compiler. No Roblox APIs or mutable caller-owned data escape the compiler.
local EquipmentCatalog = {}
EquipmentCatalog.PlanKind = "EquipmentCatalogPlan"
EquipmentCatalog.Limits = table.freeze({
    MaxContentVersion = 2147483647,
    MaxItems = 16,
    MaxIdLength = 32,
    MaxTitleBytes = 48,
    MaxDescriptionBytes = 140,
})
local Limits = EquipmentCatalog.Limits
local CATEGORIES: { [string]: boolean } = table.freeze({
    DETECTION = true, OBSERVATION = true, COMMUNICATION = true, PROTECTION = true, UTILITY = true,
})
local ACTIONS: { [string]: boolean } = table.freeze({ SCAN = true, CAPTURE = true, TOGGLE_LIGHT = true })
local CONTENT_FIELDS = { version = true, items = true }
local ITEM_FIELDS = { id = true, category = true, action = true, title = true, description = true }

export type ItemDefinition = { id: string, category: string, action: string, title: string, description: string }
export type Content = { version: number, items: { ItemDefinition } }
export type Plan = { kind: string, version: number, order: { string }, entries: { [string]: ItemDefinition } }

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
        and value >= min and value <= max and value % 1 == 0
end
local function isPlainTable(value: any): boolean
    return type(value) == "table" and getmetatable(value) == nil
end
local function hasOnlyFields(value: any, allowed: { [string]: boolean }): boolean
    for key in pairs(value) do
        if type(key) ~= "string" or allowed[key] ~= true then return false end
    end
    return true
end
local function denseArrayLength(value: any, maxCount: number): number?
    if not isPlainTable(value) then return nil end
    local count = 0
    for key in pairs(value) do
        if not isInteger(key, 1, maxCount) then return nil end
        count += 1
    end
    for index = 1, count do
        if value[index] == nil then return nil end
    end
    return count
end
local function isToken(value: any): boolean
    return type(value) == "string" and #value >= 1 and #value <= Limits.MaxIdLength
        and string.match(value, "^[A-Z][A-Z0-9_]*$") ~= nil
end
local function isText(value: any, maxBytes: number): boolean
    if type(value) ~= "string" or #value < 1 or #value > maxBytes or utf8.len(value) == nil then return false end
    for _, codepoint in utf8.codes(value) do
        if codepoint <= 0x1F or (codepoint >= 0x7F and codepoint <= 0x9F) then return false end
    end
    return true
end
local function checkItem(item: any): string?
    if not isPlainTable(item) then return "invalid_item_entry" end
    if not hasOnlyFields(item, ITEM_FIELDS) then return "unexpected_item_field" end
    if not isToken(item.id) then return "invalid_item_id" end
    if type(item.category) ~= "string" or CATEGORIES[item.category] ~= true then return "invalid_category" end
    if type(item.action) ~= "string" or ACTIONS[item.action] ~= true then return "invalid_action" end
    if not isText(item.title, Limits.MaxTitleBytes) then return "invalid_title" end
    if not isText(item.description, Limits.MaxDescriptionBytes) then return "invalid_description" end
    return nil
end

function EquipmentCatalog.validate(content: any): (boolean, string?, string?)
    if not isPlainTable(content) then return false, "invalid_content_table", nil end
    if not hasOnlyFields(content, CONTENT_FIELDS) then return false, "unexpected_content_field", nil end
    if not isInteger(content.version, 1, Limits.MaxContentVersion) then return false, "invalid_content_version", nil end
    local count = denseArrayLength(content.items, Limits.MaxItems)
    if count == nil then return false, "invalid_items_list", nil end
    if count < 1 then return false, "empty_catalog", nil end
    for index = 1, count do
        local item = content.items[index]
        local code = checkItem(item)
        if code ~= nil then
            local subject: string? = nil
            if type(item) == "table" and isToken(item.id) then subject = item.id end
            return false, code, subject
        end
    end
    local seen: { [string]: boolean } = {}
    for index = 1, count do
        local id: string = content.items[index].id
        if seen[id] then return false, "duplicate_item_id", id end
        seen[id] = true
    end
    return true, nil, nil
end

function EquipmentCatalog.compile(content: any): (Plan?, string?, string?)
    local ok, code, subject = EquipmentCatalog.validate(content)
    if not ok then return nil, code, subject end
    local order: { string } = {}
    local entries: { [string]: ItemDefinition } = {}
    for index = 1, #content.items do
        local item = content.items[index]
        order[index] = item.id
        entries[item.id] = table.freeze({
            id = item.id, category = item.category, action = item.action,
            title = item.title, description = item.description,
        })
    end
    return table.freeze({
        kind = EquipmentCatalog.PlanKind, version = content.version,
        order = table.freeze(order), entries = table.freeze(entries),
    }), nil, nil
end

return EquipmentCatalog
