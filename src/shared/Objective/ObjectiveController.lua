--!strict
-- Client orchestration of the objective snapshot (TTL-09C; pure, Lune-tested). It owns one ObjectiveView (the mirror of
-- the last accepted server snapshot), decides when to pull a fresh snapshot, and tells the UI when something changed. It
-- never talks to a RemoteEvent itself: every collaborator is injected through `deps`, like every pure module in this
-- repository (the Roblox wiring is src/mission/client/Objective/ObjectiveNetwork.lua). The server stays authoritative: this
-- module has no way to complete, fail, cancel or change an objective, and the only request it can cause is the
-- payload-less snapshot pull of TTL-09B.
--
-- Synchronization (design 8.2):
--   * the server pushes a full snapshot at mission start, when this client's listener may not exist yet, and after every
--     applied command; the push at start can therefore be missed;
--   * so the controller connects its listener FIRST and pulls the current snapshot only after the port reports the
--     listener ready (`onReady`). A snapshot that arrives before or after the pull is handled by the view's revision
--     rule (strictly newer wins; duplicates and stale payloads change nothing, so no notification is emitted);
--   * if no valid snapshot has been accepted a few seconds after the pull, it pulls again (bounded: the server rate limit
--     is 3 requests with a slow refill), and a malformed payload triggers one throttled refresh (also bounded).
-- Nothing yields here and nothing polls: at most one delayed retry exists at a time.

local ObjectiveController = {}

ObjectiveController.RetrySeconds = 4 -- wait for a first valid snapshot before pulling again
ObjectiveController.MaxSyncAttempts = 3 -- pulls while still unsynced (matches the server's burst of 3)
ObjectiveController.MinRequestIntervalSeconds = 2 -- never pull faster than the server's sustained rate
ObjectiveController.MaxMalformedRefreshes = 2 -- refreshes caused by malformed payloads without a valid one in between

export type Deps = {
    view: any, -- ObjectiveView module (needs .new and .Status)
    -- Connects the snapshot listener, possibly asynchronously (it may wait for the remote). Calls `onReady` once the
    -- listener is connected and `onFailed` if it never will be. Returns a function that cancels/disconnects everything.
    connect: (handler: (payload: any) -> (), onReady: () -> (), onFailed: (reason: string) -> ()) -> () -> (),
    requestSnapshot: () -> (), -- sends the payload-less pull
    schedule: (delaySeconds: number, callback: () -> ()) -> () -> (), -- returns a cancel function
    now: () -> number,
    log: (message: string) -> (),
}

local Controller = {}
Controller.__index = Controller

export type Controller = typeof(setmetatable({} :: { [string]: any }, Controller))

local function isDeps(deps: any): boolean
    if type(deps) ~= "table" or type(deps.view) ~= "table" or type(deps.view.new) ~= "function" or type(deps.view.Status) ~= "table" then
        return false
    end
    for _, name in ipairs({ "connect", "requestSnapshot", "schedule", "now", "log" }) do
        if type(deps[name]) ~= "function" then
            return false
        end
    end
    return true
end

function ObjectiveController.new(deps: Deps): Controller
    if not isDeps(deps) then
        error("ObjectiveController.new: incomplete dependencies", 2)
    end
    return setmetatable({
        _deps = deps,
        _view = deps.view.new(),
        _started = false,
        _generation = 0,
        _ready = false,
        _attempts = 0,
        _malformedRefreshes = 0,
        _lastRequestAt = nil,
        _cancelConnect = nil,
        _cancelRetry = nil,
        _changeListeners = {},
        _transitionListeners = {},
        _nextListenerId = 0,
    }, Controller)
end

local function log(self: any, message: string)
    self._deps.log("[Objective] " .. message)
end

local function notify(self: any, listeners: { [number]: any }, ...: any)
    for _, listener in pairs(listeners) do
        local ok, err = pcall(listener, ...)
        if not ok then
            log(self, "listener failed: " .. tostring(err))
        end
    end
end

local function cancelRetry(self: any)
    local cancel = self._cancelRetry
    self._cancelRetry = nil
    if cancel ~= nil then
        pcall(cancel)
    end
end

-- One throttled pull. Returns whether a request was actually sent.
local function requestFresh(self: any, reason: string): boolean
    local deps = self._deps
    local now = deps.now()
    local last = self._lastRequestAt
    if last ~= nil and now - last < ObjectiveController.MinRequestIntervalSeconds then
        return false
    end
    self._lastRequestAt = now
    self._attempts = self._attempts + 1
    local ok, err = pcall(deps.requestSnapshot)
    if not ok then
        log(self, string.format("snapshot request (%s) failed: %s", reason, tostring(err)))
    end
    return ok
end

-- While no valid snapshot was accepted, pull again after RetrySeconds, at most MaxSyncAttempts pulls in total.
local function scheduleRetry(self: any, capturedGeneration: number)
    cancelRetry(self)
    if self._view:isSynced() or self._attempts >= ObjectiveController.MaxSyncAttempts then
        return
    end
    self._cancelRetry = self._deps.schedule(ObjectiveController.RetrySeconds, function()
        if not self._started or self._generation ~= capturedGeneration then
            return
        end
        self._cancelRetry = nil
        if self._view:isSynced() then
            return
        end
        requestFresh(self, "retry")
        scheduleRetry(self, capturedGeneration)
    end)
end

local function onReady(self: any, capturedGeneration: number)
    if not self._started or self._generation ~= capturedGeneration or self._ready then
        return
    end
    self._ready = true
    requestFresh(self, "initial") -- the listener exists now: pull the current state once
    scheduleRetry(self, capturedGeneration)
end

local function onFailed(self: any, capturedGeneration: number, reason: string)
    if not self._started or self._generation ~= capturedGeneration then
        return
    end
    log(self, "snapshot listener unavailable: " .. tostring(reason))
end

local function onPayload(self: any, capturedGeneration: number, payload: any)
    if not self._started or self._generation ~= capturedGeneration then
        return -- destroyed or restarted: a late delivery must change nothing
    end
    local Status = self._deps.view.Status
    local status, events = self._view:applySnapshot(payload)
    if status == Status.Applied then
        self._malformedRefreshes = 0
        cancelRetry(self)
        notify(self, self._changeListeners)
        if #events > 0 then
            notify(self, self._transitionListeners, events)
        end
    elseif status == Status.Malformed then
        log(self, "ignored a malformed objective snapshot")
        if self._ready and self._malformedRefreshes < ObjectiveController.MaxMalformedRefreshes then
            if requestFresh(self, "malformed") then
                self._malformedRefreshes = self._malformedRefreshes + 1
            end
        end
    end
    -- duplicate / stale: nothing changed, nothing to announce
end

-- Idempotent: a second call neither reconnects nor pulls again.
function Controller.start(self: Controller)
    local data: any = self
    if data._started then
        return
    end
    data._started = true
    data._generation = data._generation + 1
    data._ready = false
    data._attempts = 0
    data._malformedRefreshes = 0
    data._lastRequestAt = nil
    data._view:reset()
    local capturedGeneration: number = data._generation
    local cancel = data._deps.connect(function(payload: any)
        onPayload(data, capturedGeneration, payload)
    end, function()
        onReady(data, capturedGeneration)
    end, function(reason: string)
        onFailed(data, capturedGeneration, reason)
    end)
    data._cancelConnect = cancel
end

-- Disconnects, cancels the pending retry, forgets the mirrored state and every listener. Idempotent; a delivery or timer
-- that fires afterwards is ignored (generation guard).
function Controller.destroy(self: Controller)
    local data: any = self
    data._started = false
    data._generation = data._generation + 1
    data._ready = false
    cancelRetry(data)
    local cancel = data._cancelConnect
    data._cancelConnect = nil
    if cancel ~= nil then
        pcall(cancel)
    end
    data._view:reset()
    data._changeListeners = {}
    data._transitionListeners = {}
end

function Controller.isStarted(self: Controller): boolean
    return (self :: any)._started
end

function Controller.isSynced(self: Controller): boolean
    return (self :: any)._view:isSynced()
end

function Controller.getRevision(self: Controller): number
    return (self :: any)._view:getRevision()
end

-- A fresh copy of the mirrored state (empty and unsynced before the first valid snapshot and after destroy).
function Controller.getViewModel(self: Controller): any
    return (self :: any)._view:getViewModel()
end

local function addListener(self: any, field: string, listener: any): () -> ()
    self._nextListenerId = self._nextListenerId + 1
    local id = self._nextListenerId
    self[field][id] = listener
    return function()
        self[field][id] = nil
    end
end

-- Called after every ACCEPTED snapshot (never for duplicates, stale or malformed payloads).
function Controller.onChanged(self: Controller, listener: () -> ()): () -> ()
    return addListener(self, "_changeListeners", listener)
end

-- Called with the list of player-relevant transitions of an accepted snapshot (never for the first snapshot).
function Controller.onTransition(self: Controller, listener: (events: { any }) -> ()): () -> ()
    return addListener(self, "_transitionListeners", listener)
end

return ObjectiveController
