--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MovementAnimationConfig = require(ReplicatedStorage:WaitForChild("MovementAnimationConfig"))

type Controller = {
	character: Model,
	humanoid: Humanoid,
	animator: Animator,
	runningSpeed: number,
	movementAnimationIds: {[string]: boolean},
	connections: {RBXScriptConnection},
}

local localPlayer = Players.LocalPlayer
local activeController: Controller? = nil
local setupGeneration = 0

local function disconnectController()
	local controller = activeController
	activeController = nil
	if not controller then
		return
	end
	for _, connection in ipairs(controller.connections) do
		connection:Disconnect()
	end
	table.clear(controller.connections)
end

local function nameLooksLikeMovement(name: string): boolean
	local lowerName = string.lower(name)
	return string.find(lowerName, "walk", 1, true) ~= nil
		or string.find(lowerName, "run", 1, true) ~= nil
end

local function animationLooksLikeMovement(animation: Animation, character: Model): boolean
	local current: Instance? = animation
	while current do
		if nameLooksLikeMovement(current.Name) then
			return true
		end
		if current == character then
			break
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
	if activeController ~= controller
		or not controller.character.Parent
		or controller.humanoid.Health <= 0
		or controller.humanoid.WalkSpeed <= MovementAnimationConfig.MOVING_SPEED_THRESHOLD
		or controller.runningSpeed <= MovementAnimationConfig.MOVING_SPEED_THRESHOLD then
		return
	end
	local state = controller.humanoid:GetState()
	if state ~= Enum.HumanoidStateType.Running
		and state ~= Enum.HumanoidStateType.RunningNoPhysics then
		return
	end

	local playbackSpeed = MovementAnimationConfig.GetPlaybackSpeed(
		controller.runningSpeed,
		controller.humanoid.WalkSpeed
	)
	for _, track in ipairs(controller.animator:GetPlayingAnimationTracks()) do
		if trackIsMovement(controller, track) then
			track:AdjustSpeed(playbackSpeed)
		end
	end
end

local function setupCharacter(character: Model)
	setupGeneration += 1
	local generation = setupGeneration
	disconnectController()
	local humanoidInstance = character:WaitForChild("Humanoid", 10)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		return
	end
	local animatorInstance = humanoidInstance:FindFirstChildOfClass("Animator")
		or humanoidInstance:WaitForChild("Animator", 10)
	if not animatorInstance or not animatorInstance:IsA("Animator") then
		return
	end
	character:WaitForChild("Animate", 5)
	task.wait()
	if generation ~= setupGeneration or localPlayer.Character ~= character or not character.Parent then
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
		animator = animatorInstance,
		runningSpeed = 0,
		movementAnimationIds = movementAnimationIds,
		connections = {},
	}
	activeController = controller
	table.insert(controller.connections, humanoidInstance.Running:Connect(function(speed)
		controller.runningSpeed = speed
		task.defer(applyMovementPlaybackSpeed, controller)
	end))
	table.insert(controller.connections, animatorInstance.AnimationPlayed:Connect(function(_track)
		task.defer(applyMovementPlaybackSpeed, controller)
	end))
	table.insert(controller.connections, character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Animation") and animationLooksLikeMovement(descendant, character) then
			controller.movementAnimationIds[descendant.AnimationId] = true
		end
	end))
	-- Connect after the character's Animate script has initialized so this is the
	-- final locomotion speed adjustment made for the current animation frame.
	table.insert(controller.connections, RunService.PreAnimation:Connect(function()
		applyMovementPlaybackSpeed(controller)
	end))
	table.insert(controller.connections, character.Destroying:Connect(function()
		if activeController == controller then
			disconnectController()
		end
	end))
end

localPlayer.CharacterAdded:Connect(function(character)
	task.spawn(setupCharacter, character)
end)
localPlayer.CharacterRemoving:Connect(function(character)
	if activeController and activeController.character == character then
		setupGeneration += 1
		disconnectController()
	end
end)
if localPlayer.Character then
	task.spawn(setupCharacter, localPlayer.Character)
end
