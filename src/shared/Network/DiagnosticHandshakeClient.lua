--!strict
-- TTL-02 diagnostic handshake (client half). Isolated and removable: delete this file, the
-- matching server module, the two contract entries, the NetworkConfig entry and the bootstrap calls.
-- The acknowledgement is informational only; it grants no permission or authority.

local NetworkContract = require(script.Parent.NetworkContract)
local ClientNetwork = require(script.Parent.ClientNetwork)

local DiagnosticHandshakeClient = {}

local started = false

function DiagnosticHandshakeClient.start(placeName: string)
    if started then
        return
    end
    started = true

    task.spawn(function()
        local ack = ClientNetwork.waitForNotification(NetworkContract.Notifications.HandshakeAck)
        local request = ClientNetwork.waitForRequest(NetworkContract.Requests.ClientReady)
        if not ack or not request then
            warn(string.format("[THE LAST TURN][%s] Handshake unavailable: remotes missing.", placeName))
            return
        end

        -- Connect before firing so the reply cannot be missed.
        ack.OnClientEvent:Connect(function(payload: any)
            if type(payload) ~= "table" then
                return
            end
            print(
                string.format(
                    "[THE LAST TURN][%s] Handshake acknowledged by server (place=%s, compatible=%s).",
                    placeName,
                    tostring(payload.place),
                    tostring(payload.compatible)
                )
            )
        end)

        request:FireServer({ protocolVersion = NetworkContract.ProtocolVersion })
    end)
end

return DiagnosticHandshakeClient
