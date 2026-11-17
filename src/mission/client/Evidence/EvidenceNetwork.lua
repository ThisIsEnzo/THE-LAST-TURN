--!strict
-- Roblox wiring of the evidence snapshot controller (TTL-11C). This is the ONLY client module that touches the evidence
-- remotes: it waits for the server-created remotes (ClientNetwork never creates any), connects the snapshot listener first,
-- then reports the listener ready so the controller pulls the current snapshot once (this also initializes a player who
-- joins a mission already in progress). The only thing it can send is the payload-less EvidenceRequestSnapshot: evidence is
-- discovered through server-created interactions, so no remote can discover, confirm or change anything. Every wait is bounded
-- by ClientNetwork's timeout and runs on its own thread, so nothing here can block the client's startup.
--
-- The controller itself is the existing pure ObjectiveController (TTL-09C): it is generic over the injected view module, so
-- it drives EvidenceView unchanged and nothing is duplicated. (Its log lines carry an "[Objective]" prefix; cosmetic.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClientNetwork = require(Shared:WaitForChild("Network"):WaitForChild("ClientNetwork"))
local NetworkContract = require(Shared:WaitForChild("Network"):WaitForChild("NetworkContract"))
local EvidenceView = require(Shared:WaitForChild("Evidence"):WaitForChild("EvidenceView"))
local ObjectiveController = require(Shared:WaitForChild("Objective"):WaitForChild("ObjectiveController"))

local LOG_PREFIX = "[THE LAST TURN][MISSION]"

local EvidenceNetwork = {}

-- Builds a controller wired to the real evidence remotes. The caller starts and destroys it.
function EvidenceNetwork.createController(): any
    local requestRemote: RemoteEvent? = nil

    local function connect(handler: (any) -> (), onReady: () -> (), onFailed: (string) -> ()): () -> ()
        local cancelled = false
        local connection: RBXScriptConnection? = nil

        task.spawn(function()
            local notification = ClientNetwork.waitForNotification(NetworkContract.Notifications.EvidenceSnapshot)
            if cancelled then
                return
            end
            if notification == nil then
                onFailed("the evidence snapshot remote is not available")
                return
            end
            connection = notification.OnClientEvent:Connect(handler) -- listener first ...

            local request = ClientNetwork.waitForRequest(NetworkContract.Requests.EvidenceRequestSnapshot)
            if cancelled then
                return
            end
            if request == nil then
                onFailed("the evidence snapshot request remote is not available (pushes still work)")
                return
            end
            requestRemote = request
            onReady() -- ... then the controller pulls the current snapshot
        end)

        return function()
            cancelled = true
            local current = connection
            connection = nil
            if current ~= nil then
                current:Disconnect()
            end
            requestRemote = nil
        end
    end

    return ObjectiveController.new({
        view = EvidenceView,
        connect = connect,
        requestSnapshot = function()
            local remote = requestRemote
            if remote ~= nil then
                remote:FireServer() -- no arguments: the client never names evidence, a source or a state
            end
        end,
        schedule = function(delaySeconds: number, callback: () -> ()): () -> ()
            local thread = task.delay(delaySeconds, callback)
            return function()
                pcall(task.cancel, thread)
            end
        end,
        now = time,
        log = function(message: string)
            warn(LOG_PREFIX .. message)
        end,
    })
end

return EvidenceNetwork
