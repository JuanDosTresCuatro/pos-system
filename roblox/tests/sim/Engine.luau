-- A small fake Roblox engine for running the real RoPOS server code in Lune, without Roblox.
--
-- It implements only what RoPOS uses: instances with properties, children, attributes and
-- signals; the datatypes; Players, CollectionService, DataStoreService, MessagingService and
-- friends. Several engines can share one DataStore/MessagingService backend to act as several
-- game servers of the same experience.
--
-- It is stricter than Roblox in two useful ways: every remote payload and every DataStore value
-- is checked, so a mixed table, a function or a Color3 in a DataStore fails loudly.

local task = require("@lune/task")

local Engine = {}

local nativeTypeof = typeof

local function typeOf(value: any): string
	if type(value) == "table" then
		local mt = getmetatable(value)
		if type(mt) == "table" and rawget(mt, "__type") then
			return rawget(mt, "__type")
		end
	end
	return nativeTypeof(value)
end
Engine.typeof = typeOf

------------------------------------------------------------------------ signals

local Signal = {}
Signal.__index = Signal
Signal.__type = "RBXScriptSignal"

function Signal.new()
	return setmetatable({ handlers = {} }, Signal)
end

function Signal:Connect(fn)
	local handler = { fn = fn, on = true }
	table.insert(self.handlers, handler)
	return {
		Connected = true,
		Disconnect = function()
			handler.on = false
		end,
	}
end

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection.Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Fire(...)
	for _, handler in table.clone(self.handlers) do
		if handler.on then
			task.spawn(handler.fn, ...)
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

Engine.Signal = Signal

------------------------------------------------------------------------ datatypes

local function typed(name: string, fields: { [string]: any }?)
	local mt = { __type = name }
	for k, v in fields or {} do
		mt[k] = v
	end
	return mt
end

local Vector3mt
local function v3(x: number?, y: number?, z: number?)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3mt)
end
Vector3mt = typed("Vector3", {
	__add = function(a, b)
		return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
	end,
	__sub = function(a, b)
		return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
	end,
	__mul = function(a, b)
		if type(a) == "number" then
			a, b = b, a
		end
		if type(b) == "number" then
			return v3(a.X * b, a.Y * b, a.Z * b)
		end
		return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
	end,
	__unm = function(a)
		return v3(-a.X, -a.Y, -a.Z)
	end,
	__eq = function(a, b)
		return a.X == b.X and a.Y == b.Y and a.Z == b.Z
	end,
	__index = function(v, key)
		if key == "Magnitude" then
			return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		elseif key == "Unit" then
			local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
			return if m == 0 then v3() else v3(v.X / m, v.Y / m, v.Z / m)
		end
		return nil
	end,
	__tostring = function(v)
		return string.format("%g, %g, %g", v.X, v.Y, v.Z)
	end,
})

local Vector3 = { new = v3, zero = v3(), one = v3(1, 1, 1) }

-- CFrames keep a position only. Rotation is not needed for distance checks.
local CFramemt
local function cf(position)
	return setmetatable({ Position = position, X = position.X, Y = position.Y, Z = position.Z }, CFramemt)
end
CFramemt = typed("CFrame", {
	__mul = function(a, b)
		if typeOf(b) == "CFrame" then
			return cf(a.Position + b.Position)
		end
		return a.Position + b
	end,
})
local CFrame = {
	new = function(x, y, z)
		if typeOf(x) == "Vector3" then
			return cf(x)
		end
		return cf(v3(x, y, z))
	end,
	lookAt = function(position)
		return cf(position)
	end,
	Angles = function()
		return cf(v3())
	end,
	identity = cf(v3()),
}

local Color3mt = typed("Color3")
local Color3 = {
	new = function(r, g, b)
		return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3mt)
	end,
	fromRGB = function(r, g, b)
		return setmetatable({ R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255 }, Color3mt)
	end,
}

local UDimmt = typed("UDim")
local UDim = {
	new = function(scale, offset)
		return setmetatable({ Scale = scale or 0, Offset = offset or 0 }, UDimmt)
	end,
}
local UDim2mt = typed("UDim2")
local function udim2(xs, xo, ys, yo)
	return setmetatable({ X = UDim.new(xs, xo), Y = UDim.new(ys, yo) }, UDim2mt)
end
local UDim2 = {
	new = udim2,
	fromScale = function(x, y)
		return udim2(x, 0, y, 0)
	end,
	fromOffset = function(x, y)
		return udim2(0, x, 0, y)
	end,
}

local Vector2mt = typed("Vector2")
local Vector2 = {
	new = function(x, y)
		return setmetatable({ X = x or 0, Y = y or 0 }, Vector2mt)
	end,
}
Vector2.zero = Vector2.new()

local function stub(name: string)
	local mt = typed(name)
	return {
		new = function(...)
			return setmetatable({ args = { ... } }, mt)
		end,
	}
end

local enumItems = {}
local Enum = setmetatable({}, {
	__index = function(_, enumType)
		return setmetatable({}, {
			__index = function(_, itemName)
				local key = enumType .. "." .. itemName
				local item = enumItems[key]
				if not item then
					item = setmetatable(
						{ Name = itemName, EnumType = enumType },
						typed("EnumItem", {
							__tostring = function()
								return "Enum." .. key
							end,
						})
					)
					enumItems[key] = item
				end
				return item
			end,
		})
	end,
})

Engine.datatypes = {
	Vector3 = Vector3,
	Vector2 = Vector2,
	CFrame = CFrame,
	Color3 = Color3,
	UDim = UDim,
	UDim2 = UDim2,
	Font = stub("Font"),
	TweenInfo = stub("TweenInfo"),
	NumberSequence = stub("NumberSequence"),
	ColorSequence = stub("ColorSequence"),
	Enum = Enum,
}

------------------------------------------------------------------------ value checks

local function checkPlain(value: any, path: string, allowRoblox: boolean, seen: { [any]: boolean })
	local kind = typeOf(value)
	if kind == "nil" or kind == "boolean" or kind == "string" then
		return
	elseif kind == "number" then
		if value ~= value and not allowRoblox then
			error(path .. " is NaN", 0)
		end
		return
	elseif kind == "table" then
		if seen[value] then
			error(path .. " is a cyclic table", 0)
		end
		seen[value] = true
		local count, numeric, text = 0, 0, 0
		for key, item in value do
			count += 1
			if type(key) == "number" then
				numeric += 1
			elseif type(key) == "string" then
				text += 1
			else
				error(path .. " has a " .. typeOf(key) .. " key", 0)
			end
			checkPlain(item, path .. "." .. tostring(key), allowRoblox, seen)
		end
		if numeric > 0 and text > 0 then
			error(path .. " mixes array and dictionary keys", 0)
		end
		if numeric > 0 and #value ~= numeric then
			error(path .. " is an array with holes", 0)
		end
		seen[value] = nil
		return
	elseif allowRoblox and (kind == "Instance" or kind == "Color3" or kind == "Vector3" or kind == "EnumItem") then
		return
	end
	error(path .. " cannot be sent or saved (it is a " .. kind .. ")", 0)
end

function Engine.checkRemote(value: any, path: string)
	checkPlain(value, path, true, {})
end

function Engine.checkDataStore(value: any, path: string)
	checkPlain(value, path, false, {})
end

------------------------------------------------------------------------ instances

local INHERITS = {
	Part = "BasePart",
	SpawnLocation = "Part",
	BasePart = "PVInstance",
	Model = "PVInstance",
	PVInstance = "Instance",
	Workspace = "Model",
	IntValue = "ValueBase",
	NumberValue = "ValueBase",
	ValueBase = "Instance",
	TextLabel = "GuiObject",
	TextButton = "GuiButton",
	GuiButton = "GuiObject",
	Frame = "GuiObject",
	GuiObject = "GuiBase2d",
	SurfaceGui = "LayerCollector",
	BillboardGui = "LayerCollector",
	ScreenGui = "LayerCollector",
	LayerCollector = "GuiBase2d",
	GuiBase2d = "Instance",
	Tool = "BackpackItem",
	BackpackItem = "Instance",
	Script = "BaseScript",
	BaseScript = "LuaSourceContainer",
	ModuleScript = "LuaSourceContainer",
	LuaSourceContainer = "Instance",
}

local EVENTS = {
	Triggered = true,
	ChildAdded = true,
	ChildRemoved = true,
	DescendantAdded = true,
	Changed = true,
	PlayerAdded = true,
	PlayerRemoving = true,
	OnServerEvent = true,
	Activated = true,
}

local state = setmetatable({}, { __mode = "k" })
local InstanceMT = { __type = "Instance" }
local methods = {}
local classMethods = {}

local function isA(className: string, target: string): boolean
	local current: string? = className
	while current do
		if current == target then
			return true
		end
		current = INHERITS[current] or (if current ~= "Instance" then "Instance" else nil)
	end
	return false
end

local function signalFor(instance, name: string)
	local st = state[instance]
	local signal = st.signals[name]
	if not signal then
		signal = Signal.new()
		st.signals[name] = signal
	end
	return signal
end

InstanceMT.__index = function(instance, key)
	local st = state[instance]
	local method = methods[key] or (classMethods[st.className] and classMethods[st.className][key])
	if method then
		return method
	end
	if key == "ClassName" then
		return st.className
	elseif key == "Parent" then
		return st.parent
	elseif key == "Position" and st.props.CFrame then
		return st.props.CFrame.Position
	end
	local value = st.props[key]
	if value ~= nil then
		return value
	end
	if EVENTS[key] then
		return signalFor(instance, key)
	end
	for _, child in st.children do
		if state[child].props.Name == key then
			return child
		end
	end
	return nil
end

InstanceMT.__newindex = function(instance, key, value)
	local st = state[instance]
	if st.destroyed and key == "Parent" and value ~= nil then
		error("The Parent property of " .. tostring(st.props.Name) .. " is locked", 2)
	end
	if key == "Parent" then
		local old = st.parent
		if old == value then
			return
		end
		if old then
			local siblings = state[old].children
			local index = table.find(siblings, instance)
			if index then
				table.remove(siblings, index)
			end
			signalFor(old, "ChildRemoved"):Fire(instance)
		end
		st.parent = value
		if value then
			table.insert(state[value].children, instance)
			signalFor(value, "ChildAdded"):Fire(instance)
			local ancestor = value
			while ancestor do
				signalFor(ancestor, "DescendantAdded"):Fire(instance)
				ancestor = state[ancestor].parent
			end
		end
		return
	end
	if key == "Position" and isA(st.className, "BasePart") then
		st.props.CFrame = CFrame.new(value)
	else
		st.props[key] = value
	end
	local changed = st.propertySignals[key]
	if changed then
		changed:Fire()
	end
end

InstanceMT.__tostring = function(instance)
	return tostring(state[instance].props.Name)
end

local function newInstance(className: string)
	local instance = setmetatable({}, InstanceMT)
	state[instance] = {
		className = className,
		props = { Name = className },
		children = {},
		parent = nil,
		attributes = {},
		tags = {},
		signals = {},
		propertySignals = {},
		destroyed = false,
	}
	return instance
end
Engine.newInstance = newInstance

function methods.IsA(self, className)
	return isA(state[self].className, className)
end

function methods.GetChildren(self)
	return table.clone(state[self].children)
end

function methods.GetDescendants(self)
	local out = {}
	local function walk(node)
		for _, child in state[node].children do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end

function methods.FindFirstChild(self, name, recursive)
	for _, child in state[self].children do
		if state[child].props.Name == name then
			return child
		end
	end
	if recursive then
		for _, child in state[self].children do
			local found = child:FindFirstChild(name, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function methods.FindFirstChildWhichIsA(self, className, recursive)
	for _, child in state[self].children do
		if child:IsA(className) then
			return child
		end
	end
	if recursive then
		for _, child in state[self].children do
			local found = child:FindFirstChildWhichIsA(className, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function methods.FindFirstChildOfClass(self, className)
	for _, child in state[self].children do
		if state[child].className == className then
			return child
		end
	end
	return nil
end

function methods.WaitForChild(self, name, timeout)
	local deadline = os.clock() + (timeout or 10)
	while os.clock() < deadline do
		local child = self:FindFirstChild(name)
		if child then
			return child
		end
		task.wait(0.01)
	end
	if timeout then
		return nil
	end
	error("WaitForChild timed out: " .. self:GetFullName() .. "." .. name, 2)
end

function methods.IsDescendantOf(self, ancestor)
	local node = state[self].parent
	while node do
		if node == ancestor then
			return true
		end
		node = state[node].parent
	end
	return false
end

function methods.GetAttribute(self, name)
	return state[self].attributes[name]
end

function methods.SetAttribute(self, name, value)
	state[self].attributes[name] = value
end

function methods.GetPropertyChangedSignal(self, property)
	local st = state[self]
	local signal = st.propertySignals[property]
	if not signal then
		signal = Signal.new()
		st.propertySignals[property] = signal
	end
	return signal
end

function methods.Destroy(self)
	local st = state[self]
	for _, child in table.clone(st.children) do
		child:Destroy()
	end
	self.Parent = nil
	st.destroyed = true
end

function methods.ClearAllChildren(self)
	for _, child in table.clone(state[self].children) do
		child:Destroy()
	end
end

function methods.Clone(self)
	local st = state[self]
	local copy = newInstance(st.className)
	for key, value in st.props do
		state[copy].props[key] = value
	end
	for key, value in st.attributes do
		state[copy].attributes[key] = value
	end
	for _, child in st.children do
		child:Clone().Parent = copy
	end
	return copy
end

function methods.GetFullName(self)
	local parts = {}
	local node = self
	while node and state[node].className ~= "DataModel" do
		table.insert(parts, 1, tostring(state[node].props.Name))
		node = state[node].parent
	end
	return table.concat(parts, ".")
end

------------------------------------------------------------------------ engines

export type Backend = {
	data: { [string]: { [string]: any } },
	subscribers: { [string]: { (any) -> () } },
	failNext: number,
	writes: number,
}

function Engine.newBackend(): Backend
	return { data = {}, subscribers = {}, failNext = 0, writes = 0 }
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end

local guid = 0
local contexts = setmetatable({}, { __mode = "k" }) -- DataModel -> per-server state

methods.FindFirstAncestorGame = function(self)
	local node = self
	while node and state[node].className ~= "DataModel" do
		node = state[node].parent
	end
	return node
end

-- Per-server state for any instance in that server's tree.
local function ctx(instance)
	local game = instance:FindFirstAncestorGame()
	return assert(contexts[game], "instance is not in a game: " .. tostring(instance))
end

classMethods.DataModel = {
	GetService = function(self, className)
		return contexts[self].service(className)
	end,
	BindToClose = function(self, fn)
		table.insert(contexts[self].engine.closeHandlers, fn)
	end,
}

classMethods.Workspace = {
	Raycast = function()
		return nil
	end,
}

classMethods.Players = {
	GetPlayers = function(self)
		local out = {}
		for _, child in self:GetChildren() do
			if child.ClassName == "Player" then
				table.insert(out, child)
			end
		end
		return out
	end,
	GetPlayerByUserId = function(self, userId)
		for _, child in self:GetChildren() do
			if child.ClassName == "Player" and child.UserId == userId then
				return child
			end
		end
		return nil
	end,
}

classMethods.Player = {
	GetRankInGroupAsync = function()
		return 0
	end,
}

classMethods.RunService = {
	IsStudio = function(self)
		return ctx(self).studio
	end,
	IsServer = function()
		return true
	end,
}

classMethods.RemoteEvent = {
	FireClient = function(self, player, ...)
		local args = { ... }
		Engine.checkRemote(args, "FireClient(" .. tostring(args[1]) .. ")")
		local engine = ctx(self).engine
		engine.inbox[player] = engine.inbox[player] or {}
		table.insert(engine.inbox[player], { kind = args[1], payload = args[2] })
	end,
}

local function tagSignal(instance, kind: string, tag: string)
	local list = ctx(instance)[kind]
	list[tag] = list[tag] or Signal.new()
	return list[tag]
end

classMethods.CollectionService = {
	AddTag = function(self, instance, tag)
		state[instance].tags[tag] = true
		tagSignal(self, "added", tag):Fire(instance)
	end,
	RemoveTag = function(self, instance, tag)
		state[instance].tags[tag] = nil
		tagSignal(self, "removed", tag):Fire(instance)
	end,
	HasTag = function(_, instance, tag)
		return state[instance].tags[tag] == true
	end,
	GetTagged = function(self, tag)
		local out = {}
		for _, instance in self:FindFirstAncestorGame():GetDescendants() do
			if state[instance].tags[tag] then
				table.insert(out, instance)
			end
		end
		return out
	end,
	GetInstanceAddedSignal = function(self, tag)
		return tagSignal(self, "added", tag)
	end,
	GetInstanceRemovedSignal = function(self, tag)
		return tagSignal(self, "removed", tag)
	end,
}

classMethods.TweenService = {
	Create = function(_, instance, _info, props)
		return {
			Play = function()
				for key, value in props do
					instance[key] = value
				end
			end,
		}
	end,
}

classMethods.HttpService = {
	GenerateGUID = function()
		guid += 1
		return string.format("%08X-0000-4000-8000-%012X", guid, guid)
	end,
}

-- One backend shared by every server, like the real DataStores.
classMethods.DataStoreService = {
	GetDataStore = function(self, storeName)
		local backend = ctx(self).engine.backend
		backend.data[storeName] = backend.data[storeName] or {}
		local data = backend.data[storeName]
		local function maybeFail()
			task.wait(0.002) -- DataStore calls always yield
			if backend.failNext > 0 then
				backend.failNext -= 1
				error("503: simulated DataStore outage", 0)
			end
		end
		return {
			GetAsync = function(_, key)
				maybeFail()
				return deepCopy(data[key])
			end,
			SetAsync = function(_, key, value)
				maybeFail()
				Engine.checkDataStore(value, storeName .. "/" .. key)
				backend.writes += 1
				data[key] = deepCopy(value)
			end,
			UpdateAsync = function(_, key, transform)
				maybeFail()
				local new = transform(deepCopy(data[key]))
				if new == nil then
					return nil
				end
				Engine.checkDataStore(new, storeName .. "/" .. key)
				backend.writes += 1
				data[key] = deepCopy(new)
				return deepCopy(new)
			end,
		}
	end,
}

classMethods.MessagingService = {
	SubscribeAsync = function(self, topic, callback)
		local backend = ctx(self).engine.backend
		backend.subscribers[topic] = backend.subscribers[topic] or {}
		table.insert(backend.subscribers[topic], callback)
		return { Disconnect = function() end }
	end,
	PublishAsync = function(self, topic, data)
		local backend = ctx(self).engine.backend
		Engine.checkDataStore(data, "PublishAsync " .. topic)
		task.wait(0.002)
		for _, callback in backend.subscribers[topic] or {} do
			task.spawn(callback, { Data = data, Sent = os.time() })
		end
	end,
}

-- Creates one fake game server. options.studio: what RunService:IsStudio() returns.
function Engine.new(name: string, backend: Backend, options: { studio: boolean? }?)
	local engine = {
		name = name,
		backend = backend,
		inbox = {} :: { [any]: { { kind: string, payload: any } } },
		closeHandlers = {},
	}
	local opts = options or {}

	local game = newInstance("DataModel")
	game.Name = name
	game.CreatorType = Enum.CreatorType.User
	game.CreatorId = 0
	engine.game = game

	local services = {}
	local function service(className: string)
		local instance = services[className]
		if not instance then
			instance = newInstance(className)
			instance.Name = className
			instance.Parent = game
			services[className] = instance
		end
		return instance
	end
	contexts[game] = { service = service, engine = engine, studio = opts.studio == true, added = {}, removed = {} }

	for _, className in
		{
			"Workspace",
			"Players",
			"ReplicatedStorage",
			"ServerStorage",
			"ServerScriptService",
			"RunService",
			"CollectionService",
			"TweenService",
			"HttpService",
			"DataStoreService",
			"MessagingService",
			"Lighting",
			"StarterPlayer",
		}
	do
		service(className)
	end
	local workspace = service("Workspace")
	local players = service("Players")
	engine.workspace = workspace

	-- Helpers for scenarios ------------------------------------------------

	function engine.addPlayer(userId: number, displayName: string, position)
		local player = newInstance("Player")
		player.Name = string.lower(displayName)
		player.DisplayName = displayName
		player.UserId = userId
		local character = newInstance("Model")
		character.Name = displayName
		local root = newInstance("Part")
		root.Name = "HumanoidRootPart"
		root.CFrame = CFrame.new(position)
		root.Parent = character
		player.Character = character
		character.Parent = workspace
		local backpack = newInstance("Backpack")
		backpack.Name = "Backpack"
		backpack.Parent = player
		player.Parent = players
		players.PlayerAdded:Fire(player)
		return player
	end

	function engine.removePlayer(player)
		players.PlayerRemoving:Fire(player)
		task.wait(0.05)
		player.Parent = nil
	end

	function engine.moveTo(player, position)
		player.Character.HumanoidRootPart.CFrame = CFrame.new(position)
	end

	function engine.pushes(player, kind: string?)
		local out = {}
		for _, push in engine.inbox[player] or {} do
			if kind == nil or push.kind == kind then
				table.insert(out, push.payload)
			end
		end
		return out
	end

	function engine.lastPush(player, kind: string)
		local list = engine.pushes(player, kind)
		return list[#list]
	end

	function engine.clearInbox(player)
		engine.inbox[player] = {}
	end

	function engine.shutdown()
		for _, fn in engine.closeHandlers do
			fn()
		end
	end

	return engine
end

return Engine
