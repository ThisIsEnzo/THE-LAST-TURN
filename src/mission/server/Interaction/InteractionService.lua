--!strict
-- MISSION interaction adapter (TTL-08B-B). Server-only Roblox integration around the pure InteractionCore:
-- native ProximityPrompts, server-observed Triggered events, authoritative context building, a dedicated
-- per-player RateLimiter and cleanup through MissionLifecycleService. See docs/TTL-08B-B_INTERACTION_SERVICE.md.
--
-- It owns: the Core Store, the prompts it creates, their connections, the handle -> resource mapping, the limiter.
-- It does NOT own: gameplay effects or state (consumers do), player/mission lifecycle, client feedback. There is no
-- RemoteEvent: the only input is ProximityPrompt.Triggered on prompts this service created, and the engine-supplied
-- Player is the only trusted piece of it. Distance, eligibility, roster, mission state and time are all read on
-- the server for every activation.
--
-- HANDLER CONTRACT: the handler passed to register is synchronous, short and NON-YIELDING (no task.wait,
-- WaitForChild, DataStore, teleport or other yielding call, no asynchronous work). It is enforced by code review,
-- not by the runtime. A handler returns true only when its effect was applied; false or an error applies no cooldown.
--
-- Lifecycle: init() registers one mission system and must run after MissionConfigService.init() and before
-- MissionLifecycleService.init(). Consumers register interactions from their own lifecycle start() callbacks
-- (registered later, so they start after this system and stop before it). One-shot per server lifetime.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local PlayerLifecycle = require(ReplicatedStorage.Shared.Types.PlayerLifecycle)
local InteractionCore = require(ServerStorage.ServerShared.Interaction.InteractionCore)
local RateLimiter = require(ServerStorage.ServerShared.Network.RateLimiter)
local PlayerStateService = require(ServerStorage.ServerShared.Player.PlayerStateService)
local MissionLifecycleService = require(script.Parent.Parent.MissionLifecycle.MissionLifecycleService)
local InteractionConfig = require(script.Parent.InteractionConfig)

export type Spec = InteractionCore.Spec
export type RegistrationHandle = InteractionCore.RegistrationHandle
-- Synchronous, non-yielding. Returns true only when the effect was applied.
export type Handler = (player: Player) -> boolean

type Registration = {
    handle: RegistrationHandle,
    id: string,
    target: BasePart,
    prompt: ProximityPrompt,
    handler: Handler,
    connections: { RBXScriptConnection },
}

local SYSTEM_NAME = "Interaction"
local LOG_PREFIX = "[THE LAST TURN][Interaction]"

-- Core reasons that indicate an adapter/programming problem. Ordinary rejections (cooldown, range, state...) are
-- expected during play and are never logged.
local UNEXPECTED_REASONS: { [string]: boolean } = {
    [InteractionCore.Reasons.INVALID_HANDLE] = true,
    [InteractionCore.Reasons.INVALID_CONTEXT] = true,
    [InteractionCore.Reasons.INVALID_HOOKS] = true,
    [InteractionCore.Reasons.HOOK_ERROR] = true,
}

local Config = InteractionConfig.Values

local InteractionService = {}

local initialized = false
local configProblem: string? = nil
local ready = false
local generation = 0
local store: InteractionCore.Store? = nil
local limiter: RateLimiter.RateLimiter? = nil
local roster: { [number]: boolean } = {}
local registrations: { [RegistrationHandle]: Registration } = {}
local playerRemovingConnection: RBXScriptConnection? = nil

-- Cleanup ---------------------------------------------------------------------------------------------------------

-- Identity-guarded: acts only if this exact registration is still the active one for its handle, so an old
-- callback can never remove, or otherwise touch, a newer registration.
local function removeRegistration(registration: Registration)
    if registrations[registration.handle] ~= registration then
        return
    end
    registrations[registration.handle] = nil
    for _, connection in ipairs(registration.connections) do
        connection:Disconnect()
    end
    table.clear(registration.connections)
    registration.prompt:Destroy()
    local activeStore = store
    if activeStore ~= nil then
        activeStore:unregister(registration.handle)
    end
end

-- Authoritative facts -----------------------------------------------------------------------------------------------

local function isTargetAvailable(target: BasePart): boolean
    return target.Parent ~= nil and target:IsDescendantOf(workspace)
end

-- Never yields: no WaitForChild. Returns (available, rootPosition).
local function readCharacter(player: Player): (boolean, Vector3?)
    local character = player.Character
    if character == nil or not character:IsDescendantOf(workspace) then
        return false, nil
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
        return false, nil
    end
    return true, root.Position
end

-- A fresh context for every activation. Nothing here comes from the client.
local function buildContext(player: Player, registration: Registration): InteractionCore.Context
    local characterAvailable, rootPosition = readCharacter(player)
    local targetAvailable = isTargetAvailable(registration.target)

    local distance: number? = nil
    if characterAvailable and targetAvailable and rootPosition ~= nil then
        local raw = (rootPosition - registration.target.Position).Magnitude
        distance = InteractionConfig.coreDistance(raw, Config.distanceToleranceStuds)
    end

    return {
        missionActive = MissionLifecycleService.isActive(),
        isParticipant = roster[player.UserId] == true,
        playerEligible = PlayerStateService.getState(player) == PlayerLifecycle.States.ALIVE,
        characterAvailable = characterAvailable,
        targetAvailable = targetAvailable,
        distance = distance,
        now = time(),
    }
end

-- Activation ------------------------------------------------------------------------------------------------------

-- Runs on the server for every ProximityPrompt.Triggered of a prompt this service created. The transaction itself
-- (evaluate, token, evaluate, reserve, handler, complete) is delegated to InteractionCore.activate.
local function onTriggered(registration: Registration, capturedGeneration: number, player: Player)
    if not ready or capturedGeneration ~= generation or registrations[registration.handle] ~= registration then
        return -- stale: the service stopped or this registration was removed/replaced
    end
    if player.Parent ~= Players then
        return -- Roblox gave us the Player, but ignore players that are already leaving
    end
    local activeStore = store
    local activeLimiter = limiter
    if activeStore == nil or activeLimiter == nil then
        return
    end

    local context = buildContext(player, registration)
    local action = Config.rateLimit.action
    local result = activeStore:activate(registration.handle, context, {
        consumeToken = function(): boolean
            return activeLimiter:tryConsume(player.UserId, action)
        end,
        handler = function(): boolean
            return registration.handler(player)
        end,
    })

    if not result.ok and result.reason ~= nil and UNEXPECTED_REASONS[result.reason] then
        warn(string.format("%s Unexpected activation rejection for '%s': %s", LOG_PREFIX, registration.id, result.reason))
    end
end

local function logHandlerError(id: string, serial: number, message: string)
    -- Server log only: nothing about handler errors is ever sent to clients.
    warn(string.format("%s Handler for '%s' (registration #%d) failed:\n%s", LOG_PREFIX, id, serial, message))
end

-- Creates the prompt and its connections, or raises after cleaning up everything it created.
local function buildRegistration(
    handle: RegistrationHandle,
    state: InteractionCore.State,
    part: BasePart,
    handler: Handler,
    actionText: string,
    objectText: string
): Registration
    local prompt = Instance.new("ProximityPrompt")
    local connections: { RBXScriptConnection } = {}
    local registration: Registration = {
        handle = handle,
        id = state.id,
        target = part,
        prompt = prompt,
        handler = handler,
        connections = connections,
    }
    local capturedGeneration = generation

    local ok, err = pcall(function()
        prompt.Name = "InteractionPrompt"
        prompt.ActionText = actionText
        prompt.ObjectText = objectText
        prompt.HoldDuration = state.holdDuration
        prompt.MaxActivationDistance = InteractionConfig.effectiveRadius(state.maxDistance, Config.distanceToleranceStuds)
        prompt.RequiresLineOfSight = false -- v1: no line-of-sight validation (documented limitation)
        prompt.ClickablePrompt = true -- touch and mouse
        prompt.Enabled = state.enabled
        table.insert(
            connections,
            prompt.Triggered:Connect(function(player: Player)
                onTriggered(registration, capturedGeneration, player)
            end)
        )
        table.insert(
            connections,
            part.Destroying:Connect(function()
                removeRegistration(registration)
            end)
        )
        prompt.Parent = part
    end)
    if not ok then
        for _, connection in ipairs(connections) do
            connection:Disconnect()
        end
        prompt:Destroy()
        error(err, 0)
    end
    return registration
end

-- Public API ------------------------------------------------------------------------------------------------------

-- Registers one interaction on one target part (one registration per target; separate anchor parts for
-- multi-action objects). `spec` is an InteractionCore.Spec; `handler` follows the non-yielding contract.
-- `options` is optional: { actionText: string?, objectText: string? } overrides the generic prompt texts.
-- Returns (handle, nil) or (nil, reason). Reasons: service_unavailable, invalid_handler, invalid_options, invalid_target,
-- prompt_failed, or an InteractionCore reason (invalid_spec, invalid_target_key, duplicate_id, target_in_use). A
-- rejected call leaves no Core registration and no Roblox resource behind. Call it from a lifecycle start() callback.
function InteractionService.register(spec: any, target: any, handler: any, options: any): (RegistrationHandle?, string?)
    local activeStore = store
    if not ready or activeStore == nil then
        return nil, "service_unavailable"
    end
    if type(handler) ~= "function" then
        return nil, "invalid_handler"
    end
    local actionText: string = Config.prompt.actionText
    local objectText: string = Config.prompt.objectText
    if options ~= nil then
        local optionsOk = InteractionConfig.validatePromptOptions(options)
        if not optionsOk then
            return nil, "invalid_options"
        end
        if options.actionText ~= nil then
            actionText = options.actionText
        end
        if options.objectText ~= nil then
            objectText = options.objectText
        end
    end
    if typeof(target) ~= "Instance" then
        return nil, "invalid_target"
    end
    local instance = target :: Instance
    if not instance:IsA("BasePart") or not instance:IsDescendantOf(workspace) then
        return nil, "invalid_target"
    end
    local part = instance :: BasePart

    local handle, reason, detail = activeStore:register(spec, part)
    if handle == nil then
        if detail ~= nil then
            warn(string.format("%s register rejected (%s): %s", LOG_PREFIX, tostring(reason), detail))
        end
        return nil, reason
    end

    local state = activeStore:getState(handle)
    local built: any = nil
    local created = false
    if state ~= nil then
        created, built = pcall(buildRegistration, handle, state, part, handler :: Handler, actionText, objectText)
    end
    if not created then
        activeStore:unregister(handle) -- roll back: never leave an invisible active registration behind
        warn(string.format("%s Could not create the prompt for '%s': %s", LOG_PREFIX, handle.id, tostring(built)))
        return nil, "prompt_failed"
    end
    registrations[handle] = built :: Registration
    return handle, nil
end

-- Destroys the prompt, disconnects its connection and invalidates the handle. Returns (true, nil) or (false, reason)
-- with reason service_unavailable, invalid_handle (never issued by this service) or not_registered (stale).
function InteractionService.unregister(handle: any): (boolean, string?)
    local activeStore = store
    if not ready or activeStore == nil then
        return false, "service_unavailable"
    end
    local registration = registrations[handle]
    if registration == nil then
        return activeStore:unregister(handle) -- reports why; cannot affect another registration
    end
    removeRegistration(registration)
    return true, nil
end

-- Updates the Core state first and the prompt only if the Core accepted it. A stale or invalid handle, or a
-- non-boolean value, changes nothing.
function InteractionService.setEnabled(handle: any, enabled: any): (boolean, string?)
    local activeStore = store
    if not ready or activeStore == nil then
        return false, "service_unavailable"
    end
    local ok, reason = activeStore:setEnabled(handle, enabled)
    if not ok then
        return false, reason
    end
    local registration = registrations[handle]
    if registration ~= nil then
        registration.prompt.Enabled = enabled :: boolean
    end
    return true, nil
end

function InteractionService.isReady(): boolean
    return ready
end

-- Lifecycle -------------------------------------------------------------------------------------------------------

-- Runs inside MissionLifecycleService's pcall while the mission is INITIALIZING. Throwing aborts the mission
-- (ABORTED / initialization_failed). Nothing is published (ready stays false) until everything succeeded. The session
-- table is shared with every system: only the roster numbers are copied, the reference is never kept or mutated.
local function start(session: any)
    if ready or store ~= nil then
        error("InteractionService: already started")
    end
    if configProblem ~= nil then
        error("InteractionService: invalid configuration: " .. configProblem)
    end
    if type(session) ~= "table" or type(session.expectedUserIds) ~= "table" then
        error("InteractionService: the mission session has no expectedUserIds roster")
    end

    local newRoster: { [number]: boolean } = {}
    for _, userId in ipairs(session.expectedUserIds) do
        if type(userId) ~= "number" then
            error("InteractionService: invalid roster entry")
        end
        newRoster[userId] = true
    end

    local newStore = InteractionCore.new({ onHandlerError = logHandlerError })
    local limits: { [string]: RateLimiter.Limit } = {}
    limits[Config.rateLimit.action] = {
        capacity = Config.rateLimit.capacity,
        refillPerSecond = Config.rateLimit.refillPerSecond,
    }
    local newLimiter = RateLimiter.new(limits, time)

    -- Mirrors NetworkService: clear immediately and again after queued callbacks ran.
    local activeLimiter = newLimiter
    local connection = Players.PlayerRemoving:Connect(function(player: Player)
        local userId = player.UserId
        activeLimiter:removePlayer(userId)
        task.defer(function()
            activeLimiter:removePlayer(userId)
        end)
    end)

    roster = newRoster
    store = newStore
    limiter = newLimiter
    playerRemovingConnection = connection
    generation += 1
    ready = true
end

-- Idempotent and safe after a partial start. Order: unavailable first, then every resource, then state.
local function stop()
    ready = false
    generation += 1

    local connection = playerRemovingConnection
    playerRemovingConnection = nil
    if connection ~= nil then
        connection:Disconnect()
    end

    local pending: { Registration } = {}
    for _, registration in pairs(registrations) do
        table.insert(pending, registration)
    end
    for _, registration in ipairs(pending) do
        removeRegistration(registration)
    end
    table.clear(registrations)

    local activeStore = store
    store = nil
    limiter = nil
    table.clear(roster)
    if activeStore ~= nil then
        activeStore:clear()
    end
end

-- Idempotent. Must run after MissionConfigService.init() and BEFORE MissionLifecycleService.init(): init() may start
-- systems immediately when the mission context is already READY, and registration closes from then on. An invalid
-- configuration is logged here and makes start() throw, so the mission aborts cleanly instead of crashing the bootstrap.
function InteractionService.init()
    if initialized then
        return
    end

    local configOk, configCode = InteractionConfig.validate(Config)
    if not configOk then
        configProblem = tostring(configCode)
        warn(string.format("%s Invalid configuration (%s): missions will abort during initialization.", LOG_PREFIX, configProblem))
    end

    local registered = MissionLifecycleService.registerSystem({
        name = SYSTEM_NAME,
        start = start,
        stop = stop,
    })
    if not registered then
        -- Deterministic programming error (wrong bootstrap order): fail loudly.
        error("InteractionService: could not register with MissionLifecycleService; init() must run before MissionLifecycleService.init()")
    end
    initialized = true
end

return InteractionService
