--!strict

local Workspace = game:GetService("Workspace")

local HiderConfig = require(script.Parent:WaitForChild("HiderConfig"))

local DOOR_COLLISION_GROUP = "Doors"
local NPC_COLLISION_GROUP = "RoundNPCs"

local NpcDoorInteraction = {}

local function horizontalUnit(vector: Vector3): Vector3?
	local horizontal = Vector3.new(vector.X, 0, vector.Z)
	return if horizontal.Magnitude > 0.001 then horizontal.Unit else nil
end

local function closestPointInBounds(part: BasePart, worldPosition: Vector3): Vector3
	local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
	local halfSize = part.Size * 0.5
	local clamped = Vector3.new(
		math.clamp(localPosition.X, -halfSize.X, halfSize.X),
		math.clamp(localPosition.Y, -halfSize.Y, halfSize.Y),
		math.clamp(localPosition.Z, -halfSize.Z, halfSize.Z)
	)
	return part.CFrame:PointToWorldSpace(clamped)
end

function NpcDoorInteraction.TryPush(
	npc: Model,
	rootPart: BasePart,
	moveDirection: Vector3
): BasePart?
	local direction = horizontalUnit(moveDirection)
	if not direction then
		return nil
	end

	local parameters = OverlapParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { npc }
	parameters.CollisionGroup = NPC_COLLISION_GROUP
	parameters.MaxParts = HiderConfig.DOOR_PROBE_MAX_PARTS

	local probeCenter = rootPart.Position + direction * HiderConfig.DOOR_PROBE_FORWARD_OFFSET
	local nearbyParts = Workspace:GetPartBoundsInRadius(
		probeCenter,
		HiderConfig.DOOR_PROBE_RADIUS,
		parameters
	)

	local selectedPart: BasePart? = nil
	local selectedAssembly: BasePart? = nil
	local selectedPoint = Vector3.zero
	local selectedDistance = math.huge
	for _, part in nearbyParts do
		if not part.CanCollide or part.CollisionGroup ~= DOOR_COLLISION_GROUP then
			continue
		end
		local assemblyRoot = part.AssemblyRootPart
		if not assemblyRoot or assemblyRoot.Anchored then
			continue
		end

		local contactPoint = closestPointInBounds(part, rootPart.Position)
		local offset = Vector3.new(
			contactPoint.X - rootPart.Position.X,
			0,
			contactPoint.Z - rootPart.Position.Z
		)
		if offset:Dot(direction) < -0.1 then
			continue
		end
		local distance = offset.Magnitude
		if distance < selectedDistance then
			selectedPart = part
			selectedAssembly = assemblyRoot
			selectedPoint = contactPoint
			selectedDistance = distance
		end
	end

	if not selectedPart or not selectedAssembly then
		return nil
	end
	local assemblyMass = selectedAssembly.AssemblyMass
	if assemblyMass <= 0 or assemblyMass == math.huge then
		return nil
	end

	-- Applying the force at the body/leaf contact point creates the same hinge
	-- torque as a walking player pushing against the gate.
	selectedAssembly:ApplyImpulseAtPosition(
		direction * assemblyMass * HiderConfig.DOOR_PUSH_SPEED_CHANGE,
		selectedPoint
	)
	return selectedPart
end

return NpcDoorInteraction
