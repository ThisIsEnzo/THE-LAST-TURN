--!strict
-- First gameplay consumer of the interaction infrastructure (TTL-08C): one server-authoritative test door that
-- toggles between Closed and Open through InteractionService. It owns only door state, the door fixture and the
-- movement; every interaction validation (mission ACTIVE, expected roster, ALIVE, character, target, distance, rate
-- limit, busy, cooldown) stays in InteractionService / InteractionCore and is NOT repeated here. No RemoteEvent: the
-- client never controls door state, it only sees the replicated panel position.
--
-- Lifecycle: init() registers one mission system, AFTER InteractionService.init() and before
-- MissionLifecycleService.init(). The interaction is registered inside start() (InteractionService has already
-- started because systems start in registration order) and unregistered in stop() (consumers stop before it).
--
-- HANDLER: synchronous and non-yielding. The movement is a TweenService tween that is started and NOT waited for;
-- the final pose is guaranteed by a task.delay callback that runs outside the handler, guarded against staleness.
-- A transition is protected twice: the interaction cooldown (>= the transition time) and DoorCore's own deadline.
--
-- This consumer is optional demo/infrastructure proof: if the fixture or the registration fails it logs a warning and
-- the mission continues without the door. Only a wrong system order (InteractionService not ready) is a hard error.

local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local DoorCore = require(ServerStorage.ServerShared.Door.DoorCore)
local InteractionService = require(script.Parent.Parent.Interaction.InteractionService)
local MissionLifecycleService = require(script.Parent.Parent.MissionLifecycle.MissionLifecycleService)
local DoorConfig = require(script.Parent.DoorConfig)
local DoorFixture = require(script.Parent.DoorFixture)

local SYSTEM_NAME = "DoorInteraction"
local LOG_PREFIX = "[THE LAST TURN][Door]"

local Config = DoorConfig.Values

local DoorInteractionService = {}

local initialized = false
local running = false
local generation = 0
local transitionToken = 0
local door: DoorCore.Door? = nil
local fixture: DoorFixture.Fixture? = nil
local handle: InteractionService.RegistrationHandle? = nil
local activeTween: Tween? = nil

-- Movement --------------------------------------------------------------------------------------------------------

local function poseFor(current: DoorFixture.Fixture, state: string): CFrame
    if state == DoorCore.States.Open then
        return current.openCFrame
    end
    return current.closedCFrame
end

local function cancelTween()
    local tween = activeTween
    activeTween = nil
    if tween ~= nil then
        pcall(function()
            tween:Cancel()
        end)
    end
end

-- Puts the panel exactly in the pose of `state` (idempotent; never raises).
local function snapToState(state: string)
    local current = fixture
    if current == nil then
        return
    end
    pcall(function()
        current.panel.CFrame = poseFor(current, state)
    end)
end

-- Starts the movement toward `state` and returns immediately (a tween is started, never waited for). Falls back to
-- an instant move if the tween cannot be set up. Returns false only if the panel could not be moved at all.
local function applyMovement(state: string): boolean
    local current = fixture
    if current == nil or not current.panel:IsDescendantOf(workspace) then
        return false
    end
    local goal = poseFor(current, state)
    cancelTween()
    local started = pcall(function()
        local info = TweenInfo.new(Config.door.transitionSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
        local tween = TweenService:Create(current.panel, info, { CFrame = goal })
        tween:Play()
        activeTween = tween
    end)
    if started then
        return true
    end
    return pcall(function()
        current.panel.CFrame = goal
    end)
end

-- Guarantees the final pose after the transition window even if the tween was interrupted. Runs outside the
-- interaction handler; stale callbacks (service stopped, a newer transition started) do nothing.
local function scheduleFinalPose(state: string)
    transitionToken += 1
    local token = transitionToken
    local capturedGeneration = generation
    task.delay(Config.door.transitionSeconds, function()
        if not running or generation ~= capturedGeneration or transitionToken ~= token then
            return
        end
        activeTween = nil
        snapToState(state)
    end)
end

-- Interaction handler ---------------------------------------------------------------------------------------------

-- Synchronous, short, non-yielding. Returns true only when the door really changed state; false leaves the state
-- unchanged and (per InteractionCore) applies no cooldown. The player was already validated by InteractionService.
local function handleInteract(_player: Player): boolean
    local activeDoor = door
    if not running or activeDoor == nil then
        return false
    end
    local now = time()
    local target = activeDoor:planToggle(now)
    if target == nil then
        return false -- still transitioning (or invalid time): nothing changes
    end
    if not applyMovement(target) then
        return false -- movement failed before the state changed
    end
    local committed = activeDoor:commitToggle(target, now)
    if not committed then
        snapToState(activeDoor:getState()) -- cannot normally happen (one synchronous step); restore consistency
        return false
    end
    scheduleFinalPose(target)
    return true
end

-- Lifecycle -------------------------------------------------------------------------------------------------------

-- Runs inside MissionLifecycleService's pcall while the mission is INITIALIZING. The session is not used.
local function start(_session: any)
    if running then
        error("DoorInteraction: already started")
    end
    if not InteractionService.isReady() then
        -- Deterministic programming error: this system must be registered after InteractionService.init().
        error("DoorInteraction: InteractionService is not ready; check the bootstrap and system order")
    end

    local newDoor = DoorCore.new(Config.door)
    local built, builtFixture = pcall(DoorFixture.build, Config.fixture)
    if not built then
        warn(string.format("%s Could not build the test door fixture: %s", LOG_PREFIX, tostring(builtFixture)))
        return
    end
    local newFixture = builtFixture :: DoorFixture.Fixture

    pcall(function()
        newFixture.panel.CFrame = poseFor(newFixture, newDoor:getState())
    end)

    local newHandle, reason = InteractionService.register(
        DoorConfig.interactionSpec(Config),
        newFixture.anchor,
        handleInteract,
        DoorConfig.promptOptions(Config)
    )
    if newHandle == nil then
        pcall(function()
            newFixture.model:Destroy()
        end)
        warn(string.format("%s Could not register the door interaction: %s", LOG_PREFIX, tostring(reason)))
        return
    end

    door = newDoor
    fixture = newFixture
    handle = newHandle
    generation += 1
    transitionToken += 1
    running = true
end

-- Idempotent and safe after a partial or skipped start. Leaves the panel in the pose of the logical state (never
-- mid-swing), unregisters the interaction while InteractionService is still running (it stops after us) and
-- destroys the fixture this consumer created.
local function stop()
    running = false
    generation += 1
    transitionToken += 1
    cancelTween()

    local activeDoor = door
    if activeDoor ~= nil then
        snapToState(activeDoor:getState())
    end

    local currentHandle = handle
    handle = nil
    if currentHandle ~= nil then
        pcall(InteractionService.unregister, currentHandle)
    end

    local currentFixture = fixture
    fixture = nil
    door = nil
    if currentFixture ~= nil then
        pcall(function()
            currentFixture.model:Destroy()
        end)
    end
end

-- The logical door state ("Closed" / "Open"), or nil when the door is not running. For diagnostics.
function DoorInteractionService.getState(): string?
    local activeDoor = door
    if activeDoor == nil then
        return nil
    end
    return activeDoor:getState()
end

-- Idempotent. Must run after InteractionService.init() and BEFORE MissionLifecycleService.init(). A disabled or
-- invalid configuration registers nothing: the door is optional, so the mission is not aborted.
function DoorInteractionService.init()
    if initialized then
        return
    end
    initialized = true

    if not Config.enabled then
        return
    end
    local configOk, configDetail = DoorConfig.validate(Config)
    local doorOk, doorDetail = DoorCore.validateConfig(Config.door)
    if not configOk or not doorOk then
        warn(string.format("%s Invalid door configuration (%s): the door is disabled.", LOG_PREFIX, tostring(configDetail or doorDetail)))
        return
    end

    local registered = MissionLifecycleService.registerSystem({
        name = SYSTEM_NAME,
        start = start,
        stop = stop,
    })
    if not registered then
        initialized = false
        error("DoorInteractionService: could not register with MissionLifecycleService; init() must run before MissionLifecycleService.init()")
    end
end

return DoorInteractionService
