-- RoPOS configuration. Most games only need to edit this file.
-- Money is always a whole number in your game's currency (no decimals).

local Config = {}

Config.Store = {
	Name = "Blox Mart",
	ReceiptPrefix = "BM",
	Footer = "Thanks for shopping at Blox Mart!",
}

Config.Currency = {
	-- "Builtin":     RoPOS creates and saves a leaderstats currency for you.
	-- "Leaderstats": RoPOS uses an IntValue/NumberValue your game already creates under
	--                player.leaderstats, and leaves saving to your game.
	Provider = "Builtin",
	StatName = "Cash",
	Symbol = "£", -- whole pounds, like every Roblox currency
	StartingBalance = 100,
}

Config.Tax = {
	Enabled = false,
	Name = "VAT",
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
	-- Build a shop counter if the place has no register tagged "POSRegister".
	SpawnRegister = true,
	-- Create simple item Tools for products that have no Tool in ServerStorage.POSItems.
	CreateItemTools = true,
}

Config.RegisterTag = "POSRegister"

Config.Categories = { "Snacks", "Gear", "Tools", "Cosmetics" }

-- Id must be unique and must never change (sales and stock refer to it).
-- Price is in whole pounds. Stock = nil means the product is not stock-tracked.
-- TaxRate is a percentage (20 = UK standard VAT) and is used only when Config.Tax.Enabled is true.
-- Tool is the name of a Tool in ServerStorage.POSItems that the customer receives.
local rgb = Color3.fromRGB
Config.Products = {
	-- Snacks
	{
		Id = "bloxycola",
		Name = "Bloxy Cola",
		Category = "Snacks",
		Price = 3,
		TaxRate = 20,
		Colour = rgb(196, 40, 28),
		Tool = "Bloxy Cola",
	},
	{
		Id = "pizza",
		Name = "Pizza Slice",
		Category = "Snacks",
		Price = 4,
		TaxRate = 20,
		Colour = rgb(245, 180, 60),
		Tool = "Pizza Slice",
	},
	{
		Id = "cheezburger",
		Name = "Cheezburger",
		Category = "Snacks",
		Price = 5,
		TaxRate = 20,
		Colour = rgb(170, 110, 60),
		Tool = "Cheezburger",
	},
	{
		Id = "taco",
		Name = "Taco",
		Category = "Snacks",
		Price = 3,
		TaxRate = 20,
		Colour = rgb(230, 190, 90),
		Tool = "Taco",
	},
	{
		Id = "icecream",
		Name = "Ice Cream Cone",
		Category = "Snacks",
		Price = 2,
		TaxRate = 20,
		Colour = rgb(255, 170, 200),
		Tool = "Ice Cream Cone",
	},
	-- Gear
	{
		Id = "gravitycoil",
		Name = "Gravity Coil",
		Category = "Gear",
		Price = 25,
		TaxRate = 20,
		Stock = 10,
		Colour = rgb(120, 80, 220),
		Tool = "Gravity Coil",
	},
	{
		Id = "speedcoil",
		Name = "Speed Coil",
		Category = "Gear",
		Price = 25,
		TaxRate = 20,
		Stock = 10,
		Colour = rgb(40, 200, 120),
		Tool = "Speed Coil",
	},
	{
		Id = "grapplehook",
		Name = "Grapple Hook",
		Category = "Gear",
		Price = 30,
		TaxRate = 20,
		Stock = 6,
		Colour = rgb(90, 100, 120),
		Tool = "Grapple Hook",
	},
	{
		Id = "magiccarpet",
		Name = "Magic Carpet",
		Category = "Gear",
		Price = 60,
		TaxRate = 20,
		Stock = 3,
		Colour = rgb(170, 40, 90),
		Tool = "Magic Carpet",
	},
	{
		Id = "jetpack",
		Name = "Jetpack",
		Category = "Gear",
		Price = 80,
		TaxRate = 20,
		Stock = 2,
		Colour = rgb(160, 165, 175),
		Tool = "Jetpack",
	},
	-- Tools
	{
		Id = "sword",
		Name = "Linked Sword",
		Category = "Tools",
		Price = 15,
		TaxRate = 20,
		Colour = rgb(200, 205, 215),
		Tool = "Linked Sword",
	},
	{
		Id = "paintball",
		Name = "Paintball Gun",
		Category = "Tools",
		Price = 20,
		TaxRate = 20,
		Colour = rgb(30, 140, 230),
		Tool = "Paintball Gun",
	},
	{
		Id = "slingshot",
		Name = "Slingshot",
		Category = "Tools",
		Price = 8,
		TaxRate = 20,
		Colour = rgb(130, 85, 50),
		Tool = "Slingshot",
	},
	{
		Id = "flashlight",
		Name = "Flashlight",
		Category = "Tools",
		Price = 5,
		TaxRate = 20,
		Colour = rgb(250, 220, 90),
		Tool = "Flashlight",
	},
	{
		Id = "boombox",
		Name = "Boombox",
		Category = "Tools",
		Price = 12,
		TaxRate = 20,
		Stock = 4,
		Colour = rgb(45, 45, 55),
		Tool = "Boombox",
	},
	-- Cosmetics
	{
		Id = "partyhat",
		Name = "Party Hat",
		Category = "Cosmetics",
		Price = 6,
		TaxRate = 20,
		Colour = rgb(255, 90, 160),
		Tool = "Party Hat",
	},
	{
		Id = "tophat",
		Name = "Top Hat",
		Category = "Cosmetics",
		Price = 10,
		TaxRate = 20,
		Colour = rgb(25, 25, 30),
		Tool = "Top Hat",
	},
	{
		Id = "sparkletrail",
		Name = "Sparkle Trail",
		Category = "Cosmetics",
		Price = 18,
		TaxRate = 20,
		Stock = 15,
		Colour = rgb(120, 220, 255),
	},
	{
		Id = "crown",
		Name = "Golden Crown",
		Category = "Cosmetics",
		Price = 150,
		TaxRate = 20,
		Colour = rgb(240, 190, 40),
		Tool = "Golden Crown",
	},
}

return Config
