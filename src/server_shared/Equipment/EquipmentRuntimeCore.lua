--!strict
-- Pure equipment runtime rules. No Roblox APIs, clocks, remotes, or Evidence dependencies.
local EquipmentRuntimeCore = {}

EquipmentRuntimeCore.Reason = table.freeze({
    INVALID_DISTANCE = "invalid_distance",
    UNKNOWN_ITEM = "unknown_item",
    INVALID_TIMESTAMP = "invalid_timestamp",
    INVALID_CAMERA_STATE = "invalid_camera_state",
    INVALID_CAPTURE_RESULT = "invalid_capture_result",
    NO_CHARGES = "no_charges",
    COOLDOWN_ACTIVE = "cooldown_active",
})

EquipmentRuntimeCore.Cooldowns = table.freeze({
    EMF_READER = 6,
    THERMOMETER = 6,
    FIELD_CAMERA = 8,
    SPIRIT_BOX = 10,
    UTILITY_FLASHLIGHT = 0.5,
})
EquipmentRuntimeCore.CameraMaxCharges = 3
EquipmentRuntimeCore.CaptureResult = table.freeze({ PRESENT = "PRESENT", ABSENT = "ABSENT" })

local Reason = EquipmentRuntimeCore.Reason
local Cooldowns = EquipmentRuntimeCore.Cooldowns
local CameraMaxCharges = EquipmentRuntimeCore.CameraMaxCharges
local CaptureResult = EquipmentRuntimeCore.CaptureResult

local function isFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isTimestamp(value: any): boolean
    return isFiniteNumber(value) and value >= 0
end

function EquipmentRuntimeCore.bandForDistance(distance: any): (number?, string?)
    if distance == nil then return 1, nil end
    if not isFiniteNumber(distance) or distance < 0 then
        return nil, Reason.INVALID_DISTANCE
    end
    if distance <= 6 then return 5, nil end
    if distance <= 10 then return 4, nil end
    if distance <= 16 then return 3, nil end
    if distance <= 24 then return 2, nil end
    return 1, nil
end

function EquipmentRuntimeCore.cooldownFor(itemId: any): (number?, string?)
    if type(itemId) ~= "string" then return nil, Reason.UNKNOWN_ITEM end
    local cooldown = Cooldowns[itemId]
    if cooldown == nil then return nil, Reason.UNKNOWN_ITEM end
    return cooldown, nil
end

function EquipmentRuntimeCore.cooldownEndsAt(itemId: any, lastUsedAt: any): (number?, string?)
    local cooldown, reason = EquipmentRuntimeCore.cooldownFor(itemId)
    if cooldown == nil then return nil, reason end
    if lastUsedAt == nil then return 0, nil end
    if not isTimestamp(lastUsedAt) then return nil, Reason.INVALID_TIMESTAMP end
    return lastUsedAt + cooldown, nil
end

function EquipmentRuntimeCore.isReady(itemId: any, lastUsedAt: any, now: any): (boolean, string?)
    if not isTimestamp(now) then return false, Reason.INVALID_TIMESTAMP end
    local readyAt, reason = EquipmentRuntimeCore.cooldownEndsAt(itemId, lastUsedAt)
    if readyAt == nil then return false, reason end
    return now >= readyAt, nil
end

function EquipmentRuntimeCore.newCameraState()
    return table.freeze({ charges = CameraMaxCharges, lastUsedAt = nil })
end

local function isValidCameraState(state: any): boolean
    if type(state) ~= "table" or getmetatable(state) ~= nil then return false end
    local fieldCount = 0
    for key in pairs(state) do
        if key ~= "charges" and key ~= "lastUsedAt" then return false end
        fieldCount += 1
    end
    if fieldCount ~= 2 then return false end
    if not isFiniteNumber(state.charges) or state.charges % 1 ~= 0
        or state.charges < 0 or state.charges > CameraMaxCharges then
        return false
    end
    if state.lastUsedAt ~= nil and not isTimestamp(state.lastUsedAt) then return false end
    return true
end

-- Both PRESENT and ABSENT consume the cooldown. Only PRESENT consumes a charge.
-- Cooldown enforcement lives in this transition so callers cannot accidentally bypass it.
function EquipmentRuntimeCore.applyCapture(state: any, result: any, now: any): (any?, string?)
    if not isValidCameraState(state) then return nil, Reason.INVALID_CAMERA_STATE end
    if result ~= CaptureResult.PRESENT and result ~= CaptureResult.ABSENT then
        return nil, Reason.INVALID_CAPTURE_RESULT
    end
    if not isTimestamp(now) then return nil, Reason.INVALID_TIMESTAMP end

    local ready, readinessReason = EquipmentRuntimeCore.isReady("FIELD_CAMERA", state.lastUsedAt, now)
    if not ready then
        if readinessReason ~= nil then return nil, readinessReason end
        return nil, Reason.COOLDOWN_ACTIVE
    end

    if result == CaptureResult.PRESENT and state.charges <= 0 then
        return nil, Reason.NO_CHARGES
    end

    local charges = state.charges
    if result == CaptureResult.PRESENT then charges -= 1 end
    return table.freeze({ charges = charges, lastUsedAt = now }), nil
end

return EquipmentRuntimeCore
