--!strict
local Harness = require("../Harness")
local ObjectiveConfig = require("../../src/mission/server/Objective/ObjectiveConfig")
local ObjectiveContent = require("../../src/mission/server/Objective/ObjectiveContent")
local ObjectiveRuntime = require("../../src/server_shared/Objective/ObjectiveRuntime")
local ObjectiveGraph = require("../../src/server_shared/Objective/ObjectiveGraph")
local InteractionCore = require("../../src/server_shared/Interaction/InteractionCore")
local InteractionConfig = require("../../src/mission/server/Interaction/InteractionConfig")
local NetworkContract = require("../../src/shared/Network/NetworkContract")
local NetworkConfig = require("../../src/server_shared/Network/NetworkConfig")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local function copyValues(): any
    return {
        interaction = { maxDistance = 8, holdDuration = 0, cooldown = 0.5 },
        prompt = { actionText = "Use" },
        fixture = { spawnDistanceStuds = 26, spacingStuds = 5, anchorSizeStuds = 2.5, heightStuds = 1.5, fallbackX = 0, fallbackY = 0, fallbackZ = -40 },
    }
end

test("the shipped configuration is valid and frozen", function()
    local ok, detail = ObjectiveConfig.validate(ObjectiveConfig.Values)
    expectTrue(ok, tostring(detail))
    expectTrue(table.isfrozen(ObjectiveConfig.Values))
    expectTrue(table.isfrozen(ObjectiveConfig.Values.interaction))
    expectTrue(table.isfrozen(ObjectiveConfig.Values.prompt))
    expectTrue(table.isfrozen(ObjectiveConfig.Values.fixture))
end)

test("validation rejects unknown fields, bad ranges and bad texts", function()
    local function invalid(mutate: (any) -> ()): boolean
        local config = copyValues()
        mutate(config)
        local ok = ObjectiveConfig.validate(config)
        return not ok
    end
    expectFalse(invalid(function() end), "baseline is valid")
    expectTrue(invalid(function(c: any) c.extra = true end))
    expectTrue(invalid(function(c: any) c.interaction.extra = 1 end))
    expectTrue(invalid(function(c: any) c.interaction.maxDistance = 1 end))
    expectTrue(invalid(function(c: any) c.interaction.maxDistance = 16 end))
    expectTrue(invalid(function(c: any) c.interaction.maxDistance = 0 / 0 end))
    expectTrue(invalid(function(c: any) c.interaction.holdDuration = 4 end))
    expectTrue(invalid(function(c: any) c.interaction.cooldown = -1 end))
    expectTrue(invalid(function(c: any) c.prompt.actionText = "" end))
    expectTrue(invalid(function(c: any) c.prompt.actionText = string.rep("x", 41) end))
    expectTrue(invalid(function(c: any) c.prompt.actionText = "a\nb" end))
    expectTrue(invalid(function(c: any) c.fixture.spacingStuds = 1 end))
    expectTrue(invalid(function(c: any) c.fixture.fallbackZ = math.huge end))
    expectTrue(invalid(function(c: any) c.fixture = nil end))
    expectFalse(ObjectiveConfig.validate("x"))
end)

test("every interaction spec and prompt option derived from the config passes the interaction layer's validators", function()
    local count = 0
    for _, objective in ipairs(ObjectiveContent.objectives) do
        for _, slot in ipairs(objective.completion.slots) do
            local spec = ObjectiveRuntime.buildSpec(ObjectiveConfig.Values, objective.id, slot.id)
            local ok, detail = InteractionCore.validateSpec(spec)
            expectTrue(ok, tostring(detail))
            local optionsOk, optionsDetail = InteractionConfig.validatePromptOptions(ObjectiveRuntime.buildPromptOptions(ObjectiveConfig.Values, slot.label))
            expectTrue(optionsOk, tostring(optionsDetail))
            count = count + 1
        end
    end
    expectEqual(count, 6)
end)

test("the prompt action text fits the interaction layer's own limit", function()
    expectTrue(#ObjectiveConfig.Values.prompt.actionText <= InteractionConfig.MaxTextBytes)
    expectTrue(ObjectiveGraph.Limits.MaxLabelBytes <= InteractionConfig.MaxTextBytes, "slot labels (prompt object text) must fit too")
end)

test("the network additions follow the contract conventions", function()
    local requests: any = NetworkContract.Requests
    local notifications: any = NetworkContract.Notifications
    expectEqual(requests.ObjectiveRequestSnapshot, "ObjectiveRequestSnapshot")
    expectEqual(notifications.ObjectiveSnapshot, "ObjectiveSnapshot")
    local limit = (NetworkConfig.RateLimits :: any).ObjectiveRequestSnapshot
    expectTrue(type(limit) == "table")
    expectTrue(limit.capacity >= 1 and limit.refillPerSecond > 0)
    -- the pull is a deliberately slow request: no larger a burst than the party snapshot pull
    expectTrue(limit.capacity <= (NetworkConfig.RateLimits :: any).PartyRequestSnapshot.capacity)
end)

test("every contract request still has a rate limit and every rate limit names a request", function()
    for name in pairs(NetworkContract.Requests :: any) do
        expectTrue((NetworkConfig.RateLimits :: any)[name] ~= nil, "missing rate limit for " .. name)
    end
    for name in pairs(NetworkConfig.RateLimits :: any) do
        expectTrue((NetworkContract.Requests :: any)[name] ~= nil, "rate limit without request: " .. name)
    end
end)

test("no request or notification can name an objective command", function()
    -- The client may only pull a snapshot: no contract name mentions completing, failing or changing objectives.
    for _, group in ipairs({ NetworkContract.Requests :: any, NetworkContract.Notifications :: any }) do
        for name in pairs(group) do
            local lowered = string.lower(name)
            if string.find(lowered, "objective", 1, true) ~= nil then
                expectTrue(name == "ObjectiveRequestSnapshot" or name == "ObjectiveSnapshot", "unexpected objective remote " .. name)
            end
        end
    end
end)
