--!strict
-- Mission lifecycle adapter for TTL-11D evidence/objective integration.
local ServerStorage = game:GetService("ServerStorage")
local Bridge = require(ServerStorage.ServerShared.Evidence.EvidenceObjectiveBridge)
local EvidenceService = require(script.Parent.EvidenceService)
local ObjectiveService = require(script.Parent.Parent.Objective.ObjectiveService)
local MissionLifecycleService = require(script.Parent.Parent.MissionLifecycle.MissionLifecycleService)
local MappingContent = require(script.Parent.EvidenceObjectiveContent)
local EvidenceContent = require(script.Parent.EvidenceContent)
local ObjectiveContent = require(script.Parent.Parent.Objective.ObjectiveContent)
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
local function validateContentMapping()
    local evidenceIds: {[string]: boolean} = {}
    for _, definition in ipairs(EvidenceContent.evidence) do evidenceIds[definition.id] = true end
    local signalTokens: {[string]: string} = {}
    for _, objective in ipairs(ObjectiveContent.objectives) do
        if objective.completion.kind == "SIGNAL" then
            signalTokens[objective.id] = objective.completion.signal.sourceToken
        end
    end
    for _, mapping in ipairs(MappingContent.mappings) do
        if not evidenceIds[mapping.evidenceId] then
            error(string.format("EvidenceObjectiveBridgeService: unknown evidence id %s", mapping.evidenceId))
        end
        local token = signalTokens[mapping.objectiveId]
        if token == nil then
            error(string.format("EvidenceObjectiveBridgeService: %s is not a SIGNAL objective", mapping.objectiveId))
        end
        if token ~= mapping.sourceToken then
            error(string.format("EvidenceObjectiveBridgeService: sourceToken mismatch for %s", mapping.objectiveId))
        end
    end
end

function Service.init()
    if initialized then return end
    validateContentMapping()
    local ok, code, subject = Bridge.validateMapping(MappingContent)
    if not ok then error(string.format("invalid evidence/objective mapping %s at %s", tostring(code), tostring(subject))) end
    if not MissionLifecycleService.registerSystem({ name = "EvidenceObjective", start = start, stop = stop }) then
        error("EvidenceObjectiveBridgeService must initialize before MissionLifecycleService")
    end
    initialized = true
end
return Service
