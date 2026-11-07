--!strict
-- MISSION lifecycle tuning (server-only). Validated at init by MissionLifecycleCore.validateConfig.
-- PlaceIds are NOT here: HubPlaceId / MissionPlaceId live in ServerShared.MissionTeleport.MissionPlaces.

return table.freeze({
    -- Must match the mission type the HUB sends (HUB MissionTeleportConfig.missionType).
    expectedMissionType = "DEFAULT",
    -- Abort if no complete (READY) arrival context exists this long after the server became ready for players.
    contextWaitTimeoutSeconds = 120,
    -- Return-to-HUB teleport policy (bounded; the same destination is reused for retries).
    returnMaxRetriesPerPlayer = 2,
    returnRetryDelaySeconds = 2,
    returnTimeoutSeconds = 30,
})
