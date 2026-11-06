--!strict
-- HUB party tuning. Server-only. Party size comes from the shared product constant.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)

return table.freeze({
    maxPartySize = Constants.Experience.MaxPartySize,
    inviteTtlSeconds = 60,
    maxPendingInvitesPerTarget = 8,
    maxPendingInvitesPerInviter = 16,
})
