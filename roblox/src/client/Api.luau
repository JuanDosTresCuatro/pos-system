-- Client side of the Api router: Api.call returns (ok, dataOrError), Api.on listens to pushes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("POS")
local Net = require(Shared:WaitForChild("Net"))

local Api = {}

local remote, push = Net.client()
local listeners: { [string]: { (any) -> () } } = {}

push.OnClientEvent:Connect(function(kind: string, payload: any)
	local list = listeners[kind]
	if list then
		for _, fn in list do
			task.spawn(fn, payload)
		end
	end
end)

function Api.on(kind: string, fn: (any) -> ())
	listeners[kind] = listeners[kind] or {}
	table.insert(listeners[kind], fn)
end

function Api.call(action: string, ...: any): (boolean, any)
	local ok, response = pcall(remote.InvokeServer, remote, action, ...)
	if not ok then
		return false, "Connection problem. Try again."
	end
	if typeof(response) ~= "table" then
		return false, "Unexpected response"
	end
	if response.ok then
		return true, response.data
	end
	return false, response.error
end

return Api
