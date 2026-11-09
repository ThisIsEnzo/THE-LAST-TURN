--!strict
local Harness = require("../Harness")
local DoorConfig = require("../../src/mission/server/Door/DoorConfig")
local DoorCore = require("../../src/server_shared/Door/DoorCore")
local InteractionCore = require("../../src/server_shared/Interaction/InteractionCore")
local InteractionConfig = require("../../src/mission/server/Interaction/InteractionConfig")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local Values = DoorConfig.Values

local function clone(value: any): any
    if type(value) ~= "table" then
        return value
    end
    local copy: { [any]: any } = {}
    for key, item in pairs(value) do
        copy[key] = clone(item)
    end
    return copy
end

local function with(path: { string }, value: any): any
    local config = clone(Values)
    local node: any = config
    for index = 1, #path - 1 do
        node = node[path[index]]
    end
    node[path[#path]] = value
    return config
end

local function invalid(config: any, label: string)
    local ok, detail = DoorConfig.validate(config)
    expectFalse(ok, label)
    expectTrue(type(detail) == "string", label .. " detail")
end

test("the shipped configuration is valid, frozen and has the documented defaults", function()
    local ok, detail = DoorConfig.validate(Values)
    expectTrue(ok, tostring(detail))
    expectTrue(table.isfrozen(Values))
    expectTrue(table.isfrozen(Values.interaction))
    expectTrue(table.isfrozen(Values.door))
    expectTrue(table.isfrozen(Values.fixture))
    expectEqual(Values.interaction.id, "TestDoor")
    expectEqual(Values.door.initialState, "Closed")
    expectEqual(Values.door.transitionSeconds, 0.6)
end)

test("the door settings satisfy DoorCore's own validation", function()
    local ok, detail = DoorCore.validateConfig(Values.door)
    expectTrue(ok, tostring(detail))
    expectTrue(DoorCore.new(Values.door) ~= nil)
end)

test("the interaction spec satisfies InteractionCore's validation and registers", function()
    local spec = DoorConfig.interactionSpec(Values)
    local ok, detail = InteractionCore.validateSpec(spec)
    expectTrue(ok, tostring(detail))
    local store = InteractionCore.new()
    local handle, reason = store:register(spec, {})
    expectTrue(handle ~= nil, tostring(reason))
    expectEqual(store:getState(handle).cooldown, Values.interaction.cooldown)
end)

test("the prompt options satisfy the interaction service's text validation", function()
    local ok, detail = InteractionConfig.validatePromptOptions(DoorConfig.promptOptions(Values))
    expectTrue(ok, tostring(detail))
end)

test("the interaction cooldown covers the door transition", function()
    expectTrue(Values.interaction.cooldown >= Values.door.transitionSeconds)
    invalid(with({ "interaction", "cooldown" }, 0.5), "cooldown shorter than the transition")
    expectTrue((DoorConfig.validate(with({ "interaction", "cooldown" }, 0.6))), "equal is allowed")
end)

test("helpers return fresh tables", function()
    local specA = DoorConfig.interactionSpec(Values)
    local specB = DoorConfig.interactionSpec(Values)
    expectTrue(specA ~= specB)
    specA.cooldown = 99
    expectEqual(Values.interaction.cooldown, 1)
    expectFalse(table.isfrozen(specA))
end)

test("validate rejects malformed top-level configuration", function()
    invalid(nil, "nil")
    invalid("config", "string")
    invalid({ 1, 2 }, "array")
    local extra = clone(Values)
    extra.extra = true
    invalid(extra, "unknown field")
    local missing = clone(Values)
    missing.fixture = nil
    invalid(missing, "missing fixture")
    invalid(with({ "enabled" }, "yes"), "non-boolean enabled")
    expectTrue((DoorConfig.validate(with({ "enabled" }, false))), "disabled is valid")
end)

test("validate rejects invalid interaction settings", function()
    for _, id in ipairs({ "", string.rep("a", 65), "bad id", "dot.id" }) do
        invalid(with({ "interaction", "id" }, id), "id " .. id)
    end
    invalid(with({ "interaction", "id" }, 5), "numeric id")
    for _, distance in ipairs({ 1.9, 15.1, -1, 0 / 0, math.huge }) do
        invalid(with({ "interaction", "maxDistance" }, distance), "maxDistance " .. tostring(distance))
    end
    for _, hold in ipairs({ -1, 3.1, 0 / 0 }) do
        invalid(with({ "interaction", "holdDuration" }, hold), "hold " .. tostring(hold))
    end
    for _, cooldown in ipairs({ -1, 60.1, 0 / 0, math.huge }) do
        invalid(with({ "interaction", "cooldown" }, cooldown), "cooldown " .. tostring(cooldown))
    end
    invalid(with({ "interaction", "actionText" }, ""), "empty action text")
    invalid(with({ "interaction", "actionText" }, string.rep("x", 41)), "long action text")
    invalid(with({ "interaction", "actionText" }, "Open\ndoor"), "control character")
    invalid(with({ "interaction", "objectText" }, 5), "numeric object text")
    local unknown = clone(Values)
    unknown.interaction.extra = 1
    invalid(unknown, "unknown interaction field")
end)

test("validate rejects invalid door settings", function()
    invalid(with({ "door", "transitionSeconds" }, 0 / 0), "NaN transition")
    invalid(with({ "door", "transitionSeconds" }, "1"), "string transition")
    local unknown = clone(Values)
    unknown.door.extra = 1
    invalid(unknown, "unknown door field")
end)

test("validate rejects invalid fixture settings", function()
    local cases = {
        { "panelWidth", 1.9 },
        { "panelWidth", 12.1 },
        { "panelHeight", 3.9 },
        { "panelHeight", 16.1 },
        { "panelThickness", 0.1 },
        { "panelThickness", 2.1 },
        { "pillarWidth", 0.4 },
        { "pillarWidth", 3.1 },
        { "spawnDistanceStuds", 3.9 },
        { "spawnDistanceStuds", 60.1 },
        { "fallbackX", 10001 },
        { "fallbackY", 0 / 0 },
        { "fallbackZ", math.huge },
        { "openAngleDegrees", 29 },
        { "openAngleDegrees", -29 },
        { "openAngleDegrees", 121 },
        { "openAngleDegrees", 0 },
        { "openAngleDegrees", 0 / 0 },
    }
    for _, case in ipairs(cases) do
        invalid(with({ "fixture", case[1] :: string }, case[2]), tostring(case[1]) .. "=" .. tostring(case[2]))
    end
    expectTrue((DoorConfig.validate(with({ "fixture", "openAngleDegrees" }, -90))), "a negative swing angle is valid")
    local unknown = clone(Values)
    unknown.fixture.extra = 1
    invalid(unknown, "unknown fixture field")
end)
