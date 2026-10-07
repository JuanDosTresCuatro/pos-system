-- Design tokens. Change these to restyle the whole POS.

local Theme = {}

local rgb = Color3.fromRGB

Theme.Colors = {
	Backdrop = rgb(5, 6, 9),
	Bg = rgb(13, 15, 20),
	Panel = rgb(20, 23, 31),
	Raised = rgb(28, 32, 43),
	RaisedHover = rgb(36, 41, 55),
	Border = rgb(44, 50, 66),
	Text = rgb(236, 239, 245),
	Muted = rgb(146, 153, 170),
	Faint = rgb(98, 105, 124),
	Accent = rgb(92, 132, 255),
	AccentHover = rgb(118, 152, 255),
	AccentSoft = rgb(34, 44, 78),
	Success = rgb(46, 204, 113),
	SuccessHover = rgb(76, 220, 138),
	SuccessSoft = rgb(22, 58, 41),
	Warning = rgb(242, 173, 61),
	WarningSoft = rgb(66, 50, 22),
	Danger = rgb(235, 87, 87),
	DangerHover = rgb(245, 115, 115),
	DangerSoft = rgb(70, 28, 32),
	Paper = rgb(250, 248, 242),
	Ink = rgb(28, 28, 32),
}

local family = "rbxasset://fonts/families/BuilderSans.json"
local mono = "rbxasset://fonts/families/RobotoMono.json"

Theme.Fonts = {
	Regular = Font.new(family, Enum.FontWeight.Regular),
	Medium = Font.new(family, Enum.FontWeight.Medium),
	Bold = Font.new(family, Enum.FontWeight.Bold),
	Heavy = Font.new(family, Enum.FontWeight.ExtraBold),
	Mono = Font.new(mono, Enum.FontWeight.Regular),
	MonoBold = Font.new(mono, Enum.FontWeight.Bold),
}

Theme.Radius = {
	Small = UDim.new(0, 8),
	Medium = UDim.new(0, 12),
	Large = UDim.new(0, 16),
	Pill = UDim.new(1, 0),
}

Theme.Tween = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
Theme.TweenSlow = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

return Theme
