-- Reports (managers): 7-day takings chart, totals, best sellers and cashier leaderboard.
-- Days are UTC so every server agrees on where a sale belongs.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Aggregate = require(Shared.Aggregate)
local Config = require(Shared.Config)
local Format = require(Shared.Format)

local Client = script.Parent.Parent
local Api = require(Client.Api)
local UI = require(Client.UI.UI)
local Theme = require(Client.UI.Theme)
local Toasts = require(Client.UI.Toasts)

local C, F = Theme.Colors, Theme.Fonts

local Reports = {}

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

local function rankList(
	parent: Instance,
	title: string,
	rows: { { label: string, value: number, sub: string } },
	colour: Color3,
	order: number
)
	local card = UI.card({
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(0.5, -6, 0, 0),
		LayoutOrder = order,
		Parent = parent,
		Children = { UI.padding(16), UI.list(8) },
	})
	UI.text({ Text = title, FontFace = F.Bold, Parent = card })
	if #rows == 0 then
		UI.text({ Text = "No sales in this period", TextColor3 = C.Faint, LayoutOrder = 1, Parent = card })
	end
	local best = if rows[1] then math.max(rows[1].value, 1) else 1
	for i, row in rows do
		local bar = UI.new(
			"Frame",
			{ BackgroundColor3 = colour, Size = UDim2.fromScale(0, 1), Children = { UI.corner(Theme.Radius.Pill) } }
		)
		UI.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 40),
			LayoutOrder = i,
			Parent = card,
			Children = {
				UI.text({ Text = row.label, TextSize = 15, Size = UDim2.new(0.6, 0, 0, 20) }),
				UI.text({
					Text = row.sub,
					TextSize = 12,
					TextColor3 = C.Muted,
					Position = UDim2.fromScale(0.6, 0),
					Size = UDim2.new(0.4, 0, 0, 20),
					TextXAlignment = Enum.TextXAlignment.Right,
				}),
				UI.new("Frame", {
					BackgroundColor3 = C.Panel,
					Position = UDim2.fromOffset(0, 26),
					Size = UDim2.new(1, 0, 0, 8),
					Children = { UI.corner(Theme.Radius.Pill), bar },
				}),
			},
		})
		UI.tween(bar, { Size = UDim2.fromScale(row.value / best, 1) }, Theme.TweenSlow)
	end
end

function Reports.new(_ctx)
	local self = {}
	local frame = UI.new("Frame", { Name = "Reports", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
	self.frame = frame
	local body = UI.scroll({ Parent = frame, Children = { UI.list(14), UI.padding(0, 8, 8, 0) } })

	local function render(days)
		UI.clear(body)

		local week = Aggregate.new()
		for _, day in days do
			Aggregate.merge(week, day.totals)
		end
		local net = Aggregate.net(week)

		UI.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 42),
			LayoutOrder = 1,
			Parent = body,
			Children = {
				UI.text({ Text = "Last 7 days", TextSize = 24, FontFace = F.Heavy, Size = UDim2.new(0.5, 0, 0, 30) }),
				UI.text({
					Text = "All registers on all servers",
					TextSize = 14,
					TextColor3 = C.Muted,
					Position = UDim2.fromOffset(0, 28),
					Size = UDim2.new(0.5, 0, 0, 16),
				}),
				UI.button({
					Text = "↻ Refresh",
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.fromOffset(120, 40),
					OnClick = function()
						task.spawn(self.show)
					end,
				}),
			},
		})

		local stats = UI.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 86),
			LayoutOrder = 2,
			Parent = body,
			Children = {
				UI.new("UIGridLayout", {
					CellSize = UDim2.new(0.25, -9, 1, 0),
					CellPadding = UDim2.fromOffset(12, 0),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		})
		UI.stat("Net takings", money(net), C.Success, 1).Parent = stats
		UI.stat("Sales", Format.number(week.count), nil, 2).Parent = stats
		UI.stat("Items sold", Format.number(week.items), nil, 3).Parent = stats
		UI.stat("Discounts given", money(week.discounts), C.Warning, 4).Parent = stats

		-- Bar chart
		local chart = UI.card({
			Size = UDim2.new(1, 0, 0, 260),
			LayoutOrder = 3,
			Parent = body,
			Children = { UI.padding(16) },
		})
		UI.text({ Text = "Net takings per day", FontFace = F.Bold, Parent = chart })
		local plot = UI.new("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 32),
			Size = UDim2.new(1, 0, 1, -32),
			Parent = chart,
			Children = {
				UI.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalFlex = Enum.UIFlexAlignment.Fill,
					Padding = UDim.new(0, 12),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		})
		local peak = 1
		for _, day in days do
			peak = math.max(peak, Aggregate.net(day.totals))
		end
		for i, day in days do
			local value = Aggregate.net(day.totals)
			local isToday = i == #days
			local bar = UI.new("Frame", {
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.fromScale(0.5, 1),
				Size = UDim2.fromScale(0.7, 0),
				BackgroundColor3 = if isToday then C.Accent else C.AccentSoft,
				Children = {
					UI.corner(6),
					UI.new("UIGradient", { Transparency = NumberSequence.new(0, 0.35), Rotation = 90 }),
				},
			})
			UI.new("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(0, 1),
				LayoutOrder = i,
				Parent = plot,
				Children = {
					UI.text({
						Text = if value ~= 0 then money(value) else "–",
						TextSize = 13,
						FontFace = F.Bold,
						TextColor3 = if isToday then C.Text else C.Muted,
						TextXAlignment = Enum.TextXAlignment.Center,
						Size = UDim2.new(1, 0, 0, 18),
					}),
					UI.new("Frame", {
						BackgroundTransparency = 1,
						Position = UDim2.fromOffset(0, 22),
						Size = UDim2.new(1, 0, 1, -48),
						Children = { bar },
					}),
					UI.text({
						Text = day.label,
						TextSize = 13,
						TextColor3 = if isToday then C.Text else C.Muted,
						TextXAlignment = Enum.TextXAlignment.Center,
						AnchorPoint = Vector2.new(0, 1),
						Position = UDim2.fromScale(0, 1),
						Size = UDim2.new(1, 0, 0, 20),
					}),
				},
			})
			task.delay(i * 0.04, function()
				UI.tween(bar, { Size = UDim2.fromScale(0.7, math.max(value, 0) / peak) }, Theme.TweenSlow)
			end)
		end

		local lists = UI.new("Frame", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 4,
			Parent = body,
			Children = { UI.list(12, Enum.FillDirection.Horizontal) },
		})
		local productRows = {}
		for _, item in Aggregate.topProducts(week, 6) do
			table.insert(productRows, {
				label = item.name,
				value = item.total,
				sub = string.format("%d sold · %s", item.qty, money(item.total)),
			})
		end
		rankList(lists, "Best sellers", productRows, C.Accent, 1)
		local cashierRows = {}
		for _, cashier in Aggregate.topCashiers(week, 6) do
			table.insert(cashierRows, {
				label = cashier.name,
				value = cashier.total,
				sub = string.format("%d sales · %s", cashier.count, money(cashier.total)),
			})
		end
		rankList(lists, "Top cashiers", cashierRows, C.Success, 2)

		if week.refundCount > 0 then
			UI.text({
				Text = string.format(
					"Refunds: %d totalling %s (already taken off net takings)",
					week.refundCount,
					money(week.refunds)
				),
				TextColor3 = C.Muted,
				TextSize = 14,
				LayoutOrder = 5,
				Parent = body,
			})
		end
	end

	function self.show()
		UI.clear(body)
		UI.text({ Text = "Loading reports…", TextColor3 = C.Faint, Parent = body })
		local ok, days = Api.call("reports.days", 7)
		if ok then
			render(days)
		else
			Toasts.show(days, "error")
		end
	end

	return self
end

return Reports
