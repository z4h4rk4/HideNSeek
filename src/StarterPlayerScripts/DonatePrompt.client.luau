--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CashProductConfig"))

local player = Players.LocalPlayer
local promptPending = false

local function isDonatePrompt(prompt: ProximityPrompt): boolean
	return prompt.Name == Config.DONATE_PROMPT_NAME
		or prompt:GetAttribute(Config.DONATE_PROMPT_ATTRIBUTE) == true
end

local function promptDonatePurchase()
	if promptPending then
		return
	end

	promptPending = true
	local succeeded, message = pcall(
		MarketplaceService.PromptProductPurchase,
		MarketplaceService,
		player,
		Config.DONATE_PRODUCT_ID
	)
	if not succeeded then
		promptPending = false
		warn(`[DonatePrompt] failed to open purchase prompt: {tostring(message)}`)
		return
	end

	task.delay(Config.PURCHASE_PROMPT_TIMEOUT_SECONDS, function()
		promptPending = false
	end)
end

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
	if isDonatePrompt(prompt) then
		promptDonatePurchase()
	end
end)

MarketplaceService.PromptProductPurchaseFinished:Connect(function(
	userId: number,
	productId: number,
	_wasPurchased: boolean
)
	if userId == player.UserId and productId == Config.DONATE_PRODUCT_ID then
		promptPending = false
	end
end)
