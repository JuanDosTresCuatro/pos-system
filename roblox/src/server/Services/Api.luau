-- Request router for the single Api RemoteFunction.
--
--   Api.handle("sales.refund", Roles.Manager, function(player, receipt, restock) ... end)
--
-- Each request is rate limited per player, checked against the handler's minimum role and run
-- in a pcall. Handlers report a user-facing problem with Api.fail("message"); any other error
-- is logged and the client gets a generic message, so internals never leak.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Net = require(Shared.Net)
local Roles = require(Shared.Roles)

local Api = {}

type Handler = { role: number, fn: (Player, ...any) -> any }

local handlers: { [string]: Handler } = {}
local buckets: { [Player]: { tokens: number, last: number } } = {}
local remote: RemoteFunction
local push: RemoteEvent
local roleOf: (Player) -> number = function(_player)
	return Roles.Customer
end

local RATE = 8 -- requests refilled per second
local BURST = 20

local function allow(player: Player): boolean
	local now = os.clock()
	local bucket = buckets[player]
	if not bucket then
		bucket = { tokens = BURST, last = now }
		buckets[player] = bucket
	end
	bucket.tokens = math.min(BURST, bucket.tokens + (now - bucket.last) * RATE)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function dispatch(player: Player, action: any, ...: any)
	if typeof(action) ~= "string" then
		return { ok = false, error = "Bad request" }
	end
	local handler = handlers[action]
	if not handler then
		return { ok = false, error = "Unknown action" }
	end
	if not allow(player) then
		return { ok = false, error = "Slow down a little" }
	end
	if roleOf(player) < handler.role then
		return { ok = false, error = "You don't have permission to do that" }
	end

	local ok, result = pcall(handler.fn, player, ...)
	if ok then
		return { ok = true, data = result }
	end
	if typeof(result) == "table" and result.posError then
		return { ok = false, error = result.posError }
	end
	warn(string.format("[RoPOS] %s from %s failed: %s", action, player.Name, tostring(result)))
	return { ok = false, error = "Something went wrong. Try again." }
end

function Api.init(resolveRole: (Player) -> number)
	roleOf = resolveRole
	remote, push = Net.server()
	remote.OnServerInvoke = dispatch
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)
end

function Api.handle(action: string, minRole: number, fn: (Player, ...any) -> any)
	assert(handlers[action] == nil, "duplicate handler " .. action)
	handlers[action] = { role = minRole, fn = fn }
end

function Api.fail(message: string): never
	error({ posError = message }, 0)
end

function Api.push(player: Player, kind: string, payload: any?)
	if push and player.Parent then
		push:FireClient(player, kind, payload)
	end
end

function Api.pushWhere(predicate: (Player) -> boolean, kind: string, payload: any?)
	if not push then
		return
	end
	for _, player in Players:GetPlayers() do
		if predicate(player) then
			push:FireClient(player, kind, payload)
		end
	end
end

function Api.toast(player: Player, text: string, kind: string?)
	Api.push(player, "Toast", { text = text, kind = kind or "info" })
end

return Api
