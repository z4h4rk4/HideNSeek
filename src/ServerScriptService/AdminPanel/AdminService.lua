--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent:WaitForChild("AdminConfig"))
local Validation = require(script.Parent:WaitForChild("AdminValidationCore"))
local CurrencyService = require(
	script.Parent.Parent:WaitForChild("Currency"):WaitForChild("CurrencyService")
)
local RoundControl = require(script.Parent.Parent:WaitForChild("Round"):WaitForChild("RoundControl"))

local AdminService = {}

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

type Schema = {
	Keys: {[string]: boolean},
	NeedsTarget: boolean,
	Mutation: boolean,
}

local ACTION_SCHEMAS: {[string]: Schema} = table.freeze({
	GetSnapshot = { Keys = TARGET_KEYS, NeedsTarget = true, Mutation = false },
	AddCoins = { Keys = AMOUNT_KEYS, NeedsTarget = true, Mutation = true },
	RemoveCoins = { Keys = AMOUNT_KEYS, NeedsTarget = true, Mutation = true },
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
	}
end

local function buildSnapshot(target: Player): {[string]: any}
	local character = target.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local currency = CurrencyService.GetCurrency(target)
	local searchCaged = target:GetAttribute("SearchCaged") == true
		or (character ~= nil and character:GetAttribute("SearchCaged") == true)
	local cagedUntil = target:GetAttribute("SearchCagedUntil")
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
		SearchCaged = searchCaged,
		CagedRemaining = if searchCaged and type(cagedUntil) == "number"
			then math.max(0, math.ceil(cagedUntil - Workspace:GetServerTimeNow()))
			else 0,
		Round = roundSnapshot(),
	}
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
	return response(true, nil, message, buildSnapshot(admin), data)
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
			buildSnapshot(targetPlayer),
			nil
		)
	end

	if action == "SaveProfile" then
		local targetPlayer = target :: Player
		local saved, saveError = CurrencyService.SaveNow(targetPlayer)
		if not saved then
			return failure(saveError, "The profile could not be saved.")
		end
		audit(admin, action, targetPlayer, "saved=true")
		return response(true, nil, "Profile saved successfully.", buildSnapshot(targetPlayer), nil)
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
		return response(true, nil, message, buildSnapshot(targetPlayer), data)
	end

	if action == "RespawnPlayer" then
		local targetPlayer = target :: Player
		targetPlayer:LoadCharacter()
		audit(admin, action, targetPlayer, "requested=true")
		return response(true, nil, "Player respawned.", buildSnapshot(targetPlayer), nil)
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
		return response(true, nil, "Player healed.", buildSnapshot(targetPlayer), nil)
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
		return response(true, nil, message, buildSnapshot(targetPlayer), data)
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

	if action == "FillNpcSlots" or action == "ClearNpcs" then
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
