--!strict
-- Roblox wiring of the objective controller (TTL-09C). This is the ONLY client module that touches the objective remotes:
-- it waits for the server-created remotes (ClientNetwork never creates any), connects the snapshot listener first, then
-- reports the listener ready so the controller pulls the current snapshot once. The only thing it can send is the
-- payload-less ObjectiveRequestSnapshot; no remote can complete, fail or change an objective. Every wait is bounded by
-- ClientNetwork's timeout (10 s) and runs on its own thread, so nothing here can block the client's startup.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClientNetwork = require(Shared:WaitForChild("Network"):WaitForChild("ClientNetwork"))
local NetworkContract = require(Shared:WaitForChild("Network"):WaitForChild("NetworkContract"))
local ObjectiveView = require(Shared:WaitForChild("Objective"):WaitForChild("ObjectiveView"))
local ObjectiveController = require(Shared:WaitForChild("Objective"):WaitForChild("ObjectiveController"))

local LOG_PREFIX = "[THE LAST TURN][MISSION]"

local ObjectiveNetwork = {}

-- Builds an ObjectiveController wired to the real remotes. The caller starts and destroys it.
function ObjectiveNetwork.createController(): any
    local requestRemote: RemoteEvent? = nil

    local function connect(handler: (any) -> (), onReady: () -> (), onFailed: (string) -> ()): () -> ()
        local cancelled = false
        local connection: RBXScriptConnection? = nil

        task.spawn(function()
            local notification = ClientNetwork.waitForNotification(NetworkContract.Notifications.ObjectiveSnapshot)
            if cancelled then
                return
            end
            if notification == nil then
                onFailed("the objective snapshot remote is not available")
                return
            end
            connection = notification.OnClientEvent:Connect(handler) -- listener first ...

            local request = ClientNetwork.waitForRequest(NetworkContract.Requests.ObjectiveRequestSnapshot)
            if cancelled then
                return
            end
            if request == nil then
                onFailed("the objective snapshot request remote is not available (pushes still work)")
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
        view = ObjectiveView,
        connect = connect,
        requestSnapshot = function()
            local remote = requestRemote
            if remote ~= nil then
                remote:FireServer() -- no arguments: the client never names an objective or a state
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

return ObjectiveNetwork
