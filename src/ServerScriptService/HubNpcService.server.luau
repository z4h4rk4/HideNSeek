--!strict

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local CashProductConfig = require(ReplicatedStorage:WaitForChild("CashProductConfig"))
local SkinCaseConfig = require(ReplicatedStorage:WaitForChild("SkinCaseConfig"))
local RoundConfig = require(script.Parent:WaitForChild("Round"):WaitForChild("RoundConfig"))
local DoorCharacterCollider = require(script.Parent:WaitForChild("Round"):WaitForChild("DoorCharacterCollider"))
local HiderAnimation = require(script.Parent:WaitForChild("Round"):WaitForChild("HiderAnimation"))

local HUB_CONTAINER_NAME = "HUB"
local HUB_SPAWN_NAME = "SpawnHUB"
local HUB_SHOPS_NAME = "Shops"
local HUB_SHOP_NAME = "Shop"
local HUNTER_CHARACTER_NAME = "HunterCharacter"
local DONATE_OBJECT_NAME = "DonatePls"
local HUB_CHARACTER_FOLDER_NAME = "HubCharacters"
local HUB_CHARACTER_ATTRIBUTE = "HubAmbientCharacter"
local CASE_SELLER_PROMPT_NAME = SkinCaseConfig.HUB_CASE_SELLER_PROMPT_NAME
local CASE_SELLER_PROMPT_ATTRIBUTE = SkinCaseConfig.HUB_CASE_SELLER_PROMPT_ATTRIBUTE
local CASE_SELLER_ANIMATION_ID = "rbxassetid://109216362397650"
local CASE_SELLER_ANIMATION_RESTART_SECONDS = 0.25
local CASE_SELLER_ANIMATION_LENGTH_WAIT_SECONDS = 5

local HUB_CHARACTER_COUNT = 6
local HUB_WANDER_RADIUS = 42
local HUB_WALK_SPEED = math.max(4, RoundConfig.WALK_SPEED * 0.7)
local CASE_SELLER_PROMPT_DISTANCE = 10
local SURFACE_SAMPLE_ATTEMPTS = 40
local DIRECT_MOVE_TIMEOUT_SECONDS = 8
local WAYPOINT_TIMEOUT_SECONDS = 5
local IDLE_MIN_SECONDS = 2.5
local IDLE_MAX_SECONDS = 6
local IDLE_ONLY_CHANCE = 0.45
local MIN_RESPAWN_SECONDS = 3

local random = Random.new()
local spawnWarningShown = false
local hubCharacterFolder = Workspace:FindFirstChild(HUB_CHARACTER_FOLDER_NAME)
if not hubCharacterFolder then
	hubCharacterFolder = Instance.new("Folder")
	hubCharacterFolder.Name = HUB_CHARACTER_FOLDER_NAME
	hubCharacterFolder.Parent = Workspace
end
for _, child in ipairs(hubCharacterFolder:GetChildren()) do
	child:Destroy()
end

local function getHub(): Instance?
	return Workspace:FindFirstChild(HUB_CONTAINER_NAME)
end

local function getHubSpawn(): BasePart?
	local hub = getHub()
	local spawn = hub and hub:FindFirstChild(HUB_SPAWN_NAME)
	return if spawn and spawn:IsA("BasePart") then spawn else nil
end

local function getCaseSeller(): Model?
	local hub = getHub()
	local shops = hub and hub:FindFirstChild(HUB_SHOPS_NAME)
	local shop = shops and shops:FindFirstChild(HUB_SHOP_NAME)
	local seller = shop and shop:FindFirstChild(HUNTER_CHARACTER_NAME)
	return if seller and seller:IsA("Model") then seller else nil
end

local function getDonateObject(): Instance?
	local hub = getHub()
	return hub and hub:FindFirstChild(DONATE_OBJECT_NAME, true) or nil
end

local function getStarterPack(): Instance?
	local characters = ServerStorage:FindFirstChild(SkinCaseConfig.CHARACTERS_FOLDER_NAME)
	return characters and characters:FindFirstChild(SkinCaseConfig.STARTER_PACK_FOLDER_NAME) or nil
end

local function templateIsUsable(template: Instance): boolean
	if not template:IsA("Model") then
		return false
	end
	local humanoid = template:FindFirstChildOfClass("Humanoid")
	local rootPart = template:FindFirstChild("HumanoidRootPart")
	return humanoid ~= nil and rootPart ~= nil and rootPart:IsA("BasePart")
end

local function getRandomTemplate(): Model?
	local starterPack = getStarterPack()
	if not starterPack then
		return nil
	end

	local templates = {}
	for _, child in ipairs(starterPack:GetChildren()) do
		if templateIsUsable(child) then
			table.insert(templates, child)
		end
	end
	if #templates == 0 then
		return nil
	end
	return templates[random:NextInteger(1, #templates)] :: Model
end

local function collectHubFloorParts(): {BasePart}
	local hub = getHub()
	if not hub then
		return {}
	end

	local floorParts = {}
	for _, descendant in ipairs(hub:GetDescendants()) do
		if descendant:IsA("BasePart")
			and descendant.CanCollide
			and descendant.CanQuery
			and descendant.Size.X >= 3
			and descendant.Size.Z >= 3
			and math.abs(descendant.CFrame.UpVector.Y) >= 0.7 then
			table.insert(floorParts, descendant)
		end
	end
	return floorParts
end

local function getRaycastParams(character: Model?): RaycastParams
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	local excludes = { hubCharacterFolder }
	if character then
		table.insert(excludes, character)
	end
	parameters.FilterDescendantsInstances = excludes
	parameters.IgnoreWater = true
	return parameters
end

local function projectToHubFloor(origin: Vector3, character: Model?): Vector3?
	local hub = getHub()
	if not hub then
		return nil
	end
	local hit = Workspace:Raycast(origin + Vector3.new(0, 35, 0), Vector3.new(0, -90, 0), getRaycastParams(character))
	if not hit or not hit.Instance:IsDescendantOf(hub) or hit.Normal.Y < 0.65 then
		return nil
	end
	return hit.Position
end

local function sampleDestination(character: Model?): Vector3?
	local floorParts = collectHubFloorParts()
	if #floorParts > 0 then
		for _ = 1, SURFACE_SAMPLE_ATTEMPTS do
			local part = floorParts[random:NextInteger(1, #floorParts)]
			local localPoint = Vector3.new(
				random:NextNumber(-part.Size.X * 0.45, part.Size.X * 0.45),
				part.Size.Y * 0.5 + 8,
				random:NextNumber(-part.Size.Z * 0.45, part.Size.Z * 0.45)
			)
			local projected = projectToHubFloor(part.CFrame:PointToWorldSpace(localPoint), character)
			if projected then
				return projected
			end
		end
	end

	local hubSpawn = getHubSpawn()
	if not hubSpawn then
		return nil
	end
	for _ = 1, SURFACE_SAMPLE_ATTEMPTS do
		local angle = random:NextNumber(0, math.pi * 2)
		local radius = math.sqrt(random:NextNumber()) * HUB_WANDER_RADIUS
		local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local projected = projectToHubFloor(hubSpawn.Position + offset, character)
		if projected then
			return projected
		end
	end
	return projectToHubFloor(hubSpawn.Position, character)
end

local function getRootCFrameForGround(humanoid: Humanoid, rootPart: BasePart, groundPosition: Vector3): CFrame
	local height = humanoid.HipHeight + rootPart.Size.Y * 0.5
	return CFrame.new(groundPosition + Vector3.new(0, height, 0))
end

local function pivotCharacterRootTo(character: Model, humanoid: Humanoid, rootPart: BasePart, groundPosition: Vector3)
	local rootToPivot = rootPart.CFrame:ToObjectSpace(character:GetPivot())
	character:PivotTo(getRootCFrameForGround(humanoid, rootPart, groundPosition) * rootToPivot)
end

local function moveTo(humanoid: Humanoid, rootPart: BasePart, destination: Vector3, timeoutSeconds: number): boolean
	local finished = false
	local reached = false
	local connection = humanoid.MoveToFinished:Connect(function(didReach)
		reached = didReach
		finished = true
	end)
	humanoid:MoveTo(destination)

	local startedAt = os.clock()
	while not finished
		and rootPart.Parent
		and humanoid.Health > 0
		and os.clock() - startedAt < timeoutSeconds do
		task.wait(0.1)
	end
	connection:Disconnect()
	return reached
end

local function walkPath(character: Model, humanoid: Humanoid, rootPart: BasePart, destination: Vector3)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = false,
		WaypointSpacing = 5,
	})
	local ok = pcall(function()
		path:ComputeAsync(rootPart.Position, destination)
	end)
	if ok and path.Status == Enum.PathStatus.Success then
		for _, waypoint in ipairs(path:GetWaypoints()) do
			if not character.Parent or humanoid.Health <= 0 then
				return
			end
			if not moveTo(humanoid, rootPart, waypoint.Position, WAYPOINT_TIMEOUT_SECONDS) then
				return
			end
		end
	else
		moveTo(humanoid, rootPart, destination, DIRECT_MOVE_TIMEOUT_SECONDS)
	end
end

local function prepareCharacter(character: Model, index: number): (Humanoid?, BasePart?)
	character:SetAttribute(HUB_CHARACTER_ATTRIBUTE, true)
	character:SetAttribute("RoundRole", nil)
	character.Name = `HubCharacter_{index}`

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		return nil, nil
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant.Disabled = true
		end
	end

	humanoid.DisplayName = ""
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.WalkSpeed = HUB_WALK_SPEED
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = 0
	humanoid.AutoRotate = true
	humanoid.Sit = false
	humanoid.PlatformStand = false
	if humanoid.MaxHealth <= 0 then
		humanoid.MaxHealth = 100
	end
	humanoid.Health = humanoid.MaxHealth
	return humanoid, rootPart
end

local function getPromptParent(character: Model): BasePart?
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	local head = character:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head else nil
end

local function getInstancePromptParent(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		local primaryPart = instance.PrimaryPart
		if primaryPart then
			return primaryPart
		end
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function playCaseSellerAnimation(character: Model, humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animation = Instance.new("Animation")
	animation.Name = "CaseSellerIdle"
	animation.AnimationId = CASE_SELLER_ANIMATION_ID

	local succeeded, trackOrMessage = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not succeeded then
		warn(`HubNpcService: could not load case seller animation: {tostring(trackOrMessage)}`)
		return
	end

	local track = trackOrMessage :: AnimationTrack
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action

	local stopped = false
	local stoppedConnection: RBXScriptConnection? = nil

	local function sellerStillValid(): boolean
		return not stopped
			and character.Parent ~= nil
			and humanoid.Parent ~= nil
			and humanoid.Health > 0
	end

	local function playFromStart()
		if not sellerStillValid() then
			return
		end
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Action
		if not track.IsPlaying then
			track:Play(0.05)
		end
		pcall(function()
			track.TimePosition = 0
		end)
	end

	stoppedConnection = track.Stopped:Connect(function()
		if stopped then
			return
		end
		task.delay(0.05, playFromStart)
	end)

	playFromStart()

	character.Destroying:Once(function()
		stopped = true
		if stoppedConnection then
			stoppedConnection:Disconnect()
			stoppedConnection = nil
		end
		track:Stop(0)
		track:Destroy()
	end)

	task.spawn(function()
		local lengthDeadline = os.clock() + CASE_SELLER_ANIMATION_LENGTH_WAIT_SECONDS
		while sellerStillValid() and track.Length <= 0 and os.clock() < lengthDeadline do
			task.wait(CASE_SELLER_ANIMATION_RESTART_SECONDS)
		end

		while sellerStillValid() do
			local waitSeconds = if track.Length > 0
				then math.max(CASE_SELLER_ANIMATION_RESTART_SECONDS, track.Length - 0.05)
				else CASE_SELLER_ANIMATION_RESTART_SECONDS
			task.wait(waitSeconds)
			if sellerStillValid() then
				playFromStart()
			end
		end
	end)
end

local function setupCaseSeller()
	local character = getCaseSeller()
	if not character then
		warn("HubNpcService: expected Workspace.HUB.Shops.Shop.HunterCharacter")
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayName = ""
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.AutoRotate = false
		playCaseSellerAnimation(character, humanoid)
	end

	DoorCharacterCollider.Configure()
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = DoorCharacterCollider.HUB_COLLISION_GROUP
		end
	end

	local promptParent = getPromptParent(character)
	if not promptParent then
		warn("HubNpcService: HunterCharacter needs HumanoidRootPart or Head for the case shop prompt")
		return
	end

	local prompt = promptParent:FindFirstChild(CASE_SELLER_PROMPT_NAME)
	if not prompt or not prompt:IsA("ProximityPrompt") then
		if prompt then
			prompt:Destroy()
		end
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = CASE_SELLER_PROMPT_NAME
		prompt.Parent = promptParent
	end

	prompt:SetAttribute(CASE_SELLER_PROMPT_ATTRIBUTE, true)
	prompt.ActionText = "Open"
	prompt.ObjectText = "Cases"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = CASE_SELLER_PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
end

local function setupDonatePrompt()
	local donateObject = getDonateObject()
	if not donateObject then
		warn("HubNpcService: expected Workspace.HUB.DonatePls")
		return
	end

	local promptParent = getInstancePromptParent(donateObject)
	if not promptParent then
		warn("HubNpcService: Workspace.HUB.DonatePls needs a BasePart for the donate prompt")
		return
	end

	local prompt = promptParent:FindFirstChild(CashProductConfig.DONATE_PROMPT_NAME)
	if not prompt or not prompt:IsA("ProximityPrompt") then
		if prompt then
			prompt:Destroy()
		end
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = CashProductConfig.DONATE_PROMPT_NAME
		prompt.Parent = promptParent
	end

	prompt:SetAttribute(CashProductConfig.DONATE_PROMPT_ATTRIBUTE, true)
	prompt.ActionText = CashProductConfig.DONATE_PROMPT_ACTION_TEXT
	prompt.ObjectText = CashProductConfig.DONATE_PROMPT_OBJECT_TEXT
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = CashProductConfig.DONATE_PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
end

local function spawnHubCharacter(index: number): Model?
	local template = getRandomTemplate()
	local hubSpawn = getHubSpawn()
	if not template or not hubSpawn then
		return nil
	end

	local oldArchivable = template.Archivable
	template.Archivable = true
	local character = template:Clone()
	template.Archivable = oldArchivable

	local humanoid, rootPart = prepareCharacter(character, index)
	if not humanoid or not rootPart then
		character:Destroy()
		return nil
	end

	local spawnPoint = sampleDestination(character) or hubSpawn.Position
	pivotCharacterRootTo(character, humanoid, rootPart, spawnPoint)
	character.Parent = hubCharacterFolder
	DoorCharacterCollider.Refresh(character, DoorCharacterCollider.HUB_COLLISION_GROUP)
	pcall(function()
		rootPart:SetNetworkOwnershipAuto()
	end)
	HiderAnimation.Start(character)
	return character
end

local function runHubCharacter(index: number)
	while true do
		local character = spawnHubCharacter(index)
		if not character then
			if not spawnWarningShown then
				spawnWarningShown = true
				warn("HubNpcService: could not spawn HUB character; waiting for HUB and StarterPack templates")
			end
			task.wait(MIN_RESPAWN_SECONDS)
			continue
		end
		spawnWarningShown = false

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		while character.Parent and humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") do
			local hubSpawn = getHubSpawn()
			if hubSpawn and rootPart.Position.Y < hubSpawn.Position.Y - 80 then
				break
			end
			local destination = if random:NextNumber() >= IDLE_ONLY_CHANCE
				then sampleDestination(character)
				else nil
			if destination then
				walkPath(character, humanoid, rootPart, destination)
			else
				humanoid:Move(Vector3.zero, false)
			end
			task.wait(random:NextNumber(IDLE_MIN_SECONDS, IDLE_MAX_SECONDS))
		end

		HiderAnimation.Stop(character)
		DoorCharacterCollider.Destroy(character)
		if character.Parent then
			character:Destroy()
		end
		task.wait(MIN_RESPAWN_SECONDS)
	end
end

task.defer(function()
	if not getHub() then
		Workspace:WaitForChild(HUB_CONTAINER_NAME, 30)
	end
	if not getStarterPack() then
		local characters = ServerStorage:WaitForChild(SkinCaseConfig.CHARACTERS_FOLDER_NAME, 30)
		if characters then
			characters:WaitForChild(SkinCaseConfig.STARTER_PACK_FOLDER_NAME, 30)
		end
	end

	setupCaseSeller()
	setupDonatePrompt()

	for index = 1, HUB_CHARACTER_COUNT do
		task.spawn(runHubCharacter, index)
		task.wait(0.25)
	end
end)
