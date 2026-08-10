--!strict

local BAT_MODEL_NAME = "BatModel"
local CageConfig = require(script.Parent:WaitForChild("CageConfig"))
local TrashCanConfig = require(script.Parent:WaitForChild("TrashCanConfig"))

return table.freeze({
	BAT_MODEL_NAME = BAT_MODEL_NAME,
	WEAPON_MODEL_NAMES = table.freeze({
		BAT_MODEL_NAME,
		CageConfig.WEAPON_MODEL_NAME,
		TrashCanConfig.WEAPON_MODEL_NAME,
	}),
	ATTACK_ANIMATION_NAME = "batattack",
	REMOTE_EVENT_NAME = "BatAttackRequest",
	KNOCKDOWN_ATTRIBUTE = "BatKnockedDown",

	ATTACK_COOLDOWN_SECONDS = 0.8,
	HIT_DELAY_SECONDS = 0.05,
	HIT_WINDOW_DURATION_SECONDS = 0.7,
	HANDLE_CONTACT_PADDING = 0.15,
	MIN_TARGET_FORWARD_DOT = 0,
	KNOCKDOWN_DURATION_SECONDS = 1.7,
	KNOCKBACK_SPEED = 18,
	KNOCKBACK_UPWARD_SPEED = 6,
	KNOCKBACK_TIP_SPEED = 3,
})
