-- Tiny test harness that runs both in the Luau CLI and inside Roblox Studio.

local TestKit = {}

local function render(value: any): string
	if type(value) == "table" then
		local parts = {}
		for k, v in value do
			table.insert(parts, tostring(k) .. "=" .. render(v))
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function TestKit.new()
	local results = { passed = 0, failed = 0, failures = {} }
	local prefix = ""

	local kit = {}

	function kit.describe(name: string, fn: () -> ())
		local saved = prefix
		prefix = prefix .. name .. " > "
		fn()
		prefix = saved
	end

	function kit.it(name: string, fn: () -> ())
		local ok, err = pcall(fn)
		if ok then
			results.passed += 1
		else
			results.failed += 1
			table.insert(results.failures, prefix .. name .. "\n    " .. tostring(err))
		end
	end

	function kit.expect(actual: any)
		return {
			equals = function(expected: any)
				if not deepEqual(actual, expected) then
					error(string.format("expected %s, got %s", render(expected), render(actual)), 2)
				end
			end,
			isNil = function()
				if actual ~= nil then
					error("expected nil, got " .. render(actual), 2)
				end
			end,
			truthy = function()
				if not actual then
					error("expected a truthy value, got " .. render(actual), 2)
				end
			end,
		}
	end

	function kit.report(): boolean
		for _, failure in results.failures do
			print("  FAIL " .. failure)
		end
		print(string.format("RoPOS tests: %d passed, %d failed", results.passed, results.failed))
		return results.failed == 0
	end

	return kit
end

return TestKit
