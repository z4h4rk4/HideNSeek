--!strict

local IceConfig = {
	ICE_NAME = "ice",
	ICE_ATTRIBUTE = "IsIce",
	ROLE_ATTRIBUTE = "RoundRole",
	ROLE_SEEKER = "Seeker",
	ON_ICE_ATTRIBUTE = "IsSlidingOnIce",

	RAY_EXTRA_DISTANCE = 2,
	MOVE_DIRECTION_THRESHOLD = 0.05,
	MIN_SLIDE_SPEED = 0.15,
	STEERING_ACCELERATION = 8,
	COAST_DECELERATION = 1.35,
	MAX_SPEED_MULTIPLIER = 1.25,
}

function IceConfig.IsIcePart(part: BasePart): boolean
	local current: Instance? = part
	while current and current ~= workspace do
		if string.lower(current.Name) == IceConfig.ICE_NAME
			or current:GetAttribute(IceConfig.ICE_ATTRIBUTE) == true then
			return true
		end
		current = current.Parent
	end
	return false
end

function IceConfig.MoveToward(
	current: Vector3,
	target: Vector3,
	maxDelta: number
): Vector3
	local difference = target - current
	local distance = difference.Magnitude
	if distance <= maxDelta or distance <= 0.0001 then
		return target
	end
	return current + difference / distance * maxDelta
end

function IceConfig.ClampHorizontalVelocity(velocity: Vector3, walkSpeed: number): Vector3
	local maximumSpeed = math.max(1, walkSpeed) * IceConfig.MAX_SPEED_MULTIPLIER
	if velocity.Magnitude <= maximumSpeed then
		return velocity
	end
	return velocity.Unit * maximumSpeed
end

return table.freeze(IceConfig)
