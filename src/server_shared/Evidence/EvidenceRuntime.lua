--!strict
-- Orchestration of one mission's evidence ledger (TTL-11B, docs/TTL-11B_EVIDENCE_SERVICE.md).
--
-- This module is the testable half of EvidenceService. It contains NO Roblox APIs: every collaborator (catalog, core,
-- interaction registration, source discovery, availability, lifecycle, player facts, network send, clock, logging) is
-- injected through `deps`, so Lune specs drive it with fakes (and with the real InteractionCore) while EvidenceService wires
-- the real services. Like every pure module in this repository it requires no other module.
--
-- How evidence is discovered: clients never name evidence. The authored world contains evidence SOURCES (parts tagged
-- `EvidenceSource`, each with `EvidenceId` and `SourceId` attributes). For every source this runtime registers one
-- server-created interaction through the existing InteractionService, which already validates every activation (mission
-- ACTIVE, roster, ALIVE, character, target, server-measured distance, rate limit, busy, cooldown). The handler then
-- re-checks the facts that belong to evidence, derives the evidence id and source id from the registration (never from the
-- client) and applies the command through EvidenceCore. All state-transition and validation rules live in EvidenceCore.
--
-- Responsibilities (and only these):
--   * compile the catalog once and own the EvidenceCore for the mission;
--   * index the authored sources, register one interaction per valid source and keep prompt availability equal to the
--     ledger (`reconcile`, idempotent and self-healing);
--   * turn a validated interaction into `observe` (and, by policy, `confirm`) and publish exactly one privacy-safe
--     snapshot per applied activation (never for rejections or duplicates);
--   * answer snapshot pulls for connected roster members only.
-- Everything runs synchronously and never yields, so a command cannot be interleaved with another.

local EvidenceRuntime = {}

EvidenceRuntime.SourceTag = "EvidenceSource"
EvidenceRuntime.EvidenceIdAttribute = "EvidenceId"
EvidenceRuntime.SourceIdAttribute = "SourceId"
EvidenceRuntime.AvailableAttribute = "Available"
EvidenceRuntime.SnapshotVersion = 1

export type Deps = {
    catalog: any, -- EvidenceCatalog module (needs .compile and .isToken)
    core: any, -- EvidenceCore module (needs .new and .States)
    content: any, -- EvidenceContent table (validated here by compile)
    config: any, -- EvidenceConfig.Values (interaction, prompt, confirmWhenCorroborated)
    interaction: any, -- { register, setEnabled, unregister } with InteractionService semantics
    collectSources: () -> { any }, -- array of { evidenceId, sourceId, anchor } read from the authored world
    isAvailable: (anchor: any) -> boolean, -- is the world object still present and usable right now
    lifecycle: any, -- { isActive: () -> boolean }
    players: any, -- { getUserId, getPlayer, isConnected, isAlive }
    send: (player: any, payload: any) -> (), -- one EvidenceSnapshot notification to one player
    now: () -> number,
    log: (message: string) -> (),
}

local Runtime = {}
Runtime.__index = Runtime

export type Runtime = typeof(setmetatable({} :: { [string]: any }, Runtime))

local INTERACTION_ID_PREFIX = "EVD"

local function isDeps(deps: any): boolean
    if type(deps) ~= "table" then
        return false
    end
    for _, name in ipairs({ "collectSources", "isAvailable", "send", "now", "log" }) do
        if type(deps[name]) ~= "function" then
            return false
        end
    end
    for _, name in ipairs({ "catalog", "core", "config", "interaction", "lifecycle", "players" }) do
        if type(deps[name]) ~= "table" then
            return false
        end
    end
    return deps.content ~= nil
end

-- The InteractionCore spec of one source. `index` is its position in the deterministic, sorted source list, so the id is a
-- short token (the 64 character limit would not fit two 32 character ids) that reveals nothing about the evidence.
function EvidenceRuntime.buildSpec(config: any, index: number): { [string]: any }
    return {
        id = INTERACTION_ID_PREFIX .. "_" .. tostring(index),
        maxDistance = config.interaction.maxDistance,
        holdDuration = config.interaction.holdDuration,
        cooldown = config.interaction.cooldown,
        enabled = false,
    }
end

-- Prompt texts are generic on purpose: the prompt is visible to every client before anything is discovered, so it must not
-- name the evidence it belongs to.
function EvidenceRuntime.buildPromptOptions(config: any): { [string]: string }
    return { actionText = config.prompt.actionText, objectText = config.prompt.objectText }
end

export type SourceIndex = {
    sources: { any }, -- { evidenceId, sourceId, anchor }, sorted by "evidenceId/sourceId"
    duplicates: { string }, -- keys claimed by more than one world object (none of them is used), sorted
    unknown: { string }, -- evidence ids not in the catalog, sorted, each once (ignored)
    invalid: number, -- candidates with a malformed id or no anchor (ignored)
}

-- Pure indexing of the authored sources. The result does not depend on the order of `candidates`. Rules (fail-closed): both
-- ids must be content-style tokens, the evidence must exist in the catalog plan, a (evidenceId, sourceId) pair claimed by two
-- world objects is ambiguous and used by neither.
function EvidenceRuntime.indexSources(candidates: any, plan: any, isToken: (any) -> boolean): SourceIndex
    local byKey: { [string]: any } = {}
    local counts: { [string]: number } = {}
    local unknownSet: { [string]: boolean } = {}
    local invalid = 0
    if type(candidates) == "table" then
        for _, candidate in ipairs(candidates) do
            if type(candidate) ~= "table" or not isToken(candidate.evidenceId) or not isToken(candidate.sourceId) or candidate.anchor == nil then
                invalid = invalid + 1
            elseif plan.entries[candidate.evidenceId] == nil then
                unknownSet[candidate.evidenceId] = true
            else
                local key: string = candidate.evidenceId .. "/" .. candidate.sourceId
                counts[key] = (counts[key] or 0) + 1
                byKey[key] = { evidenceId = candidate.evidenceId, sourceId = candidate.sourceId, anchor = candidate.anchor }
            end
        end
    end
    local duplicates: { string } = {}
    for key, count in pairs(counts) do
        if count > 1 then
            byKey[key] = nil
            table.insert(duplicates, key)
        end
    end
    table.sort(duplicates)
    local keys: { string } = {}
    for key in pairs(byKey) do
        table.insert(keys, key)
    end
    table.sort(keys)
    local sources: { any } = {}
    for _, key in ipairs(keys) do
        table.insert(sources, byKey[key])
    end
    local unknown: { string } = {}
    for id in pairs(unknownSet) do
        table.insert(unknown, id)
    end
    table.sort(unknown)
    return { sources = sources, duplicates = duplicates, unknown = unknown, invalid = invalid }
end

function EvidenceRuntime.new(deps: Deps): Runtime
    if not isDeps(deps) then
        error("EvidenceRuntime.new: incomplete dependencies", 2)
    end
    return setmetatable({
        _deps = deps,
        _running = false,
        _generation = 0,
        _plan = nil,
        _core = nil,
        _roster = {}, -- [userId] = true
        _rosterList = {}, -- UserIds in session order (deterministic broadcast order)
        _slots = {}, -- array of { evidenceId, sourceId, anchor, handle, applied }
    }, Runtime)
end

local function log(self: any, message: string)
    self._deps.log("[Evidence] " .. message)
end

local function releaseSlots(self: any)
    local slots = self._slots
    self._slots = {}
    for _, slot in ipairs(slots) do
        if slot.handle ~= nil then
            pcall(self._deps.interaction.unregister, slot.handle)
        end
    end
end

-- Prompt reconciliation: a source prompt is enabled exactly when its evidence is not CONFIRMED, this source has not been
-- used yet and the world object is available. Idempotent; a failed prompt update is retried by the next call because
-- `applied` is only updated after the interaction service accepted the change. (Availability can also change without a
-- command; the handler re-checks it at activation, so the prompt can only be momentarily stale, never exploitable.)
local function reconcile(self: any)
    local core = self._core
    if core == nil then
        return
    end
    local confirmed = self._deps.core.States.CONFIRMED
    for _, slot in ipairs(self._slots) do
        local entry = core:getEntry(slot.evidenceId)
        local used = false
        if entry ~= nil then
            for _, observation in ipairs(entry.observations) do
                if observation.sourceId == slot.sourceId then
                    used = true
                    break
                end
            end
        end
        local desired = entry ~= nil and entry.state ~= confirmed and not used and self._deps.isAvailable(slot.anchor) == true
        if slot.applied ~= desired then
            local ok, accepted = pcall(self._deps.interaction.setEnabled, slot.handle, desired)
            if ok and accepted == true then
                slot.applied = desired
            else
                log(self, string.format("could not set prompt %s/%s to %s", slot.evidenceId, slot.sourceId, tostring(desired)))
            end
        end
    end
end

local function isConnectedRosterPlayer(self: any, player: any): boolean
    local players = self._deps.players
    local userId = players.getUserId(player)
    return type(userId) == "number" and self._roster[userId] == true and players.isConnected(player) == true
end

-- The replicable projection. Privacy: UNKNOWN evidence is omitted entirely (only the total count is sent), and nothing about
-- sources, contributors, positions or confirmers is included. Titles come from the server-only catalog and are sent only for
-- evidence that has been discovered.
local function buildSnapshot(self: any): any
    local core = self._core
    local States = self._deps.core.States
    local evidence: { any } = {}
    for _, entry in ipairs(core:getEntries()) do
        if entry.state ~= States.UNKNOWN then
            local definition = self._plan.entries[entry.id]
            table.insert(evidence, {
                id = entry.id,
                title = definition.title,
                category = entry.category,
                state = entry.state,
                sources = entry.sourceCount,
                required = entry.required,
            })
        end
    end
    return { v = EvidenceRuntime.SnapshotVersion, revision = core:getRevision(), total = #self._plan.order, evidence = evidence }
end

local function sendSnapshot(self: any, player: any)
    if self._core == nil then
        return
    end
    local ok, err = pcall(function()
        self._deps.send(player, buildSnapshot(self))
    end)
    if not ok then
        log(self, "snapshot delivery failed: " .. tostring(err))
    end
end

-- One snapshot per connected roster member, each a fresh copy of the same revision.
local function broadcast(self: any)
    for _, userId in ipairs(self._rosterList) do
        local player = self._deps.players.getPlayer(userId)
        if player ~= nil and self._deps.players.isConnected(player) == true then
            sendSnapshot(self, player)
        end
    end
end

-- The handler body of every source interaction. InteractionService validated the activation first; the checks here are the
-- single choke point for what belongs to evidence. Evidence and source ids come from the registration closure, never from
-- the client. Returns true only when an observation was applied (so a rejected or duplicate activation consumes no cooldown).
local function activate(self: any, capturedGeneration: number, slot: any, player: any): boolean
    if not self._running or self._generation ~= capturedGeneration then
        return false
    end
    local deps = self._deps
    if not deps.lifecycle.isActive() then
        return false
    end
    if not isConnectedRosterPlayer(self, player) then
        return false
    end
    if deps.isAvailable(slot.anchor) ~= true then
        return false -- the world object is missing or currently unavailable
    end
    local userId = deps.players.getUserId(player)
    local context = { eligible = deps.players.isAlive(player) == true, now = deps.now() }
    local result = self._core:observe(slot.evidenceId, slot.sourceId, userId, context)
    if not result.ok or not result.changed then
        return false
    end
    if deps.config.confirmWhenCorroborated then
        -- Policy only: EvidenceCore decides whether enough distinct sources agree (a rejection here is normal and silent).
        self._core:confirm(slot.evidenceId, userId, context)
    end
    local reconciled, reconcileError = pcall(reconcile, self)
    if not reconciled then
        log(self, "reconcile raised: " .. tostring(reconcileError))
    end
    local sent, sendError = pcall(broadcast, self)
    if not sent then
        log(self, "broadcast raised: " .. tostring(sendError))
    end
    return true
end

-- Raises on any problem so the lifecycle aborts the mission (invalid content or roster); partial work is rolled back first.
-- Missing, ambiguous or unbindable sources are NOT fatal (evidence is optional content): they are logged and ignored.
function Runtime.start(self: any, session: any)
    if self._running or self._core ~= nil then
        error("EvidenceRuntime: already started")
    end
    local deps = self._deps

    local plan, code, subject = deps.catalog.compile(deps.content)
    if plan == nil then
        local where = ""
        if subject ~= nil then
            where = " at " .. tostring(subject)
        end
        error(string.format("EvidenceRuntime: invalid evidence content (%s%s)", tostring(code), where))
    end

    local roster: { [number]: boolean } = {}
    local rosterList: { number } = {}
    local expected: any = nil
    if type(session) == "table" then
        expected = session.expectedUserIds
    end
    if type(expected) ~= "table" then
        error("EvidenceRuntime: the session has no expectedUserIds")
    end
    for _, userId in ipairs(expected) do
        if type(userId) ~= "number" or userId % 1 ~= 0 or userId < 1 or roster[userId] then
            error("EvidenceRuntime: invalid roster")
        end
        roster[userId] = true
        table.insert(rosterList, userId)
    end
    if #rosterList == 0 then
        error("EvidenceRuntime: the roster is empty")
    end

    local core = deps.core.new(plan, deps.now())
    self._generation = self._generation + 1
    local capturedGeneration = self._generation
    self._plan = plan
    self._core = core
    self._roster = roster
    self._rosterList = rosterList
    self._slots = {}

    local index = EvidenceRuntime.indexSources(deps.collectSources(), plan, deps.catalog.isToken)
    if #index.duplicates > 0 then
        log(self, "ambiguous sources (claimed more than once, none will be used): " .. table.concat(index.duplicates, ", "))
    end
    if #index.unknown > 0 then
        log(self, "sources for evidence that is not in the catalog are ignored: " .. table.concat(index.unknown, ", "))
    end
    if index.invalid > 0 then
        log(self, string.format("%d source object(s) have invalid ids and are ignored", index.invalid))
    end

    for position, source in ipairs(index.sources) do
        local slot: any = { evidenceId = source.evidenceId, sourceId = source.sourceId, anchor = source.anchor, handle = nil, applied = false }
        local handle, reason = deps.interaction.register(
            EvidenceRuntime.buildSpec(deps.config, position),
            source.anchor,
            function(player: any): boolean
                return activate(self, capturedGeneration, slot, player)
            end,
            EvidenceRuntime.buildPromptOptions(deps.config)
        )
        if handle == nil then
            log(self, string.format("source %s/%s could not be registered (%s)", source.evidenceId, source.sourceId, tostring(reason)))
        else
            slot.handle = handle
            table.insert(self._slots, slot)
        end
    end

    -- Evidence that can never be confirmed with the sources actually available is a content problem worth a loud log.
    local counts: { [string]: number } = {}
    for _, slot in ipairs(self._slots) do
        counts[slot.evidenceId] = (counts[slot.evidenceId] or 0) + 1
    end
    for _, id in ipairs(plan.order) do
        local required: number = plan.entries[id].distinctSources
        if (counts[id] or 0) < required then
            log(self, string.format("evidence %s needs %d distinct sources but only %d are bound", id, required, counts[id] or 0))
        end
    end

    self._running = true
    reconcile(self)
    broadcast(self)
end

-- Idempotent, safe after a partial start. Invalidates every captured handler (generation), unregisters the prompts (the
-- interaction service is still alive: consumers stop before it) and drops all state, so a new mission starts clean.
function Runtime.stop(self: any)
    self._running = false
    self._generation = self._generation + 1
    releaseSlots(self)
    self._core = nil
    self._plan = nil
    self._roster = {}
    self._rosterList = {}
end

function Runtime.isRunning(self: any): boolean
    return self._running
end

-- Answers a snapshot pull. Only connected roster members while running; the answer goes to the requester only and repeats
-- the current revision (clients drop duplicates).
function Runtime.requestSnapshot(self: any, player: any)
    if not self._running or self._core == nil then
        return
    end
    if not isConnectedRosterPlayer(self, player) then
        return
    end
    sendSnapshot(self, player)
end

-- Diagnostics (read-only).
function Runtime.getEvidenceState(self: any, evidenceId: string): string?
    local core = self._core
    if core == nil then
        return nil
    end
    return core:getState(evidenceId)
end

function Runtime.getProgress(self: any): any?
    local core = self._core
    if core == nil then
        return nil
    end
    return core:getProgress()
end

function Runtime.getRevision(self: any): number?
    local core = self._core
    if core == nil then
        return nil
    end
    return core:getRevision()
end

return EvidenceRuntime
