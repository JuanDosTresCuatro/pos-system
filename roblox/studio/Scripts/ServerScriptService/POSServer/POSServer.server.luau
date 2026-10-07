-- RoPOS server bootstrap. Order matters: storage first, then data, then the world.

local Services = script.Services

local Store = require(Services.Store)
local Api = require(Services.Api)
local Staff = require(Services.Staff)
local Wallet = require(Services.Wallet)
local Audit = require(Services.Audit)
local Catalogue = require(Services.Catalogue)
local Reports = require(Services.Reports)
local Sales = require(Services.Sales)
local Demo = require(Services.Demo)
local Registers = require(Services.Registers)
local Checkout = require(Services.Checkout)

Store.init()
Staff.init()
Wallet.init()
Audit.init()
Catalogue.init()
Reports.init()
Sales.init()
Demo.setup()
Registers.init()
Checkout.init()
require(script.Handlers)
-- Remotes appear last, so a client never calls an action before its handler exists.
Api.init(Staff.roleOf)
Store.start()

print(
	string.format(
		"[RoPOS] Ready. %d register(s). Data %s.",
		#Registers.all(),
		if Store.persistent then "saved to DataStores" else "in memory only"
	)
)
