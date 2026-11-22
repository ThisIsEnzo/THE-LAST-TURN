--!strict
-- Pure equipment runtime domain logic. All time is caller-supplied; no Roblox or Evidence dependencies.
local Core = {}
Core.Reasons = table.freeze({
    INVALID_DISTANCE="invalid_distance", UNKNOWN_ITEM="unknown_item", INVALID_TIMESTAMP="invalid_timestamp",
    INVALID_CAMERA_STATE="invalid_camera_state", INVALID_CAPTURE_RESULT="invalid_capture_result",
    NO_CHARGES="no_charges", COOLDOWN_ACTIVE="cooldown_active",
})
local Reasons = Core.Reasons
Core.Cooldowns = table.freeze({
    EMF_READER=6, THERMOMETER=6, FIELD_CAMERA=8, SPIRIT_BOX=10, UTILITY_FLASHLIGHT=0.5,
})
local Cooldowns = Core.Cooldowns
Core.CameraMaxCharges = 3
Core.CaptureResults = table.freeze({PRESENT="PRESENT", ABSENT="ABSENT"})
local Results = Core.CaptureResults
local Bands = table.freeze({
    table.freeze({max=6,band=5}), table.freeze({max=10,band=4}),
    table.freeze({max=16,band=3}), table.freeze({max=24,band=2}),
})
export type CameraState = { charges: number, lastUsedAt: number? }

local function finite(value: any): boolean
    return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
end
local function timestamp(value: any): boolean
    return finite(value) and value>=0
end
local function plainTable(value: any): boolean
    return type(value)=="table" and getmetatable(value)==nil
end
local function configuredCooldown(itemId: any): number?
    if type(itemId)~="string" then return nil end
    return (Cooldowns :: {[string]: number?})[itemId]
end
local function validCameraState(state: any): boolean
    if not plainTable(state) then return false end
    for key in pairs(state) do
        if key~="charges" and key~="lastUsedAt" then return false end
    end
    local charges=state.charges
    if not finite(charges) or charges%1~=0 or charges<0 or charges>Core.CameraMaxCharges then return false end
    if state.lastUsedAt~=nil and not timestamp(state.lastUsedAt) then return false end
    return true
end

function Core.bandForDistance(distance: any): (number?, string?)
    if distance==nil then return 1,nil end
    if not finite(distance) or distance<0 then return nil,Reasons.INVALID_DISTANCE end
    for _,entry in ipairs(Bands) do
        if distance<=entry.max then return entry.band,nil end
    end
    return 1,nil
end
function Core.cooldownFor(itemId: any): (number?, string?)
    local value=configuredCooldown(itemId)
    if value==nil then return nil,Reasons.UNKNOWN_ITEM end
    return value,nil
end
function Core.cooldownEndsAt(itemId: any,lastUsedAt: any): (number?,string?)
    local value=configuredCooldown(itemId)
    if value==nil then return nil,Reasons.UNKNOWN_ITEM end
    if lastUsedAt==nil then return 0,nil end
    if not timestamp(lastUsedAt) then return nil,Reasons.INVALID_TIMESTAMP end
    return lastUsedAt+value,nil
end
function Core.isReady(itemId: any,lastUsedAt: any,now: any): (boolean?,string?)
    local value=configuredCooldown(itemId)
    if value==nil then return nil,Reasons.UNKNOWN_ITEM end
    if not timestamp(now) then return nil,Reasons.INVALID_TIMESTAMP end
    if lastUsedAt==nil then return true,nil end
    if not timestamp(lastUsedAt) then return nil,Reasons.INVALID_TIMESTAMP end
    return now>=lastUsedAt+value,nil
end
function Core.newCameraState(): CameraState
    return table.freeze({charges=Core.CameraMaxCharges,lastUsedAt=nil})
end
-- Both outcomes start the 8s cooldown; only PRESENT consumes a charge. Enforced atomically here.
function Core.applyCapture(state: any,result: any,now: any): (CameraState?,string?)
    if not validCameraState(state) then return nil,Reasons.INVALID_CAMERA_STATE end
    if result~=Results.PRESENT and result~=Results.ABSENT then return nil,Reasons.INVALID_CAPTURE_RESULT end
    if not timestamp(now) then return nil,Reasons.INVALID_TIMESTAMP end
    local ready,code=Core.isReady("FIELD_CAMERA",state.lastUsedAt,now)
    if ready==nil then return nil,code end
    if not ready then return nil,Reasons.COOLDOWN_ACTIVE end
    local charges: number=state.charges
    if result==Results.PRESENT then
        if charges<=0 then return nil,Reasons.NO_CHARGES end
        charges-=1
    end
    return table.freeze({charges=charges,lastUsedAt=now}),nil
end
return Core
