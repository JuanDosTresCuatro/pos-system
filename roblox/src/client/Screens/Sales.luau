-- Sales history: the latest receipts across every server, lookup by receipt number, refunds.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Roles = require(Shared.Roles)

local Client = script.Parent.Parent
local Api = require(Client.Api)
local Receipt = require(Client.Receipt)
local State = require(Client.State)
local UI = require(Client.UI.UI)
local Theme = require(Client.UI.Theme)
local Toasts = require(Client.UI.Toasts)

local C, F = Theme.Colors, Theme.Fonts

local Sales = {}

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

-- Column layout shared by the header and rows: { label, x scale, width scale, align }
local COLUMNS = {
	{ "Receipt", 0, 0.18 },
	{ "Time", 0.18, 0.16 },
	{ "Cashier → Customer", 0.34, 0.32 },
	{ "Items", 0.66, 0.08, "right" },
	{ "Total", 0.74, 0.12, "right" },
	{ "", 0.88, 0.12, "right" },
}

local function cell(text: string, column, props: { [string]: any }?)
	local label = UI.text({
		Text = text,
		Position = UDim2.new(column[2], 8, 0, 0),
		Size = UDim2.new(column[3], -16, 1, 0),
		TextXAlignment = if column[4] == "right" then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
		TextSize = 15,
	})
	for key, value in (props or {}) :: { [string]: any } do
		(label :: any)[key] = value
	end
	return label
end

function Sales.new(ctx)
	local self = {}
	local frame = UI.new("Frame", { Name = "Sales", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
	self.frame = frame

	UI.text({ Text = "Sales", TextSize = 24, FontFace = F.Heavy, Size = UDim2.new(0.4, 0, 0, 42), Parent = frame })
	local find = UI.input({
		Placeholder = "Receipt number, e.g. " .. Format.receipt(Config.Store.ReceiptPrefix, 42),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -230, 0, 0),
		Size = UDim2.fromOffset(280, 42),
	})
	find.Parent = frame

	local list
	local refresh -- forward

	local function open(receipt: string)
		local ok, sale = Api.call("sales.get", receipt)
		if not ok then
			Toasts.show(sale, "error")
			return
		end
		Receipt.showSale(ctx.overlay, sale, {
			canRefund = State.role >= Roles.Manager,
			onChanged = function()
				task.spawn(refresh)
			end,
		})
	end

	UI.button({
		Text = "Find",
		Style = "primary",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -130, 0, 0),
		Size = UDim2.fromOffset(90, 42),
		Parent = frame,
		OnClick = function()
			local text = string.gsub(find.Text, "%s", "")
			if text ~= "" then
				open(string.upper(text))
			end
		end,
	})
	UI.button({
		Text = "↻ Refresh",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(120, 42),
		Parent = frame,
		OnClick = function()
			task.spawn(refresh)
		end,
	})

	local head = UI.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 58),
		Size = UDim2.new(1, -8, 0, 24),
		Parent = frame,
	})
	for _, column in COLUMNS do
		cell(column[1], column, { TextSize = 13, TextColor3 = C.Faint, FontFace = F.Bold }).Parent = head
	end

	list = UI.scroll({
		Position = UDim2.fromOffset(0, 86),
		Size = UDim2.new(1, 0, 1, -86),
		Parent = frame,
		Children = { UI.list(6) },
	})

	function refresh()
		local ok, sales = Api.call("sales.recent", 100)
		UI.clear(list)
		if not ok then
			Toasts.show(sales, "error")
			return
		end
		if #sales == 0 then
			UI.text({ Text = "No sales yet. Ring something up on the Sell tab.", TextColor3 = C.Faint, Parent = list })
		end
		for i, sale in sales do
			local row = UI.new("TextButton", {
				Text = "",
				AutoButtonColor = false,
				BackgroundColor3 = C.Raised,
				Size = UDim2.new(1, -8, 0, 50),
				LayoutOrder = i,
				Parent = list,
				Children = { UI.corner(Theme.Radius.Medium) },
			})
			cell(sale.receipt, COLUMNS[1], { FontFace = F.MonoBold, TextSize = 14 }).Parent = row
			cell(Format.dateTime(sale.t), COLUMNS[2], { TextColor3 = C.Muted }).Parent = row
			cell(sale.cashier .. "  →  " .. sale.customer, COLUMNS[3]).Parent = row
			cell(tostring(sale.items), COLUMNS[4], { TextColor3 = C.Muted }).Parent = row
			cell(money(sale.total), COLUMNS[5], { FontFace = F.Bold }).Parent = row
			local status = if sale.refunded
				then UI.pill("Refunded", C.Danger, C.DangerSoft)
				else UI.pill("Paid", C.Success, C.SuccessSoft)
			status.AnchorPoint = Vector2.new(1, 0.5)
			status.Position = UDim2.new(1, -12, 0.5, 0)
			status.Parent = row

			row.MouseEnter:Connect(function()
				UI.tween(row, { BackgroundColor3 = C.RaisedHover })
			end)
			row.MouseLeave:Connect(function()
				UI.tween(row, { BackgroundColor3 = C.Raised })
			end)
			row.Activated:Connect(function()
				open(sale.receipt)
			end)
		end
	end

	self.show = refresh
	return self
end

return Sales
