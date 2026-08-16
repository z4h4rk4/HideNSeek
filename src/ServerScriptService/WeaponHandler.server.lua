--!strict

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local StarterPlayer = game:GetService("StarterPlayer")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("BatAttackConfig"))
local CageConfig = require(ReplicatedStorage:WaitForChild("CageConfig"))
local CooldownPassConfig = require(ReplicatedStorage:WaitForChild("CooldownPassConfig"))
local FistConfig = require(ReplicatedStorage:WaitForChild("FistConfig"))
local SearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local TrashCanConfig = require(ReplicatedStorage:WaitForChild("TrashCanConfig"))
local WeaponShopConfig = require(ReplicatedStorage:WaitForChild("WeaponShopConfig"))
local CageService = require(script.Parent:WaitForChild("Round"):WaitForChild("CageService"))
local RoundResultService = require(
	script.Parent:WaitForChild("Round"):WaitForChild("RoundResultService")
)

local ROUND_ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = "Hider"
local ROLE_SEEKER = "Seeker"
local ROUND_NPC_FOLDER_NAME = "RoundNPCs"
local MANAGED_ROUND_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROUND_STATE_NAME = "RoundState"
local PHASE_ROUND = "Round"

type KnockdownRecord = {
	token: number,
	platformStand: boolean,
	autoRotate: boolean,
	walkSpeed: number,
	jumpHeight: number,
	jumpPower: number,
	physical: boolean,
	collisionStates: {[BasePart]: boolean},
	collider: Part?,
	walkSpeedConnection: RBXScriptConnection?,
	animationPlayedConnection: RBXScriptConnection?,
	reactionTrack: AnimationTrack?,
	reactionStartRootPosition: Vector3?,
	reactionTravelDirection: Vector3?,
	npcTurnOrientation: AlignOrientation?,
	npcTurnOrientationEnabled: boolean?,
}

type FistHitRecord = {
	character: Model,
	count: number,
	revision: number,
	destroyingConnection: RBXScriptConnection?,
}

local nextAttackAtByCharacter: {[Model]: {[string]: number}} = {}
local knockdownRecords: {[Humanoid]: KnockdownRecord} = {}
local fistReactionTracks: {[Humanoid]: AnimationTrack} = {}
local fistHitRecords: {[Humanoid]: FistHitRecord} = {}
local fistHitDisplayCharacters: {[Model]: boolean} = {}
local configuredWeapons: {[Tool]: boolean} = {}
local configuredWeaponParts: {[BasePart]: boolean} = {}
local warnedMissingTrashAnimation = false
local warnedMissingTrashEffect = false
local warnedMissingBatHitEffect = false
local warnedSoundTemplates: {[string]: boolean} = {}
local warnedMissingFistReaction = false
local studioTrashAnimation: Animation? = nil
local studioFistReactionAnimation: Animation? = nil

local SOUND_FALLBACK_LIFETIME_SECONDS = 10
local cooldownRandom = Random.new()
local fistSoundRandom = Random.new()
local fistHitGeneration = 0

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

local function ownedAttributeName(weaponName: string): string
	return WeaponShopConfig.OWNED_ATTRIBUTE_PREFIX .. weaponName
end

local function playerCanUseWeapon(player: Player, weaponName: string): boolean
	local item = WeaponShopConfig.BY_WEAPON[weaponName]
	return item ~= nil
		and (item.FREE or player:GetAttribute(ownedAttributeName(weaponName)) == true)
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

local function playSoundTemplate(templateName: string, parent: Instance): boolean
	local template = SoundService:FindFirstChild(templateName)
	if not template or not template:IsA("Sound") then
		if not warnedSoundTemplates[templateName] then
			warnedSoundTemplates[templateName] = true
			warn(`WeaponHandler: SoundService.{templateName} must be a Sound`)
		end
		return false
	end
	if template.SoundId == "" then
		if not warnedSoundTemplates[templateName] then
			warnedSoundTemplates[templateName] = true
			warn(`WeaponHandler: SoundService.{templateName}.SoundId is empty`)
		end
		return false
	end
	warnedSoundTemplates[templateName] = nil
	template.Archivable = true
	local sound = template:Clone()
	sound.Name = `{templateName}Playback`
	sound.Looped = false
	sound.PlayOnRemove = false
	sound.Parent = parent
	sound.Ended:Once(function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
	Debris:AddItem(sound, SOUND_FALLBACK_LIFETIME_SECONDS)
	sound:Play()
	return true
end

local function setFistHitDisplay(targetCharacter: Model, count: number)
	local existing = targetCharacter:FindFirstChild(FistConfig.HIT_COUNTER_GUI_NAME)
	if count <= 0 then
		fistHitDisplayCharacters[targetCharacter] = nil
		targetCharacter:SetAttribute(FistConfig.HIT_COUNT_ATTRIBUTE, nil)
		if existing and existing:IsA("BillboardGui") then
			existing:Destroy()
		end
		return
	end

	fistHitDisplayCharacters[targetCharacter] = true
	targetCharacter:SetAttribute(FistConfig.HIT_COUNT_ATTRIBUTE, count)
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot or not targetRoot:IsA("BasePart") then
		return
	end

	local billboard: BillboardGui
	local label: TextLabel?
	if existing and existing:IsA("BillboardGui") then
		billboard = existing
		local currentLabel = billboard:FindFirstChild("Count")
		label = if currentLabel and currentLabel:IsA("TextLabel")
			then currentLabel
			else nil
	else
		billboard = Instance.new("BillboardGui")
		billboard.Name = FistConfig.HIT_COUNTER_GUI_NAME
		billboard.AlwaysOnTop = false
		billboard.LightInfluence = 0
		billboard.MaxDistance = FistConfig.HIT_COUNTER_MAX_DISTANCE_STUDS
		billboard.Size = UDim2.fromOffset(112, 32)
		billboard.StudsOffsetWorldSpace = Vector3.yAxis
			* FistConfig.HIT_COUNTER_HEIGHT_OFFSET_STUDS
		label = nil
	end

	billboard.Adornee = targetRoot
	if not label then
		label = Instance.new("TextLabel")
		label.Name = "Count"
		label.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
		label.BackgroundTransparency = 0.2
		label.BorderSizePixel = 0
		label.Font = Enum.Font.GothamBold
		label.Size = UDim2.fromScale(1, 1)
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextScaled = true
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.TextStrokeTransparency = 0.55

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = label

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 6)
		padding.PaddingRight = UDim.new(0, 6)
		padding.PaddingTop = UDim.new(0, 3)
		padding.PaddingBottom = UDim.new(0, 3)
		padding.Parent = label

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 108, 76)
		stroke.Thickness = 2
		stroke.Parent = label
		label.Parent = billboard
	end
	label.Text = `Hits: {count}/{FistConfig.HITS_TO_KNOCKDOWN}`
	if not billboard.Parent then
		billboard.Parent = targetCharacter
	end
end

local function detachFistHitRecord(
	humanoid: Humanoid,
	record: FistHitRecord,
	clearDisplay: boolean
): boolean
	if fistHitRecords[humanoid] ~= record then
		return false
	end
	fistHitRecords[humanoid] = nil
	if record.destroyingConnection then
		record.destroyingConnection:Disconnect()
		record.destroyingConnection = nil
	end
	if clearDisplay then
		setFistHitDisplay(record.character, 0)
	end
	return true
end

local function clearFistHitRecord(humanoid: Humanoid)
	local record = fistHitRecords[humanoid]
	if record then
		detachFistHitRecord(humanoid, record, true)
	end
end

local function resetFistHitRecords()
	for humanoid in pairs(fistHitRecords) do
		clearFistHitRecord(humanoid)
	end
	for character in pairs(fistHitDisplayCharacters) do
		setFistHitDisplay(character, 0)
	end
end

local function playRandomFistHitSound(targetCharacter: Model)
	local soundNames = FistConfig.HIT_SOUND_TEMPLATE_NAMES
	if #soundNames == 0 then
		return
	end
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if targetRoot and targetRoot:IsA("BasePart") then
		local firstIndex = fistSoundRandom:NextInteger(1, #soundNames)
		for offset = 0, #soundNames - 1 do
			local index = ((firstIndex + offset - 1) % #soundNames) + 1
			if playSoundTemplate(soundNames[index], targetRoot) then
				return
			end
		end
	end
end

local function scheduleFistHitDecay(humanoid: Humanoid, record: FistHitRecord)
	local expectedRevision = record.revision
	task.delay(FistConfig.HIT_DECAY_DELAY_SECONDS, function()
		while fistHitRecords[humanoid] == record
			and record.revision == expectedRevision
			and record.count > 0 do
			record.count -= 1
			if record.count <= 0 then
				detachFistHitRecord(humanoid, record, true)
				return
			end
			setFistHitDisplay(record.character, record.count)
			task.wait(FistConfig.HIT_DECAY_INTERVAL_SECONDS)
		end
	end)
end

local function getPunchEffectSize(decal: Decal): Vector2
	local sourcePart: BasePart? = nil
	local current = decal.Parent
	while current and current ~= ServerStorage do
		if current:IsA("BasePart") then
			sourcePart = current
			break
		end
		current = current.Parent
	end

	local fallback = Config.HIT_EFFECT_FALLBACK_SIZE_STUDS
	local width = fallback
	local height = fallback
	if sourcePart then
		local size = sourcePart.Size
		if decal.Face == Enum.NormalId.Top or decal.Face == Enum.NormalId.Bottom then
			width = size.X
			height = size.Z
		elseif decal.Face == Enum.NormalId.Front or decal.Face == Enum.NormalId.Back then
			width = size.X
			height = size.Y
		else
			width = size.Z
			height = size.Y
		end
	end
	return Vector2.new(
		math.clamp(width, Config.HIT_EFFECT_MIN_SIZE_STUDS, Config.HIT_EFFECT_MAX_SIZE_STUDS),
		math.clamp(height, Config.HIT_EFFECT_MIN_SIZE_STUDS, Config.HIT_EFFECT_MAX_SIZE_STUDS)
	)
end

local function showBatHitEffect(targetRoot: BasePart)
	local template = ServerStorage:FindFirstChild(Config.HIT_EFFECT_TEMPLATE_NAME)
	local decal: Decal? = nil
	if template then
		decal = if template:IsA("Decal")
			then template
			else template:FindFirstChildWhichIsA("Decal", true)
	end
	if not decal or decal.Texture == "" then
		if not warnedMissingBatHitEffect then
			warnedMissingBatHitEffect = true
			warn(
				`WeaponHandler: ServerStorage.{Config.HIT_EFFECT_TEMPLATE_NAME} `
					.. "must contain a Decal with a Texture"
			)
		end
		return
	end
	warnedMissingBatHitEffect = false

	local effectSize = getPunchEffectSize(decal)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BatPunchHitEffect"
	billboard.Adornee = targetRoot
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = Config.HIT_EFFECT_MAX_DISTANCE_STUDS
	billboard.Size = UDim2.fromScale(effectSize.X, effectSize.Y)
	billboard.StudsOffsetWorldSpace = Vector3.yAxis * Config.HIT_EFFECT_HEIGHT_OFFSET_STUDS
	billboard:SetAttribute(SearchConfig.PRESERVE_VISUAL_ATTRIBUTE, true)

	local image = Instance.new("ImageLabel")
	image.Name = "Punch"
	image.BackgroundTransparency = 1
	image.BorderSizePixel = 0
	image.Size = UDim2.fromScale(1, 1)
	image.Image = decal.Texture
	image.ImageColor3 = decal.Color3
	image.ImageTransparency = decal.Transparency
	image.ScaleType = Enum.ScaleType.Fit
	image.Parent = billboard
	billboard.Parent = targetRoot

	local fadeDuration = math.min(
		Config.HIT_EFFECT_FADE_SECONDS,
		Config.HIT_EFFECT_LIFETIME_SECONDS
	)
	task.delay(Config.HIT_EFFECT_LIFETIME_SECONDS - fadeDuration, function()
		if image.Parent then
			TweenService:Create(
				image,
				TweenInfo.new(fadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ ImageTransparency = 1 }
			):Play()
		end
	end)
	Debris:AddItem(billboard, Config.HIT_EFFECT_LIFETIME_SECONDS)
end

local function emitBatHitFeedback(targetCharacter: Model)
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot or not targetRoot:IsA("BasePart") then
		return
	end
	showBatHitEffect(targetRoot)
	playSoundTemplate(Config.HIT_SOUND_TEMPLATE_NAME, targetRoot)
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

	local isFistTool = weapon.Name == FistConfig.WEAPON_MODEL_NAME
	local handle = findWeaponHandle(weapon)
	if not isFistTool and not handle then
		warn(`WeaponHandler: {weapon.Name} needs a BasePart named Handle`)
		return false
	end
	local weaponAttachment = if handle then handle:FindFirstChild("Attachment") else nil
	if not isFistTool and (not weaponAttachment or not weaponAttachment:IsA("Attachment")) then
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

local function attachWeapon(character: Model, weapon: Tool): boolean
	if not configureWeapon(weapon) then
		return false
	end
	if weapon.Name == FistConfig.WEAPON_MODEL_NAME then
		return true
	end
	local handAttachment = character:FindFirstChild("RightGripAttachment", true)
	if not handAttachment or not handAttachment:IsA("Attachment") then
		warn("WeaponHandler: RightGripAttachment not found in the character")
		return false
	end
	local handle = findWeaponHandle(weapon)
	if not handle then
		return false
	end
	disableWeaponPhysics(weapon)
	local weaponAttachment = handle:FindFirstChild("Attachment")
	if not weaponAttachment or not weaponAttachment:IsA("Attachment") then
		return false
	end

	removeWeaponGrip(weapon)
	local rigidConstraint = Instance.new("RigidConstraint")
	rigidConstraint.Name = "WeaponGrip"
	rigidConstraint.Attachment0 = handAttachment
	rigidConstraint.Attachment1 = weaponAttachment
	rigidConstraint.Parent = handle
	return true
end

local function createFistTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = FistConfig.WEAPON_MODEL_NAME
	tool.ToolTip = FistConfig.TOOLTIP
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool.ManualActivationOnly = true
	return tool
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
	local managedWeapons: {[string]: Tool} = {}
	local equippedBefore = findEquippedWeapon(character)
	local equippedWeaponName = if equippedBefore then equippedBefore.Name else nil
	for _, weaponName in ipairs(Config.WEAPON_MODEL_NAMES) do
		local weapon = findOwnedWeapon(player, character, weaponName)
		if not playerCanUseWeapon(player, weaponName) then
			if weapon then
				weapon:Destroy()
			end
			continue
		end
		if not weapon then
			if weaponName == FistConfig.WEAPON_MODEL_NAME then
				weapon = createFistTool()
			else
				local template = ServerStorage:FindFirstChild(weaponName)
				if not template or not template:IsA("Tool") then
					warn(`WeaponHandler: ServerStorage.{weaponName} must be a Tool`)
					continue
				end
				makeHierarchyArchivable(template)
				weapon = template:Clone()
			end
		end

		if configureWeapon(weapon) then
			managedWeapons[weaponName] = weapon
			if not weapon.Parent then
				weapon.Parent = backpackInstance
			elseif weapon.Parent == character then
				attachWeapon(character, weapon)
			end
			if weaponName == FistConfig.WEAPON_MODEL_NAME then
				defaultWeapon = weapon
			end
		elseif not weapon.Parent then
			weapon:Destroy()
		end
	end

	if player.Character == character and defaultWeapon then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			-- Roblox's Core hotbar follows Backpack insertion order. Reinsert every
			-- Tool synchronously so Fists is slot 1, the managed Tools follow their
			-- config order, and unrelated Tools retain their relative order.
			humanoid:UnequipTools()
			local unrelatedTools: {Tool} = {}
			local managedInstances: {[Tool]: boolean} = {}
			for _, weapon in pairs(managedWeapons) do
				managedInstances[weapon] = true
			end
			for _, child in ipairs(backpackInstance:GetChildren()) do
				if child:IsA("Tool") and managedInstances[child] ~= true then
					table.insert(unrelatedTools, child)
				end
			end
			for _, child in ipairs(backpackInstance:GetChildren()) do
				if child:IsA("Tool") then
					child.Parent = nil
				end
			end
			for _, weaponName in ipairs(Config.WEAPON_MODEL_NAMES) do
				local weapon = managedWeapons[weaponName]
				if weapon then
					weapon.Parent = backpackInstance
				end
			end
			for _, weapon in ipairs(unrelatedTools) do
				weapon.Parent = backpackInstance
			end
			local weaponToEquip = if equippedWeaponName
				then managedWeapons[equippedWeaponName]
				else nil
			humanoid:EquipTool(weaponToEquip or defaultWeapon)
		end
	end
end

local function hasLineOfSight(
	attackerCharacter: Model,
	targetCharacter: Model,
	requestedOrigin: Vector3?
): boolean
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetCharacter.Parent
		or not attackerRoot or not attackerRoot:IsA("BasePart")
		or not targetRoot or not targetRoot:IsA("BasePart") then
		return false
	end

	local rayOrigin = requestedOrigin or attackerRoot.Position
	local direction = targetRoot.Position - rayOrigin
	if direction.Magnitude <= 0.05 then
		return true
	end

	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { attackerCharacter }
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true

	local result = Workspace:Raycast(rayOrigin, direction, parameters)
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
	requireInFront: boolean,
	lineOfSightOrigin: Vector3?
): boolean
	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if targetCharacter == attackerCharacter
		or characterIsCaged(targetCharacter)
		or targetCharacter:GetAttribute(Config.KNOCKDOWN_ATTRIBUTE) == true
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
	return hasLineOfSight(attackerCharacter, targetCharacter, lineOfSightOrigin)
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

local function getCageAttackOrigin(
	attackerRoot: BasePart,
	requestedOrigin: any,
	trustedNpcTargeting: boolean
): Vector3
	local serverOrigin = attackerRoot.Position
	if trustedNpcTargeting
		or typeof(requestedOrigin) ~= "Vector3"
		or requestedOrigin.X ~= requestedOrigin.X
		or requestedOrigin.Y ~= requestedOrigin.Y
		or requestedOrigin.Z ~= requestedOrigin.Z
		or math.abs(requestedOrigin.X) == math.huge
		or math.abs(requestedOrigin.Y) == math.huge
		or math.abs(requestedOrigin.Z) == math.huge then
		return serverOrigin
	end

	-- Player-owned character replication can arrive just after the attack
	-- RemoteEvent. Preserve the local X/Z snapshot, but never let it extend the
	-- authoritative origin farther than the configured movement allowance.
	local requestedHorizontalOrigin = Vector3.new(
		requestedOrigin.X,
		serverOrigin.Y,
		requestedOrigin.Z
	)
	local offset = requestedHorizontalOrigin - serverOrigin
	local offsetMagnitude = offset.Magnitude
	if offsetMagnitude ~= offsetMagnitude or math.abs(offsetMagnitude) == math.huge then
		return serverOrigin
	end
	local velocity = attackerRoot.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local horizontalSpeed = horizontalVelocity.Magnitude
	if horizontalSpeed < CageConfig.SERVER_ATTACK_ORIGIN_MIN_SPEED
		or horizontalSpeed ~= horizontalSpeed
		or math.abs(horizontalSpeed) == math.huge then
		return serverOrigin
	end

	-- Only compensate in the direction in which the character is demonstrably
	-- moving on the server. This fixes replication lag without granting an
	-- arbitrary client-controlled extension of the capture sector.
	local movementDirection = horizontalVelocity.Unit
	local forwardDistance = offset:Dot(movementDirection)
	if forwardDistance <= 0 then
		return serverOrigin
	end
	local maxOffset = CageConfig.SERVER_ATTACK_ORIGIN_MAX_OFFSET
	local compensatedOffset = movementDirection * math.min(forwardDistance, maxOffset)
	local lateralOffset = offset - movementDirection * forwardDistance
	local lateralMagnitude = lateralOffset.Magnitude
	local maxLateralOffset = CageConfig.SERVER_ATTACK_ORIGIN_MAX_LATERAL_OFFSET
	if lateralMagnitude > maxLateralOffset then
		lateralOffset = lateralOffset.Unit * maxLateralOffset
	end
	compensatedOffset += lateralOffset
	if compensatedOffset.Magnitude > maxOffset then
		compensatedOffset = compensatedOffset.Unit * maxOffset
	end
	return serverOrigin + compensatedOffset
end

local function fistTargetIsValid(
	attackerCharacter: Model,
	targetCharacter: Model,
	direction: Vector3,
	applyRangeForgiveness: boolean
): (boolean, number, number)
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetCharacter.Parent
		or not attackerRoot or not attackerRoot:IsA("BasePart")
		or not targetRoot or not targetRoot:IsA("BasePart")
		or not characterCanBeHit(attackerCharacter, targetCharacter, false, nil) then
		return false, math.huge, -math.huge
	end
	local offset = targetRoot.Position - attackerRoot.Position
	local horizontalOffset = Vector3.new(offset.X, 0, offset.Z)
	local distance = horizontalOffset.Magnitude
	local centerDot = if distance > 0.05 then direction:Dot(horizontalOffset.Unit) else 1
	local rangeMultiplier = if applyRangeForgiveness
		then FistConfig.SERVER_RANGE_FORGIVENESS_MULTIPLIER
		else 1
	if distance > FistConfig.RANGE_STUDS * rangeMultiplier
		or math.abs(offset.Y) > FistConfig.MAX_VERTICAL_DIFFERENCE then
		return false, distance, centerDot
	end
	if centerDot < FistConfig.MIN_TARGET_FORWARD_DOT then
		return false, distance, centerDot
	end
	return true, distance, centerDot
end

local function findFistTarget(
	attackerCharacter: Model,
	direction: Vector3,
	requestedTarget: any,
	trustedTarget: boolean
): Model?
	if trustedTarget
		and typeof(requestedTarget) == "Instance"
		and requestedTarget:IsA("Model") then
		local valid = fistTargetIsValid(attackerCharacter, requestedTarget, direction, false)
		return if valid then requestedTarget else nil
	end

	local closestTarget: Model? = nil
	local closestDistance = math.huge
	local closestCenterDot = -math.huge
	local checked: {[Model]: boolean} = {}
	local function consider(targetCharacter: Model?)
		if not targetCharacter or checked[targetCharacter] then
			return
		end
		checked[targetCharacter] = true
		local valid, distance, centerDot = fistTargetIsValid(
			attackerCharacter,
			targetCharacter,
			direction,
			true
		)
		if valid
			and (centerDot > closestCenterDot + 0.0001
				or (math.abs(centerDot - closestCenterDot) <= 0.0001
					and distance < closestDistance)) then
			closestCenterDot = centerDot
			closestDistance = distance
			closestTarget = targetCharacter
		end
	end

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		consider(targetPlayer.Character)
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
		if not characterCanBeHit(attackerCharacter, character, true, nil)
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

local function findBatFallbackTarget(attackerCharacter: Model): Model?
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart") then
		return nil
	end

	local closestCharacter: Model? = nil
	local closestDistance = math.huge
	local closestCenterDot = -math.huge
	local direction = getAttackDirection(attackerRoot, nil)
	local maximumRange = Config.FALLBACK_HIT_RANGE_STUDS
		* Config.SERVER_RANGE_FORGIVENESS_MULTIPLIER
	local checkedCharacters: {[Model]: boolean} = {}
	local function considerCharacter(targetCharacter: Model?)
		if not targetCharacter or checkedCharacters[targetCharacter] then
			return
		end
		checkedCharacters[targetCharacter] = true
		local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
		if not targetRoot
			or not targetRoot:IsA("BasePart")
			or not characterCanBeHit(attackerCharacter, targetCharacter, true, nil) then
			return
		end
		local offset = targetRoot.Position - attackerRoot.Position
		local horizontalOffset = Vector3.new(offset.X, 0, offset.Z)
		local horizontalDistance = horizontalOffset.Magnitude
		local centerDot = if horizontalDistance > 0.05
			then direction:Dot(horizontalOffset.Unit)
			else 1
		if horizontalDistance > maximumRange
			or math.abs(offset.Y) > Config.FALLBACK_MAX_VERTICAL_DIFFERENCE
			or centerDot < Config.MIN_TARGET_FORWARD_DOT
			or centerDot < closestCenterDot - 0.0001
			or (math.abs(centerDot - closestCenterDot) <= 0.0001
				and horizontalDistance >= closestDistance) then
			return
		end
		closestCenterDot = centerDot
		closestDistance = horizontalDistance
		closestCharacter = targetCharacter
	end

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		considerCharacter(targetPlayer.Character)
	end
	local npcFolder = Workspace:FindFirstChild(ROUND_NPC_FOLDER_NAME)
	if npcFolder then
		for _, npc in ipairs(npcFolder:GetChildren()) do
			if npc:IsA("Model") then
				considerCharacter(npc)
			end
		end
	end
	return closestCharacter
end

local function findRequestedBatTarget(
	attackerCharacter: Model,
	requestedDirection: any,
	requestedTarget: any
): Model?
	if typeof(requestedTarget) ~= "Instance" or not requestedTarget:IsA("Model") then
		return nil
	end
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	local targetRoot = requestedTarget:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart")
		or not targetRoot or not targetRoot:IsA("BasePart")
		or not characterCanBeHit(attackerCharacter, requestedTarget, false, nil) then
		return nil
	end
	local offset = targetRoot.Position - attackerRoot.Position
	local horizontalOffset = Vector3.new(offset.X, 0, offset.Z)
	if horizontalOffset.Magnitude > Config.FALLBACK_HIT_RANGE_STUDS
		or math.abs(offset.Y) > Config.FALLBACK_MAX_VERTICAL_DIFFERENCE then
		return nil
	end
	if horizontalOffset.Magnitude > 0.05 then
		local direction = getAttackDirection(attackerRoot, requestedDirection)
		if direction:Dot(horizontalOffset.Unit) < Config.MIN_TARGET_FORWARD_DOT then
			return nil
		end
	end
	return requestedTarget
end

local function cageTargetIsEligible(character: Model): boolean
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		return player.Character == character
	end
	local npcFolder = Workspace:FindFirstChild(ROUND_NPC_FOLDER_NAME)
	return npcFolder ~= nil
		and character.Parent == npcFolder
		and character:GetAttribute(MANAGED_ROUND_NPC_ATTRIBUTE) == true
end

local function findCageAreaTarget(
	attackerCharacter: Model,
	direction: Vector3,
	requestedTarget: any,
	requestedOrigin: any,
	trustedNpcTargeting: boolean
): (Model?, Vector3?)
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart") then
		return nil, nil
	end

	local attackOrigin = getCageAttackOrigin(
		attackerRoot,
		requestedOrigin,
		trustedNpcTargeting
	)
	local targetPriorityCenter = attackOrigin
		+ direction * CageConfig.TARGET_PRIORITY_DISTANCE
	local parameters = OverlapParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { attackerCharacter }
	parameters.RespectCanCollide = false
	local areaDiameter = CageConfig.AREA_MAX_DISTANCE * 2
	local parts = Workspace:GetPartBoundsInBox(
		CFrame.new(attackOrigin),
		Vector3.new(areaDiameter, CageConfig.AREA_HEIGHT, areaDiameter),
		parameters
	)
	local checkedCharacters: {[Model]: boolean} = {}
	local closestCharacter: Model? = nil
	local closestDistance = math.huge

	local function considerCharacter(character: Model?, useTolerance: boolean): boolean
		if not character
			or checkedCharacters[character]
			or not cageTargetIsEligible(character) then
			return false
		end
		checkedCharacters[character] = true

		local targetRoot = character:FindFirstChild("HumanoidRootPart")
		if not characterCanBeHit(attackerCharacter, character, false, attackOrigin)
			or not targetRoot
			or not targetRoot:IsA("BasePart") then
			return false
		end

		local offset = targetRoot.Position - attackOrigin
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
		local distanceToPriorityCenter = Vector2.new(
			targetRoot.Position.X - targetPriorityCenter.X,
			targetRoot.Position.Z - targetPriorityCenter.Z
		).Magnitude
		if horizontalDistance >= math.max(0, CageConfig.AREA_MIN_DISTANCE - distanceTolerance)
			and horizontalDistance <= CageConfig.AREA_MAX_DISTANCE + distanceTolerance
			and facingDot >= minimumFacingDot
			and math.abs(offset.Y) <= CageConfig.AREA_HEIGHT * 0.5 + verticalTolerance
			and distanceToPriorityCenter < closestDistance then
			closestDistance = distanceToPriorityCenter
			closestCharacter = character
			return true
		end
		return false
	end

	if typeof(requestedTarget) == "Instance" and requestedTarget:IsA("Model") then
		if considerCharacter(requestedTarget, true) then
			local requestedRoot = requestedTarget:FindFirstChild("HumanoidRootPart")
			if requestedRoot and requestedRoot:IsA("BasePart") then
				return requestedTarget, requestedRoot.Position
			end
		end
		-- Do not silently cage a different character than the one highlighted by
		-- the client. A moved/invalid requested target simply turns this into a miss.
		return nil, nil
	end

	-- Player characters are checked directly so custom CanQuery settings cannot
	-- make a visibly contained target disappear from the cage area.
	for _, player in ipairs(Players:GetPlayers()) do
		considerCharacter(player.Character, false)
	end
	local npcFolder = Workspace:FindFirstChild(ROUND_NPC_FOLDER_NAME)
	if npcFolder then
		for _, npc in ipairs(npcFolder:GetChildren()) do
			if npc:IsA("Model")
				and npc:GetAttribute(MANAGED_ROUND_NPC_ATTRIBUTE) == true then
				considerCharacter(npc, false)
			end
		end
	end
	for _, part in ipairs(parts) do
		considerCharacter(findCharacter(part), false)
	end

	if closestCharacter then
		local closestRoot = closestCharacter:FindFirstChild("HumanoidRootPart")
		if closestRoot and closestRoot:IsA("BasePart") then
			return closestCharacter, closestRoot.Position
		end
	end
	return nil, nil
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

local function raiseCharacterAboveGround(
	targetCharacter: Model,
	humanoid: Humanoid,
	targetRoot: BasePart
)
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { targetCharacter }
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true
	local probeHeight = 5
	local result = Workspace:Raycast(
		targetRoot.Position + Vector3.yAxis * probeHeight,
		-Vector3.yAxis * (probeHeight + humanoid.HipHeight + targetRoot.Size.Y + 10),
		parameters
	)
	if not result then
		return
	end
	local minimumRootY = result.Position.Y + humanoid.HipHeight + targetRoot.Size.Y * 0.5 + 0.05
	local lift = minimumRootY - targetRoot.Position.Y
	if lift > 0 then
		targetCharacter:PivotTo(targetCharacter:GetPivot() + Vector3.yAxis * lift)
	end
end

local function createKnockdownCollider(
	targetCharacter: Model,
	targetRoot: BasePart
): (Part, {[BasePart]: boolean})
	local collisionStates: {[BasePart]: boolean} = {}
	for _, descendant in ipairs(targetCharacter:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "KnockdownCollider" then
			collisionStates[descendant] = descendant.CanCollide
			descendant.CanCollide = false
		end
	end

	local includedBodyParts: {[string]: boolean} = {
		HumanoidRootPart = true,
		Head = true,
		Torso = true,
		UpperTorso = true,
		LowerTorso = true,
		["Left Leg"] = true,
		["Right Leg"] = true,
		LeftUpperLeg = true,
		LeftLowerLeg = true,
		LeftFoot = true,
		RightUpperLeg = true,
		RightLowerLeg = true,
		RightFoot = true,
	}
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, child in ipairs(targetCharacter:GetChildren()) do
		if child:IsA("BasePart") and includedBodyParts[child.Name] then
			local relative = targetRoot.CFrame:ToObjectSpace(child.CFrame)
			local halfSize = child.Size * 0.5
			local xExtent = math.abs(relative.RightVector.X) * halfSize.X
				+ math.abs(relative.UpVector.X) * halfSize.Y
				+ math.abs(relative.LookVector.X) * halfSize.Z
			local yExtent = math.abs(relative.RightVector.Y) * halfSize.X
				+ math.abs(relative.UpVector.Y) * halfSize.Y
				+ math.abs(relative.LookVector.Y) * halfSize.Z
			local zExtent = math.abs(relative.RightVector.Z) * halfSize.X
				+ math.abs(relative.UpVector.Z) * halfSize.Y
				+ math.abs(relative.LookVector.Z) * halfSize.Z
			local position = relative.Position
			minimum = Vector3.new(
				math.min(minimum.X, position.X - xExtent),
				math.min(minimum.Y, position.Y - yExtent),
				math.min(minimum.Z, position.Z - zExtent)
			)
			maximum = Vector3.new(
				math.max(maximum.X, position.X + xExtent),
				math.max(maximum.Y, position.Y + yExtent),
				math.max(maximum.Z, position.Z + zExtent)
			)
		end
	end

	local scale = math.max(targetCharacter:GetScale(), 0.1)
	local minimumSize = Config.KNOCKDOWN_COLLIDER_MIN_SIZE_STUDS * scale
	local padding = Config.KNOCKDOWN_COLLIDER_PADDING_STUDS * scale
	local center = Vector3.zero
	local size = minimumSize
	if minimum.X < math.huge and maximum.X > -math.huge then
		center = (minimum + maximum) * 0.5
		local boundsSize = maximum - minimum + padding * 2
		size = Vector3.new(
			math.max(boundsSize.X, minimumSize.X),
			math.max(boundsSize.Y, minimumSize.Y),
			math.max(boundsSize.Z, minimumSize.Z)
		)
	end

	local collider = Instance.new("Part")
	collider.Name = "KnockdownCollider"
	collider.Shape = Enum.PartType.Block
	collider.Size = size
	collider.CFrame = targetRoot.CFrame * CFrame.new(center)
	collider.Transparency = 1
	collider.CastShadow = false
	collider.CanCollide = true
	collider.CanTouch = false
	collider.CanQuery = false
	collider.Massless = true
	collider.CollisionGroup = targetRoot.CollisionGroup
	collider.CustomPhysicalProperties = PhysicalProperties.new(
		0.1,
		Config.KNOCKDOWN_COLLIDER_FRICTION,
		0,
		100,
		100
	)
	collider.Parent = targetCharacter

	local weld = Instance.new("WeldConstraint")
	weld.Name = "KnockdownColliderWeld"
	weld.Part0 = targetRoot
	weld.Part1 = collider
	weld.Parent = collider
	return collider, collisionStates
end

local function liftKnockdownColliderAboveGround(targetCharacter: Model, collider: Part)
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { targetCharacter }
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true
	local probeUp = 6
	local result = Workspace:Raycast(
		collider.Position + Vector3.yAxis * probeUp,
		-Vector3.yAxis * (probeUp + collider.Size.Magnitude + 10),
		parameters
	)
	if not result then
		return
	end
	local halfSize = collider.Size * 0.5
	local halfHeight = math.abs(collider.CFrame.RightVector.Y) * halfSize.X
		+ math.abs(collider.CFrame.UpVector.Y) * halfSize.Y
		+ math.abs(collider.CFrame.LookVector.Y) * halfSize.Z
	local minimumCenterY = result.Position.Y
		+ halfHeight
		+ Config.KNOCKDOWN_COLLIDER_GROUND_CLEARANCE_STUDS
	local lift = minimumCenterY - collider.Position.Y
	if lift > 0 then
		targetCharacter:PivotTo(targetCharacter:GetPivot() + Vector3.yAxis * lift)
	end
end

local function restoreKnockdownCollisions(record: KnockdownRecord)
	if record.collider then
		record.collider:Destroy()
		record.collider = nil
	end
	for part, canCollide in pairs(record.collisionStates) do
		if part.Parent then
			part.CanCollide = canCollide
		end
	end
	table.clear(record.collisionStates)
end

local function getSafeReactionRootPosition(
	targetCharacter: Model,
	targetRoot: BasePart,
	desiredPosition: Vector3
): Vector3
	local horizontalOffset = Vector3.new(
		desiredPosition.X - targetRoot.Position.X,
		0,
		desiredPosition.Z - targetRoot.Position.Z
	)
	local distance = horizontalOffset.Magnitude
	if distance <= 0.05 then
		return targetRoot.Position
	end

	local excluded: {Instance} = { targetCharacter }
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character and player.Character ~= targetCharacter then
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

	local scale = math.max(targetCharacter:GetScale(), 0.1)
	local direction = horizontalOffset.Unit
	local rightDirection = Vector3.yAxis:Cross(direction)
	local wallClearance = math.max(targetRoot.Size.X, targetRoot.Size.Z) * 0.5
		+ 0.15 * scale
	local maximumDistance = distance
	local origins = {
		targetRoot.Position,
		targetRoot.Position + Vector3.yAxis * 1.25 * scale,
		targetRoot.Position - Vector3.yAxis * 0.75 * scale,
		targetRoot.Position + rightDirection * 0.8 * scale,
		targetRoot.Position - rightDirection * 0.8 * scale,
	}
	for _, origin in ipairs(origins) do
		local result = Workspace:Raycast(origin, direction * distance, parameters)
		if result then
			maximumDistance = math.min(
				maximumDistance,
				math.max(0, result.Distance - wallClearance)
			)
		end
	end

	local safePosition = targetRoot.Position + direction * maximumDistance
	local floorResult = Workspace:Raycast(
		safePosition + Vector3.yAxis * 4 * scale,
		-Vector3.yAxis * 12 * scale,
		parameters
	)
	if not floorResult then
		return targetRoot.Position
	end
	return Vector3.new(safePosition.X, targetRoot.Position.Y, safePosition.Z)
end

local function getReactionSettledRootPosition(
	targetCharacter: Model,
	targetRoot: BasePart,
	record: KnockdownRecord
): Vector3?
	local startPosition = record.reactionStartRootPosition
	local travelDirection = record.reactionTravelDirection
	if not startPosition or not travelDirection then
		return nil
	end
	local scale = math.max(targetCharacter:GetScale(), 0.1)
	return getSafeReactionRootPosition(
		targetCharacter,
		targetRoot,
		startPosition
			+ travelDirection * TrashCanConfig.REACTION_TRAVEL_DISTANCE_STUDS * scale
	)
end

local function holdReactionLastFrame(
	humanoid: Humanoid,
	record: KnockdownRecord,
	token: number
)
	local track = record.reactionTrack
	if not track then
		return
	end

	task.spawn(function()
		local previousTimePosition = 0
		while knockdownRecords[humanoid] == record
			and record.token == token
			and record.reactionTrack == track do
			local succeeded, length, timePosition = pcall(function()
				return track.Length, track.TimePosition
			end)
			if not succeeded then
				return
			end
			if length > 0 then
				local finalTimePosition = math.max(0, length - 0.01)
				local reachedEnd = timePosition >= finalTimePosition
				local loopedBetweenFrames = timePosition + 0.02 < previousTimePosition
				if reachedEnd or loopedBetweenFrames then
					pcall(function()
						track:AdjustSpeed(0)
						track.TimePosition = finalTimePosition
						track:AdjustWeight(1, 0)
						track.Looped = false
					end)
					return
				end
				previousTimePosition = timePosition
			end
			RunService.Heartbeat:Wait()
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
	knockbackTipSpeed: number,
	reactionTrack: AnimationTrack?,
	knockbackOrigin: Vector3?,
	knockbackDirection: Vector3?
)
	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	local attackerRoot = attackerCharacter:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0
		or (not allowSeeker and getCharacterRole(targetCharacter) == ROLE_SEEKER)
		or not targetRoot or not targetRoot:IsA("BasePart")
		or targetRoot.Anchored
		or not attackerRoot or not attackerRoot:IsA("BasePart") then
		if reactionTrack then
			reactionTrack:Destroy()
		end
		return
	end
	local sourcePosition = knockbackOrigin or attackerRoot.Position
	local horizontalDirection = if knockbackDirection
		then Vector3.new(knockbackDirection.X, 0, knockbackDirection.Z)
		else Vector3.new(
			targetRoot.Position.X - sourcePosition.X,
			0,
			targetRoot.Position.Z - sourcePosition.Z
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
	clearFistHitRecord(humanoid)
	local fistReactionTrack = fistReactionTracks[humanoid]
	if fistReactionTrack then
		fistReactionTracks[humanoid] = nil
		pcall(function()
			fistReactionTrack:Stop(0)
			fistReactionTrack:Destroy()
		end)
	end

	local record = knockdownRecords[humanoid]
	local isNewKnockdown = record == nil
	if not record then
		raiseCharacterAboveGround(targetCharacter, humanoid, targetRoot)
		local physical = reactionTrack == nil
		-- Animated knockdowns need the proxy too: pose-driven body parts cannot
		-- reliably stop the actual character assembly when it reaches a wall.
		local collider, collisionStates = createKnockdownCollider(targetCharacter, targetRoot)
		local turnOrientation = targetCharacter:FindFirstChild("NpcSmoothTurnOrientation", true)
		local npcTurnOrientation = if turnOrientation and turnOrientation:IsA("AlignOrientation")
			then turnOrientation
			else nil
		record = {
			token = 0,
			platformStand = humanoid.PlatformStand,
			autoRotate = humanoid.AutoRotate,
			walkSpeed = humanoid.WalkSpeed,
			jumpHeight = humanoid.JumpHeight,
			jumpPower = humanoid.JumpPower,
			physical = physical,
			collisionStates = collisionStates,
			collider = collider,
			walkSpeedConnection = nil,
			animationPlayedConnection = nil,
			reactionTrack = nil,
			reactionStartRootPosition = nil,
			reactionTravelDirection = nil,
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
				if knockdownRecords[humanoid] == record and track ~= record.reactionTrack then
					track:Stop(0)
				end
			end)
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				track:Stop(0.05)
			end
		end
	end
	if record.physical and reactionTrack then
		reactionTrack:Destroy()
		reactionTrack = nil
	end
	if record.reactionTrack then
		record.reactionTrack:Stop(0.05)
		record.reactionTrack:Destroy()
		record.reactionTrack = nil
	end
	record.reactionStartRootPosition = nil
	record.reactionTravelDirection = nil
	if not reactionTrack and not record.physical then
		record.physical = true
	end
	if reactionTrack then
		record.reactionTrack = reactionTrack
		local succeeded = pcall(function()
			reactionTrack:Play(0.05, 1, 1)
		end)
		if not succeeded then
			record.reactionTrack = nil
			reactionTrack:Destroy()
			if not record.physical then
				record.physical = true
			end
		end
	end
	record.token += 1
	local token = record.token
	holdReactionLastFrame(humanoid, record, token)

	targetCharacter:SetAttribute(Config.KNOCKDOWN_ATTRIBUTE, true)
	if isNewKnockdown then
		RoundResultService.RecordKnockdown(attackerCharacter, targetCharacter)
	end
	if record.npcTurnOrientation then
		record.npcTurnOrientation.Enabled = false
	end
	humanoid:Move(Vector3.zero, false)
	humanoid.WalkSpeed = 0
	humanoid.Jump = false
	humanoid.JumpHeight = 0
	humanoid.JumpPower = 0
	humanoid.AutoRotate = false
	-- Keep knockback authoritative for both player characters and server NPCs.
	setServerNetworkOwnership(targetRoot)
	if record.reactionTrack then
		-- AllahBabah falls backwards, so the rig must look against the shot for
		-- the visible fall to travel away from the attacker.
		local rootToPivot = targetRoot.CFrame:ToObjectSpace(targetCharacter:GetPivot())
		local alignedRoot = CFrame.lookAt(
			targetRoot.Position,
			targetRoot.Position - horizontalDirection,
			Vector3.yAxis
		)
		targetCharacter:PivotTo(alignedRoot * rootToPivot)
		record.reactionStartRootPosition = targetRoot.Position
		record.reactionTravelDirection = horizontalDirection
	end
	local fallAxis = Vector3.yAxis:Cross(horizontalDirection)
	if record.physical then
		-- Player-owned Humanoids may reject a server state change. Give the server
		-- authority before entering Physics so every confirmed bat hit falls.
		humanoid.PlatformStand = true
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		if isNewKnockdown
			and fallAxis.Magnitude > 0.05
			and math.abs(targetRoot.CFrame.UpVector.Y) > 0.45 then
			local rootToPivot = targetRoot.CFrame:ToObjectSpace(targetCharacter:GetPivot())
			local tiltedRoot = CFrame.new(targetRoot.Position)
				* CFrame.fromAxisAngle(
					fallAxis.Unit,
					math.rad(Config.INITIAL_KNOCKDOWN_TILT_DEGREES)
				)
				* targetRoot.CFrame.Rotation
			targetCharacter:PivotTo(tiltedRoot * rootToPivot)
		end
		if record.collider and record.collider.Parent then
			liftKnockdownColliderAboveGround(targetCharacter, record.collider)
		end
		targetRoot.AssemblyLinearVelocity = horizontalDirection * knockbackSpeed
			+ Vector3.yAxis * knockbackUpwardSpeed
		targetRoot.AssemblyAngularVelocity = if fallAxis.Magnitude <= 0.05
			then Vector3.zero
			else fallAxis.Unit * knockbackTipSpeed
	else
		-- AllahBabah supplies bone-only visible travel. The matching configured
		-- distance is applied to HumanoidRootPart after a wall and floor safety sweep.
		targetRoot.AssemblyLinearVelocity = Vector3.zero
		targetRoot.AssemblyAngularVelocity = Vector3.zero
	end

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
		local settledRootPosition = if record.reactionTrack and targetRoot.Parent
			then getReactionSettledRootPosition(targetCharacter, targetRoot, record)
			else nil
		if record.reactionTrack then
			record.reactionTrack:Stop(0)
			record.reactionTrack:Destroy()
			record.reactionTrack = nil
		end
		record.reactionStartRootPosition = nil
		record.reactionTravelDirection = nil
		if settledRootPosition and targetRoot.Parent then
			local rootToPivot = targetRoot.CFrame:ToObjectSpace(targetCharacter:GetPivot())
			local settledRoot = CFrame.new(settledRootPosition) * targetRoot.CFrame.Rotation
			targetCharacter:PivotTo(settledRoot * rootToPivot)
		end
		pcall(function()
			targetCharacter:SetAttribute(Config.KNOCKDOWN_ATTRIBUTE, nil)
		end)
		if targetRoot.Parent then
			targetRoot.AssemblyLinearVelocity = Vector3.zero
			targetRoot.AssemblyAngularVelocity = Vector3.zero
		end
		restoreKnockdownCollisions(record)
		if not targetCharacter.Parent or not humanoid.Parent then
			return
		end
		if targetRoot.Parent then
			raiseCharacterAboveGround(targetCharacter, humanoid, targetRoot)
		end
		local turnOrientation = record.npcTurnOrientation
		if turnOrientation and turnOrientation.Parent then
			turnOrientation.Enabled = record.npcTurnOrientationEnabled == true
		end
		humanoid.PlatformStand = record.platformStand
		humanoid.AutoRotate = record.autoRotate
		humanoid.WalkSpeed = record.walkSpeed
		humanoid.JumpHeight = record.jumpHeight
		humanoid.JumpPower = record.jumpPower
		if record.physical and humanoid.Health > 0 and not record.platformStand then
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			task.delay(0.05, function()
				if targetCharacter.Parent and humanoid.Parent and targetRoot.Parent then
					raiseCharacterAboveGround(targetCharacter, humanoid, targetRoot)
				end
			end)
		end
		if targetRoot.Parent then
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

local function getCharacterAnimationContainers(character: Model): {Instance}
	local containers: {Instance} = {}
	local added: {[Instance]: boolean} = {}
	local function add(container: Instance?)
		if container and not added[container] then
			added[container] = true
			table.insert(containers, container)
		end
	end

	add(character:FindFirstChild("Animate"))
	add(character)
	local starterScripts = StarterPlayer:FindFirstChild("StarterCharacterScripts")
	add(if starterScripts then starterScripts:FindFirstChild("Animate") else nil)
	add(ServerStorage)
	return containers
end

local function resolveFistReactionAnimation(targetCharacter: Model): Animation?
	local containers = getCharacterAnimationContainers(targetCharacter)
	for _, container in ipairs(containers) do
		local animation = findNamedAnimation(
			container,
			FistConfig.HIT_REACTION_ANIMATION_NAME
		)
		if animation then
			return animation
		end
	end
	if studioFistReactionAnimation then
		return studioFistReactionAnimation
	end

	local sequence: KeyframeSequence? = nil
	for _, container in ipairs(containers) do
		sequence = findNamedKeyframeSequence(
			container,
			FistConfig.HIT_REACTION_ANIMATION_NAME
		)
		if sequence then
			break
		end
	end
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
	temporaryAnimation.Name = FistConfig.HIT_REACTION_ANIMATION_NAME
	temporaryAnimation.AnimationId = temporaryId
	studioFistReactionAnimation = temporaryAnimation
	return temporaryAnimation
end

local function playFistHitReaction(targetCharacter: Model)
	local animation = resolveFistReactionAnimation(targetCharacter)
	if not animation then
		if not warnedMissingFistReaction then
			warnedMissingFistReaction = true
			warn(
				`WeaponHandler: Animation '{FistConfig.HIT_REACTION_ANIMATION_NAME}' not found in Animate`
			)
		end
		return
	end
	warnedMissingFistReaction = false

	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local previousTrack = fistReactionTracks[humanoid]
	if previousTrack then
		fistReactionTracks[humanoid] = nil
		pcall(function()
			previousTrack:Stop(FistConfig.HIT_REACTION_FADE_SECONDS)
			previousTrack:Destroy()
		end)
	end

	local succeeded, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not succeeded or not track then
		warn(`WeaponHandler: failed to load animation '{animation:GetFullName()}'`)
		return
	end
	track.Priority = FistConfig.HIT_REACTION_ANIMATION_PRIORITY
	track.Looped = false
	fistReactionTracks[humanoid] = track
	local cleaned = false
	local function cleanup(stopTrack: boolean)
		if cleaned then
			return
		end
		cleaned = true
		if fistReactionTracks[humanoid] == track then
			fistReactionTracks[humanoid] = nil
		end
		pcall(function()
			if stopTrack then
				track:Stop(0)
			end
			track:Destroy()
		end)
	end
	track.Ended:Once(function()
		cleanup(false)
	end)
	track.Destroying:Once(function()
		if not cleaned then
			cleaned = true
			if fistReactionTracks[humanoid] == track then
				fistReactionTracks[humanoid] = nil
			end
		end
	end)
	local played = pcall(function()
		track:Play(
			FistConfig.HIT_REACTION_FADE_SECONDS,
			1,
			FistConfig.HIT_REACTION_ANIMATION_SPEED
		)
	end)
	if not played then
		cleanup(true)
		return
	end
	task.delay(FistConfig.HIT_REACTION_FALLBACK_LIFETIME_SECONDS, function()
		if fistReactionTracks[humanoid] == track then
			cleanup(true)
		end
	end)
end

local function recordFistHit(attackerCharacter: Model, targetCharacter: Model)
	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or not targetCharacter.Parent then
		return
	end

	playRandomFistHitSound(targetCharacter)
	local record = fistHitRecords[humanoid]
	if record and record.character ~= targetCharacter then
		detachFistHitRecord(humanoid, record, true)
		record = nil
	end
	if not record then
		record = {
			character = targetCharacter,
			count = 0,
			revision = 0,
			destroyingConnection = nil,
		}
		fistHitRecords[humanoid] = record
		record.destroyingConnection = humanoid.Destroying:Connect(function()
			detachFistHitRecord(humanoid, record :: FistHitRecord, true)
		end)
	end

	record.count = math.min(record.count + 1, FistConfig.HITS_TO_KNOCKDOWN)
	record.revision += 1
	setFistHitDisplay(targetCharacter, record.count)
	if record.count >= FistConfig.HITS_TO_KNOCKDOWN then
		-- Keep 4/4 visible during the short fall, but remove the active combo first
		-- so the generic knockdown cleanup cannot treat it as an unfinished series.
		detachFistHitRecord(humanoid, record, false)
		knockDown(
			targetCharacter,
			attackerCharacter,
			FistConfig.KNOCKDOWN_DURATION_SECONDS,
			false,
			0,
			0,
			0,
			nil,
			nil,
			nil
		)
		task.delay(FistConfig.KNOCKDOWN_DURATION_SECONDS, function()
			if fistHitRecords[humanoid] == nil then
				fistHitDisplayCharacters[targetCharacter] = nil
				if targetCharacter.Parent then
					setFistHitDisplay(targetCharacter, 0)
				end
			end
		end)
		return
	end

	playFistHitReaction(targetCharacter)
	scheduleFistHitDecay(humanoid, record)
end

local function getTrashCanAnimationContainers(targetCharacter: Model, weapon: Tool): {Instance}
	local containers: {Instance} = {}
	local added: {[Instance]: boolean} = {}
	local function add(container: Instance?)
		if container and not added[container] then
			added[container] = true
			table.insert(containers, container)
		end
	end

	-- AllahBabah is a hit reaction, so the victim's Animate hierarchy is the
	-- authoritative source. The remaining locations keep NPCs and older assets
	-- compatible when their character clone does not contain Animate.
	add(targetCharacter:FindFirstChild("Animate"))
	add(targetCharacter)
	local starterScripts = StarterPlayer:FindFirstChild("StarterCharacterScripts")
	add(if starterScripts then starterScripts:FindFirstChild("Animate") else nil)
	add(weapon)
	add(ServerStorage)
	return containers
end

local function resolveTrashCanAnimation(targetCharacter: Model, weapon: Tool): Animation?
	local containers = getTrashCanAnimationContainers(targetCharacter, weapon)
	for _, container in ipairs(containers) do
		local animation = findNamedAnimation(container, TrashCanConfig.ATTACK_ANIMATION_NAME)
		if animation then
			return animation
		end
	end
	if studioTrashAnimation then
		return studioTrashAnimation
	end

	local sequence: KeyframeSequence? = nil
	for _, container in ipairs(containers) do
		sequence = findNamedKeyframeSequence(container, TrashCanConfig.ATTACK_ANIMATION_NAME)
		if sequence then
			break
		end
	end
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

local function loadTrashCanReaction(targetCharacter: Model, weapon: Tool): AnimationTrack?
	local animation = resolveTrashCanAnimation(targetCharacter, weapon)
	if not animation then
		if not warnedMissingTrashAnimation then
			warnedMissingTrashAnimation = true
			local hasSavedSequence = false
			for _, container in ipairs(getTrashCanAnimationContainers(targetCharacter, weapon)) do
				if findNamedKeyframeSequence(container, TrashCanConfig.ATTACK_ANIMATION_NAME) then
					hasSavedSequence = true
					break
				end
			end
			local suffix = if hasSavedSequence
				then " (the Animation Editor KeyframeSequence must first be published as an Animation)"
				else ""
			warn(
				`WeaponHandler: Animation '{TrashCanConfig.ATTACK_ANIMATION_NAME}' not found{suffix}`
			)
		end
		return
	end
	warnedMissingTrashAnimation = false

	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
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
	track.Priority = Enum.AnimationPriority.Action4
	-- Looping prevents Roblox from fading the pose before the server can pin the
	-- final time position. holdReactionLastFrame disables the loop immediately.
	track.Looped = true
	return track
end

local function getTrashCanLaunchPosition(
	weapon: Tool,
	direction: Vector3,
	attackerRoot: BasePart
): Vector3
	local origin: Vector3 = attackerRoot.Position
	local handle = findWeaponHandle(weapon)
	local namedOrigin = weapon:FindFirstChild("Muzzle", true)
		or weapon:FindFirstChild("ShotOrigin", true)
		or weapon:FindFirstChild("EffectOrigin", true)
	local attachment = if namedOrigin and namedOrigin:IsA("Attachment")
		then namedOrigin
		else (if handle then handle:FindFirstChildWhichIsA("Attachment", true) else nil)
	if attachment then
		origin = attachment.WorldPosition
	elseif namedOrigin and namedOrigin:IsA("BasePart") then
		origin = namedOrigin.Position
	elseif handle then
		origin = handle.Position
	end
	return origin
		+ Vector3.yAxis * TrashCanConfig.EFFECT_START_HEIGHT_OFFSET_STUDS
		+ direction * TrashCanConfig.EFFECT_START_FORWARD_OFFSET_STUDS
end

local function emitTrashCanEffect(
	weapon: Tool,
	direction: Vector3,
	launchPosition: Vector3
)
	local source = weapon:FindFirstChild(TrashCanConfig.EFFECT_OBJECT_NAME, true)
	if not source then
		local template = ServerStorage:FindFirstChild(TrashCanConfig.WEAPON_MODEL_NAME)
		source = if template
			then template:FindFirstChild(TrashCanConfig.EFFECT_OBJECT_NAME, true)
			else nil
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
	attackOrigin: Vector3,
	targetCharacter: Model
): boolean
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot or not targetRoot:IsA("BasePart") then
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
	local rayDirection = targetRoot.Position - attackOrigin
	if rayDirection.Magnitude <= 0.05 then
		return true
	end
	return Workspace:Raycast(
		attackOrigin,
		rayDirection,
		parameters
	) == nil
end

local function characterCanBeTrashKnocked(
	attackerCharacter: Model,
	targetCharacter: Model,
	attackOrigin: Vector3
): boolean
	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	local rootPart = targetCharacter:FindFirstChild("HumanoidRootPart")
	if targetCharacter == attackerCharacter
		or characterIsCaged(targetCharacter)
		or getCharacterRole(targetCharacter) == ROLE_SEEKER
		or not humanoid
		or humanoid.Health <= 0
		or (humanoid.PlatformStand and knockdownRecords[humanoid] == nil)
		or not rootPart
		or not rootPart:IsA("BasePart")
		or rootPart.Anchored then
		return false
	end
	return hasTrashCanLineOfSight(attackOrigin, targetCharacter)
end

local function findTrashAimAssistDirection(
	attackerCharacter: Model,
	attackOrigin: Vector3,
	direction: Vector3
): Vector3
	local minimumCenterDot = math.cos(math.rad(TrashCanConfig.SERVER_AIM_ASSIST_DEGREES))
	local bestDirection: Vector3? = nil
	local bestCenterDot = minimumCenterDot
	local bestDistance = math.huge
	local checkedCharacters: {[Model]: boolean} = {}
	local function consider(targetCharacter: Model?)
		if not targetCharacter
			or checkedCharacters[targetCharacter]
			or getCharacterRole(targetCharacter) ~= ROLE_HIDER then
			return
		end
		checkedCharacters[targetCharacter] = true
		local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
		if not targetRoot
			or not targetRoot:IsA("BasePart")
			or not characterCanBeTrashKnocked(
				attackerCharacter,
				targetCharacter,
				attackOrigin
			) then
			return
		end
		local offset = targetRoot.Position - attackOrigin
		if math.abs(offset.Y) > TrashCanConfig.MAX_VERTICAL_DIFFERENCE then
			return
		end
		local horizontalOffset = Vector3.new(offset.X, 0, offset.Z)
		local distance = horizontalOffset.Magnitude
		if distance <= 0.05 or distance > TrashCanConfig.RANGE_STUDS then
			return
		end
		local targetDirection = horizontalOffset.Unit
		local centerDot = direction:Dot(targetDirection)
		if centerDot < minimumCenterDot
			or (bestDirection
				and centerDot < bestCenterDot - 0.0001)
			or (bestDirection
				and math.abs(centerDot - bestCenterDot) <= 0.0001
				and distance >= bestDistance) then
			return
		end
		bestDirection = targetDirection
		bestCenterDot = centerDot
		bestDistance = distance
	end

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		consider(targetPlayer.Character)
	end
	local npcFolder = Workspace:FindFirstChild(ROUND_NPC_FOLDER_NAME)
	if npcFolder then
		for _, npc in ipairs(npcFolder:GetChildren()) do
			if npc:IsA("Model") then
				consider(npc)
			end
		end
	end
	return bestDirection or direction
end

local function characterIsInTrashArea(
	attackOrigin: Vector3,
	targetRoot: BasePart,
	direction: Vector3
): boolean
	local offset = targetRoot.Position - attackOrigin
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
	character: Model,
	weapon: Tool,
	attackerRoot: BasePart,
	requestedDirection: any,
	applyAimAssist: boolean
)
	local attackOrigin = attackerRoot.Position
	local requestedAttackDirection = getAttackDirection(attackerRoot, requestedDirection)
	local direction = if applyAimAssist
		then findTrashAimAssistDirection(character, attackOrigin, requestedAttackDirection)
		else requestedAttackDirection
	local launchPosition = getTrashCanLaunchPosition(weapon, direction, attackerRoot)
	playSoundTemplate(
		TrashCanConfig.FIRE_SOUND_TEMPLATE_NAME,
		findWeaponHandle(weapon) or attackerRoot
	)
	emitTrashCanEffect(weapon, direction, launchPosition)

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
			and characterCanBeTrashKnocked(character, targetCharacter, attackOrigin)
			and characterIsInTrashArea(attackOrigin, targetRoot, direction) then
			local projectedDistance = math.clamp(
				(targetRoot.Position - launchPosition):Dot(direction),
				0,
				TrashCanConfig.RANGE_STUDS
			)
			local impactDelay = TrashCanConfig.EFFECT_TRAVEL_SECONDS
				* projectedDistance / math.max(TrashCanConfig.RANGE_STUDS, 0.001)
			task.delay(impactDelay, function()
				local currentTargetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
				if not targetCharacter.Parent
					or not currentTargetRoot
					or not currentTargetRoot:IsA("BasePart")
					or not characterCanBeTrashKnocked(character, targetCharacter, attackOrigin)
					or not characterIsInTrashArea(attackOrigin, currentTargetRoot, direction) then
					return
				end
				-- Always keep the authored reaction. The final server position is
				-- independently clamped to walls and validated against the floor.
				local reactionTrack = loadTrashCanReaction(targetCharacter, weapon)
				knockDown(
					targetCharacter,
					character,
					TrashCanConfig.KNOCKDOWN_DURATION_SECONDS,
					false,
					TrashCanConfig.KNOCKBACK_SPEED,
					TrashCanConfig.KNOCKBACK_UPWARD_SPEED,
					TrashCanConfig.KNOCKBACK_TIP_SPEED,
					reactionTrack,
					attackOrigin,
					direction
				)
			end)
		end
	end

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		knockCharacter(targetPlayer.Character)
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

local function getAttackCooldownSeconds(
	character: Model,
	weaponName: string,
	isFistAttack: boolean
): number
	local player = Players:GetPlayerFromCharacter(character)
	local cooldownSeconds: number? = nil
	if player then
		local item = WeaponShopConfig.BY_WEAPON[weaponName]
		if item then
			local minimum = math.max(0, item.COOLDOWN_MIN_SECONDS)
			local maximum = math.max(minimum, item.COOLDOWN_MAX_SECONDS)
			cooldownSeconds = if maximum > minimum
				then cooldownRandom:NextNumber(minimum, maximum)
				else minimum
		end
	end
	if not cooldownSeconds then
		cooldownSeconds = if isFistAttack
			then FistConfig.ATTACK_COOLDOWN_SECONDS
			else Config.ATTACK_COOLDOWN_SECONDS
	end
	if player and player:GetAttribute(CooldownPassConfig.OWNED_ATTRIBUTE) == true then
		cooldownSeconds *= CooldownPassConfig.COOLDOWN_MULTIPLIER
	end
	return cooldownSeconds
end

local function tryStartAttackCooldown(
	character: Model,
	weaponName: string,
	isFistAttack: boolean
): boolean
	local now = os.clock()
	local cooldowns = nextAttackAtByCharacter[character]
	if not cooldowns then
		cooldowns = {}
		nextAttackAtByCharacter[character] = cooldowns
		character.Destroying:Connect(function()
			nextAttackAtByCharacter[character] = nil
		end)
	end
	local nextAttackAt = cooldowns[weaponName]
	if nextAttackAt and now < nextAttackAt then
		return false
	end

	local cooldownSeconds = getAttackCooldownSeconds(character, weaponName, isFistAttack)
	cooldowns[weaponName] = now + cooldownSeconds
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		player:SetAttribute(
			WeaponShopConfig.COOLDOWN_ATTRIBUTE_PREFIX .. weaponName,
			Workspace:GetServerTimeNow() + cooldownSeconds
		)
	end
	return true
end

local function resetPlayerAttackCooldowns(player: Player)
	local character = player.Character
	if character then
		local cooldowns = nextAttackAtByCharacter[character]
		if cooldowns then
			table.clear(cooldowns)
		end
	end

	local resetDeadline = Workspace:GetServerTimeNow()
	for _, item in ipairs(WeaponShopConfig.ITEMS) do
		player:SetAttribute(
			WeaponShopConfig.COOLDOWN_ATTRIBUTE_PREFIX .. item.WEAPON_NAME,
			resetDeadline
		)
	end
end

local function resetManagedNpcAttackCooldowns()
	for character, cooldowns in pairs(nextAttackAtByCharacter) do
		if character:GetAttribute(MANAGED_ROUND_NPC_ATTRIBUTE) == true then
			table.clear(cooldowns)
		end
	end
end

local function bindRoundCooldownReset()
	local roundState = ReplicatedStorage:WaitForChild(ROUND_STATE_NAME)
	local function handlePhaseChanged()
		-- Cancel delayed fist hit windows and remove combo UI both when a round
		-- starts and when players return to the HUB.
		fistHitGeneration += 1
		resetFistHitRecords()
		if roundState:GetAttribute("Phase") == PHASE_ROUND then
			-- Players reset when they are actually placed on the arena. Managed
			-- NPC cooldowns live only in this server table, so reset them here.
			resetManagedNpcAttackCooldowns()
		end
	end
	roundState:GetAttributeChangedSignal("Phase"):Connect(handlePhaseChanged)
	handlePhaseChanged()
end

local function tryAttackCharacter(
	character: Model,
	requestedDirection: any,
	requestedTarget: any,
	trustedNpcTargeting: boolean?,
	requestedWeapon: any?,
	requestedAttackOrigin: any?
): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local attackerRoot = character:FindFirstChild("HumanoidRootPart")
	local equippedWeapon = findEquippedWeapon(character)
	if requestedWeapon ~= nil
		and (typeof(requestedWeapon) ~= "Instance"
			or not requestedWeapon:IsA("Tool")
			or requestedWeapon ~= equippedWeapon) then
		return false
	end
	local isFistAttack = equippedWeapon ~= nil
		and equippedWeapon.Name == FistConfig.WEAPON_MODEL_NAME
	local handleInstance = if equippedWeapon then findWeaponHandle(equippedWeapon) else nil
	if not character.Parent
		or not humanoid
		or humanoid.Health <= 0
		or humanoid.PlatformStand
		or character:GetAttribute(Config.KNOCKDOWN_ATTRIBUTE) == true
		or characterIsCaged(character)
		or not attackerRoot
		or not attackerRoot:IsA("BasePart")
		or not equippedWeapon
		or (not isFistAttack and not handleInstance) then
		return false
	end
	local attackingPlayer = Players:GetPlayerFromCharacter(character)
	if attackingPlayer and not playerCanUseWeapon(attackingPlayer, equippedWeapon.Name) then
		return false
	end

	if not tryStartAttackCooldown(character, equippedWeapon.Name, isFistAttack) then
		return false
	end

	if isFistAttack then
		local rootDirection = getAttackDirection(attackerRoot, nil)
		local requestedAttackDirection = getAttackDirection(attackerRoot, requestedDirection)
		local attackX = requestedAttackDirection.X
		local attackZ = requestedAttackDirection.Z
		local requestedDirectionIsValid = attackX == attackX
			and attackZ == attackZ
			and math.abs(attackX) < math.huge
			and math.abs(attackZ) < math.huge
			and requestedAttackDirection.Magnitude > 0.05
		local attackDirection = rootDirection
		if requestedDirectionIsValid
			and (trustedNpcTargeting == true
				or requestedAttackDirection:Dot(rootDirection)
					>= FistConfig.MIN_ATTACK_DIRECTION_LOOK_DOT) then
			attackDirection = requestedAttackDirection
		end
		local hitGeneration = fistHitGeneration
		task.delay(FistConfig.HIT_DELAY_SECONDS, function()
			if fistHitGeneration ~= hitGeneration then
				return
			end
			local hitWindowEndsAt = os.clock() + FistConfig.HIT_WINDOW_DURATION_SECONDS
			repeat
				if fistHitGeneration ~= hitGeneration
					or not character.Parent
					or not attackerRoot.Parent
					or humanoid.Health <= 0
					or humanoid.PlatformStand
					or character:GetAttribute(Config.KNOCKDOWN_ATTRIBUTE) == true
					or characterIsCaged(character)
					or findEquippedWeapon(character) ~= equippedWeapon then
					return
				end

				local targetCharacter = findFistTarget(
					character,
					attackDirection,
					requestedTarget,
					trustedNpcTargeting == true
				)
				if targetCharacter then
					recordFistHit(character, targetCharacter)
					return
				end
				RunService.Heartbeat:Wait()
			until os.clock() >= hitWindowEndsAt
		end)
		return true
	end

	local handle = handleInstance :: BasePart
	if equippedWeapon.Name == TrashCanConfig.WEAPON_MODEL_NAME then
		fireTrashCan(
			character,
			equippedWeapon,
			attackerRoot,
			requestedDirection,
			trustedNpcTargeting ~= true
		)
		return true
	end
	local cageDirection = if equippedWeapon.Name == CageConfig.WEAPON_MODEL_NAME
		then getAttackDirection(attackerRoot, requestedDirection)
		else nil
	if cageDirection then
		local targetCharacter, captureCenter = findCageAreaTarget(
			character,
			cageDirection,
			requestedTarget,
			requestedAttackOrigin,
			trustedNpcTargeting == true
		)
		if targetCharacter and captureCenter then
			putInCage(targetCharacter, captureCenter)
		end
		return true
	end

	task.delay(Config.HIT_DELAY_SECONDS, function()
		local hitWindowEndsAt = os.clock() + Config.HIT_WINDOW_DURATION_SECONDS
		repeat
			if not character.Parent
				or humanoid.Health <= 0
				or characterIsCaged(character)
				or findEquippedWeapon(character) ~= equippedWeapon
				or not handle:IsDescendantOf(equippedWeapon) then
				return
			end

			local targetCharacter = if trustedNpcTargeting == true
				then findRequestedBatTarget(character, requestedDirection, requestedTarget)
				else (findHandleContactTarget(character, handle)
					or findBatFallbackTarget(character))
			if targetCharacter then
				emitBatHitFeedback(targetCharacter)
				knockDown(
					targetCharacter,
					character,
					Config.KNOCKDOWN_DURATION_SECONDS,
					false,
					Config.KNOCKBACK_SPEED,
					Config.KNOCKBACK_UPWARD_SPEED,
					Config.KNOCKBACK_TIP_SPEED,
					nil,
					nil,
					nil
				)
				return
			end
			RunService.Heartbeat:Wait()
		until os.clock() >= hitWindowEndsAt
	end)
	return true
end

local function handleAttack(
	player: Player,
	requestedDirection: any,
	requestedTarget: any,
	requestedWeapon: any,
	requestedAttackOrigin: any
)
	local character = player.Character
	if character then
		tryAttackCharacter(
			character,
			requestedDirection,
			requestedTarget,
			false,
			requestedWeapon,
			requestedAttackOrigin
		)
	end
end

local function isManagedRoundNpc(character: Model): boolean
	local npcFolder = Workspace:FindFirstChild(ROUND_NPC_FOLDER_NAME)
	return npcFolder ~= nil
		and character.Parent == npcFolder
		and character:GetAttribute(MANAGED_ROUND_NPC_ATTRIBUTE) == true
end

local function equipManagedNpcWeapon(character: Model, weaponName: string): Tool?
	if not isManagedRoundNpc(character) or not isWeaponName(weaponName) then
		return nil
	end
	local existingWeapon = findEquippedWeapon(character)
	if existingWeapon then
		if existingWeapon:GetAttribute("NpcWeaponOwned") ~= true then
			return nil
		end
		existingWeapon:Destroy()
	end
	local weapon: Tool
	if weaponName == FistConfig.WEAPON_MODEL_NAME then
		weapon = createFistTool()
	else
		local template = ServerStorage:FindFirstChild(weaponName)
		if not template or not template:IsA("Tool") then
			warn(`WeaponHandler: ServerStorage.{weaponName} must be a Tool`)
			return nil
		end

		makeHierarchyArchivable(template)
		weapon = template:Clone()
	end
	weapon:SetAttribute("NpcWeaponOwned", true)
	if not attachWeapon(character, weapon) then
		weapon:Destroy()
		return nil
	end
	weapon.Parent = character
	return weapon
end

local function registerNpcWeaponAdapter()
	-- NPCWeapons is optional. Removing that folder completely disables NPC Tool
	-- behavior while the player weapon path below keeps working unchanged.
	local npcWeaponsFolder = script.Parent:FindFirstChild("NPCWeapons")
	local bridgeModule = if npcWeaponsFolder
		then npcWeaponsFolder:FindFirstChild("WeaponBridge")
		else nil
	if not bridgeModule or not bridgeModule:IsA("ModuleScript") then
		return
	end

	local succeeded, bridgeOrMessage = pcall(require, bridgeModule)
	if not succeeded then
		warn(`WeaponHandler: NPC weapon bridge failed to load: {tostring(bridgeOrMessage)}`)
		return
	end
	local bridge = bridgeOrMessage :: any
	bridge.SetAdapter({
		EquipWeapon = equipManagedNpcWeapon,
		Attack = function(character: Model, requestedDirection: any, requestedTarget: any): boolean
			if not isManagedRoundNpc(character) then
				return false
			end
			return tryAttackCharacter(
				character,
				requestedDirection,
				requestedTarget,
				true,
				nil,
				nil
			)
		end,
	})
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
	local refreshScheduled = false
	local function refreshWeapons()
		if refreshScheduled then
			return
		end
		refreshScheduled = true
		task.defer(function()
			refreshScheduled = false
			local character = player.Character
			if character then
				task.spawn(giveWeapons, player, character)
			end
		end)
	end
	player:GetAttributeChangedSignal(
		WeaponShopConfig.OWNERSHIP_READY_ATTRIBUTE
	):Connect(refreshWeapons)
	for _, item in ipairs(WeaponShopConfig.ITEMS) do
		player:GetAttributeChangedSignal(
			ownedAttributeName(item.WEAPON_NAME)
		):Connect(refreshWeapons)
	end
	player:GetAttributeChangedSignal(
		WeaponShopConfig.ROUND_ARENA_TELEPORT_REVISION_ATTRIBUTE
	):Connect(function()
		resetPlayerAttackCooldowns(player)
	end)
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
	local character = player.Character
	if character then
		nextAttackAtByCharacter[character] = nil
	end
end)
attackRemote.OnServerEvent:Connect(handleAttack)
registerNpcWeaponAdapter()
task.spawn(bindRoundCooldownReset)
