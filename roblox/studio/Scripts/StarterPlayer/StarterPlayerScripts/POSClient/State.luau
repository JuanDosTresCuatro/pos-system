-- Client state with a change signal: State.set("register", value) fires State.changed("register").

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Signal = require(Shared.Signal)

local State = {
	role = 0,
	roleName = "Customer",
	maxDiscount = 0,
	persistent = true,
	catalogue = {},
	byId = {},
	register = nil,
}

State.changed = Signal.new()

function State.set(key: string, value: any)
	State[key] = value
	if key == "catalogue" then
		local byId = {}
		for _, product in value do
			byId[product.id] = product
		end
		State.byId = byId
	end
	State.changed:Fire(key, value)
end

return State
