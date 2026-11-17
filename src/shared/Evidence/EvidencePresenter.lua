--!strict
-- Presentation logic of the evidence HUD (TTL-11C; pure, Lune-tested). It turns the mirrored server state into a small
-- render state, owns the journal open/closed flag, and drives a UI PORT (the Roblox EvidenceHud) through a few calls. It
-- contains no Roblox API, no remote and no evidence rule: the controller supplies server-authoritative state, the UI port
-- draws it, and nothing here can discover, confirm or change evidence. Like every pure module in this repository it requires
-- no other module; the controller, UI port and text catalogue are injected.
--
-- Responsibilities:
--   * one UI instance only: `start` is idempotent, so a respawn, a second start call or a restarted mission can never create
--     a second HUD or a second set of subscriptions (the HUD is not tied to the character at all);
--   * render the compact counter and the journal from the controller's view model, only for DISCOVERED evidence (the view
--     model contains nothing else), with no placeholder rows that could hint at undiscovered evidence;
--   * announce a transition once: the controller emits events only for accepted, strictly newer snapshots and never for the
--     baseline, so duplicates and evidence that was already known produce no toast; several discoveries in one snapshot share
--     one short notification;
--   * clean up completely on `destroy`: unsubscribe, destroy the UI, close the journal; late callbacks are inert.

local EvidencePresenter = {}

EvidencePresenter.MaxToastLines = 2

export type Deps = {
    controller: any, -- { getViewModel, onChanged, onTransition } (ObjectiveController driving an EvidenceView)
    ui: any, -- { create(callbacks) -> handle, render(handle, state), toast(handle, toast), destroy(handle) }
    text: any, -- Messages catalogue (evidenceCounter, evidenceStatus, evidenceCategory, evidenceCorroboration, evidenceEvent, ...)
    log: (message: string) -> (),
}

export type EntryState = {
    title: string,
    category: string, -- formatted for display
    status: string, -- OBSERVED | CONFIRMED as a word
    progress: string, -- "1 of 2 sightings" for unconfirmed multi-source evidence, otherwise ""
    isConfirmed: boolean,
}

export type RenderState = {
    visible: boolean, -- false until the first valid snapshot
    counter: string,
    journalOpen: boolean,
    journalTitle: string,
    entries: { EntryState },
    emptyText: string, -- shown only when the journal has no entries
}

export type Toast = { kind: string, lines: { string } }

local Presenter = {}
Presenter.__index = Presenter

export type Presenter = typeof(setmetatable({} :: { [string]: any }, Presenter))

local function isDeps(deps: any): boolean
    if type(deps) ~= "table" or type(deps.log) ~= "function" then
        return false
    end
    local controller = deps.controller
    if type(controller) ~= "table" or type(controller.getViewModel) ~= "function" or type(controller.onChanged) ~= "function" or type(controller.onTransition) ~= "function" then
        return false
    end
    local ui = deps.ui
    if type(ui) ~= "table" or type(ui.create) ~= "function" or type(ui.render) ~= "function" or type(ui.toast) ~= "function" or type(ui.destroy) ~= "function" then
        return false
    end
    local text = deps.text
    if type(text) ~= "table" then
        return false
    end
    for _, name in ipairs({ "evidenceCounter", "evidenceStatus", "evidenceCategory", "evidenceCorroboration", "evidenceEvent" }) do
        if type(text[name]) ~= "function" then
            return false
        end
    end
    return true
end

-- Pure: the render state for a view model. Exposed for tests and so the UI port stays dumb.
function EvidencePresenter.buildState(model: any, journalOpen: boolean, text: any): RenderState
    local entries: { EntryState } = {}
    for _, entry in ipairs(model.entries) do
        local progress = ""
        if entry.hasCorroboration and not entry.isConfirmed then
            progress = text.evidenceCorroboration(entry.sources, entry.required)
        end
        table.insert(entries, {
            title = entry.title,
            category = text.evidenceCategory(entry.category),
            status = text.evidenceStatus(entry.state),
            progress = progress,
            isConfirmed = entry.isConfirmed,
        })
    end
    local emptyText = ""
    if #entries == 0 and type(text.EvidenceEmpty) == "string" then
        emptyText = text.EvidenceEmpty
    end
    local title = ""
    if type(text.EvidenceJournalTitle) == "string" then
        title = text.EvidenceJournalTitle
    end
    return {
        visible = model.synced == true,
        counter = text.evidenceCounter(model.discovered, model.total),
        journalOpen = journalOpen and model.synced == true,
        journalTitle = title,
        entries = entries,
        emptyText = emptyText,
    }
end

function EvidencePresenter.new(deps: Deps): Presenter
    if not isDeps(deps) then
        error("EvidencePresenter.new: incomplete dependencies", 2)
    end
    return setmetatable({
        _deps = deps,
        _started = false,
        _generation = 0,
        _handle = nil,
        _journalOpen = false,
        _unsubscribers = {},
    }, Presenter)
end

local function log(self: any, message: string)
    self._deps.log("[Evidence] " .. message)
end

local function render(self: any)
    if not self._started or self._handle == nil then
        return
    end
    local state = EvidencePresenter.buildState(self._deps.controller:getViewModel(), self._journalOpen, self._deps.text)
    local ok, err = pcall(self._deps.ui.render, self._handle, state)
    if not ok then
        log(self, "render failed: " .. tostring(err))
    end
end

local function showToast(self: any, events: any)
    if not self._started or self._handle == nil then
        return
    end
    local lines: { string } = {}
    local kind = ""
    for _, event in ipairs(events) do
        if #lines >= EvidencePresenter.MaxToastLines then
            break
        end
        local line = self._deps.text.evidenceEvent(event.kind, event.title)
        if line ~= "" then
            if #lines == 0 then
                kind = event.kind
            end
            table.insert(lines, line)
        end
    end
    if #lines == 0 then
        return
    end
    local ok, err = pcall(self._deps.ui.toast, self._handle, { kind = kind, lines = lines })
    if not ok then
        log(self, "toast failed: " .. tostring(err))
    end
end

-- Idempotent: a second call (a respawn, a restart, a double bootstrap) creates no second UI and no second subscription.
function Presenter.start(self: Presenter)
    local data: any = self
    if data._started then
        return
    end
    data._started = true
    data._generation = data._generation + 1
    local capturedGeneration: number = data._generation
    data._journalOpen = false

    local ok, handle = pcall(data._deps.ui.create, {
        toggle = function()
            if data._started and data._generation == capturedGeneration then
                data:toggleJournal()
            end
        end,
        close = function()
            if data._started and data._generation == capturedGeneration then
                data:closeJournal()
            end
        end,
    })
    if not ok or handle == nil then
        data._started = false
        data._generation = data._generation + 1
        log(data, "the UI could not be created: " .. tostring(handle))
        return
    end
    data._handle = handle

    local controller = data._deps.controller
    table.insert(data._unsubscribers, controller:onChanged(function()
        if data._generation == capturedGeneration then
            render(data)
        end
    end))
    table.insert(data._unsubscribers, controller:onTransition(function(events: any)
        if data._generation == capturedGeneration then
            showToast(data, events)
        end
    end))
    render(data)
end

-- Idempotent; safe before start. Unsubscribes, destroys the UI and forgets everything; later callbacks are inert.
function Presenter.destroy(self: Presenter)
    local data: any = self
    data._started = false
    data._generation = data._generation + 1
    for _, unsubscribe in ipairs(data._unsubscribers) do
        pcall(unsubscribe)
    end
    data._unsubscribers = {}
    local handle = data._handle
    data._handle = nil
    data._journalOpen = false
    if handle ~= nil then
        local ok, err = pcall(data._deps.ui.destroy, handle)
        if not ok then
            log(data, "destroy failed: " .. tostring(err))
        end
    end
end

function Presenter.isStarted(self: Presenter): boolean
    return (self :: any)._started
end

function Presenter.isJournalOpen(self: Presenter): boolean
    return (self :: any)._journalOpen
end

-- Local UI state only (never sent anywhere). The journal can only open once the server state is known.
function Presenter.openJournal(self: Presenter)
    local data: any = self
    if not data._started or data._journalOpen then
        return
    end
    if not data._deps.controller:getViewModel().synced then
        return
    end
    data._journalOpen = true
    render(data)
end

function Presenter.closeJournal(self: Presenter)
    local data: any = self
    if not data._started or not data._journalOpen then
        return
    end
    data._journalOpen = false
    render(data)
end

function Presenter.toggleJournal(self: Presenter)
    local data: any = self
    if data._journalOpen then
        data:closeJournal()
    else
        data:openJournal()
    end
end

return EvidencePresenter
