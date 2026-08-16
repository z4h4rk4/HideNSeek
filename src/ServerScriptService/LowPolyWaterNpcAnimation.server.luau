--!strict

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local NPC_FOLDER_NAME = "RoundNPCs"
local WATER_NAME = "lowpolywater"
local SWIM_ANIMATION_NAME = "swim"
local SWIM_IDLE_ANIMATION_NAME = "swimidle"
local SWIM_SOUND_NAME = "SwimSound"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local MOVING_SPEED_THRESHOLD = 0.5
local PROBE_INTERVAL_SECONDS = 0.08
local PROBE_HEIGHT = 1.5
local PROBE_CENTER_OFFSET = -0.25
local FADE_SECONDS = 0.15

type Controller = {
	npc: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	swimTrack: AnimationTrack,
	swimIdleTrack: AnimationTrack,
	swimSound: Sound?,
	activeTrack: AnimationTrack?,
	probeParameters: OverlapParams,
	runningSpeed: number,
	connections: {RBXScriptConnection},
}

local controllers: {[Model]: Controller} = {}
local probeAccumulator = 0
local warnedInvalidSound = false

local function stopTrack(track: AnimationTrack?)
	if track and track.IsPlaying then
		track:Stop(FADE_SECONDS)
	end
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
			for _, nested in ipairs(descendant:GetDescendants()) do
				if nested:IsA("Animation") and nested.AnimationId ~= "" then
					return nested
				end
			end
		end
	end
	return nil
end

local function findNpcAnimation(npc: Model, expectedName: string): Animation?
	local embedded = findAnimation(npc, expectedName)
	if embedded then
		return embedded
	end
	local scripts = StarterPlayer:FindFirstChild("StarterCharacterScripts")
	local animate = if scripts then scripts:FindFirstChild("Animate") else nil
	return if animate then findAnimation(animate, expectedName) else nil
end

local function loadTrack(animator: Animator, animation: Animation): AnimationTrack?
	local succeeded, result = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not succeeded then
		warn(`LowPolyWaterNpcAnimation: could not load {animation:GetFullName()}: {tostring(result)}`)
		return nil
	end
	local track = result :: AnimationTrack
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action
	return track
end

local function createSwimSound(rootPart: BasePart): Sound?
	local template = SoundService:FindFirstChild(SWIM_SOUND_NAME)
	if not template or not template:IsA("Sound") or template.SoundId == "" then
		if not warnedInvalidSound then
			warnedInvalidSound = true
			warn(`LowPolyWaterNpcAnimation: SoundService.{SWIM_SOUND_NAME} must be a Sound with a SoundId`)
		end
		return nil
	end
	warnedInvalidSound = false
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
	if not controller.npc.Parent then
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
	setActiveTrack(
		controller,
		if controller.runningSpeed > MOVING_SPEED_THRESHOLD
			then controller.swimTrack
			else controller.swimIdleTrack
	)
end

local function removeController(npc: Model)
	local controller = controllers[npc]
	if not controller then
		return
	end
	controllers[npc] = nil
	for _, connection in ipairs(controller.connections) do
		connection:Disconnect()
	end
	table.clear(controller.connections)
	stopTrack(controller.swimTrack)
	stopTrack(controller.swimIdleTrack)
	controller.swimTrack:Destroy()
	controller.swimIdleTrack:Destroy()
	if controller.swimSound then
		controller.swimSound:Stop()
		controller.swimSound:Destroy()
	end
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
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local swimAnimation = findNpcAnimation(npc, SWIM_ANIMATION_NAME)
	local swimIdleAnimation = findNpcAnimation(npc, SWIM_IDLE_ANIMATION_NAME)
	if not swimAnimation or not swimIdleAnimation then
		warn(`LowPolyWaterNpcAnimation: {npc:GetFullName()} needs swim and swimIdle animations`)
		return
	end
	local swimTrack = loadTrack(animator, swimAnimation)
	local swimIdleTrack = loadTrack(animator, swimIdleAnimation)
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
	probeParameters.FilterDescendantsInstances = { npc }
	probeParameters.MaxParts = 32
	local controller: Controller = {
		npc = npc,
		humanoid = humanoid,
		rootPart = rootPart,
		swimTrack = swimTrack,
		swimIdleTrack = swimIdleTrack,
		swimSound = createSwimSound(rootPart),
		activeTrack = nil,
		probeParameters = probeParameters,
		runningSpeed = 0,
		connections = {},
	}
	controllers[npc] = controller
	table.insert(controller.connections, humanoid.Running:Connect(function(speed)
		controller.runningSpeed = speed
	end))
	table.insert(controller.connections, npc.Destroying:Connect(function()
		removeController(npc)
	end))
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
	probeAccumulator += deltaTime
	if probeAccumulator < PROBE_INTERVAL_SECONDS then
		return
	end
	probeAccumulator = 0
	for _, controller in pairs(controllers) do
		updateController(controller)
	end
end)
