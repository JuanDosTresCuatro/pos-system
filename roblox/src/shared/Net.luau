-- Two remotes carry everything:
--   Api  (RemoteFunction) client -> server requests, routed by action name, answered with
--        { ok = true, data = ... } or { ok = false, error = "message" }
--   Push (RemoteEvent)    server -> client events: Push:FireClient(player, kind, payload)
-- The server never calls InvokeClient, so a client cannot hang a server thread.

local Net = {}

local FOLDER = "Remotes"

function Net.server(): (RemoteFunction, RemoteEvent)
	local folder = Instance.new("Folder")
	folder.Name = FOLDER
	local api = Instance.new("RemoteFunction")
	api.Name = "Api"
	api.Parent = folder
	local push = Instance.new("RemoteEvent")
	push.Name = "Push"
	push.Parent = folder
	folder.Parent = script.Parent
	return api, push
end

function Net.client(): (RemoteFunction, RemoteEvent)
	local folder = script.Parent:WaitForChild(FOLDER)
	return folder:WaitForChild("Api") :: RemoteFunction, folder:WaitForChild("Push") :: RemoteEvent
end

return Net
