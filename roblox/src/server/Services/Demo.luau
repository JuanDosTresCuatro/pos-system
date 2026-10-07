-- Builds a café counter with a register when the place has none, and simple item Tools for
-- products that have no Tool in ServerStorage.POSItems. Turn both off in Config.Demo.

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)

local Demo = {}

local function part(parent: Instance, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function groundY(x: number, z: number): number
	local result = workspace:Raycast(Vector3.new(x, 500, z), Vector3.new(0, -1000, 0))
	return if result then result.Position.Y else 0
end

local function sign(parent: Instance, text: string, cframe: CFrame)
	local board = part(parent, {
		Name = "Sign",
		Size = Vector3.new(8, 1.6, 0.3),
		CFrame = cframe,
		Color = Color3.fromRGB(22, 25, 33),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.LightInfluence = 0
	gui.Brightness = 2
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextScaled = true
	textLabel.TextColor3 = Color3.fromRGB(255, 214, 153)
	textLabel.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.18, 0)
	padding.PaddingBottom = UDim.new(0.18, 0)
	padding.Parent = textLabel
	textLabel.Parent = gui
	gui.Parent = board
end

function Demo.buildCounter()
	local origin = Vector3.new(0, 0, -26)
	local y = groundY(origin.X, origin.Z)
	-- Customers stand on the +Z side, staff behind the counter on the -Z side.
	local base = CFrame.new(origin.X, y, origin.Z)

	local model = Instance.new("Model")
	model.Name = "RoPOS Counter"

	part(model, {
		Name = "Counter",
		Size = Vector3.new(16, 3.6, 3),
		CFrame = base * CFrame.new(0, 1.8, 0),
		Color = Color3.fromRGB(110, 76, 52),
		Material = Enum.Material.WoodPlanks,
	})
	part(model, {
		Name = "Top",
		Size = Vector3.new(16.6, 0.3, 3.6),
		CFrame = base * CFrame.new(0, 3.75, 0),
		Color = Color3.fromRGB(235, 232, 226),
		Material = Enum.Material.Marble,
	})
	local till = part(model, {
		Name = "Till",
		Size = Vector3.new(2.4, 0.7, 1.8),
		CFrame = base * CFrame.new(-3, 4.25, -0.2),
		Color = Color3.fromRGB(30, 34, 45),
		Material = Enum.Material.SmoothPlastic,
	})
	part(model, {
		Name = "Stand",
		Size = Vector3.new(0.3, 1.1, 0.3),
		CFrame = base * CFrame.new(-3, 5.15, -0.3),
		Color = Color3.fromRGB(45, 50, 64),
		Material = Enum.Material.Metal,
	})
	-- Tilted towards the customer. A part's front face points along its LookVector.
	local screenPos = (base * CFrame.new(-3, 6.2, -0.15)).Position
	part(model, {
		Name = "Screen",
		Size = Vector3.new(2.6, 1.6, 0.15),
		CFrame = CFrame.lookAt(screenPos, screenPos + Vector3.new(0, 0.25, 1)),
		Color = Color3.fromRGB(10, 10, 12),
		Material = Enum.Material.Glass,
	})
	part(model, {
		Name = "CardReader",
		Size = Vector3.new(0.6, 0.15, 0.9),
		CFrame = base * CFrame.new(-1.2, 3.98, 0.9) * CFrame.Angles(math.rad(-15), 0, 0),
		Color = Color3.fromRGB(45, 50, 64),
		Material = Enum.Material.SmoothPlastic,
	})
	part(model, {
		Name = "TipJar",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.1, 0.8, 0.8),
		CFrame = base * CFrame.new(1.5, 4.45, 0.8) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(200, 230, 255),
		Material = Enum.Material.Glass,
		Transparency = 0.4,
	})

	-- A menu board above the counter, readable from the customer side.
	sign(model, "ORDER HERE  ☕", base * CFrame.new(0, 9.5, 0) * CFrame.Angles(0, math.pi, 0))
	part(model, {
		Name = "SignPost",
		Size = Vector3.new(0.3, 5.5, 0.3),
		CFrame = base * CFrame.new(-7.5, 6.5, 0),
		Color = Color3.fromRGB(45, 50, 64),
		Material = Enum.Material.Metal,
	})
	part(model, {
		Name = "SignPost",
		Size = Vector3.new(0.3, 5.5, 0.3),
		CFrame = base * CFrame.new(7.5, 6.5, 0),
		Color = Color3.fromRGB(45, 50, 64),
		Material = Enum.Material.Metal,
	})

	model.PrimaryPart = till
	model:SetAttribute("RegisterId", "R1")
	model:SetAttribute("RegisterName", "Front Counter")
	model.Parent = workspace
	CollectionService:AddTag(model, Config.RegisterTag)
end

local function buildTool(name: string, colour: Color3): Tool
	local tool = Instance.new("Tool")
	tool.Name = name
	tool.ToolTip = name
	tool.CanBeDropped = false
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.8, 1.1, 0.8)
	handle.Color = colour
	handle.Material = Enum.Material.SmoothPlastic
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Massless = true
	handle.Parent = tool
	return tool
end

function Demo.ensureItems()
	local folder = ServerStorage:FindFirstChild("POSItems")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "POSItems"
		folder.Parent = ServerStorage
	end
	for _, product in Config.Products do
		if product.Tool and not folder:FindFirstChild(product.Tool) then
			buildTool(product.Tool, product.Colour or Color3.new(1, 1, 1)).Parent = folder
		end
	end
end

function Demo.setup()
	if Config.Demo.SpawnRegister and #CollectionService:GetTagged(Config.RegisterTag) == 0 then
		Demo.buildCounter()
	end
	if Config.Demo.CreateItemTools then
		Demo.ensureItems()
	end
end

return Demo
