-- Audit log (managers): sign-offs on sales, discounts, refunds, price, stock and shift changes.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Format = require(Shared.Format)

local Client = script.Parent.Parent
local Api = require(Client.Api)
local UI = require(Client.UI.UI)
local Theme = require(Client.UI.Theme)
local Toasts = require(Client.UI.Toasts)

local C, F = Theme.Colors, Theme.Fonts

local Audit = {}

local TAGS = {
	sale = { C.Success, C.SuccessSoft },
	refund = { C.Danger, C.DangerSoft },
	discount = { C.Warning, C.WarningSoft },
	["shift.open"] = { C.Accent, C.AccentSoft },
	["shift.close"] = { C.Accent, C.AccentSoft },
}

function Audit.new(_ctx)
	local self = {}
	local frame = UI.new("Frame", { Name = "Audit", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
	self.frame = frame

	UI.text({ Text = "Audit log", TextSize = 24, FontFace = F.Heavy, Size = UDim2.new(0.5, 0, 0, 30), Parent = frame })
	UI.text({
		Text = "The latest 500 actions across every server",
		TextSize = 14,
		TextColor3 = C.Muted,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(0.6, 0, 0, 18),
		Parent = frame,
	})
	local list = UI.scroll({
		Position = UDim2.fromOffset(0, 62),
		Size = UDim2.new(1, 0, 1, -62),
		Parent = frame,
		Children = { UI.list(4) },
	})

	function self.show()
		local ok, entries = Api.call("audit.recent", 200)
		UI.clear(list)
		if not ok then
			Toasts.show(entries, "error")
			return
		end
		if #entries == 0 then
			UI.text({ Text = "Nothing logged yet", TextColor3 = C.Faint, Parent = list })
		end
		for i, entry in entries do
			local colours = TAGS[entry.action] or { C.Muted, C.Panel }
			local tag = UI.pill(entry.action, colours[1], colours[2], { Position = UDim2.new(0.22, 0, 0.5, -12) })
			UI.new("Frame", {
				BackgroundColor3 = C.Raised,
				Size = UDim2.new(1, -8, 0, 42),
				LayoutOrder = i,
				Parent = list,
				Children = {
					UI.corner(Theme.Radius.Small),
					UI.text({
						Text = Format.dateTime(entry.t),
						TextSize = 14,
						FontFace = F.Mono,
						TextColor3 = C.Muted,
						Position = UDim2.fromOffset(12, 0),
						Size = UDim2.fromScale(0.12, 1),
					}),
					UI.text({
						Text = entry.actor,
						TextSize = 14,
						FontFace = F.Bold,
						Position = UDim2.fromScale(0.13, 0),
						Size = UDim2.new(0.09, -8, 1, 0),
					}),
					tag,
					UI.text({
						Text = entry.detail,
						TextSize = 14,
						Position = UDim2.fromScale(0.36, 0),
						Size = UDim2.new(0.64, -12, 1, 0),
					}),
				},
			})
		end
	end

	return self
end

return Audit
