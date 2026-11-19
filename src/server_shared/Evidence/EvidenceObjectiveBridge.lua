--!strict
-- Pure evidence -> objective bridge. Dependencies are injected; no Roblox APIs.
local BridgeModule = {}
local function validId(v: any): boolean
    return type(v) == "string" and #v >= 1 and #v <= 32 and string.match(v, "^[A-Z][A-Z0-9_]*$") ~= nil
end
local function validToken(v: any): boolean
    return type(v) == "string" and #v >= 1 and #v <= 48 and string.match(v, "^[A-Za-z0-9_%-]+$") ~= nil
end
local function onlyFields(v: any, allowed: any): boolean
    if type(v) ~= "table" or getmetatable(v) ~= nil then return false end
    for k in pairs(v) do if type(k) ~= "string" or not allowed[k] then return false end end
    return true
end
function BridgeModule.validateMapping(content: any): (boolean, string?, string?)
    if not onlyFields(content, { version = true, mappings = true }) then return false, "invalid_mapping_table", nil end
    if type(content.version) ~= "number" or content.version < 1 or content.version % 1 ~= 0 then return false, "invalid_mapping_version", nil end
    if not onlyFields(content.mappings, {}) and (type(content.mappings) ~= "table" or getmetatable(content.mappings) ~= nil) then return false, "invalid_mappings", nil end
    local count = 0
    for k in pairs(content.mappings) do
        if type(k) ~= "number" or k < 1 or k > 32 or k % 1 ~= 0 then return false, "invalid_mappings", nil end
        count += 1
    end
    for i = 1, count do if content.mappings[i] == nil then return false, "invalid_mappings", nil end end
    local seen = {}
    for i = 1, count do
        local e = content.mappings[i]
        if not onlyFields(e, { evidenceId = true, objectiveId = true, sourceToken = true }) then return false, "invalid_mapping_entry", nil end
        if not validId(e.evidenceId) then return false, "invalid_evidence_id", nil end
        if not validId(e.objectiveId) then return false, "invalid_objective_id", e.evidenceId end
        if not validToken(e.sourceToken) then return false, "invalid_source_token", e.evidenceId end
        if seen[e.evidenceId] then return false, "duplicate_evidence_mapping", e.evidenceId end
        seen[e.evidenceId] = true
    end
    return true, nil, nil
end
function BridgeModule.compileMapping(content: any): (any?, string?, string?)
    local ok, code, subject = BridgeModule.validateMapping(content)
    if not ok then return nil, code, subject end
    local index = {}
    for _, e in ipairs(content.mappings) do index[e.evidenceId] = table.freeze({ objectiveId = e.objectiveId, sourceToken = e.sourceToken }) end
    return table.freeze(index), nil, nil
end
local Bridge = {}
Bridge.__index = Bridge
function BridgeModule.new(deps: any): any
    if type(deps) ~= "table" or type(deps.subscribe) ~= "function" or type(deps.completeBySignal) ~= "function"
        or type(deps.mapping) ~= "table" or type(deps.log) ~= "function" then error("EvidenceObjectiveBridge: invalid dependencies", 2) end
    return setmetatable({ _deps = deps, _running = false, _generation = 0, _unsubscribe = nil, _forwarded = {} }, Bridge)
end
local function onConfirmed(self: any, generation: number, evidenceId: any)
    if not self._running or self._generation ~= generation or type(evidenceId) ~= "string" or self._forwarded[evidenceId] then return end
    local mapping = self._deps.mapping[evidenceId]
    if mapping == nil then return end
    local ok, result = pcall(self._deps.completeBySignal, mapping.objectiveId, mapping.sourceToken)
    if not ok or type(result) ~= "table" or result.ok ~= true then
        self._deps.log("signal completion failed for " .. mapping.objectiveId .. ": " .. tostring(ok and result.reason or result))
        return
    end
    self._forwarded[evidenceId] = true
end
function Bridge.start(self: any, _session: any)
    if self._running then return end
    self._generation += 1
    local generation = self._generation
    self._forwarded = {}
    self._running = true
    local ok, unsubscribe = pcall(self._deps.subscribe, function(id: string, _info: any) onConfirmed(self, generation, id) end)
    if not ok or type(unsubscribe) ~= "function" then
        self._running = false
        self._generation += 1
        error("EvidenceObjectiveBridge: subscribe failed: " .. tostring(unsubscribe))
    end
    self._unsubscribe = unsubscribe
end
function Bridge.stop(self: any)
    self._running = false
    self._generation += 1
    local unsubscribe = self._unsubscribe
    self._unsubscribe = nil
    if unsubscribe ~= nil then pcall(unsubscribe) end
    self._forwarded = {}
end
function Bridge.isRunning(self: any): boolean return self._running end
return BridgeModule
