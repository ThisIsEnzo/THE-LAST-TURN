--!strict
-- Mission lifecycle adapter for TTL-11D evidence/objective integration.
local ServerStorage = game:GetService("ServerStorage")
local Bridge = require(ServerStorage.ServerShared.Evidence.EvidenceObjectiveBridge)
local EvidenceService = require(script.Parent.EvidenceService)
local ObjectiveService = require(script.Parent.Parent.Objective.ObjectiveService)
local MissionLifecycleService = require(script.Parent.Parent.MissionLifecycle.MissionLifecycleService)
local MappingContent = require(script.Parent.EvidenceObjectiveContent)
local Service = {}
local initialized = false
local activeBridge: any = nil
local function start(session: any)
    if activeBridge ~= nil then error("EvidenceObjectiveBridgeService: already started") end
    local mapping, code, subject = Bridge.compileMapping(MappingContent)
    if mapping == nil then error(string.format("invalid mapping %s at %s", tostring(code), tostring(subject))) end
    local instance = Bridge.new({
        subscribe = function(callback) return EvidenceService.onEvidenceConfirmed(callback) end,
        completeBySignal = function(id, token) return ObjectiveService.completeBySignal(id, token) end,
        mapping = mapping,
        log = function(message) warn("[THE LAST TURN][EvidenceObjective] " .. message) end,
    })
    activeBridge = instance
    instance:start(session)
end
local function stop()
    local instance = activeBridge
    activeBridge = nil
    if instance ~= nil then instance:stop() end
end
function Service.init()
    if initialized then return end
    local ok, code, subject = Bridge.validateMapping(MappingContent)
    if not ok then error(string.format("invalid evidence/objective mapping %s at %s", tostring(code), tostring(subject))) end
    if not MissionLifecycleService.registerSystem({ name = "EvidenceObjective", start = start, stop = stop }) then
        error("EvidenceObjectiveBridgeService must initialize before MissionLifecycleService")
    end
    initialized = true
end
return Service
