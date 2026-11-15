--!strict
-- MISSION client entry point. Client controllers are added in their own roadmap tasks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("[THE LAST TURN][MISSION] Client bootstrap started.")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiagnosticHandshakeClient = require(Shared:WaitForChild("Network"):WaitForChild("DiagnosticHandshakeClient"))

DiagnosticHandshakeClient.start("MISSION") -- TTL-02 diagnostic only; removable.

-- TTL-09C: objective HUD. Each piece starts in its own protected call so one failure cannot take down the others or the
-- rest of the client; failures are logged, never swallowed.
local ObjectiveNetwork = require(script.Parent:WaitForChild("Objective"):WaitForChild("ObjectiveNetwork"))
local ObjectiveHud = require(script.Parent:WaitForChild("Objective"):WaitForChild("ObjectiveHud"))

local function startPart(name: string, startFunction: () -> ())
    local ok, err = pcall(startFunction)
    if not ok then
        warn(string.format("[THE LAST TURN][MISSION] %s failed to start: %s", name, tostring(err)))
    end
end

local objectiveController: any = nil
startPart("ObjectiveController", function()
    objectiveController = ObjectiveNetwork.createController()
    objectiveController:start() -- connects the listener first, then pulls the current snapshot once it is ready
end)
startPart("ObjectiveHud", function()
    if objectiveController ~= nil then
        ObjectiveHud.start(objectiveController)
    end
end)
