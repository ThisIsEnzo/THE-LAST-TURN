--!strict
-- HUB client entry point.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("[THE LAST TURN][HUB] Client bootstrap started.")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiagnosticHandshakeClient = require(Shared:WaitForChild("Network"):WaitForChild("DiagnosticHandshakeClient"))

DiagnosticHandshakeClient.start("HUB") -- TTL-02 diagnostic only; removable.

-- TTL-HUB-02: party UI and mission preparation. Each piece starts in its own protected call so one failure cannot take
-- down the others or the rest of the client; failures are logged, never swallowed.
local PartyController = require(script.Parent:WaitForChild("Party"):WaitForChild("PartyController"))
local MissionLaunchController = require(script.Parent:WaitForChild("Mission"):WaitForChild("MissionLaunchController"))
local PartyHud = require(script.Parent:WaitForChild("UI"):WaitForChild("PartyHud"))
local MissionTerminal = require(script.Parent:WaitForChild("UI"):WaitForChild("MissionTerminal"))

local function startPart(name: string, startFunction: () -> ())
    local ok, err = pcall(startFunction)
    if not ok then
        warn(string.format("[THE LAST TURN][HUB] %s failed to start: %s", name, tostring(err)))
    end
end

startPart("PartyController", function()
    PartyController.start()
end)
startPart("MissionLaunchController", function()
    MissionLaunchController.start(PartyController)
end)
startPart("PartyHud", function()
    PartyHud.start(PartyController, MissionLaunchController)
end)
startPart("MissionTerminal", function()
    MissionTerminal.start(PartyController, MissionLaunchController)
end)
