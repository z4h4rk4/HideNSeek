--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MovementAnimationConfig = require(ReplicatedStorage:WaitForChild("MovementAnimationConfig"))

type Controller = {
	player: Player,
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	animator: Animator,
	movementAnimationIds: {[string]: boolean},
	connections: {RBXScriptConnection},
}

local controllers: {[Model]: Controller} = {}
local playerConnections: {[Player]: {RBXScriptConnection}} = {}
local setupRevisions: {[Player]: number} = {}

local function disconnectController(character: Model)
	local controller = controllers[character]
	controllers[character] = nil
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
	-- Do not classify by the character name: a player whose username contains
	-- "run" or "walk" must not make every one of their tracks locomotion.
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

local function getHorizontalSpeed(rootPart: BasePart): number
	local velocity = rootPart.AssemblyLinearVelocity
	return Vector2.new(velocity.X, velocity.Z).Magnitude
end

local function applyMovementPlaybackSpeed(controller: Controller)
	if controllers[controller.character] ~= controller
		or controller.player.Character ~= controller.character
		or not controller.character.Parent
		or not controller.rootPart.Parent
		or controller.humanoid.Health <= 0 then
		return
	end

	local actualSpeed = getHorizontalSpeed(controller.rootPart)
	if controller.humanoid.WalkSpeed <= MovementAnimationConfig.MOVING_SPEED_THRESHOLD
		or actualSpeed <= MovementAnimationConfig.MOVING_SPEED_THRESHOLD then
		return
	end
	local state = controller.humanoid:GetState()
	if state ~= Enum.HumanoidStateType.Running
		and state ~= Enum.HumanoidStateType.RunningNoPhysics then
		return
	end

	local playbackSpeed = MovementAnimationConfig.GetPlaybackSpeed(
		actualSpeed,
		controller.humanoid.WalkSpeed
	)
	for _, track in ipairs(controller.animator:GetPlayingAnimationTracks()) do
		if trackIsMovement(controller, track) then
			track:AdjustSpeed(playbackSpeed)
		end
	end
end

local function setupCharacter(player: Player, character: Model, revision: number)
	disconnectController(character)
	local humanoidInstance = character:WaitForChild("Humanoid", 10)
	local rootInstance = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoidInstance
		or not humanoidInstance:IsA("Humanoid")
		or not rootInstance
		or not rootInstance:IsA("BasePart") then
		return
	end
	local animatorInstance = humanoidInstance:FindFirstChildOfClass("Animator")
		or humanoidInstance:WaitForChild("Animator", 10)
	if not animatorInstance or not animatorInstance:IsA("Animator") then
		return
	end
	character:WaitForChild("Animate", 5)
	task.wait()
	if setupRevisions[player] ~= revision
		or player.Character ~= character
		or not character.Parent then
		return
	end

	local movementAnimationIds: {[string]: boolean} = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Animation") and animationLooksLikeMovement(descendant, character) then
			movementAnimationIds[descendant.AnimationId] = true
		end
	end

	local controller: Controller = {
		player = player,
		character = character,
		humanoid = humanoidInstance,
		rootPart = rootInstance,
		animator = animatorInstance,
		movementAnimationIds = movementAnimationIds,
		connections = {},
	}
	controllers[character] = controller
	table.insert(controller.connections, animatorInstance.AnimationPlayed:Connect(function(_track)
		task.defer(applyMovementPlaybackSpeed, controller)
	end))
	table.insert(controller.connections, character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Animation") and animationLooksLikeMovement(descendant, character) then
			controller.movementAnimationIds[descendant.AnimationId] = true
		end
	end))
	table.insert(controller.connections, character.Destroying:Connect(function()
		disconnectController(character)
	end))
end

local function setupPlayer(player: Player)
	if playerConnections[player] then
		return
	end
	local connections: {RBXScriptConnection} = {}
	playerConnections[player] = connections

	local function beginCharacterSetup(character: Model)
		local revision = (setupRevisions[player] or 0) + 1
		setupRevisions[player] = revision
		task.spawn(setupCharacter, player, character, revision)
	end

	table.insert(connections, player.CharacterAdded:Connect(beginCharacterSetup))
	table.insert(connections, player.CharacterRemoving:Connect(function(character)
		setupRevisions[player] = (setupRevisions[player] or 0) + 1
		disconnectController(character)
	end))
	if player.Character then
		beginCharacterSetup(player.Character)
	end
end

local function removePlayer(player: Player)
	local connections = playerConnections[player]
	playerConnections[player] = nil
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	setupRevisions[player] = nil
	if player.Character then
		disconnectController(player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end
Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(removePlayer)

-- AnimationTrack speed changes are local visual state. Apply them for every
-- real player so remote avatars look the same as the local avatar on this client.
RunService.PreAnimation:Connect(function()
	for _, controller in pairs(controllers) do
		applyMovementPlaybackSpeed(controller)
	end
end)
