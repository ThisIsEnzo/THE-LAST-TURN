--!strict
-- Server-only networking configuration. Lives in ServerStorage; never replicated to clients.
-- Every request in NetworkContract.Requests MUST have a rate limit here (checked at init).

local NetworkConfig = {
    RateLimits = table.freeze({
        -- Handshake is sent once per client; small burst, slow refill.
        ClientReady = table.freeze({ capacity = 3, refillPerSecond = 0.1 }),
    }),
}

return table.freeze(NetworkConfig)
