-- Luau CLI entry point: luau tests/run.luau

local TestKit = require("./TestKit")
local Specs = require("./Specs")

local kit = TestKit.new()
Specs(kit, {
	Pricing = require("../src/shared/Pricing"),
	Validate = require("../src/shared/Validate"),
	Aggregate = require("../src/shared/Aggregate"),
	Format = require("../src/shared/Format"),
})

if not kit.report() then
	error("tests failed", 0)
end
