--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CashProductConfig = require(ReplicatedStorage:WaitForChild("CashProductConfig"))
local CurrencyService = require(script.Parent:WaitForChild("CurrencyService"))
local SkinCaseService = require(
	game:GetService("ServerScriptService"):WaitForChild("Skins"):WaitForChild("SkinCaseService")
)

type ProductDefinition = {
	Key: string,
	FrameName: string,
	ProductId: number,
	Amount: number,
}

local CashProductService = {}
local started = false
local productById: {[number]: ProductDefinition} = {}

for _, product in ipairs(CashProductConfig.PRODUCTS) do
	productById[product.ProductId] = product
end

local function processReceipt(receiptInfo): Enum.ProductPurchaseDecision
	if receiptInfo.ProductId == CashProductConfig.DONATE_PRODUCT_ID then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local product = productById[receiptInfo.ProductId]
	if not product then
		local skinCaseDecision = SkinCaseService.ProcessReceipt(receiptInfo)
		if skinCaseDecision then
			return skinCaseDecision
		end
		warn(`[DeveloperProducts] Unknown developer product id: {tostring(receiptInfo.ProductId)}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not (CurrencyService.IsLoaded(player) or CurrencyService.AwaitLoaded(player, 30)) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local granted, _, reason = CurrencyService.GrantDeveloperProduct(
		player,
		tostring(receiptInfo.PurchaseId),
		product.Amount,
		`DeveloperProduct:{product.Key}`
	)
	if granted then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	warn(
		`[CashProducts] Could not grant {product.Amount} Coins to {player.Name}: {tostring(reason)}`
	)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function CashProductService.Start()
	if started then
		return
	end
	started = true
	CurrencyService.Start()
	SkinCaseService.Start()

	for _, product in ipairs(CashProductConfig.PRODUCTS) do
		assert(
			type(product.ProductId) == "number" and product.ProductId > 0,
			`{product.Key} developer product id must be a positive number`
		)
		assert(
			type(product.Amount) == "number" and product.Amount > 0,
			`{product.Key} amount must be a positive number`
		)
	end

	MarketplaceService.ProcessReceipt = processReceipt
end

return CashProductService
