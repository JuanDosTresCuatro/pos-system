-- Products (managers): prices, stock adjustments and on/off sale. Changes reach every server.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)

local Client = script.Parent.Parent
local Api = require(Client.Api)
local State = require(Client.State)
local UI = require(Client.UI.UI)
local Theme = require(Client.UI.Theme)
local Toasts = require(Client.UI.Toasts)

local C, F = Theme.Colors, Theme.Fonts

local Products = {}

local function call(action: string, ...: any)
	local ok, err = Api.call(action, ...)
	if not ok then
		Toasts.show(err, "error")
	end
	return ok
end

function Products.new(_ctx)
	local self = {}
	local frame = UI.new("Frame", { Name = "Products", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
	self.frame = frame

	UI.text({ Text = "Products", TextSize = 24, FontFace = F.Heavy, Size = UDim2.new(0.5, 0, 0, 30), Parent = frame })
	UI.text({
		Text = "Names, categories and tools live in Config.Products. Price, stock and availability are saved here.",
		TextSize = 14,
		TextColor3 = C.Muted,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = frame,
	})

	local list = UI.scroll({
		Position = UDim2.fromOffset(0, 62),
		Size = UDim2.new(1, 0, 1, -62),
		Parent = frame,
		Children = { UI.list(6) },
	})

	local function render()
		UI.clear(list)
		for i, product in State.catalogue do
			local row = UI.new("Frame", {
				Name = product.id,
				BackgroundColor3 = C.Raised,
				BackgroundTransparency = if product.active then 0 else 0.5,
				Size = UDim2.new(1, -8, 0, 60),
				LayoutOrder = i,
				Parent = list,
				Children = {
					UI.corner(Theme.Radius.Medium),
					UI.new("Frame", {
						BackgroundColor3 = product.colour,
						Position = UDim2.new(0, 14, 0.5, -14),
						Size = UDim2.fromOffset(28, 28),
						Children = { UI.corner(8) },
					}),
					UI.text({
						Text = product.name,
						FontFace = F.Bold,
						Position = UDim2.fromOffset(54, 10),
						Size = UDim2.new(0.3, -54, 0, 20),
					}),
					UI.text({
						Text = product.category .. "  ·  " .. product.id,
						TextSize = 13,
						TextColor3 = C.Muted,
						Position = UDim2.fromOffset(54, 30),
						Size = UDim2.new(0.3, -54, 0, 18),
					}),
				},
			})

			-- Price
			UI.text({
				Text = Config.Currency.Symbol,
				TextColor3 = C.Muted,
				Position = UDim2.new(0.3, 0, 0.5, -10),
				Size = UDim2.fromOffset(14, 20),
				Parent = row,
			})
			local price = UI.input({
				Text = tostring(product.price),
				TextXAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.new(0.3, 16, 0.5, -18),
				Size = UDim2.fromOffset(96, 36),
			})
			price.Parent = row
			price.FocusLost:Connect(function()
				local value = tonumber(price.Text)
				if value and value >= 0 and value % 1 == 0 then
					if value ~= product.price and call("products.price", product.id, value) then
						Toasts.show(
							product.name .. " now costs " .. Format.money(value, Config.Currency.Symbol),
							"success"
						)
					end
				else
					Toasts.show("Enter a whole number price", "warning")
					price.Text = tostring(product.price)
				end
			end)

			-- Stock
			local stock = UI.new("Frame", {
				BackgroundTransparency = 1,
				Position = UDim2.new(0.52, 0, 0.5, -18),
				Size = UDim2.fromOffset(250, 36),
				Parent = row,
				Children = {
					UI.list(6, Enum.FillDirection.Horizontal, { VerticalAlignment = Enum.VerticalAlignment.Center }),
				},
			})
			if product.stock == nil then
				UI.text({
					Text = "Not stock-tracked",
					TextColor3 = C.Faint,
					TextSize = 14,
					Size = UDim2.fromOffset(200, 36),
					Parent = stock,
				})
			else
				for order, delta in { -10, -1 } do
					UI.button({
						Text = tostring(delta),
						TextSize = 13,
						Size = UDim2.fromOffset(42, 32),
						LayoutOrder = order,
						Parent = stock,
						OnClick = function()
							call("products.stock", product.id, delta)
						end,
					})
				end
				local low = product.stock <= Config.Inventory.LowStockAt
				UI.text({
					Text = tostring(product.stock),
					FontFace = F.Heavy,
					TextSize = 18,
					TextColor3 = if product.stock == 0 then C.Danger elseif low then C.Warning else C.Text,
					TextXAlignment = Enum.TextXAlignment.Center,
					Size = UDim2.fromOffset(52, 32),
					LayoutOrder = 3,
					Parent = stock,
				})
				for order, delta in { 1, 10 } do
					UI.button({
						Text = "+" .. delta,
						TextSize = 13,
						Size = UDim2.fromOffset(42, 32),
						LayoutOrder = 3 + order,
						Parent = stock,
						OnClick = function()
							call("products.stock", product.id, delta)
						end,
					})
				end
			end

			-- On sale toggle
			UI.button({
				Text = if product.active then "On sale" else "Off sale",
				Style = if product.active then "success" else "secondary",
				TextSize = 14,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -14, 0.5, 0),
				Size = UDim2.fromOffset(96, 34),
				Radius = Theme.Radius.Pill,
				Parent = row,
				OnClick = function()
					call("products.active", product.id, not product.active)
				end,
			})
		end
	end

	State.changed:Connect(function(key)
		if key == "catalogue" and frame.Visible then
			-- Do not redraw while someone is typing a price.
			local focused = game:GetService("UserInputService"):GetFocusedTextBox()
			if not (focused and focused:IsDescendantOf(list)) then
				render()
			end
		end
	end)

	self.show = render
	return self
end

return Products
