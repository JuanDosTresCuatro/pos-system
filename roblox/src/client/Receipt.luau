-- Paper-style receipts and shift reports, with the manager refund flow.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)

local Api = require(script.Parent.Api)
local UI = require(script.Parent.UI.UI)
local Theme = require(script.Parent.UI.Theme)
local Toasts = require(script.Parent.UI.Toasts)

local C, F = Theme.Colors, Theme.Fonts

local Receipt = {}

local WIDTH = 34 -- characters per receipt line
local LINE_HEIGHT = 18

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

type Line = { text: string, align: string?, bold: boolean? }

local function paper(lines: { Line }, stamp: string?): Frame
	local scroll = UI.scroll({
		Name = "Paper",
		Size = UDim2.new(1, 0, 0, math.min(#lines * LINE_HEIGHT + 40, 420)),
		BackgroundColor3 = C.Paper,
		BackgroundTransparency = 0,
		ScrollBarImageColor3 = Color3.fromRGB(190, 186, 176),
		Children = { UI.corner(6), UI.padding(20, 18), UI.list(0) },
	})
	for i, line in lines do
		UI.text({
			Text = line.text,
			LayoutOrder = i,
			FontFace = if line.bold then F.MonoBold else F.Mono,
			TextSize = 14,
			TextColor3 = C.Ink,
			TextTruncate = Enum.TextTruncate.None,
			TextXAlignment = if line.align == "center" then Enum.TextXAlignment.Center else Enum.TextXAlignment.Left,
			Size = UDim2.new(1, 0, 0, LINE_HEIGHT),
			Parent = scroll,
		})
	end
	local holder = UI.new("Frame", {
		Name = "PaperHolder",
		BackgroundTransparency = 1,
		Size = scroll.Size,
		LayoutOrder = 1,
		Children = { scroll },
	})
	if stamp then
		UI.text({
			Text = stamp,
			FontFace = F.Heavy,
			TextSize = 40,
			TextColor3 = C.Danger,
			TextTransparency = 0.15,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.45),
			Size = UDim2.fromOffset(260, 56),
			Rotation = -14,
			ZIndex = 5,
			Children = { UI.stroke(C.Danger, 3, 0.15) },
			Parent = holder,
		})
	end
	return holder
end

local function rule(): Line
	return { text = string.rep("-", WIDTH) }
end

local function row(left: string, right: string, bold: boolean?): Line
	return { text = Format.row(left, right, WIDTH), bold = bold }
end

function Receipt.saleLines(sale): { Line }
	local lines: { Line } = {
		{ text = string.upper(Config.Store.Name), align = "center", bold = true },
		{ text = sale.registerName, align = "center" },
		rule(),
		row("Receipt", sale.receipt),
		row("Date", Format.dateTime(sale.t)),
		row("Cashier", sale.cashier.name),
		row("Customer", sale.customer.name),
		rule(),
	}
	for _, line in sale.lines do
		table.insert(lines, row(string.format("%d x %s", line.qty, line.name), money(line.unitPrice * line.qty)))
	end
	table.insert(lines, rule())
	table.insert(lines, row("Subtotal", money(sale.subtotal)))
	if sale.discount > 0 then
		table.insert(lines, row(string.format("Discount %d%%", sale.discountPct), "-" .. money(sale.discount)))
	end
	if sale.tax > 0 then
		table.insert(lines, row(Config.Tax.Name .. (if Config.Tax.Inclusive then " (incl.)" else ""), money(sale.tax)))
	end
	table.insert(lines, row("TOTAL", money(sale.total), true))
	if sale.refunded then
		table.insert(lines, rule())
		table.insert(lines, row("Refunded", Format.dateTime(sale.refunded.t)))
		table.insert(lines, row("By", sale.refunded.by))
	end
	table.insert(lines, rule())
	table.insert(lines, { text = Config.Store.Footer, align = "center" })
	return lines
end

local function buttonRow(order: number): Frame
	return UI.new("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = order,
		Children = {
			UI.list(10, Enum.FillDirection.Horizontal, { HorizontalAlignment = Enum.HorizontalAlignment.Right }),
		},
	})
end

-- options.canRefund: show the refund flow. options.onChanged(sale): called after a refund.
function Receipt.showSale(gui: Instance, sale, options: { canRefund: boolean?, onChanged: ((any) -> ())? }?)
	local opts = options or {}
	local dialog, close = UI.modal(gui, { Title = "Receipt " .. sale.receipt, Width = 400 })
	paper(Receipt.saleLines(sale), if sale.refunded then "REFUNDED" else nil).Parent = dialog

	local actions = buttonRow(2)
	actions.Parent = dialog

	local function showActions()
		UI.clear(actions)
		if opts.canRefund and not sale.refunded then
			UI.button({
				Text = "Refund",
				Style = "danger",
				LayoutOrder = 1,
				Parent = actions,
				OnClick = function()
					UI.clear(actions)
					local restock = true
					local toggle
					toggle = UI.button({
						Text = "☑ Restock items",
						Style = "ghost",
						Size = UDim2.fromOffset(150, 40),
						LayoutOrder = 1,
						OnClick = function()
							restock = not restock
							toggle.Text = (if restock then "☑" else "☐") .. " Restock items"
						end,
					})
					toggle.Parent = actions
					UI.button({ Text = "Back", LayoutOrder = 2, Size = UDim2.fromOffset(80, 40), OnClick = showActions }).Parent =
						actions
					UI.button({
						Text = "Confirm " .. money(sale.total),
						Style = "danger",
						Size = UDim2.fromOffset(150, 40),
						LayoutOrder = 3,
						OnClick = function(button)
							UI.setEnabled(button, false)
							button.Text = "Refunding…"
							local ok, result = Api.call("sales.refund", sale.receipt, restock)
							if ok then
								Toasts.show(
									string.format("Refunded %s to %s", money(sale.total), sale.customer.name),
									"success"
								)
								close()
								if opts.onChanged then
									opts.onChanged(result)
								end
							else
								Toasts.show(result, "error")
								showActions()
							end
						end,
					}).Parent =
						actions
				end,
			}).Parent =
				actions
		end
		UI.button({ Text = "Close", Style = "primary", LayoutOrder = 9, OnClick = close }).Parent = actions
	end
	showActions()
	return close
end

function Receipt.showReport(gui: Instance, title: string, report)
	local t = report.totals
	local lines: { Line } = {
		{ text = string.upper(Config.Store.Name), align = "center", bold = true },
		{ text = title, align = "center", bold = true },
		rule(),
		row("Register", report.registerName),
		row("Shift", report.id),
		row("Opened", Format.dateTime(report.openedAt)),
		row("Opened by", report.openedBy),
	}
	if report.closedAt then
		table.insert(lines, row("Closed", Format.dateTime(report.closedAt)))
		table.insert(lines, row("Closed by", report.closedBy))
		table.insert(lines, row("Length", Format.duration(report.closedAt - report.openedAt)))
	end
	table.insert(lines, rule())
	table.insert(lines, row("Sales", tostring(t.count)))
	table.insert(lines, row("Items sold", tostring(t.items)))
	table.insert(lines, row("Gross", money(t.gross)))
	table.insert(lines, row("Discounts", "-" .. money(t.discounts)))
	if t.tax > 0 then
		table.insert(lines, row(Config.Tax.Name, money(t.tax)))
	end
	table.insert(lines, row("Taken", money(t.sales)))
	table.insert(lines, row(string.format("Refunds (%d)", t.refundCount), "-" .. money(t.refunds)))
	table.insert(lines, row("NET", money(report.net), true))
	table.insert(lines, row("Average sale", money(report.average)))
	if #report.topProducts > 0 then
		table.insert(lines, rule())
		table.insert(lines, { text = "TOP ITEMS", bold = true })
		for _, item in report.topProducts do
			table.insert(lines, row(string.format("%d x %s", item.qty, item.name), money(item.total)))
		end
	end
	if #report.cashiers > 0 then
		table.insert(lines, rule())
		table.insert(lines, { text = "BY CASHIER", bold = true })
		for _, cashier in report.cashiers do
			table.insert(lines, row(string.format("%s (%d)", cashier.name, cashier.count), money(cashier.total)))
		end
	end

	local dialog, close = UI.modal(gui, { Title = title, Width = 400 })
	paper(lines).Parent = dialog
	local actions = buttonRow(2)
	actions.Parent = dialog
	UI.button({ Text = "Done", Style = "primary", OnClick = close }).Parent = actions
	return close
end

return Receipt
