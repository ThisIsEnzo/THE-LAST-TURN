--!strict
-- Pure lifecycle rules and per-player state store. No Roblox services, so it is unit testable.
-- PlayerStateService wraps this with Roblox player/character events.
--
-- Lifecycle state is NOT character existence, Humanoid health, mission phase, party membership or
-- connection status. There is deliberately no transition back to ALIVE.

export type TransitionResult = {
    ok: boolean,
    changed: boolean, -- true only when the state actually changed
    from: string?,
    to: string?,
    rejection: string?, -- "invalid_state" | "unknown_player" | "forbidden_transition"
}

local States = table.freeze({
    ALIVE = "ALIVE",
    DEAD = "DEAD",
    GHOST = "GHOST",
    SPECTATING = "SPECTATING",
    RETURNING = "RETURNING",
})

local Transitions: { [string]: { [string]: boolean } } = table.freeze({
    ALIVE = table.freeze({ DEAD = true, RETURNING = true }),
    DEAD = table.freeze({ GHOST = true, SPECTATING = true, RETURNING = true }),
    GHOST = table.freeze({ SPECTATING = true, RETURNING = true }),
    SPECTATING = table.freeze({ RETURNING = true }),
    RETURNING = table.freeze({}), -- terminal for the current lifecycle
})

local PlayerStateCore = {}
PlayerStateCore.States = States
PlayerStateCore.InitialState = States.ALIVE

function PlayerStateCore.isValidState(value: any): boolean
    return type(value) == "string" and States[value :: string] ~= nil
end

-- Pure rule check. Same-state is NOT a transition (handled as idempotent by the store).
function PlayerStateCore.canTransition(from: string, to: string): (boolean, string?)
    if not PlayerStateCore.isValidState(from) or not PlayerStateCore.isValidState(to) then
        return false, "invalid_state"
    end
    if Transitions[from][to] == true then
        return true, nil
    end
    return false, "forbidden_transition"
end

type StoreData = {
    _states: { [number]: string },
    _count: number,
}

local Store = {}
Store.__index = Store

export type Store = typeof(setmetatable({} :: StoreData, Store))

function PlayerStateCore.new(): Store
    return setmetatable({ _states = {}, _count = 0 }, Store)
end

-- Registers a player in the initial state. Returns false if already registered (state untouched).
function Store.register(self: Store, key: number): boolean
    if self._states[key] ~= nil then
        return false
    end
    self._states[key] = PlayerStateCore.InitialState
    self._count += 1
    return true
end

function Store.unregister(self: Store, key: number): boolean
    if self._states[key] == nil then
        return false
    end
    self._states[key] = nil
    self._count -= 1
    return true
end

function Store.get(self: Store, key: number): string?
    return self._states[key]
end

function Store.count(self: Store): number
    return self._count
end

function Store.clear(self: Store)
    table.clear(self._states)
    self._count = 0
end

-- Order of checks: invalid state, unknown player, same state (idempotent), forbidden transition.
function Store.transition(self: Store, key: number, nextState: any): TransitionResult
    if not PlayerStateCore.isValidState(nextState) then
        return { ok = false, changed = false, from = self._states[key], to = nil, rejection = "invalid_state" }
    end
    local current = self._states[key]
    if current == nil then
        return { ok = false, changed = false, from = nil, to = nextState, rejection = "unknown_player" }
    end
    if current == nextState then
        return { ok = true, changed = false, from = current, to = current, rejection = nil }
    end
    local allowed = PlayerStateCore.canTransition(current, nextState)
    if not allowed then
        return { ok = false, changed = false, from = current, to = nextState, rejection = "forbidden_transition" }
    end
    self._states[key] = nextState
    return { ok = true, changed = true, from = current, to = nextState, rejection = nil }
end

return PlayerStateCore
