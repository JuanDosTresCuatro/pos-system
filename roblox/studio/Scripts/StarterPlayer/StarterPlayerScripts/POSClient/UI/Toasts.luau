-- Stacked notifications at the top of the screen.

local UI = require(script.Parent.UI)
local Theme = require(script.Parent.Theme)

local C, F = Theme.Colors, Theme.Fonts

local Toasts = {}

local container: Frame
local order = 0

local KINDS = {
	info = { icon = "ℹ", colour = C.Accent },
	success = { icon = "✓", colour = C.Success },
	warning = { icon = "!", colour = C.Warning },
	error = { icon = "✕", colour = C.Danger },
}

function Toasts.mount(gui: ScreenGui)
	container = UI.new("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 72),
		Size = UDim2.new(0, 420, 1, -80),
		BackgroundTransparency = 1,
		ZIndex = 100,
		Parent = gui,
		Children = { UI.list(8, nil, { HorizontalAlignment = Enum.HorizontalAlignment.Center }) },
	})
end

function Toasts.show(text: string, kind: string?)
	if not container then
		return
	end
	local style = KINDS[kind or "info"] or KINDS.info
	order -= 1
	local scale = UI.new("UIScale", { Scale = 0.85 })
	local toast = UI.new("CanvasGroup", {
		Name = "Toast",
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(),
		BackgroundColor3 = C.Raised,
		GroupTransparency = 1,
		ZIndex = 100,
		LayoutOrder = order, -- newest on top
		Parent = container,
		Children = {
			UI.corner(Theme.Radius.Medium),
			UI.stroke(style.colour, 1, 0.4),
			UI.padding(10, 16, 10, 12),
			UI.list(10, Enum.FillDirection.Horizontal, { VerticalAlignment = Enum.VerticalAlignment.Center }),
			UI.new("UISizeConstraint", { MaxSize = Vector2.new(420, math.huge) }),
			scale,
			UI.new("TextLabel", {
				Text = style.icon,
				FontFace = F.Heavy,
				TextSize = 14,
				TextColor3 = C.Bg,
				BackgroundColor3 = style.colour,
				Size = UDim2.fromOffset(22, 22),
				Children = { UI.corner(Theme.Radius.Pill) },
			}),
			UI.text({
				Text = text,
				TextSize = 15,
				FontFace = F.Medium,
				AutomaticSize = Enum.AutomaticSize.XY,
				Size = UDim2.new(),
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
				Children = { UI.new("UISizeConstraint", { MaxSize = Vector2.new(340, math.huge) }) },
			}),
		},
	})
	UI.tween(toast, { GroupTransparency = 0 })
	UI.tween(scale, { Scale = 1 }, Theme.TweenSlow)
	task.delay(3.6, function()
		UI.tween(toast, { GroupTransparency = 1 })
		task.wait(0.2)
		toast:Destroy()
	end)
end

return Toasts
