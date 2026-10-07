-- Daily totals (UTC days) shared across servers. Each server keeps a delta per day and merges
-- it into the stored total on flush.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Aggregate = require(Shared.Aggregate)
local Format = require(Shared.Format)
local Store = require(script.Parent.Store)

local Reports = {}

local STORE = "Reports"
local CACHE_SECONDS = 20
local DAY = 86400

local pending: { [string]: Aggregate.Aggregate } = {}
local inflight: { [string]: Aggregate.Aggregate } = {}
local cache: { [string]: { at: number, agg: Aggregate.Aggregate } } = {}

local function delta(t: number): Aggregate.Aggregate
	local day = Format.dayKey(t)
	local agg = pending[day]
	if not agg then
		agg = Aggregate.new()
		pending[day] = agg
	end
	return agg
end

function Reports.recordSale(sale)
	Aggregate.addSale(delta(sale.t), sale)
end

function Reports.recordRefund(sale, t: number)
	Aggregate.addRefund(delta(t), sale)
end

local function stored(day: string): Aggregate.Aggregate
	local hit = cache[day]
	if hit and os.clock() - hit.at < CACHE_SECONDS then
		return hit.agg
	end
	local ok, raw = Store.read(STORE, "d/" .. day)
	if not ok then
		return if hit then hit.agg else Aggregate.new()
	end
	local agg = Aggregate.normalise(raw)
	cache[day] = { at = os.clock(), agg = agg }
	return agg
end

export type Day = { day: string, label: string, totals: Aggregate.Aggregate }

-- The last `count` days, oldest first, including changes not saved yet.
function Reports.days(count: number): { Day }
	local now = os.time()
	local out: { Day } = {}
	local loaded = {}
	local remaining = count
	local waiting = false

	-- Read the days in parallel; each read can take a moment.
	local thread = coroutine.running()
	for i = count - 1, 0, -1 do
		local t = now - i * DAY
		task.spawn(function()
			loaded[i] = stored(Format.dayKey(t))
			remaining -= 1
			if remaining == 0 and waiting then
				task.spawn(thread)
			end
		end)
	end
	if remaining > 0 then
		waiting = true
		coroutine.yield()
	end

	for i = count - 1, 0, -1 do
		local t = now - i * DAY
		local day = Format.dayKey(t)
		local totals = Aggregate.merge(Aggregate.normalise(loaded[i]), inflight[day] or Aggregate.new())
		Aggregate.merge(totals, pending[day] or Aggregate.new())
		table.insert(out, { day = day, label = if i == 0 then "Today" else Format.weekday(t), totals = totals })
	end
	return out
end

function Reports.init()
	Store.onFlush("reports", function()
		if next(pending) == nil then
			return
		end
		inflight = pending
		pending = {}
		for day, agg in inflight do
			local ok = Store.update(STORE, "d/" .. day, function(old)
				return Aggregate.merge(Aggregate.normalise(old), agg)
			end)
			if ok then
				cache[day] = nil
			else
				pending[day] = Aggregate.merge(pending[day] or Aggregate.new(), agg)
			end
			inflight[day] = nil
		end
	end)
end

return Reports
