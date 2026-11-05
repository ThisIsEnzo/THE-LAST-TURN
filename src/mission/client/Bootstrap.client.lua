--!strict
-- MISSION client entry point. Client controllers are added in their own roadmap tasks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("[THE LAST TURN][MISSION] Client bootstrap started.")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiagnosticHandshakeClient = require(Shared:WaitForChild("Network"):WaitForChild("DiagnosticHandshakeClient"))

DiagnosticHandshakeClient.start("MISSION") -- TTL-02 diagnostic only; removable.
