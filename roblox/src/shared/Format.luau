--!strict
-- Text formatting. Roblox only allows os.date("*t") and os.date("!*t"), so times are built by hand.

local Format = {}

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

function Format.number(n: number): string
	local digits = tostring(math.floor(math.abs(n)))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return (if n < 0 then "-" else "") .. grouped
end

function Format.money(n: number, symbol: string?): string
	local sign = if n < 0 then "-" else ""
	return sign .. (symbol or "") .. Format.number(math.abs(n))
end

function Format.receipt(prefix: string, n: number): string
	return string.format("%s-%06d", prefix, n)
end

function Format.clock(t: number): string
	local d = os.date("*t", t) :: any
	return string.format("%02d:%02d", d.hour, d.min)
end

function Format.date(t: number): string
	local d = os.date("*t", t) :: any
	return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

function Format.dateTime(t: number): string
	return Format.date(t) .. " " .. Format.clock(t)
end

-- Report days are UTC so every server agrees on which day a sale belongs to.
function Format.dayKey(t: number): string
	local d = os.date("!*t", t) :: any
	return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

function Format.weekday(t: number): string
	local d = os.date("!*t", t) :: any
	return DAYS[d.wday]
end

function Format.duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	if h > 0 then
		return string.format("%dh %02dm", h, m)
	end
	return string.format("%dm", m)
end

-- One receipt row: left text, then right text aligned to `width` characters (monospace).
function Format.row(left: string, right: string, width: number): string
	local space = width - utf8.len(left) :: number - utf8.len(right) :: number
	if space < 1 then
		local keep = math.max(1, width - (utf8.len(right) :: number) - 2)
		local cut = utf8.offset(left, keep + 1)
		left = (if cut then string.sub(left, 1, cut - 1) else left) .. "…"
		space = math.max(1, width - utf8.len(left) :: number - utf8.len(right) :: number)
	end
	return left .. string.rep(" ", space) .. right
end

return Format
