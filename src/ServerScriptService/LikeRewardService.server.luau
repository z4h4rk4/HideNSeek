--!strict

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CurrencyService = require(ServerScriptService:WaitForChild("Currency"):WaitForChild("CurrencyService"))

local DATASTORE_NAME = "LikeRewardClaimStore_v1"
local REMOTE_NAME = "LikeRewardRemote"
local RESET_REMOTE_NAME = "LikeRewardResetRemote"
local ADMIN_RESET_BINDABLE_NAME = "LikeRewardAdminReset"
local REWARD_AMOUNT = 100
local PENDING_EXPIRY_SECONDS = 300

type ClaimRecord = {
	Status: string?,
	Claimed: boolean?,
	ClaimedAt: number?,
	PendingAt: number?,
	GrantId: string?,
}

local likeRewardStore = DataStoreService:GetDataStore(DATASTORE_NAME)
local claimLocks: {[number]: boolean} = {}

local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
if existing and not existing:IsA("RemoteFunction") then
	error(`ReplicatedStorage.{REMOTE_NAME} must be a RemoteFunction`)
end

local remoteFunction: RemoteFunction = if existing
	then existing :: RemoteFunction
	else Instance.new("RemoteFunction") :: RemoteFunction
remoteFunction.Name = REMOTE_NAME
remoteFunction.Parent = ReplicatedStorage

local existingResetRemote = ReplicatedStorage:FindFirstChild(RESET_REMOTE_NAME)
if existingResetRemote and not existingResetRemote:IsA("RemoteEvent") then
	error(`ReplicatedStorage.{RESET_REMOTE_NAME} must be a RemoteEvent`)
end

local resetRemote: RemoteEvent = if existingResetRemote
	then existingResetRemote :: RemoteEvent
	else Instance.new("RemoteEvent") :: RemoteEvent
resetRemote.Name = RESET_REMOTE_NAME
resetRemote.Parent = ReplicatedStorage

local existingAdminReset = ServerScriptService:FindFirstChild(ADMIN_RESET_BINDABLE_NAME)
if existingAdminReset and not existingAdminReset:IsA("BindableFunction") then
	error(`ServerScriptService.{ADMIN_RESET_BINDABLE_NAME} must be a BindableFunction`)
end

local adminResetBindable: BindableFunction = if existingAdminReset
	then existingAdminReset :: BindableFunction
	else Instance.new("BindableFunction") :: BindableFunction
adminResetBindable.Name = ADMIN_RESET_BINDABLE_NAME
adminResetBindable.Parent = ServerScriptService

local function getKey(player: Player): string
	return tostring(player.UserId)
end

local function recordIsClaimed(raw: any): boolean
	if raw == true then
		return true
	end
	if type(raw) ~= "table" then
		return false
	end
	local record = raw :: ClaimRecord
	return record.Claimed == true or record.Status == "Claimed"
end

local function recordIsPending(raw: any, now: number): boolean
	if type(raw) ~= "table" then
		return false
	end
	local record = raw :: ClaimRecord
	if record.Status ~= "Pending" then
		return false
	end
	local pendingAt = record.PendingAt
	return type(pendingAt) == "number" and now - pendingAt < PENDING_EXPIRY_SECONDS
end

local function checkIfPlayerLiked(_player: Player): boolean
	-- Roblox does not expose a server API for checking whether a player liked the game.
	-- Treat this as a one-time free reward unless a trusted external verifier is added.
	return true
end

local function hasClaimed(player: Player): (boolean?, string?)
	local success, result = pcall(function()
		return likeRewardStore:GetAsync(getKey(player))
	end)
	if not success then
		return nil, "DATASTORE_READ_FAILED"
	end
	return recordIsClaimed(result), nil
end

local function resetClaim(player: Player): (boolean, string?)
	local success, resetError = pcall(function()
		likeRewardStore:RemoveAsync(getKey(player))
	end)
	if not success then
		warn(`[LikeReward] Failed to reset reward for {player.Name}: {tostring(resetError)}`)
		return false, "DATASTORE_WRITE_FAILED"
	end

	claimLocks[player.UserId] = nil
	resetRemote:FireClient(player)
	return true, nil
end

local function beginClaim(player: Player): (string?, string?)
	local grantId = HttpService:GenerateGUID(false)
	local now = os.time()
	local alreadyClaimed = false
	local pending = false
	local reserved = false

	local success, updateError = pcall(function()
		likeRewardStore:UpdateAsync(getKey(player), function(current)
			if recordIsClaimed(current) then
				alreadyClaimed = true
				return current
			end
			if type(current) == "table" then
				local record = current :: ClaimRecord
				if record.Status == "Pending" and record.GrantId == grantId then
					reserved = true
					return current
				elseif recordIsPending(current, now) then
					pending = true
					return current
				end
			end

			reserved = true
			return {
				Status = "Pending",
				PendingAt = now,
				GrantId = grantId,
			}
		end)
	end)

	if not success then
		warn(`[LikeReward] Failed to reserve reward for {player.Name}: {tostring(updateError)}`)
		return nil, "DATASTORE_WRITE_FAILED"
	end
	if alreadyClaimed then
		return nil, "ALREADY_CLAIMED"
	end
	if pending then
		return nil, "CLAIM_PENDING"
	end
	if not reserved then
		return nil, "CLAIM_NOT_RESERVED"
	end
	return grantId, nil
end

local function finishClaim(player: Player, grantId: string): (boolean, string?)
	local now = os.time()
	local completed = false
	local updateError: any = nil

	for attempt = 1, 3 do
		local success, err = pcall(function()
			likeRewardStore:UpdateAsync(getKey(player), function(current)
				if recordIsClaimed(current) then
					completed = true
					return current
				end
				if type(current) == "table" then
					local record = current :: ClaimRecord
					if record.Status == "Pending" and record.GrantId == grantId then
						completed = true
						return {
							Status = "Claimed",
							Claimed = true,
							ClaimedAt = now,
						}
					end
				end
				return current
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
		warn(`[LikeReward] Failed to finish reward for {player.Name}: {tostring(updateError)}`)
		return false, "DATASTORE_WRITE_FAILED"
	end
	return completed, if completed then nil else "CLAIM_RESERVATION_LOST"
end

local function clearPending(player: Player, grantId: string)
	local success, updateError = pcall(function()
		likeRewardStore:UpdateAsync(getKey(player), function(current)
			if type(current) ~= "table" then
				return current
			end
			local record = current :: ClaimRecord
			if record.Status == "Pending" and record.GrantId == grantId then
				return {
					Status = "Open",
					ClearedAt = os.time(),
				}
			end
			return current
		end)
	end)
	if not success then
		warn(`[LikeReward] Failed to clear pending reward for {player.Name}: {tostring(updateError)}`)
	end
end

local function messageForReason(reason: string?): string
	if reason == "ALREADY_CLAIMED" then
		return "Вы уже получили эту награду!"
	elseif reason == "CLAIM_PENDING" then
		return "Награда уже обрабатывается. Подождите пару секунд."
	elseif reason == "PROFILE_NOT_LOADED" then
		return "Профиль валюты еще загружается. Попробуйте позже."
	elseif reason == "NOT_LIKED" then
		return "Вы еще не поставили лайк игре!"
	elseif reason == "DATASTORE_READ_FAILED" or reason == "DATASTORE_WRITE_FAILED" then
		return "Ошибка сохранения награды. Попробуйте позже."
	elseif reason == "CLAIM_RESERVATION_LOST" then
		return "Награда не была подтверждена. Попробуйте позже."
	end
	return "Не удалось выдать награду. Попробуйте позже."
end

remoteFunction.OnServerInvoke = function(player: Player, action: string)
	if action == "Check" then
		local claimed, reason = hasClaimed(player)
		if claimed == nil then
			return false, messageForReason(reason)
		end
		return claimed
	end

	if action ~= "Claim" then
		return false, "Неизвестное действие"
	end

	if claimLocks[player.UserId] then
		return false, messageForReason("CLAIM_PENDING")
	end
	claimLocks[player.UserId] = true

	local success, result, message = xpcall(function()
		local claimed, checkReason = hasClaimed(player)
		if claimed == nil then
			return false, messageForReason(checkReason)
		end
		if claimed then
			return false, messageForReason("ALREADY_CLAIMED")
		end
		if not checkIfPlayerLiked(player) then
			return false, messageForReason("NOT_LIKED")
		end
		if not (CurrencyService.IsLoaded(player) or CurrencyService.AwaitLoaded(player, 5)) then
			return false, messageForReason("PROFILE_NOT_LOADED")
		end

		local grantId, reserveReason = beginClaim(player)
		if not grantId then
			return false, messageForReason(reserveReason)
		end

		local added, _, addReason = CurrencyService.AddCurrency(player, REWARD_AMOUNT, "LikeReward")
		if not added then
			clearPending(player, grantId)
			warn(`[LikeReward] Could not grant {REWARD_AMOUNT} Coins to {player.Name}: {tostring(addReason)}`)
			return false, messageForReason("PROFILE_NOT_LOADED")
		end

		local finished, finishReason = finishClaim(player, grantId)
		if not finished then
			return false, messageForReason(finishReason)
		end
		return true, `Награда в {REWARD_AMOUNT} монет успешно начислена!`
	end, debug.traceback)

	claimLocks[player.UserId] = nil
	if not success then
		warn("[LikeReward] Claim failed:\n" .. tostring(result))
		return false, messageForReason(nil)
	end
	return result, message
end

adminResetBindable.OnInvoke = function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "INVALID_PLAYER"
	end
	return resetClaim(player)
end

print("[LikeRewardService] Started successfully.")
