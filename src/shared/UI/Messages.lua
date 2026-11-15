--!strict
-- Player-facing text for the HUB party / mission UI (pure, Lune-tested). Technical statuses, codes and reasons coming
-- from the server are translated here; raw codes, ids, tokens and errors are never shown to players.

local Messages = {}

export type Text = { title: string, text: string, tone: string } -- tone: info | progress | warning | error

local function text(title: string, body: string, tone: string): Text
    return { title = title, text = body, tone = tone }
end

local TELEPORT_FAILED_BY_CODE: { [string]: Text } = {
    timeout = text("DEPLOYMENT TIMED OUT", "The transfer took too long. Try again.", "error"),
    teleport_call_failed = text("DEPLOYMENT FAILED", "The mission server could not be started. Try again in a moment.", "error"),
}

local INVALID_PARTY_BY_CODE: { [string]: string } = {
    member_disconnected = "A squad member disconnected. Check your squad and try again.",
}

local PREPARATION_FAILED_BY_CODE: { [string]: Text } = {
    mission_not_configured = text("MISSION UNAVAILABLE", "This mission is not available right now.", "error"),
    invalid_lifecycle = text("SQUAD NOT READY", "A squad member is not ready. Try again in a moment.", "warning"),
    member_in_launch = text("SQUAD BUSY", "A squad member is already deploying.", "warning"),
    party_changed = text("SQUAD CHANGED", "The squad changed during preparation. Try again.", "warning"),
}

-- Maps a MissionLaunchStatus payload (status plus optional code/attempt/maxAttempts) to player text.
function Messages.launch(status: any, code: any, attempt: any, maxAttempts: any): Text
    if status == "accepted" then
        return text("PREPARING DEPLOYMENT", "Preparing the mission server...", "progress")
    elseif status == "launch_initiated" then
        return text("DEPLOYING", "Transferring the squad to THE ASYLUM...", "progress")
    elseif status == "retrying" then
        if type(attempt) == "number" and type(maxAttempts) == "number" and attempt >= 1 and maxAttempts >= attempt then
            return text("RECONNECTING", string.format("Connection problem. Retrying (%d of %d)...", attempt, maxAttempts), "progress")
        end
        return text("RECONNECTING", "Connection problem. Retrying...", "progress")
    elseif status == "partial_failure" then
        return text("SQUAD MEMBER LOST", "A squad member could not be transferred. The rest of the squad is still deploying.", "warning")
    elseif status == "teleport_failed" then
        local known = TELEPORT_FAILED_BY_CODE[tostring(code)]
        if known ~= nil then
            return known
        end
        return text("TRANSFER FAILED", "The transfer to the mission failed. Try again.", "error")
    elseif status == "not_leader" then
        return text("LEADER ONLY", "Only the squad leader can start the mission.", "error")
    elseif status == "already_in_progress" then
        return text("ALREADY DEPLOYING", "A deployment is already in progress.", "warning")
    elseif status == "invalid_party" then
        local body = INVALID_PARTY_BY_CODE[tostring(code)]
        if body == nil then
            body = "Your squad changed. Check your squad and try again."
        end
        return text("SQUAD PROBLEM", body, "error")
    elseif status == "preparation_failed" then
        local known = PREPARATION_FAILED_BY_CODE[tostring(code)]
        if known ~= nil then
            return known
        end
        return text("PREPARATION FAILED", "The mission could not be prepared. Try again.", "error")
    end
    return text("UNEXPECTED RESPONSE", "Something went wrong. Try again.", "error")
end

-- Client-side recovery messages (no server status involved).
Messages.NoResponse = text("NO RESPONSE", "The server did not respond. Try again.", "error")
Messages.LaunchTimedOut = text("DEPLOYMENT TIMED OUT", "The deployment took too long. Try again.", "error")

local INVITE_ENDED_TARGET: { [string]: string } = {
    accepted = "You joined {name}'s squad.",
    declined = "You declined {name}'s invitation.",
    expired = "{name}'s invitation expired.",
    cancelled = "{name}'s invitation was cancelled.",
    superseded = "{name}'s invitation was replaced.",
}

local INVITE_ENDED_INVITER: { [string]: string } = {
    accepted = "{name} joined your squad.",
    declined = "{name} declined your invitation.",
    expired = "Your invitation to {name} expired.",
    cancelled = "Your invitation to {name} was cancelled.",
    superseded = "Your invitation to {name} was replaced.",
}

-- role: "target" (you were invited) or "inviter" (you invited someone). Returns a template containing {name}.
function Messages.inviteEnded(reason: any, role: string): string
    local table_ = INVITE_ENDED_TARGET
    local fallback = "{name}'s invitation ended."
    if role == "inviter" then
        table_ = INVITE_ENDED_INVITER
        fallback = "Your invitation to {name} ended."
    end
    local template = table_[tostring(reason)]
    if template == nil then
        return fallback
    end
    return template
end

local INVITE_BLOCKED: { [string]: string } = {
    not_leader = "Only the squad leader can invite players.",
    party_full = "Your squad is full.",
    already_in_party = "That player is already in your squad.",
    already_invited = "Invitation already sent.",
    self = "You cannot invite yourself.",
    busy = "Please wait a moment.",
}

function Messages.inviteBlocked(reason: any): string
    local message = INVITE_BLOCKED[tostring(reason)]
    if message == nil then
        return "That invitation cannot be sent."
    end
    return message
end

-- Server-authoritative rejection reasons for invitation actions. Never display raw server codes.
local PARTY_ACTION_FAILURE: { [string]: string } = {
    not_leader = "Only the squad leader can do that.",
    party_full = "The squad is full.",
    already_in_party = "That player is already in your squad.",
    already_invited = "An invitation is already pending.",
    unknown_player = "You are no longer in this server session.",
    unknown_target = "That player is no longer in this server.",
    unknown_inviter = "That invitation is no longer available.",
    invite_invalid = "That invitation is no longer valid.",
    no_invite = "That invitation is no longer available.",
    invite_expired = "That invitation has expired.",
    too_many_invites = "Too many invitations are pending. Try again later.",
    cannot_invite_self = "You cannot invite yourself.",
    target_in_party = "Leave your current squad before accepting another invitation.",
    cannot_respond_self = "That invitation is invalid.",
    not_initialized = "The squad service is temporarily unavailable.",
}

function Messages.partyActionFailure(reason: any): string
    local message = PARTY_ACTION_FAILURE[tostring(reason)]
    if message == nil then
        return "The squad action was rejected. Check the squad and try again."
    end
    return message
end

-- Squad change events (see PartyView.applySnapshot). Returns a template containing {name} where relevant.
function Messages.partyEvent(eventType: any, isLocal: boolean?): string
    if eventType == "member_joined" then
        return "{name} joined the squad."
    elseif eventType == "member_left" then
        return "{name} left the squad."
    elseif eventType == "leader_changed" then
        if isLocal then
            return "You are now the squad leader."
        end
        return "{name} is now the squad leader."
    elseif eventType == "joined_party" then
        return "You joined a squad."
    elseif eventType == "left_party" then
        return "You are no longer in that squad."
    end
    return "The squad changed."
end

function Messages.fill(template: string, name: string): string
    local result = string.gsub(template, "{name}", function()
        return name
    end)
    return result
end

-- Objective HUD (TTL-09C). Objective titles, descriptions and slot labels come from the server snapshot; only the fixed
-- chrome (header, status words, tags, transition lines) lives here. Never shows ids, states as codes or reasons.
Messages.ObjectiveHeader = "OBJECTIVES"

local OBJECTIVE_STATUS: { [string]: string } = {
    LOCKED = "LOCKED",
    AVAILABLE = "ACTIVE",
    IN_PROGRESS = "IN PROGRESS",
    COMPLETED = "DONE",
    FAILED = "FAILED",
    CANCELLED = "UNAVAILABLE",
}

function Messages.objectiveStatus(state: any): string
    local word = OBJECTIVE_STATUS[state]
    if word == nil then
        return ""
    end
    return word
end

-- OPTIONAL objectives carry a tag; REQUIRED ones are the default and stay untagged.
function Messages.objectiveTag(importance: any): string
    if importance == "OPTIONAL" then
        return "OPTIONAL"
    end
    return ""
end

-- One short line for a transition event (kinds from ObjectiveView.EventKinds); `title` is server text.
function Messages.objectiveEvent(kind: any, title: any): string
    local name = "an objective"
    if type(title) == "string" and #title > 0 then
        name = title
    end
    if kind == "UNLOCKED" then
        return "New objective: " .. name
    elseif kind == "COMPLETED" then
        return "Completed: " .. name
    elseif kind == "FAILED" then
        return "Failed: " .. name
    elseif kind == "CANCELLED" then
        return "No longer available: " .. name
    end
    return ""
end

function Messages.objectiveMore(count: any): string
    if type(count) == "number" and count >= 1 then
        return string.format("+%d more", math.floor(count))
    end
    return ""
end

return Messages
