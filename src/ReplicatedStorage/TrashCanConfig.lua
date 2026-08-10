--!strict

return table.freeze({
	-- Tool contents
	WEAPON_MODEL_NAME = "TrashCan",
	ATTACK_ANIMATION_NAME = "AllahBabah",
	EFFECT_OBJECT_NAME = "Effect",

	-- Damage sector
	RANGE_STUDS = 12,
	ANGLE_DEGREES = 90,
	MAX_VERTICAL_DIFFERENCE = 7,

	-- Complete knockdown
	KNOCKDOWN_DURATION_SECONDS = 3,
	KNOCKBACK_SPEED = 18,
	KNOCKBACK_UPWARD_SPEED = 6,
	KNOCKBACK_TIP_SPEED = 5,

	-- Flying effect
	EFFECT_TRAVEL_SECONDS = 0.45,
	EFFECT_START_FORWARD_OFFSET_STUDS = 0.5,
	EFFECT_START_HEIGHT_OFFSET_STUDS = 0.5,
	EFFECT_CLEANUP_PADDING_SECONDS = 0.1,

	-- Safety fallback in case Roblox never reports that the animation ended
	ACTION_LOCK_TIMEOUT_SECONDS = 10,
})
