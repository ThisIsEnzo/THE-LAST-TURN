--!strict
-- MISSION server entry point. Mission systems are wired here as their tasks are implemented.

local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "MISSION bootstrap must run on the server.")

print("[THE LAST TURN][MISSION] Server bootstrap started.")
