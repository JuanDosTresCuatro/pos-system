--!strict
-- Sales totals used by shift (X/Z) reports and daily reports. Aggregates are plain tables so
-- they can be saved to a DataStore and merged as deltas from many servers.

export type ProductStat = { name: string, qty: number, total: number }
export type CashierStat = { count: number, total: number }

export type Aggregate = {
	count: number, -- number of sales
	items: number, -- units sold
	gross: number, -- before discount
	discounts: number,
	tax: number,
	sales: number, -- money taken
	refunds: number, -- money returned
	refundCount: number,
	products: { [string]: ProductStat },
	cashiers: { [string]: CashierStat },
}

-- The fields of a sale that aggregation reads.
export type SaleLike = {
	cashier: { name: string },
	lines: { { productId: string, name: string?, qty: number, total: number } },
	subtotal: number,
	discount: number,
	tax: number,
	total: number,
}

local Aggregate = {}

function Aggregate.new(): Aggregate
	return {
		count = 0,
		items = 0,
		gross = 0,
		discounts = 0,
		tax = 0,
		sales = 0,
		refunds = 0,
		refundCount = 0,
		products = {},
		cashiers = {},
	}
end

function Aggregate.addSale(agg: Aggregate, sale: SaleLike)
	agg.count += 1
	agg.gross += sale.subtotal
	agg.discounts += sale.discount
	agg.tax += sale.tax
	agg.sales += sale.total
	for _, line in sale.lines do
		agg.items += line.qty
		local stat = agg.products[line.productId]
		if not stat then
			stat = { name = line.name or line.productId, qty = 0, total = 0 }
			agg.products[line.productId] = stat
		end
		stat.qty += line.qty
		stat.total += line.total
	end
	local cashier = agg.cashiers[sale.cashier.name]
	if not cashier then
		cashier = { count = 0, total = 0 }
		agg.cashiers[sale.cashier.name] = cashier
	end
	cashier.count += 1
	cashier.total += sale.total
end

function Aggregate.addRefund(agg: Aggregate, sale: SaleLike)
	agg.refunds += sale.total
	agg.refundCount += 1
end

-- Adds every value of `delta` into `into`. Used to apply this server's changes on top of
-- whatever other servers already saved.
function Aggregate.merge(into: Aggregate, delta: Aggregate): Aggregate
	into.count += delta.count
	into.items += delta.items
	into.gross += delta.gross
	into.discounts += delta.discounts
	into.tax += delta.tax
	into.sales += delta.sales
	into.refunds += delta.refunds
	into.refundCount += delta.refundCount
	for id, stat in delta.products do
		local target = into.products[id]
		if target then
			target.qty += stat.qty
			target.total += stat.total
		else
			into.products[id] = { name = stat.name, qty = stat.qty, total = stat.total }
		end
	end
	for name, stat in delta.cashiers do
		local target = into.cashiers[name]
		if target then
			target.count += stat.count
			target.total += stat.total
		else
			into.cashiers[name] = { count = stat.count, total = stat.total }
		end
	end
	return into
end

-- Fills fields that are missing from data saved by an older version.
function Aggregate.normalise(raw: any): Aggregate
	local agg = Aggregate.new()
	if typeof(raw) == "table" then
		Aggregate.merge(agg, {
			count = raw.count or 0,
			items = raw.items or 0,
			gross = raw.gross or 0,
			discounts = raw.discounts or 0,
			tax = raw.tax or 0,
			sales = raw.sales or 0,
			refunds = raw.refunds or 0,
			refundCount = raw.refundCount or 0,
			products = raw.products or {},
			cashiers = raw.cashiers or {},
		})
	end
	return agg
end

export type Ranked = { id: string, name: string, qty: number, total: number }

function Aggregate.topProducts(agg: Aggregate, limit: number): { Ranked }
	local list: { Ranked } = {}
	for id, stat in agg.products do
		table.insert(list, { id = id, name = stat.name, qty = stat.qty, total = stat.total })
	end
	table.sort(list, function(a, b)
		if a.total ~= b.total then
			return a.total > b.total
		end
		return a.id < b.id
	end)
	while #list > limit do
		table.remove(list)
	end
	return list
end

export type RankedCashier = { name: string, count: number, total: number }

function Aggregate.topCashiers(agg: Aggregate, limit: number): { RankedCashier }
	local list: { RankedCashier } = {}
	for name, stat in agg.cashiers do
		table.insert(list, { name = name, count = stat.count, total = stat.total })
	end
	table.sort(list, function(a, b)
		if a.total ~= b.total then
			return a.total > b.total
		end
		return a.name < b.name
	end)
	while #list > limit do
		table.remove(list)
	end
	return list
end

function Aggregate.net(agg: Aggregate): number
	return agg.sales - agg.refunds
end

return Aggregate
