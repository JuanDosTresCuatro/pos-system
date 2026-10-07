-- Register shifts: open, take sales, X report at any time, Z report on close.
-- The roleplay equivalent of the web POS till session.

local HttpService = game:GetService("HttpService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Aggregate = require(Shared.Aggregate)
local Store = require(script.Parent.Store)

local Shifts = {}

export type Shift = {
	id: string,
	registerId: string,
	registerName: string,
	openedAt: number,
	openedBy: string,
	totals: Aggregate.Aggregate,
}

export type Report = {
	id: string,
	registerName: string,
	openedAt: number,
	openedBy: string,
	closedAt: number?,
	closedBy: string?,
	totals: Aggregate.Aggregate,
	net: number,
	average: number,
	topProducts: { Aggregate.Ranked },
	cashiers: { Aggregate.RankedCashier },
}

function Shifts.new(registerId: string, registerName: string, openedBy: Player): Shift
	return {
		id = string.sub(HttpService:GenerateGUID(false), 1, 8),
		registerId = registerId,
		registerName = registerName,
		openedAt = os.time(),
		openedBy = openedBy.Name,
		totals = Aggregate.new(),
	}
end

function Shifts.recordSale(shift: Shift, sale)
	Aggregate.addSale(shift.totals, sale)
end

function Shifts.recordRefund(shift: Shift, sale)
	Aggregate.addRefund(shift.totals, sale)
end

function Shifts.report(shift: Shift): Report
	local totals = shift.totals
	return {
		id = shift.id,
		registerName = shift.registerName,
		openedAt = shift.openedAt,
		openedBy = shift.openedBy,
		totals = totals,
		net = Aggregate.net(totals),
		average = if totals.count > 0 then math.floor(totals.sales / totals.count + 0.5) else 0,
		topProducts = Aggregate.topProducts(totals, 5),
		cashiers = Aggregate.topCashiers(totals, 10),
	}
end

-- Builds the Z report and saves it. Saving runs in the background.
function Shifts.close(shift: Shift, closedBy: string): Report
	local report = Shifts.report(shift)
	report.closedAt = os.time()
	report.closedBy = closedBy
	task.spawn(Store.update, "Shifts", "z/" .. shift.id, function()
		return report
	end)
	return report
end

return Shifts
