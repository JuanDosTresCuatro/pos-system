-- Receipts. Each sale is its own DataStore key ("s/BM-000042"); a rolling list of the latest
-- 200 summaries is shared by every server for the Sales screen.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Store = require(script.Parent.Store)
local Reports = require(script.Parent.Reports)

local Sales = {}

export type SaleLine = {
	productId: string,
	name: string,
	qty: number,
	unitPrice: number,
	discount: number,
	tax: number,
	total: number,
}

export type Sale = {
	receipt: string,
	t: number,
	registerId: string,
	registerName: string,
	shiftId: string?,
	cashier: { userId: number, name: string },
	customer: { userId: number, name: string },
	lines: { SaleLine },
	discountPct: number,
	subtotal: number,
	discount: number,
	tax: number,
	total: number,
	refunded: { t: number, by: string, restocked: boolean }?,
}

export type Summary = {
	receipt: string,
	t: number,
	cashier: string,
	customer: string,
	items: number,
	total: number,
	refunded: boolean,
}

local STORE = "Sales"
local KEEP = 200
local CACHE_SECONDS = 15

local cache: { [string]: Sale } = {}
local pendingSummaries: { Summary } = {} -- oldest first
local pendingRefunds: { [string]: boolean } = {}
local storedRecent: { Summary } = {}
local storedAt = -math.huge
local fallbackCounter = 0

local function summarise(sale: Sale): Summary
	local items = 0
	for _, line in sale.lines do
		items += line.qty
	end
	return {
		receipt = sale.receipt,
		t = sale.t,
		cashier = sale.cashier.name,
		customer = sale.customer.name,
		items = items,
		total = sale.total,
		refunded = sale.refunded ~= nil,
	}
end

local function nextReceipt(): string
	local ok, n = Store.update(STORE, "counter", function(old)
		return (old or 0) + 1
	end)
	if ok and typeof(n) == "number" then
		return Format.receipt(Config.Store.ReceiptPrefix, n)
	end
	-- The counter is unreachable: use a time-based number that cannot clash with it.
	fallbackCounter += 1
	return string.format("%s-T%d%02d", Config.Store.ReceiptPrefix, os.time(), fallbackCounter % 100)
end

-- Yields while the receipt number is reserved. Fills in sale.receipt.
function Sales.record(sale: Sale): Sale
	sale.receipt = nextReceipt()
	cache[sale.receipt] = sale
	table.insert(pendingSummaries, summarise(sale))
	Reports.recordSale(sale)
	task.spawn(Store.update, STORE, "s/" .. sale.receipt, function()
		return sale
	end)
	return sale
end

function Sales.get(receipt: string): Sale?
	local hit = cache[receipt]
	if hit then
		return hit
	end
	local ok, stored = Store.read(STORE, "s/" .. receipt)
	if ok and stored then
		cache[receipt] = stored
		return stored
	end
	return nil
end

function Sales.recent(limit: number): { Summary }
	if os.clock() - storedAt > CACHE_SECONDS then
		local ok, stored = Store.read(STORE, "recent")
		if ok then
			storedRecent = stored or {}
			storedAt = os.clock()
		end
	end
	local out, seen = {}, {}
	local function add(summary: Summary)
		if #out < limit and not seen[summary.receipt] then
			seen[summary.receipt] = true
			local copy = table.clone(summary)
			copy.refunded = copy.refunded
				or pendingRefunds[copy.receipt] == true
				or (cache[copy.receipt] and cache[copy.receipt].refunded ~= nil)
				or false
			table.insert(out, copy)
		end
	end
	for i = #pendingSummaries, 1, -1 do
		add(pendingSummaries[i])
	end
	for _, summary in storedRecent do
		add(summary)
	end
	return out
end

-- Marks the sale refunded. The UpdateAsync transform is the guard against two managers (or
-- two servers) refunding the same sale. Returns the updated sale, or nil and a reason.
function Sales.markRefunded(receipt: string, by: string, restocked: boolean): (Sale?, string?)
	local claimed, reason = false, nil
	local ok, updated = Store.update(STORE, "s/" .. receipt, function(old)
		claimed = false
		if not old then
			reason = "This sale has not finished saving yet. Try again in a minute."
			return nil
		elseif old.refunded then
			reason = "This sale has already been refunded"
			return nil
		end
		old.refunded = { t = os.time(), by = by, restocked = restocked }
		claimed = true
		return old
	end)
	if not ok then
		return nil, "Could not reach the data store. Try again."
	end
	if not claimed then
		return nil, reason
	end
	cache[receipt] = updated
	pendingRefunds[receipt] = true
	return updated, nil
end

function Sales.unmarkRefunded(receipt: string)
	local ok, updated = Store.update(STORE, "s/" .. receipt, function(old)
		if old then
			old.refunded = nil
		end
		return old
	end)
	if ok and updated then
		cache[receipt] = updated
	end
	pendingRefunds[receipt] = nil
end

function Sales.init()
	Store.onFlush("sales", function()
		if #pendingSummaries == 0 and next(pendingRefunds) == nil then
			return
		end
		local batch = pendingSummaries
		local refunds = pendingRefunds
		pendingSummaries = {}
		pendingRefunds = {}
		local ok = Store.update(STORE, "recent", function(old)
			local merged, seen = {}, {}
			for i = #batch, 1, -1 do
				table.insert(merged, batch[i])
				seen[batch[i].receipt] = true
			end
			for _, summary in old or {} do
				if #merged >= KEEP then
					break
				end
				if not seen[summary.receipt] then
					table.insert(merged, summary)
				end
			end
			for _, summary in merged do
				if refunds[summary.receipt] then
					summary.refunded = true
				end
			end
			return merged
		end)
		if ok then
			storedAt = -math.huge
		else
			for i, summary in batch do
				table.insert(pendingSummaries, i, summary)
			end
			for receipt in refunds do
				pendingRefunds[receipt] = true
			end
		end
	end)
end

return Sales
