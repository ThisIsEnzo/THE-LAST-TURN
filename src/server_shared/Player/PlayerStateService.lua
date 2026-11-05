--!strict
-- Server-authoritative player lifecycle (ALIVE / DEAD / GHOST / SPECTATING / RETURNING).
-- Shared by HUB and MISSION via ServerStorage.ServerShared. Rules and storage live in the pure
-- PlayerStateCore; this module only adds Roblox player/character event handling.
--
-- Lifecycle state is separate from character existence: CharacterAdded/Removing never change it,
-- and nothing here ever moves a player back to ALIVE. Humanoid.Died moves ALIVE -> DEAD only.
-- Clients cannot request transitions: there is no remote. The state is projected to clients through
-- a server-owned Player attribute (read-only for them). Transition reasons stay on the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerLifecycle = require(ReplicatedStorage.Shared.Types.PlayerLifecycle)
local PlayerStateCore = require(script.Parent.PlayerStateCore)

export type TransitionResult = PlayerStateCore.TransitionResult

-- Server-side listener: (player, fromState, toState, reason). Fired only on real changes.
export type StateChangedListener = (player: Player, from: string, to: string, reason: string?) -> ()

type PlayerRecord = {
    characterToken: number, -- bumped on every character change; invalidates stale callbacks
    characterConnections: { RBXScriptConnection },
    playerConnections: { RBXScriptConnection },
}

local PlayerStateService = {}

local initialized = false
local store: PlayerStateCore.Store? = nil
local records: { [Player]: PlayerRecord } = {}
local serviceConnections: { RBXScriptConnection } = {}
local listeners: { [number]: StateChangedListener } = {}
local nextListenerId = 0

local function reject(rejection: string, from: string?, to: string?): TransitionResult
    return { ok = false, changed = false, from = from, to = to, rejection = rejection }
end

local function disconnectAll(connections: { RBXScriptConnection })
    for index, connection in ipairs(connections) do
        connection:Disconnect()
        connections[index] = nil
    end
end

local function setAttribute(player: Player, state: string?)
    player:SetAttribute(PlayerLifecycle.StateAttribute, state)
end

local function fireStateChanged(player: Player, from: string, to: string, reason: string?)
    -- Copy so listeners may unsubscribe while we iterate.
    local snapshot: { StateChangedListener } = {}
    for _, listener in pairs(listeners) do
        table.insert(snapshot, listener)
    end
    for _, listener in ipairs(snapshot) do
        local ok, err = pcall(listener, player, from, to, reason)
        if not ok then
            warn("[THE LAST TURN][PlayerState] Listener error: " .. tostring(err))
        end
    end
end

-- Returns the current state, or nil for unregistered players.
function PlayerStateService.getState(player: Player): string?
    if store == nil or records[player] == nil then
        return nil
    end
    return store:get(player.UserId)
end

function PlayerStateService.isInState(player: Player, state: string): boolean
    return PlayerStateService.getState(player) == state
end

-- Validated transition. Same-state requests succeed without side effects (changed = false).
-- Always returns a fresh table; never exposes internal state.
function PlayerStateService.transition(player: Player, nextState: string, reason: string?): TransitionResult
    local activeStore = store
    if not initialized or activeStore == nil then
        return reject("not_initialized", nil, nil)
    end
    if reason ~= nil and type(reason) ~= "string" then
        return reject("invalid_reason", nil, nil)
    end
    if not PlayerStateCore.isValidState(nextState) then
        return reject("invalid_state", nil, nil)
    end
    if typeof(player :: any) ~= "Instance" or records[player] == nil then
        return reject("unknown_player", nil, nextState)
    end

    local result = activeStore:transition(player.UserId, nextState)
    if result.ok and result.changed then
        setAttribute(player, result.to)
        fireStateChanged(player, result.from :: string, result.to :: string, reason)
    end
    return result
end

-- Subscribes a server system to state changes. Returns an unsubscribe function.
function PlayerStateService.onStateChanged(listener: StateChangedListener): () -> ()
    nextListenerId += 1
    local id = nextListenerId
    listeners[id] = listener
    return function()
        listeners[id] = nil
    end
end

local function unbindCharacter(record: PlayerRecord)
    record.characterToken += 1
    disconnectAll(record.characterConnections)
end

local function handleDeath(player: Player, record: PlayerRecord, token: number)
    if records[player] ~= record or record.characterToken ~= token then
        return -- stale callback from a previous character or an unregistered player
    end
    -- Rejections are expected and intentionally ignored here: a death event while not ALIVE
    -- (duplicate event, or a later character dying in GHOST/SPECTATING) must not change state.
    PlayerStateService.transition(player, PlayerStateCore.States.DEAD, "humanoid_died")
end

local function bindCharacter(player: Player, record: PlayerRecord, character: Model)
    unbindCharacter(record) -- also invalidates callbacks of the previous character
    local token = record.characterToken
    local humanoidBound = false

    local function bindHumanoid(humanoid: Humanoid)
        if humanoidBound or records[player] ~= record or record.characterToken ~= token then
            return
        end
        humanoidBound = true
        table.insert(
            record.characterConnections,
            humanoid.Died:Connect(function()
                handleDeath(player, record, token)
            end)
        )
        -- A character that spawns already dead never fires Died.
        if humanoid.Health <= 0 then
            handleDeath(player, record, token)
        end
    end

    local existing = character:FindFirstChildOfClass("Humanoid")
    if existing then
        bindHumanoid(existing)
    else
        -- No wait loop: listen until a Humanoid appears; the connection is dropped when the
        -- character is replaced/removed or the player is unregistered.
        local childAdded: RBXScriptConnection
        childAdded = character.ChildAdded:Connect(function(child: Instance)
            if child:IsA("Humanoid") then
                childAdded:Disconnect()
                bindHumanoid(child)
            end
        end)
        table.insert(record.characterConnections, childAdded)
    end
end

-- Registers a player in the initial state (ALIVE). Idempotent: returns false, without resetting
-- anything, if the player is already registered or is leaving.
function PlayerStateService.registerPlayer(player: Player): boolean
    assert(initialized and store ~= nil, "PlayerStateService.init() must run before registerPlayer")
    if records[player] ~= nil or player.Parent ~= Players then
        return false
    end
    if not (store :: PlayerStateCore.Store):register(player.UserId) then
        return false
    end

    local record: PlayerRecord = { characterToken = 0, characterConnections = {}, playerConnections = {} }
    records[player] = record
    setAttribute(player, PlayerStateCore.InitialState)

    table.insert(
        record.playerConnections,
        player.CharacterAdded:Connect(function(character: Model)
            bindCharacter(player, record, character)
        end)
    )
    table.insert(
        record.playerConnections,
        player.CharacterRemoving:Connect(function()
            unbindCharacter(record)
        end)
    )
    if player.Character then
        bindCharacter(player, record, player.Character)
    end
    return true
end

-- Removes all state and connections for a player. Idempotent.
function PlayerStateService.unregisterPlayer(player: Player): boolean
    local record = records[player]
    if record == nil then
        return false
    end
    records[player] = nil
    unbindCharacter(record)
    disconnectAll(record.playerConnections)
    if store ~= nil then
        store:unregister(player.UserId)
    end
    return true
end

-- Idempotent. Call after NetworkService.init() in each server bootstrap.
function PlayerStateService.init()
    if initialized then
        return
    end
    store = PlayerStateCore.new()
    initialized = true

    -- Connect first, then register existing players; registerPlayer is idempotent so no gap/duplicates.
    table.insert(
        serviceConnections,
        Players.PlayerAdded:Connect(function(player: Player)
            PlayerStateService.registerPlayer(player)
        end)
    )
    table.insert(
        serviceConnections,
        Players.PlayerRemoving:Connect(function(player: Player)
            PlayerStateService.unregisterPlayer(player)
        end)
    )
    for _, player in ipairs(Players:GetPlayers()) do
        PlayerStateService.registerPlayer(player)
    end
end

-- Disconnects everything, clears state and replicated attributes. init() may run again. Idempotent.
function PlayerStateService.shutdown()
    if not initialized then
        return
    end
    disconnectAll(serviceConnections)
    local registered: { Player } = {}
    for player in pairs(records) do
        table.insert(registered, player)
    end
    for _, player in ipairs(registered) do
        PlayerStateService.unregisterPlayer(player)
        setAttribute(player, nil)
    end
    if store ~= nil then
        store:clear()
    end
    store = nil
    table.clear(listeners)
    initialized = false
end

return PlayerStateService
