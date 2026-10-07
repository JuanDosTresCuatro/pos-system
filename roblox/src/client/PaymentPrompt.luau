-- The customer's side of checkout: an itemised bill with a countdown, Pay and Decline.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)

local Api = require(script.Parent.Api)
local Receipt = require(script.Parent.Receipt)
local UI = require(script.Parent.UI.UI)
local Theme = require(script.Parent.UI.Theme)
local Toasts = require(script.Parent.UI.Toasts)

local C, F = Theme.Colors, Theme.Fonts

local PaymentPrompt = {}

local gui: ScreenGui
local current: { id: string, close: () -> () }? = nil

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

local function balance(): number?
	local leaderstats = Players.LocalPlayer:FindFirstChild("leaderstats")
	local stat = leaderstats and leaderstats:FindFirstChild(Config.Currency.StatName)
	return if stat and (stat:IsA("IntValue") or stat:IsA("NumberValue")) then stat.Value else nil
end

local function totalRow(label: string, value: string, order: number, strong: boolean?)
	return UI.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, if strong then 34 else 22),
		LayoutOrder = order,
		Children = {
			UI.text({
				Text = label,
				TextSize = if strong then 20 else 15,
				FontFace = if strong then F.Heavy else F.Medium,
				TextColor3 = if strong then C.Text else C.Muted,
				Size = UDim2.fromScale(0.5, 1),
			}),
			UI.text({
				Text = value,
				TextSize = if strong then 26 else 15,
				FontFace = if strong then F.Heavy else F.Medium,
				TextColor3 = if strong then C.Text else C.Muted,
				TextXAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.fromScale(0.5, 0),
				Size = UDim2.fromScale(0.5, 1),
			}),
		},
	})
end

function PaymentPrompt.show(order)
	if current then
		current.close()
	end

	local dialog, close = UI.modal(gui, { Width = 420, Dismissable = false })
	local entry = { id = order.id, close = close }
	current = entry
	local function done()
		if current == entry then
			current = nil
		end
		close()
	end

	-- Header
	UI.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 52),
		LayoutOrder = 1,
		Parent = dialog,
		Children = {
			UI.new("TextLabel", {
				Text = "🛒",
				TextSize = 24,
				BackgroundColor3 = C.AccentSoft,
				Size = UDim2.fromOffset(48, 48),
				Children = { UI.corner(Theme.Radius.Medium) },
			}),
			UI.text({
				Text = "Payment request",
				TextSize = 22,
				FontFace = F.Heavy,
				Position = UDim2.fromOffset(60, 2),
				Size = UDim2.new(1, -60, 0, 26),
			}),
			UI.text({
				Text = string.format("%s at %s, %s", order.cashier, order.registerName, Config.Store.Name),
				TextSize = 14,
				TextColor3 = C.Muted,
				Position = UDim2.fromOffset(60, 28),
				Size = UDim2.new(1, -60, 0, 20),
			}),
		},
	})

	-- Items
	local list = UI.scroll({
		Name = "Items",
		Size = UDim2.new(1, 0, 0, math.min(#order.lines * 30 + 12, 190)),
		BackgroundColor3 = C.Raised,
		BackgroundTransparency = 0,
		LayoutOrder = 2,
		Parent = dialog,
		Children = { UI.corner(Theme.Radius.Medium), UI.padding(6, 12), UI.list(0) },
	})
	for i, line in order.lines do
		UI.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 30),
			LayoutOrder = i,
			Parent = list,
			Children = {
				UI.text({
					Text = string.format("%d × %s", line.qty, line.name or line.productId),
					Size = UDim2.new(1, -90, 1, 0),
					TextSize = 15,
				}),
				UI.text({
					Text = money(line.unitPrice * line.qty),
					TextXAlignment = Enum.TextXAlignment.Right,
					Position = UDim2.new(1, -90, 0, 0),
					Size = UDim2.new(0, 90, 1, 0),
					TextSize = 15,
					FontFace = F.Mono,
				}),
			},
		})
	end

	-- Totals
	local totals = UI.new("Frame", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = 3,
		Parent = dialog,
		Children = { UI.list(2) },
	})
	if order.discount > 0 or order.tax > 0 then
		totalRow("Subtotal", money(order.subtotal), 1).Parent = totals
	end
	if order.discount > 0 then
		totalRow(string.format("Discount (%d%%)", order.discountPct), "-" .. money(order.discount), 2).Parent = totals
	end
	if order.tax > 0 then
		totalRow(Config.Tax.Name, money(order.tax), 3).Parent = totals
	end
	totalRow("Total", money(order.total), 4, true).Parent = totals

	local wallet = balance()
	local enough = wallet ~= nil and wallet >= order.total
	UI.text({
		Text = if wallet
			then string.format(
				"Your %s: %s → %s",
				Config.Currency.StatName,
				money(wallet),
				money(wallet - order.total)
			)
			else "Loading your balance…",
		TextSize = 14,
		TextColor3 = if enough then C.Muted else C.Danger,
		LayoutOrder = 4,
		Parent = dialog,
	})

	-- Countdown
	local bar = UI.new("Frame", {
		BackgroundColor3 = C.Accent,
		Size = UDim2.fromScale(1, 1),
		Children = { UI.corner(Theme.Radius.Pill) },
	})
	UI.new("Frame", {
		BackgroundColor3 = C.Raised,
		Size = UDim2.new(1, 0, 0, 6),
		LayoutOrder = 5,
		Parent = dialog,
		Children = { UI.corner(Theme.Radius.Pill), bar },
	})
	UI.tween(
		bar,
		{ Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Warning },
		TweenInfo.new(order.timeout, Enum.EasingStyle.Linear)
	)

	-- Actions
	local actions = UI.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 48),
		LayoutOrder = 6,
		Parent = dialog,
	})
	local decline = UI.button({
		Text = "Decline",
		Style = "ghost",
		Size = UDim2.new(0.38, -5, 1, 0),
		OnClick = function(button)
			UI.setEnabled(button, false)
			Api.call("checkout.respond", order.id, false)
			done()
		end,
	})
	decline.Parent = actions
	local pay = UI.button({
		Text = if enough then "Pay " .. money(order.total) else "Not enough " .. Config.Currency.StatName,
		Style = "success",
		TextSize = 18,
		Position = UDim2.new(0.38, 5, 0, 0),
		Size = UDim2.new(0.62, -5, 1, 0),
		OnClick = function(button)
			UI.setEnabled(button, false)
			UI.setEnabled(decline, false)
			button.Text = "Paying…"
			local ok, result = Api.call("checkout.respond", order.id, true)
			if ok then
				done()
			else
				Toasts.show(result, "error")
				button.Text = "Pay " .. money(order.total)
				UI.setEnabled(button, true)
				UI.setEnabled(decline, true)
			end
		end,
	})
	pay.Parent = actions
	if not enough then
		UI.setEnabled(pay, false)
	end
end

function PaymentPrompt.mount(screen: ScreenGui)
	gui = screen
	Api.on("PaymentRequest", PaymentPrompt.show)
	Api.on("PaymentClosed", function(payload)
		if current and current.id == payload.orderId then
			current.close()
			current = nil
			if payload.reason then
				Toasts.show(payload.reason, "warning")
			end
		end
	end)
	Api.on("Receipt", function(sale)
		Toasts.show(string.format("Paid %s. Enjoy!", money(sale.total)), "success")
		-- When you rang yourself up, the Sell screen already shows this receipt.
		if sale.cashier.userId ~= Players.LocalPlayer.UserId then
			Receipt.showSale(gui, sale)
		end
	end)
end

return PaymentPrompt
