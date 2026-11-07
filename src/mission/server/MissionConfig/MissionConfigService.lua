--!strict
-- MISSION mission-configuration owner (server-authoritative). Registers with MissionLifecycleService as the FIRST
-- mission system; its start callback runs while the mission is INITIALIZING and creates the one immutable
-- MissionConfig for this session (seed generated here, never by the HUB, never in the teleport payload).
-- Later systems register after it and read the configuration in their own start callbacks.
--
-- No remotes, no client access: the seed (with the content table) would reveal hidden mission facts.
-- Everything is synchronous (no timers, no yielding), so there are no delayed callbacks to guard.
--
-- Consumer contract for MissionConfigService.getConfig():
--   * the returned table is frozen: never try to mutate it;
--   * getConfig() returns nil before this system started and after its stop callback ran. Clearing the local
--     reference does not revoke references other systems already hold, so every consumer must drop its own
--     reference in its own stop callback;
--   * the lifecycle stops systems in reverse registration order, so dependent systems (registered later) stop
--     BEFORE this one and can still read the configuration inside their stop callbacks.
--
-- One-shot per server lifetime, like the lifecycle itself (the lifecycle clears its registrations on shutdown).

local ServerStorage = game:GetService("ServerStorage")

local MissionConfigCore = require(ServerStorage.ServerShared.MissionConfig.MissionConfigCore)
local SeededRandom = require(ServerStorage.ServerShared.MissionConfig.SeededRandom)
local MissionLifecycleService = require(script.Parent.Parent.MissionLifecycle.MissionLifecycleService)
local MissionContent = require(script.Parent.MissionContent)

export type MissionConfig = MissionConfigCore.MissionConfig

local SYSTEM_NAME = "MissionConfig"

local MissionConfigService = {}

local initialized = false
local contentProblem: string? = nil
local config: MissionConfig? = nil

-- The seed is not a secret, but it comes from the engine's own entropy, never from a global shared generator
-- that unrelated code could advance.
local function generateSeed(): number
    return Random.new():NextInteger(SeededRandom.MinSeed, SeededRandom.MaxSeed)
end

-- Runs inside MissionLifecycleService's pcall during INITIALIZING. Throwing aborts the mission with
-- ABORTED/"initialization_failed" (the lifecycle then also calls our stop and returns the players to the HUB).
local function start(session: any)
    if config ~= nil then
        error("MissionConfigService: configuration already created for this session") -- fail closed on duplicates
    end
    if contentProblem ~= nil then
        error("MissionConfigService: invalid mission content: " .. contentProblem)
    end
    if type(session) ~= "table" then
        error("MissionConfigService: missing mission session")
    end

    -- Read only the scalar fields needed. The lifecycle passes the same mutable session snapshot to every
    -- system: never mutate it and never keep its reference.
    local missionId = session.missionId
    local missionType = session.missionType

    local ok, result = MissionConfigCore.create({
        seed = generateSeed(),
        missionId = missionId,
        missionType = missionType,
        content = MissionContent,
    }, SeededRandom)
    if not ok then
        error("MissionConfigService: configuration rejected: " .. tostring(result))
    end

    local created: MissionConfig = result
    config = created
    print(
        string.format(
            "[THE LAST TURN][MissionConfig] Created mission configuration (missionId=%s, seed=%d, location=%s, contentVersion=%d).",
            created.missionId,
            created.seed,
            created.locationId,
            created.contentVersion
        )
    )
end

local function stop()
    config = nil
end

-- The frozen configuration, or nil before this system started / after it stopped.
function MissionConfigService.getConfig(): MissionConfig?
    return config
end

function MissionConfigService.isReady(): boolean
    return config ~= nil
end

-- Idempotent. Must run BEFORE MissionLifecycleService.init(): init() may start systems immediately when the
-- mission context is already READY, and registration is closed from then on. Invalid static content is logged and
-- makes the mission abort cleanly in start() (players are returned to the HUB) instead of crashing the bootstrap.
function MissionConfigService.init()
    if initialized then
        return
    end

    local contentOk, contentCode = MissionConfigCore.validateContent(MissionContent)
    if not contentOk then
        contentProblem = tostring(contentCode)
        warn("[THE LAST TURN][MissionConfig] Invalid mission content (" .. contentProblem .. "): missions will abort during initialization.")
    end

    local registered = MissionLifecycleService.registerSystem({
        name = SYSTEM_NAME,
        start = start,
        stop = stop,
    })
    if not registered then
        -- Deterministic programming error (wrong bootstrap order or duplicate registration): fail loudly.
        error("MissionConfigService: could not register with MissionLifecycleService; init() must run before MissionLifecycleService.init()")
    end
    initialized = true
end

return MissionConfigService
