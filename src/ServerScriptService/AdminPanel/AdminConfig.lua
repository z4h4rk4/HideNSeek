--!strict

local allowedUserIds: {[number]: boolean} = {
	[10244668710] = true,
}

local actionCooldownSeconds: {[string]: number} = {
	SaveProfile = 3,
	RespawnPlayer = 1,
	StartRoundNow = 0.5,
	EndRound = 0.5,
	RestartRound = 0.5,
	ClearNpcs = 0.5,
	FillNpcSlots = 0.5,
}

return table.freeze({
	AllowedUserIds = table.freeze(allowedUserIds),

	GuiName = "FounderAdminPanel",
	RemoteName = "AdminRequest",
	ClientTemplateName = "AdminPanelClient",

	RequestCooldownSeconds = 0.25,
	ActionCooldownSeconds = table.freeze(actionCooldownSeconds),
	ResponseCacheSize = 24,
	MinRequestIdLength = 8,
	MaxRequestIdLength = 64,
	MaxRequestSequence = 9_007_199_254_740_991,
	MaxTargetUserId = 9_007_199_254_740_991,
	MaxCoinAdjustment = 1_000_000_000_000,
	MinRoundTimeSeconds = 1,
	MaxRoundTimeSeconds = 600,
})
