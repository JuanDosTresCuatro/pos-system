-- Products: fixed details come from Config.Products; price, active flag and stock are saved.
--
-- Changes are queued as operations ({ kind = "stock", delta = -2 }) and applied inside an
-- UpdateAsync transform, so stock sold on several servers at once adds up correctly.
-- The live view is always: last stored document + operations in flight + operations pending.

local MessagingService = game:GetService("MessagingService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Signal = require(Shared.Signal)
local Store = require(script.Parent.Store)

local Catalogue = {}
Catalogue.changed = Signal.new()

export type Product = {
	id: string,
	name: string,
	category: string,
	colour: Color3,
	taxRate: number,
	tool: string?,
	price: number,
	active: boolean,
	stock: number?, -- nil = not stock-tracked
}

type Op = { kind: "stock" | "price" | "active", id: string, value: any }

type Doc = { version: number, products: { [string]: { price: number?, active: boolean?, stock: number? } } }

local STORE, KEY, TOPIC = "Catalogue", "products", "RoPOS_Catalogue"

local seeds = {}
local order: { string } = {}
local products: { [string]: Product } = {}

local storedDoc: Doc = { version = 0, products = {} }
local inflight: { Op } = {}
local pending: { Op } = {}
local changeQueued = false

for _, seed in Config.Products do
	assert(seeds[seed.Id] == nil, "Duplicate product id " .. seed.Id)
	seeds[seed.Id] = seed
	table.insert(order, seed.Id)
end

local function applyOp(doc: Doc, op: Op)
	local seed = seeds[op.id]
	if not seed then
		return
	end
	local entry = doc.products[op.id]
	if not entry then
		entry = {}
		doc.products[op.id] = entry
	end
	if op.kind == "stock" then
		if seed.Stock ~= nil then
			entry.stock = math.max(0, (entry.stock or seed.Stock) + op.value)
		end
	elseif op.kind == "price" then
		entry.price = op.value
	elseif op.kind == "active" then
		entry.active = op.value
	end
end

local function normalise(raw: any): Doc
	if typeof(raw) ~= "table" or typeof(raw.products) ~= "table" then
		return { version = 0, products = {} }
	end
	return { version = raw.version or 0, products = raw.products }
end

local function announce()
	if changeQueued then
		return
	end
	changeQueued = true
	task.defer(function()
		changeQueued = false
		Catalogue.changed:Fire()
	end)
end

local function recompute()
	local view = Store.deepCopy(storedDoc)
	for _, op in inflight do
		applyOp(view, op)
	end
	for _, op in pending do
		applyOp(view, op)
	end
	for _, id in order do
		local seed = seeds[id]
		local saved = view.products[id] or {}
		products[id] = {
			id = id,
			name = seed.Name,
			category = seed.Category,
			colour = seed.Colour or Color3.fromRGB(120, 120, 140),
			taxRate = seed.TaxRate or 0,
			tool = seed.Tool,
			price = saved.price or seed.Price,
			active = if saved.active ~= nil then saved.active else true,
			stock = if seed.Stock ~= nil then (saved.stock or seed.Stock) else nil,
		}
	end
	announce()
end

local function queue(op: Op)
	table.insert(pending, op)
	recompute()
end

local function accept(doc: Doc)
	if doc.version >= storedDoc.version then
		storedDoc = doc
		recompute()
	end
end

local function flush()
	if #pending == 0 then
		return
	end
	inflight = pending
	pending = {}
	local batch = inflight
	local ok, stored = Store.update(STORE, KEY, function(old)
		local doc = normalise(old)
		for _, op in batch do
			applyOp(doc, op)
		end
		doc.version += 1
		return doc
	end)
	inflight = {}
	if ok and stored then
		accept(normalise(stored))
		pcall(MessagingService.PublishAsync, MessagingService, TOPIC, stored.version)
	else
		for i = #batch, 1, -1 do
			table.insert(pending, 1, batch[i])
		end
		recompute()
	end
end

local function refresh()
	local ok, stored = Store.read(STORE, KEY)
	if ok then
		accept(normalise(stored))
	end
end

function Catalogue.init()
	refresh()
	recompute()
	Store.onFlush("catalogue", flush)
	task.spawn(function()
		pcall(MessagingService.SubscribeAsync, MessagingService, TOPIC, function(message)
			if (tonumber(message.Data) or 0) > storedDoc.version then
				refresh()
			end
		end)
	end)
end

function Catalogue.get(id: string): Product?
	return products[id]
end

function Catalogue.list(): { Product }
	local out = {}
	for _, id in order do
		table.insert(out, products[id])
	end
	return out
end

function Catalogue.adjustStock(id: string, delta: number)
	local product = products[id]
	if product and product.stock ~= nil and delta ~= 0 then
		queue({ kind = "stock", id = id, value = delta })
	end
end

function Catalogue.setPrice(id: string, price: number)
	queue({ kind = "price", id = id, value = price })
end

function Catalogue.setActive(id: string, active: boolean)
	queue({ kind = "active", id = id, value = active })
end

return Catalogue
