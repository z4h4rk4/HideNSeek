--!strict

local Players = game:GetService("Players")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("BatAttackConfig"))
local CageConfig = require(ReplicatedStorage:WaitForChild("CageConfig"))
local SearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local TrashCanConfig = require(ReplicatedStorage:WaitForChild("TrashCanConfig"))
local CageService = require(script.Parent:WaitForChild("Round"):WaitForChild("CageService"))

local ROUND_ROLE_ATTRIBUTE = "RoundRole"
local ROLE_SEEKER = "Seeker"
local ROUND_NPC_FOLDER_NAME = "RoundNPCs"

type KnockdownRecord = {
	token: number,
	platformStand: boolean,
	autoRotate: boolean,
	walkSpeed: number,
	walkSpeedConnection: RBXScriptConnection?,
	animationPlayedConnection: RBXScriptConnection?,
	npcTurnOrientation: AlignOrientation?,
	npcTurnOrientationEnabled: boolean?,
}

type TrashActionRecord = {
	character: Model,
	track: AnimationTrack,
	walkSpeed: number,
	autoRotate: boolean,
	jumpHeight: number,
	jumpPower: number,
	connections: {RBXScriptConnection},
}

local lastAttackByPlayer: {[Player]: number} = {}
local knockdownRecords: {[Humanoid]: KnockdownRecord} = {}
local trashActionRecords: {[Humanoid]: TrashActionRecord} = {}
local configuredWeapons: {[Tool]: boolean} = {}
local configuredWeaponParts: {[BasePart]: boolean} = {}
local warnedMissingTrashAnimation = false
local warnedMissingTrashEffect = false
local studioTrashAnimation: Animation? = nil

local attackRemoteInstance = ReplicatedStorage:FindFirstChild(Config.REMOTE_EVENT_NAME)
if attackRemoteInstance and not attackRemoteInstance:IsA("RemoteEvent") then
	error(`ReplicatedStorage.{Config.REMOTE_EVENT_NAME} must be a RemoteEvent`)
end
local attackRemote: RemoteEvent
if attackRemoteInstance then
	attackRemote = attackRemoteInstance :: RemoteEvent
else
	local newRemote = Instance.new("RemoteEvent")
	newRemote.Name = Config.REMOTE_EVENT_NAME
	newRemote.Parent = ReplicatedStorage
	attackRemote = newRemote
end

local function isWeaponName(name: string): boolean
	for _, weaponName in ipairs(Config.WEAPON_MODEL_NAMES) do
		if name == weaponName then
			return true
		end
	end
	return false
end

local function findEquippedWeapon(character: Model): Tool?
	for _, weaponName in ipairs(Config.WEAPON_MODEL_NAMES) do
		local weapon = character:FindFirstChild(weaponName)
		if weapon and weapon:IsA("Tool") then
			return weapon
		end
	end
	return nil
end

local function findWeaponHandle(weapon: Tool): BasePart?
	local handle = weapon:FindFirstChild("Handle", true)
	return if handle and handle:IsA("BasePart") then handle else nil
end

local function removeWeaponGrip(weapon: Tool)
	local handle = findWeaponHandle(weapon)
	local grip = if handle then handle:FindFirstChild("WeaponGrip") else nil
	if grip and grip:IsA("RigidConstraint") then
		grip:Destroy()
	end
end

local function disableWeaponPartPhysics(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	if configuredWeaponParts[part] then
		return
	end
	configuredWeaponParts[part] = true
	local function keepCollisionDisabled()
		if part.Parent then
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
		end
	end
	part:GetPropertyChangedSignal("CanCollide"):Connect(keepCollisionDisabled)
	part:GetPropertyChangedSignal("CanTouch"):Connect(keepCollisionDisabled)
	part:GetPropertyChangedSignal("CanQuery"):Connect(keepCollisionDisabled)
	part.Destroying:Connect(function()
		configuredWeaponParts[part] = nil
	end)
end

local function disableWeaponPhysics(weapon: Tool)
	for _, descendant in ipairs(weapon:GetDescendants()) do
		if descendant:IsA("BasePart") then
			disableWeaponPartPhysics(descendant)
		end
	end
end

local function makeHierarchyArchivable(root: Instance)
	root.Archivable = true
	for _, descendant in ipairs(root:GetDescendants()) do
		descendant.Archivable = true
	end
end

local function ensureTrashCanEffect(weapon: Tool)
	if weapon.Name ~= TrashCanConfig.WEAPON_MODEL_NAME
		or weapon:FindFirstChild(TrashCanConfig.EFFECT_OBJECT_NAME, true) then
		return
	end
	local template = ServerStorage:FindFirstChild(TrashCanConfig.WEAPON_MODEL_NAME)
	local templateEffect = if template
		then template:FindFirstChild(TrashCanConfig.EFFECT_OBJECT_NAME, true)
		else nil
	if not templateEffect then
		return
	end
	makeHierarchyArchivable(templateEffect)
	local effect = templateEffect:Clone()
	effect.Parent = weapon
end

local function setTrashCanSourceEffectEnabled(weapon: Tool, enabled: boolean)
	if weapon.Name ~= TrashCanConfig.WEAPON_MODEL_NAME then
		return
	end
	local effect = weapon:FindFirstChild(TrashCanConfig.EFFECT_OBJECT_NAME, true)
	if not effect then
		return
	end
	for _, descendant in ipairs(effect:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = enabled
		end
	end
end

local function configureWeapon(weapon: Tool): boolean
	ensureTrashCanEffect(weapon)
	if configuredWeapons[weapon] then
		return true
	end

	local handle = findWeaponHandle(weapon)
	if not handle then
		warn(`WeaponHandler: {weapon.Name} needs a BasePart named Handle`)
		return false
	end
	local weaponAttachment = handle:FindFirstChild("Attachment")
	if not weaponAttachment or not weaponAttachment:IsA("Attachment") then
		warn(`WeaponHandler: {weapon.Name}.Handle needs an Attachment`)
		return false
	end

	weapon.RequiresHandle = false
	weapon.CanBeDropped = false
	weapon.ManualActivationOnly = true
	disableWeaponPhysics(weapon)
	setTrashCanSourceEffectEnabled(weapon, false)
	configuredWeapons[weapon] = true
	weapon.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			disableWeaponPartPhysics(descendant)
		end
	end)
	weapon.Unequipped:Connect(function()
		removeWeaponGrip(weapon)
	end)
	weapon.Destroying:Connect(function()
		configuredWeapons[weapon] = nil
	end)
	return true
end

local function attachWeapon(character: Model, weapon: Tool)
	if not configureWeapon(weapon) then
		return
	end
	local handAttachment = character:FindFirstChild("RightGripAttachment", true)
	if not handAttachment or not handAttachment:IsA("Attachment") then
		warn("WeaponHandler: RightGripAttachment not found in the character")
		return
	end
	local handle = findWeaponHandle(weapon)
	if not handle then
		return
	end
	disableWeaponPhysics(weapon)
	local weaponAttachment = handle:FindFirstChild("Attachment")
	if not weaponAttachment or not weaponAttachment:IsA("Attachment") then
		return
	end

	removeWeaponGrip(weapon)
	local rigidConstraint = Instance.new("RigidConstraint")
	rigidConstraint.Name = "WeaponGrip"
	rigidConstraint.Attachment0 = handAttachment
	rigidConstraint.Attachment1 = weaponAttachment
	rigidConstraint.Parent = handle
end

local function findOwnedWeapon(player: Player, character: Model, weaponName: string): Tool?
	local equipped = character:FindFirstChild(weaponName)
	if equipped and equipped:IsA("Tool") then
		return equipped
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	local stored = if backpack then backpack:FindFirstChild(weaponName) else nil
	return if stored and stored:IsA("Tool") then stored else nil
end

local function giveWeapons(player: Player, character: Model)
	-- Let the skinned character, Backpack, and hand attachments finish loading.
	task.wait(0.5)
	if player.Character ~= character or not character.Parent then
		return
	end
	local backpackInstance = player:WaitForChild("Backpack", 10)
	if not backpackInstance or not backpackInstance:IsA("Backpack") then
		warn(`WeaponHandler: Backpack not found for {player.Name}`)
		return
	end

	local defaultWeapon: Tool? = nil
	for _, weaponName in ipairs(Config.WEAPON_MODEL_NAMES) do
		local weapon = findOwnedWeapon(player, character, weaponName)
		if not weapon then
			local template = ServerStorage:FindFirstChild(weaponName)
			if not template or not template:IsA("Tool") then
				warn(`WeaponHandler: ServerStorage.{weaponName} must be a Tool`)
				continue
			end
			makeHierarchyArchivable(template)
			weapon = template:Clone()
		end

		if configureWeapon(weapon) then
			if not weapon.Parent then
				weapon.Parent = backpackInstance
			elseif weapon.Parent == character then
				attachWeapon(character, weapon)
			end
			if weaponName == Config.BAT_MODEL_NAME then
				defaultWeapon = weapon
			end
		elseif not weapon.Parent then
			weapon:Destroy()
		end
	end

	if player.Character == character
		and not findEquippedWeapon(character)
		and defaultWeapon
		and defaultWeapon.Parent == backpackInstance then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid:EquipTool(defaultWeapon)
		end
	end
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

local function findCharacter(descendant: Instance): Model?
	local current: Instance? = descendant
	while current and current ~= Workspace do
		if current:IsA("Model") then
			local humanoid = current:FindFirstChildOfClass("Humanoid")
			local rootPart = current:FindFirstChild("HumanoidRootPart")
			if humanoid and rootPart and rootPart:IsA("BasePart") then
				return current
			end
		end
		current = current.Parent
	end
	return nil
end

local function getCharacterRole(character: Model): any
	local player = Players:GetPlayerFromCharacter(character)
	return if player
		then player:GetAttribute(ROUND_ROLE_ATTRIBUTE)
		else character:GetAttribute(ROUND_ROLE_ATTRIBUTE)
end

local function characterIsCaged(character: Model): boolean
	if character:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true then
		return true
	end
	local player = Players:GetPlayerFromCharacter(character)
	return player ~= nil and player:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true
end

local function targetIsInFront(attackerCharacter: Model, targetRoot: BasePart): boolean
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart") then
		return false
	end

	local offset = targetRoot.Position - attackerRoot.Position
	local horizontalOffset = Vector3.new(offset.X, 0, offset.Z)
	if horizontalOffset.Magnitude <= 0.05 then
		return true
	end

	local lookVector = attackerRoot.CFrame.LookVector
	local horizontalForward = Vector3.new(lookVector.X, 0, lookVector.Z)
	if horizontalForward.Magnitude <= 0.05 then
		return false
	end

	return horizontalForward.Unit:Dot(horizontalOffset.Unit) >= Config.MIN_TARGET_FORWARD_DOT
end

local function characterCanBeHit(
	attackerCharacter: Model,
	targetCharacter: Model,
	requireInFront: boolean
): boolean
	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if targetCharacter == attackerCharacter
		or characterIsCaged(targetCharacter)
		or getCharacterRole(targetCharacter) == ROLE_SEEKER
		or not humanoid
		or humanoid.Health <= 0
		or humanoid.PlatformStand
		or not targetRoot
		or not targetRoot:IsA("BasePart")
		or targetRoot.Anchored
		or (requireInFront and not targetIsInFront(attackerCharacter, targetRoot)) then
		return false
	end
	return hasLineOfSight(attackerCharacter, targetCharacter)
end

local function getAttackDirection(attackerRoot: BasePart, requestedDirection: any): Vector3
	if typeof(requestedDirection) == "Vector3"
		and requestedDirection.X == requestedDirection.X
		and requestedDirection.Y == requestedDirection.Y
		and requestedDirection.Z == requestedDirection.Z
		and math.abs(requestedDirection.X) < math.huge
		and math.abs(requestedDirection.Y) < math.huge
		and math.abs(requestedDirection.Z) < math.huge then
		local horizontal = Vector3.new(requestedDirection.X, 0, requestedDirection.Z)
		if horizontal.Magnitude > 0.05 then
			return horizontal.Unit
		end
	end

	local lookVector = attackerRoot.CFrame.LookVector
	local horizontalLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	return if horizontalLook.Magnitude > 0.05 then horizontalLook.Unit else Vector3.zAxis
end

local function putInCage(targetCharacter: Model, captureCenter: Vector3)
	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	local rootPart = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0
		or not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local owner = Players:GetPlayerFromCharacter(targetCharacter) or targetCharacter
	CageService.Attach(owner, targetCharacter, humanoid, rootPart, captureCenter)
end

local function findHandleContactTarget(
	attackerCharacter: Model,
	handle: BasePart
): Model?
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart") then
		return nil
	end

	local parameters = OverlapParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { attackerCharacter }
	parameters.RespectCanCollide = false

	local contactSize = handle.Size + Vector3.one * (Config.HANDLE_CONTACT_PADDING * 2)
	local parts = Workspace:GetPartBoundsInBox(handle.CFrame, contactSize, parameters)
	local checkedCharacters: {[Model]: boolean} = {}
	local closestCharacter: Model? = nil
	local closestDistance = math.huge

	for _, part in ipairs(parts) do
		local character = findCharacter(part)
		if not character or checkedCharacters[character] then
			continue
		end
		checkedCharacters[character] = true

		local targetRoot = character:FindFirstChild("HumanoidRootPart")
		if not characterCanBeHit(attackerCharacter, character, true)
			or not targetRoot
			or not targetRoot:IsA("BasePart") then
			continue
		end

		local distance = (targetRoot.Position - handle.Position).Magnitude
		if distance < closestDistance then
			closestDistance = distance
			closestCharacter = character
		end
	end

	return closestCharacter
end

local function findCageAreaTarget(
	attackerCharacter: Model,
	direction: Vector3,
	requestedTarget: any
): (Model?, Vector3?)
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart") then
		return nil, nil
	end

	local captureCenter = attackerRoot.Position
		+ direction * CageConfig.CAPTURE_PLACEMENT_DISTANCE
	local parameters = OverlapParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { attackerCharacter }
	parameters.RespectCanCollide = false
	local areaDiameter = CageConfig.AREA_MAX_DISTANCE * 2
	local parts = Workspace:GetPartBoundsInBox(
		CFrame.new(attackerRoot.Position),
		Vector3.new(areaDiameter, CageConfig.AREA_HEIGHT, areaDiameter),
		parameters
	)
	local checkedCharacters: {[Model]: boolean} = {}
	local closestCharacter: Model? = nil
	local closestDistance = math.huge

	local function considerCharacter(character: Model?, useTolerance: boolean): boolean
		if not character or checkedCharacters[character] then
			return false
		end
		checkedCharacters[character] = true

		local targetRoot = character:FindFirstChild("HumanoidRootPart")
		if not characterCanBeHit(attackerCharacter, character, false)
			or not targetRoot
			or not targetRoot:IsA("BasePart") then
			return false
		end

		local offset = targetRoot.Position - attackerRoot.Position
		local horizontalDistance = Vector3.new(offset.X, 0, offset.Z).Magnitude
		local facingDot = if horizontalDistance > 0.05
			then direction:Dot(Vector3.new(offset.X, 0, offset.Z).Unit)
			else 1
		local distanceTolerance = if useTolerance then CageConfig.SERVER_DISTANCE_TOLERANCE else 0
		local angleTolerance = if useTolerance then CageConfig.SERVER_ANGLE_TOLERANCE_DEGREES else 0
		local verticalTolerance = if useTolerance then CageConfig.SERVER_VERTICAL_TOLERANCE else 0
		local minimumFacingDot = math.cos(math.rad(
			CageConfig.AREA_FOV_DEGREES * 0.5 + angleTolerance
		))
		local distanceToCaptureCenter = Vector2.new(
			targetRoot.Position.X - captureCenter.X,
			targetRoot.Position.Z - captureCenter.Z
		).Magnitude
		if horizontalDistance >= math.max(0, CageConfig.AREA_MIN_DISTANCE - distanceTolerance)
			and horizontalDistance <= CageConfig.AREA_MAX_DISTANCE + distanceTolerance
			and facingDot >= minimumFacingDot
			and math.abs(offset.Y) <= CageConfig.AREA_HEIGHT * 0.5 + verticalTolerance
			and distanceToCaptureCenter < closestDistance then
			closestDistance = distanceToCaptureCenter
			closestCharacter = character
			return true
		end
		return false
	end

	if typeof(requestedTarget) == "Instance"
		and requestedTarget:IsA("Model")
		and considerCharacter(requestedTarget, true) then
		return requestedTarget, captureCenter
	end

	-- Player characters are checked directly so custom CanQuery settings cannot
	-- make a visibly contained target disappear from the cage area.
	for _, player in ipairs(Players:GetPlayers()) do
		considerCharacter(player.Character, false)
	end
	local npcFolder = Workspace:FindFirstChild(ROUND_NPC_FOLDER_NAME)
	if npcFolder then
		for _, npc in ipairs(npcFolder:GetChildren()) do
			if npc:IsA("Model") then
				considerCharacter(npc, false)
			end
		end
	end
	for _, part in ipairs(parts) do
		considerCharacter(findCharacter(part), false)
	end

	return closestCharacter, captureCenter
end

local function setServerNetworkOwnership(rootPart: BasePart)
	pcall(function()
		local canSet = rootPart:CanSetNetworkOwnership()
		if canSet then
			rootPart:SetNetworkOwner(nil)
		end
	end)
end

local function restoreNetworkOwnership(rootPart: BasePart, character: Model)
	pcall(function()
		local canSet = rootPart:CanSetNetworkOwnership()
		if canSet then
			if Players:GetPlayerFromCharacter(character) then
				rootPart:SetNetworkOwnershipAuto()
			else
				rootPart:SetNetworkOwner(nil)
			end
		end
	end)
end

local function knockDown(
	targetCharacter: Model,
	attackerCharacter: Model,
	durationSeconds: number,
	allowSeeker: boolean,
	knockbackSpeed: number,
	knockbackUpwardSpeed: number,
	knockbackTipSpeed: number
)
	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0
		or (not allowSeeker and getCharacterRole(targetCharacter) == ROLE_SEEKER)
		or not targetRoot or not targetRoot:IsA("BasePart")
		or targetRoot.Anchored
		or not attackerRoot or not attackerRoot:IsA("BasePart") then
		return
	end

	local record = knockdownRecords[humanoid]
	if not record then
		local turnOrientation = targetCharacter:FindFirstChild("NpcSmoothTurnOrientation", true)
		local npcTurnOrientation = if turnOrientation and turnOrientation:IsA("AlignOrientation")
			then turnOrientation
			else nil
		record = {
			token = 0,
			platformStand = humanoid.PlatformStand,
			autoRotate = humanoid.AutoRotate,
			walkSpeed = humanoid.WalkSpeed,
			walkSpeedConnection = nil,
			animationPlayedConnection = nil,
			npcTurnOrientation = npcTurnOrientation,
			npcTurnOrientationEnabled = if npcTurnOrientation
				then npcTurnOrientation.Enabled
				else nil,
		}
		knockdownRecords[humanoid] = record
		record.walkSpeedConnection = humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
			if knockdownRecords[humanoid] == record and humanoid.WalkSpeed ~= 0 then
				record.walkSpeed = humanoid.WalkSpeed
				humanoid.WalkSpeed = 0
			end
		end)
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			record.animationPlayedConnection = animator.AnimationPlayed:Connect(function(track)
				if knockdownRecords[humanoid] == record then
					track:Stop(0)
				end
			end)
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				track:Stop(0.05)
			end
		end
	end
	record.token += 1
	local token = record.token

	local horizontalDirection = Vector3.new(
		targetRoot.Position.X - attackerRoot.Position.X,
		0,
		targetRoot.Position.Z - attackerRoot.Position.Z
	)
	if horizontalDirection.Magnitude <= 0.05 then
		horizontalDirection = Vector3.new(
			attackerRoot.CFrame.LookVector.X,
			0,
			attackerRoot.CFrame.LookVector.Z
		)
	end
	if horizontalDirection.Magnitude <= 0.05 then
		horizontalDirection = Vector3.zAxis
	else
		horizontalDirection = horizontalDirection.Unit
	end

	targetCharacter:SetAttribute(Config.KNOCKDOWN_ATTRIBUTE, true)
	if record.npcTurnOrientation then
		record.npcTurnOrientation.Enabled = false
	end
	humanoid:Move(Vector3.zero, false)
	humanoid.WalkSpeed = 0
	humanoid.Jump = false
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	setServerNetworkOwnership(targetRoot)
	local knockbackVelocity = horizontalDirection * knockbackSpeed
		+ Vector3.yAxis * knockbackUpwardSpeed
	targetRoot.AssemblyLinearVelocity = knockbackVelocity
	targetRoot.AssemblyAngularVelocity = horizontalDirection:Cross(Vector3.yAxis)
		* knockbackTipSpeed

	task.delay(durationSeconds, function()
		if knockdownRecords[humanoid] ~= record or record.token ~= token then
			return
		end
		knockdownRecords[humanoid] = nil
		if record.walkSpeedConnection then
			record.walkSpeedConnection:Disconnect()
			record.walkSpeedConnection = nil
		end
		if record.animationPlayedConnection then
			record.animationPlayedConnection:Disconnect()
			record.animationPlayedConnection = nil
		end
		if not targetCharacter.Parent or not humanoid.Parent then
			return
		end
		targetCharacter:SetAttribute(Config.KNOCKDOWN_ATTRIBUTE, nil)

		local turnOrientation = record.npcTurnOrientation
		if turnOrientation and turnOrientation.Parent then
			turnOrientation.Enabled = record.npcTurnOrientationEnabled == true
		end
		humanoid.PlatformStand = record.platformStand
		humanoid.AutoRotate = record.autoRotate
		humanoid.WalkSpeed = record.walkSpeed
		if humanoid.Health > 0 and not record.platformStand then
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		if targetRoot.Parent then
			targetRoot.AssemblyAngularVelocity = Vector3.zero
			restoreNetworkOwnership(targetRoot, targetCharacter)
		end
	end)
end

local function findNamedAnimation(container: Instance, animationName: string): Animation?
	local lowerName = string.lower(animationName)
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("Animation")
			and descendant.AnimationId ~= ""
			and string.lower(descendant.Name) == lowerName then
			return descendant
		end
	end
	return nil
end

local function findNamedKeyframeSequence(
	container: Instance,
	animationName: string
): KeyframeSequence?
	local lowerName = string.lower(animationName)
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("KeyframeSequence") and string.lower(descendant.Name) == lowerName then
			return descendant
		elseif descendant:IsA("ObjectValue")
			and string.lower(descendant.Name) == lowerName
			and descendant.Value
			and descendant.Value:IsA("KeyframeSequence") then
			return descendant.Value
		end
	end
	return nil
end

local function resolveTrashCanAnimation(weapon: Tool): Animation?
	local animation = findNamedAnimation(weapon, TrashCanConfig.ATTACK_ANIMATION_NAME)
		or findNamedAnimation(ServerStorage, TrashCanConfig.ATTACK_ANIMATION_NAME)
	if animation then
		return animation
	end
	if studioTrashAnimation then
		return studioTrashAnimation
	end

	local sequence = findNamedKeyframeSequence(weapon, TrashCanConfig.ATTACK_ANIMATION_NAME)
		or findNamedKeyframeSequence(ServerStorage, TrashCanConfig.ATTACK_ANIMATION_NAME)
	if not sequence or not RunService:IsStudio() then
		return nil
	end
	local succeeded, temporaryId = pcall(function()
		return KeyframeSequenceProvider:RegisterKeyframeSequence(sequence)
	end)
	if not succeeded then
		return nil
	end
	local temporaryAnimation = Instance.new("Animation")
	temporaryAnimation.Name = TrashCanConfig.ATTACK_ANIMATION_NAME
	temporaryAnimation.AnimationId = temporaryId
	studioTrashAnimation = temporaryAnimation
	return temporaryAnimation
end

local function playTrashCanAnimation(character: Model, weapon: Tool): AnimationTrack?
	local animation = resolveTrashCanAnimation(weapon)
	if not animation then
		if not warnedMissingTrashAnimation then
			warnedMissingTrashAnimation = true
			local suffix = if findNamedKeyframeSequence(weapon, TrashCanConfig.ATTACK_ANIMATION_NAME)
				or findNamedKeyframeSequence(ServerStorage, TrashCanConfig.ATTACK_ANIMATION_NAME)
				then " (the Animation Editor KeyframeSequence must first be published as an Animation)"
				else ""
			warn(
				`WeaponHandler: Animation '{TrashCanConfig.ATTACK_ANIMATION_NAME}' not found{suffix}`
			)
		end
		return
	end
	warnedMissingTrashAnimation = false

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local succeeded, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not succeeded or not track then
		warn(`WeaponHandler: failed to load animation '{animation:GetFullName()}'`)
		return
	end
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	track:Play(0.05, 1, 1)
	return track
end

local function releaseTrashAction(humanoid: Humanoid, record: TrashActionRecord)
	if trashActionRecords[humanoid] ~= record then
		return
	end
	trashActionRecords[humanoid] = nil
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	table.clear(record.connections)
	if record.track.IsPlaying then
		record.track:Stop(0.05)
	end
	record.track:Destroy()
	if not humanoid.Parent or not record.character.Parent then
		return
	end
	humanoid.WalkSpeed = record.walkSpeed
	humanoid.AutoRotate = record.autoRotate
	humanoid.JumpHeight = record.jumpHeight
	humanoid.JumpPower = record.jumpPower
	humanoid.Jump = false
end

local function lockTrashAction(character: Model, track: AnimationTrack)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		track:Destroy()
		return
	end
	local existing = trashActionRecords[humanoid]
	if existing then
		releaseTrashAction(humanoid, existing)
	end
	local record: TrashActionRecord = {
		character = character,
		track = track,
		walkSpeed = humanoid.WalkSpeed,
		autoRotate = humanoid.AutoRotate,
		jumpHeight = humanoid.JumpHeight,
		jumpPower = humanoid.JumpPower,
		connections = {},
	}
	trashActionRecords[humanoid] = record
	table.insert(record.connections, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if trashActionRecords[humanoid] == record and humanoid.WalkSpeed ~= 0 then
			record.walkSpeed = humanoid.WalkSpeed
			humanoid.WalkSpeed = 0
		end
	end))
	table.insert(record.connections, humanoid:GetPropertyChangedSignal("AutoRotate"):Connect(function()
		if trashActionRecords[humanoid] == record and humanoid.AutoRotate then
			record.autoRotate = true
			humanoid.AutoRotate = false
		end
	end))
	table.insert(record.connections, humanoid:GetPropertyChangedSignal("JumpHeight"):Connect(function()
		if trashActionRecords[humanoid] == record and humanoid.JumpHeight ~= 0 then
			record.jumpHeight = humanoid.JumpHeight
			humanoid.JumpHeight = 0
		end
	end))
	table.insert(record.connections, humanoid:GetPropertyChangedSignal("JumpPower"):Connect(function()
		if trashActionRecords[humanoid] == record and humanoid.JumpPower ~= 0 then
			record.jumpPower = humanoid.JumpPower
			humanoid.JumpPower = 0
		end
	end))
	table.insert(record.connections, track.Ended:Connect(function()
		releaseTrashAction(humanoid, record)
	end))
	table.insert(record.connections, character.Destroying:Connect(function()
		releaseTrashAction(humanoid, record)
	end))
	humanoid:Move(Vector3.zero, false)
	humanoid.WalkSpeed = 0
	humanoid.AutoRotate = false
	humanoid.JumpHeight = 0
	humanoid.JumpPower = 0
	humanoid.Jump = false
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	task.delay(TrashCanConfig.ACTION_LOCK_TIMEOUT_SECONDS, function()
		releaseTrashAction(humanoid, record)
	end)
end

local function emitTrashCanEffect(
	weapon: Tool,
	direction: Vector3,
	attackerRoot: BasePart
)
	local source = weapon:FindFirstChild(TrashCanConfig.EFFECT_OBJECT_NAME, true)
	if not source then
		local template = ServerStorage:FindFirstChild(TrashCanConfig.WEAPON_MODEL_NAME)
		source = if template
			then template:FindFirstChild(TrashCanConfig.EFFECT_OBJECT_NAME, true)
			else nil
	end
	local handle = findWeaponHandle(weapon)
	if not handle then
		if not warnedMissingTrashEffect then
			warnedMissingTrashEffect = true
			warn(`WeaponHandler: {weapon.Name} needs a BasePart named Handle`)
		end
		return
	end
	if not source then
		if not warnedMissingTrashEffect then
			warnedMissingTrashEffect = true
			warn(
				`WeaponHandler: {weapon.Name} is missing {TrashCanConfig.EFFECT_OBJECT_NAME}`
			)
		end
		return
	end
	makeHierarchyArchivable(source)

	local effect: BasePart
	if source:IsA("BasePart") then
		effect = source:Clone()
	else
		-- Effect may be a Model/Folder containing only ParticleEmitters. Such a
		-- container has no world position, so give the particles a flying carrier.
		local carrier = Instance.new("Part")
		carrier.Name = "TrashCanEffect"
		carrier.Size = Vector3.one * 0.1
		carrier.Transparency = 1
		for _, descendant in ipairs(source:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") then
				local emitter = descendant:Clone()
				emitter.Parent = carrier
			end
		end
		effect = carrier
	end

	for _, descendant in ipairs(effect:GetDescendants()) do
		if descendant:IsA("Constraint") or descendant:IsA("JointInstance") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
		end
	end
	effect.Anchored = true
	effect.CanCollide = false
	effect.CanTouch = false
	effect.CanQuery = false
	effect.Massless = true
	local launchPosition = Vector3.new(
		attackerRoot.Position.X,
		attackerRoot.Position.Y + TrashCanConfig.EFFECT_START_HEIGHT_OFFSET_STUDS,
		attackerRoot.Position.Z
	) + direction * TrashCanConfig.EFFECT_START_FORWARD_OFFSET_STUDS
	effect.CFrame = CFrame.lookAt(launchPosition, launchPosition + direction)
	effect.Parent = Workspace

	local maximumParticleLifetime = 0
	local emitterCount = 0
	for _, descendant in ipairs(effect:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			emitterCount += 1
			descendant.Enabled = true
			maximumParticleLifetime = math.max(maximumParticleLifetime, descendant.Lifetime.Max)
		end
	end
	if emitterCount == 0 then
		effect:Destroy()
		if not warnedMissingTrashEffect then
			warnedMissingTrashEffect = true
			warn(
				`WeaponHandler: {weapon.Name}.{TrashCanConfig.EFFECT_OBJECT_NAME} needs a ParticleEmitter`
			)
		end
		return
	end
	warnedMissingTrashEffect = false

	local tween = TweenService:Create(
		effect,
		TweenInfo.new(TrashCanConfig.EFFECT_TRAVEL_SECONDS, Enum.EasingStyle.Linear),
		{
			CFrame = effect.CFrame + direction * math.max(
				0,
				TrashCanConfig.RANGE_STUDS - TrashCanConfig.EFFECT_START_FORWARD_OFFSET_STUDS
			),
		}
	)
	tween.Completed:Once(function()
		if not effect.Parent then
			return
		end
		for _, descendant in ipairs(effect:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
			end
		end
		effect.Transparency = 1
		task.delay(maximumParticleLifetime + TrashCanConfig.EFFECT_CLEANUP_PADDING_SECONDS, function()
			effect:Destroy()
		end)
	end)
	tween:Play()
end

local function hasTrashCanLineOfSight(
	attackerCharacter: Model,
	targetCharacter: Model
): boolean
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart")
		or not targetRoot or not targetRoot:IsA("BasePart") then
		return false
	end
	local excluded: {Instance} = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(excluded, player.Character)
		end
	end
	local npcFolder = Workspace:FindFirstChild(ROUND_NPC_FOLDER_NAME)
	if npcFolder then
		table.insert(excluded, npcFolder)
	end
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = excluded
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true
	local rayDirection = targetRoot.Position - attackerRoot.Position
	if rayDirection.Magnitude <= 0.05 then
		return true
	end
	return Workspace:Raycast(
		attackerRoot.Position,
		rayDirection,
		parameters
	) == nil
end

local function characterCanBeTrashKnocked(
	attackerCharacter: Model,
	targetCharacter: Model
): boolean
	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	local rootPart = targetCharacter:FindFirstChild("HumanoidRootPart")
	if targetCharacter == attackerCharacter
		or characterIsCaged(targetCharacter)
		or not humanoid
		or humanoid.Health <= 0
		or (humanoid.PlatformStand and knockdownRecords[humanoid] == nil)
		or not rootPart
		or not rootPart:IsA("BasePart")
		or rootPart.Anchored then
		return false
	end
	return hasTrashCanLineOfSight(attackerCharacter, targetCharacter)
end

local function characterIsInTrashArea(
	attackerRoot: BasePart,
	targetRoot: BasePart,
	direction: Vector3
): boolean
	local offset = targetRoot.Position - attackerRoot.Position
	if math.abs(offset.Y) > TrashCanConfig.MAX_VERTICAL_DIFFERENCE then
		return false
	end
	local horizontalOffset = Vector3.new(offset.X, 0, offset.Z)
	local distance = horizontalOffset.Magnitude
	if distance > TrashCanConfig.RANGE_STUDS then
		return false
	end
	if distance <= 0.05 or TrashCanConfig.ANGLE_DEGREES >= 360 then
		return true
	end
	local halfAngle = math.rad(math.clamp(TrashCanConfig.ANGLE_DEGREES, 0, 360) * 0.5)
	return direction:Dot(horizontalOffset.Unit) >= math.cos(halfAngle)
end

local function fireTrashCan(
	player: Player,
	character: Model,
	weapon: Tool,
	attackerRoot: BasePart,
	requestedDirection: any
)
	local direction = getAttackDirection(attackerRoot, requestedDirection)
	local track = playTrashCanAnimation(character, weapon)
	if track then
		lockTrashAction(character, track)
	end
	emitTrashCanEffect(weapon, direction, attackerRoot)

	local checkedCharacters: {[Model]: boolean} = {}
	local function knockCharacter(targetCharacter: Model?)
		if not targetCharacter
			or targetCharacter == character
			or checkedCharacters[targetCharacter] then
			return
		end
		checkedCharacters[targetCharacter] = true
		local targetRoot = if targetCharacter
			then targetCharacter:FindFirstChild("HumanoidRootPart")
			else nil
		if targetRoot
			and targetRoot:IsA("BasePart")
			and characterCanBeTrashKnocked(character, targetCharacter)
			and characterIsInTrashArea(attackerRoot, targetRoot, direction) then
			knockDown(
				targetCharacter,
				character,
				TrashCanConfig.KNOCKDOWN_DURATION_SECONDS,
				true,
				TrashCanConfig.KNOCKBACK_SPEED,
				TrashCanConfig.KNOCKBACK_UPWARD_SPEED,
				TrashCanConfig.KNOCKBACK_TIP_SPEED
			)
		end
	end

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= player then
			knockCharacter(targetPlayer.Character)
		end
	end
	local npcFolder = Workspace:FindFirstChild(ROUND_NPC_FOLDER_NAME)
	if npcFolder then
		for _, npc in ipairs(npcFolder:GetChildren()) do
			if npc:IsA("Model") then
				knockCharacter(npc)
			end
		end
	end
end

local function handleAttack(player: Player, requestedDirection: any, requestedTarget: any)
	local now = os.clock()
	local lastAttackAt = lastAttackByPlayer[player]
	if lastAttackAt and now - lastAttackAt < Config.ATTACK_COOLDOWN_SECONDS then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local attackerRoot = character and character:FindFirstChild("HumanoidRootPart")
	local equippedWeapon = character and findEquippedWeapon(character)
	local handleInstance = if equippedWeapon then findWeaponHandle(equippedWeapon) else nil
	if not character
		or not humanoid
		or humanoid.Health <= 0
		or humanoid.PlatformStand
		or trashActionRecords[humanoid] ~= nil
		or characterIsCaged(character)
		or not attackerRoot
		or not attackerRoot:IsA("BasePart")
		or not equippedWeapon
		or not handleInstance
		or not handleInstance:IsA("BasePart") then
		return
	end
	lastAttackByPlayer[player] = now
	if equippedWeapon.Name == TrashCanConfig.WEAPON_MODEL_NAME then
		fireTrashCan(player, character, equippedWeapon, attackerRoot, requestedDirection)
		return
	end
	local cageDirection = if equippedWeapon.Name == CageConfig.WEAPON_MODEL_NAME
		then getAttackDirection(attackerRoot, requestedDirection)
		else nil
	if cageDirection then
		local targetCharacter, captureCenter = findCageAreaTarget(
			character,
			cageDirection,
			requestedTarget
		)
		if targetCharacter and captureCenter then
			putInCage(targetCharacter, captureCenter)
		end
		return
	end

	task.delay(Config.HIT_DELAY_SECONDS, function()
		local hitWindowEndsAt = os.clock() + Config.HIT_WINDOW_DURATION_SECONDS
		repeat
			if player.Character ~= character
				or not character.Parent
				or humanoid.Health <= 0
				or characterIsCaged(character)
				or findEquippedWeapon(character) ~= equippedWeapon
				or not handleInstance:IsDescendantOf(equippedWeapon) then
				return
			end

			local targetCharacter = findHandleContactTarget(character, handleInstance)
			if targetCharacter then
				knockDown(
					targetCharacter,
					character,
					Config.KNOCKDOWN_DURATION_SECONDS,
					false,
					Config.KNOCKBACK_SPEED,
					Config.KNOCKBACK_UPWARD_SPEED,
					Config.KNOCKBACK_TIP_SPEED
				)
				return
			end
			RunService.Heartbeat:Wait()
		until os.clock() >= hitWindowEndsAt
	end)
end

local function setupCharacterWeapons(player: Player, character: Model)
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and isWeaponName(child.Name) then
			task.defer(attachWeapon, character, child)
		end
	end)
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and isWeaponName(child.Name) then
			task.defer(attachWeapon, character, child)
		end
	end
	task.spawn(giveWeapons, player, character)
end

local function setupPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		setupCharacterWeapons(player, character)
	end)
	if player.Character then
		setupCharacterWeapons(player, player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end
Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(function(player)
	lastAttackByPlayer[player] = nil
end)
attackRemote.OnServerEvent:Connect(handleAttack)
