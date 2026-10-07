-- DataStore access with retries, a serialised flush loop, and an in-memory fallback for
-- Studio places that have API access turned off.
--
-- Every shared document is written with UpdateAsync and a transform that applies this
-- server's *changes* (deltas) to the stored value, so many servers can write the same key
-- without overwriting each other.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("POS").Config)

local Store = {}
Store.persistent = true

local stores = {}
local flushers: { { name: string, fn: () -> () } } = {}
local flushing = false

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end
Store.deepCopy = deepCopy

-- Same calls as a DataStore, kept in memory for this server only.
local MemoryStore = {}
MemoryStore.__index = MemoryStore

function MemoryStore.new()
	return setmetatable({ data = {} }, MemoryStore)
end

function MemoryStore:GetAsync(key: string)
	return deepCopy(self.data[key])
end

function MemoryStore:SetAsync(key: string, value: any)
	self.data[key] = deepCopy(value)
end

function MemoryStore:UpdateAsync(key: string, transform: (any) -> any)
	local new = transform(deepCopy(self.data[key]))
	if new == nil then
		return nil
	end
	self.data[key] = deepCopy(new)
	return deepCopy(new)
end

function Store.init()
	if not RunService:IsStudio() then
		return
	end
	local ok, err = pcall(function()
		DataStoreService:GetDataStore("RoPOS_Probe"):GetAsync("probe")
	end)
	if not ok then
		Store.persistent = false
		warn(
			"[RoPOS] DataStores are not available ("
				.. tostring(err)
				.. "). Data is kept in memory and is lost when the test stops. To save data, publish the place and turn on"
				.. " Game Settings > Security > Enable Studio Access to API Services."
		)
	end
end

function Store.get(name: string)
	local fullName = string.format("RoPOS_%s_%s", name, Config.Data.Scope)
	local store = stores[fullName]
	if not store then
		store = if Store.persistent then DataStoreService:GetDataStore(fullName) else MemoryStore.new()
		stores[fullName] = store
	end
	return store
end

local ATTEMPTS = 4

function Store.retry(label: string, fn: () -> any): (boolean, any)
	local lastError
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = result
		if attempt < ATTEMPTS then
			task.wait(0.5 * 2 ^ attempt)
		end
	end
	warn(string.format("[RoPOS] %s failed: %s", label, tostring(lastError)))
	return false, lastError
end

function Store.read(storeName: string, key: string): (boolean, any)
	local store = Store.get(storeName)
	return Store.retry("read " .. storeName .. "/" .. key, function()
		return store:GetAsync(key)
	end)
end

-- transform(old) returns the new value, or nil to leave the key unchanged.
function Store.update(storeName: string, key: string, transform: (any) -> any): (boolean, any)
	local store = Store.get(storeName)
	return Store.retry("update " .. storeName .. "/" .. key, function()
		return store:UpdateAsync(key, transform)
	end)
end

-- Flushers send batched changes. They never run at the same time as each other.
function Store.onFlush(name: string, fn: () -> ())
	table.insert(flushers, { name = name, fn = fn })
end

function Store.flushAll()
	while flushing do
		task.wait()
	end
	flushing = true
	for _, flusher in flushers do
		local ok, err = pcall(flusher.fn)
		if not ok then
			warn(string.format("[RoPOS] flush %s failed: %s", flusher.name, tostring(err)))
		end
	end
	flushing = false
end

function Store.start()
	task.spawn(function()
		while true do
			task.wait(Config.Data.FlushInterval)
			Store.flushAll()
		end
	end)
	game:BindToClose(function()
		Store.flushAll()
	end)
end

return Store
