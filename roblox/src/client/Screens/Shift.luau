-- Shift: open it to take payments, watch the live X report, close it for the Z report.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)

local Client = script.Parent.Parent
local Api = require(Client.Api)
local Receipt = require(Client.Receipt)
local State = require(Client.State)
local UI = require(Client.UI.UI)
local Theme = require(Client.UI.Theme)
local Toasts = require(Client.UI.Toasts)

local C, F = Theme.Colors, Theme.Fonts

local Shift = {}

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

function Shift.new(ctx)
	local self = {}
	local frame = UI.new("Frame", { Name = "Shift", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
	self.frame = frame
	local body = UI.scroll({ Parent = frame, Children = { UI.list(14), UI.padding(0, 8, 8, 0) } })

	local render -- forward

	local function act(action: string, after: (any) -> ())
		local ok, result = Api.call(action)
		if ok then
			after(result)
		else
			Toasts.show(result, "error")
		end
	end

	local function openShift()
		act("shift.open", function(summary)
			State.set("register", summary)
			Toasts.show("Shift opened on " .. summary.name, "success")
		end)
	end

	local function closeShift()
		local dialog, close = UI.modal(ctx.overlay, { Title = "Close shift?", Width = 380 })
		UI.text({
			Text = "This ends the shift on " .. State.register.name .. " and prints the Z report.",
			TextWrapped = true,
			TextColor3 = C.Muted,
			Size = UDim2.new(1, 0, 0, 44),
			LayoutOrder = 1,
			Parent = dialog,
		})
		local actions = UI.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 42),
			LayoutOrder = 2,
			Parent = dialog,
			Children = {
				UI.list(10, Enum.FillDirection.Horizontal, { HorizontalAlignment = Enum.HorizontalAlignment.Right }),
			},
		})
		UI.button({
			Text = "Keep open",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(110, 42),
			Parent = actions,
			OnClick = close,
		})
		UI.button({
			Text = "Close shift",
			Style = "danger",
			LayoutOrder = 2,
			Size = UDim2.fromOffset(130, 42),
			Parent = actions,
			OnClick = function()
				close()
				act("shift.close", function(report)
					local register = table.clone(State.register)
					register.shift = nil
					State.set("register", register)
					Receipt.showReport(ctx.overlay, "Z REPORT", report)
				end)
			end,
		})
	end

	function render()
		UI.clear(body)
		local register = State.register
		if not register then
			return
		end
		local report = register.shift

		if not report then
			UI.card({
				Size = UDim2.new(1, 0, 0, 200),
				LayoutOrder = 1,
				Parent = body,
				Children = {
					UI.padding(28),
					UI.list(12, nil, {
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						VerticalAlignment = Enum.VerticalAlignment.Center,
					}),
					UI.text({
						Text = "⏱",
						TextSize = 36,
						TextXAlignment = Enum.TextXAlignment.Center,
						Size = UDim2.new(1, 0, 0, 40),
						LayoutOrder = 1,
					}),
					UI.text({
						Text = "No shift open on " .. register.name,
						TextSize = 22,
						FontFace = F.Heavy,
						TextXAlignment = Enum.TextXAlignment.Center,
						Size = UDim2.new(1, 0, 0, 28),
						LayoutOrder = 2,
					}),
					UI.text({
						Text = "Open a shift to start taking payments. Every sale is added to its report.",
						TextColor3 = C.Muted,
						TextXAlignment = Enum.TextXAlignment.Center,
						LayoutOrder = 3,
					}),
					UI.button({
						Text = "Open shift",
						Style = "success",
						Size = UDim2.fromOffset(180, 46),
						LayoutOrder = 4,
						OnClick = openShift,
					}),
				},
			})
			return
		end

		local t = report.totals
		-- Header row
		UI.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 46),
			LayoutOrder = 1,
			Parent = body,
			Children = {
				UI.text({
					Text = "Shift " .. report.id,
					TextSize = 24,
					FontFace = F.Heavy,
					Size = UDim2.new(0.5, 0, 0, 28),
				}),
				UI.text({
					Text = string.format(
						"Opened %s by %s · running %s",
						Format.clock(report.openedAt),
						report.openedBy,
						Format.duration(os.time() - report.openedAt)
					),
					TextSize = 14,
					TextColor3 = C.Muted,
					Position = UDim2.fromOffset(0, 28),
					Size = UDim2.new(0.6, 0, 0, 18),
				}),
				UI.new("Frame", {
					BackgroundTransparency = 1,
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.fromScale(0.4, 1),
					Children = {
						UI.list(
							10,
							Enum.FillDirection.Horizontal,
							{ HorizontalAlignment = Enum.HorizontalAlignment.Right }
						),
						UI.button({
							Text = "X report",
							Size = UDim2.fromOffset(110, 42),
							LayoutOrder = 1,
							OnClick = function()
								act("shift.report", function(summary)
									State.set("register", summary)
									if summary.shift then
										Receipt.showReport(ctx.overlay, "X REPORT", summary.shift)
									end
								end)
							end,
						}),
						UI.button({
							Text = "Close shift",
							Style = "danger",
							Size = UDim2.fromOffset(130, 42),
							LayoutOrder = 2,
							OnClick = closeShift,
						}),
					},
				}),
			},
		})

		-- Stat tiles
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
		UI.stat("Net takings", money(report.net), C.Success, 1).Parent = stats
		UI.stat("Sales", tostring(t.count), nil, 2).Parent = stats
		UI.stat("Average sale", money(report.average), nil, 3).Parent = stats
		UI.stat("Refunds", money(t.refunds), if t.refunds > 0 then C.Danger else nil, 4).Parent = stats

		-- Top items with proportional bars
		local top = UI.card({
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 3,
			Parent = body,
			Children = { UI.padding(16), UI.list(8) },
		})
		UI.text({ Text = "Top items this shift", TextSize = 16, FontFace = F.Bold, Parent = top })
		if #report.topProducts == 0 then
			UI.text({ Text = "Nothing sold yet", TextColor3 = C.Faint, LayoutOrder = 1, Parent = top })
		end
		local best = if report.topProducts[1] then math.max(report.topProducts[1].total, 1) else 1
		for i, item in report.topProducts do
			local bar = UI.new("Frame", {
				BackgroundColor3 = C.Accent,
				Size = UDim2.fromScale(0, 1),
				Children = { UI.corner(Theme.Radius.Pill) },
			})
			UI.new("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 30),
				LayoutOrder = i,
				Parent = top,
				Children = {
					UI.text({ Text = string.format("%d × %s", item.qty, item.name), Size = UDim2.fromScale(0.35, 1) }),
					UI.new("Frame", {
						BackgroundColor3 = C.Panel,
						Position = UDim2.new(0.36, 0, 0.5, -5),
						Size = UDim2.new(0.5, 0, 0, 10),
						Children = { UI.corner(Theme.Radius.Pill), bar },
					}),
					UI.text({
						Text = money(item.total),
						FontFace = F.Bold,
						TextXAlignment = Enum.TextXAlignment.Right,
						Position = UDim2.fromScale(0.86, 0),
						Size = UDim2.fromScale(0.14, 1),
					}),
				},
			})
			UI.tween(bar, { Size = UDim2.fromScale(item.total / best, 1) }, Theme.TweenSlow)
		end
	end

	State.changed:Connect(function(key)
		if key == "register" and frame.Visible then
			render()
		end
	end)

	function self.show()
		act("shift.report", function(summary)
			State.set("register", summary)
		end)
		render()
	end

	return self
end

return Shift
