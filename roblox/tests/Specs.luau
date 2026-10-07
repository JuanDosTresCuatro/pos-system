-- Specs for the pure shared modules. `M` holds the modules so this file works with both
-- string requires (Luau CLI) and instance requires (Studio).

return function(kit, M)
	local describe, it, expect = kit.describe, kit.it, kit.expect
	local Pricing, Validate, Aggregate, Format = M.Pricing, M.Validate, M.Aggregate, M.Format

	-- The same cases as test/pricing.test.js in the web POS: both must give identical totals.
	describe("Pricing", function()
		it("tax-inclusive prices extract tax from the gross", function()
			local r = Pricing.priceLines(
				{ { productId = "a", unitPrice = 120, qty = 1, taxRate = 20 } },
				{ taxInclusive = true }
			)
			expect({ r.subtotal, r.tax, r.total }).equals({ 120, 20, 120 })
		end)

		it("tax-exclusive prices add tax on top", function()
			local r = Pricing.priceLines(
				{ { productId = "a", unitPrice = 100, qty = 3, taxRate = 20 } },
				{ taxInclusive = false }
			)
			expect({ r.subtotal, r.tax, r.total }).equals({ 300, 60, 360 })
		end)

		it("discount applies before tax and is spread across lines", function()
			local r = Pricing.priceLines({
				{ productId = "a", unitPrice = 120, qty = 2, taxRate = 20 },
				{ productId = "b", unitPrice = 395, qty = 1, taxRate = 0 },
			}, { discountPct = 10, taxInclusive = true })
			expect(r.discount).equals(24 + 40)
			expect(r.tax).equals(36)
			expect(r.total).equals(571)
		end)

		it("discount is clamped to 0..100", function()
			local line = { { productId = "a", unitPrice = 100, qty = 1, taxRate = 0 } }
			expect(Pricing.priceLines(line, { discountPct = 150 }).total).equals(0)
			expect(Pricing.priceLines(line, { discountPct = -5 }).total).equals(100)
		end)

		it("line totals add up to the order total", function()
			local r = Pricing.priceLines({
				{ productId = "a", unitPrice = 33, qty = 3, taxRate = 20 },
				{ productId = "b", unitPrice = 17, qty = 7, taxRate = 5 },
			}, { discountPct = 15, taxInclusive = false })
			local sum = 0
			for _, line in r.lines do
				sum += line.total
			end
			expect(sum).equals(r.total)
		end)
	end)

	describe("Validate.cart", function()
		it("merges duplicate products in first-seen order", function()
			local cart = Validate.cart({
				{ productId = "latte", qty = 1 },
				{ productId = "cookie", qty = 2 },
				{ productId = "latte", qty = 3 },
			}, 20, 20)
			expect(cart).equals({ { productId = "latte", qty = 4 }, { productId = "cookie", qty = 2 } })
		end)

		it("rejects bad quantities", function()
			expect(Validate.cart({ { productId = "a", qty = 0 } }, 20, 20)).isNil()
			expect(Validate.cart({ { productId = "a", qty = 1.5 } }, 20, 20)).isNil()
			expect(Validate.cart({ { productId = "a", qty = 0 / 0 } }, 20, 20)).isNil()
			expect(Validate.cart({ { productId = "a", qty = "3" } }, 20, 20)).isNil()
		end)

		it("rejects merged quantities over the limit", function()
			local cart, err = Validate.cart({ { productId = "a", qty = 15 }, { productId = "a", qty = 10 } }, 20, 20)
			expect(cart).isNil()
			expect(err).truthy()
		end)

		it("rejects non-array and empty carts", function()
			expect(Validate.cart({ x = { productId = "a", qty = 1 } }, 20, 20)).isNil()
			expect(Validate.cart({}, 20, 20)).isNil()
			expect(Validate.cart("cart", 20, 20)).isNil()
		end)

		it("rejects too many different lines", function()
			local raw = {}
			for i = 1, 4 do
				table.insert(raw, { productId = "p" .. i, qty = 1 })
			end
			expect(Validate.cart(raw, 3, 20)).isNil()
		end)
	end)

	describe("Aggregate", function()
		local function sale(cashier: string, total: number)
			return {
				cashier = { name = cashier },
				lines = { { productId = "latte", name = "Latte", qty = 2, total = total } },
				subtotal = total,
				discount = 0,
				tax = 0,
				total = total,
			}
		end

		it("adds sales and refunds", function()
			local agg = Aggregate.new()
			Aggregate.addSale(agg, sale("Ann", 50))
			Aggregate.addSale(agg, sale("Bob", 30))
			Aggregate.addRefund(agg, sale("Bob", 30))
			expect({ agg.count, agg.items, agg.sales, agg.refunds, Aggregate.net(agg) }).equals({ 2, 4, 80, 30, 50 })
			expect(agg.products.latte.qty).equals(4)
		end)

		it("merges deltas from two servers into one total", function()
			local a, b = Aggregate.new(), Aggregate.new()
			Aggregate.addSale(a, sale("Ann", 50))
			Aggregate.addSale(b, sale("Ann", 20))
			local stored = Aggregate.merge(Aggregate.normalise(nil), a)
			Aggregate.merge(stored, b)
			expect(stored.cashiers.Ann).equals({ count = 2, total = 70 })
			expect(stored.products.latte.total).equals(70)
		end)

		it("ranks products by takings", function()
			local agg = Aggregate.new()
			Aggregate.addSale(agg, {
				cashier = { name = "Ann" },
				lines = {
					{ productId = "a", name = "A", qty = 1, total = 10 },
					{ productId = "b", name = "B", qty = 1, total = 90 },
				},
				subtotal = 100,
				discount = 0,
				tax = 0,
				total = 100,
			})
			local top = Aggregate.topProducts(agg, 1)
			expect(#top).equals(1)
			expect(top[1].id).equals("b")
		end)
	end)

	describe("Format", function()
		it("groups thousands", function()
			expect(Format.money(1234567, "$")).equals("$1,234,567")
			expect(Format.money(-950, "$")).equals("-$950")
			expect(Format.money(0, "$")).equals("$0")
		end)

		it("pads receipt numbers", function()
			expect(Format.receipt("BB", 42)).equals("BB-000042")
		end)

		it("aligns receipt rows to a fixed width", function()
			expect(Format.row("Latte", "$28", 12)).equals("Latte    $28")
			expect(#Format.row("A very long product name", "$28", 12) > 0).truthy()
		end)
	end)
end
