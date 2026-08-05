--!strict

local Workspace = game:GetService("Workspace")

local HiderConfig = require(script.Parent:WaitForChild("HiderConfig"))
local DoorCharacterCollider = require(script.Parent:WaitForChild("DoorCharacterCollider"))

local DOOR_COLLISION_GROUP = DoorCharacterCollider.DOOR_COLLISION_GROUP
local PROXY_COLLISION_GROUP = DoorCharacterCollider.PROXY_COLLISION_GROUP

local NpcDoorInteraction = {}

type DoorMechanism = {
	hinge: HingeConstraint?,
}

local mechanismsByDoor: {[BasePart]: DoorMechanism} = {}
local ownershipVersions: {[BasePart]: number} = {}

local function horizontalUnit(vector: Vector3): Vector3?
	local horizontal = Vector3.new(vector.X, 0, vector.Z)
	return if horizontal.Magnitude > 0.001 then horizontal.Unit else nil
end

local function getDoorMechanism(doorPart: BasePart): DoorMechanism
	local cached = mechanismsByDoor[doorPart]
	if cached then
		return cached
	end

	local hingeAttachment = doorPart:FindFirstChild("Hinge1")
	if not hingeAttachment or not hingeAttachment:IsA("Attachment") then
		local assemblyRoot = doorPart.AssemblyRootPart
		if assemblyRoot and assemblyRoot ~= doorPart then
			hingeAttachment = assemblyRoot:FindFirstChild("Hinge1")
		end
	end

	local mechanism: DoorMechanism = {
		hinge = nil,
	}
	if hingeAttachment and hingeAttachment:IsA("Attachment") then
		for _, descendant in Workspace:GetDescendants() do
			if descendant:IsA("HingeConstraint")
				and (descendant.Attachment0 == hingeAttachment
					or descendant.Attachment1 == hingeAttachment) then
				mechanism.hinge = descendant
			end
			if mechanism.hinge then
				break
			end
		end
	end
	mechanismsByDoor[doorPart] = mechanism
	return mechanism
end

local function releaseDoorResistance(doorPart: BasePart)
	local mechanism = getDoorMechanism(doorPart)
	if mechanism.hinge and mechanism.hinge.Parent then
		-- The gate script uses TargetAngle = 0. Any positive ServoMaxTorque is
		-- therefore a brake while a character is trying to open the leaf.
		mechanism.hinge.ServoMaxTorque = 0
	end
end

local function claimDoorForServer(assemblyRoot: BasePart)
	pcall(function()
		assemblyRoot:SetNetworkOwner(nil)
	end)
	local version = (ownershipVersions[assemblyRoot] or 0) + 1
	ownershipVersions[assemblyRoot] = version
	task.delay(HiderConfig.DOOR_SERVER_OWNERSHIP_SECONDS, function()
		if ownershipVersions[assemblyRoot] ~= version then
			return
		end
		ownershipVersions[assemblyRoot] = nil
		if assemblyRoot.Parent then
			pcall(function()
				assemblyRoot:SetNetworkOwnershipAuto()
			end)
		end
	end)
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
	parameters.CollisionGroup = PROXY_COLLISION_GROUP
	parameters.MaxParts = HiderConfig.DOOR_PROBE_MAX_PARTS
	parameters.RespectCanCollide = true

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

		local contactPoint = part:GetClosestPointOnSurface(rootPart.Position)
		local offset = Vector3.new(
			contactPoint.X - rootPart.Position.X,
			0,
			contactPoint.Z - rootPart.Position.Z
		)
		if offset:Dot(direction) < -0.1 then
			continue
		end
		local distance = offset.Magnitude
		if distance > HiderConfig.DOOR_PUSH_CONTACT_DISTANCE then
			continue
		end
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

	releaseDoorResistance(selectedPart)
	claimDoorForServer(selectedAssembly)

	-- Applying the force at the body/leaf contact point creates the same hinge
	-- torque as a walking player pushing against the gate.
	selectedAssembly:ApplyImpulseAtPosition(
		direction * assemblyMass * HiderConfig.DOOR_PUSH_SPEED_CHANGE,
		selectedPoint
	)
	return selectedPart
end

return NpcDoorInteraction
