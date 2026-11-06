--!strict
-- Entry point: `lune run tests/run`. Exits non-zero if any test fails.

local process = require("@lune/process")

local Harness = require("./Harness")
require("./server_shared/Validator.spec")
require("./server_shared/RateLimiter.spec")
require("./server_shared/PlayerStateCore.spec")
require("./server_shared/PartyCore.spec")
require("./server_shared/TeleportPayload.spec")
require("./server_shared/ArrivalCore.spec")
require("./server_shared/LaunchCoordinator.spec")

local results = Harness.results()
for _, failure in ipairs(results.failures) do
    print("FAIL " .. failure)
end
print(string.format("%d passed, %d failed", results.passed, results.failed))
if results.failed > 0 then
    process.exit(1)
end
