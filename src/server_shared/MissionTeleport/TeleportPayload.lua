--!strict
-- Versioned mission teleport payload: built by the HUB server, validated (fail closed) by the MISSION server.
-- Pure Luau, dependency free. The payload carries only what MISSION needs: no reserved-server id, no secrets,
-- no player data beyond UserIds. It is NOT proof of authorization; MISSION also checks its own environment.

export type Payload = {
    schemaVersion: number,
    missionId: string,
    partyId: string,
    partyLeaderUserId: number,
    memberUserIds: { number },
    missionType: string,
    createdAt: number, -- epoch seconds, informational
}

local TeleportPayload = {}

TeleportPayload.SchemaVersion = 1
TeleportPayload.MaxMembers = 8

local MAX_USER_ID = 9007199254740991 -- 2^53 - 1
local MAX_CREATED_AT = 4102444800 -- 2100-01-01

local EXPECTED_FIELDS: { [string]: boolean } = {
    schemaVersion = true,
    missionId = true,
    partyId = true,
    partyLeaderUserId = true,
    memberUserIds = true,
    missionType = true,
    createdAt = true,
}

local function isInteger(value: any, min: number, max: number): boolean
    return type(value) == "number" and value == value and value % 1 == 0 and value >= min and value <= max
end

local function isToken(value: any, maxLength: number, pattern: string): boolean
    return type(value) == "string" and #value >= 1 and #value <= maxLength and string.match(value, pattern) ~= nil
end

-- Returns (true, sanitizedCopy) or (false, reason). Reasons are for server logs only.
function TeleportPayload.validate(data: any): (boolean, any)
    if type(data) ~= "table" or getmetatable(data) ~= nil then
        return false, "payload is not a plain table"
    end
    for key in pairs(data) do
        if type(key) ~= "string" or not EXPECTED_FIELDS[key] then
            return false, "unexpected field"
        end
    end
    if data.schemaVersion ~= TeleportPayload.SchemaVersion then
        return false, "unsupported schema version"
    end
    if not isToken(data.missionId, 64, "^[%w%-]+$") then
        return false, "invalid missionId"
    end
    if not isToken(data.partyId, 32, "^[%w_%-]+$") then
        return false, "invalid partyId"
    end
    if not isToken(data.missionType, 32, "^[%w_%-]+$") then
        return false, "invalid missionType"
    end
    if not isInteger(data.partyLeaderUserId, 1, MAX_USER_ID) then
        return false, "invalid partyLeaderUserId"
    end
    if not isInteger(data.createdAt, 0, MAX_CREATED_AT) then
        return false, "invalid createdAt"
    end

    local members = data.memberUserIds
    if type(members) ~= "table" or getmetatable(members) ~= nil then
        return false, "memberUserIds is not a table"
    end
    local count = 0
    for key in pairs(members) do
        if type(key) ~= "number" then
            return false, "memberUserIds is not an array"
        end
        count += 1
    end
    if count < 1 or count > TeleportPayload.MaxMembers or #members ~= count then
        return false, "invalid memberUserIds size"
    end
    local seen: { [number]: boolean } = {}
    local copy: { number } = {}
    for index = 1, count do
        local userId = members[index]
        if not isInteger(userId, 1, MAX_USER_ID) then
            return false, "invalid member UserId"
        end
        if seen[userId] then
            return false, "duplicate member UserId"
        end
        seen[userId] = true
        copy[index] = userId
    end
    if not seen[data.partyLeaderUserId] then
        return false, "leader is not a member"
    end

    return true,
        {
            schemaVersion = data.schemaVersion,
            missionId = data.missionId,
            partyId = data.partyId,
            partyLeaderUserId = data.partyLeaderUserId,
            memberUserIds = copy,
            missionType = data.missionType,
            createdAt = data.createdAt,
        }
end

-- HUB side: builds a payload from server-derived values; errors if they would not validate (server bug).
function TeleportPayload.build(fields: {
    missionId: string,
    partyId: string,
    leaderUserId: number,
    memberUserIds: { number },
    missionType: string,
    createdAt: number,
}): Payload
    local ok, result = TeleportPayload.validate({
        schemaVersion = TeleportPayload.SchemaVersion,
        missionId = fields.missionId,
        partyId = fields.partyId,
        partyLeaderUserId = fields.leaderUserId,
        memberUserIds = fields.memberUserIds,
        missionType = fields.missionType,
        createdAt = fields.createdAt,
    })
    if not ok then
        error("TeleportPayload.build: " .. tostring(result), 2)
    end
    return result
end

return TeleportPayload
