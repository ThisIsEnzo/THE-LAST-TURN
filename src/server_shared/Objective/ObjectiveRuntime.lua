--!strict
-- Orchestration of one mission's objectives (TTL-09B, docs/TTL-09_OBJECTIVE_SYSTEM.md sections 3, 7, 8 and 11).
--
-- This module is the testable half of ObjectiveService. It contains NO Roblox APIs: every collaborator (graph, core,
-- interaction registration, anchors, lifecycle, player facts, network send, scheduler, clock, logging) is injected
-- through `deps`, so Lune specs drive it with fakes while ObjectiveService wires the real services. Like every pure
-- module in this repository it requires no other module.
--
-- Responsibilities (and only these):
--   * compile the objective content once and own the ObjectiveCore for the mission;
--   * register one interaction per contribution slot and keep prompt availability equal to the authoritative state
--     (`reconcile`, idempotent and self-healing);
--   * turn a validated interaction into `ObjectiveCore:contribute` and publish exactly one final snapshot per applied
--     command (never for rejections or no-ops);
--   * answer snapshot pulls for roster members only;
--   * report a mission resolution to the lifecycle through its own API, deferred, guarded and only while the
--     lifecycle is still active. The lifecycle keeps ownership of mission state; this module never ends or stops
--     anything by itself.
-- It never decides a transition: all rules live in ObjectiveCore. Everything runs synchronously and never yields, so a
-- command cannot be interleaved with another.

local ObjectiveRuntime = {}

export type Deps = {
    graph: any, -- ObjectiveGraph module (needs .compile)
    core: any, -- ObjectiveCore module (needs .new)
    content: any, -- ObjectiveContent table (validated here by compile)
    config: any, -- ObjectiveConfig.Values (interaction + prompt settings)
    interaction: any, -- { register, setEnabled, unregister } with InteractionService semantics
    resolveAnchor: (pointId: string) -> any?, -- logical anchor id -> BasePart (or nil)
    lifecycle: any, -- { isActive: () -> boolean, endMission: (outcome, reason) -> any }
    players: any, -- { getUserId, getPlayer, isConnected, isAlive }
    send: (player: any, payload: any) -> (), -- one ObjectiveSnapshot notification to one player
    defer: (callback: () -> ()) -> (), -- runs the callback later, outside the current call (task.defer)
    now: () -> number,
    log: (message: string) -> (),
}

local Runtime = {}
Runtime.__index = Runtime

export type Runtime = typeof(setmetatable({} :: { [string]: any }, Runtime))

local INTERACTION_ID_PREFIX = "OBJ"

-- Interaction id of a slot: a token of at most 64 characters (validated by InteractionCore.validateSpec).
function ObjectiveRuntime.interactionId(objectiveId: string, slotId: string): string
    return INTERACTION_ID_PREFIX .. "_" .. objectiveId .. "_" .. slotId
end

-- The InteractionCore spec of a slot. Registered disabled; `reconcile` enables it when the objective allows it.
function ObjectiveRuntime.buildSpec(config: any, objectiveId: string, slotId: string): { [string]: any }
    return {
        id = ObjectiveRuntime.interactionId(objectiveId, slotId),
        maxDistance = config.interaction.maxDistance,
        holdDuration = config.interaction.holdDuration,
        cooldown = config.interaction.cooldown,
        enabled = false,
    }
end

-- The prompt texts of a slot: a generic verb plus the slot label (<= 40 bytes, validated by content validation).
function ObjectiveRuntime.buildPromptOptions(config: any, label: string): { [string]: string }
    return { actionText = config.prompt.actionText, objectText = label }
end

local function isDeps(deps: any): boolean
    if type(deps) ~= "table" then
        return false
    end
    local functions = { "resolveAnchor", "send", "defer", "now", "log" }
    for _, name in ipairs(functions) do
        if type(deps[name]) ~= "function" then
            return false
        end
    end
    local tables = { "graph", "core", "config", "interaction", "lifecycle", "players" }
    for _, name in ipairs(tables) do
        if type(deps[name]) ~= "table" then
            return false
        end
    end
    return deps.content ~= nil
end

function ObjectiveRuntime.new(deps: Deps): Runtime
    if not isDeps(deps) then
        error("ObjectiveRuntime.new: incomplete dependencies", 2)
    end
    return setmetatable({
        _deps = deps,
        _running = false,
        _generation = 0,
        _plan = nil,
        _core = nil,
        _roster = {}, -- [userId] = true
        _rosterList = {}, -- UserIds in session order (deterministic broadcast order)
        _slots = {}, -- array of { objectiveId, slotId, handle, applied }
    }, Runtime)
end

local function log(self: any, message: string)
    self._deps.log("[Objective] " .. message)
end

-- Unregisters everything this runtime registered. Idempotent; never raises.
local function releaseSlots(self: any)
    local slots = self._slots
    self._slots = {}
    for _, slot in ipairs(slots) do
        if slot.handle ~= nil then
            pcall(self._deps.interaction.unregister, slot.handle)
        end
    end
end

-- Prompt reconciliation (design 3.5): a slot prompt is enabled exactly when its objective is AVAILABLE or
-- IN_PROGRESS, the slot is unfilled and the mission has not resolved. Idempotent. Failures change nothing in the Core and
-- are retried by the next call, because `applied` is only updated after the interaction service accepted the change.
local function reconcile(self: any)
    local core = self._core
    if core == nil then
        return
    end
    local resolved = core:isResolved()
    for _, slot in ipairs(self._slots) do
        local state = core:getState(slot.objectiveId)
        local desired = not resolved
            and (state == "AVAILABLE" or state == "IN_PROGRESS")
            and core:getContributor(slot.objectiveId, slot.slotId) == nil
        if slot.applied ~= desired then
            local ok, accepted = pcall(self._deps.interaction.setEnabled, slot.handle, desired)
            if ok and accepted == true then
                slot.applied = desired
            else
                log(self, string.format("could not set prompt %s_%s to %s", slot.objectiveId, slot.slotId, tostring(desired)))
            end
        end
    end
end

local function isConnectedRosterPlayer(self: any, player: any): boolean
    local players = self._deps.players
    local userId = players.getUserId(player)
    return type(userId) == "number" and self._roster[userId] == true and players.isConnected(player) == true
end

-- Sends the current snapshot to one player. Never raises (a failing send must not break a command).
local function sendSnapshot(self: any, player: any)
    local core = self._core
    if core == nil then
        return
    end
    local ok, err = pcall(self._deps.send, player, core:getSnapshot())
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

-- Reports a resolution to the lifecycle. Deferred, so it never runs inside the interaction handler (ending the mission
-- stops InteractionService, which must not happen mid-activation), and guarded: it does nothing when this runtime was
-- stopped meanwhile or when the lifecycle is no longer ACTIVE (someone else already owns the ending).
local function reportResolution(self: any, resolution: any)
    local capturedGeneration = self._generation
    local outcome: string = resolution.outcome
    local reason: string = resolution.reason
    self._deps.defer(function()
        if not self._running or self._generation ~= capturedGeneration then
            return
        end
        if not self._deps.lifecycle.isActive() then
            return
        end
        local ok, err = pcall(self._deps.lifecycle.endMission, outcome, reason)
        if not ok then
            log(self, "endMission raised: " .. tostring(err))
        end
    end)
end

-- Side effects of one APPLIED command, in a fixed order. Each step is isolated so a failure in one cannot leave the
-- Core inconsistent (it already committed) or skip the others; prompts heal on the next reconcile.
local function afterApplied(self: any, result: any)
    local ok, err = pcall(reconcile, self)
    if not ok then
        log(self, "reconcile raised: " .. tostring(err))
    end
    local sent, sendErr = pcall(broadcast, self)
    if not sent then
        log(self, "broadcast raised: " .. tostring(sendErr))
    end
    if result.resolution ~= nil then
        reportResolution(self, result.resolution)
    end
end

-- The handler body of every slot interaction. The player was already validated by InteractionService (mission active,
-- roster, ALIVE, character, target, distance, rate limit, busy, cooldown); the checks here are the single choke point
-- required by the design and the guard against stale registrations. Returns true only when a state change was applied
-- (so a rejected or duplicate activation consumes no cooldown). Synchronous and non-yielding.
local function contribute(self: any, capturedGeneration: number, objectiveId: string, slotId: string, player: any): boolean
    if not self._running or self._generation ~= capturedGeneration then
        return false
    end
    local deps = self._deps
    if not deps.lifecycle.isActive() then
        return false -- before ACTIVE (still INITIALIZING) or after the mission left ACTIVE
    end
    if not isConnectedRosterPlayer(self, player) then
        return false
    end
    local userId = deps.players.getUserId(player)
    local eligible = deps.players.isAlive(player) == true
    local result = self._core:contribute(objectiveId, slotId, userId, { eligible = eligible, now = deps.now() })
    if not result.ok or not result.changed then
        return false
    end
    afterApplied(self, result)
    return true
end

-- Raises on any problem so the lifecycle aborts the mission (ABORTED / initialization_failed); partial work is rolled
-- back first. `session.expectedUserIds` is the roster; the session table is never kept or mutated.
function Runtime.start(self: any, session: any)
    if self._running or self._core ~= nil then
        error("ObjectiveRuntime: already started")
    end
    local deps = self._deps

    local plan, code, subject = deps.graph.compile(deps.content)
    if plan == nil then
        local where = ""
        if subject ~= nil then
            where = " at " .. tostring(subject)
        end
        error(string.format("ObjectiveRuntime: invalid objective content (%s%s)", tostring(code), where))
    end

    local roster: { [number]: boolean } = {}
    local rosterList: { number } = {}
    local expected: any = nil
    if type(session) == "table" then
        expected = session.expectedUserIds
    end
    if type(expected) ~= "table" then
        error("ObjectiveRuntime: the session has no expectedUserIds")
    end
    for _, userId in ipairs(expected) do
        if type(userId) ~= "number" or userId % 1 ~= 0 or userId < 1 or roster[userId] then
            error("ObjectiveRuntime: invalid roster")
        end
        roster[userId] = true
        table.insert(rosterList, userId)
    end
    if #rosterList == 0 then
        error("ObjectiveRuntime: the roster is empty")
    end

    local core = deps.core.new(plan, deps.now())
    self._generation = self._generation + 1
    local capturedGeneration = self._generation
    self._plan = plan
    self._core = core
    self._roster = roster
    self._rosterList = rosterList
    self._slots = {}

    local function rollback(message: string)
        releaseSlots(self)
        self._core = nil
        self._plan = nil
        self._roster = {}
        self._rosterList = {}
        self._generation = self._generation + 1
        error(message, 0)
    end

    for _, objectiveId in ipairs(plan.order) do
        local definition = plan.objectives[objectiveId]
        local created: { any } = {}
        local failure: string? = nil
        for _, slotDefinition in ipairs(definition.slots) do
            local anchor = deps.resolveAnchor(slotDefinition.pointId)
            if anchor == nil then
                failure = "no anchor for point " .. slotDefinition.pointId
                break
            end
            local slotId: string = slotDefinition.id
            local handle, reason = deps.interaction.register(
                ObjectiveRuntime.buildSpec(deps.config, objectiveId, slotId),
                anchor,
                function(player: any): boolean
                    return contribute(self, capturedGeneration, objectiveId, slotId, player)
                end,
                ObjectiveRuntime.buildPromptOptions(deps.config, slotDefinition.label)
            )
            if handle == nil then
                failure = string.format("interaction %s rejected (%s)", ObjectiveRuntime.interactionId(objectiveId, slotId), tostring(reason))
                break
            end
            local entry = { objectiveId = objectiveId, slotId = slotId, handle = handle, applied = false }
            table.insert(created, entry)
            table.insert(self._slots, entry)
        end

        if failure ~= nil then
            -- A REQUIRED objective without its interactions can never complete: abort loudly instead of softlocking.
            -- An OPTIONAL one is cancelled (design 11.1) and the mission continues, provided the Core can cancel it
            -- (cancel is only defined from AVAILABLE / IN_PROGRESS); otherwise the content cannot be served: abort.
            if definition.importance == "REQUIRED" then
                rollback(string.format("ObjectiveRuntime: required objective %s cannot be bound: %s", objectiveId, failure))
            end
            local cancelled = core:cancel(objectiveId, "binding_failed", deps.now())
            if not cancelled.ok then
                rollback(string.format("ObjectiveRuntime: optional objective %s cannot be bound (%s) and cannot be cancelled (%s)", objectiveId, failure, tostring(cancelled.reason)))
            end
            log(self, string.format("optional objective %s cancelled: %s", objectiveId, failure))
            for _, entry in ipairs(created) do
                pcall(deps.interaction.unregister, entry.handle)
                for index = #self._slots, 1, -1 do
                    if self._slots[index] == entry then
                        table.remove(self._slots, index)
                    end
                end
            end
        end
    end

    self._running = true
    reconcile(self)
    broadcast(self)
end

-- Idempotent, safe after a partial start. Invalidates every captured handler (generation), unregisters the prompts
-- (the interaction service is still alive: consumers stop before it) and drops all state.
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

-- Answers a snapshot pull. Only connected roster members while running; the answer goes to the requester only and
-- repeats the current revision (clients drop duplicates).
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
function Runtime.getObjectiveState(self: any, objectiveId: string): string?
    local core = self._core
    if core == nil then
        return nil
    end
    return core:getState(objectiveId)
end

function Runtime.getResolution(self: any): any?
    local core = self._core
    if core == nil then
        return nil
    end
    return core:getResolution()
end

function Runtime.getRevision(self: any): number?
    local core = self._core
    if core == nil then
        return nil
    end
    return core:getRevision()
end

return ObjectiveRuntime
