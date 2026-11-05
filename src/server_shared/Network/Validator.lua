--!strict
-- Server-side payload validation. Pure Luau: no Roblox services, so it can be unit tested.
--
-- Fail-closed: anything that does not exactly match the schema is rejected.
--   * Objects reject unexpected fields and non-string keys; required fields must be present.
--   * Strings require an explicit maxLength (byte length) and must be valid UTF-8.
--   * Numbers require explicit min/max, reject NaN and infinities; integers reject fractions.
--   * Extra call arguments are rejected.
-- Errors returned here are for server logs only and must never be sent back to the client.

export type Spec = { [string]: any }

local Validator = {}

local function assertBound(value: any, label: string)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        error("Validator schema error: " .. label .. " must be a finite number", 3)
    end
end

function Validator.string(options: { minLength: number?, maxLength: number }): Spec
    assertBound(options.maxLength, "maxLength")
    local minLength = options.minLength or 0
    assertBound(minLength, "minLength")
    return { kind = "string", minLength = minLength, maxLength = options.maxLength }
end

function Validator.number(options: { min: number, max: number, integer: boolean? }): Spec
    assertBound(options.min, "min")
    assertBound(options.max, "max")
    return { kind = "number", min = options.min, max = options.max, integer = options.integer == true }
end

function Validator.integer(options: { min: number, max: number }): Spec
    return Validator.number({ min = options.min, max = options.max, integer = true })
end

function Validator.boolean(): Spec
    return { kind = "boolean" }
end

function Validator.enum(values: { string }): Spec
    local set: { [string]: boolean } = {}
    for _, value in ipairs(values) do
        set[value] = true
    end
    return { kind = "enum", values = set }
end

function Validator.object(fields: { [string]: Spec }): Spec
    return { kind = "object", fields = fields }
end

-- Marks a field/argument as optional (nil accepted). Present values are still fully validated.
function Validator.optional(inner: Spec): Spec
    local copy: Spec = {}
    for key, value in pairs(inner) do
        copy[key] = value
    end
    copy.optional = true
    return copy
end

local function validateValue(spec: Spec, value: any, path: string): (boolean, any)
    if value == nil then
        if spec.optional == true then
            return true, nil
        end
        return false, path .. ": missing required value"
    end

    local kind = spec.kind
    if kind == "string" then
        if type(value) ~= "string" then
            return false, path .. ": expected string"
        end
        if utf8.len(value) == nil then
            return false, path .. ": invalid UTF-8"
        end
        local length = #value
        if length < spec.minLength or length > spec.maxLength then
            return false, path .. ": string length out of bounds"
        end
        return true, value
    elseif kind == "number" then
        if type(value) ~= "number" then
            return false, path .. ": expected number"
        end
        if value ~= value or value == math.huge or value == -math.huge then
            return false, path .. ": non-finite number"
        end
        if value < spec.min or value > spec.max then
            return false, path .. ": number out of bounds"
        end
        if spec.integer and value % 1 ~= 0 then
            return false, path .. ": expected integer"
        end
        return true, value
    elseif kind == "boolean" then
        if type(value) ~= "boolean" then
            return false, path .. ": expected boolean"
        end
        return true, value
    elseif kind == "enum" then
        if type(value) ~= "string" or spec.values[value] ~= true then
            return false, path .. ": not an allowed value"
        end
        return true, value
    elseif kind == "object" then
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return false, path .. ": expected plain table"
        end
        local fields: { [string]: Spec } = spec.fields
        for key in pairs(value) do
            if type(key) ~= "string" then
                return false, path .. ": non-string key"
            end
            if fields[key] == nil then
                return false, path .. ": unexpected field '" .. string.sub(key, 1, 32) .. "'"
            end
        end
        local cleaned: { [string]: any } = {}
        for name, fieldSpec in pairs(fields) do
            local ok, result = validateValue(fieldSpec, (value :: any)[name], path .. "." .. name)
            if not ok then
                return false, result
            end
            cleaned[name] = result
        end
        return true, cleaned
    end

    -- Unknown spec kind is a programmer error: fail closed.
    return false, path .. ": unsupported schema kind"
end

-- Validates a single value against a spec. Returns (true, sanitizedValue) or (false, reason).
function Validator.validate(spec: Spec, value: any): (boolean, any)
    return validateValue(spec, value, "value")
end

-- Validates remote call arguments (excluding the Player). Returns (true, sanitizedArgs) or
-- (false, reason). More arguments than specs are rejected.
function Validator.validateArguments(argSpecs: { Spec }, ...: any): (boolean, any)
    local count = select("#", ...)
    if count > #argSpecs then
        return false, "too many arguments"
    end
    local args = { ... }
    local sanitized: { any } = {}
    for index, spec in ipairs(argSpecs) do
        local ok, result = validateValue(spec, args[index], "arg" .. index)
        if not ok then
            return false, result
        end
        sanitized[index] = result
    end
    return true, sanitized
end

return Validator
