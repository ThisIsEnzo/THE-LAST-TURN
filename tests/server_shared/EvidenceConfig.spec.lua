--!strict
local Harness = require("../Harness")
local EvidenceConfig = require("../../src/mission/server/Evidence/EvidenceConfig")
local EvidenceRuntime = require("../../src/server_shared/Evidence/EvidenceRuntime")
local InteractionCore = require("../../src/server_shared/Interaction/InteractionCore")
local InteractionConfig = require("../../src/mission/server/Interaction/InteractionConfig")
local NetworkContract = require("../../src/shared/Network/NetworkContract")
local NetworkConfig = require("../../src/server_shared/Network/NetworkConfig")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local function copyValues(): any
    return {
        interaction = { maxDistance = 8, holdDuration = 1.2, cooldown = 1 },
        prompt = { actionText = "Examine", objectText = "Strange sign" },
        confirmWhenCorroborated = true,
    }
end

test("the shipped configuration is valid and frozen", function()
    local ok, detail = EvidenceConfig.validate(EvidenceConfig.Values)
    expectTrue(ok, tostring(detail))
    expectTrue(table.isfrozen(EvidenceConfig.Values))
    expectTrue(table.isfrozen(EvidenceConfig.Values.interaction))
    expectTrue(table.isfrozen(EvidenceConfig.Values.prompt))
end)

test("validation rejects unknown fields, bad ranges, bad texts and a non-boolean policy", function()
    local function invalid(mutate: (any) -> ()): boolean
        local config = copyValues()
        mutate(config)
        local ok = EvidenceConfig.validate(config)
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
    expectTrue(invalid(function(c: any) c.prompt.objectText = string.rep("x", 41) end))
    expectTrue(invalid(function(c: any) c.prompt.objectText = "a\nb" end))
    expectTrue(invalid(function(c: any) c.confirmWhenCorroborated = "yes" end))
    expectTrue(invalid(function(c: any) c.confirmWhenCorroborated = nil end))
    expectTrue(invalid(function(c: any) c.prompt = nil end))
    expectFalse(EvidenceConfig.validate("x"))
end)

test("derived interaction specs and prompt options pass the interaction layer's own validators", function()
    for position = 1, 32 do
        local ok, detail = InteractionCore.validateSpec(EvidenceRuntime.buildSpec(EvidenceConfig.Values, position))
        expectTrue(ok, tostring(detail))
    end
    local optionsOk, optionsDetail = InteractionConfig.validatePromptOptions(EvidenceRuntime.buildPromptOptions(EvidenceConfig.Values))
    expectTrue(optionsOk, tostring(optionsDetail))
end)

test("the prompt text does not name any shipped evidence", function()
    local text = string.upper(EvidenceConfig.Values.prompt.objectText .. " " .. EvidenceConfig.Values.prompt.actionText)
    for _, name in ipairs({ "COLD", "STATIC", "MOVED", "VOICE", "ECHO", "SPOT", "INTERFERENCE" }) do
        expectFalse(string.find(text, name, 1, true) ~= nil, name)
    end
end)

test("the network additions follow the contract conventions", function()
    local requests: any = NetworkContract.Requests
    local notifications: any = NetworkContract.Notifications
    expectEqual(requests.EvidenceRequestSnapshot, "EvidenceRequestSnapshot")
    expectEqual(notifications.EvidenceSnapshot, "EvidenceSnapshot")
    local limit = (NetworkConfig.RateLimits :: any).EvidenceRequestSnapshot
    expectTrue(type(limit) == "table")
    expectTrue(limit.capacity >= 1 and limit.refillPerSecond > 0)
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

test("no request can name evidence, a source, a position or a state: the only evidence request is the snapshot pull", function()
    for name in pairs(NetworkContract.Requests :: any) do
        local lowered = string.lower(name)
        if string.find(lowered, "evidence", 1, true) ~= nil then
            expectEqual(name, "EvidenceRequestSnapshot")
        end
    end
    for name in pairs(NetworkContract.Notifications :: any) do
        local lowered = string.lower(name)
        if string.find(lowered, "evidence", 1, true) ~= nil then
            expectEqual(name, "EvidenceSnapshot")
        end
    end
end)
