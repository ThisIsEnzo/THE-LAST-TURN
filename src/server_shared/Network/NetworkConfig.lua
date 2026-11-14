--!strict
-- Server-only networking configuration. Lives in ServerStorage; never replicated to clients.
-- Every request in NetworkContract.Requests MUST have a rate limit here (checked at init).

local NetworkConfig = {
    RateLimits = table.freeze({
        -- Handshake is sent once per client; small burst, slow refill.
        ClientReady = table.freeze({ capacity = 3, refillPerSecond = 0.1 }),
        -- TTL-04 Party System.
        PartyInvite = table.freeze({ capacity = 5, refillPerSecond = 0.5 }),
        PartyRespondInvite = table.freeze({ capacity = 5, refillPerSecond = 1 }),
        PartyLeave = table.freeze({ capacity = 3, refillPerSecond = 0.5 }),
        PartyKick = table.freeze({ capacity = 5, refillPerSecond = 0.5 }),
        PartyRequestSnapshot = table.freeze({ capacity = 3, refillPerSecond = 0.5 }),
        -- TTL-05: launching is rare and expensive; allow a small burst, slow refill.
        MissionLaunch = table.freeze({ capacity = 2, refillPerSecond = 0.2 }),
        -- TTL-09B: a pull once per client listener; small burst, slow refill.
        ObjectiveRequestSnapshot = table.freeze({ capacity = 3, refillPerSecond = 0.5 }),
    }),
}

return table.freeze(NetworkConfig)
