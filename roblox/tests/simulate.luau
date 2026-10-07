-- End-to-end run of the real RoPOS server code on two simulated game servers that share one
-- set of DataStores. No Roblox needed:  lune run tests/simulate
--
-- Players are fake, but every request goes through the same Api router, handlers, services
-- and DataStore code that runs in a live game.

local process = require("@lune/process")
local task = require("@lune/task")

local Engine = require("./sim/Engine")
local Loader = require("./sim/Loader")

local ROOT = "."
local V3 = Engine.datatypes.Vector3.new
local AT_COUNTER = V3(-3, 3, -23.5) -- customer side of the demo counter
local BEHIND = V3(-3, 3, -28.5) -- staff side
local FAR = V3(0, 3, 80)

local passed, failed = 0, 0
local current = ""

local function step(name: string)
	current = name
	print("\n• " .. name)
end

local function check(condition: any, label: string, detail: any?)
	if condition then
		passed += 1
		print("    ✓ " .. label)
	else
		failed += 1
		print("    ✗ " .. label .. (if detail ~= nil then "  (got: " .. tostring(detail) .. ")" else ""))
	end
end

local function settle(seconds: number?)
	task.wait(seconds or 0.05)
end

local function ok(response, label: string)
	check(response.ok, label, response.error)
	return response.data
end

local function refused(response, pattern: string, label: string)
	check(
		not response.ok and string.find(response.error or "", pattern, 1, true) ~= nil,
		label,
		if response.ok then "accepted" else response.error
	)
end

local function cash(player): number
	return player.leaderstats.Cash.Value
end

local function count(list, name: string): number
	local n = 0
	for _, item in list do
		if item.Name == name then
			n += 1
		end
	end
	return n
end

------------------------------------------------------------------------ boot

local backend = Engine.newBackend()

local function boot(name: string)
	local engine = Engine.new(name, backend, { studio = false })
	local server = Loader.server(engine, ROOT, function(s)
		-- Live-game rules: roles from Config.Staff.Users, no self-checkout.
		local Config = s.sharedModule("Config")
		Config.Staff.Users = { [1] = "Manager", [2] = "Cashier", [4] = "Manager" }
	end)
	server.start()
	return server
end

step("Boot two game servers")
local A = boot("Server A")
local B = boot("Server B")
check(A.api ~= nil and B.api ~= nil, "both servers created their remotes")

local function display(server): string
	local screen = server.engine.workspace:FindFirstChild("RoPOS Counter"):FindFirstChild("Screen")
	return screen:FindFirstChild("Status", true).Text
end

local function prompt(server)
	return server.engine.workspace:FindFirstChild("RoPOS Counter"):FindFirstChild("Till"):FindFirstChild("RoPOSPrompt")
end

check(prompt(A) ~= nil, "demo counter built with a register prompt")
check(display(A) == "Closed", "register screen says Closed", display(A))

local ann = A.engine.addPlayer(1, "Ann", BEHIND)
local cass = A.engine.addPlayer(2, "Cass", BEHIND)
local bob = A.engine.addPlayer(3, "Bob", FAR)
local dee = B.engine.addPlayer(4, "Dee", BEHIND)
local eve = B.engine.addPlayer(5, "Eve", AT_COUNTER)
settle(0.2)
check(cash(bob) == 500 and cash(eve) == 500, "new customers start with 500 Cash")
check(
	ann:GetAttribute("POSRole") == "Manager" and bob:GetAttribute("POSRole") == "Customer",
	"roles exposed as POSRole"
)

------------------------------------------------------------------------ register

step("Only staff can use a register")
prompt(A).Triggered:Fire(bob)
settle()
local toast = A.engine.lastPush(bob, "Toast")
check(toast and string.find(toast.text, "Only staff", 1, true), "customer gets 'Only staff'")
prompt(A).Triggered:Fire(cass)
settle()
local opened = A.engine.lastPush(cass, "OpenRegister")
check(opened and opened.name == "Front Counter", "cashier opens Front Counter")
prompt(A).Triggered:Fire(ann)
settle()
toast = A.engine.lastPush(ann, "Toast")
check(toast and string.find(toast.text, "being used by Cass", 1, true), "second staff member is told it is in use")

local CART = { { productId = "latte", qty = 2 }, { productId = "bagel", qty = 1 } }

step("Checkout rules")
refused(A.call(cass, "checkout.start", CART, 0, 3), "Open a shift", "no payments before a shift is open")
ok(A.call(cass, "shift.open"), "cashier opens a shift")
refused(A.call(cass, "shift.open"), "already open", "cannot open a second shift")
refused(A.call(cass, "checkout.start", CART, 25, 3), "discount limit is 10%", "cashier discount capped at 10%")
refused(A.call(cass, "checkout.start", CART, 0, 3), "needs to stand at the register", "customer must be at the counter")
A.engine.moveTo(bob, AT_COUNTER)
refused(A.call(cass, "checkout.start", CART, 0, 2), "can't ring up your own", "no self-checkout in live games")

step("Malformed requests are rejected cleanly")
refused(A.call(cass, "checkout.start", "cart", 0, 3), "Invalid cart", "cart that is not a table")
refused(
	A.call(cass, "checkout.start", { { productId = "latte", qty = 1.5 } }, 0, 3),
	"Invalid cart line",
	"fractional quantity"
)
refused(
	A.call(cass, "checkout.start", { { productId = "latte", qty = 1 } }, 0 / 0, 3),
	"Invalid discount",
	"NaN discount"
)
refused(A.call(cass, "checkout.start", { { productId = "caviar", qty = 1 } }, 0, 3), "not available", "unknown product")
refused(A.call(cass, "checkout.start", CART, 0, "3"), "Choose a customer", "customer id as a string")
refused(
	A.call(cass, "checkout.start", { { productId = "latte", qty = 99 } }, 0, 3),
	"Invalid cart line",
	"quantity over the limit"
)
refused(A.call(cass, "no.such.action"), "Unknown action", "unknown action")
refused(A.call(cass, 42), "Bad request", "non-string action")

------------------------------------------------------------------------ payment

step("Customer approves a payment")
local started = ok(A.call(cass, "checkout.start", CART, 0, 3), "cashier charges Bob")
local request = A.engine.lastPush(bob, "PaymentRequest")
check(request and request.total == 82, "Bob sees a bill for 82 (2 x 28 + 26)", request and request.total)
check(display(A) == "Please approve", "register screen asks the customer to approve", display(A))
refused(A.call(cass, "checkout.start", CART, 0, 3), "already waiting", "one payment at a time per register")
local paid = ok(A.call(bob, "checkout.respond", started.orderId, true), "Bob pays")
settle()
check(cash(bob) == 418, "Bob's Cash goes from 500 to 418", cash(bob))
local items = bob.Backpack:GetChildren()
check(
	count(items, "Caramel Latte") == 2 and count(items, "Everything Bagel") == 1,
	"Bob receives 2 lattes and 1 bagel as Tools"
)
local update = A.engine.lastPush(cass, "OrderUpdate")
check(
	update and update.status == "paid" and update.sale.receipt == "BB-000001",
	"cashier gets receipt BB-000001",
	update and update.sale and update.sale.receipt
)
check(A.engine.lastPush(bob, "Receipt") ~= nil, "Bob gets the receipt")
check(paid.receipt == "BB-000001", "response carries the receipt number")
check(A.module("Services.Catalogue").get("bagel").stock == 3, "bagel stock 4 -> 3")
check(display(A) == "Thank you!", "register screen says Thank you!", display(A))
refused(
	A.call(bob, "checkout.respond", started.orderId, true),
	"no longer available",
	"the same payment cannot be approved twice"
)

step("Decline, cancel and timeout")
local o = ok(A.call(cass, "checkout.start", { { productId = "espresso", qty = 1 } }, 0, 3), "charge an espresso")
ok(A.call(bob, "checkout.respond", o.orderId, false), "Bob declines")
check(A.engine.lastPush(cass, "OrderUpdate").status == "declined", "cashier sees declined")
o = ok(A.call(cass, "checkout.start", { { productId = "espresso", qty = 1 } }, 0, 3), "charge again")
ok(A.call(cass, "checkout.cancel", o.orderId), "cashier cancels")
check(A.engine.lastPush(bob, "PaymentClosed") ~= nil, "Bob's payment screen closes")
local Config = A.sharedModule("Config")
Config.Checkout.PaymentTimeout = 0.3
o = ok(A.call(cass, "checkout.start", { { productId = "espresso", qty = 1 } }, 0, 3), "charge with a short timeout")
settle(0.5)
check(A.engine.lastPush(cass, "OrderUpdate").status == "expired", "payment expires")
refused(A.call(bob, "checkout.respond", o.orderId, true), "no longer available", "expired payment cannot be paid")
Config.Checkout.PaymentTimeout = 30
check(cash(bob) == 418, "Bob was not charged for any of these", cash(bob))

step("Not enough money, and prices changing mid-payment")
o = ok(A.call(cass, "checkout.start", { { productId = "giftcard", qty = 2 } }, 0, 3), "charge 500 for 2 gift cards")
refused(A.call(bob, "checkout.respond", o.orderId, true), "don't have enough Cash", "Bob cannot pay 500 with 418")
ok(A.call(cass, "checkout.cancel", o.orderId), "cashier cancels it")
o = ok(A.call(cass, "checkout.start", { { productId = "latte", qty = 1 } }, 0, 3), "charge a latte at 28")
ok(A.call(ann, "products.price", "latte", 30), "manager raises the latte to 30 meanwhile")
refused(
	A.call(bob, "checkout.respond", o.orderId, true),
	"Prices or stock changed",
	"approval refused instead of charging a different amount"
)
check(cash(bob) == 418, "Bob still has 418", cash(bob))

step("Permissions")
refused(A.call(cass, "products.price", "latte", 1), "permission", "cashier cannot change prices")
refused(A.call(cass, "sales.refund", "BB-000001", true), "permission", "cashier cannot refund")
refused(A.call(bob, "sales.recent"), "permission", "customer cannot read sales")
refused(A.call(bob, "checkout.start", CART, 0, 3), "permission", "customer cannot charge anyone")

step("Refunds")
local refundedSale = ok(A.call(ann, "sales.refund", "BB-000001", true), "manager refunds BB-000001 with restock")
check(refundedSale and refundedSale.refunded and refundedSale.refunded.by == "ann", "sale marked refunded by ann")
check(cash(bob) == 500, "Bob gets 82 back", cash(bob))
check(A.module("Services.Catalogue").get("bagel").stock == 4, "bagel returned to stock")
refused(A.call(ann, "sales.refund", "BB-000001", true), "already been refunded", "second refund refused")
check(string.find(A.engine.lastPush(bob, "Toast").text, "refunded $82", 1, true), "Bob is told about the refund")

------------------------------------------------------------------------ multi-server

step("Stock and prices stay correct across servers")
A.module("Services.Store").flushAll()
settle(0.1)
check(B.module("Services.Catalogue").get("latte").price == 30, "server B picks up the new latte price")
prompt(B).Triggered:Fire(dee)
settle()
ok(B.call(dee, "shift.open"), "Dee opens a shift on server B")
local eveOrder =
	ok(B.call(dee, "checkout.start", { { productId = "bagel", qty = 1 } }, 0, 5), "Dee charges Eve for 1 bagel")
local eveSale = ok(B.call(eve, "checkout.respond", eveOrder.orderId, true), "Eve pays on server B")
local bobOrder =
	ok(A.call(cass, "checkout.start", { { productId = "bagel", qty = 2 } }, 0, 3), "Cass charges Bob for 2 bagels")
local bobSale = ok(A.call(bob, "checkout.respond", bobOrder.orderId, true), "Bob pays on server A")
A.module("Services.Store").flushAll()
settle(0.1)
B.module("Services.Store").flushAll()
settle(0.1)
local stored = backend.data.RoPOS_Catalogue_v1.products.products.bagel.stock
check(stored == 1, "saved bagel stock is 4 - 1 - 2 = 1", stored)
check(
	A.module("Services.Catalogue").get("bagel").stock == 1,
	"server A shows 1 bagel",
	A.module("Services.Catalogue").get("bagel").stock
)
check(
	B.module("Services.Catalogue").get("bagel").stock == 1,
	"server B shows 1 bagel",
	B.module("Services.Catalogue").get("bagel").stock
)
refused(
	A.call(cass, "checkout.start", { { productId = "bagel", qty = 2 } }, 0, 3),
	"Only 1 Everything Bagel left",
	"cannot sell stock another server sold"
)
check(
	eveSale.receipt == "BB-000002" and bobSale.receipt == "BB-000003",
	"receipt numbers continue across servers (BB-000002 on B, BB-000003 on A)",
	eveSale.receipt .. ", " .. bobSale.receipt
)

step("Refund to a customer who has left, from another server")
B.engine.removePlayer(eve)
settle(0.1)
check(
	backend.data.RoPOS_Wallets_v1.u5.balance == 474,
	"Eve's 474 is saved when she leaves",
	backend.data.RoPOS_Wallets_v1.u5.balance
)
ok(A.call(ann, "sales.refund", eveSale.receipt, false), "Ann on server A refunds Eve's sale from server B")
local eveAgain = B.engine.addPlayer(5, "Eve", AT_COUNTER)
settle(0.2)
check(cash(eveAgain) == 500, "Eve rejoins with 500", cash(eveAgain))

step("Reports, sales history and audit log merge every server")
A.module("Services.Store").flushAll()
B.module("Services.Store").flushAll()
settle(0.1)
local days = ok(B.call(dee, "reports.days", 7), "Dee reads the 7-day report on server B")
local today = days and days[#days].totals
check(today and today.count == 3, "3 sales today across both servers", today and today.count)
check(today and today.sales == 82 + 52 + 26, "160 taken", today and today.sales)
check(today and today.refunds == 82 + 26, "108 refunded", today and today.refunds)
check(
	today and today.products.bagel.qty == 4,
	"4 bagels sold",
	today and today.products.bagel and today.products.bagel.qty
)
local recent = ok(A.call(cass, "sales.recent", 50), "Cass reads recent sales")
check(recent and #recent == 3, "3 receipts listed", recent and #recent)
local flagged = 0
for _, summary in recent or {} do
	if summary.refunded then
		flagged += 1
	end
end
check(flagged == 2, "2 of them flagged refunded", flagged)
local audit = ok(A.call(ann, "audit.recent", 100), "Ann reads the audit log")
local actions = {}
for _, entry in audit or {} do
	actions[entry.action] = (actions[entry.action] or 0) + 1
end
check(
	actions.sale == 3 and actions.refund == 2 and actions["product.price"] == 1 and actions["shift.open"] == 2,
	"audit has 3 sales, 2 refunds, 1 price change, 2 shift opens"
)

step("Shift close and Z report")
local z = ok(A.call(cass, "shift.close"), "Cass closes the shift")
check(z and z.totals.count == 2 and z.totals.sales == 134 and z.net == 134, "Z report: 2 sales, 134 net", z and z.net)
check(z and z.topProducts[1].id == "bagel", "top item is bagel", z and z.topProducts[1] and z.topProducts[1].id)

step("Rate limiting")
local slowed = false
for _ = 1, 40 do
	local r = A.call(cass, "shift.report")
	if not r.ok and string.find(r.error, "Slow down", 1, true) then
		slowed = true
	end
end
check(slowed, "40 rapid requests get 'Slow down'")

step("Walking away signs the cashier out")
settle(4.2) -- let the 4 s "Thank you!" flash finish
check(display(A) == "Closed", "register screen says Closed after the shift", display(A))
A.engine.moveTo(cass, FAR)
settle(1.3)
check(A.engine.lastPush(cass, "CloseRegister") ~= nil, "cashier signed out of the register")
check(display(A) == "Closed", "register screen still says Closed", display(A))

step("DataStore outage")
ok(A.call(ann, "products.stock", "mug", 5), "manager restocks 5 mugs")
backend.failNext = 1
A.module("Services.Store").flushAll()
check(
	backend.data.RoPOS_Catalogue_v1.products.products.mug.stock == 15,
	"the write is retried and lands",
	backend.data.RoPOS_Catalogue_v1.products.products.mug.stock
)

step("Shutdown saves everything")
A.call(ann, "products.active", "giftcard", false)
A.engine.shutdown()
check(backend.data.RoPOS_Catalogue_v1.products.products.giftcard.active == false, "BindToClose flushes pending changes")

step("Two managers on two servers refund the same sale at the same moment")
-- Both managers have the receipt open first, so only the DataStore guard can stop the second.
ok(A.call(ann, "sales.get", bobSale.receipt), "Ann opens the receipt on server A")
ok(B.call(dee, "sales.get", bobSale.receipt), "Dee opens the same receipt on server B")
local before = cash(bob)
local results = {}
local finished = 0
task.spawn(function()
	results.A = A.call(ann, "sales.refund", bobSale.receipt, false)
	finished += 1
end)
task.spawn(function()
	results.B = B.call(dee, "sales.refund", bobSale.receipt, false)
	finished += 1
end)
while finished < 2 do
	settle(0.01)
end
local wins = (if results.A.ok then 1 else 0) + (if results.B.ok then 1 else 0)
check(wins == 1, "exactly one refund succeeds", wins)
check(cash(bob) == before + 52, "Bob is refunded 52 once", cash(bob) - before)

step("No unexpected warnings")
for _, server in { A, B } do
	for _, message in server.engine.warnings do
		print("    warning on " .. server.engine.name .. ": " .. message)
	end
end
check(#A.engine.warnings == 0 and #B.engine.warnings == 0, "no warnings on either server")

print(string.format("\nRoPOS simulation: %d passed, %d failed", passed, failed))
process.exit(if failed == 0 then 0 else 1)
