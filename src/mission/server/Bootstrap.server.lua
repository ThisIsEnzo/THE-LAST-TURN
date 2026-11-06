--!strict
-- MISSION server entry point. Feature services are added in their own roadmap tasks.

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

assert(RunService:IsServer(), "MISSION bootstrap must run on the server.")

print("[THE LAST TURN][MISSION] Server bootstrap started.")

-- Networking must initialize before any system that registers remote handlers.
local NetworkService = require(ServerStorage.ServerShared.Network.NetworkService)
local DiagnosticHandshake = require(ServerStorage.ServerShared.Network.DiagnosticHandshake)
local PlayerStateService = require(ServerStorage.ServerShared.Player.PlayerStateService)
local MissionContextService = require(script.Parent.MissionContext.MissionContextService)

NetworkService.init()
PlayerStateService.init() -- TTL-03: must run after networking; other systems start after this.
MissionContextService.init() -- TTL-05: validates teleport data of arriving players; starts no gameplay.
DiagnosticHandshake.register("MISSION") -- TTL-02 diagnostic only; removable.

print("[THE LAST TURN][MISSION] Networking initialized.")
