--!strict
-- TTL-02 diagnostic handshake (server half). Isolated and removable without affecting gameplay.
-- The client signals "initial client setup complete"; the server validates it, rate limits it
-- (via NetworkService) and replies with an informational notification only. Receiving the
-- signal grants no permission, state change or authority.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkContract = require(ReplicatedStorage.Shared.Network.NetworkContract)
local NetworkService = require(script.Parent.NetworkService)
local Validator = require(script.Parent.Validator)

local DiagnosticHandshake = {}

function DiagnosticHandshake.register(placeName: string)
    NetworkService.registerRequest(NetworkContract.Requests.ClientReady, {
        args = {
            Validator.object({
                protocolVersion = Validator.integer({ min = 1, max = 1000 }),
                buildLabel = Validator.optional(Validator.string({ maxLength = 32 })),
            }),
        },
        handler = function(player: Player, payload: any)
            NetworkService.fireNotification(NetworkContract.Notifications.HandshakeAck, player, {
                place = placeName,
                protocolVersion = NetworkContract.ProtocolVersion,
                compatible = payload.protocolVersion == NetworkContract.ProtocolVersion,
            })
        end,
    })
end

return DiagnosticHandshake
