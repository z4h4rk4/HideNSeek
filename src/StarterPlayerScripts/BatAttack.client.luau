--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("BatAttackConfig"))
local CageConfig = require(ReplicatedStorage:WaitForChild("CageConfig"))
local SearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local TrashCanConfig = require(ReplicatedStorage:WaitForChild("TrashCanConfig"))
local attackRemote = ReplicatedStorage:WaitForChild(Config.REMOTE_EVENT_NAME) :: RemoteEvent

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local activeButton: GuiButton? = nil
local buttonConnection: RBXScriptConnection? = nil
local lastAttackAt = -math.huge
local warnedMissingAnimation: {[string]: boolean} = {}
local lastAimDirection: Vector3? = nil
local currentCageTarget: Model? = nil

local ROUND_ROLE_ATTRIBUTE = "RoundRole"
local ROLE_SEEKER = "Seeker"
local ROUND_NPC_FOLDER_NAME = "RoundNPCs"

type CageAreaVisual = {
	folder: Folder,
	fillWedges: {WedgePart},
	outlineParts: {Part},
	targetHighlight: Highlight,
}

local cageAreaVisual: CageAreaVisual? = nil

local function findEquippedWeapon(character: Model): Tool?
	for _, weaponName in ipairs(Config.WEAPON_MODEL_NAMES) do
		local weapon = character:FindFirstChild(weaponName)
		if weapon and weapon:IsA("Tool") then
			return weapon
		end
	end
	return nil
end

local function findAttackAnimation(weapon: Tool, animationName: string): Animation?
	for _, descendant in ipairs(weapon:GetDescendants()) do
		if descendant:IsA("Animation")
			and string.lower(descendant.Name) == string.lower(animationName) then
			return descendant
		end
	end
	return nil
end

local function playAttackAnimation(character: Model, weapon: Tool)
	-- TrashCan's animation is started by the server so AllahBabah may live in
	-- ServerStorage/RBX_ANIMSAVES instead of directly inside the Tool.
	if weapon.Name == TrashCanConfig.WEAPON_MODEL_NAME then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animationName = Config.ATTACK_ANIMATION_NAME
	local animation = findAttackAnimation(weapon, animationName)
	if not animation and weapon.Name == CageConfig.WEAPON_MODEL_NAME then
		local backpack = localPlayer:FindFirstChildOfClass("Backpack")
		local bat = character:FindFirstChild(Config.BAT_MODEL_NAME)
			or (if backpack then backpack:FindFirstChild(Config.BAT_MODEL_NAME) else nil)
		if bat and bat:IsA("Tool") then
			animation = findAttackAnimation(bat, Config.ATTACK_ANIMATION_NAME)
		end
	end
	if not humanoid or humanoid.Health <= 0 or not animation then
		if not animation and not warnedMissingAnimation[weapon.Name] then
			warnedMissingAnimation[weapon.Name] = true
			warn(
				`BatAttack: Animation '{animationName}' not found inside {weapon.Name}`
			)
		end
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end

	local succeeded, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not succeeded or not track then
		warn(`BatAttack: failed to load animation '{animation:GetFullName()}'`)
		return
	end

	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	track:Play(0.05, 1, 1)
	track.Ended:Once(function()
		track:Destroy()
	end)
end

local function horizontalUnit(direction: Vector3): Vector3?
	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	return if horizontal.Magnitude > 0.05 then horizontal.Unit else nil
end

local function getAimDirection(humanoid: Humanoid, rootPart: BasePart): Vector3
	local moveDirection = horizontalUnit(humanoid.MoveDirection)
	if moveDirection then
		lastAimDirection = moveDirection
		return moveDirection
	end
	if lastAimDirection then
		return lastAimDirection
	end

	local lookDirection = horizontalUnit(rootPart.CFrame.LookVector) or Vector3.zAxis
	lastAimDirection = lookDirection
	return lookDirection
end

local function configureAreaPart(part: BasePart, folder: Folder)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Transparency = 1
	part.Parent = folder
end

local function getCageAreaVisual(): CageAreaVisual
	if cageAreaVisual then
		return cageAreaVisual
	end

	local folder = Instance.new("Folder")
	folder.Name = "_CageTargetArea"
	folder.Archivable = false
	folder.Parent = Workspace
	local fillWedges: {WedgePart} = {}
	for _ = 1, CageConfig.INDICATOR_SEGMENT_COUNT * 4 do
		local wedge = Instance.new("WedgePart")
		wedge.Name = "SectorFill"
		wedge.Color = CageConfig.INDICATOR_FILL_COLOR
		configureAreaPart(wedge, folder)
		table.insert(fillWedges, wedge)
	end
	local outlineParts: {Part} = {}
	for _ = 1, CageConfig.INDICATOR_SEGMENT_COUNT * 2 + 2 do
		local line = Instance.new("Part")
		line.Name = "SectorOutline"
		line.Color = CageConfig.INDICATOR_OUTLINE_COLOR
		configureAreaPart(line, folder)
		table.insert(outlineParts, line)
	end
	local targetHighlight = Instance.new("Highlight")
	targetHighlight.Name = "CageTarget"
	targetHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
	targetHighlight.FillColor = CageConfig.TARGET_FILL_COLOR
	targetHighlight.FillTransparency = CageConfig.TARGET_FILL_TRANSPARENCY
	targetHighlight.OutlineColor = CageConfig.TARGET_OUTLINE_COLOR
	targetHighlight.OutlineTransparency = CageConfig.TARGET_OUTLINE_TRANSPARENCY
	targetHighlight.Enabled = false
	targetHighlight.Parent = folder

	local visual = {
		folder = folder,
		fillWedges = fillWedges,
		outlineParts = outlineParts,
		targetHighlight = targetHighlight,
	}
	cageAreaVisual = visual
	return visual
end

local function hideCageIndicator()
	local visual = cageAreaVisual
	if not visual then
		return
	end
	for _, wedge in ipairs(visual.fillWedges) do
		wedge.Transparency = 1
	end
	for _, line in ipairs(visual.outlineParts) do
		line.Transparency = 1
	end
	visual.targetHighlight.Enabled = false
	visual.targetHighlight.Adornee = nil
	currentCageTarget = nil
end

local function drawTriangle(
	pointA: Vector3,
	pointB: Vector3,
	pointC: Vector3,
	firstWedge: WedgePart,
	secondWedge: WedgePart
)
	local ab = pointB - pointA
	local ac = pointC - pointA
	local bc = pointC - pointB
	local abSquared = ab:Dot(ab)
	local acSquared = ac:Dot(ac)
	local bcSquared = bc:Dot(bc)
	if abSquared > acSquared and abSquared > bcSquared then
		pointC, pointA = pointA, pointC
	elseif acSquared > abSquared and acSquared > bcSquared then
		pointA, pointB = pointB, pointA
	end

	ab = pointB - pointA
	ac = pointC - pointA
	bc = pointC - pointB
	local rightVector = ac:Cross(ab)
	if rightVector.Magnitude <= 0.001 or bc.Magnitude <= 0.001 then
		firstWedge.Transparency = 1
		secondWedge.Transparency = 1
		return
	end
	local right = rightVector.Unit
	local back = bc.Unit
	local upVector = bc:Cross(right)
	if upVector.Magnitude <= 0.001 then
		firstWedge.Transparency = 1
		secondWedge.Transparency = 1
		return
	end
	local up = upVector.Unit
	local height = math.abs(ab:Dot(up))
	local firstLength = math.abs(ab:Dot(back))
	local secondLength = math.abs(ac:Dot(back))
	firstWedge.Size = Vector3.new(
		CageConfig.INDICATOR_THICKNESS,
		math.max(0.01, height),
		math.max(0.01, firstLength)
	)
	firstWedge.CFrame = CFrame.fromMatrix((pointA + pointB) * 0.5, right, up, back)
	secondWedge.Size = Vector3.new(
		CageConfig.INDICATOR_THICKNESS,
		math.max(0.01, height),
		math.max(0.01, secondLength)
	)
	secondWedge.CFrame = CFrame.fromMatrix((pointA + pointC) * 0.5, -right, up, -back)
	firstWedge.Transparency = if firstLength > 0.01
		then CageConfig.INDICATOR_FILL_TRANSPARENCY
		else 1
	secondWedge.Transparency = if secondLength > 0.01
		then CageConfig.INDICATOR_FILL_TRANSPARENCY
		else 1
end

local function setLine(part: Part, first: Vector3, second: Vector3, visible: boolean)
	local offset = second - first
	if not visible or offset.Magnitude <= 0.01 then
		part.Transparency = 1
		return
	end
	part.Size = Vector3.new(
		CageConfig.INDICATOR_OUTLINE_WIDTH,
		CageConfig.INDICATOR_THICKNESS,
		offset.Magnitude
	)
	part.CFrame = CFrame.lookAt((first + second) * 0.5, second)
	part.Transparency = CageConfig.INDICATOR_OUTLINE_TRANSPARENCY
end

local function getGroundPosition(character: Model, center: Vector3, fallbackY: number): Vector3
	local excluded: {Instance} = { character }
	for _ = 1, 5 do
		local parameters = RaycastParams.new()
		parameters.FilterType = Enum.RaycastFilterType.Exclude
		parameters.FilterDescendantsInstances = excluded
		parameters.IgnoreWater = true
		local result = Workspace:Raycast(
			center + Vector3.yAxis * 5,
			-Vector3.yAxis * 15,
			parameters
		)
		if not result then
			break
		end

		local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
		if hitModel and hitModel:FindFirstChildOfClass("Humanoid") then
			table.insert(excluded, hitModel)
			continue
		end
		return result.Position + Vector3.yAxis
			* (CageConfig.INDICATOR_THICKNESS * 0.5 + CageConfig.INDICATOR_GROUND_OFFSET)
	end
	return Vector3.new(center.X, fallbackY, center.Z)
end

local function characterIsCaged(character: Model): boolean
	if character:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true then
		return true
	end
	local player = Players:GetPlayerFromCharacter(character)
	return player ~= nil and player:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true
end

local function getCharacterRole(character: Model): any
	local player = Players:GetPlayerFromCharacter(character)
	return if player
		then player:GetAttribute(ROUND_ROLE_ATTRIBUTE)
		else character:GetAttribute(ROUND_ROLE_ATTRIBUTE)
end

local function hasLineOfSight(attackerCharacter: Model, targetCharacter: Model): boolean
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart")
		or not targetRoot or not targetRoot:IsA("BasePart") then
		return false
	end
	local direction = targetRoot.Position - attackerRoot.Position
	if direction.Magnitude <= 0.05 then
		return true
	end
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { attackerCharacter }
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true
	local result = Workspace:Raycast(attackerRoot.Position, direction, parameters)
	return result == nil or result.Instance:IsDescendantOf(targetCharacter)
end

local function findCageTarget(
	attackerCharacter: Model,
	attackerRoot: BasePart,
	direction: Vector3
): Model?
	local captureCenter = attackerRoot.Position
		+ direction * CageConfig.CAPTURE_PLACEMENT_DISTANCE
	local minimumFacingDot = math.cos(math.rad(CageConfig.AREA_FOV_DEGREES * 0.5))
	local checked: {[Model]: boolean} = {}
	local closestTarget: Model? = nil
	local closestDistance = math.huge
	local function consider(character: Model?)
		if not character or character == attackerCharacter or checked[character] then
			return
		end
		checked[character] = true
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if getCharacterRole(character) == ROLE_SEEKER
			or characterIsCaged(character)
			or not humanoid or humanoid.Health <= 0 or humanoid.PlatformStand
			or not rootPart or not rootPart:IsA("BasePart") or rootPart.Anchored then
			return
		end
		local offset = rootPart.Position - attackerRoot.Position
		local horizontalOffset = Vector3.new(offset.X, 0, offset.Z)
		local horizontalDistance = horizontalOffset.Magnitude
		local facingDot = if horizontalDistance > 0.05
			then direction:Dot(horizontalOffset.Unit)
			else 1
		if horizontalDistance < CageConfig.AREA_MIN_DISTANCE
			or horizontalDistance > CageConfig.AREA_MAX_DISTANCE
			or facingDot < minimumFacingDot
			or math.abs(offset.Y) > CageConfig.AREA_HEIGHT * 0.5
			or not hasLineOfSight(attackerCharacter, character) then
			return
		end
		local distanceToCaptureCenter = Vector2.new(
			rootPart.Position.X - captureCenter.X,
			rootPart.Position.Z - captureCenter.Z
		).Magnitude
		if distanceToCaptureCenter < closestDistance then
			closestDistance = distanceToCaptureCenter
			closestTarget = character
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		consider(player.Character)
	end
	local npcFolder = Workspace:FindFirstChild(ROUND_NPC_FOLDER_NAME)
	if npcFolder then
		for _, npc in ipairs(npcFolder:GetChildren()) do
			if npc:IsA("Model") then
				consider(npc)
			end
		end
	end
	return closestTarget
end

local function updateSectorVisual(
	visual: CageAreaVisual,
	rootPart: BasePart,
	direction: Vector3,
	groundY: number,
	minimumDistance: number,
	maximumDistance: number,
	fovDegrees: number
)
	local origin = Vector3.new(rootPart.Position.X, groundY, rootPart.Position.Z)
	local right = Vector3.new(-direction.Z, 0, direction.X)
	local halfAngle = math.rad(fovDegrees * 0.5)
	local angleStep = halfAngle * 2 / CageConfig.INDICATOR_SEGMENT_COUNT
	local outerPoints: {Vector3} = {}
	local innerPoints: {Vector3} = {}
	for index = 0, CageConfig.INDICATOR_SEGMENT_COUNT do
		local angle = -halfAngle + angleStep * index
		local rayDirection = direction * math.cos(angle) + right * math.sin(angle)
		outerPoints[index + 1] = origin + rayDirection * maximumDistance
		innerPoints[index + 1] = origin + rayDirection * minimumDistance
	end

	for index = 1, CageConfig.INDICATOR_SEGMENT_COUNT do
		local wedgeIndex = (index - 1) * 4 + 1
		local innerFirst = innerPoints[index]
		local innerSecond = innerPoints[index + 1]
		local outerFirst = outerPoints[index]
		local outerSecond = outerPoints[index + 1]
		drawTriangle(
			innerFirst,
			outerFirst,
			outerSecond,
			visual.fillWedges[wedgeIndex],
			visual.fillWedges[wedgeIndex + 1]
		)
		drawTriangle(
			innerFirst,
			outerSecond,
			innerSecond,
			visual.fillWedges[wedgeIndex + 2],
			visual.fillWedges[wedgeIndex + 3]
		)
		setLine(visual.outlineParts[index], outerFirst, outerSecond, true)
		setLine(
			visual.outlineParts[CageConfig.INDICATOR_SEGMENT_COUNT + index],
			innerFirst,
			innerSecond,
			minimumDistance > 0.01
		)
	end
	local sideIndex = CageConfig.INDICATOR_SEGMENT_COUNT * 2 + 1
	setLine(visual.outlineParts[sideIndex], innerPoints[1], outerPoints[1], true)
	setLine(
		visual.outlineParts[sideIndex + 1],
		innerPoints[#innerPoints],
		outerPoints[#outerPoints],
		true
	)
end

local function updateAttackAreaIndicator()
	local character = localPlayer.Character
	if not character
		or character:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true
		or localPlayer:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true then
		hideCageIndicator()
		return
	end

	local weapon = findEquippedWeapon(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local isCage = weapon ~= nil and weapon.Name == CageConfig.WEAPON_MODEL_NAME
	local isTrashCan = weapon ~= nil and weapon.Name == TrashCanConfig.WEAPON_MODEL_NAME
	if not weapon or (not isCage and not isTrashCan)
		or not humanoid or humanoid.Health <= 0 or humanoid.PlatformStand
		or not rootPart or not rootPart:IsA("BasePart") then
		hideCageIndicator()
		return
	end

	local direction = getAimDirection(humanoid, rootPart)
	local minimumDistance = if isCage then CageConfig.AREA_MIN_DISTANCE else 0
	local maximumDistance = if isCage
		then CageConfig.AREA_MAX_DISTANCE
		else TrashCanConfig.RANGE_STUDS
	local fovDegrees = if isCage
		then CageConfig.AREA_FOV_DEGREES
		else TrashCanConfig.ANGLE_DEGREES
	local centerDistance = if isCage
		then CageConfig.CAPTURE_PLACEMENT_DISTANCE
		else maximumDistance * 0.5
	local center = rootPart.Position + direction * centerDistance
	local fallbackY = rootPart.Position.Y - humanoid.HipHeight - rootPart.Size.Y * 0.5
	local groundPosition = getGroundPosition(character, center, fallbackY)
	local visual = getCageAreaVisual()
	updateSectorVisual(
		visual,
		rootPart,
		direction,
		groundPosition.Y,
		minimumDistance,
		maximumDistance,
		fovDegrees
	)
	local target = if isCage then findCageTarget(character, rootPart, direction) else nil
	currentCageTarget = target
	visual.targetHighlight.Adornee = target
	visual.targetHighlight.Enabled = target ~= nil
end

local function attack()
	local now = os.clock()
	if now - lastAttackAt < Config.ATTACK_COOLDOWN_SECONDS then
		return
	end

	local character = localPlayer.Character
	if not character
		or character:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true
		or localPlayer:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true then
		return
	end
	local weapon = findEquippedWeapon(character)
	if not weapon then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or humanoid.PlatformStand then
		return
	end

	lastAttackAt = now
	playAttackAnimation(character, weapon)
	if weapon.Name == CageConfig.WEAPON_MODEL_NAME
		or weapon.Name == TrashCanConfig.WEAPON_MODEL_NAME then
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart or not rootPart:IsA("BasePart") then
			return
		end
		local direction = getAimDirection(humanoid, rootPart)
		local target = if weapon.Name == CageConfig.WEAPON_MODEL_NAME
			then findCageTarget(character, rootPart, direction) or currentCageTarget
			else nil
		attackRemote:FireServer(direction, target)
	else
		attackRemote:FireServer()
	end
end

local function getAttackButton(): GuiButton?
	local attackGui = playerGui:FindFirstChild("AttackGui")
	local attackFrame = attackGui and attackGui:FindFirstChild("AttackFrame")
	local fistButton = attackFrame and attackFrame:FindFirstChild("FistBtn")
	return if fistButton and fistButton:IsA("GuiButton") then fistButton else nil
end

local function refreshButton()
	local button = getAttackButton()
	if button == activeButton then
		return
	end

	if buttonConnection then
		buttonConnection:Disconnect()
		buttonConnection = nil
	end
	activeButton = button
	if button then
		buttonConnection = button.Activated:Connect(attack)
	end
end

playerGui.DescendantAdded:Connect(function(descendant)
	if descendant.Name == "AttackGui"
		or descendant.Name == "AttackFrame"
		or descendant.Name == "FistBtn" then
		task.defer(refreshButton)
	end
end)
playerGui.DescendantRemoving:Connect(function(descendant)
	local button = activeButton
	if button and (descendant == button or descendant:IsAncestorOf(button)) then
		task.defer(refreshButton)
	end
end)
localPlayer.CharacterAdded:Connect(function()
	lastAttackAt = -math.huge
	lastAimDirection = nil
	hideCageIndicator()
	task.defer(refreshButton)
end)

refreshButton()
RunService.RenderStepped:Connect(updateAttackAreaIndicator)
