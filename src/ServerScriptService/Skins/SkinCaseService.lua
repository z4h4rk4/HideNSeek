--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage:WaitForChild("SkinCaseConfig"))
local CurrencyService = require(
	game:GetService("ServerScriptService"):WaitForChild("Currency"):WaitForChild("CurrencyService")
)

type SkinDefinition = {
	Id: string,
	DisplayName: string,
	Rarity: string,
	Weight: number,
}

type CaseDefinition = {
	Id: string,
	DisplayName: string,
	CoinPrice: number,
	RobuxProductId: number,
	Skins: {SkinDefinition},
}

local SkinCaseService = {}
local started = false
local remote: RemoteFunction? = nil
local caseById: {[string]: CaseDefinition} = {}
local caseByProductId: {[number]: CaseDefinition} = {}
local lastRobuxResults: {[Player]: any} = {}
local paidRandomRestrictedByPlayer: {[Player]: boolean} = {}
local policyWarnedByPlayer: {[Player]: boolean} = {}
local caseOperationLocks: {[Player]: boolean} = {}

for caseId, caseDefinition in pairs(Config.CASES) do
	caseById[caseId] = caseDefinition
	caseByProductId[caseDefinition.RobuxProductId] = caseDefinition
end

local function getDuplicateReward(skin: SkinDefinition): number
	local rarity = Config.RARITIES[skin.Rarity]
	return if rarity and type(rarity.DuplicateCoins) == "number" then rarity.DuplicateCoins else 0
end

local function getSkin(caseDefinition: CaseDefinition, skinId: string): SkinDefinition?
	for _, skin in ipairs(caseDefinition.Skins) do
		if skin.Id == skinId then
			return skin
		end
	end
	return nil
end

local function getSkinCatalog()
	local catalog = {}
	for caseId, caseDefinition in pairs(caseById) do
		local skins = {}
		for _, skin in ipairs(caseDefinition.Skins) do
			table.insert(skins, {
				Id = skin.Id,
				DisplayName = skin.DisplayName,
				Rarity = skin.Rarity,
				DuplicateCoins = getDuplicateReward(skin),
			})
		end
		catalog[caseId] = {
			Id = caseDefinition.Id,
			DisplayName = caseDefinition.DisplayName,
			CoinPrice = caseDefinition.CoinPrice,
			RobuxProductId = caseDefinition.RobuxProductId,
			Skins = skins,
		}
	end
	return catalog
end

local function publishSkinAttributes(player: Player)
	local ownedSkins = CurrencyService.GetOwnedSkins(player) or {}
	for _, caseDefinition in pairs(caseById) do
		for _, skin in ipairs(caseDefinition.Skins) do
			player:SetAttribute(`SkinOwned_{skin.Id}`, if ownedSkins[skin.Id] == true then true else nil)
		end
	end
	player:SetAttribute("EquippedSkin", CurrencyService.GetEquippedSkin(player))
end

local function validateSkinTemplates()
	local characters = ServerStorage:FindFirstChild(Config.CHARACTERS_FOLDER_NAME)
	local starterPack = characters and characters:FindFirstChild(Config.STARTER_PACK_FOLDER_NAME)
	if not starterPack then
		warn(
			`[SkinCase] ServerStorage.{Config.CHARACTERS_FOLDER_NAME}.`
				.. `{Config.STARTER_PACK_FOLDER_NAME} not found`
		)
		return
	end

	for _, caseDefinition in pairs(caseById) do
		for _, skin in ipairs(caseDefinition.Skins) do
			local template = starterPack:FindFirstChild(skin.Id)
			if not template then
				warn(
					`[SkinCase] Missing skin template ServerStorage.{Config.CHARACTERS_FOLDER_NAME}.`
						.. `{Config.STARTER_PACK_FOLDER_NAME}.{skin.Id}`
				)
			elseif not template:IsA("Model") then
				warn(`[SkinCase] Skin template {template:GetFullName()} must be a Model`)
			end
		end
	end
end

local function rollSkin(caseDefinition: CaseDefinition): SkinDefinition
	local totalWeight = 0
	for _, skin in ipairs(caseDefinition.Skins) do
		if type(skin.Weight) == "number" and skin.Weight > 0 then
			totalWeight += skin.Weight
		end
	end
	assert(totalWeight > 0, `[SkinCase] {caseDefinition.Id} needs at least one positive skin weight`)

	local roll = math.random() * totalWeight
	local cursor = 0
	for _, skin in ipairs(caseDefinition.Skins) do
		if type(skin.Weight) == "number" and skin.Weight > 0 then
			cursor += skin.Weight
			if roll <= cursor then
				return skin
			end
		end
	end
	return caseDefinition.Skins[#caseDefinition.Skins]
end

local function isPaidRandomItemsRestricted(player: Player): boolean
	local cached = paidRandomRestrictedByPlayer[player]
	if cached ~= nil then
		return cached
	end

	local succeeded, policyInfo = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	local restricted = true
	if succeeded and type(policyInfo) == "table" then
		restricted = policyInfo.ArePaidRandomItemsRestricted == true
	elseif not policyWarnedByPlayer[player] then
		policyWarnedByPlayer[player] = true
		warn(
			`[SkinCase] PolicyService failed for {player.Name}; `
				.. "using deterministic case rewards as a safe fallback"
		)
	end

	paidRandomRestrictedByPlayer[player] = restricted
	player:SetAttribute("PaidRandomItemsRestricted", restricted)
	return restricted
end

local function getSkinsByRarity(caseDefinition: CaseDefinition, rarity: string): {SkinDefinition}
	local skins = {}
	for _, skin in ipairs(caseDefinition.Skins) do
		if skin.Rarity == rarity then
			table.insert(skins, skin)
		end
	end
	return skins
end

local function countScheduledRarityAwardsBefore(rollNumber: number, rarity: string): number
	local previousRolls = math.max(0, rollNumber - 1)
	if rarity == "Legend" then
		return math.floor(previousRolls / 100)
	end
	if rarity == "Mystic" then
		return math.floor(previousRolls / 50) - math.floor(previousRolls / 100)
	end
	if rarity == "Rare" then
		return math.floor(previousRolls / 25) - math.floor(previousRolls / 50)
	end
	return previousRolls - math.floor(previousRolls / 25)
end

local function chooseDeterministicSkin(caseDefinition: CaseDefinition, rollNumber: number): SkinDefinition
	local rarity = "Common"
	if rollNumber % 100 == 0 then
		rarity = "Legend"
	elseif rollNumber % 50 == 0 then
		rarity = "Mystic"
	elseif rollNumber % 25 == 0 then
		rarity = "Rare"
	end

	local skins = getSkinsByRarity(caseDefinition, rarity)
	if #skins == 0 then
		return caseDefinition.Skins[1]
	end
	local awardIndex = countScheduledRarityAwardsBefore(rollNumber, rarity) + 1
	return skins[((awardIndex - 1) % #skins) + 1]
end

local function selectSkin(player: Player, caseDefinition: CaseDefinition, rollOffset: number): SkinDefinition
	if not isPaidRandomItemsRestricted(player) then
		return rollSkin(caseDefinition)
	end

	local currentRollCount = CurrencyService.GetSkinCaseRollCount(player, caseDefinition.Id)
	return chooseDeterministicSkin(caseDefinition, currentRollCount + rollOffset)
end

local function beginCaseOperation(player: Player): boolean
	if caseOperationLocks[player] then
		return false
	end
	caseOperationLocks[player] = true
	return true
end

local function finishCaseOperation(player: Player)
	caseOperationLocks[player] = nil
end

local function describeResult(caseDefinition: CaseDefinition, result)
	local skin = getSkin(caseDefinition, result.SkinId)
	return {
		SkinId = result.SkinId,
		DisplayName = if skin then skin.DisplayName else result.SkinId,
		Rarity = if skin then skin.Rarity else "Unknown",
		Duplicate = result.Duplicate == true,
		DuplicateCoins = result.DuplicateCoins or 0,
	}
end

local function describeResults(caseDefinition: CaseDefinition, results)
	local described = {}
	for _, result in ipairs(results) do
		table.insert(described, describeResult(caseDefinition, result))
	end
	return described
end

local function getState(player: Player)
	publishSkinAttributes(player)
	return {
		Loaded = CurrencyService.IsLoaded(player),
		Cases = getSkinCatalog(),
		OwnedSkins = CurrencyService.GetOwnedSkins(player) or {},
		EquippedSkin = CurrencyService.GetEquippedSkin(player),
	}
end

local function openWithCoins(player: Player, caseId: string, quantity: number)
	local caseDefinition = caseById[caseId]
	if not caseDefinition then
		return false, "UNKNOWN_CASE"
	end
	if type(quantity) ~= "number" or quantity ~= quantity then
		return false, "INVALID_QUANTITY"
	end
	quantity = math.clamp(math.floor(quantity), 1, Config.MAX_COIN_OPEN_QUANTITY)

	if not beginCaseOperation(player) then
		return false, "CASE_BUSY"
	end

	local callSucceeded, success, payloadOrReason = pcall(function()
		local rolledSkinIds: {string} = {}
		local duplicateRewards: {[string]: number} = {}
		for rollOffset = 1, quantity do
			local skin = selectSkin(player, caseDefinition, rollOffset)
			table.insert(rolledSkinIds, skin.Id)
			duplicateRewards[skin.Id] = getDuplicateReward(skin)
		end

		local purchaseSuccess, payload, reason = CurrencyService.PurchaseSkinCaseRolls(
			player,
			caseDefinition.CoinPrice * quantity,
			rolledSkinIds,
			duplicateRewards,
			`SkinCase:{caseDefinition.Id}:Coins`,
			caseDefinition.Id
		)
		if not purchaseSuccess then
			return false, reason
		end

		publishSkinAttributes(player)
		payload.CaseId = caseDefinition.Id
		payload.Results = describeResults(caseDefinition, payload.Results)
		return true, payload
	end)
	finishCaseOperation(player)

	if not callSucceeded then
		warn(`[SkinCase] Coin open failed for {player.Name}: {tostring(success)}`)
		return false, "SERVER_ERROR"
	end
	return success, payloadOrReason
end

local function equipSkin(player: Player, skinId: string)
	local success, reason = CurrencyService.EquipSkin(player, skinId, "SkinInventory:Equip")
	if not success then
		return false, reason
	end
	publishSkinAttributes(player)
	return true, getState(player)
end

function SkinCaseService.ProcessReceipt(receiptInfo): Enum.ProductPurchaseDecision?
	local caseDefinition = caseByProductId[receiptInfo.ProductId]
	if not caseDefinition then
		return nil
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not (CurrencyService.IsLoaded(player) or CurrencyService.AwaitLoaded(player, 30)) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not beginCaseOperation(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local callSucceeded, granted, payload, reason = pcall(function()
		local skin = selectSkin(player, caseDefinition, 1)
		return CurrencyService.GrantDeveloperProductSkinCaseRoll(
			player,
			tostring(receiptInfo.PurchaseId),
			skin.Id,
			getDuplicateReward(skin),
			`SkinCase:{caseDefinition.Id}:Robux`,
			caseDefinition.Id
		)
	end)
	finishCaseOperation(player)
	if not callSucceeded then
		warn(`[SkinCase] Robux case processing failed for {player.Name}: {tostring(granted)}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not granted then
		warn(`[SkinCase] Could not grant Robux case to {player.Name}: {tostring(reason)}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if payload and not payload.AlreadyGranted and payload.Result then
		publishSkinAttributes(player)
		payload.CaseId = caseDefinition.Id
		payload.Results = { describeResult(caseDefinition, payload.Result) }
		lastRobuxResults[player] = payload
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function SkinCaseService.Start()
	if started then
		return
	end
	started = true
	CurrencyService.Start()
	validateSkinTemplates()

	local existing = ReplicatedStorage:FindFirstChild(Config.REMOTE_NAME)
	if existing then
		if not existing:IsA("RemoteFunction") then
			error(`ReplicatedStorage.{Config.REMOTE_NAME} must be a RemoteFunction`)
		end
		remote = existing
	else
		local created = Instance.new("RemoteFunction")
		created.Name = Config.REMOTE_NAME
		created.Parent = ReplicatedStorage
		remote = created
	end

	remote.OnServerInvoke = function(player: Player, action: string, payload)
		if action == "GetState" then
			return true, getState(player)
		end
		if action == "OpenCoins" then
			local caseId = if type(payload) == "table" then payload.CaseId else nil
			local quantity = if type(payload) == "table" then payload.Quantity else 1
			return openWithCoins(player, caseId, quantity)
		end
		if action == "EquipSkin" then
			local skinId = if type(payload) == "table" then payload.SkinId else nil
			if type(skinId) ~= "string" then
				return false, "INVALID_SKIN"
			end
			return equipSkin(player, skinId)
		end
		if action == "ConsumeLastRobuxResult" then
			local result = lastRobuxResults[player]
			lastRobuxResults[player] = nil
			return true, result
		end
		return false, "UNKNOWN_ACTION"
	end

	Players.PlayerRemoving:Connect(function(player)
		lastRobuxResults[player] = nil
		paidRandomRestrictedByPlayer[player] = nil
		policyWarnedByPlayer[player] = nil
		caseOperationLocks[player] = nil
	end)
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			if player.Parent == Players then
				isPaidRandomItemsRestricted(player)
			end
		end)
		task.spawn(function()
			if CurrencyService.AwaitLoaded(player, 30) and player.Parent == Players then
				publishSkinAttributes(player)
			end
		end)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			if player.Parent == Players then
				isPaidRandomItemsRestricted(player)
			end
		end)
		task.spawn(function()
			if CurrencyService.AwaitLoaded(player, 30) and player.Parent == Players then
				publishSkinAttributes(player)
			end
		end)
	end
end

return SkinCaseService
