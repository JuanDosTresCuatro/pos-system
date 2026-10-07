--!strict
-- Input checks for anything that arrives over a RemoteFunction. Never trust the client.

export type CartLine = { productId: string, qty: number }

local Validate = {}

local HARD_LINE_LIMIT = 100

function Validate.int(value: any, min: number, max: number): number?
	if typeof(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < min or value > max then
		return nil
	end
	return value
end

function Validate.text(value: any, maxLength: number): string?
	if typeof(value) ~= "string" then
		return nil
	end
	local trimmed = string.match(value, "^%s*(.-)%s*$") or ""
	if #trimmed == 0 or #trimmed > maxLength then
		return nil
	end
	return trimmed
end

-- Accepts an array of { productId, qty }, merges duplicate products and keeps first-seen order.
function Validate.cart(raw: any, maxLines: number, maxQty: number): ({ CartLine }?, string?)
	if typeof(raw) ~= "table" then
		return nil, "Invalid cart"
	end

	local merged: { [string]: number } = {}
	local order: { string } = {}
	local seen = 0

	for index, line in raw do
		seen += 1
		if seen > HARD_LINE_LIMIT then
			return nil, "Invalid cart"
		end
		if typeof(index) ~= "number" or typeof(line) ~= "table" then
			return nil, "Invalid cart"
		end
		local id = Validate.text(line.productId, 64)
		local qty = Validate.int(line.qty, 1, maxQty)
		if not id or not qty then
			return nil, "Invalid cart line"
		end
		if merged[id] then
			merged[id] += qty
		else
			merged[id] = qty
			table.insert(order, id)
		end
	end

	if #order == 0 then
		return nil, "The order is empty"
	end
	if #order > maxLines then
		return nil, string.format("An order can have at most %d different items", maxLines)
	end

	local out: { CartLine } = {}
	for _, id in order do
		if merged[id] > maxQty then
			return nil, string.format("You can sell at most %d of one item", maxQty)
		end
		table.insert(out, { productId = id, qty = merged[id] })
	end
	return out, nil
end

return Validate
