--!strict

local MovementAnimationConfig = {
	MOVING_SPEED_THRESHOLD = 0.5,
	MIN_PLAYBACK_SPEED = 0.65,
	MAX_PLAYBACK_SPEED = 1.35,
}

function MovementAnimationConfig.GetPlaybackSpeed(actualSpeed: number, walkSpeed: number): number
	return math.clamp(
		actualSpeed / math.max(walkSpeed, 1),
		MovementAnimationConfig.MIN_PLAYBACK_SPEED,
		MovementAnimationConfig.MAX_PLAYBACK_SPEED
	)
end

return table.freeze(MovementAnimationConfig)
