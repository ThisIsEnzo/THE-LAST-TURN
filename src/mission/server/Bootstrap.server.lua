--!strict
-- MISSION server entry point. Feature services are added in their own roadmap tasks.

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

assert(RunService:IsServer(), "MISSION bootstrap must run on the server.")

print("[THE LAST TURN][MISSION] Server bootstrap started.")

-- Networking must initialize before any system that registers remote handlers.
local NetworkService = require(ServerStorage.ServerShared.Network.NetworkService)
local DiagnosticHandshake = require(ServerStorage.ServerShared.Network.DiagnosticHandshake)

NetworkService.init()
DiagnosticHandshake.register("MISSION") -- TTL-02 diagnostic only; removable.

print("[THE LAST TURN][MISSION] Networking initialized.")
