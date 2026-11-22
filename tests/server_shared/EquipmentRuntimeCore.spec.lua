--!strict
local Harness = require("../Harness")
local Core = require("../../src/server_shared/Equipment/EquipmentRuntimeCore")
local test, eq, yes, no = Harness.test, Harness.expectEqual, Harness.expectTrue, Harness.expectFalse

local Reason = Core.Reason
local Result = Core.CaptureResult

test("scanner bands use inclusive upper boundaries and no-target band one", function()
    eq(Core.bandForDistance(nil), 1)
    eq(Core.bandForDistance(0), 5)
    eq(Core.bandForDistance(6), 5)
    eq(Core.bandForDistance(6.001), 4)
    eq(Core.bandForDistance(10), 4)
    eq(Core.bandForDistance(10.001), 3)
    eq(Core.bandForDistance(16), 3)
    eq(Core.bandForDistance(16.001), 2)
    eq(Core.bandForDistance(24), 2)
    eq(Core.bandForDistance(24.001), 1)
end)

test("scanner bands reject negative and non-finite distances", function()
    local band, reason = Core.bandForDistance(-0.1)
    eq(band, nil); eq(reason, Reason.INVALID_DISTANCE)
    band, reason = Core.bandForDistance(math.huge)
    eq(band, nil); eq(reason, Reason.INVALID_DISTANCE)
    band, reason = Core.bandForDistance(0 / 0)
    eq(band, nil); eq(reason, Reason.INVALID_DISTANCE)
    band, reason = Core.bandForDistance("6")
    eq(band, nil); eq(reason, Reason.INVALID_DISTANCE)
end)

test("cooldowns are defined only for known equipment", function()
    eq(Core.cooldownFor("EMF_READER"), 6)
    eq(Core.cooldownFor("THERMOMETER"), 6)
    eq(Core.cooldownFor("FIELD_CAMERA"), 8)
    eq(Core.cooldownFor("SPIRIT_BOX"), 10)
    eq(Core.cooldownFor("UTILITY_FLASHLIGHT"), 0.5)
    local cooldown, reason = Core.cooldownFor("UNKNOWN")
    eq(cooldown, nil); eq(reason, Reason.UNKNOWN_ITEM)
end)

test("cooldown readiness accepts exact boundary and fractional timestamps", function()
    yes(Core.isReady("EMF_READER", nil, 0))
    no(Core.isReady("EMF_READER", 10.25, 16.249999))
    yes(Core.isReady("EMF_READER", 10.25, 16.25))
    no(Core.isReady("UTILITY_FLASHLIGHT", 10.125, 10.624999))
    yes(Core.isReady("UTILITY_FLASHLIGHT", 10.125, 10.625))
    local ready, reason = Core.isReady("EMF_READER", -1, 20)
    no(ready); eq(reason, Reason.INVALID_TIMESTAMP)
    ready, reason = Core.isReady("EMF_READER", nil, math.huge)
    no(ready); eq(reason, Reason.INVALID_TIMESTAMP)
end)

test("camera starts with three charges and immutable state", function()
    local state = Core.newCameraState()
    eq(state.charges, 3)
    eq(state.lastUsedAt, nil)
    yes(table.isfrozen(state))
end)

test("PRESENT consumes one charge and sets cooldown timestamp", function()
    local initial = Core.newCameraState()
    local nextState, reason = Core.applyCapture(initial, Result.PRESENT, 12.25)
    yes(nextState ~= nil); eq(reason, nil)
    eq(nextState.charges, 2)
    eq(nextState.lastUsedAt, 12.25)
    eq(initial.charges, 3)
    yes(table.isfrozen(nextState))
end)

test("ABSENT consumes no charge but sets cooldown timestamp", function()
    local nextState, reason = Core.applyCapture(Core.newCameraState(), Result.ABSENT, 4.5)
    yes(nextState ~= nil); eq(reason, nil)
    eq(nextState.charges, 3)
    eq(nextState.lastUsedAt, 4.5)
end)

test("camera enforces cooldown inside the capture transition", function()
    local state = Core.newCameraState()
    local first = Core.applyCapture(state, Result.PRESENT, 10.25)
    yes(first ~= nil)
    local blocked, reason = Core.applyCapture(first, Result.PRESENT, 18.249999)
    eq(blocked, nil); eq(reason, Reason.COOLDOWN_ACTIVE)
    blocked, reason = Core.applyCapture(first, Result.ABSENT, 18.249999)
    eq(blocked, nil); eq(reason, Reason.COOLDOWN_ACTIVE)
    local ready, readyReason = Core.applyCapture(first, Result.ABSENT, 18.25)
    yes(ready ~= nil); eq(readyReason, nil)
    eq(ready.charges, 2)
end)

test("camera rejects capture after charges are exhausted", function()
    local state = Core.newCameraState()
    state = Core.applyCapture(state, Result.PRESENT, 0)
    state = Core.applyCapture(state, Result.PRESENT, 8)
    state = Core.applyCapture(state, Result.PRESENT, 16)
    eq(state.charges, 0)
    local nextState, reason = Core.applyCapture(state, Result.PRESENT, 24)
    eq(nextState, nil); eq(reason, Reason.NO_CHARGES)
end)

test("camera rejects invalid state including nil explicitly", function()
    local nextState, reason = Core.applyCapture(nil, Result.PRESENT, 0)
    eq(nextState, nil); eq(reason, Reason.INVALID_CAMERA_STATE)

    local invalidStates = {
        {},
        { charges = 3 },
        { charges = 3, lastUsedAt = nil, extra = true },
        { charges = -1, lastUsedAt = nil },
        { charges = 1.5, lastUsedAt = nil },
        { charges = 4, lastUsedAt = nil },
        { charges = 2, lastUsedAt = -1 },
        { charges = 2, lastUsedAt = math.huge },
    }
    for _, invalidState in ipairs(invalidStates) do
        nextState, reason = Core.applyCapture(invalidState, Result.PRESENT, 0)
        eq(nextState, nil); eq(reason, Reason.INVALID_CAMERA_STATE)
    end
end)

test("camera rejects invalid result and timestamp", function()
    local nextState, reason = Core.applyCapture(Core.newCameraState(), "UNKNOWN", 0)
    eq(nextState, nil); eq(reason, Reason.INVALID_CAPTURE_RESULT)
    nextState, reason = Core.applyCapture(Core.newCameraState(), Result.PRESENT, -1)
    eq(nextState, nil); eq(reason, Reason.INVALID_TIMESTAMP)
    nextState, reason = Core.applyCapture(Core.newCameraState(), Result.PRESENT, math.huge)
    eq(nextState, nil); eq(reason, Reason.INVALID_TIMESTAMP)
end)
