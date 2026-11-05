--!strict
-- Shared, non-secret constants only. Never place server-only decisions or credentials here.

local Constants = {
    Experience = {
        MinPartySize = 1,
        MaxPartySize = 8,
        BalancePartySize = 4,
    },
    Mission = {
        TargetDurationMinSeconds = 15 * 60,
        TargetDurationMaxSeconds = 20 * 60,
    },
    Interaction = {
        DefaultActivationDistance = 10,
        DefaultHoldDuration = 0,
    },
}

return table.freeze(Constants)
