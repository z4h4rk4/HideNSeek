--!strict

local allowedUserIds: {[number]: boolean} = {
	[10244668710] = true,
}

local actionCooldownSeconds: {[string]: number} = {
	AddCoins = 1,
	RemoveCoins = 1,
	ResetWeaponPurchases = 2,
	ResetLikeReward = 2,
	SetCooldownPassTestState = 0.75,
	SaveProfile = 3,
	RespawnPlayer = 1,
	HealPlayer = 0.5,
	NormalizeMovement = 0.5,
	SetRole = 0.5,
	StartRoundNow = 0.5,
	EndRound = 0.5,
	RestartRound = 0.5,
	SetRemainingTime = 0.5,
	ClearNpcs = 0.5,
	FillNpcSlots = 0.5,
	SpawnNpc = 0.35,
	RemoveNpcs = 0.5,
	SetNpcPopulation = 0.75,
	ClearNpcPopulationOverride = 0.75,
	SetNpcAIEnabled = 0.5,
}

local actionResourceKeys: {[string]: string} = {
	StartRoundNow = "RoundState",
	EndRound = "RoundState",
	RestartRound = "RoundState",
	SetRemainingTime = "RoundState",
	ClearNpcs = "NpcPopulation",
	FillNpcSlots = "NpcPopulation",
	SpawnNpc = "NpcPopulation",
	RemoveNpcs = "NpcPopulation",
	SetNpcPopulation = "NpcPopulation",
	ClearNpcPopulationOverride = "NpcPopulation",
	SetNpcAIEnabled = "NpcPopulation",
}

local resourceCooldownSeconds: {[string]: number} = {
	RoundState = 0.35,
	NpcPopulation = 0.5,
}

return table.freeze({
	AllowedUserIds = table.freeze(allowedUserIds),

	GuiName = "FounderAdminPanel",
	RemoteName = "AdminRequest",
	ClientTemplateName = "AdminPanelClient",

	RequestCooldownSeconds = 0.25,
	ActionCooldownSeconds = table.freeze(actionCooldownSeconds),
	ActionResourceKeys = table.freeze(actionResourceKeys),
	ResourceCooldownSeconds = table.freeze(resourceCooldownSeconds),
	ResponseCacheSize = 24,
	MaxResponseNodes = 256,
	MinRequestIdLength = 8,
	MaxRequestIdLength = 64,
	MaxRequestSequence = 9_007_199_254_740_991,
	MaxTargetUserId = 9_007_199_254_740_991,
	MaxCoinAdjustment = 1_000_000_000_000,
	MinRoundTimeSeconds = 1,
	MaxRoundTimeSeconds = 600,
	MaxNpcPopulation = 6,
})
