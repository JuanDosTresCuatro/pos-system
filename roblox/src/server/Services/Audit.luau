-- Who did what and when. Entries are batched and merged into one rolling list shared by every
-- server (newest first, the latest 500 kept).

local Store = require(script.Parent.Store)

local Audit = {}

export type Entry = { t: number, actor: string, userId: number, action: string, detail: string }

local STORE, KEY, KEEP = "Audit", "log", 500
local CACHE_SECONDS = 15

local pending: { Entry } = {} -- oldest first
local cached: { Entry } = {}
local cachedAt = -math.huge

function Audit.log(actor: Player | string, action: string, detail: string?)
	local isPlayer = typeof(actor) == "Instance"
	table.insert(pending, {
		t = os.time(),
		actor = if isPlayer then (actor :: Player).Name else tostring(actor),
		userId = if isPlayer then (actor :: Player).UserId else 0,
		action = action,
		detail = detail or "",
	})
end

function Audit.recent(limit: number): { Entry }
	if os.clock() - cachedAt > CACHE_SECONDS then
		local ok, stored = Store.read(STORE, KEY)
		if ok then
			cached = stored or {}
			cachedAt = os.clock()
		end
	end
	local out = {}
	for i = #pending, 1, -1 do
		if #out >= limit then
			return out
		end
		table.insert(out, pending[i])
	end
	for _, entry in cached do
		if #out >= limit then
			break
		end
		table.insert(out, entry)
	end
	return out
end

function Audit.init()
	Store.onFlush("audit", function()
		if #pending == 0 then
			return
		end
		local batch = pending
		pending = {}
		local ok = Store.update(STORE, KEY, function(old)
			local merged = {}
			for i = #batch, 1, -1 do
				table.insert(merged, batch[i])
			end
			for _, entry in old or {} do
				if #merged >= KEEP then
					break
				end
				table.insert(merged, entry)
			end
			return merged
		end)
		if ok then
			cachedAt = -math.huge
		else
			for i, entry in batch do
				table.insert(pending, i, entry)
			end
		end
	end)
end

return Audit
