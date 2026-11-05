--!strict
-- HUB server entry point. Feature services are added in their own roadmap tasks.

local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "HUB bootstrap must run on the server.")

print("[THE LAST TURN][HUB] Server bootstrap started.")
