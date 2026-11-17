--!strict
-- Server-side evidence integration (TTL-11B). Thin Roblox glue around EvidenceRuntime (pure, Lune-tested) and the merged
-- EvidenceCore: it wires the real services into the runtime's injected ports, discovers the authored evidence sources
-- (parts tagged `EvidenceSource` with `EvidenceId` and `SourceId` attributes, found server-side in the Workspace), registers
-- the snapshot pull request and registers ONE mission lifecycle system. The sources belong to the map: this service never
-- creates, moves or destroys them. It owns no evidence rules and no interaction validation: InteractionService /
-- InteractionCore validate every activation first (mission ACTIVE, roster, ALIVE, character, target, server-measured
-- distance, rate limit, busy, cooldown); the runtime then applies the command through EvidenceCore.
--
-- Clients never send evidence ids, source ids, positions, distances, states or progress. The only thing a client can ask for
-- is the current snapshot.
--
-- Lifecycle: init() registers the system AFTER ObjectiveService.init() and BEFORE MissionLifecycleService.init(). start()
-- runs inside the lifecycle's pcall while INITIALIZING (InteractionService has already started) and THROWS on invalid
-- content or roster, which aborts the mission (ABORTED / initialization_failed). stop() runs before InteractionService
-- stops (reverse order), so the prompts are unregistered while that service is alive.
--
-- Network: one request (`EvidenceRequestSnapshot`, no payload, rate limited) and one notification (`EvidenceSnapshot`,
-- privacy-safe projection). No remote can observe, confirm or modify anything.
--
-- Not here: client ledger / HUD (TTL-11C), objective integration and entity evidence tables (TTL-11D), equipment, rituals.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local NetworkContract = require(ReplicatedStorage.Shared.Network.NetworkContract)
local PlayerLifecycle = require(ReplicatedStorage.Shared.Types.PlayerLifecycle)
local NetworkService = require(ServerStorage.ServerShared.Network.NetworkService)
local PlayerStateService = require(ServerStorage.ServerShared.Player.PlayerStateService)
local EvidenceCatalog = require(ServerStorage.ServerShared.Evidence.EvidenceCatalog)
local EvidenceCore = require(ServerStorage.ServerShared.Evidence.EvidenceCore)
local EvidenceRuntime = require(ServerStorage.ServerShared.Evidence.EvidenceRuntime)
local InteractionService = require(script.Parent.Parent.Interaction.InteractionService)
local MissionLifecycleService = require(script.Parent.Parent.MissionLifecycle.MissionLifecycleService)
local EvidenceConfig = require(script.Parent.EvidenceConfig)
local EvidenceContent = require(script.Parent.EvidenceContent)

local SYSTEM_NAME = "Evidence"
local LOG_PREFIX = "[THE LAST TURN]"

local Config = EvidenceConfig.Values

local EvidenceService = {}

local initialized = false
local runtime: any = nil
local requestRegistered = false

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

-- Reads the authored evidence sources from the Workspace. Only the server reads this; clients never supply sources.
local function collectSources(): { any }
    local candidates: { any } = {}
    for _, instance in ipairs(CollectionService:GetTagged(EvidenceRuntime.SourceTag)) do
        if instance:IsA("BasePart") and instance:IsDescendantOf(workspace) then
            table.insert(candidates, {
                evidenceId = instance:GetAttribute(EvidenceRuntime.EvidenceIdAttribute),
                sourceId = instance:GetAttribute(EvidenceRuntime.SourceIdAttribute),
                anchor = instance,
            })
        end
    end
    return candidates
end

-- Is the world object still present and usable right now? A future system can set the `Available` attribute to false.
local function isAvailable(anchor: any): boolean
    return anchor.Parent ~= nil and anchor:IsDescendantOf(workspace) and anchor:GetAttribute(EvidenceRuntime.AvailableAttribute) ~= false
end

-- Runs inside MissionLifecycleService's pcall while the mission is INITIALIZING. Throws to abort.
local function start(session: any)
    if runtime ~= nil then
        error("Evidence: already started")
    end
    if not InteractionService.isReady() then
        error("Evidence: InteractionService is not ready; check the bootstrap and system order")
    end
    local created = EvidenceRuntime.new({
        catalog = EvidenceCatalog,
        core = EvidenceCore,
        content = EvidenceContent,
        config = Config,
        interaction = InteractionService,
        collectSources = collectSources,
        isAvailable = isAvailable,
        lifecycle = MissionLifecycleService,
        players = buildPlayersPort(),
        send = function(player: any, payload: any)
            NetworkService.fireNotification(NetworkContract.Notifications.EvidenceSnapshot, player, payload)
        end,
        now = time,
        log = function(message: string)
            warn(LOG_PREFIX .. message)
        end,
    })
    runtime = created

    created:start(session) -- raises on invalid content or roster; rolls back its own work

    NetworkService.registerRequest(NetworkContract.Requests.EvidenceRequestSnapshot, {
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

-- Idempotent and safe after a partial or skipped start. Removes only what this service registered (prompts, the request
-- handler); the authored map is never touched.
local function stop()
    if requestRegistered then
        requestRegistered = false
        pcall(NetworkService.unregisterRequest, NetworkContract.Requests.EvidenceRequestSnapshot)
    end
    local active = runtime
    runtime = nil
    if active ~= nil then
        pcall(function()
            active:stop()
        end)
    end
end

-- Diagnostics: the current state of one evidence ("UNKNOWN", "OBSERVED", "CONFIRMED"), or nil when not running.
function EvidenceService.getEvidenceState(evidenceId: string): string?
    local active = runtime
    if active == nil then
        return nil
    end
    return active:getEvidenceState(evidenceId)
end

-- Idempotent. Must run after InteractionService.init() and BEFORE MissionLifecycleService.init(). Invalid configuration or
-- content is logged here; start() then aborts the mission with the same problem.
function EvidenceService.init()
    if initialized then
        return
    end
    initialized = true

    local configOk, configDetail = EvidenceConfig.validate(Config)
    if not configOk then
        warn(string.format("%s[Evidence] Invalid configuration (%s): the mission will abort at start.", LOG_PREFIX, tostring(configDetail)))
    end
    local plan, code, subject = EvidenceCatalog.compile(EvidenceContent)
    if plan == nil then
        warn(string.format("%s[Evidence] Invalid evidence content (%s at %s): the mission will abort at start.", LOG_PREFIX, tostring(code), tostring(subject)))
    end

    local registered = MissionLifecycleService.registerSystem({
        name = SYSTEM_NAME,
        start = start,
        stop = stop,
    })
    if not registered then
        initialized = false
        error("EvidenceService: could not register with MissionLifecycleService; init() must run before MissionLifecycleService.init()")
    end
end

return EvidenceService
