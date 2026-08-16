--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local IceConfig = require(ReplicatedStorage:WaitForChild("IceConfig"))

type Controller = {
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	raycastParameters: RaycastParams,
	slideVelocity: Vector3,
	wasOnIce: boolean,
}

local localPlayer = Players.LocalPlayer
local activeController: Controller? = nil

local function setSlidingAttribute(controller: Controller, value: boolean)
	controller.character:SetAttribute(
		IceConfig.ON_ICE_ATTRIBUTE,
		if value then true else nil
	)
end

local function resetSlide(controller: Controller)
	controller.slideVelocity = Vector3.zero
	controller.wasOnIce = false
	setSlidingAttribute(controller, false)
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
	return localPlayer:GetAttribute(IceConfig.ROLE_ATTRIBUTE) ~= IceConfig.ROLE_SEEKER
		and controller.character.Parent ~= nil
		and controller.humanoid.Health > 0
		and not controller.humanoid.PlatformStand
		and not controller.rootPart.Anchored
end

local function updateSlide(controller: Controller, deltaTime: number)
	if activeController ~= controller or not canSlide(controller) then
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

local function setupCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local rootPart = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid
		or not humanoid:IsA("Humanoid")
		or not rootPart
		or not rootPart:IsA("BasePart") then
		return
	end

	local raycastParameters = RaycastParams.new()
	raycastParameters.FilterType = Enum.RaycastFilterType.Exclude
	raycastParameters.FilterDescendantsInstances = { character }
	raycastParameters.IgnoreWater = true
	activeController = {
		character = character,
		humanoid = humanoid,
		rootPart = rootPart,
		raycastParameters = raycastParameters,
		slideVelocity = Vector3.zero,
		wasOnIce = false,
	}
end

localPlayer.CharacterAdded:Connect(setupCharacter)
localPlayer.CharacterRemoving:Connect(function(character)
	if activeController and activeController.character == character then
		resetSlide(activeController)
		activeController = nil
	end
end)
if localPlayer.Character then
	task.spawn(setupCharacter, localPlayer.Character)
end

RunService.Heartbeat:Connect(function(deltaTime)
	local controller = activeController
	if controller then
		updateSlide(controller, deltaTime)
	end
end)
