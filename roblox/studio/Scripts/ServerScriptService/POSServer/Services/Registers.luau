-- Physical registers. Tag any Model or BasePart with "POSRegister" (CollectionService) and it
-- becomes a working till with a ProximityPrompt and a customer-facing screen.
--
-- Optional attributes on the tagged instance:
--   RegisterId   (string) stable id, generated if missing
--   RegisterName (string) shown to staff and customers
-- Optional child: a BasePart named "Screen" for the customer display (front face).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Signal = require(Shared.Signal)
local Api = require(script.Parent.Api)
local Staff = require(script.Parent.Staff)
local Shifts = require(script.Parent.Shifts)

local Registers = {}
Registers.released = Signal.new() -- (register, reason)

export type Display = {
	status: TextLabel,
	detail: TextLabel,
	total: TextLabel,
	accent: Frame,
}

export type Register = {
	id: string,
	name: string,
	instance: Instance,
	anchor: BasePart,
	prompt: ProximityPrompt,
	display: Display?,
	operator: Player?,
	shift: Shifts.Shift?,
	order: any?, -- the pending Checkout order, if any
	preview: { items: number, total: number }?,
	flashUntil: number,
}

local registers: { [string]: Register } = {}
local byInstance: { [Instance]: Register } = {}
local byOperator: { [Player]: Register } = {}
local count = 0

local COLOURS = {
	idle = Color3.fromRGB(88, 130, 255),
	busy = Color3.fromRGB(242, 173, 61),
	paid = Color3.fromRGB(46, 204, 113),
	closed = Color3.fromRGB(110, 116, 135),
}

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.TextColor3 = Color3.fromRGB(236, 239, 245)
	text.TextScaled = true
	text.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
	for key, value in props do
		(text :: any)[key] = value
	end
	text.Parent = parent
	return text
end

local function buildDisplay(register: Register): Display?
	local screen = register.instance:FindFirstChild("Screen", true)
	local part = if screen and screen:IsA("BasePart") then screen else nil
	local gui: LayerCollector
	if part then
		local surface = Instance.new("SurfaceGui")
		surface.Face = Enum.NormalId.Front
		surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		surface.PixelsPerStud = 120
		surface.LightInfluence = 0
		surface.Brightness = 1.6
		surface.Adornee = part
		gui = surface
	else
		local board = Instance.new("BillboardGui")
		board.Size = UDim2.fromScale(5, 2.6)
		board.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
		board.MaxDistance = 60
		board.Adornee = register.anchor
		gui = board
	end
	gui.Name = "RoPOSDisplay"

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Color3.fromRGB(13, 15, 20)
	root.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.06, 0)
	corner.Parent = root

	local accent = Instance.new("Frame")
	accent.Size = UDim2.fromScale(1, 0.05)
	accent.BorderSizePixel = 0
	accent.BackgroundColor3 = COLOURS.closed
	accent.Parent = root

	label(root, {
		Name = "Store",
		Size = UDim2.fromScale(0.9, 0.13),
		Position = UDim2.fromScale(0.05, 0.1),
		Text = string.upper(Config.Store.Name),
		TextColor3 = Color3.fromRGB(146, 153, 170),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local status = label(root, {
		Name = "Status",
		Size = UDim2.fromScale(0.9, 0.24),
		Position = UDim2.fromScale(0.05, 0.27),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local detail = label(root, {
		Name = "Detail",
		Size = UDim2.fromScale(0.9, 0.13),
		Position = UDim2.fromScale(0.05, 0.53),
		TextColor3 = Color3.fromRGB(146, 153, 170),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
	})
	local total = label(root, {
		Name = "Total",
		Size = UDim2.fromScale(0.9, 0.24),
		Position = UDim2.fromScale(0.05, 0.7),
		TextXAlignment = Enum.TextXAlignment.Right,
		FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold),
	})

	gui.Parent = part or register.anchor
	return { status = status, detail = detail, total = total, accent = accent }
end

function Registers.updateDisplay(register: Register)
	local display = register.display
	local operator = register.operator
	register.prompt.ObjectText = if operator then register.name .. " · " .. operator.DisplayName else register.name
	if not display then
		return
	end

	local status, detail, total, colour
	if os.clock() < register.flashUntil then
		status, detail, total, colour = "Thank you!", "Payment approved", "✓", COLOURS.paid
	elseif register.order then
		status = "Please approve"
		detail = "Waiting for " .. register.order.customer.DisplayName
		total, colour = money(register.order.totals.total), COLOURS.busy
	elseif operator and register.preview and register.preview.items > 0 then
		status = string.format("%d item%s", register.preview.items, if register.preview.items == 1 then "" else "s")
		detail = "Served by " .. operator.DisplayName
		total, colour = money(register.preview.total), COLOURS.idle
	elseif operator and register.shift then
		status, detail, total, colour = "Welcome!", operator.DisplayName .. " can take your order", "", COLOURS.idle
	elseif register.shift then
		status, detail, total, colour = "Back soon", "Waiting for a cashier", "", COLOURS.closed
	else
		status, detail, total, colour = "Closed", register.name, "", COLOURS.closed
	end

	display.status.Text = status
	display.detail.Text = detail
	display.total.Text = total
	TweenService:Create(display.accent, TweenInfo.new(0.35), { BackgroundColor3 = colour }):Play()
end

function Registers.flashPaid(register: Register)
	register.flashUntil = os.clock() + 4
	register.preview = nil
	Registers.updateDisplay(register)
	task.delay(4.1, Registers.updateDisplay, register)
end

function Registers.summary(register: Register)
	return {
		id = register.id,
		name = register.name,
		shift = if register.shift then Shifts.report(register.shift) else nil,
	}
end

function Registers.distance(register: Register, player: Player): number
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return math.huge
	end
	return (root.Position - register.anchor.Position).Magnitude
end

function Registers.of(player: Player): Register?
	return byOperator[player]
end

function Registers.get(id: string): Register?
	return registers[id]
end

function Registers.release(register: Register, reason: string?)
	local operator = register.operator
	if not operator then
		return
	end
	Registers.released:Fire(register, reason or "The register was closed")
	register.operator = nil
	register.preview = nil
	byOperator[operator] = nil
	Api.push(operator, "CloseRegister", { id = register.id, reason = reason })
	Registers.updateDisplay(register)
end

function Registers.claim(register: Register, player: Player)
	if not Staff.isStaff(player) then
		Api.toast(player, "Only staff can use the register", "warning")
		return
	end
	if register.operator and register.operator ~= player then
		Api.toast(player, register.name .. " is being used by " .. register.operator.DisplayName, "warning")
		return
	end
	local current = byOperator[player]
	if current and current ~= register then
		Registers.release(current, "You moved to " .. register.name)
	end
	register.operator = player
	byOperator[player] = register
	Api.push(player, "OpenRegister", Registers.summary(register))
	Registers.updateDisplay(register)
end

-- Pushes fresh register details (shift totals) to the operator.
function Registers.refreshOperator(register: Register)
	if register.operator then
		Api.push(register.operator, "Register", Registers.summary(register))
	end
end

local function findAnchor(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	elseif instance:IsA("Model") and instance.PrimaryPart then
		return instance.PrimaryPart
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function add(instance: Instance)
	if byInstance[instance] then
		return
	end
	local anchor = findAnchor(instance)
	if not anchor then
		warn("[RoPOS] " .. instance:GetFullName() .. " is tagged " .. Config.RegisterTag .. " but has no parts")
		return
	end

	count += 1
	local id = instance:GetAttribute("RegisterId")
	if typeof(id) ~= "string" or id == "" or registers[id] then
		id = "R" .. count
		instance:SetAttribute("RegisterId", id)
	end
	local name = instance:GetAttribute("RegisterName")
	if typeof(name) ~= "string" or name == "" then
		name = "Register " .. count
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RoPOSPrompt"
	prompt.ActionText = "Use register"
	prompt.ObjectText = name
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	local register: Register = {
		id = id,
		name = name,
		instance = instance,
		anchor = anchor,
		prompt = prompt,
		display = nil,
		operator = nil,
		shift = nil,
		order = nil,
		preview = nil,
		flashUntil = 0,
	}
	register.display = buildDisplay(register)
	registers[id] = register
	byInstance[instance] = register

	prompt.Triggered:Connect(function(player)
		Registers.claim(register, player)
	end)
	Registers.updateDisplay(register)
end

local function remove(instance: Instance)
	local register = byInstance[instance]
	if not register then
		return
	end
	Registers.release(register, "The register was removed")
	register.prompt:Destroy()
	byInstance[instance] = nil
	registers[register.id] = nil
end

function Registers.all(): { Register }
	local out = {}
	for _, register in registers do
		table.insert(out, register)
	end
	return out
end

function Registers.init()
	for _, instance in CollectionService:GetTagged(Config.RegisterTag) do
		add(instance)
	end
	CollectionService:GetInstanceAddedSignal(Config.RegisterTag):Connect(add)
	CollectionService:GetInstanceRemovedSignal(Config.RegisterTag):Connect(remove)

	Players.PlayerRemoving:Connect(function(player)
		local register = byOperator[player]
		if register then
			Registers.release(register, "The cashier left")
		end
	end)

	-- Sign the cashier out when they walk away.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, register in registers do
				local operator = register.operator
				if operator and Registers.distance(register, operator) > Config.Checkout.OperatorRange then
					Registers.release(register, "You walked away from " .. register.name)
				end
			end
		end
	end)
end

return Registers
