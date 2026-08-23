--!strict

local CurrencyCore = {}

local function isFiniteInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
end

function CurrencyCore.IsValidBalance(value: any, maxBalance: number): boolean
	return isFiniteInteger(value) and value >= 0 and value <= maxBalance
end

function CurrencyCore.IsValidStat(value: any, maxStatValue: number): boolean
	return isFiniteInteger(value) and value >= 0 and value <= maxStatValue
end

local function cloneOwnedWeapons(raw: any): {[string]: boolean}
	local ownedWeapons: {[string]: boolean} = {}
	if type(raw) ~= "table" then
		return ownedWeapons
	end
	for weaponName, owned in pairs(raw) do
		if type(weaponName) == "string"
			and #weaponName >= 1
			and #weaponName <= 64
			and owned == true then
			ownedWeapons[weaponName] = true
		end
	end
	return ownedWeapons
end

local function cloneOwnedSkins(raw: any): {[string]: boolean}
	local ownedSkins: {[string]: boolean} = {}
	if type(raw) ~= "table" then
		return ownedSkins
	end
	for skinId, owned in pairs(raw) do
		if type(skinId) == "string"
			and #skinId >= 1
			and #skinId <= 64
			and owned == true then
			ownedSkins[skinId] = true
		end
	end
	return ownedSkins
end

local function cloneDeveloperProductReceipts(raw: any): {[string]: number}
	local receipts: {[string]: number} = {}
	if type(raw) ~= "table" then
		return receipts
	end
	for purchaseId, processedAt in pairs(raw) do
		if type(purchaseId) == "string"
			and #purchaseId >= 1
			and #purchaseId <= 128
			and isFiniteInteger(processedAt) then
			receipts[purchaseId] = processedAt
		end
	end
	return receipts
end

local function cloneSkinCaseRollCounts(raw: any): {[string]: number}
	local rollCounts: {[string]: number} = {}
	if type(raw) ~= "table" then
		return rollCounts
	end
	for caseId, rollCount in pairs(raw) do
		if type(caseId) == "string"
			and #caseId >= 1
			and #caseId <= 64
			and isFiniteInteger(rollCount)
			and rollCount >= 0 then
			rollCounts[caseId] = rollCount
		end
	end
	return rollCounts
end

function CurrencyCore.CloneData(data: any): {[string]: any}
	return {
		Currency = data.Currency,
		OwnedWeapons = cloneOwnedWeapons(data.OwnedWeapons),
		OwnedSkins = cloneOwnedSkins(data.OwnedSkins),
		EquippedSkin = if type(data.EquippedSkin) == "string" then data.EquippedSkin else nil,
		DeveloperProductReceipts = cloneDeveloperProductReceipts(data.DeveloperProductReceipts),
		SkinCaseRollCounts = cloneSkinCaseRollCounts(data.SkinCaseRollCounts),
		Wins = data.Wins,
		PlayTimeSeconds = data.PlayTimeSeconds,
	}
end

function CurrencyCore.NormalizeStored(
	raw: any,
	expectedVersion: number,
	startingCurrency: number,
	maxBalance: number,
	maxStatValue: number
)
	if raw == nil then
		return {
			Version = expectedVersion,
			Data = {
				Currency = startingCurrency,
				OwnedWeapons = {},
				OwnedSkins = {},
				EquippedSkin = nil,
				DeveloperProductReceipts = {},
				SkinCaseRollCounts = {},
				Wins = 0,
				PlayTimeSeconds = 0,
			},
			SessionId = nil,
			SessionStart = 0,
			SaveTime = 0,
			Closed = true,
			UpdatedAt = 0,
		}
	end

	-- Support a simple number and the old Cash/Currency table shapes so data can
	-- be migrated into the extensible profile without a manual conversion job.
	if CurrencyCore.IsValidBalance(raw, maxBalance) then
		return {
			Version = expectedVersion,
			Data = {
				Currency = raw,
				OwnedWeapons = {},
				OwnedSkins = {},
				EquippedSkin = nil,
				DeveloperProductReceipts = {},
				SkinCaseRollCounts = {},
				Wins = 0,
				PlayTimeSeconds = 0,
			},
			SessionId = nil,
			SessionStart = 0,
			SaveTime = 0,
			Closed = false,
			UpdatedAt = 0,
		}
	end

	if type(raw) ~= "table" then
		return nil, "CORRUPT_DATA"
	end
	if isFiniteInteger(raw.Version) and raw.Version > expectedVersion then
		return nil, "UNSUPPORTED_VERSION"
	end

	local rawData = if type(raw.Data) == "table" then raw.Data else raw
	local currency = rawData.Currency
	if currency == nil then
		currency = raw.Cash
	end
	if not CurrencyCore.IsValidBalance(currency, maxBalance) then
		return nil, "INVALID_CURRENCY"
	end

	local wins = rawData.Wins
	if wins == nil then
		wins = 0
	end
	if not CurrencyCore.IsValidStat(wins, maxStatValue) then
		return nil, "INVALID_WINS"
	end

	local playTimeSeconds = rawData.PlayTimeSeconds
	if playTimeSeconds == nil then
		playTimeSeconds = 0
	end
	if not CurrencyCore.IsValidStat(playTimeSeconds, maxStatValue) then
		return nil, "INVALID_PLAY_TIME"
	end

	return {
		Version = expectedVersion,
		Data = {
			Currency = currency,
			OwnedWeapons = cloneOwnedWeapons(rawData.OwnedWeapons),
			OwnedSkins = cloneOwnedSkins(rawData.OwnedSkins),
			EquippedSkin = if type(rawData.EquippedSkin) == "string" then rawData.EquippedSkin else nil,
			DeveloperProductReceipts = cloneDeveloperProductReceipts(rawData.DeveloperProductReceipts),
			SkinCaseRollCounts = cloneSkinCaseRollCounts(rawData.SkinCaseRollCounts),
			Wins = wins,
			PlayTimeSeconds = playTimeSeconds,
		},
		SessionId = if type(raw.SessionId) == "string" then raw.SessionId else nil,
		SessionStart = if isFiniteInteger(raw.SessionStart) then raw.SessionStart else 0,
		SaveTime = if isFiniteInteger(raw.SaveTime) then raw.SaveTime else 0,
		Closed = if type(raw.Closed) == "boolean" then raw.Closed else false,
		UpdatedAt = if isFiniteInteger(raw.UpdatedAt) then raw.UpdatedAt else 0,
	}
end

function CurrencyCore.CanWriteSave(
	existing: any,
	sessionId: string,
	sessionStart: number,
	saveTime: number
)
	if type(existing) ~= "table" then
		return true
	end

	local existingSessionStart = if isFiniteInteger(existing.SessionStart)
		then existing.SessionStart
		else 0
	if existingSessionStart > sessionStart then
		return false, "NEWER_SESSION_START"
	end
	if existingSessionStart < sessionStart then
		return true
	end

	if isFiniteInteger(existing.SaveTime) and existing.SaveTime > saveTime then
		if existing.SessionId == sessionId then
			return false, "OLDER_SAME_SESSION_SAVE"
		end
		return false, "NEWER_SESSION_SAVE"
	end

	return true
end

function CurrencyCore.ApplyDelta(
	balance: number,
	delta: number,
	maxBalance: number,
	maxTransaction: number
)
	if not isFiniteInteger(delta) or delta == 0 or math.abs(delta) > maxTransaction then
		return nil, "INVALID_AMOUNT"
	end
	if not CurrencyCore.IsValidBalance(balance, maxBalance) then
		return nil, "INVALID_BALANCE"
	end

	local nextBalance = balance + delta
	if nextBalance < 0 then
		return nil, "INSUFFICIENT_FUNDS"
	end
	if nextBalance > maxBalance or not isFiniteInteger(nextBalance) then
		return nil, "BALANCE_LIMIT"
	end
	return nextBalance
end

return CurrencyCore
