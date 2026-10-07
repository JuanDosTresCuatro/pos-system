--!strict
-- Staff roles, lowest to highest. Compare with >= to check permissions.

local Roles = {
	Customer = 0,
	Cashier = 1,
	Manager = 2,
}

local NAMES = { [0] = "Customer", [1] = "Cashier", [2] = "Manager" }

function Roles.name(role: number): string
	return NAMES[role] or "Customer"
end

function Roles.fromName(name: string?): number?
	if name == "Manager" then
		return Roles.Manager
	elseif name == "Cashier" then
		return Roles.Cashier
	elseif name == "Customer" then
		return Roles.Customer
	end
	return nil
end

return Roles
