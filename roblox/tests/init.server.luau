-- Runs the specs on every Studio play test. Does nothing in live servers.

if not game:GetService("RunService"):IsStudio() then
	return
end

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local TestKit = require(script.TestKit)
local Specs = require(script.Specs)

local kit = TestKit.new()
Specs(kit, {
	Pricing = require(Shared.Pricing),
	Validate = require(Shared.Validate),
	Aggregate = require(Shared.Aggregate),
	Format = require(Shared.Format),
})
if not kit.report() then
	warn("RoPOS: some tests failed, see the Output window")
end
