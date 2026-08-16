--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local WATER_NAME = "lowpolywater"
local SWIM_ANIMATION_NAME = "swim"
local SWIM_IDLE_ANIMATION_NAME = "swimidle"
local SWIM_SOUND_NAME = "SwimSound"
local MOVING_THRESHOLD = 0.05
local PROBE_INTERVAL_SECONDS = 0.08
local PROBE_HEIGHT = 1.5
local PROBE_CENTER_OFFSET = -0.25
local FADE_SECONDS = 0.15

type Controller = {
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	swimTrack: AnimationTrack,
	swimIdleTrack: AnimationTrack,
	swimSound: Sound?,
	activeTrack: AnimationTrack?,
	probeParameters: OverlapParams,
	connections: {RBXScriptConnection},
	probeAccumulator: number,
}

local localPlayer = Players.LocalPlayer
local activeController: Controller? = nil
local setupGeneration = 0

local function stopTrack(track: AnimationTrack?)
	if track and track.IsPlaying then
		track:Stop(FADE_SECONDS)
	end
end

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
	stopTrack(controller.swimTrack)
	stopTrack(controller.swimIdleTrack)
	if controller.swimSound then
		controller.swimSound:Stop()
		controller.swimSound:Destroy()
	end
	controller.swimTrack:Destroy()
	controller.swimIdleTrack:Destroy()
end

local function isWaterPart(part: BasePart): boolean
	local current: Instance? = part
	while current and current ~= Workspace do
		if string.lower(current.Name) == WATER_NAME then
			return true
		end
		current = current.Parent
	end
	return false
end

local function findAnimation(container: Instance, expectedName: string): Animation?
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("Animation")
			and string.lower(descendant.Name) == expectedName
			and descendant.AnimationId ~= "" then
			return descendant
		end
	end
	for _, descendant in ipairs(container:GetDescendants()) do
		if string.lower(descendant.Name) == expectedName then
			if descendant:IsA("Animation") and descendant.AnimationId ~= "" then
				return descendant
			end
			for _, nested in ipairs(descendant:GetDescendants()) do
				if nested:IsA("Animation") and nested.AnimationId ~= "" then
					return nested
				end
			end
		end
	end
	return nil
end

local function loadTrack(animator: Animator, animation: Animation): AnimationTrack?
	local succeeded, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not succeeded then
		warn(`LowPolyWaterAnimation: could not load {animation:GetFullName()}: {tostring(track)}`)
		return nil
	end
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action
	return track
end

local function createSwimSound(rootPart: BasePart): Sound?
	local template = SoundService:FindFirstChild(SWIM_SOUND_NAME)
	if not template or not template:IsA("Sound") or template.SoundId == "" then
		warn(`LowPolyWaterAnimation: SoundService.{SWIM_SOUND_NAME} must be a Sound with a SoundId`)
		return nil
	end
	local sound = template:Clone()
	sound.Name = SWIM_SOUND_NAME
	sound.Looped = true
	sound.PlayOnRemove = false
	sound.Parent = rootPart
	return sound
end

local function characterIsOnWater(controller: Controller): boolean
	local humanoid = controller.humanoid
	local rootPart = controller.rootPart
	if humanoid.Health <= 0 or humanoid.PlatformStand or not rootPart.Parent then
		return false
	end
	local footY = rootPart.Position.Y
		- math.max(0, humanoid.HipHeight)
		- rootPart.Size.Y * 0.5
	local probeCenter = Vector3.new(
		rootPart.Position.X,
		footY + PROBE_CENTER_OFFSET,
		rootPart.Position.Z
	)
	local probeSize = Vector3.new(
		math.max(1, rootPart.Size.X * 0.8),
		PROBE_HEIGHT,
		math.max(1, rootPart.Size.Z * 0.8)
	)
	for _, part in ipairs(Workspace:GetPartBoundsInBox(
		CFrame.new(probeCenter),
		probeSize,
		controller.probeParameters
	)) do
		if isWaterPart(part) then
			return true
		end
	end
	return false
end

local function setActiveTrack(controller: Controller, desiredTrack: AnimationTrack?)
	if controller.activeTrack == desiredTrack then
		if desiredTrack and not desiredTrack.IsPlaying then
			desiredTrack:Play(FADE_SECONDS)
		end
		return
	end
	stopTrack(controller.activeTrack)
	controller.activeTrack = desiredTrack
	if desiredTrack then
		desiredTrack:Play(FADE_SECONDS)
	end
end

local function updateController(controller: Controller)
	if activeController ~= controller or not controller.character.Parent then
		return
	end
	if not characterIsOnWater(controller) then
		setActiveTrack(controller, nil)
		if controller.swimSound and controller.swimSound.IsPlaying then
			controller.swimSound:Stop()
		end
		return
	end
	if controller.swimSound and not controller.swimSound.IsPlaying then
		controller.swimSound:Play()
	end
	local moving = controller.humanoid.MoveDirection.Magnitude > MOVING_THRESHOLD
	setActiveTrack(controller, if moving then controller.swimTrack else controller.swimIdleTrack)
end

local function setupCharacter(character: Model)
	setupGeneration += 1
	local generation = setupGeneration
	disconnectController()
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
	if generation ~= setupGeneration or localPlayer.Character ~= character or not character.Parent then
		return
	end
	local swimAnimation = findAnimation(character, SWIM_ANIMATION_NAME)
	local swimIdleAnimation = findAnimation(character, SWIM_IDLE_ANIMATION_NAME)
	if not swimAnimation or not swimIdleAnimation then
		warn("LowPolyWaterAnimation: character Animate needs swim and swimIdle animations")
		return
	end
	local swimTrack = loadTrack(animatorInstance, swimAnimation)
	local swimIdleTrack = loadTrack(animatorInstance, swimIdleAnimation)
	if not swimTrack or not swimIdleTrack then
		if swimTrack then
			swimTrack:Destroy()
		end
		if swimIdleTrack then
			swimIdleTrack:Destroy()
		end
		return
	end

	local probeParameters = OverlapParams.new()
	probeParameters.FilterType = Enum.RaycastFilterType.Exclude
	probeParameters.FilterDescendantsInstances = { character }
	probeParameters.MaxParts = 32
	local controller: Controller = {
		character = character,
		humanoid = humanoidInstance,
		rootPart = rootInstance,
		swimTrack = swimTrack,
		swimIdleTrack = swimIdleTrack,
		swimSound = createSwimSound(rootInstance),
		activeTrack = nil,
		probeParameters = probeParameters,
		connections = {},
		probeAccumulator = 0,
	}
	activeController = controller
	table.insert(controller.connections, RunService.Heartbeat:Connect(function(deltaTime)
		controller.probeAccumulator += deltaTime
		if controller.probeAccumulator < PROBE_INTERVAL_SECONDS then
			return
		end
		controller.probeAccumulator = 0
		updateController(controller)
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
