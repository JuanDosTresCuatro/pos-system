-- Minimal pure-Luau signal. Handlers run in their own thread so one error cannot break others.

local Signal = {}
Signal.__index = Signal

export type Connection = { Disconnect: () -> () }

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn: (...any) -> ()): Connection
	local handler = { fn = fn, connected = true }
	table.insert(self._handlers, handler)
	return {
		Disconnect = function()
			handler.connected = false
			local index = table.find(self._handlers, handler)
			if index then
				table.remove(self._handlers, index)
			end
		end,
	}
end

function Signal:Fire(...: any)
	for _, handler in table.clone(self._handlers) do
		if handler.connected then
			task.spawn(handler.fn, ...)
		end
	end
end

return Signal
