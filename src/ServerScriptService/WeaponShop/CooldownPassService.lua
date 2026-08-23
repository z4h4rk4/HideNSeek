--!strict

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("CooldownPassConfig"))
local CurrencyService = require(
	ServerScriptService:WaitForChild("Currency"):WaitForChild("CurrencyService")
)

type PassDefinition = {
	Key: string,
	GamePassId: number,
	OwnedAttribute: string,
	ReadyAttribute: string,
}

local Service = {}
local started = false
local syncRevisions: {[Player]: number} = {}
local warnedOwnershipFailure: {[Player]: {[string]: boolean}} = {}
local verifiedOwnership: {[Player]: {[string]: boolean}} = {}
local verifiedOwnershipReady: {[Player]: {[string]: boolean}} = {}
local testOverrides: {[Player]: boolean?} = {}
local vipBonusLocks: {[Player]: boolean} = {}
local cashRemainders: {[Player]: number} = {}

local vipBonusStore = DataStoreService:GetDataStore("VIPPassBonusGrants_v1")

local PASS_DEFINITIONS: {PassDefinition} = {
	{
		Key = "Cooldown",
		GamePassId = Config.GAME_PASS_ID,
		OwnedAttribute = Config.OWNED_ATTRIBUTE,
		ReadyAttribute = Config.OWNERSHIP_READY_ATTRIBUTE,
	},
	{
		Key = "VIP",
		GamePassId = Config.VIP_GAME_PASS_ID,
		OwnedAttribute = Config.VIP_OWNED_ATTRIBUTE,
		ReadyAttribute = Config.VIP_OWNERSHIP_READY_ATTRIBUTE,
	},
	{
		Key = "x2Cash",
		GamePassId = Config.X2_CASH_GAME_PASS_ID,
		OwnedAttribute = Config.X2_CASH_OWNED_ATTRIBUTE,
		ReadyAttribute = Config.X2_CASH_OWNERSHIP_READY_ATTRIBUTE,
	},
}

local passByGamePassId: {[number]: PassDefinition} = {}
for _, passDefinition in ipairs(PASS_DEFINITIONS) do
	passByGamePassId[passDefinition.GamePassId] = passDefinition
end

local function getKey(player: Player): string
	return tostring(player.UserId)
end

local function ensureBooleanPlayerMap(store: {[Player]: {[string]: boolean}}, player: Player): {[string]: boolean}
	local map = store[player]
	if not map then
		map = {}
		store[player] = map
	end
	return map
end

local function getVerified(player: Player, store: {[Player]: {[string]: boolean}}, key: string): boolean
	local map = store[player]
	return map ~= nil and map[key] == true
end

local function applyEntitlement(player: Player, passDefinition: PassDefinition)
	local owned = getVerified(player, verifiedOwnership, passDefinition.Key)
	local ready = getVerified(player, verifiedOwnershipReady, passDefinition.Key)

	if passDefinition.Key == "Cooldown" then
		local testOverride = testOverrides[player]
		if testOverride ~= nil then
			owned = testOverride
			ready = true
		end
		player:SetAttribute(Config.TEST_OVERRIDE_ATTRIBUTE, testOverride)
	end

	player:SetAttribute(passDefinition.OwnedAttribute, owned)
	player:SetAttribute(passDefinition.ReadyAttribute, ready)
end

local function setVerifiedOwnership(
	player: Player,
	passDefinition: PassDefinition,
	owned: boolean,
	ready: boolean
)
	ensureBooleanPlayerMap(verifiedOwnership, player)[passDefinition.Key] = owned
	ensureBooleanPlayerMap(verifiedOwnershipReady, player)[passDefinition.Key] = ready
	applyEntitlement(player, passDefinition)
end

local function recordVipBonusStatus(player: Player, granted: boolean?)
	player:SetAttribute(Config.VIP_BONUS_GRANTED_ATTRIBUTE, if granted == true then true else nil)
end

local function recordIsGranted(raw: any): boolean
	if raw == true then
		return true
	end
	return type(raw) == "table" and raw.Status == "Granted"
end

local function recordIsPending(raw: any, now: number): boolean
	return type(raw) == "table"
		and raw.Status == "Pending"
		and type(raw.PendingAt) == "number"
		and now - raw.PendingAt < 300
end

local function reserveVipBonus(player: Player): (boolean, string?)
	local now = os.time()
	local alreadyGranted = false
	local pending = false
	local reserved = false
	local success, updateError = pcall(function()
		vipBonusStore:UpdateAsync(getKey(player), function(current)
			if recordIsGranted(current) then
				alreadyGranted = true
				return current
			end
			if recordIsPending(current, now) then
				pending = true
				return current
			end
			reserved = true
			return {
				Status = "Pending",
				PendingAt = now,
			}
		end)
	end)

	if not success then
		warn(`[GamePass] VIP bonus reserve failed for {player.Name}: {tostring(updateError)}`)
		return false, "DATASTORE_WRITE_FAILED"
	end
	if alreadyGranted then
		recordVipBonusStatus(player, true)
		return false, "ALREADY_GRANTED"
	end
	if pending then
		return false, "PENDING"
	end
	return reserved, if reserved then nil else "NOT_RESERVED"
end

local function finishVipBonus(player: Player): boolean
	local completed = false
	local updateError: any = nil
	for attempt = 1, 3 do
		local success, err = pcall(function()
			vipBonusStore:UpdateAsync(getKey(player), function(current)
				if recordIsGranted(current) then
					completed = true
					return current
				end
				completed = true
				return {
					Status = "Granted",
					GrantedAt = os.time(),
				}
			end)
		end)
		if success then
			updateError = nil
			break
		end
		updateError = err
		task.wait(0.25 * attempt)
	end

	if updateError and not completed then
		warn(`[GamePass] VIP bonus finish failed for {player.Name}: {tostring(updateError)}`)
		return false
	end
	recordVipBonusStatus(player, true)
	return completed
end

local function clearVipBonusReservation(player: Player)
	local success, updateError = pcall(function()
		vipBonusStore:UpdateAsync(getKey(player), function(current)
			if type(current) == "table" and current.Status == "Pending" then
				return {
					Status = "Open",
					ClearedAt = os.time(),
				}
			end
			return current
		end)
	end)
	if not success then
		warn(`[GamePass] VIP bonus clear failed for {player.Name}: {tostring(updateError)}`)
	end
end

local function grantVipBonus(player: Player)
	if vipBonusLocks[player] or player.Parent ~= Players then
		return
	end
	vipBonusLocks[player] = true

	task.spawn(function()
		local reserved, reserveReason = reserveVipBonus(player)
		if not reserved then
			if reserveReason ~= "ALREADY_GRANTED" and reserveReason ~= "PENDING" then
				warn(`[GamePass] VIP bonus not reserved for {player.Name}: {tostring(reserveReason)}`)
			end
			vipBonusLocks[player] = nil
			return
		end

		if not (CurrencyService.IsLoaded(player) or CurrencyService.AwaitLoaded(player, 30)) then
			clearVipBonusReservation(player)
			vipBonusLocks[player] = nil
			return
		end

		local added, _, addReason = CurrencyService.AddCurrency(
			player,
			Config.VIP_BONUS_CURRENCY,
			"VIPPassBonus"
		)
		if not added then
			clearVipBonusReservation(player)
			warn(`[GamePass] VIP bonus grant failed for {player.Name}: {tostring(addReason)}`)
			vipBonusLocks[player] = nil
			return
		end

		local finished = finishVipBonus(player)
		if not finished then
			task.spawn(function()
				for attempt = 1, 10 do
					if player.Parent ~= Players then
						vipBonusLocks[player] = nil
						return
					end
					task.wait(math.min(2 ^ attempt, 60))
					if finishVipBonus(player) then
						vipBonusLocks[player] = nil
						return
					end
				end
				vipBonusLocks[player] = nil
			end)
			return
		end
		vipBonusLocks[player] = nil
	end)
end

local function syncPassOwnership(
	player: Player,
	passDefinition: PassDefinition,
	revision: number,
	preserveCurrentState: boolean?
)
	if not preserveCurrentState then
		setVerifiedOwnership(player, passDefinition, false, false)
	end
	task.spawn(function()
		local retryDelay = Config.OWNERSHIP_RETRY_INITIAL_SECONDS
		while player.Parent == Players and syncRevisions[player] == revision do
			local succeeded, ownsPass = pcall(
				MarketplaceService.UserOwnsGamePassAsync,
				MarketplaceService,
				player.UserId,
				passDefinition.GamePassId
			)
			if succeeded then
				local warned = warnedOwnershipFailure[player]
				if warned then
					warned[passDefinition.Key] = nil
				end
				if player.Parent == Players and syncRevisions[player] == revision then
					setVerifiedOwnership(player, passDefinition, ownsPass == true, true)
					if passDefinition.Key == "VIP" and ownsPass == true then
						grantVipBonus(player)
					end
				end
				return
			end

			local warned = ensureBooleanPlayerMap(warnedOwnershipFailure, player)
			if not warned[passDefinition.Key] then
				warned[passDefinition.Key] = true
				warn(
					`{passDefinition.Key}Pass: ownership check failed for {player.Name}; `
						.. "the benefit stays locked until Roblox confirms ownership"
				)
			end
			task.wait(retryDelay)
			retryDelay = math.min(retryDelay * 2, Config.OWNERSHIP_RETRY_MAX_SECONDS)
		end
	end)
end

local function syncOwnership(player: Player)
	local revision = (syncRevisions[player] or 0) + 1
	syncRevisions[player] = revision
	recordVipBonusStatus(player, nil)
	for _, passDefinition in ipairs(PASS_DEFINITIONS) do
		syncPassOwnership(player, passDefinition, revision)
	end
end

function Service.GetState(player: Player): {[string]: any}
	local testOverride = testOverrides[player]
	return {
		GamePassId = Config.GAME_PASS_ID,
		RealOwnershipReady = getVerified(player, verifiedOwnershipReady, "Cooldown"),
		RealOwned = getVerified(player, verifiedOwnership, "Cooldown"),
		EffectiveOwned = player:GetAttribute(Config.OWNED_ATTRIBUTE) == true,
		TestMode = if testOverride == nil
			then "Roblox"
			elseif testOverride
			then "Owned"
			else "Unowned",
		VIPOwned = player:GetAttribute(Config.VIP_OWNED_ATTRIBUTE) == true,
		X2CashOwned = player:GetAttribute(Config.X2_CASH_OWNED_ATTRIBUTE) == true,
	}
end

function Service.SetTestOverride(player: Player, override: boolean?): (boolean, any)
	if player.Parent ~= Players then
		return false, "TARGET_NOT_IN_SERVER"
	end
	if override ~= nil and type(override) ~= "boolean" then
		return false, "INVALID_OVERRIDE"
	end

	testOverrides[player] = override
	applyEntitlement(player, PASS_DEFINITIONS[1])
	return true, Service.GetState(player)
end

function Service.GetCashMultiplier(player: Player): number
	local multiplier = 1
	if player:GetAttribute(Config.VIP_OWNED_ATTRIBUTE) == true then
		multiplier *= Config.VIP_CURRENCY_MULTIPLIER
	end
	if player:GetAttribute(Config.X2_CASH_OWNED_ATTRIBUTE) == true then
		multiplier *= Config.X2_CASH_MULTIPLIER
	end
	return multiplier
end

function Service.ApplyCashMultiplier(player: Player, baseAmount: number): (number, number)
	if type(baseAmount) ~= "number" or baseAmount <= 0 then
		return 0, cashRemainders[player] or 0
	end
	local previousRemainder = cashRemainders[player] or 0
	local scaled = baseAmount * Service.GetCashMultiplier(player)
	local total = scaled + previousRemainder
	local whole = math.floor(total)
	cashRemainders[player] = total - whole
	return math.max(1, whole), previousRemainder
end

function Service.RestoreCashMultiplierRemainder(player: Player, previousRemainder: number)
	if type(previousRemainder) == "number" and previousRemainder >= 0 and previousRemainder < 1 then
		cashRemainders[player] = previousRemainder
	end
end

function Service.Start()
	if started then
		return
	end
	started = true
	for _, passDefinition in ipairs(PASS_DEFINITIONS) do
		assert(
			type(passDefinition.GamePassId) == "number" and passDefinition.GamePassId > 0,
			`{passDefinition.Key} game pass id must be a positive number`
		)
	end
	assert(
		type(Config.COOLDOWN_MULTIPLIER) == "number"
			and Config.COOLDOWN_MULTIPLIER > 0
			and Config.COOLDOWN_MULTIPLIER <= 1,
		"CooldownPassConfig.COOLDOWN_MULTIPLIER must be in (0, 1]"
	)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(
		player: Player,
		gamePassId: number,
		wasPurchased: boolean
	)
		local passDefinition = passByGamePassId[gamePassId]
		if not wasPurchased or not passDefinition or player.Parent ~= Players then
			return
		end

		local revision = (syncRevisions[player] or 0) + 1
		syncRevisions[player] = revision
		local warned = warnedOwnershipFailure[player]
		if warned then
			warned[passDefinition.Key] = nil
		end
		if passDefinition.Key == "Cooldown" then
			testOverrides[player] = nil
		end
		setVerifiedOwnership(player, passDefinition, true, true)
		if passDefinition.Key == "VIP" then
			grantVipBonus(player)
		end
		for _, otherPassDefinition in ipairs(PASS_DEFINITIONS) do
			if otherPassDefinition ~= passDefinition then
				syncPassOwnership(player, otherPassDefinition, revision, true)
			end
		end
	end)

	Players.PlayerAdded:Connect(syncOwnership)
	Players.PlayerRemoving:Connect(function(player)
		syncRevisions[player] = nil
		warnedOwnershipFailure[player] = nil
		verifiedOwnership[player] = nil
		verifiedOwnershipReady[player] = nil
		testOverrides[player] = nil
		vipBonusLocks[player] = nil
		cashRemainders[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		syncOwnership(player)
	end
end

return Service
