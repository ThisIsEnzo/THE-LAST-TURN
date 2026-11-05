--!strict
-- Client-side access to the remotes created by the server.
-- The client never creates remotes; it only waits for the server-created instances.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkContract = require(script.Parent.NetworkContract)

local DEFAULT_TIMEOUT_SECONDS = 10

local ClientNetwork = {}

local function waitForRemote(folderName: string, remoteName: string, timeout: number?): RemoteEvent?
    local root = ReplicatedStorage:WaitForChild(NetworkContract.RootFolderName, timeout or DEFAULT_TIMEOUT_SECONDS)
    local folder = root and root:WaitForChild(folderName, timeout or DEFAULT_TIMEOUT_SECONDS)
    local remote = folder and folder:WaitForChild(remoteName, timeout or DEFAULT_TIMEOUT_SECONDS)
    if remote and remote:IsA("RemoteEvent") then
        return remote
    end
    warn(string.format("[THE LAST TURN][Network] Remote %s/%s not available.", folderName, remoteName))
    return nil
end

-- Client -> server remote. Names must come from NetworkContract.Requests.
function ClientNetwork.waitForRequest(name: string, timeout: number?): RemoteEvent?
    if (NetworkContract.Requests :: { [string]: string })[name] ~= name then
        error("Unknown request remote: " .. tostring(name), 2)
    end
    return waitForRemote(NetworkContract.RequestsFolderName, name, timeout)
end

-- Server -> client remote. Names must come from NetworkContract.Notifications.
function ClientNetwork.waitForNotification(name: string, timeout: number?): RemoteEvent?
    if (NetworkContract.Notifications :: { [string]: string })[name] ~= name then
        error("Unknown notification remote: " .. tostring(name), 2)
    end
    return waitForRemote(NetworkContract.NotificationsFolderName, name, timeout)
end

return ClientNetwork
