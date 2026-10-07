-- Sell: product grid on the left, order on the right. Totals are computed with the same
-- Pricing module the server uses, so the preview always matches what the customer is charged.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Pricing = require(Shared.Pricing)

local Client = script.Parent.Parent
local Api = require(Client.Api)
local Receipt = require(Client.Receipt)
local State = require(Client.State)
local UI = require(Client.UI.UI)
local Theme = require(Client.UI.Theme)
local Toasts = require(Client.UI.Toasts)

local C, F = Theme.Colors, Theme.Fonts

local Sell = {}

local CART_WIDTH = 368
local BOTTOM_HEIGHT = 244

local current -- the live screen instance; push listeners forward to it

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

local function stockBadge(product): (string?, Color3?, Color3?)
	if product.stock == nil then
		return nil
	elseif product.stock <= 0 then
		return "Sold out", C.Danger, C.DangerSoft
	elseif product.stock <= Config.Inventory.LowStockAt then
		return string.format("Low · %d", product.stock), C.Warning, C.WarningSoft
	end
	return string.format("%d left", product.stock), C.Muted, C.Panel
end

function Sell.new(ctx)
	local self = {}

	local cart: { { productId: string, qty: number } } = {}
	local discount = 0
	local customer: { userId: number, name: string }? = nil
	local pending: { orderId: string, customer: string, total: number }? = nil
	local category = "All"
	local query = ""
	local tiles: { [string]: { stroke: UIStroke, badge: Frame, scale: UIScale } } = {}
	local previewToken = 0

	local frame = UI.new("Frame", { Name = "Sell", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
	self.frame = frame

	------------------------------------------------------------------ left: catalogue
	local left = UI.new("Frame", {
		Name = "Catalogue",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(CART_WIDTH + 16), 1, 0),
		Parent = frame,
	})
	local search = UI.input({ Placeholder = "🔍  Search products", Size = UDim2.new(1, 0, 0, 42), Parent = left })
	search.Parent = left
	local chips = UI.scroll({
		Name = "Categories",
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 0, 36),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 0,
		Parent = left,
		Children = { UI.list(8, Enum.FillDirection.Horizontal) },
	})
	local grid = UI.scroll({
		Name = "Grid",
		Position = UDim2.fromOffset(0, 100),
		Size = UDim2.new(1, 0, 1, -100),
		Parent = left,
		Children = {
			UI.new("UIGridLayout", {
				CellSize = UDim2.fromOffset(166, 114),
				CellPadding = UDim2.fromOffset(10, 10),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			UI.padding(2, 8, 8, 2),
		},
	})

	------------------------------------------------------------------ right: order
	local panel = UI.new("Frame", {
		Name = "Order",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, CART_WIDTH, 1, 0),
		BackgroundColor3 = C.Panel,
		Parent = frame,
		Children = { UI.corner(Theme.Radius.Large), UI.stroke(), UI.padding(14) },
	})
	UI.text({
		Text = "Current order",
		TextSize = 18,
		FontFace = F.Heavy,
		Size = UDim2.new(1, -80, 0, 28),
		Parent = panel,
	})
	local clearButton = UI.button({
		Text = "Clear",
		Style = "ghost",
		TextSize = 14,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(70, 28),
	})
	clearButton.Parent = panel

	local customerButton = UI.button({
		Text = "",
		Style = "secondary",
		Position = UDim2.fromOffset(0, 38),
		Size = UDim2.new(1, 0, 0, 46),
		Font = F.Medium,
		TextSize = 15,
	})
	customerButton.TextXAlignment = Enum.TextXAlignment.Left
	UI.padding(0, 14).Parent = customerButton
	customerButton.Parent = panel

	local lines = UI.scroll({
		Name = "Lines",
		Position = UDim2.fromOffset(0, 94),
		Size = UDim2.new(1, 0, 1, -(94 + BOTTOM_HEIGHT)),
		Parent = panel,
		Children = { UI.list(6) },
	})
	local empty = UI.text({
		Text = "Tap a product to add it to the order",
		TextColor3 = C.Faint,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, 94),
		Size = UDim2.new(1, 0, 1, -(94 + BOTTOM_HEIGHT)),
		Parent = panel,
	})

	local bottom = UI.new("Frame", {
		Name = "Summary",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, BOTTOM_HEIGHT),
		Parent = panel,
	})
	UI.new("Frame", { BackgroundColor3 = C.Border, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), Parent = bottom })
	UI.text({
		Text = "Discount",
		TextSize = 13,
		TextColor3 = C.Muted,
		Position = UDim2.fromOffset(0, 10),
		Parent = bottom,
	})
	local discountRow = UI.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 32),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = bottom,
		Children = { UI.list(6, Enum.FillDirection.Horizontal) },
	})

	local function totalLine(y: number, label: string, strong: boolean?)
		local name = UI.text({
			Text = label,
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(0.5, 0, 0, if strong then 34 else 20),
			TextSize = if strong then 20 else 15,
			FontFace = if strong then F.Heavy else F.Medium,
			TextColor3 = if strong then C.Text else C.Muted,
			Parent = bottom,
		})
		local value = UI.text({
			Text = "",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, y),
			Size = UDim2.new(0.5, 0, 0, if strong then 34 else 20),
			TextSize = if strong then 28 else 15,
			FontFace = if strong then F.Heavy else F.Medium,
			TextColor3 = if strong then C.Text else C.Muted,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = bottom,
		})
		return name, value
	end
	local _, subtotalValue = totalLine(74, "Subtotal")
	local discountName, discountValue = totalLine(96, "Discount")
	local taxName, taxValue = totalLine(118, Config.Tax.Name)
	local _, totalValue = totalLine(142, "Total", true)

	local charge = UI.button({
		Text = "Charge",
		Style = "primary",
		TextSize = 19,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 54),
		Radius = Theme.Radius.Medium,
	})
	charge.Parent = bottom

	-- Waiting-for-payment overlay
	local waitScale = UI.new("UIScale")
	local waitBar = UI.new(
		"Frame",
		{ BackgroundColor3 = C.Accent, Size = UDim2.fromScale(1, 1), Children = { UI.corner(Theme.Radius.Pill) } }
	)
	local waitTitle = UI.text({
		Text = "",
		TextSize = 22,
		FontFace = F.Heavy,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = 2,
		TextWrapped = true,
	})
	local waitTotal = UI.text({
		Text = "",
		TextSize = 40,
		FontFace = F.Heavy,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 48),
		LayoutOrder = 3,
	})
	local waiting = UI.new("TextButton", {
		Name = "Waiting",
		Text = "",
		AutoButtonColor = false,
		Visible = false,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.04,
		Size = UDim2.new(1, 28, 1, 28),
		Position = UDim2.fromOffset(-14, -14),
		ZIndex = 10,
		Parent = panel,
		Children = {
			UI.corner(Theme.Radius.Large),
			UI.padding(28),
			UI.list(14, nil, {
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			}),
			waitScale,
			UI.new("TextLabel", {
				Text = "⏳",
				TextSize = 34,
				BackgroundColor3 = C.AccentSoft,
				Size = UDim2.fromOffset(72, 72),
				LayoutOrder = 1,
				Children = { UI.corner(Theme.Radius.Pill) },
			}),
			waitTitle,
			waitTotal,
			UI.text({
				Text = "The customer approves the payment on their screen",
				TextSize = 14,
				TextColor3 = C.Muted,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.new(1, 0, 0, 36),
				LayoutOrder = 4,
			}),
			UI.new("Frame", {
				BackgroundColor3 = C.Raised,
				Size = UDim2.new(1, 0, 0, 6),
				LayoutOrder = 5,
				Children = { UI.corner(Theme.Radius.Pill), waitBar },
			}),
		},
	})
	local cancelWait =
		UI.button({ Text = "Cancel payment", Style = "ghost", Size = UDim2.new(1, 0, 0, 42), LayoutOrder = 6 })
	cancelWait.Parent = waiting

	-- Customer picker
	local picker = UI.new("Frame", {
		Name = "Picker",
		Visible = false,
		BackgroundColor3 = C.Raised,
		Position = UDim2.fromOffset(0, 88),
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 8,
		Parent = panel,
		Children = { UI.corner(Theme.Radius.Medium), UI.stroke(C.Accent, 1, 0.3), UI.padding(8), UI.list(4) },
	})

	------------------------------------------------------------------ logic
	local function payload()
		local out = {}
		for _, line in cart do
			table.insert(out, { productId = line.productId, qty = line.qty })
		end
		return out
	end

	local function totals(): Pricing.Totals
		local priced = {}
		for _, line in cart do
			local product = State.byId[line.productId]
			if product then
				table.insert(priced, {
					productId = product.id,
					name = product.name,
					unitPrice = product.price,
					qty = line.qty,
					taxRate = if Config.Tax.Enabled then product.taxRate else 0,
				})
			end
		end
		return Pricing.priceLines(priced, { discountPct = discount, taxInclusive = Config.Tax.Inclusive })
	end

	local function schedulePreview()
		previewToken += 1
		local token = previewToken
		task.delay(0.35, function()
			if token == previewToken and State.register then
				Api.call("register.preview", payload(), discount)
			end
		end)
	end

	local renderCart -- forward declaration

	local function qtyIn(productId: string): number
		for _, line in cart do
			if line.productId == productId then
				return line.qty
			end
		end
		return 0
	end

	local function setQty(productId: string, qty: number)
		local product = State.byId[productId]
		if not product then
			return
		end
		if qty > Config.Checkout.MaxQty then
			Toasts.show(string.format("You can sell at most %d of one item", Config.Checkout.MaxQty), "warning")
			return
		end
		if product.stock ~= nil and qty > product.stock then
			Toasts.show(
				if product.stock == 0
					then product.name .. " is sold out"
					else string.format("Only %d %s left", product.stock, product.name),
				"warning"
			)
			return
		end
		for i, line in cart do
			if line.productId == productId then
				if qty <= 0 then
					table.remove(cart, i)
				else
					line.qty = qty
				end
				renderCart()
				return
			end
		end
		if qty > 0 then
			if #cart >= Config.Checkout.MaxLines then
				Toasts.show(
					string.format("An order can have at most %d different items", Config.Checkout.MaxLines),
					"warning"
				)
				return
			end
			table.insert(cart, { productId = productId, qty = qty })
			renderCart()
		end
	end

	local function updateTiles()
		for id, tile in tiles do
			local qty = qtyIn(id)
			tile.badge.Visible = qty > 0
			local label = tile.badge:FindFirstChild("Label") :: TextLabel?
			if label then
				label.Text = "×" .. qty
			end
			UI.tween(
				tile.stroke,
				{ Color = if qty > 0 then C.Accent else C.Border, Thickness = if qty > 0 then 2 else 1 }
			)
		end
	end

	local function renderGrid()
		UI.clear(grid)
		table.clear(tiles)
		local needle = string.lower(query)
		for index, product in State.catalogue do
			local matchesCategory = category == "All" or product.category == category
			local matchesQuery = needle == "" or string.find(string.lower(product.name), needle, 1, true) ~= nil
			if product.active and matchesCategory and matchesQuery then
				local soldOut = product.stock ~= nil and product.stock <= 0
				local stroke = UI.stroke()
				local scale = UI.new("UIScale")
				local badgeText, badgeFg, badgeBg = stockBadge(product)
				local inCart = UI.pill("×0", Color3.new(1, 1, 1), C.Accent, {
					Visible = false,
					AnchorPoint = Vector2.new(1, 1),
					Position = UDim2.new(1, -10, 1, -10),
				})
				local tile = UI.new("TextButton", {
					Name = product.id,
					Text = "",
					AutoButtonColor = false,
					LayoutOrder = index,
					BackgroundColor3 = C.Raised,
					Parent = grid,
					Children = {
						UI.corner(Theme.Radius.Medium),
						stroke,
						scale,
						UI.new("TextLabel", {
							Text = string.upper(string.sub(product.name, 1, 1)),
							FontFace = F.Heavy,
							TextSize = 18,
							TextColor3 = Color3.new(1, 1, 1),
							TextStrokeTransparency = 0.7,
							BackgroundColor3 = product.colour,
							Position = UDim2.fromOffset(12, 12),
							Size = UDim2.fromOffset(36, 36),
							Children = {
								UI.corner(10),
								UI.new("UIGradient", {
									Transparency = NumberSequence.new(0, 0.25),
									Rotation = 90,
								}),
							},
						}),
						if badgeText
							then UI.pill(badgeText, badgeFg :: Color3, badgeBg :: Color3, {
								AnchorPoint = Vector2.new(1, 0),
								Position = UDim2.new(1, -10, 0, 12),
								Size = UDim2.fromOffset(0, 22),
							})
							else nil,
						UI.text({
							Text = product.name,
							FontFace = F.Bold,
							TextSize = 16,
							TextColor3 = if soldOut then C.Faint else C.Text,
							Position = UDim2.fromOffset(12, 56),
							Size = UDim2.new(1, -24, 0, 20),
						}),
						UI.text({
							Text = money(product.price),
							FontFace = F.Heavy,
							TextSize = 19,
							TextColor3 = if soldOut then C.Faint else C.AccentHover,
							Position = UDim2.fromOffset(12, 80),
							Size = UDim2.new(1, -70, 0, 22),
						}),
						inCart,
					},
				})
				tiles[product.id] = { stroke = stroke, badge = inCart, scale = scale }
				tile.MouseEnter:Connect(function()
					UI.tween(tile, { BackgroundColor3 = C.RaisedHover })
				end)
				tile.MouseLeave:Connect(function()
					UI.tween(tile, { BackgroundColor3 = C.Raised })
				end)
				tile.Activated:Connect(function()
					if pending then
						return
					end
					scale.Scale = 0.93
					UI.tween(scale, { Scale = 1 }, Theme.TweenSlow)
					setQty(product.id, qtyIn(product.id) + 1)
				end)
			end
		end
		if #grid:GetChildren() <= 2 then
			UI.text({
				Text = "No products match",
				TextColor3 = C.Faint,
				Parent = grid,
			})
		end
		updateTiles()
	end

	local function renderChips()
		UI.clear(chips)
		local names = { "All" }
		for _, name in Config.Categories do
			table.insert(names, name)
		end
		for i, name in names do
			local selected = name == category
			local chip = UI.button({
				Text = name,
				Style = if selected then "primary" else "secondary",
				TextSize = 14,
				Size = UDim2.fromScale(0, 1),
				LayoutOrder = i,
				Radius = Theme.Radius.Pill,
				OnClick = function()
					category = name
					renderChips()
					renderGrid()
				end,
			})
			chip.AutomaticSize = Enum.AutomaticSize.X
			UI.padding(0, 16).Parent = chip
			chip.Parent = chips
		end
	end

	local function renderDiscounts()
		UI.clear(discountRow)
		for i, pct in Config.Discounts.Presets do
			if pct <= State.maxDiscount then
				UI.button({
					Text = if pct == 0 then "None" else pct .. "%",
					Style = if pct == discount then "primary" else "secondary",
					TextSize = 13,
					Size = UDim2.new(0, if pct == 0 then 54 else 44, 1, 0),
					LayoutOrder = i,
					Parent = discountRow,
					OnClick = function()
						discount = pct
						renderDiscounts()
						renderCart()
					end,
				})
			end
		end
	end

	local function updateCustomerButton()
		customerButton.Text = if customer then "👤  " .. customer.name else "👤  Choose customer   ▾"
		customerButton.TextColor3 = if customer then C.Text else C.Muted
	end

	local function updateCharge(total: number)
		local register = State.register
		if not register or not register.shift then
			charge.Text = "Open a shift to take payments"
			UI.setEnabled(charge, true)
			charge:SetAttribute("Action", "shift")
		elseif #cart == 0 then
			charge.Text = "Charge"
			UI.setEnabled(charge, false)
			charge:SetAttribute("Action", nil)
		elseif not customer then
			charge.Text = "Choose a customer"
			UI.setEnabled(charge, true)
			charge:SetAttribute("Action", "customer")
		else
			charge.Text = "Charge " .. money(total)
			UI.setEnabled(charge, true)
			charge:SetAttribute("Action", "charge")
		end
	end

	function renderCart()
		UI.clear(lines)
		local result = totals()
		for i, line in result.lines do
			local product = State.byId[line.productId]
			local row = UI.new("Frame", {
				Name = line.productId,
				BackgroundColor3 = C.Raised,
				Size = UDim2.new(1, -6, 0, 54),
				LayoutOrder = i,
				Parent = lines,
				Children = {
					UI.corner(Theme.Radius.Medium),
					UI.new("Frame", {
						BackgroundColor3 = if product then product.colour else C.Accent,
						Position = UDim2.fromOffset(0, 10),
						Size = UDim2.new(0, 4, 1, -20),
						Children = { UI.corner(2) },
					}),
					UI.text({
						Text = line.name or line.productId,
						FontFace = F.Bold,
						TextSize = 15,
						Position = UDim2.fromOffset(14, 8),
						Size = UDim2.new(1, -190, 0, 20),
					}),
					UI.text({
						Text = money(line.unitPrice) .. " each",
						TextSize = 13,
						TextColor3 = C.Muted,
						Position = UDim2.fromOffset(14, 28),
						Size = UDim2.new(1, -190, 0, 18),
					}),
					UI.text({
						Text = money(line.unitPrice * line.qty),
						FontFace = F.Bold,
						TextSize = 15,
						TextXAlignment = Enum.TextXAlignment.Right,
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.new(1, -12, 0.5, 0),
						Size = UDim2.fromOffset(64, 20),
					}),
				},
			})
			local stepper = UI.new("Frame", {
				BackgroundColor3 = C.Panel,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -84, 0.5, 0),
				Size = UDim2.fromOffset(96, 32),
				Parent = row,
				Children = { UI.corner(Theme.Radius.Small) },
			})
			UI.button({
				Text = "−",
				Style = "ghost",
				Size = UDim2.fromOffset(32, 32),
				OnClick = function()
					if not pending then
						setQty(line.productId, line.qty - 1)
					end
				end,
			}).Parent =
				stepper
			UI.text({
				Text = tostring(line.qty),
				FontFace = F.Heavy,
				TextXAlignment = Enum.TextXAlignment.Center,
				Position = UDim2.fromOffset(32, 0),
				Size = UDim2.fromOffset(32, 32),
				Parent = stepper,
			})
			UI.button({
				Text = "+",
				Style = "ghost",
				Position = UDim2.fromOffset(64, 0),
				Size = UDim2.fromOffset(32, 32),
				OnClick = function()
					if not pending then
						setQty(line.productId, line.qty + 1)
					end
				end,
			}).Parent =
				stepper
		end

		empty.Visible = #cart == 0
		subtotalValue.Text = money(result.subtotal)
		discountName.Visible = result.discount > 0
		discountValue.Visible = result.discount > 0
		discountName.Text = string.format("Discount (%d%%)", discount)
		discountValue.Text = "-" .. money(result.discount)
		taxName.Visible = Config.Tax.Enabled
		taxValue.Visible = Config.Tax.Enabled
		taxValue.Text = money(result.tax)
		totalValue.Text = money(result.total)
		updateCharge(result.total)
		updateTiles()
		schedulePreview()
	end

	local function showWaiting(visible: boolean)
		if visible and pending then
			waitTitle.Text = "Waiting for " .. pending.customer
			waitTotal.Text = money(pending.total)
			waiting.Visible = true
			waitScale.Scale = 0.95
			UI.tween(waitScale, { Scale = 1 }, Theme.TweenSlow)
			waitBar.Size = UDim2.fromScale(1, 1)
			waitBar.BackgroundColor3 = C.Accent
			UI.tween(
				waitBar,
				{ Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Warning },
				TweenInfo.new(Config.Checkout.PaymentTimeout, Enum.EasingStyle.Linear)
			)
			UI.setEnabled(cancelWait, true)
		else
			waiting.Visible = false
		end
	end

	local function closePicker()
		picker.Visible = false
	end

	local function openPicker()
		UI.clear(picker)
		picker.Visible = true
		UI.text({
			Text = "Looking for customers nearby…",
			TextSize = 14,
			TextColor3 = C.Muted,
			ZIndex = 9,
			Parent = picker,
		})
		local ok, nearby = Api.call("register.customers")
		if not picker.Visible then
			return
		end
		UI.clear(picker)
		if not ok then
			Toasts.show(nearby, "error")
			closePicker()
			return
		end
		if #nearby == 0 then
			UI.text({
				Text = "Nobody is at the counter. Ask the customer to stand at the register.",
				TextSize = 14,
				TextColor3 = C.Muted,
				TextWrapped = true,
				Size = UDim2.new(1, 0, 0, 40),
				ZIndex = 9,
				Parent = picker,
			})
		end
		for i, person in nearby do
			local option = UI.button({
				Text = string.format(
					"%s  ·  @%s%s",
					person.name,
					person.username,
					if person.isYou then "  (you)" else ""
				),
				Style = "ghost",
				Font = F.Medium,
				TextSize = 15,
				Size = UDim2.new(1, 0, 0, 38),
				LayoutOrder = i,
				ZIndex = 9,
				OnClick = function()
					customer = { userId = person.userId, name = person.name }
					closePicker()
					updateCustomerButton()
					renderCart()
				end,
			})
			option.TextXAlignment = Enum.TextXAlignment.Left
			UI.padding(0, 10).Parent = option
			option.Parent = picker
		end
		UI.button({
			Text = "↻ Refresh",
			Style = "ghost",
			TextSize = 13,
			Size = UDim2.new(1, 0, 0, 30),
			LayoutOrder = 100,
			ZIndex = 9,
			OnClick = function()
				task.spawn(openPicker)
			end,
		}).Parent =
			picker
	end

	------------------------------------------------------------------ wiring
	search:GetPropertyChangedSignal("Text"):Connect(function()
		query = search.Text
		renderGrid()
	end)

	clearButton.Activated:Connect(function()
		if pending then
			return
		end
		table.clear(cart)
		discount = 0
		customer = nil
		renderDiscounts()
		updateCustomerButton()
		renderCart()
	end)

	customerButton.Activated:Connect(function()
		if pending then
			return
		end
		if picker.Visible then
			closePicker()
		else
			task.spawn(openPicker)
		end
	end)

	charge.Activated:Connect(function()
		local action = charge:GetAttribute("Action")
		if charge:GetAttribute("Disabled") or pending then
			return
		elseif action == "shift" then
			ctx.go("shift")
		elseif action == "customer" then
			task.spawn(openPicker)
		elseif action == "charge" and customer then
			UI.setEnabled(charge, false)
			charge.Text = "Sending…"
			local ok, result = Api.call("checkout.start", payload(), discount, customer.userId)
			if ok then
				pending = { orderId = result.orderId, customer = result.customer, total = result.total }
				showWaiting(true)
			else
				Toasts.show(result, "error")
			end
			renderCart()
		end
	end)

	cancelWait.Activated:Connect(function()
		if pending then
			UI.setEnabled(cancelWait, false)
			local ok, err = Api.call("checkout.cancel", pending.orderId)
			if not ok then
				Toasts.show(err, "error")
				UI.setEnabled(cancelWait, true)
			end
		end
	end)

	function self.onOrderUpdate(update)
		if not pending or pending.orderId ~= update.orderId then
			return
		end
		pending = nil
		showWaiting(false)
		if update.status == "paid" then
			local sale = update.sale
			Toasts.show(string.format("Paid %s · %s", money(sale.total), sale.receipt), "success")
			table.clear(cart)
			discount = 0
			customer = nil
			renderDiscounts()
			updateCustomerButton()
			Receipt.showSale(ctx.overlay, sale)
		else
			Toasts.show(update.reason or "Payment was not completed", "warning")
		end
		renderCart()
	end

	function self.onClosed()
		pending = nil
		showWaiting(false)
		closePicker()
	end

	State.changed:Connect(function(key)
		if key == "catalogue" then
			-- Drop anything taken off sale, then redraw with new prices and stock.
			for i = #cart, 1, -1 do
				local product = State.byId[cart[i].productId]
				if not product or not product.active then
					table.remove(cart, i)
				end
			end
			renderGrid()
			renderCart()
		elseif key == "register" then
			renderCart()
		end
	end)

	function self.show()
		search.Text = query
	end

	renderChips()
	renderDiscounts()
	updateCustomerButton()
	renderGrid()
	renderCart()

	current = self
	return self
end

Api.on("OrderUpdate", function(update)
	if current then
		current.onOrderUpdate(update)
	end
end)

Api.on("CloseRegister", function()
	if current then
		current.onClosed()
	end
end)

return Sell
