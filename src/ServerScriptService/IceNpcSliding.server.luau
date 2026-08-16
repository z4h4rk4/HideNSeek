--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local IceConfig = require(ReplicatedStorage:WaitForChild("IceConfig"))

local NPC_FOLDER_NAME = "RoundNPCs"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"

type Controller = {
	npc: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	raycastParameters: RaycastParams,
	slideVelocity: Vector3,
	wasOnIce: boolean,
}

local controllers: {[Model]: Controller} = {}

local function setSlidingAttribute(controller: Controller, value: boolean)
	controller.npc:SetAttribute(
		IceConfig.ON_ICE_ATTRIBUTE,
		if value then true else nil
	)
end

local function resetSlide(controller: Controller)
	controller.slideVelocity = Vector3.zero
	controller.wasOnIce = false
	setSlidingAttribute(controller, false)
end

local function removeController(npc: Model)
	local controller = controllers[npc]
	if not controller then
		return
	end
	resetSlide(controller)
	controllers[npc] = nil
end

local function getFloorHit(controller: Controller): RaycastResult?
	local rayLength = controller.humanoid.HipHeight
		+ controller.rootPart.Size.Y * 0.5
		+ IceConfig.RAY_EXTRA_DISTANCE
	return Workspace:Raycast(
		controller.rootPart.Position,
		Vector3.new(0, -rayLength, 0),
		controller.raycastParameters
	)
end

local function canSlide(controller: Controller): boolean
	return controller.npc:GetAttribute(IceConfig.ROLE_ATTRIBUTE) ~= IceConfig.ROLE_SEEKER
		and controller.npc.Parent ~= nil
		and controller.humanoid.Health > 0
		and not controller.humanoid.PlatformStand
		and not controller.rootPart.Anchored
end

local function updateSlide(controller: Controller, deltaTime: number)
	if not canSlide(controller) then
		resetSlide(controller)
		return
	end

	local floorHit = getFloorHit(controller)
	if not floorHit or not IceConfig.IsIcePart(floorHit.Instance) then
		resetSlide(controller)
		return
	end

	local assemblyVelocity = controller.rootPart.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(assemblyVelocity.X, 0, assemblyVelocity.Z)
	if not controller.wasOnIce then
		controller.slideVelocity = horizontalVelocity
		controller.wasOnIce = true
		setSlidingAttribute(controller, true)
	end

	local moveDirection = controller.humanoid.MoveDirection
	local horizontalDirection = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	if horizontalDirection.Magnitude > IceConfig.MOVE_DIRECTION_THRESHOLD then
		local targetVelocity = horizontalDirection.Unit * controller.humanoid.WalkSpeed
		controller.slideVelocity = IceConfig.MoveToward(
			controller.slideVelocity,
			targetVelocity,
			IceConfig.STEERING_ACCELERATION * deltaTime
		)
	else
		controller.slideVelocity = IceConfig.MoveToward(
			controller.slideVelocity,
			Vector3.zero,
			IceConfig.COAST_DECELERATION * deltaTime
		)
	end

	controller.slideVelocity = IceConfig.ClampHorizontalVelocity(
		controller.slideVelocity,
		controller.humanoid.WalkSpeed
	)
	if controller.slideVelocity.Magnitude < IceConfig.MIN_SLIDE_SPEED then
		controller.slideVelocity = Vector3.zero
	end
	controller.rootPart.AssemblyLinearVelocity = Vector3.new(
		controller.slideVelocity.X,
		assemblyVelocity.Y,
		controller.slideVelocity.Z
	)
end

local function setupNpc(npc: Model)
	if controllers[npc]
		or npc:GetAttribute(MANAGED_NPC_ATTRIBUTE) ~= true
		or not npc:IsDescendantOf(Workspace) then
		return
	end
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local raycastParameters = RaycastParams.new()
	raycastParameters.FilterType = Enum.RaycastFilterType.Exclude
	raycastParameters.FilterDescendantsInstances = { npc }
	raycastParameters.IgnoreWater = true
	controllers[npc] = {
		npc = npc,
		humanoid = humanoid,
		rootPart = rootPart,
		raycastParameters = raycastParameters,
		slideVelocity = Vector3.zero,
		wasOnIce = false,
	}
end

local npcFolder = Workspace:WaitForChild(NPC_FOLDER_NAME)
for _, child in ipairs(npcFolder:GetChildren()) do
	if child:IsA("Model") then
		task.defer(setupNpc, child)
	end
end
npcFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		task.defer(setupNpc, child)
	end
end)
npcFolder.ChildRemoved:Connect(function(child)
	if child:IsA("Model") then
		removeController(child)
	end
end)

RunService.Heartbeat:Connect(function(deltaTime)
	for _, controller in pairs(controllers) do
		updateSlide(controller, deltaTime)
	end
end)
