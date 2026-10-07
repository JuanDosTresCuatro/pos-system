--!nolint DeprecatedApi
-- GetRankInGroupAsync is soft-deprecated for GroupService:GetRolesInGroupAsync, whose result is
-- not typed yet. Rank numbers are what group-run shops configure, so this keeps using them.

-- Works out each player's role once when they join, from Config.Staff.
-- The role is also set as the "POSRole" attribute so other scripts in your game can read it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Roles = require(Shared.Roles)

local Staff = {}

local roles: { [Player]: number } = {}

local function resolve(player: Player): number
	local settings = Config.Staff

	if RunService:IsStudio() and settings.StudioRole then
		return Roles.fromName(settings.StudioRole) or Roles.Customer
	end

	local override = Roles.fromName(settings.Users[player.UserId])
	if override then
		return override
	end

	if settings.OwnerIsManager and game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return Roles.Manager
	end

	if settings.GroupId and settings.GroupId > 0 then
		local ok, rank = pcall(player.GetRankInGroupAsync, player, settings.GroupId)
		if ok then
			if settings.OwnerIsManager and rank == 255 then
				return Roles.Manager
			elseif rank >= settings.ManagerRank then
				return Roles.Manager
			elseif rank >= settings.CashierRank then
				return Roles.Cashier
			end
		else
			warn("[RoPOS] Could not read group rank for " .. player.Name .. ": " .. tostring(rank))
		end
	end

	return Roles.Customer
end

function Staff.roleOf(player: Player): number
	local role = roles[player]
	if role == nil then
		role = resolve(player)
		roles[player] = role
		player:SetAttribute("POSRole", Roles.name(role))
	end
	return role
end

function Staff.isStaff(player: Player): boolean
	return Staff.roleOf(player) >= Roles.Cashier
end

function Staff.maxDiscount(player: Player): number
	if Staff.roleOf(player) >= Roles.Manager then
		return Config.Discounts.ManagerMaxPct
	end
	return Config.Discounts.CashierMaxPct
end

function Staff.init()
	Players.PlayerAdded:Connect(Staff.roleOf)
	for _, player in Players:GetPlayers() do
		task.spawn(Staff.roleOf, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		roles[player] = nil
	end)
end

return Staff
