--!strict
-- HUB mission-launch tuning (server-only). The target PlaceId is NOT here: it comes from
-- ServerStorage.ServerShared.MissionTeleport.MissionPlaces so HUB and MISSION share one source of truth.

return table.freeze({
    missionType = "DEFAULT", -- chosen by the server; clients cannot select a mission yet
    maxRetriesPerPlayer = 2, -- bounded retries of the SAME destination after TeleportInitFailed
    retryDelaySeconds = 2,
    launchTimeoutSeconds = 60, -- releases the party lock if members never resolve (no leaked locks)
})
