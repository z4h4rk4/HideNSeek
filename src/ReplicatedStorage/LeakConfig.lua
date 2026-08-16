--!strict

local LeakConfig = {
	TRAIL_DURATION_SECONDS = 7,
	SERVER_SAMPLE_INTERVAL_SECONDS = 0.1,
	CLIENT_CHECK_INTERVAL_SECONDS = 0.05,
	MIN_MOVE_SPEED = 4,
	STEP_DISTANCE = 2.2,
	RAY_EXTRA_DISTANCE = 4,
	ON_LEAK_SPEED_MULTIPLIER = 0.3,
	AFTER_EXIT_SPEED_MULTIPLIER = 0.45,
	SLOW_MULTIPLIER_ATTRIBUTE = "LeakSpeedMultiplier",
}

function LeakConfig.GetRecoveryAlpha(remainingWetSeconds: number): number
	local linearAlpha = 1 - math.clamp(
		remainingWetSeconds / LeakConfig.TRAIL_DURATION_SECONDS,
		0,
		1
	)
	return linearAlpha * linearAlpha * (3 - 2 * linearAlpha)
end

return table.freeze(LeakConfig)
