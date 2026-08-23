--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent:WaitForChild("AdminConfig"))
local Validation = require(script.Parent:WaitForChild("AdminValidationCore"))
local CurrencyService = require(
	script.Parent.Parent:WaitForChild("Currency"):WaitForChild("CurrencyService")
)
local CooldownPassService = require(
	script.Parent.Parent:WaitForChild("WeaponShop"):WaitForChild("CooldownPassService")
)
local roundModules = script.Parent.Parent:WaitForChild("Round")
local RoundConfig = require(roundModules:WaitForChild("RoundConfig"))
local RoundControl = require(roundModules:WaitForChild("RoundControl"))

-- AdminConfig is an independent safety ceiling. The gameplay cap may be made
-- smaller without accidentally letting the panel exceed it.
local MAX_NPC_POPULATION = math.min(
	Config.MaxNpcPopulation,
	RoundConfig.NPC.MAX_ACTIVE_NPCS
)

local AdminService = {}

local LIKE_REWARD_ADMIN_RESET_BINDABLE_NAME = "LikeRewardAdminReset"

local TARGET_KEYS = table.freeze({
	Action = true,
	RequestId = true,
	Sequence = true,
	TargetUserId = true,
})
local AMOUNT_KEYS = table.freeze({
	Action = true,
	RequestId = true,
	Sequence = true,
	TargetUserId = true,
	Amount = true,
})
local ROLE_KEYS = table.freeze({
	Action = true,
	RequestId = true,
	Sequence = true,
	TargetUserId = true,
	Role = true,
})
local COOLDOWN_PASS_TEST_KEYS = table.freeze({
	Action = true,
	RequestId = true,
	Sequence = true,
	TargetUserId = true,
	State = true,
})
local GLOBAL_KEYS = table.freeze({
	Action = true,
	RequestId = true,
	Sequence = true,
})
local SECONDS_KEYS = table.freeze({
	Action = true,
	RequestId = true,
	Sequence = true,
	Seconds = true,
})
local NPC_ROLE_KEYS = table.freeze({
	Action = true,
	RequestId = true,
	Sequence = true,
	Role = true,
})
local ENABLED_KEYS = table.freeze({
	Action = true,
	RequestId = true,
	Sequence = true,
	Enabled = true,
})
local NPC_POPULATION_KEYS = table.freeze({
	Action = true,
	RequestId = true,
	Sequence = true,
	HiderCount = true,
	SeekerCount = true,
})

type Schema = {
	Keys: {[string]: boolean},
	NeedsTarget: boolean,
	Mutation: boolean,
}

local ACTION_SCHEMAS: {[string]: Schema} = table.freeze({
	GetSnapshot = { Keys = TARGET_KEYS, NeedsTarget = true, Mutation = false },
	AddCoins = { Keys = AMOUNT_KEYS, NeedsTarget = true, Mutation = true },
	RemoveCoins = { Keys = AMOUNT_KEYS, NeedsTarget = true, Mutation = true },
	ResetWeaponPurchases = { Keys = TARGET_KEYS, NeedsTarget = true, Mutation = true },
	ResetLikeReward = { Keys = TARGET_KEYS, NeedsTarget = true, Mutation = true },
	SetCooldownPassTestState = {
		Keys = COOLDOWN_PASS_TEST_KEYS,
		NeedsTarget = true,
		Mutation = true,
	},
	SaveProfile = { Keys = TARGET_KEYS, NeedsTarget = true, Mutation = true },
	SetRole = { Keys = ROLE_KEYS, NeedsTarget = true, Mutation = true },
	RespawnPlayer = { Keys = TARGET_KEYS, NeedsTarget = true, Mutation = true },
	HealPlayer = { Keys = TARGET_KEYS, NeedsTarget = true, Mutation = true },
	NormalizeMovement = { Keys = TARGET_KEYS, NeedsTarget = true, Mutation = true },
	StartRoundNow = { Keys = GLOBAL_KEYS, NeedsTarget = false, Mutation = true },
	EndRound = { Keys = GLOBAL_KEYS, NeedsTarget = false, Mutation = true },
	RestartRound = { Keys = GLOBAL_KEYS, NeedsTarget = false, Mutation = true },
	SetRemainingTime = { Keys = SECONDS_KEYS, NeedsTarget = false, Mutation = true },
	FillNpcSlots = { Keys = GLOBAL_KEYS, NeedsTarget = false, Mutation = true },
	ClearNpcs = { Keys = GLOBAL_KEYS, NeedsTarget = false, Mutation = true },
	SpawnNpc = { Keys = NPC_ROLE_KEYS, NeedsTarget = false, Mutation = true },
	RemoveNpcs = { Keys = NPC_ROLE_KEYS, NeedsTarget = false, Mutation = true },
	SetNpcPopulation = { Keys = NPC_POPULATION_KEYS, NeedsTarget = false, Mutation = true },
	ClearNpcPopulationOverride = { Keys = GLOBAL_KEYS, NeedsTarget = false, Mutation = true },
	SetNpcAIEnabled = { Keys = ENABLED_KEYS, NeedsTarget = false, Mutation = true },
})

local ERROR_MESSAGES: {[string]: string} = table.freeze({
	BALANCE_LIMIT = "This would exceed the maximum Coins balance.",
	INSUFFICIENT_FUNDS = "The player does not have enough Coins.",
	INVALID_AMOUNT = "Enter a valid whole-number amount.",
	NOT_LOADED = "The player's currency profile is not loaded yet.",
	PROFILE_CLOSING = "The player's profile is closing.",
	SESSION_SUPERSEDED = "The player's profile is active on another server.",
})

local VALID_PLAYER_ROLES: {[string]: boolean} = table.freeze({
	Hider = true,
	Seeker = true,
	Spectator = true,
})
local VALID_NPC_ROLES: {[string]: boolean} = table.freeze({
	Hider = true,
	Seeker = true,
})
local VALID_COOLDOWN_PASS_TEST_STATES: {[string]: boolean} = table.freeze({
	Owned = true,
	Unowned = true,
	Roblox = true,
})

local function response(ok: boolean, reason: string?, message: string, snapshot: any?, data: any?)
	return {
		Ok = ok,
		Reason = reason,
		Message = message,
		Snapshot = snapshot,
		Data = data,
	}
end

local function failure(reason: any, fallback: string?)
	local normalized = tostring(reason or "UNKNOWN_ERROR")
	return response(
		false,
		normalized,
		ERROR_MESSAGES[normalized] or fallback or "The operation failed.",
		nil,
		nil
	)
end

local function findOnlinePlayer(userId: number): Player?
	for _, candidate in Players:GetPlayers() do
		if candidate.UserId == userId then
			return candidate
		end
	end
	return nil
end

local function countNpcs(): (number, number, number)
	local total = 0
	local hiders = 0
	local seekers = 0
	local folder = Workspace:FindFirstChild("RoundNPCs")
	if not folder then
		return total, hiders, seekers
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("ManagedRoundNPC") == true then
			total += 1
			local role = child:GetAttribute("RoundRole")
			if role == "Hider" then
				hiders += 1
			elseif role == "Seeker" then
				seekers += 1
			end
		end
	end
	return total, hiders, seekers
end

local function roundSnapshot(): {[string]: any}
	local roundState = ReplicatedStorage:FindFirstChild("RoundState")
	local phase = "Unavailable"
	local endsAt = 0
	local hiderCount = 0
	local caughtHiderCount = 0
	local seekerCount = 0
	local maxHiders = 0
	local maxSeekers = 0
	local npcAIEnabled = true
	local botSeekerMode = false
	local npcPopulationOverrideEnabled = false
	local npcTargetHiders = 0
	local npcTargetSeekers = 0
	local maxAdminNpcs = MAX_NPC_POPULATION
	local activeArena = "None"
	if roundState then
		phase = tostring(roundState:GetAttribute("Phase") or "Unavailable")
		endsAt = tonumber(roundState:GetAttribute("EndsAt")) or 0
		hiderCount = tonumber(roundState:GetAttribute("HiderCount")) or 0
		caughtHiderCount = tonumber(roundState:GetAttribute("CaughtHiderCount")) or 0
		seekerCount = tonumber(roundState:GetAttribute("SeekerCount")) or 0
		maxHiders = tonumber(roundState:GetAttribute("MaxHiders")) or 0
		maxSeekers = tonumber(roundState:GetAttribute("MaxSeekers")) or 0
		local activeArenaAttribute = roundState:GetAttribute("ActiveArena")
		if type(activeArenaAttribute) == "string" and activeArenaAttribute ~= "" then
			activeArena = activeArenaAttribute
		end
		local enabledAttribute = roundState:GetAttribute("NpcAIEnabled")
		if type(enabledAttribute) == "boolean" then
			npcAIEnabled = enabledAttribute
		end
		botSeekerMode = roundState:GetAttribute("BotSeekerMode") == true
		npcPopulationOverrideEnabled = roundState:GetAttribute("NpcPopulationOverrideEnabled") == true
		npcTargetHiders = tonumber(roundState:GetAttribute("NpcTargetHiders")) or 0
		npcTargetSeekers = tonumber(roundState:GetAttribute("NpcTargetSeekers")) or 0
		maxAdminNpcs = math.min(
			tonumber(roundState:GetAttribute("MaxAdminNpcs")) or maxAdminNpcs,
			MAX_NPC_POPULATION
		)
	end

	local stateOk, _, controlState = RoundControl.Execute("GetState", {})
	if stateOk and type(controlState) == "table" then
		if type(controlState.Phase) == "string" then
			phase = controlState.Phase
		end
		if type(controlState.EndsAt) == "number" then
			endsAt = controlState.EndsAt
		end
		if type(controlState.NpcAIEnabled) == "boolean" then
			npcAIEnabled = controlState.NpcAIEnabled
		end
		if type(controlState.BotSeekerMode) == "boolean" then
			botSeekerMode = controlState.BotSeekerMode
		end
		if type(controlState.NpcPopulationOverrideEnabled) == "boolean" then
			npcPopulationOverrideEnabled = controlState.NpcPopulationOverrideEnabled
		end
		if type(controlState.NpcTargetHiders) == "number" then
			npcTargetHiders = controlState.NpcTargetHiders
		end
		if type(controlState.NpcTargetSeekers) == "number" then
			npcTargetSeekers = controlState.NpcTargetSeekers
		end
		if type(controlState.MaxAdminNpcs) == "number" then
			maxAdminNpcs = math.min(controlState.MaxAdminNpcs, MAX_NPC_POPULATION)
		end
		if type(controlState.ActiveArena) == "string" and controlState.ActiveArena ~= "" then
			activeArena = controlState.ActiveArena
		end
	end

	local npcCount, hiderNpcs, seekerNpcs = countNpcs()
	return {
		Phase = phase,
		EndsAt = endsAt,
		RemainingTime = math.max(0, math.ceil(endsAt - Workspace:GetServerTimeNow())),
		ActiveArena = activeArena,
		HiderCount = hiderCount,
		CaughtHiderCount = caughtHiderCount,
		SeekerCount = seekerCount,
		MaxHiders = maxHiders,
		MaxSeekers = maxSeekers,
		NpcCount = npcCount,
		HiderNpcCount = hiderNpcs,
		SeekerNpcCount = seekerNpcs,
		NpcAIEnabled = npcAIEnabled,
		BotSeekerMode = botSeekerMode,
		NpcPopulationOverrideEnabled = npcPopulationOverrideEnabled,
		NpcTargetHiders = npcTargetHiders,
		NpcTargetSeekers = npcTargetSeekers,
		MaxAdminNpcs = maxAdminNpcs,
	}
end

local function buildSnapshot(target: Player): {[string]: any}
	local character = target.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local currency = CurrencyService.GetCurrency(target)
	return {
		TargetUserId = target.UserId,
		TargetName = target.Name,
		DisplayName = target.DisplayName,
		CurrencyLoaded = CurrencyService.IsLoaded(target),
		Coins = currency,
		Role = tostring(target:GetAttribute("RoundRole") or "Spectator"),
		Team = if target.Team then target.Team.Name else "None",
		CharacterAlive = humanoid ~= nil and humanoid.Health > 0,
		Health = if humanoid then humanoid.Health else 0,
		MaxHealth = if humanoid then humanoid.MaxHealth else 0,
		WalkSpeed = if humanoid then humanoid.WalkSpeed else 0,
		CharacterScale = if character then character:GetScale() else 0,
		CooldownPass = CooldownPassService.GetState(target),
		Round = roundSnapshot(),
	}
end

local function safeBuildSnapshot(target: Player): {[string]: any}?
	local succeeded, snapshotOrError = pcall(buildSnapshot, target)
	if succeeded and type(snapshotOrError) == "table" then
		return snapshotOrError
	end
	warn(("[AdminPanel] Snapshot failed for %s (%d): %s"):format(
		target.Name,
		target.UserId,
		tostring(snapshotOrError)
	))
	return nil
end

local function audit(admin: Player, action: string, target: Player?, details: string)
	local targetText = if target
		then ("%s(%d)"):format(target.Name, target.UserId)
		else "server"
	print(("[AdminAudit] job=%s admin=%s(%d) action=%s target=%s %s"):format(
		game.JobId,
		admin.Name,
		admin.UserId,
		action,
		targetText,
		details
	))
end

local function executeRoundAction(
	admin: Player,
	action: string,
	arguments: {[string]: any},
	details: string
)
	local ok, message, data = RoundControl.Execute(action, arguments)
	if not ok then
		return failure("ROUND_CONTROL_FAILED", message)
	end
	audit(admin, action, nil, details)
	local responseData: {[string]: any} = {}
	if type(data) == "table" then
		for key, value in data do
			if type(key) == "string" then
				responseData[key] = value
			end
		end
	end
	local snapshotSucceeded, currentRoundOrError = pcall(roundSnapshot)
	if snapshotSucceeded and type(currentRoundOrError) == "table" then
		responseData.Round = currentRoundOrError
	else
		warn(("[AdminPanel] Post-action round snapshot failed: %s"):format(
			tostring(currentRoundOrError)
		))
	end
	return response(true, nil, message, nil, responseData)
end

local function resetLikeReward(target: Player): (boolean, string?)
	local bindable = ServerScriptService:WaitForChild(
		LIKE_REWARD_ADMIN_RESET_BINDABLE_NAME,
		5
	)
	if not bindable or not bindable:IsA("BindableFunction") then
		return false, "LIKE_REWARD_SERVICE_UNAVAILABLE"
	end

	local invoked, ok, reason = pcall(function()
		return (bindable :: BindableFunction):Invoke(target)
	end)
	if not invoked then
		warn(("[AdminPanel] Like reward reset failed for %s (%d): %s"):format(
			target.Name,
			target.UserId,
			tostring(ok)
		))
		return false, "LIKE_REWARD_RESET_FAILED"
	end
	return ok == true, if ok == true then nil else tostring(reason or "LIKE_REWARD_RESET_FAILED")
end

function AdminService.IsAuthorized(player: Player): boolean
	return Validation.IsAuthorizedUserId(player.UserId, Config.AllowedUserIds)
end

function AdminService.HandleRequest(admin: Player, payload: any)
	if not AdminService.IsAuthorized(admin) then
		return failure("UNAUTHORIZED", "Access denied.")
	end
	if type(payload) ~= "table" or type(payload.Action) ~= "string" then
		return failure("INVALID_REQUEST", "Invalid request.")
	end

	local action = payload.Action
	local schema = ACTION_SCHEMAS[action]
	if not schema then
		return failure("INVALID_ACTION", "Unknown admin action.")
	end
	if not Validation.HasOnlyKeys(payload, schema.Keys) then
		return failure("INVALID_PAYLOAD", "The request contains unexpected fields.")
	end

	local target: Player? = nil
	if schema.NeedsTarget then
		local targetUserId = Validation.ParseIntegerInRange(
			payload.TargetUserId,
			1,
			Config.MaxTargetUserId
		)
		if not targetUserId then
			return failure("INVALID_USER_ID", "Enter a valid UserId.")
		end
		target = findOnlinePlayer(targetUserId)
		if not target then
			return failure("TARGET_NOT_IN_SERVER", "The target player must be on this server.")
		end
	end

	if action == "GetSnapshot" then
		return response(true, nil, "Snapshot refreshed.", buildSnapshot(target :: Player), nil)
	end

	if action == "AddCoins" or action == "RemoveCoins" then
		local targetPlayer = target :: Player
		local amount = Validation.ParseIntegerInRange(payload.Amount, 1, Config.MaxCoinAdjustment)
		if not amount then
			return failure(
				"INVALID_AMOUNT",
				("Enter a whole number from 1 to %d."):format(Config.MaxCoinAdjustment)
			)
		end
		local before = CurrencyService.GetCurrency(targetPlayer)
		local changed, balance, currencyError
		if action == "AddCoins" then
			changed, balance, currencyError = CurrencyService.AddCurrency(
				targetPlayer,
				amount,
				"FounderAdmin:AddCoins"
			)
		else
			changed, balance, currencyError = CurrencyService.SpendCurrency(
				targetPlayer,
				amount,
				"FounderAdmin:RemoveCoins"
			)
		end
		if not changed then
			return failure(currencyError)
		end
		audit(admin, action, targetPlayer, ("coins=%s->%s amount=%d"):format(
			tostring(before),
			tostring(balance),
			amount
		))
		return response(
			true,
			nil,
			if action == "AddCoins"
				then ("Added %d Coins."):format(amount)
				else ("Removed %d Coins."):format(amount),
			safeBuildSnapshot(targetPlayer),
			nil
		)
	end

	if action == "ResetWeaponPurchases" then
		local targetPlayer = target :: Player
		local reset, removedCount, resetError = CurrencyService.ResetOwnedWeapons(
			targetPlayer,
			"FounderAdmin:ResetWeaponPurchases"
		)
		if not reset then
			return failure(resetError, "Weapon purchases could not be reset.")
		end
		local saved, saveError = CurrencyService.SaveNow(targetPlayer)
		audit(
			admin,
			action,
			targetPlayer,
			("removed=%d saved=%s saveReason=%s"):format(
				removedCount,
				tostring(saved),
				tostring(saveError)
			)
		)
		local message = if saved
			then ("Reset %d purchased weapon(s). Fists remain available."):format(removedCount)
			else ("Reset %d purchased weapon(s); automatic save is still queued."):format(removedCount)
		return response(true, nil, message, safeBuildSnapshot(targetPlayer), {
			RemovedWeaponCount = removedCount,
			SavedImmediately = saved,
		})
	end

	if action == "ResetLikeReward" then
		local targetPlayer = target :: Player
		local reset, resetError = resetLikeReward(targetPlayer)
		if not reset then
			return failure(resetError, "Free prize claim state could not be reset.")
		end
		audit(admin, action, targetPlayer, "reset=true")
		return response(
			true,
			nil,
			"Free prize UI reset. The player can claim it again.",
			safeBuildSnapshot(targetPlayer),
			nil
		)
	end

	if action == "SetCooldownPassTestState" then
		local targetPlayer = target :: Player
		if targetPlayer ~= admin then
			return failure(
				"PASS_TEST_SELF_ONLY",
				"Cooldown pass simulation is restricted to your own admin account."
			)
		end
		local state = payload.State
		if type(state) ~= "string" or not VALID_COOLDOWN_PASS_TEST_STATES[state] then
			return failure(
				"INVALID_PASS_TEST_STATE",
				"Pass test state must be Owned, Unowned, or Roblox."
			)
		end

		local override = if state == "Roblox" then nil else state == "Owned"
		local changed, stateOrReason = CooldownPassService.SetTestOverride(
			targetPlayer,
			override
		)
		if not changed then
			return failure(stateOrReason, "The cooldown pass test state could not be changed.")
		end
		audit(admin, action, targetPlayer, ("state=%s"):format(state))

		local message
		if state == "Owned" then
			message = "Cooldown pass simulated as owned for this server."
		elseif state == "Unowned" then
			message = "Cooldown pass simulated as not owned for this server."
		elseif stateOrReason.RealOwnershipReady then
			message = "Restored verified Roblox cooldown pass ownership."
		else
			message = "Restored Roblox ownership mode; verification is still pending."
		end
		return response(true, nil, message, safeBuildSnapshot(targetPlayer), {
			CooldownPass = stateOrReason,
		})
	end

	if action == "SaveProfile" then
		local targetPlayer = target :: Player
		local saved, saveError = CurrencyService.SaveNow(targetPlayer)
		if not saved then
			return failure(saveError, "The profile could not be saved.")
		end
		audit(admin, action, targetPlayer, "saved=true")
		return response(true, nil, "Profile saved successfully.", safeBuildSnapshot(targetPlayer), nil)
	end

	if action == "SetRole" then
		local targetPlayer = target :: Player
		local role = payload.Role
		if type(role) ~= "string" or not VALID_PLAYER_ROLES[role] then
			return failure("INVALID_ROLE", "Role must be Hider, Seeker, or Spectator.")
		end
		local before = tostring(targetPlayer:GetAttribute("RoundRole") or "Spectator")
		local ok, message, data = RoundControl.Execute("SetRole", {
			Target = targetPlayer,
			Role = role,
		})
		if not ok then
			return failure("ROUND_CONTROL_FAILED", message)
		end
		audit(admin, action, targetPlayer, ("role=%s->%s"):format(before, role))
		return response(true, nil, message, safeBuildSnapshot(targetPlayer), data)
	end

	if action == "RespawnPlayer" then
		local targetPlayer = target :: Player
		targetPlayer:LoadCharacter()
		audit(admin, action, targetPlayer, "requested=true")
		return response(true, nil, "Player respawned.", safeBuildSnapshot(targetPlayer), nil)
	end

	if action == "HealPlayer" then
		local targetPlayer = target :: Player
		local character = targetPlayer.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if not humanoid or humanoid.Health <= 0 then
			return failure("CHARACTER_NOT_ALIVE", "The target has no living character.")
		end
		local before = humanoid.Health
		humanoid.Health = humanoid.MaxHealth
		audit(admin, action, targetPlayer, ("health=%.2f->%.2f"):format(before, humanoid.Health))
		return response(true, nil, "Player healed.", safeBuildSnapshot(targetPlayer), nil)
	end

	if action == "NormalizeMovement" then
		local targetPlayer = target :: Player
		local ok, message, data = RoundControl.Execute("NormalizeMovement", {
			Target = targetPlayer,
		})
		if not ok then
			return failure("ROUND_CONTROL_FAILED", message)
		end
		audit(admin, action, targetPlayer, "normalized=true")
		return response(true, nil, message, safeBuildSnapshot(targetPlayer), data)
	end

	if action == "StartRoundNow" or action == "EndRound" or action == "RestartRound" then
		return executeRoundAction(admin, action, {}, "requested=true")
	end

	if action == "SetRemainingTime" then
		local seconds = Validation.ParseIntegerInRange(
			payload.Seconds,
			Config.MinRoundTimeSeconds,
			Config.MaxRoundTimeSeconds
		)
		if not seconds then
			return failure(
				"INVALID_TIME",
				("Enter a whole number from %d to %d seconds."):format(
					Config.MinRoundTimeSeconds,
					Config.MaxRoundTimeSeconds
				)
			)
		end
		return executeRoundAction(
			admin,
			action,
			{ Seconds = seconds },
			("seconds=%d"):format(seconds)
		)
	end

	if action == "SetNpcPopulation" then
		local hiderCount = Validation.ParseIntegerInRange(
			payload.HiderCount,
			0,
			MAX_NPC_POPULATION
		)
		local seekerCount = Validation.ParseIntegerInRange(
			payload.SeekerCount,
			0,
			MAX_NPC_POPULATION
		)
		if not hiderCount or not seekerCount or hiderCount + seekerCount > MAX_NPC_POPULATION then
			return failure(
				"INVALID_NPC_POPULATION",
				("Use whole NPC counts from 0 to %d; their sum cannot exceed %d."):format(
					MAX_NPC_POPULATION,
					MAX_NPC_POPULATION
				)
			)
		end
		return executeRoundAction(
			admin,
			action,
			{
				HiderCount = hiderCount,
				SeekerCount = seekerCount,
			},
			("hiders=%d seekers=%d"):format(hiderCount, seekerCount)
		)
	end

	if action == "FillNpcSlots"
		or action == "ClearNpcs"
		or action == "ClearNpcPopulationOverride" then
		return executeRoundAction(admin, action, {}, "requested=true")
	end

	if action == "SpawnNpc" or action == "RemoveNpcs" then
		local role = payload.Role
		if type(role) ~= "string" or not VALID_NPC_ROLES[role] then
			return failure("INVALID_ROLE", "NPC role must be Hider or Seeker.")
		end
		return executeRoundAction(
			admin,
			action,
			{ Role = role },
			("role=%s"):format(role)
		)
	end

	if action == "SetNpcAIEnabled" then
		if type(payload.Enabled) ~= "boolean" then
			return failure("INVALID_ENABLED", "Enabled must be a boolean.")
		end
		return executeRoundAction(
			admin,
			action,
			{ Enabled = payload.Enabled },
			("enabled=%s"):format(tostring(payload.Enabled))
		)
	end

	return failure("INVALID_ACTION", "Unknown admin action.")
end

return table.freeze(AdminService)
