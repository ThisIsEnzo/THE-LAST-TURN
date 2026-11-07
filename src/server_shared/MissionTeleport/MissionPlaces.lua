--!strict
-- Server-only mission destination configuration (lives in ServerStorage; never replicated).
--
-- These IDs belong to the same THE LAST TURN Experience (UniverseId 10775098544).
-- 0 means "not configured": HUB launches are disabled and MISSION rejects arrivals/source validation.

return table.freeze({
    HubPlaceId = 121295396016500, -- THE LAST TURN (HUB); MISSION validates GetJoinData().SourcePlaceId
    MissionPlaceId = 117948903725370, -- de1orean457's Place: 11072026_2 (MISSION)
})
