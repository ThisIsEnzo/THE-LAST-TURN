--!strict
-- Server-side objective integration (TTL-09B). Thin Roblox glue around ObjectiveRuntime (pure, Lune-tested) and the
-- already-merged ObjectiveCore: it wires the real services into the runtime's injected ports, builds the greybox
-- anchors, registers the snapshot pull request and registers ONE mission lifecycle system. It owns no objective rules
-- and no interaction validation: InteractionService / InteractionCore validate every activation first (mission ACTIVE,
-- roster, ALIVE, character, target, distance, rate limit, busy, cooldown); the runtime then applies the command through
-- ObjectiveCore.
--
-- Lifecycle: init() registers the system AFTER InteractionService.init() (and DoorInteractionService.init()) and BEFORE
-- MissionLifecycleService.init(). start() runs inside the lifecycle's pcall while INITIALIZING (InteractionService has
-- already started) and THROWS on any problem, which aborts the mission (ABORTED / initialization_failed): a mission whose
-- required objectives cannot be bound must not run. stop() runs before InteractionService stops (reverse order), so
-- the prompts are unregistered while that service is alive.
--
-- Network: one request (`ObjectiveRequestSnapshot`, no payload, rate limited) and one notification
-- (`ObjectiveSnapshot`, full snapshot). No remote can complete, fail or modify anything.
--
-- Not here: team-wipe handling, extraction policy (EXTRACT is a dev placeholder), inventory/evidence/ritual, HUD.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local NetworkContract = require(ReplicatedStorage.Shared.Network.NetworkContract)
local PlayerLifecycle = require(ReplicatedStorage.Shared.Types.PlayerLifecycle)
local NetworkService = require(ServerStorage.ServerShared.Network.NetworkService)
local PlayerStateService = require(ServerStorage.ServerShared.Player.PlayerStateService)
local ObjectiveGraph = require(ServerStorage.ServerShared.Objective.ObjectiveGraph)
local ObjectiveCore = require(ServerStorage.ServerShared.Objective.ObjectiveCore)
local ObjectiveRuntime = require(ServerStorage.ServerShared.Objective.ObjectiveRuntime)
local InteractionService = require(script.Parent.Parent.Interaction.InteractionService)
local MissionLifecycleService = require(script.Parent.Parent.MissionLifecycle.MissionLifecycleService)
local ObjectiveConfig = require(script.Parent.ObjectiveConfig)
local ObjectiveContent = require(script.Parent.ObjectiveContent)
local ObjectiveFixture = require(script.Parent.ObjectiveFixture)

local SYSTEM_NAME = "Objective"
local LOG_PREFIX = "[THE LAST TURN]"

local Config = ObjectiveConfig.Values

local ObjectiveService = {}

local initialized = false
local runtime: any = nil
local fixture: ObjectiveFixture.Fixture? = nil
local requestRegistered = false

-- Point ids in content order, for the fixture.
local function collectPointIds(): { string }
    local pointIds: { string } = {}
    for _, objective in ipairs(ObjectiveContent.objectives) do
        for _, slot in ipairs(objective.completion.slots) do
            table.insert(pointIds, slot.pointId)
        end
    end
    return pointIds
end

local function buildPlayersPort(): any
    return {
        getUserId = function(player: any): number?
            return player.UserId
        end,
        getPlayer = function(userId: number): any?
            return Players:GetPlayerByUserId(userId)
        end,
        isConnected = function(player: any): boolean
            return player.Parent == Players
        end,
        isAlive = function(player: any): boolean
            return PlayerStateService.getState(player) == PlayerLifecycle.States.ALIVE
        end,
    }
end

local function cleanupFixture()
    local current = fixture
    fixture = nil
    if current ~= nil then
        pcall(function()
            current.model:Destroy()
        end)
    end
end

-- Runs inside MissionLifecycleService's pcall while the mission is INITIALIZING. Throws to abort.
local function start(session: any)
    if runtime ~= nil then
        error("Objective: already started")
    end
    if not InteractionService.isReady() then
        error("Objective: InteractionService is not ready; check the bootstrap and system order")
    end

    local built, builtFixture = pcall(ObjectiveFixture.build, collectPointIds(), Config)
    if not built then
        error("Objective: could not build the anchors: " .. tostring(builtFixture))
    end
    local newFixture = builtFixture :: ObjectiveFixture.Fixture
    fixture = newFixture

    local created = ObjectiveRuntime.new({
        graph = ObjectiveGraph,
        core = ObjectiveCore,
        content = ObjectiveContent,
        config = Config,
        interaction = InteractionService,
        resolveAnchor = function(pointId: string): any?
            return newFixture.anchors[pointId]
        end,
        lifecycle = MissionLifecycleService,
        players = buildPlayersPort(),
        send = function(player: any, payload: any)
            NetworkService.fireNotification(NetworkContract.Notifications.ObjectiveSnapshot, player, payload)
        end,
        defer = function(callback: () -> ())
            task.defer(callback)
        end,
        now = time,
        log = function(message: string)
            warn(LOG_PREFIX .. message)
        end,
    })
    runtime = created

    created:start(session) -- raises on invalid content, roster or binding problems; rolls back its own work

    NetworkService.registerRequest(NetworkContract.Requests.ObjectiveRequestSnapshot, {
        args = {},
        handler = function(player: Player)
            local active = runtime
            if active ~= nil then
                active:requestSnapshot(player)
            end
        end,
    })
    requestRegistered = true
end

-- Idempotent and safe after a partial or skipped start.
local function stop()
    if requestRegistered then
        requestRegistered = false
        pcall(NetworkService.unregisterRequest, NetworkContract.Requests.ObjectiveRequestSnapshot)
    end
    local active = runtime
    runtime = nil
    if active ~= nil then
        pcall(function()
            active:stop()
        end)
    end
    cleanupFixture()
end

-- Diagnostics: the current state of one objective ("LOCKED", "AVAILABLE", ...), or nil when not running.
function ObjectiveService.getObjectiveState(objectiveId: string): string?
    local active = runtime
    if active == nil then
        return nil
    end
    return active:getObjectiveState(objectiveId)
end

-- Idempotent. Must run after InteractionService.init() and BEFORE MissionLifecycleService.init(). Invalid configuration
-- or content is logged here; start() then aborts the mission with the same problem.
function ObjectiveService.init()
    if initialized then
        return
    end
    initialized = true

    local configOk, configDetail = ObjectiveConfig.validate(Config)
    if not configOk then
        warn(string.format("%s[Objective] Invalid configuration (%s): the mission will abort at start.", LOG_PREFIX, tostring(configDetail)))
    end
    local plan, code, subject = ObjectiveGraph.compile(ObjectiveContent)
    if plan == nil then
        warn(string.format("%s[Objective] Invalid objective content (%s at %s): the mission will abort at start.", LOG_PREFIX, tostring(code), tostring(subject)))
    end

    local registered = MissionLifecycleService.registerSystem({
        name = SYSTEM_NAME,
        start = start,
        stop = stop,
    })
    if not registered then
        initialized = false
        error("ObjectiveService: could not register with MissionLifecycleService; init() must run before MissionLifecycleService.init()")
    end
end

return ObjectiveService
