-- RoPOS client bootstrap.

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("POS")
local Config = require(Shared.Config)
local Roles = require(Shared.Roles)

local Api = require(script.Api)
local App = require(script.App)
local PaymentPrompt = require(script.PaymentPrompt)
local State = require(script.State)
local Toasts = require(script.UI.Toasts)

local hello
for attempt = 1, 5 do
	local ok, data = Api.call("session.hello")
	if ok then
		hello = data
		break
	end
	task.wait(attempt)
end
if not hello then
	warn("[RoPOS] Could not reach the server")
	return
end

State.role = hello.role
State.roleName = hello.roleName
State.maxDiscount = hello.maxDiscount
State.persistent = hello.persistent
State.set("catalogue", hello.catalogue or {})
State.register = hello.register

App.mount()
PaymentPrompt.mount(App.overlay() :: any)

Api.on("OpenRegister", function(summary)
	State.set("register", summary)
	App.open()
end)

Api.on("CloseRegister", function(payload)
	State.set("register", nil)
	App.close()
	if payload and payload.reason then
		Toasts.show(payload.reason, "info")
	end
end)

Api.on("Register", function(summary)
	State.set("register", summary)
end)

Api.on("Catalogue", function(list)
	State.set("catalogue", list)
end)

Api.on("Toast", function(toast)
	Toasts.show(toast.text, toast.kind)
end)

-- Customers never see the "Use register" prompt. This only changes the local copy.
if State.role < Roles.Cashier then
	local function hide(instance: Instance)
		for _, descendant in instance:GetDescendants() do
			if descendant:IsA("ProximityPrompt") and descendant.Name == "RoPOSPrompt" then
				descendant.Enabled = false
			end
		end
		instance.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("ProximityPrompt") and descendant.Name == "RoPOSPrompt" then
				descendant.Enabled = false
			end
		end)
	end
	for _, register in CollectionService:GetTagged(Config.RegisterTag) do
		hide(register)
	end
	CollectionService:GetInstanceAddedSignal(Config.RegisterTag):Connect(hide)
end

if hello.register then
	App.open()
end
