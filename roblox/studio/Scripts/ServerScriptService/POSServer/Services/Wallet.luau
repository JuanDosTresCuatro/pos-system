-- The customer's money.
--
-- Builtin provider: the leaderstats value is the live balance. Saves send only the change since
-- the last save (value - baseline) through UpdateAsync, so a refund credited to the same key by
-- another server is merged instead of overwritten. Other scripts in your game can change the
-- leaderstats value freely and the change is saved too.
--
-- Leaderstats provider: uses a value your game already creates and saves.

local Players = game:GetService("Players")
local MessagingService = game:GetService("MessagingService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Store = require(script.Parent.Store)

local Wallet = {}

type Entry = {
	stat: IntValue, -- may be a NumberValue in Leaderstats mode; both have a numeric Value
	baseline: number,
	loaded: boolean,
	saving: boolean,
}

local entries: { [Player]: Entry } = {}
local TOPIC = "RoPOS_Wallet"
local STORE = "Wallets"

local function builtin(): boolean
	return Config.Currency.Provider ~= "Leaderstats"
end

local function key(userId: number): string
	return "u" .. userId
end

local function ensureStat(player: Player): IntValue
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end
	local stat = leaderstats:FindFirstChild(Config.Currency.StatName)
	if not stat then
		stat = Instance.new("IntValue")
		stat.Name = Config.Currency.StatName
		stat.Parent = leaderstats
	end
	return stat
end

local function save(player: Player, entry: Entry)
	while entry.saving do
		task.wait()
	end
	if not entry.loaded then
		return
	end
	entry.saving = true
	local snapshot = entry.stat.Value
	local delta = snapshot - entry.baseline
	local ok, stored = Store.update(STORE, key(player.UserId), function(old)
		old = old or { balance = Config.Currency.StartingBalance }
		old.balance = math.max(0, old.balance + delta)
		return old
	end)
	if ok and stored then
		-- Anything above our snapshot was credited by another server while we were away.
		local extra = stored.balance - snapshot
		entry.baseline = stored.balance
		if extra ~= 0 then
			entry.stat.Value += extra
		end
	end
	entry.saving = false
end

local function load(player: Player)
	if not builtin() then
		local leaderstats = player:WaitForChild("leaderstats", 15)
		local stat = leaderstats and leaderstats:WaitForChild(Config.Currency.StatName, 15)
		if stat and (stat:IsA("IntValue") or stat:IsA("NumberValue")) then
			entries[player] = { stat = stat :: any, baseline = 0, loaded = true, saving = false }
		else
			warn(
				"[RoPOS] "
					.. player.Name
					.. " has no leaderstats."
					.. Config.Currency.StatName
					.. "; payments are disabled for them"
			)
		end
		return
	end

	local entry: Entry = { stat = ensureStat(player), baseline = 0, loaded = false, saving = false }
	entries[player] = entry
	for attempt = 1, 5 do
		local ok, stored = Store.update(STORE, key(player.UserId), function(old)
			return old or { balance = Config.Currency.StartingBalance }
		end)
		if entries[player] ~= entry then
			return
		end
		if ok and stored then
			entry.baseline = stored.balance
			entry.stat.Value = stored.balance
			entry.loaded = true
			return
		end
		task.wait(5 * attempt)
	end
	warn("[RoPOS] Could not load the wallet for " .. player.Name .. "; payments are disabled for them")
end

function Wallet.ready(player: Player): boolean
	local entry = entries[player]
	return entry ~= nil and entry.loaded
end

function Wallet.balance(player: Player): number?
	local entry = entries[player]
	return if entry and entry.loaded then entry.stat.Value else nil
end

-- Synchronous: no yield between the balance check and the debit.
function Wallet.tryDebit(player: Player, amount: number): boolean
	local entry = entries[player]
	if not entry or not entry.loaded or entry.stat.Value < amount then
		return false
	end
	entry.stat.Value -= amount
	return true
end

function Wallet.credit(player: Player, amount: number): boolean
	local entry = entries[player]
	if not entry or not entry.loaded then
		return false
	end
	entry.stat.Value += amount
	return true
end

-- Credits a player who may be offline or in another server.
function Wallet.creditUserId(userId: number, amount: number): (boolean, string?)
	local player = Players:GetPlayerByUserId(userId)
	if player and Wallet.credit(player, amount) then
		return true
	end
	if not builtin() then
		return false, "The customer must be in this server to get a refund"
	end
	local ok = Store.update(STORE, key(userId), function(old)
		old = old or { balance = Config.Currency.StartingBalance }
		old.balance += amount
		return old
	end)
	if not ok then
		return false, "Could not reach the data store. Try again."
	end
	-- Tell the server they are on (if any) to pick up the new balance now.
	pcall(MessagingService.PublishAsync, MessagingService, TOPIC, userId)
	return true
end

function Wallet.init()
	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local entry = entries[player]
		if entry and builtin() then
			save(player, entry)
		end
		entries[player] = nil
	end)

	if builtin() then
		Store.onFlush("wallets", function()
			-- Snapshot: saves yield, and players can join (adding keys) meanwhile.
			for player, entry in table.clone(entries) do
				if entry.loaded and entry.stat.Value ~= entry.baseline then
					save(player, entry)
				end
			end
		end)

		task.spawn(function()
			pcall(MessagingService.SubscribeAsync, MessagingService, TOPIC, function(message)
				local player = Players:GetPlayerByUserId(tonumber(message.Data) or 0)
				local entry = player and entries[player]
				if entry then
					save(player, entry)
				end
			end)
		end)
	end
end

return Wallet
