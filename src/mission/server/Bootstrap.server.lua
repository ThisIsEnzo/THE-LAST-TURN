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
local MissionLifecycleService = require(script.Parent.MissionLifecycle.MissionLifecycleService)
local MissionConfigService = require(script.Parent.MissionConfig.MissionConfigService)
local InteractionService = require(script.Parent.Interaction.InteractionService)
local DoorInteractionService = require(script.Parent.Door.DoorInteractionService)
local ObjectiveService = require(script.Parent.Objective.ObjectiveService)

NetworkService.init()
PlayerStateService.init() -- TTL-03: must run after networking; other systems start after this.
MissionContextService.init() -- TTL-05: validates teleport data of arriving players; starts no gameplay.
MissionConfigService.init() -- TTL-07: registers the first lifecycle system; MUST run before MissionLifecycleService.init().
InteractionService.init() -- TTL-08B-B: registers the Interaction lifecycle system; after MissionConfigService, BEFORE MissionLifecycleService.init().
DoorInteractionService.init() -- TTL-08C: first gameplay consumer; registers after InteractionService, BEFORE MissionLifecycleService.init().
ObjectiveService.init() -- TTL-09B: after InteractionService (and the door), BEFORE MissionLifecycleService.init().
MissionLifecycleService.init() -- TTL-06: owns the mission lifecycle; after MissionContextService.
DiagnosticHandshake.register("MISSION") -- TTL-02 diagnostic only; removable.

print("[THE LAST TURN][MISSION] Networking initialized.")
