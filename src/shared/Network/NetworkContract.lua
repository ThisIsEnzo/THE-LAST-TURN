--!strict
-- Network contract shared by HUB and MISSION, on both server and client.
--
-- This module only lists names. Remote names and the protocol version are NOT secrets and
-- NOT authorization: the server validates and rate-limits every request regardless.
--
-- Conventions:
--   * ReplicatedStorage.Network.Requests       : client -> server RemoteEvents (untrusted).
--   * ReplicatedStorage.Network.Notifications  : server -> client RemoteEvents.
--   * Every remote is purpose-specific. There is no generic "call server function" remote.
--   * Only the server creates remotes (see ServerStorage.ServerShared.Network.NetworkService).

local NetworkContract = {
    ProtocolVersion = 1,

    RootFolderName = "Network",
    RequestsFolderName = "Requests",
    NotificationsFolderName = "Notifications",

    -- Client -> server. Each entry must also have a rate limit in the server-only NetworkConfig.
    Requests = table.freeze({
        ClientReady = "ClientReady", -- TTL-02 diagnostic handshake (removable)
    }),

    -- Server -> client.
    Notifications = table.freeze({
        HandshakeAck = "HandshakeAck", -- TTL-02 diagnostic handshake (removable)
    }),
}

return table.freeze(NetworkContract)
