--!strict
-- Server-only mission destination configuration (lives in ServerStorage; never replicated).
--
-- OWNER ACTION REQUIRED: set MissionPlaceId to the real MISSION Place's PlaceId (same Experience as the HUB).
-- 0 means "not configured": the HUB refuses mission launches and the MISSION server rejects arrivals.
-- Do not invent an id; Roblox cannot teleport to a place that does not exist.

return table.freeze({
    MissionPlaceId = 0,
})
