--!strict
local Harness = require("../Harness")
local Validator = require("../../src/server_shared/Network/Validator")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local payloadSpec = Validator.object({
    protocolVersion = Validator.integer({ min = 1, max = 1000 }),
    buildLabel = Validator.optional(Validator.string({ maxLength = 32 })),
})

local function validArgs(payload: any): boolean
    local ok = Validator.validateArguments({ payloadSpec }, payload)
    return ok
end

test("valid payload with and without optional field", function()
    expectTrue(validArgs({ protocolVersion = 1 }))
    expectTrue(validArgs({ protocolVersion = 1, buildLabel = "abc" }))
end)

test("validated payload is a sanitized copy", function()
    local input = { protocolVersion = 5 }
    local ok, result = Validator.validateArguments({ payloadSpec }, input)
    expectTrue(ok)
    expectEqual(result[1].protocolVersion, 5)
    expectFalse(result[1] == input, "sanitized copy must not alias the input")
end)

test("missing required field is rejected", function()
    expectFalse(validArgs({}))
    expectFalse(validArgs({ buildLabel = "x" }))
end)

test("unexpected fields are rejected", function()
    expectFalse(validArgs({ protocolVersion = 1, extra = true }))
    expectFalse(validArgs({ protocolVersion = 1, userId = 123 }), "client-supplied identity must be rejected")
end)

test("non-string keys are rejected", function()
    expectFalse(validArgs({ protocolVersion = 1, [1] = "x" }))
end)

test("incorrect argument types are rejected", function()
    expectFalse(validArgs(nil))
    expectFalse(validArgs("string"))
    expectFalse(validArgs(5))
    expectFalse(validArgs(true))
    expectFalse(validArgs({ protocolVersion = "1" }))
    expectFalse(validArgs({ protocolVersion = 1, buildLabel = 5 }))
    expectFalse(validArgs(setmetatable({ protocolVersion = 1 }, {})))
end)

test("extra call arguments are rejected", function()
    expectFalse((Validator.validateArguments({ payloadSpec }, { protocolVersion = 1 }, "extra")))
    expectFalse((Validator.validateArguments({}, 1)))
    expectTrue((Validator.validateArguments({})))
end)

test("missing required argument is rejected; optional argument may be nil", function()
    expectFalse((Validator.validateArguments({ payloadSpec })))
    expectTrue((Validator.validateArguments({ Validator.optional(payloadSpec) })))
end)

test("numeric boundaries are inclusive", function()
    expectTrue(validArgs({ protocolVersion = 1 }))
    expectTrue(validArgs({ protocolVersion = 1000 }))
    expectFalse(validArgs({ protocolVersion = 0 }))
    expectFalse(validArgs({ protocolVersion = 1001 }))
    expectFalse(validArgs({ protocolVersion = -1 }))
end)

test("fractional, NaN and infinite numbers are rejected", function()
    expectFalse(validArgs({ protocolVersion = 1.5 }))
    expectFalse(validArgs({ protocolVersion = 0 / 0 }))
    expectFalse(validArgs({ protocolVersion = math.huge }))
    expectFalse(validArgs({ protocolVersion = -math.huge }))
    local number = Validator.number({ min = 0, max = 1 })
    expectTrue((Validator.validate(number, 0.5)))
    expectFalse((Validator.validate(number, 0 / 0)))
    expectFalse((Validator.validate(number, math.huge)))
end)

test("string length boundaries", function()
    expectTrue(validArgs({ protocolVersion = 1, buildLabel = string.rep("a", 32) }))
    expectFalse(validArgs({ protocolVersion = 1, buildLabel = string.rep("a", 33) }))
    expectFalse(validArgs({ protocolVersion = 1, buildLabel = string.rep("a", 100000) }))
    local spec = Validator.string({ minLength = 2, maxLength = 4 })
    expectFalse((Validator.validate(spec, "a")))
    expectTrue((Validator.validate(spec, "ab")))
    expectTrue((Validator.validate(spec, "abcd")))
    expectFalse((Validator.validate(spec, "abcde")))
    expectTrue((Validator.validate(Validator.string({ maxLength = 4 }), "")))
end)

test("invalid UTF-8 strings are rejected", function()
    expectFalse((Validator.validate(Validator.string({ maxLength = 10 }), "\255\254")))
end)

test("enum and boolean", function()
    local enum = Validator.enum({ "a", "b" })
    expectTrue((Validator.validate(enum, "a")))
    expectFalse((Validator.validate(enum, "c")))
    expectFalse((Validator.validate(enum, 1)))
    expectTrue((Validator.validate(Validator.boolean(), false)))
    expectFalse((Validator.validate(Validator.boolean(), 0)))
end)

test("nested objects reject unexpected fields", function()
    local spec = Validator.object({ inner = Validator.object({ n = Validator.integer({ min = 0, max = 5 }) }) })
    expectTrue((Validator.validate(spec, { inner = { n = 3 } })))
    expectFalse((Validator.validate(spec, { inner = { n = 3, x = 1 } })))
    expectFalse((Validator.validate(spec, { inner = 3 })))
end)

test("schema construction requires explicit bounds", function()
    Harness.expectError(function()
        Validator.string({} :: any)
    end)
    Harness.expectError(function()
        Validator.number({ min = 0 } :: any)
    end)
    Harness.expectError(function()
        Validator.number({ min = 0, max = math.huge })
    end)
end)

test("unknown schema kind fails closed", function()
    expectFalse((Validator.validate({ kind = "mystery" }, 1)))
end)

return {}
