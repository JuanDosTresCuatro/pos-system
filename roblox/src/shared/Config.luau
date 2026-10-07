-- RoPOS configuration. Most games only need to edit this file.
-- Money is always a whole number in your game's currency (no decimals).

local Config = {}

Config.Store = {
	Name = "Brickbrew Café",
	ReceiptPrefix = "BB",
	Footer = "Thanks for visiting. See you soon!",
}

Config.Currency = {
	-- "Builtin":     RoPOS creates and saves a leaderstats currency for you.
	-- "Leaderstats": RoPOS uses an IntValue/NumberValue your game already creates under
	--                player.leaderstats, and leaves saving to your game.
	Provider = "Builtin",
	StatName = "Cash",
	Symbol = "$",
	StartingBalance = 500,
}

Config.Tax = {
	Enabled = false,
	Name = "Sales tax",
	-- true: prices already include tax. false: tax is added on top at checkout.
	Inclusive = true,
}

Config.Staff = {
	-- Roblox group that owns the shop. 0 = no group.
	GroupId = 0,
	ManagerRank = 250,
	CashierRank = 10,
	-- Per-user overrides: [UserId] = "Manager" | "Cashier"
	Users = {
		-- [123456789] = "Manager",
	},
	-- The place owner (user-owned games) or group owner (rank 255) is always a manager.
	OwnerIsManager = true,
	-- Role everyone gets during Studio play tests. nil = use the normal rules.
	StudioRole = "Manager",
}

Config.Discounts = {
	Presets = { 0, 5, 10, 15, 25, 50 },
	CashierMaxPct = 10,
	ManagerMaxPct = 100,
}

Config.Checkout = {
	-- Distances are in studs (1 stud is about 0.28 m).
	CustomerRange = 16, -- customer must stand within this distance of the register (about 4.5 m)
	OperatorRange = 20, -- cashier is signed out of the register beyond this distance (about 5.6 m)
	PaymentTimeout = 30, -- seconds the customer has to approve a payment
	MaxLines = 20,
	MaxQty = 20,
	-- Let a cashier charge themselves. "Studio" = only during play tests.
	AllowSelfCheckout = "Studio",
	-- Clone the product's Tool from ServerStorage.POSItems into the customer's Backpack.
	GiveItems = true,
}

Config.Payouts = {
	-- Percentage of each sale paid to the cashier who rang it up. This creates new
	-- currency, so keep it at 0 unless your game economy plans for it.
	CashierCommissionPct = 0,
}

Config.Inventory = {
	LowStockAt = 5,
}

Config.Data = {
	-- Change the scope to start with fresh data (for example "v2").
	Scope = "v1",
	FlushInterval = 20, -- seconds between batched DataStore writes
}

Config.Demo = {
	-- Build a café counter if the place has no register tagged "POSRegister".
	SpawnRegister = true,
	-- Create simple item Tools for products that have no Tool in ServerStorage.POSItems.
	CreateItemTools = true,
}

Config.RegisterTag = "POSRegister"

Config.Categories = { "Coffee", "Tea & Cold", "Bakery", "Merch" }

-- Id must be unique and must never change (sales and stock refer to it).
-- Stock = nil means the product is not stock-tracked.
-- TaxRate is a percentage and is used only when Config.Tax.Enabled is true.
Config.Products = {
	{
		Id = "espresso",
		Name = "Espresso",
		Category = "Coffee",
		Price = 15,
		TaxRate = 20,
		Colour = Color3.fromRGB(92, 60, 40),
		Tool = "Espresso",
	},
	{
		Id = "latte",
		Name = "Caramel Latte",
		Category = "Coffee",
		Price = 28,
		TaxRate = 20,
		Colour = Color3.fromRGB(201, 150, 99),
		Tool = "Caramel Latte",
	},
	{
		Id = "flatwhite",
		Name = "Flat White",
		Category = "Coffee",
		Price = 24,
		TaxRate = 20,
		Colour = Color3.fromRGB(226, 196, 160),
		Tool = "Flat White",
	},
	{
		Id = "mocha",
		Name = "Mocha",
		Category = "Coffee",
		Price = 30,
		TaxRate = 20,
		Colour = Color3.fromRGB(120, 72, 48),
		Tool = "Mocha",
	},
	{
		Id = "matcha",
		Name = "Matcha Latte",
		Category = "Tea & Cold",
		Price = 32,
		TaxRate = 20,
		Colour = Color3.fromRGB(129, 178, 92),
		Tool = "Matcha Latte",
	},
	{
		Id = "icedtea",
		Name = "Peach Iced Tea",
		Category = "Tea & Cold",
		Price = 18,
		TaxRate = 20,
		Colour = Color3.fromRGB(245, 166, 98),
		Tool = "Peach Iced Tea",
	},
	{
		Id = "smoothie",
		Name = "Berry Smoothie",
		Category = "Tea & Cold",
		Price = 35,
		TaxRate = 20,
		Colour = Color3.fromRGB(196, 68, 120),
		Tool = "Berry Smoothie",
	},
	{
		Id = "croissant",
		Name = "Butter Croissant",
		Category = "Bakery",
		Price = 20,
		TaxRate = 0,
		Stock = 30,
		Colour = Color3.fromRGB(232, 178, 82),
		Tool = "Butter Croissant",
	},
	{
		Id = "cookie",
		Name = "Choc Chip Cookie",
		Category = "Bakery",
		Price = 12,
		TaxRate = 0,
		Stock = 40,
		Colour = Color3.fromRGB(176, 120, 70),
		Tool = "Choc Chip Cookie",
	},
	{
		Id = "muffin",
		Name = "Blueberry Muffin",
		Category = "Bakery",
		Price = 22,
		TaxRate = 0,
		Stock = 24,
		Colour = Color3.fromRGB(110, 98, 170),
		Tool = "Blueberry Muffin",
	},
	{
		Id = "bagel",
		Name = "Everything Bagel",
		Category = "Bakery",
		Price = 26,
		TaxRate = 0,
		Stock = 4,
		Colour = Color3.fromRGB(205, 160, 110),
		Tool = "Everything Bagel",
	},
	{
		Id = "mug",
		Name = "Brickbrew Mug",
		Category = "Merch",
		Price = 120,
		TaxRate = 20,
		Stock = 10,
		Colour = Color3.fromRGB(240, 240, 240),
		Tool = "Brickbrew Mug",
	},
	{
		Id = "beans",
		Name = "House Beans 250 g",
		Category = "Merch",
		Price = 90,
		TaxRate = 0,
		Stock = 15,
		Colour = Color3.fromRGB(70, 45, 30),
	},
	{
		Id = "giftcard",
		Name = "Gift Card",
		Category = "Merch",
		Price = 250,
		TaxRate = 0,
		Colour = Color3.fromRGB(88, 130, 255),
	},
}

return Config
