--!strict
-- Client-side view of the mission launch (pure, Lune-tested). The server (MissionTeleportService / LaunchCoordinator) is
-- the only authority: this module only reflects the MissionLaunchStatus notifications it receives and decides when the
-- UI may offer the Start button. It never starts a launch by itself and the request it describes carries NO data.
--
-- Actual server statuses (LaunchCoordinator.Status): accepted, already_in_progress, not_leader, invalid_party,
-- preparation_failed, teleport_failed, retrying, launch_initiated, partial_failure. A launch timeout arrives as
-- teleport_failed with code "timeout"; there is no separate cancelled/completed status (on success the players leave
-- the HUB server), so the client has its own recovery timeouts: the UI can never stay stuck in a loading state.
--
-- Time is injected (`now`, seconds). Deadlines are evaluated lazily; `nextDeadline` tells the UI when to look again.
-- The message catalogue (UI/Messages) is injected as well, like every collaborator of the project's pure modules.

local LaunchView = {}

LaunchView.RequestTimeoutSeconds = 8 -- no server reaction to a Start request
LaunchView.LaunchTimeoutSeconds = 75 -- mirrors the server's 60 s launch timeout plus margin; reset by each progress status
LaunchView.MessageSeconds = 10 -- how long a failure/rejection message stays before the UI returns to idle
LaunchView.DebounceSeconds = 1 -- minimum time between two Start requests
LaunchView.PartyChangeGraceSeconds = 2.5 -- statuses arriving right after a party change belong to the old party

LaunchView.Phase = table.freeze({
    Idle = "idle",
    Requesting = "requesting", -- Start sent, waiting for the server's first reaction
    Launching = "launching", -- accepted / launch_initiated / retrying / partial_failure
    Failed = "failed", -- teleport failed or a client recovery timeout fired; retry allowed for the leader
    Rejected = "rejected", -- the request was refused (not leader, party problem, preparation failed); retry allowed
})
local Phase = LaunchView.Phase

local PROGRESS: { [string]: boolean } = {
    accepted = true,
    launch_initiated = true,
    retrying = true,
    partial_failure = true,
}
local REJECTIONS: { [string]: boolean } = {
    not_leader = true,
    invalid_party = true,
    preparation_failed = true,
}

export type Text = { title: string, text: string, tone: string }

-- The catalogue passed to LaunchView.new: `launch(status, code, attempt, maxAttempts) -> Text`, plus the client-side
-- recovery texts `NoResponse` and `LaunchTimedOut`.
export type MessageCatalogue = {
    launch: (status: any, code: any, attempt: any, maxAttempts: any) -> Text,
    NoResponse: Text,
    LaunchTimedOut: Text,
}

export type View = {
    phase: string,
    title: string,
    text: string,
    tone: string,
    busy: boolean, -- a launch is being requested or is under way: the Start button must be disabled
    subjectUserId: number?, -- e.g. the member who failed to travel (partial_failure)
    mission: string?, -- "unavailable" after mission_not_configured, otherwise nil
}

type LaunchViewData = {
    _phase: string,
    _since: number,
    _status: string?,
    _code: any,
    _attempt: any,
    _maxAttempts: any,
    _subject: number?,
    _partyId: string?,
    _lastRequestAt: number?,
    _ignoreUntil: number,
    _custom: Text?,
    _messages: MessageCatalogue,
    _missionUnavailable: boolean,
}

local LaunchViewClass = {}
LaunchViewClass.__index = LaunchViewClass

export type LaunchView = typeof(setmetatable({} :: LaunchViewData, LaunchViewClass))

local function isFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function LaunchView.new(messages: MessageCatalogue): LaunchView
    if type(messages) ~= "table" or type(messages.launch) ~= "function" or messages.NoResponse == nil or messages.LaunchTimedOut == nil then
        error("LaunchView.new: a message catalogue (UI/Messages) is required", 2)
    end
    return setmetatable({
        _messages = messages,
        _phase = Phase.Idle,
        _since = 0,
        _status = nil,
        _code = nil,
        _attempt = nil,
        _maxAttempts = nil,
        _subject = nil,
        _partyId = nil,
        _lastRequestAt = nil,
        _ignoreUntil = -math.huge,
        _custom = nil,
        _missionUnavailable = false,
    }, LaunchViewClass)
end

-- The arguments of the MissionLaunch request. It is payload-less: PlaceId, mission type, member ids and server ids are
-- never sent by the client; the server derives everything.
function LaunchView.requestArguments(): { any }
    return table.freeze({})
end

local function reset(data: any)
    data._phase = Phase.Idle
    data._status = nil
    data._code = nil
    data._attempt = nil
    data._maxAttempts = nil
    data._subject = nil
    data._custom = nil
end

-- Applies the client-side recovery timeouts. Called by every getter.
local function normalize(data: any, now: number)
    if not isFiniteNumber(now) then
        return
    end
    local phase = data._phase
    if phase == Phase.Requesting and now - data._since >= LaunchView.RequestTimeoutSeconds then
        data._phase = Phase.Failed
        data._since = now
        data._custom = data._messages.NoResponse
        data._status = nil
    elseif phase == Phase.Launching and now - data._since >= LaunchView.LaunchTimeoutSeconds then
        data._phase = Phase.Failed
        data._since = now
        data._custom = data._messages.LaunchTimedOut
        data._status = nil
    elseif (phase == Phase.Failed or phase == Phase.Rejected) and now - data._since >= LaunchView.MessageSeconds then
        reset(data)
    end
end

-- Returns (true, nil) or (false, reason) with reason not_leader, busy or debounce. UI hint only: the server decides.
function LaunchViewClass.canRequest(self: LaunchView, isLeader: boolean, now: number): (boolean, string?)
    local data = self :: any
    normalize(data, now)
    if not isLeader then
        return false, "not_leader"
    end
    if data._phase == Phase.Requesting or data._phase == Phase.Launching then
        return false, "busy"
    end
    if data._lastRequestAt ~= nil and now - data._lastRequestAt < LaunchView.DebounceSeconds then
        return false, "debounce"
    end
    return true, nil
end

-- Call right before firing the (payload-less) MissionLaunch request. Returns (true, nil) or (false, reason): a duplicate
-- click while a request or launch is in flight is refused here and nothing must be sent.
function LaunchViewClass.tryBeginRequest(self: LaunchView, isLeader: boolean, partyId: string?, now: number): (boolean, string?)
    local data = self :: any
    local ok, reason = self:canRequest(isLeader, now)
    if not ok then
        return false, reason
    end
    reset(data)
    data._phase = Phase.Requesting
    data._since = now
    data._partyId = partyId
    data._lastRequestAt = now
    return true, nil
end

-- Applies a MissionLaunchStatus notification. Returns true if it changed the state.
function LaunchViewClass.applyStatus(self: LaunchView, payload: any, now: number): boolean
    local data = self :: any
    if type(payload) ~= "table" or type(payload.status) ~= "string" then
        return false
    end
    normalize(data, now)
    if now < data._ignoreUntil then
        return false -- belongs to the party the player just left
    end
    local status: string = payload.status
    if status == "invalid_party" or status == "preparation_failed" then
        if payload.code == "mission_not_configured" then
            data._missionUnavailable = true
        end
    end

    if PROGRESS[status] then
        data._phase = Phase.Launching
        data._since = now -- every progress status proves the launch is alive
        data._custom = nil
        if status == "retrying" then
            data._attempt = payload.attempt
            data._maxAttempts = payload.maxAttempts
        end
        if status == "partial_failure" and isFiniteNumber(payload.failedUserId) then
            data._subject = payload.failedUserId
        end
    elseif status == "teleport_failed" then
        data._phase = Phase.Failed
        data._since = now
        data._custom = nil
    elseif status == "already_in_progress" then
        if data._phase ~= Phase.Launching then
            data._phase = Phase.Launching
            data._since = now
            data._custom = nil
        else
            return false -- a duplicate request was refused while the launch is already running
        end
    elseif REJECTIONS[status] then
        if data._phase == Phase.Launching then
            return false -- a refused late request must not hide a running launch
        end
        data._phase = Phase.Rejected
        data._since = now
        data._custom = nil
    else
        -- Unknown status: show a generic error unless a launch is running.
        if data._phase == Phase.Launching then
            return false
        end
        data._phase = Phase.Rejected
        data._since = now
        data._custom = nil
    end
    data._status = status
    data._code = payload.code
    return true
end

-- Must be called with the current party id whenever the mirrored party changes. A different party resets the launch UI
-- to idle and ignores statuses for a short grace period (late notifications of the old party).
function LaunchViewClass.observeParty(self: LaunchView, partyId: string?, now: number)
    local data = self :: any
    if data._partyId == partyId then
        return
    end
    local hadPartyBefore = data._partyId ~= nil
    data._partyId = partyId
    if hadPartyBefore or data._phase ~= Phase.Idle then
        reset(data)
        data._ignoreUntil = now + LaunchView.PartyChangeGraceSeconds
    end
end

function LaunchViewClass.getView(self: LaunchView, now: number): View
    local data = self :: any
    normalize(data, now)
    local mission: string? = nil
    if data._missionUnavailable then
        mission = "unavailable"
    end
    local phase: string = data._phase
    if phase == Phase.Idle then
        return { phase = phase, title = "READY", text = "Squad ready for deployment.", tone = "info", busy = false, subjectUserId = nil, mission = mission }
    end
    local message: Text
    if phase == Phase.Requesting then
        message = { title = "REQUESTING DEPLOYMENT", text = "Contacting the mission server...", tone = "progress" }
    elseif data._custom ~= nil then
        message = data._custom
    else
        message = data._messages.launch(data._status, data._code, data._attempt, data._maxAttempts)
    end
    return {
        phase = phase,
        title = message.title,
        text = message.text,
        tone = message.tone,
        busy = phase == Phase.Requesting or phase == Phase.Launching,
        subjectUserId = data._subject,
        mission = mission,
    }
end

-- Seconds until the view changes without any notification (a timeout), or nil when idle. The UI schedules one delayed
-- refresh from this instead of polling.
function LaunchViewClass.nextDeadline(self: LaunchView, now: number): number?
    local data = self :: any
    normalize(data, now)
    local phase = data._phase
    local limit: number? = nil
    if phase == Phase.Requesting then
        limit = LaunchView.RequestTimeoutSeconds
    elseif phase == Phase.Launching then
        limit = LaunchView.LaunchTimeoutSeconds
    elseif phase == Phase.Failed or phase == Phase.Rejected then
        limit = LaunchView.MessageSeconds
    end
    if limit == nil then
        return nil
    end
    local left = limit - (now - data._since)
    if left < 0.05 then
        left = 0.05
    end
    return left
end

return LaunchView
