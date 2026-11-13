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
        -- TTL-04 Party System (HUB handlers only; the contract is shared, MISSION registers none).
        PartyInvite = "PartyInvite", -- payload includes targetUserId + client requestId for correlated result
        PartyRespondInvite = "PartyRespondInvite", -- payload includes inviterUserId, accept + client requestId
        PartyLeave = "PartyLeave",
        PartyKick = "PartyKick",
        PartyRequestSnapshot = "PartyRequestSnapshot", -- client pulls its snapshot once its listener is connected
        -- TTL-05 Mission Teleport (HUB handler only). No payload: the server decides party, place and mission.
        MissionLaunch = "MissionLaunch",
    }),

    -- Server -> client.
    Notifications = table.freeze({
        HandshakeAck = "HandshakeAck", -- TTL-02 diagnostic handshake (removable)
        PartySnapshot = "PartySnapshot", -- party state, sent only to members of that party
        PartyInviteReceived = "PartyInviteReceived", -- sent only to the invited player
        PartyInviteEnded = "PartyInviteEnded", -- sent only to the invite's inviter and target
        PartyActionResult = "PartyActionResult", -- correlated server acknowledgement for invite/response requests
        MissionLaunchStatus = "MissionLaunchStatus", -- launch progress/failure for the affected party members only
    }),
}

return table.freeze(NetworkContract)
