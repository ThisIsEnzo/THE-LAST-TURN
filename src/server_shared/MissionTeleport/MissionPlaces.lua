--!strict
-- Server-only mission destination configuration (lives in ServerStorage; never replicated).
--
-- OWNER ACTION REQUIRED: set both PlaceIds to the real HUB and MISSION places in the same Experience.
-- 0 means "not configured": HUB launches are disabled and MISSION rejects arrivals/source validation.
-- Do not invent an id; Roblox cannot teleport to a place that does not exist.

return table.freeze({
    HubPlaceId = 0, -- owner must set to the real HUB PlaceId; MISSION validates GetJoinData().SourcePlaceId
    MissionPlaceId = 0, -- owner must set to the real MISSION PlaceId
})
