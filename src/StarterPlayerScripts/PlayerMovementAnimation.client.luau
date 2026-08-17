--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MovementAnimationConfig = require(ReplicatedStorage:WaitForChild("MovementAnimationConfig"))

local localPlayer = Players.LocalPlayer

type Controller = {
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	animator: Animator,
	movementAnimationIds: {[string]: boolean},
	connections: {RBXScriptConnection},
}

local activeController: Controller? = nil
local setupRevision = 0

local function disconnectController()
	if not activeController then return end
	for _, connection in ipairs(activeController.connections) do
		connection:Disconnect()
	end
	table.clear(activeController.connections)
	activeController = nil
end

local function nameLooksLikeMovement(name: string): boolean
	local lowerName = string.lower(name)
	return string.find(lowerName, "walk", 1, true) ~= nil or string.find(lowerName, "run", 1, true) ~= nil
end

local function animationLooksLikeMovement(animation: Animation, character: Model): boolean
	local current: Instance? = animation

	while current and current ~= character do
		if nameLooksLikeMovement(current.Name) then
			return true
		end
		current = current.Parent
	end

	return false
end

local function trackIsMovement(controller: Controller, track: AnimationTrack): boolean
	if nameLooksLikeMovement(track.Name) then
		return true
	end

	local animation = track.Animation
	if controller.movementAnimationIds[animation.AnimationId] == true then
		return true
	end

	return animationLooksLikeMovement(animation, controller.character)
end

local function applyMovementPlaybackSpeed(controller: Controller)
	if not controller.character.Parent or not controller.rootPart.Parent or controller.humanoid.Health <= 0 then
		return
	end

	-- Так как мы обрабатываем только локального игрока, физика всегда идеальна
	local velocity = controller.rootPart.AssemblyLinearVelocity
	local actualSpeed = Vector2.new(velocity.X, velocity.Z).Magnitude

	if controller.humanoid.WalkSpeed <= MovementAnimationConfig.MOVING_SPEED_THRESHOLD or actualSpeed <= MovementAnimationConfig.MOVING_SPEED_THRESHOLD then
		return
	end

	local state = controller.humanoid:GetState()
	if state ~= Enum.HumanoidStateType.Running and state ~= Enum.HumanoidStateType.RunningNoPhysics then
		return
	end

	local playbackSpeed = MovementAnimationConfig.GetPlaybackSpeed(
		actualSpeed,
		controller.humanoid.WalkSpeed
	)

	for _, track in ipairs(controller.animator:GetPlayingAnimationTracks()) do
		if trackIsMovement(controller, track) then
			-- Защита от спама: меняем скорость только если она реально изменилась
			if math.abs(track.Speed - playbackSpeed) > 0.01 then
				track:AdjustSpeed(playbackSpeed)
			end
		end
	end
end

local function setupCharacter(character: Model, revision: number)
	disconnectController()

	local humanoidInstance = character:WaitForChild("Humanoid", 10)
	local rootInstance = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") or not rootInstance or not rootInstance:IsA("BasePart") then
		return
	end

	local animatorInstance = humanoidInstance:FindFirstChildOfClass("Animator") or humanoidInstance:WaitForChild("Animator", 10)
	if not animatorInstance or not animatorInstance:IsA("Animator") then
		return
	end

	character:WaitForChild("Animate", 5)
	task.wait()
	if setupRevision ~= revision or localPlayer.Character ~= character or not character.Parent then
		return
	end

	local movementAnimationIds: {[string]: boolean} = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Animation") and animationLooksLikeMovement(descendant, character) then
			movementAnimationIds[descendant.AnimationId] = true
		end
	end

	local controller: Controller = {
		character = character,
		humanoid = humanoidInstance,
		rootPart = rootInstance,
		animator = animatorInstance,
		movementAnimationIds = movementAnimationIds,
		connections = {},
	}
	activeController = controller

	table.insert(controller.connections, animatorInstance.AnimationPlayed:Connect(function(_track)
		task.defer(applyMovementPlaybackSpeed, controller)
	end))

	table.insert(controller.connections, character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Animation") and animationLooksLikeMovement(descendant, character) then
			controller.movementAnimationIds[descendant.AnimationId] = true
		end
	end))

	table.insert(controller.connections, character.Destroying:Connect(function()
		disconnectController()
	end))
end

local function beginCharacterSetup(character: Model)
	setupRevision += 1
	task.spawn(setupCharacter, character, setupRevision)
end

localPlayer.CharacterAdded:Connect(beginCharacterSetup)

localPlayer.CharacterRemoving:Connect(function()
	setupRevision += 1
	disconnectController()
end)

if localPlayer.Character then
	beginCharacterSetup(localPlayer.Character)
end

RunService.PreAnimation:Connect(function()
	if activeController then
		applyMovementPlaybackSpeed(activeController)
	end
end)
