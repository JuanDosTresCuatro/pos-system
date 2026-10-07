-- The staff window: header, tabs and screens. Opens when a cashier uses a register.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Roles = require(Shared.Roles)

local Api = require(script.Parent.Api)
local State = require(script.Parent.State)
local UI = require(script.Parent.UI.UI)
local Theme = require(script.Parent.UI.Theme)
local Toasts = require(script.Parent.UI.Toasts)

local Screens = script.Parent.Screens

local C, F = Theme.Colors, Theme.Fonts

local App = {}

type Screen = { frame: GuiObject, show: (() -> ())? }

local TABS = {
	{ id = "sell", label = "Sell", icon = "🛒", role = Roles.Cashier, module = "Sell" },
	{ id = "sales", label = "Sales", icon = "🧾", role = Roles.Cashier, module = "Sales" },
	{ id = "shift", label = "Shift", icon = "⏱", role = Roles.Cashier, module = "Shift" },
	{ id = "products", label = "Products", icon = "📦", role = Roles.Manager, module = "Products" },
	{ id = "reports", label = "Reports", icon = "📊", role = Roles.Manager, module = "Reports" },
	{ id = "audit", label = "Audit log", icon = "📜", role = Roles.Manager, module = "Audit" },
}

local gui: ScreenGui
local overlay: Frame -- modals and toasts go here so they scale with the window
local window: CanvasGroup
local windowScale: UIScale
local content: Frame
local tabBar: Frame
local shiftPill: Frame
local registerLabel: TextLabel
local screens: { [string]: Screen } = {}
local tabButtons: { [string]: TextButton } = {}
local active: string? = nil
local isOpen = false

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

function App.go(id: string)
	if not screens[id] then
		return
	end
	active = id
	for tabId, screen in screens do
		screen.frame.Visible = tabId == id
	end
	for tabId, button in tabButtons do
		local selected = tabId == id
		UI.tween(button, {
			BackgroundColor3 = if selected then C.AccentSoft else C.Panel,
			TextColor3 = if selected then C.Text else C.Muted,
		})
	end
	local screen = screens[id]
	if screen.show then
		task.spawn(screen.show)
	end
end

local function updateHeader()
	local register = State.register
	registerLabel.Text = if register then register.name else ""
	local label = shiftPill:FindFirstChild("Label") :: TextLabel
	if register and register.shift then
		label.Text = "● Shift open · " .. money(register.shift.net)
		label.TextColor3 = C.Success
		shiftPill.BackgroundColor3 = C.SuccessSoft
	else
		label.Text = "○ Shift closed"
		label.TextColor3 = C.Warning
		shiftPill.BackgroundColor3 = C.WarningSoft
	end
end

local function buildTabs()
	UI.clear(tabBar)
	table.clear(tabButtons)
	for _, screen in screens do
		screen.frame:Destroy()
	end
	table.clear(screens)

	local ctx = { overlay = overlay, go = App.go }
	for i, tab in TABS do
		if State.role >= tab.role then
			local screen = require(Screens:FindFirstChild(tab.module)).new(ctx)
			screen.frame.Visible = false
			screen.frame.Parent = content
			screens[tab.id] = screen
			tabButtons[tab.id] = UI.button({
				Text = tab.icon .. "  " .. tab.label,
				Style = "ghost",
				TextSize = 15,
				Size = UDim2.fromScale(0, 1),
				LayoutOrder = i,
				Parent = tabBar,
			})
			local button = tabButtons[tab.id]
			button.AutomaticSize = Enum.AutomaticSize.X
			UI.padding(0, 14).Parent = button
			button.Activated:Connect(function()
				App.go(tab.id)
			end)
		end
	end
end

function App.open()
	if isOpen then
		App.go(active or "sell")
		return
	end
	isOpen = true
	window.Visible = true
	window.GroupTransparency = 1
	windowScale.Scale = 0.94
	UI.tween(window, { GroupTransparency = 0 }, Theme.TweenSlow)
	UI.tween(windowScale, { Scale = 1 }, Theme.TweenSlow)
	App.go(active or "sell")
end

function App.close()
	if not isOpen then
		return
	end
	isOpen = false
	UI.tween(window, { GroupTransparency = 1 })
	UI.tween(windowScale, { Scale = 0.96 })
	task.delay(0.2, function()
		if not isOpen then
			window.Visible = false
		end
	end)
	for _, child in overlay:GetChildren() do
		if child.Name == "Modal" then
			child:Destroy()
		end
	end
end

function App.isOpen(): boolean
	return isOpen
end

function App.overlay(): Frame
	return overlay
end

local function header(): Frame
	local player = Players.LocalPlayer
	shiftPill = UI.pill("", C.Warning, C.WarningSoft, { LayoutOrder = 1 })
	registerLabel = UI.text({
		Text = "",
		TextSize = 14,
		TextColor3 = C.Muted,
		Position = UDim2.fromOffset(52, 28),
		Size = UDim2.new(1, -52, 0, 18),
	})

	local right = UI.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromScale(0.6, 1),
		Children = {
			UI.list(10, Enum.FillDirection.Horizontal, {
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			}),
			if not State.persistent
				then UI.pill("Studio: data not saved", C.Warning, C.WarningSoft, { LayoutOrder = 0 })
				else nil,
			shiftPill,
			UI.pill(player.DisplayName .. " · " .. State.roleName, C.Text, C.Raised, { LayoutOrder = 2 }),
			UI.button({
				Name = "Close",
				Text = "✕",
				Style = "ghost",
				TextSize = 18,
				Size = UDim2.fromOffset(40, 40),
				LayoutOrder = 3,
				OnClick = function()
					Api.call("register.leave")
					App.close()
				end,
			}),
		},
	})

	return UI.new("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 48),
		Children = {
			UI.new("TextLabel", {
				Text = string.sub(Config.Store.Name, 1, 1),
				FontFace = F.Heavy,
				TextSize = 22,
				TextColor3 = Color3.new(1, 1, 1),
				BackgroundColor3 = C.Accent,
				Size = UDim2.fromOffset(42, 42),
				Position = UDim2.fromOffset(0, 3),
				Children = {
					UI.corner(Theme.Radius.Medium),
					UI.new("UIGradient", {
						Color = ColorSequence.new(C.AccentHover, Color3.fromRGB(150, 92, 255)),
						Rotation = 45,
					}),
				},
			}),
			UI.text({
				Text = Config.Store.Name,
				TextSize = 20,
				FontFace = F.Heavy,
				Position = UDim2.fromOffset(52, 4),
				Size = UDim2.new(0.4, 0, 0, 24),
			}),
			registerLabel,
			right,
		},
	})
end

-- Lays the window out in "virtual pixels" so it fits any screen, from phones to 4K.
local function fitToScreen(root: Frame, scale: UIScale)
	local camera = workspace.CurrentCamera
	local function update()
		local viewport = camera.ViewportSize
		local s = math.clamp(math.min(viewport.X / 1060, viewport.Y / 640), 0.5, 1.25)
		scale.Scale = s
		root.Size = UDim2.fromOffset(viewport.X / s, viewport.Y / s)
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
	update()
end

function App.mount()
	gui = UI.new("ScreenGui", {
		Name = "RoPOS",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 10,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	local rootScale = UI.new("UIScale")
	local root = UI.new("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = gui,
		Children = { rootScale },
	})
	fitToScreen(root, rootScale)

	windowScale = UI.new("UIScale")
	window = UI.new("CanvasGroup", {
		Name = "Window",
		Visible = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -40, 1, -40),
		BackgroundColor3 = C.Bg,
		Parent = root,
		Children = {
			UI.corner(Theme.Radius.Large),
			UI.stroke(C.Border),
			UI.new("UISizeConstraint", { MaxSize = Vector2.new(1280, 780) }),
			windowScale,
			UI.padding(16, 20),
		},
	})
	header().Parent = window

	tabBar = UI.new("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 0, 38),
		Parent = window,
		Children = { UI.list(6, Enum.FillDirection.Horizontal) },
	})
	UI.new("Frame", {
		Name = "Divider",
		BackgroundColor3 = C.Border,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 106),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = window,
	})
	content = UI.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(0, 120),
		Size = UDim2.new(1, 0, 1, -120),
		Parent = window,
	})

	overlay = UI.new("Frame", {
		Name = "Overlay",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 20,
		Parent = root,
	})
	Toasts.mount(overlay :: any)

	buildTabs()
	updateHeader()

	State.changed:Connect(function(key)
		if key == "register" then
			updateHeader()
		elseif key == "role" then
			buildTabs()
			if isOpen then
				App.go("sell")
			end
		end
	end)

	-- Escape closes the window on keyboards.
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and isOpen and input.KeyCode == Enum.KeyCode.Escape then
			Api.call("register.leave")
			App.close()
		end
	end)
end

return App
