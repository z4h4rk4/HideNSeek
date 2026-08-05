--!strict

local Config = require(script.Parent:WaitForChild("SeekerSearchConfig"))

local SeekerSearchGeometry = {}

function SeekerSearchGeometry.GetForwardRayCount(): number
	return math.clamp(
		math.round(Config.VISUAL_RAY_COUNT * Config.FORWARD_RAY_FRACTION),
		1,
		Config.VISUAL_RAY_COUNT
	)
end

function SeekerSearchGeometry.GetRadius(forward: Vector3, direction: Vector3): number
	local flatDirection = Vector2.new(direction.X, direction.Z)
	if flatDirection.Magnitude <= 0.001 then
		return Config.SEARCH_RADIUS
	end

	local flatForward = Vector2.new(forward.X, forward.Z)
	if flatForward.Magnitude <= 0.001 then
		flatForward = Vector2.new(0, -1)
	end

	local forwardFraction = SeekerSearchGeometry.GetForwardRayCount() / Config.VISUAL_RAY_COUNT
	local halfAngle = math.pi * forwardFraction
	local edgeDot = math.cos(halfAngle)
	local facingDot = math.clamp(flatForward.Unit:Dot(flatDirection.Unit), -1, 1)
	return if facingDot >= edgeDot
		then Config.SEARCH_RADIUS + Config.FORWARD_RADIUS_BONUS
		else Config.SEARCH_RADIUS
end

return table.freeze(SeekerSearchGeometry)
