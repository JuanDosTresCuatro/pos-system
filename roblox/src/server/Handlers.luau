-- Every client action, in one place. Roles are checked by the router before a handler runs.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Roles = require(Shared.Roles)
local Validate = require(Shared.Validate)

local Services = script.Parent.Services
local Api = require(Services.Api)
local Audit = require(Services.Audit)
local Catalogue = require(Services.Catalogue)
local Checkout = require(Services.Checkout)
local Registers = require(Services.Registers)
local Reports = require(Services.Reports)
local Sales = require(Services.Sales)
local Shifts = require(Services.Shifts)
local Staff = require(Services.Staff)
local Store = require(Services.Store)
local Wallet = require(Services.Wallet)

local Cashier, Manager, Customer = Roles.Cashier, Roles.Manager, Roles.Customer

local function money(n: number): string
	return Format.money(n, Config.Currency.Symbol)
end

local function myRegister(player: Player): Registers.Register
	local register = Registers.of(player)
	if not register then
		Api.fail("Open a register first")
	end
	return register
end

local function product(id: any)
	local found = typeof(id) == "string" and Catalogue.get(id)
	if not found then
		Api.fail("Product not found")
	end
	return found
end

-- Session --------------------------------------------------------------------------------

Api.handle("session.hello", Customer, function(player)
	local role = Staff.roleOf(player)
	local register = Registers.of(player)
	return {
		role = role,
		roleName = Roles.name(role),
		maxDiscount = Staff.maxDiscount(player),
		persistent = Store.persistent,
		catalogue = if role >= Cashier then Catalogue.list() else nil,
		register = if register then Registers.summary(register) else nil,
	}
end)

-- Register -------------------------------------------------------------------------------

Api.handle("register.leave", Cashier, function(player)
	local register = Registers.of(player)
	if register then
		Registers.release(register, nil)
	end
end)

Api.handle("register.preview", Cashier, function(player, rawCart, rawDiscount)
	local register = myRegister(player)
	if register.order then
		return
	end
	local cart = Validate.cart(rawCart, Config.Checkout.MaxLines, Config.Checkout.MaxQty)
	local pct = math.min(Validate.int(rawDiscount, 0, 100) or 0, Staff.maxDiscount(player))
	if not cart then
		register.preview = nil
	else
		local ok, totals = pcall(Checkout.price, cart, pct)
		if ok then
			local items = 0
			for _, line in cart do
				items += line.qty
			end
			register.preview = { items = items, total = totals.total }
		end
	end
	Registers.updateDisplay(register)
end)

Api.handle("register.customers", Cashier, function(player)
	local register = myRegister(player)
	local nearby = {}
	for _, other in game:GetService("Players"):GetPlayers() do
		local distance = Registers.distance(register, other)
		if distance <= Config.Checkout.CustomerRange then
			table.insert(nearby, {
				userId = other.UserId,
				name = other.DisplayName,
				username = other.Name,
				isYou = other == player,
				distance = math.floor(distance + 0.5),
			})
		end
	end
	table.sort(nearby, function(a, b)
		if a.isYou ~= b.isYou then
			return not a.isYou
		end
		return a.distance < b.distance
	end)
	return nearby
end)

-- Shift ----------------------------------------------------------------------------------

Api.handle("shift.open", Cashier, function(player)
	local register = myRegister(player)
	if register.shift then
		Api.fail("A shift is already open on " .. register.name)
	end
	register.shift = Shifts.new(register.id, register.name, player)
	Audit.log(player, "shift.open", register.name)
	Registers.updateDisplay(register)
	return Registers.summary(register)
end)

Api.handle("shift.report", Cashier, function(player)
	return Registers.summary(myRegister(player))
end)

Api.handle("shift.close", Cashier, function(player)
	local register = myRegister(player)
	local shift = register.shift
	if not shift then
		Api.fail("No shift is open")
	end
	if register.order then
		Api.fail("Finish or cancel the waiting payment first")
	end
	local report = Shifts.close(shift, player.Name)
	register.shift = nil
	Audit.log(
		player,
		"shift.close",
		string.format("%s: %d sales, net %s", register.name, report.totals.count, money(report.net))
	)
	Registers.updateDisplay(register)
	return report
end)

-- Checkout -------------------------------------------------------------------------------

Api.handle("checkout.start", Cashier, function(player, cart, discount, customerId)
	return Checkout.start(player, myRegister(player), cart, discount, customerId)
end)

Api.handle("checkout.cancel", Cashier, function(player, orderId)
	Checkout.cancel(player, orderId)
end)

Api.handle("checkout.respond", Customer, function(player, orderId, accept)
	return Checkout.respond(player, orderId, accept)
end)

-- Sales ----------------------------------------------------------------------------------

Api.handle("sales.recent", Cashier, function(_player, limit)
	return Sales.recent(Validate.int(limit, 1, 200) or 50)
end)

Api.handle("sales.get", Cashier, function(_player, receipt)
	local id = Validate.text(receipt, 32)
	local sale = id and Sales.get(string.upper(id))
	if not sale then
		Api.fail("Receipt not found")
	end
	return sale
end)

Api.handle("sales.refund", Manager, function(player, receipt, restock)
	local id = Validate.text(receipt, 32)
	local sale = id and Sales.get(id)
	if not sale then
		Api.fail("Receipt not found")
	end
	if sale.refunded then
		Api.fail("This sale has already been refunded")
	end
	restock = restock == true

	local updated, problem = Sales.markRefunded(sale.receipt, player.Name, restock)
	if not updated then
		Api.fail(problem or "Refund failed")
	end
	local credited, creditProblem = Wallet.creditUserId(sale.customer.userId, sale.total)
	if not credited then
		Sales.unmarkRefunded(sale.receipt)
		Api.fail(creditProblem or "Could not return the money. Nothing was refunded.")
	end

	if restock then
		for _, line in sale.lines do
			Catalogue.adjustStock(line.productId, line.qty)
		end
	end
	Reports.recordRefund(sale, os.time())
	local register = Registers.of(player)
	if register and register.shift then
		Shifts.recordRefund(register.shift, sale)
		Registers.refreshOperator(register)
	end
	Audit.log(
		player,
		"refund",
		string.format(
			"%s: %s to %s%s",
			sale.receipt,
			money(sale.total),
			sale.customer.name,
			if restock then ", restocked" else ""
		)
	)

	local customer = game:GetService("Players"):GetPlayerByUserId(sale.customer.userId)
	if customer then
		Api.toast(customer, string.format("You were refunded %s for %s", money(sale.total), sale.receipt), "success")
	end
	return updated
end)

-- Products (manager) ---------------------------------------------------------------------

Api.handle("products.price", Manager, function(player, id, price)
	local item = product(id)
	local value = Validate.int(price, 0, 1e9)
	if not value then
		Api.fail("Enter a whole number price")
	end
	if value ~= item.price then
		Audit.log(player, "product.price", string.format("%s: %s -> %s", item.name, money(item.price), money(value)))
		Catalogue.setPrice(item.id, value)
	end
end)

Api.handle("products.stock", Manager, function(player, id, delta)
	local item = product(id)
	local change = Validate.int(delta, -1e6, 1e6)
	if not change or change == 0 then
		Api.fail("Invalid stock change")
	end
	if item.stock == nil then
		Api.fail(item.name .. " is not stock-tracked")
	end
	Audit.log(player, "stock.adjust", string.format("%s: %+d (was %d)", item.name, change, item.stock))
	Catalogue.adjustStock(item.id, change)
end)

Api.handle("products.active", Manager, function(player, id, active)
	local item = product(id)
	if typeof(active) ~= "boolean" then
		Api.fail("Invalid value")
	end
	Audit.log(player, "product.active", item.name .. (if active then " on sale" else " taken off sale"))
	Catalogue.setActive(item.id, active)
end)

-- Reports and audit (manager) ------------------------------------------------------------

Api.handle("reports.days", Manager, function(_player, count)
	return Reports.days(Validate.int(count, 1, 14) or 7)
end)

Api.handle("audit.recent", Manager, function(_player, limit)
	return Audit.recent(Validate.int(limit, 1, 500) or 100)
end)

-- Keep every staff screen in step with the catalogue.
Catalogue.changed:Connect(function()
	local snapshot = Catalogue.list()
	Api.pushWhere(Staff.isStaff, "Catalogue", snapshot)
end)

return {}
