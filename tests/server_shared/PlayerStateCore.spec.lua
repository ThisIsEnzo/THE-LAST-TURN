--!strict
local Harness = require("../Harness")
local PlayerStateCore = require("../../src/server_shared/Player/PlayerStateCore")
local PlayerLifecycle = require("../../src/shared/Types/PlayerLifecycle")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local ALL_STATES = { "ALIVE", "DEAD", "GHOST", "SPECTATING", "RETURNING" }

-- Independent restatement of the approved graph (docs/ARCHITECTURE.md), deliberately not read from the module.
local ALLOWED: { [string]: { [string]: boolean } } = {
    ALIVE = { DEAD = true, RETURNING = true },
    DEAD = { GHOST = true, SPECTATING = true, RETURNING = true },
    GHOST = { SPECTATING = true, RETURNING = true },
    SPECTATING = { RETURNING = true },
    RETURNING = {},
}

-- Creates a store with player `key` forced into `state` through legal transitions only.
local PATHS: { [string]: { string } } = {
    ALIVE = {},
    DEAD = { "DEAD" },
    GHOST = { "DEAD", "GHOST" },
    SPECTATING = { "DEAD", "SPECTATING" },
    RETURNING = { "RETURNING" },
}

local function storeWith(key: number, state: string)
    local store = PlayerStateCore.new()
    store:register(key)
    for _, step in ipairs(PATHS[state]) do
        expectTrue(store:transition(key, step).ok, "setup transition to " .. step)
    end
    expectEqual(store:get(key), state)
    return store
end

test("shared vocabulary matches core states", function()
    expectEqual(PlayerLifecycle.States.ALIVE, PlayerStateCore.States.ALIVE)
    for _, state in ipairs(ALL_STATES) do
        expectEqual((PlayerLifecycle.States :: any)[state], state)
        expectEqual((PlayerStateCore.States :: any)[state], state)
    end
    expectEqual(type(PlayerLifecycle.StateAttribute), "string")
end)

test("every allowed transition succeeds and reports a change", function()
    for from, targets in pairs(ALLOWED) do
        for to in pairs(targets) do
            local store = storeWith(1, from)
            local result = store:transition(1, to)
            expectTrue(result.ok, from .. " -> " .. to)
            expectTrue(result.changed, from .. " -> " .. to .. " changed")
            expectEqual(result.from, from)
            expectEqual(result.to, to)
            expectEqual(store:get(1), to)
            expectTrue(PlayerStateCore.canTransition(from, to))
        end
    end
end)

test("every forbidden transition is rejected and leaves state unchanged", function()
    for _, from in ipairs(ALL_STATES) do
        for _, to in ipairs(ALL_STATES) do
            if from ~= to and not ALLOWED[from][to] then
                local store = storeWith(1, from)
                local result = store:transition(1, to)
                expectFalse(result.ok, from .. " -> " .. to)
                expectFalse(result.changed)
                expectEqual(result.rejection, "forbidden_transition", from .. " -> " .. to)
                expectEqual(store:get(1), from, "state must be unchanged")
                local allowed, reason = PlayerStateCore.canTransition(from, to)
                expectFalse(allowed)
                expectEqual(reason, "forbidden_transition")
            end
        end
    end
end)

test("nothing transitions back to ALIVE", function()
    for _, from in ipairs({ "DEAD", "GHOST", "SPECTATING", "RETURNING" }) do
        local result = storeWith(1, from):transition(1, "ALIVE")
        expectFalse(result.ok, from .. " -> ALIVE")
        expectEqual(result.rejection, "forbidden_transition")
    end
end)

test("RETURNING is terminal", function()
    for _, to in ipairs(ALL_STATES) do
        if to ~= "RETURNING" then
            local store = storeWith(1, "RETURNING")
            expectFalse(store:transition(1, to).ok, "RETURNING -> " .. to)
            expectEqual(store:get(1), "RETURNING")
        end
    end
end)

test("same-state transition is idempotent: ok, unchanged, no change flag", function()
    for _, state in ipairs(ALL_STATES) do
        local store = storeWith(1, state)
        local result = store:transition(1, state)
        expectTrue(result.ok, state .. " -> " .. state)
        expectFalse(result.changed, "must not report a change for " .. state)
        expectEqual(result.rejection, nil)
        expectEqual(store:get(1), state)
    end
end)

test("invalid state values are rejected", function()
    local store = storeWith(1, "ALIVE")
    for _, bad in ipairs({ "alive", "ZOMBIE", "", 5, true }) do
        local result = store:transition(1, bad)
        expectFalse(result.ok)
        expectEqual(result.rejection, "invalid_state")
    end
    expectFalse(store:transition(1, nil).ok)
    expectFalse(store:transition(1, {}).ok)
    expectEqual(store:get(1), "ALIVE")
    expectFalse(PlayerStateCore.isValidState("alive"))
    expectFalse(PlayerStateCore.isValidState(nil))
    expectFalse((PlayerStateCore.canTransition("ALIVE", "bogus")))
end)

test("unknown player is rejected", function()
    local store = PlayerStateCore.new()
    local result = store:transition(42, "DEAD")
    expectFalse(result.ok)
    expectEqual(result.rejection, "unknown_player")
    expectEqual(store:get(42), nil)
    expectEqual(store:count(), 0, "rejected request must not create state")
end)

test("registration starts at ALIVE and is idempotent", function()
    local store = PlayerStateCore.new()
    expectTrue(store:register(1))
    expectEqual(store:get(1), "ALIVE")
    store:transition(1, "DEAD")
    expectFalse(store:register(1), "second registration is rejected")
    expectEqual(store:get(1), "DEAD", "re-registration must not reset state")
    expectEqual(store:count(), 1)
end)

test("players have independent state", function()
    local store = PlayerStateCore.new()
    store:register(1)
    store:register(2)
    store:register(3)
    store:transition(1, "DEAD")
    store:transition(1, "GHOST")
    store:transition(2, "RETURNING")
    expectEqual(store:get(1), "GHOST")
    expectEqual(store:get(2), "RETURNING")
    expectEqual(store:get(3), "ALIVE")
end)

test("unregister removes state; re-registration starts fresh", function()
    local store = PlayerStateCore.new()
    store:register(1)
    store:transition(1, "DEAD")
    expectTrue(store:unregister(1))
    expectFalse(store:unregister(1), "idempotent")
    expectEqual(store:get(1), nil)
    expectEqual(store:count(), 0)
    expectFalse(store:transition(1, "GHOST").ok)
    expectTrue(store:register(1))
    expectEqual(store:get(1), "ALIVE")
end)

test("clear and reinitialization leave no stale state", function()
    local store = PlayerStateCore.new()
    for key = 1, 50 do
        store:register(key)
    end
    expectEqual(store:count(), 50)
    store:clear()
    expectEqual(store:count(), 0)
    expectEqual(store:get(1), nil)
    local fresh = PlayerStateCore.new()
    expectEqual(fresh:count(), 0)
    expectTrue(fresh:register(1))
end)

test("results are fresh tables; internal state cannot be mutated through them", function()
    local store = storeWith(1, "ALIVE")
    local first = store:transition(1, "DEAD")
    first.to = "ALIVE"
    first.ok = false
    expectEqual(store:get(1), "DEAD")
    local second = store:transition(1, "DEAD")
    expectTrue(second.ok)
    expectFalse(first == second)
end)

test("state table cannot be altered by mutating module constants", function()
    expectTrue(table.isfrozen(PlayerStateCore.States))
    expectTrue(table.isfrozen(PlayerLifecycle.States))
    Harness.expectError(function()
        (PlayerStateCore.States :: any).ALIVE = "X"
    end)
end)

return {}
