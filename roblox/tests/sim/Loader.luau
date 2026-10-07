-- Mounts the real RoPOS source files into a fake engine using the same layout as
-- default.project.json, and runs them with Roblox-style `require(instance)` and `script`.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")

local Engine = require("./Engine")

local Loader = {}

-- Same rules as Rojo: init.server.luau makes the folder a Script, other files are ModuleScripts.
local function mount(engine, parent, name: string, dir: string, sources)
	local entries = fs.readDir(dir)
	table.sort(entries)
	local isScript = table.find(entries, "init.server.luau") ~= nil
	local node = Engine.newInstance(if isScript then "Script" else "Folder")
	node.Name = name
	if isScript then
		sources[node] = dir .. "/init.server.luau"
	end
	for _, entry in entries do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			mount(engine, node, entry, path, sources)
		elseif string.match(entry, "%.luau$") and not string.match(entry, "^init%.") then
			local module = Engine.newInstance("ModuleScript")
			module.Name = string.gsub(entry, "%.luau$", "")
			module.Parent = node
			sources[module] = path
		end
	end
	node.Parent = parent
	return node
end

-- Creates a server: mounts shared and server code, returns helpers. Call server.start() to boot.
function Loader.server(engine, root: string, prepare: ((any) -> ())?)
	local sources = {}
	local cache = {}
	local loading = {}
	local game = engine.game
	local types = Engine.datatypes

	local shared = mount(engine, game:GetService("ReplicatedStorage"), "POS", root .. "/src/shared", sources)
	local serverScript =
		mount(engine, game:GetService("ServerScriptService"), "POSServer", root .. "/src/server", sources)

	local requireInstance

	local function environment(scriptInstance)
		return {
			script = scriptInstance,
			game = game,
			workspace = engine.workspace,
			require = function(target)
				return requireInstance(target)
			end,
			Instance = { new = Engine.newInstance },
			typeof = Engine.typeof,
			task = task,
			warn = function(...)
				local parts = {}
				for _, part in { ... } do
					table.insert(parts, tostring(part))
				end
				table.insert(engine.warnings, table.concat(parts, " "))
			end,
			print = function() end,
			Vector3 = types.Vector3,
			Vector2 = types.Vector2,
			CFrame = types.CFrame,
			Color3 = types.Color3,
			UDim = types.UDim,
			UDim2 = types.UDim2,
			Font = types.Font,
			TweenInfo = types.TweenInfo,
			NumberSequence = types.NumberSequence,
			ColorSequence = types.ColorSequence,
			Enum = types.Enum,
		}
	end

	local function compile(instance)
		local path = assert(sources[instance], "no source for " .. instance:GetFullName())
		local bytecode = luau.compile(fs.readFile(path))
		return luau.load(bytecode, { debugName = path, environment = environment(instance) })
	end

	function requireInstance(instance)
		if cache[instance] ~= nil then
			return cache[instance]
		end
		assert(Engine.typeof(instance) == "Instance" and instance:IsA("ModuleScript"), "require expects a ModuleScript")
		assert(not loading[instance], "circular require of " .. instance:GetFullName())
		loading[instance] = true
		local result = compile(instance)()
		loading[instance] = nil
		cache[instance] = result
		return result
	end

	engine.warnings = engine.warnings or {}

	local server = { engine = engine, shared = shared, script = serverScript }

	-- Module by dotted path under the server script, e.g. "Services.Store".
	function server.module(path: string)
		local node = serverScript
		for part in string.gmatch(path, "[^%.]+") do
			node = node:FindFirstChild(part)
		end
		return requireInstance(node)
	end

	function server.sharedModule(name: string)
		return requireInstance(shared:FindFirstChild(name))
	end

	function server.start()
		if prepare then
			prepare(server)
		end
		task.spawn(compile(serverScript))
		local remotes = shared:WaitForChild("Remotes", 10)
		assert(remotes, engine.name .. " did not finish starting")
		server.api = remotes:FindFirstChild("Api")
	end

	-- Calls an Api action as `player`, exactly like a client InvokeServer.
	function server.call(player, action: string, ...)
		for i = 1, select("#", ...) do
			Engine.checkRemote((select(i, ...)), "InvokeServer " .. tostring(action) .. " argument " .. i)
		end
		local response = server.api.OnServerInvoke(player, action, ...)
		Engine.checkRemote(response, "response to " .. action)
		return response
	end

	return server
end

return Loader
