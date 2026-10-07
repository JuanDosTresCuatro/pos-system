-- A small declarative UI kit.
--
--   UI.new("Frame", { Size = ..., Children = { UI.corner(12), UI.text({ Text = "Hi" }) } })
--
-- Function values connect to the event of the same name (Activated = function() ... end).

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local C, F = Theme.Colors, Theme.Fonts

local UI = {}

function UI.new(className: string, props: { [any]: any }?): any
	local instance = Instance.new(className)
	local children, parent
	for key, value in (props or {}) :: { [any]: any } do
		if key == "Children" then
			children = value
		elseif key == "Parent" then
			parent = value
		elseif typeof(value) == "function" then
			(instance :: any)[key]:Connect(value)
		else
			(instance :: any)[key] = value
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function UI.tween(instance: Instance, props: { [string]: any }, info: TweenInfo?)
	local tween = TweenService:Create(instance, info or Theme.Tween, props)
	tween:Play()
	return tween
end

function UI.corner(radius: UDim | number?): UICorner
	local value = if typeof(radius) == "number" then UDim.new(0, radius) else (radius or Theme.Radius.Medium)
	return UI.new("UICorner", { CornerRadius = value })
end

function UI.stroke(colour: Color3?, thickness: number?, transparency: number?): UIStroke
	return UI.new("UIStroke", {
		Color = colour or C.Border,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function UI.padding(top: number, right: number?, bottom: number?, left: number?): UIPadding
	return UI.new("UIPadding", {
		PaddingTop = UDim.new(0, top),
		PaddingRight = UDim.new(0, right or top),
		PaddingBottom = UDim.new(0, bottom or top),
		PaddingLeft = UDim.new(0, left or right or top),
	})
end

function UI.list(gap: number?, direction: Enum.FillDirection?, props: { [string]: any }?): UIListLayout
	local layout = UI.new("UIListLayout", {
		Padding = UDim.new(0, gap or 8),
		FillDirection = direction or Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	for key, value in (props or {}) :: { [any]: any } do
		(layout :: any)[key] = value
	end
	return layout
end

function UI.text(props: { [string]: any }): TextLabel
	local defaults = {
		BackgroundTransparency = 1,
		FontFace = F.Medium,
		TextColor3 = C.Text,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, 20),
	}
	for key, value in props do
		defaults[key] = value
	end
	return UI.new("TextLabel", defaults)
end

local STYLES = {
	primary = { bg = C.Accent, hover = C.AccentHover, text = Color3.new(1, 1, 1) },
	success = { bg = C.Success, hover = C.SuccessHover, text = Color3.fromRGB(8, 30, 18) },
	danger = { bg = C.Danger, hover = C.DangerHover, text = Color3.new(1, 1, 1) },
	secondary = { bg = C.Raised, hover = C.RaisedHover, text = C.Text, stroke = true },
	ghost = { bg = C.Panel, hover = C.Raised, text = C.Muted },
}

-- props: Text, Style, Size, Position, AnchorPoint, TextSize, LayoutOrder, Name, OnClick, Font
function UI.button(props: { [string]: any }): TextButton
	local style = STYLES[props.Style or "secondary"]
	local scale = UI.new("UIScale")
	local button = UI.new("TextButton", {
		Name = props.Name or "Button",
		Text = props.Text or "",
		FontFace = props.Font or F.Bold,
		TextSize = props.TextSize or 16,
		TextColor3 = style.text,
		BackgroundColor3 = style.bg,
		AutoButtonColor = false,
		Size = props.Size or UDim2.fromOffset(120, 40),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		ZIndex = props.ZIndex or 1,
		Children = {
			UI.corner(props.Radius or Theme.Radius.Small),
			scale,
			if style.stroke then UI.stroke() else nil,
		},
	})
	button:SetAttribute("Style", props.Style or "secondary")

	button.MouseEnter:Connect(function()
		if not button:GetAttribute("Disabled") then
			UI.tween(button, { BackgroundColor3 = style.hover })
		end
	end)
	button.MouseLeave:Connect(function()
		if not button:GetAttribute("Disabled") then
			UI.tween(button, { BackgroundColor3 = style.bg })
		end
		UI.tween(scale, { Scale = 1 })
	end)
	button.MouseButton1Down:Connect(function()
		if not button:GetAttribute("Disabled") then
			UI.tween(scale, { Scale = 0.96 }, TweenInfo.new(0.08))
		end
	end)
	button.MouseButton1Up:Connect(function()
		UI.tween(scale, { Scale = 1 })
	end)
	if props.OnClick then
		button.Activated:Connect(function()
			if not button:GetAttribute("Disabled") then
				props.OnClick(button)
			end
		end)
	end
	if props.Parent then
		button.Parent = props.Parent
	end
	return button
end

function UI.setEnabled(button: TextButton, enabled: boolean)
	local style = STYLES[button:GetAttribute("Style") or "secondary"]
	button:SetAttribute("Disabled", not enabled)
	button.BackgroundColor3 = if enabled then style.bg else C.Raised
	button.TextColor3 = if enabled then style.text else C.Faint
end

function UI.input(props: { [string]: any }): TextBox
	local box = UI.new("TextBox", {
		Name = props.Name or "Input",
		Text = props.Text or "",
		PlaceholderText = props.Placeholder or "",
		PlaceholderColor3 = C.Faint,
		ClearTextOnFocus = false,
		FontFace = props.Font or F.Medium,
		TextSize = props.TextSize or 16,
		TextColor3 = C.Text,
		TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left,
		BackgroundColor3 = C.Raised,
		Size = props.Size or UDim2.new(1, 0, 0, 40),
		Position = props.Position or UDim2.new(),
		LayoutOrder = props.LayoutOrder or 0,
		Children = { UI.corner(Theme.Radius.Small), UI.padding(0, 12) },
	})
	local stroke = UI.stroke()
	stroke.Parent = box
	box.Focused:Connect(function()
		UI.tween(stroke, { Color = C.Accent })
	end)
	box.FocusLost:Connect(function()
		UI.tween(stroke, { Color = C.Border })
	end)
	return box
end

function UI.pill(text: string, fg: Color3, bg: Color3, props: { [string]: any }?): Frame
	local pill = UI.new("Frame", {
		Name = "Pill",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		BackgroundColor3 = bg,
		Children = {
			UI.corner(Theme.Radius.Pill),
			UI.padding(0, 10),
			UI.text({
				Name = "Label",
				Text = text,
				TextSize = 13,
				FontFace = F.Bold,
				TextColor3 = fg,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromScale(0, 1),
				TextTruncate = Enum.TextTruncate.None,
			}),
		},
	})
	for key, value in (props or {}) :: { [any]: any } do
		(pill :: any)[key] = value
	end
	return pill
end

function UI.scroll(props: { [string]: any }): ScrollingFrame
	local defaults = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Border,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Size = UDim2.fromScale(1, 1),
	}
	for key, value in props do
		defaults[key] = value
	end
	return UI.new("ScrollingFrame", defaults)
end

-- Destroys the visible children of a container but keeps its layout objects.
function UI.clear(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function UI.card(props: { [string]: any }): Frame
	local defaults = {
		BackgroundColor3 = C.Raised,
		Size = UDim2.new(1, 0, 0, 80),
	}
	for key, value in props do
		if key ~= "Children" then
			defaults[key] = value
		end
	end
	local children = { UI.corner(Theme.Radius.Medium), UI.stroke() }
	for _, child in props.Children or {} do
		table.insert(children, child)
	end
	defaults.Children = children
	return UI.new("Frame", defaults)
end

-- A stat tile: small label above a big value.
function UI.stat(label: string, value: string, accent: Color3?, layoutOrder: number?): Frame
	return UI.card({
		Name = label,
		LayoutOrder = layoutOrder or 0,
		Size = UDim2.fromOffset(0, 86),
		Children = {
			UI.padding(14, 16),
			UI.text({ Text = label, TextSize = 14, TextColor3 = C.Muted, FontFace = F.Medium }),
			UI.text({
				Name = "Value",
				Text = value,
				TextSize = 28,
				FontFace = F.Heavy,
				TextColor3 = accent or C.Text,
				Position = UDim2.fromOffset(0, 24),
				Size = UDim2.new(1, 0, 0, 34),
			}),
		},
	})
end

-- Centred dialog on a dim backdrop. Returns the dialog body and a close function.
function UI.modal(parent: Instance, props: { [string]: any })
	local scale = UI.new("UIScale", { Scale = 0.92 })
	local backdrop = UI.new("TextButton", {
		Name = "Modal",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		Parent = parent,
	})
	-- A button, so clicks inside the dialog never fall through to the backdrop.
	local dialog = UI.new("TextButton", {
		Name = "Dialog",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(props.Width or 420, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = props.Background or C.Panel,
		ZIndex = 51,
		Parent = backdrop,
		Children = {
			UI.corner(Theme.Radius.Large),
			UI.stroke(),
			UI.padding(props.Padding or 20),
			UI.list(12),
			UI.new("UISizeConstraint", { MaxSize = Vector2.new(math.huge, props.MaxHeight or 640) }),
			scale,
		},
	})
	if props.Title then
		UI.text({
			Name = "Title",
			Text = props.Title,
			TextSize = 22,
			FontFace = F.Heavy,
			Size = UDim2.new(1, 0, 0, 28),
			LayoutOrder = -100,
			ZIndex = 52,
			Parent = dialog,
		})
	end

	UI.tween(backdrop, { BackgroundTransparency = 0.35 })
	UI.tween(scale, { Scale = 1 }, Theme.TweenSlow)

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		UI.tween(backdrop, { BackgroundTransparency = 1 })
		UI.tween(scale, { Scale = 0.92 })
		task.delay(0.15, function()
			backdrop:Destroy()
		end)
		if props.OnClose then
			props.OnClose()
		end
	end
	if props.Dismissable ~= false then
		backdrop.Activated:Connect(close)
	end
	return dialog, close
end

return UI
