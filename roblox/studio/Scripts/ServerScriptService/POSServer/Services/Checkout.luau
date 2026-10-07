-- The payment handshake.
--
--   1. Cashier sends the cart. Server validates it, prices it from the live catalogue and sends
--      the customer a PaymentRequest.
--   2. Customer approves or declines on their own screen (or the request times out).
--   3. On approval the server re-prices, debits the wallet and takes the stock in one step with
--      no yields, then records the sale, hands over the items and sends both players the receipt.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Pricing = require(Shared.Pricing)
local Validate = require(Shared.Validate)
local Api = require(script.Parent.Api)
local Audit = require(script.Parent.Audit)
local Catalogue = require(script.Parent.Catalogue)
local Registers = require(script.Parent.Registers)
local Sales = require(script.Parent.Sales)
local Shifts = require(script.Parent.Shifts)
local Staff = require(script.Parent.Staff)
local Wallet = require(script.Parent.Wallet)

local Checkout = {}

export type Order = {
	id: string,
	register: Registers.Register,
	operator: Player,
	customer: Player,
	cart: { Validate.CartLine },
	discountPct: number,
	totals: Pricing.Totals,
	status: "pending" | "paid" | "declined" | "expired" | "cancelled",
	expiresAt: number,
}

local orders: { [string]: Order } = {}
local byCustomer: { [Player]: Order } = {}

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

local function selfCheckoutAllowed(): boolean
	local setting = Config.Checkout.AllowSelfCheckout
	if setting == "Studio" then
		return RunService:IsStudio()
	end
	return setting == true
end

-- Prices a validated cart from the live catalogue, or fails with a reason the cashier can act on.
function Checkout.price(cart: { Validate.CartLine }, discountPct: number): Pricing.Totals
	local lines: { Pricing.Line } = {}
	for _, line in cart do
		local product = Catalogue.get(line.productId)
		if not product or not product.active then
			Api.fail((if product then product.name else "An item") .. " is not available any more")
		end
		if product.stock ~= nil and line.qty > product.stock then
			Api.fail(
				if product.stock == 0
					then product.name .. " is sold out"
					else string.format("Only %d %s left", product.stock, product.name)
			)
		end
		table.insert(lines, {
			productId = product.id,
			name = product.name,
			unitPrice = product.price,
			qty = line.qty,
			taxRate = if Config.Tax.Enabled then product.taxRate else 0,
		})
	end
	return Pricing.priceLines(lines, { discountPct = discountPct, taxInclusive = Config.Tax.Inclusive })
end

-- What the customer's screen shows.
local function describe(order: Order)
	return {
		id = order.id,
		registerName = order.register.name,
		cashier = order.operator.DisplayName,
		lines = order.totals.lines,
		subtotal = order.totals.subtotal,
		discount = order.totals.discount,
		discountPct = order.discountPct,
		tax = order.totals.tax,
		total = order.totals.total,
		timeout = math.max(0, order.expiresAt - os.clock()),
	}
end

local function detach(order: Order)
	orders[order.id] = nil
	if byCustomer[order.customer] == order then
		byCustomer[order.customer] = nil
	end
	if order.register.order == order then
		order.register.order = nil
	end
end

local function finish(order: Order, status, reason: string)
	if order.status ~= "pending" then
		return
	end
	order.status = status
	detach(order)
	Api.push(order.operator, "OrderUpdate", { orderId = order.id, status = status, reason = reason })
	Api.push(order.customer, "PaymentClosed", { orderId = order.id, reason = reason })
	Registers.updateDisplay(order.register)
end

function Checkout.start(player: Player, register: Registers.Register, rawCart: any, rawDiscount: any, rawCustomer: any)
	if not register.shift then
		Api.fail("Open a shift before taking payments")
	end
	if register.order then
		Api.fail("This register is already waiting for a payment")
	end

	local cart, problem = Validate.cart(rawCart, Config.Checkout.MaxLines, Config.Checkout.MaxQty)
	if not cart then
		Api.fail(problem or "Invalid order")
	end
	local discountPct = Validate.int(rawDiscount, 0, 100)
	if not discountPct then
		Api.fail("Invalid discount")
	end
	if discountPct > Staff.maxDiscount(player) then
		Api.fail(string.format("Your discount limit is %d%%", Staff.maxDiscount(player)))
	end

	local customerId = Validate.int(rawCustomer, -1e15, 1e15)
	local customer = customerId and Players:GetPlayerByUserId(customerId)
	if not customer then
		Api.fail("Choose a customer")
	end
	if customer == player and not selfCheckoutAllowed() then
		Api.fail("You can't ring up your own order")
	end
	if Registers.distance(register, customer) > Config.Checkout.CustomerRange then
		Api.fail(customer.DisplayName .. " needs to stand at the register")
	end
	if byCustomer[customer] then
		Api.fail(customer.DisplayName .. " already has a payment waiting")
	end
	if not Wallet.ready(customer) then
		Api.fail(customer.DisplayName .. "'s wallet is still loading")
	end

	local totals = Checkout.price(cart, discountPct)
	local timeout = Config.Checkout.PaymentTimeout
	local order: Order = {
		id = HttpService:GenerateGUID(false),
		register = register,
		operator = player,
		customer = customer,
		cart = cart,
		discountPct = discountPct,
		totals = totals,
		status = "pending",
		expiresAt = os.clock() + timeout,
	}
	orders[order.id] = order
	byCustomer[customer] = order
	register.order = order

	Api.push(customer, "PaymentRequest", describe(order))
	Registers.updateDisplay(register)

	task.delay(timeout, function()
		finish(order, "expired", customer.DisplayName .. " did not respond in time")
	end)

	return { orderId = order.id, timeout = timeout, total = totals.total, customer = customer.DisplayName }
end

function Checkout.cancel(player: Player, orderId: any)
	local order = typeof(orderId) == "string" and orders[orderId]
	if not order or order.operator ~= player then
		Api.fail("That payment is no longer waiting")
	end
	finish(order, "cancelled", "The cashier cancelled the payment")
end

local function giveItems(customer: Player, lines: { Pricing.PricedLine })
	if not Config.Checkout.GiveItems then
		return
	end
	local folder = ServerStorage:FindFirstChild("POSItems")
	local backpack = customer:FindFirstChildOfClass("Backpack")
	if not folder or not backpack then
		return
	end
	for _, line in lines do
		local product = Catalogue.get(line.productId)
		local template = product and product.tool and folder:FindFirstChild(product.tool)
		if template and template:IsA("Tool") then
			for _ = 1, line.qty do
				template:Clone().Parent = backpack
			end
		end
	end
end

function Checkout.respond(customer: Player, orderId: any, accept: any)
	local order = typeof(orderId) == "string" and orders[orderId]
	if not order or order.customer ~= customer or order.status ~= "pending" then
		Api.fail("This payment is no longer available")
	end
	if accept ~= true then
		finish(order, "declined", customer.DisplayName .. " declined the payment")
		return { status = "declined" }
	end

	-- Prices or stock may have changed since the request. Never charge a different amount.
	local ok, repriced = pcall(Checkout.price, order.cart, order.discountPct)
	if not ok or repriced.total ~= order.totals.total then
		finish(order, "cancelled", "Prices or stock changed. Ring up the order again.")
		Api.fail("Prices or stock changed. The cashier needs to ring this up again.")
	end

	-- From here to the end of the stock loop nothing yields, so the debit and stock are atomic.
	if not Wallet.tryDebit(customer, order.totals.total) then
		Api.fail("You don't have enough " .. Config.Currency.StatName)
	end
	order.status = "paid"
	detach(order)
	for _, line in order.totals.lines do
		Catalogue.adjustStock(line.productId, -line.qty)
	end

	local register = order.register
	local operator = order.operator
	local commission = math.floor(order.totals.total * Config.Payouts.CashierCommissionPct / 100)
	if commission > 0 and operator ~= customer and operator.Parent then
		Wallet.credit(operator, commission)
	end

	local saleLines = {}
	for _, line in order.totals.lines do
		table.insert(saleLines, {
			productId = line.productId,
			name = line.name or line.productId,
			qty = line.qty,
			unitPrice = line.unitPrice,
			discount = line.discount,
			tax = line.tax,
			total = line.total,
		})
	end
	local sale: Sales.Sale = {
		receipt = "",
		t = os.time(),
		registerId = register.id,
		registerName = register.name,
		shiftId = if register.shift then register.shift.id else nil,
		cashier = { userId = operator.UserId, name = operator.DisplayName },
		customer = { userId = customer.UserId, name = customer.DisplayName },
		lines = saleLines,
		discountPct = order.discountPct,
		subtotal = order.totals.subtotal,
		discount = order.totals.discount,
		tax = order.totals.tax,
		total = order.totals.total,
		refunded = nil,
	}
	if register.shift then
		Shifts.recordSale(register.shift, sale)
	end
	giveItems(customer, order.totals.lines)
	Registers.flashPaid(register)

	Sales.record(sale) -- yields for the receipt number
	if order.discountPct > 0 then
		Audit.log(
			operator,
			"discount",
			string.format("%s: %d%% (%s off)", sale.receipt, order.discountPct, money(sale.discount))
		)
	end
	Audit.log(operator, "sale", string.format("%s: %s to %s", sale.receipt, money(sale.total), customer.Name))

	Api.push(operator, "OrderUpdate", { orderId = order.id, status = "paid", sale = sale })
	Api.push(customer, "Receipt", sale)
	Registers.refreshOperator(register)
	return { status = "paid", receipt = sale.receipt }
end

function Checkout.init()
	Registers.released:Connect(function(register, reason)
		if register.order then
			finish(register.order, "cancelled", reason)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		local order = byCustomer[player]
		if order then
			finish(order, "cancelled", player.DisplayName .. " left the game")
		end
	end)
end

return Checkout
