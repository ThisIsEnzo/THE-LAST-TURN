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

-- TTL-11C: evidence HUD. The controller is the shared snapshot controller driving EvidenceView; the presenter (pure) decides
-- what to show and the HUD (UI port) draws it. Each piece starts in its own protected call.
local EvidenceNetwork = require(script.Parent:WaitForChild("Evidence"):WaitForChild("EvidenceNetwork"))
local EvidenceHud = require(script.Parent:WaitForChild("Evidence"):WaitForChild("EvidenceHud"))
local EvidencePresenter = require(Shared:WaitForChild("Evidence"):WaitForChild("EvidencePresenter"))
local Messages = require(Shared:WaitForChild("UI"):WaitForChild("Messages"))

local evidenceController: any = nil
startPart("EvidenceController", function()
    evidenceController = EvidenceNetwork.createController()
    evidenceController:start() -- connects the listener first, then pulls the current snapshot once it is ready
end)
startPart("EvidenceHud", function()
    if evidenceController ~= nil then
        local presenter = EvidencePresenter.new({
            controller = evidenceController,
            ui = EvidenceHud,
            text = Messages,
            log = function(message: string)
                warn("[THE LAST TURN][MISSION]" .. message)
            end,
        })
        presenter:start() -- idempotent: one HUD, however often this runs
    end
end)
