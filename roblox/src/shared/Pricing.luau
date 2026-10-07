--!strict
-- Line pricing shared by the client (live cart preview) and the server (authoritative totals).
-- Port of public/js/pricing.js from the web POS: the same rounding, so both always agree.
-- All money values are whole numbers. Rates are percentages.

export type Line = {
	productId: string,
	name: string?,
	unitPrice: number,
	qty: number,
	taxRate: number?,
}

export type PricedLine = {
	productId: string,
	name: string?,
	unitPrice: number,
	qty: number,
	taxRate: number,
	discount: number,
	tax: number,
	total: number,
}

export type Totals = {
	lines: { PricedLine },
	subtotal: number,
	discount: number,
	tax: number,
	total: number,
}

export type Options = {
	discountPct: number?,
	taxInclusive: boolean?,
}

local Pricing = {}

local function round(n: number): number
	-- Math.round in JS rounds .5 up; all values here are >= 0, so floor(n + 0.5) matches it.
	return math.floor(n + 0.5)
end

function Pricing.priceLines(lines: { Line }, options: Options?): Totals
	local opts: Options = options or {}
	local pct = math.clamp(tonumber(opts.discountPct) or 0, 0, 100)
	local taxInclusive = if opts.taxInclusive == nil then true else opts.taxInclusive

	local subtotal, discount, tax, total = 0, 0, 0, 0
	local out: { PricedLine } = {}

	for _, line in lines do
		local gross = line.unitPrice * line.qty
		local lineDiscount = round(gross * pct / 100)
		local net = gross - lineDiscount
		local rate = tonumber(line.taxRate) or 0
		local lineTax = if taxInclusive then round(net * rate / (100 + rate)) else round(net * rate / 100)
		local lineTotal = if taxInclusive then net else net + lineTax

		subtotal += gross
		discount += lineDiscount
		tax += lineTax
		total += lineTotal

		table.insert(out, {
			productId = line.productId,
			name = line.name,
			unitPrice = line.unitPrice,
			qty = line.qty,
			taxRate = rate,
			discount = lineDiscount,
			tax = lineTax,
			total = lineTotal,
		})
	end

	return { lines = out, subtotal = subtotal, discount = discount, tax = tax, total = total }
end

return Pricing
